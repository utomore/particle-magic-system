-- | S3 (func-spec 0009 §8): the error protocol.
--
-- Two promises are on trial. First, a host learns exactly what a Haskell
-- host would: the text is 'renderLoadError' verbatim — the same string the
-- demo HUD puts on screen (ADR-0011 D6) — and the classified code
-- separates "this JSON is not a circle" from "this circle is too big".
-- Second, writing that text into a caller-owned buffer is safe at every
-- size: never past @err_len@, always NUL-terminated, and never cut inside
-- a multi-byte character, so the host always decodes valid UTF-8.
module FFIErrorSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.List (isInfixOf, isPrefixOf)
import Data.Word (Word8)
import FFIHarness (CastFailure (..), castRaw, testCtx)
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CInt)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (peekArray, pokeArray)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (peek)
import qualified GHC.Foreign as GHCF
import GHC.IO.Encoding (utf8)
import Magic.Codec (loadCircle, renderLoadError)
import Magic.Compile (budgetCap)
import Magic.FFI (isNullSpell, nullSpell, pm_cast_ex, pmErrBudget, pmErrJson, writeErr)
import Test.Hspec
import Test.QuickCheck

-- | Malformed input a host might plausibly send.
badSyntax, badVersion, badRune, badElement :: BS.ByteString
badSyntax = BS8.pack "{ \"version\": 1, \"circle\": { "
badVersion = BS8.pack "{ \"version\": 7, \"circle\": {} }"
badRune = BS8.pack "{ \"version\": 1, \"circle\": { \"bridge\": { \"rune\": \"bogus\" } } }"
badElement = BS8.pack "{ \"version\": 1, \"circle\": { \"core\": { \"center\": { \"element\": \"aether\", \"power\": 1 } } } }"

-- | Well-formed, decodes fine, and asks for 80 × 256 = 20480 particles —
-- past the core's cap (4096 when this was written, 16384 since func-spec
-- 0012 S1).
overBudget :: BS.ByteString
overBudget =
  BS8.pack
    "{ \"version\": 1, \"circle\": { \"core\": { \"center\": { \"element\": \"fire\", \"power\": 80.0 } } } }"

-- | A message with characters outside ASCII, so the truncation sweep has
-- multi-byte boundaries to get wrong (2-, 3- and 4-byte sequences).
multiByteMessage :: String
multiByteMessage = "spell JSON error: 魔法陣 slot \"護\" — naïve 🎆 tail"

-- | Slots allocated past the buffer handed to the library; nothing may
-- ever write here.
guardBytes :: Int
guardBytes = 8

-- | Fill byte: any value a message would not produce.
fillByte :: Word8
fillByte = 0x21 -- '!'

-- | Messages built from characters of all four UTF-8 widths, so a
-- generated truncation lands mid-sequence often. (QuickCheck's stock
-- 'String' generator can emit lone surrogates, which are not encodable at
-- all — a different failure than the one under test.)
newtype Message = Message String
  deriving (Show)

instance Arbitrary Message where
  arbitrary = Message <$> listOf (elements alphabet)
    where
      alphabet = "ab!/\"\\ " ++ "äöüé" ++ "魔法陣護" ++ "🎆🔥"

spec :: Spec
spec = describe "C ABI error protocol (func-spec 0009 §8 S3)" $ do
  describe "classification and message text" $ do
    it "answers PM_ERR_JSON with renderLoadError's text for malformed JSON" $
      mapM_ jsonFailureMatches [badSyntax, badVersion, badRune, badElement]

    it "answers PM_ERR_BUDGET for a circle the core refuses to compile" $ do
      result <- castRaw overBudget testCtx 256
      case result of
        Right _ -> expectationFailure "an over-budget circle was cast"
        Left failure -> do
          cfCode failure `shouldBe` pmErrBudget
          cfMessage failure
            `shouldSatisfy` isInfixOf ("BudgetExceeded 20480 " ++ show budgetCap)

    it "distinguishes the two failures by code, not only by text" $ do
      jsonCode <- failureCode badSyntax
      budgetCode <- failureCode overBudget
      jsonCode `shouldBe` Just pmErrJson
      budgetCode `shouldBe` Just pmErrBudget

    it "treats a NULL json pointer as a JSON error rather than a crash" $ do
      ((code, handle), _) <- withErrBuf 128 $ \buf len ->
        with nullSpell $ \out -> do
          code <- pm_cast_ex nullPtr nullPtr nullPtr 0 buf len out
          handle <- peek out
          pure (code, handle)
      code `shouldBe` pmErrJson
      isNullSpell handle `shouldBe` True

    it "returns NULL for every malformed input" $
      mapM_ castYieldsNoHandle [badSyntax, badVersion, badRune, badElement, overBudget]

  describe "err_buf is safe at every size" $ do
    it "writes nothing when err_len is 0" $ do
      (_, raw) <- withErrBuf 0 (\buf len -> writeErr buf len multiByteMessage)
      raw `shouldSatisfy` all (== fillByte)

    it "writes nothing when err_buf is NULL" $
      writeErr nullPtr 64 multiByteMessage -- must not crash

    it "always NUL-terminates inside the buffer, at every truncation point" $
      mapM_ terminatesWithin [0 .. utf8Length multiByteMessage + 4]

    it "never leaves a partial character: every truncation decodes as UTF-8" $
      mapM_ decodesAsPrefix [1 .. utf8Length multiByteMessage + 4]

    it "round-trips the whole message once the buffer is big enough" $ do
      (text, _) <- withErrBufDecoded (utf8Length multiByteMessage + 1) multiByteMessage
      text `shouldBe` multiByteMessage

    it "never writes past err_len (property, arbitrary message and size)" $
      property $ \(NonNegative len) (Message msg) ->
        len <= 64 ==> ioProperty $ do
          (_, raw) <- withErrBuf len (\buf n -> writeErr buf n msg)
          pure (drop len raw == replicate guardBytes fillByte)

    it "always decodes to a prefix of the message (property)" $
      property $ \(Positive len) (Message msg) ->
        len <= 64 ==> ioProperty $ do
          (text, _) <- withErrBufDecoded len msg
          pure (text `isPrefixOf` msg)

-- | The FFI's message for bad JSON is exactly what a Haskell host gets.
jsonFailureMatches :: BS.ByteString -> Expectation
jsonFailureMatches bytes = do
  result <- castRaw bytes testCtx 512
  case (result, loadCircle bytes) of
    (Left failure, Left err) -> do
      cfCode failure `shouldBe` pmErrJson
      cfMessage failure `shouldBe` renderLoadError err
    (Left _, Right _) -> expectationFailure "the reference path accepted what the FFI rejected"
    (Right _, _) -> expectationFailure "the FFI accepted malformed JSON"

failureCode :: BS.ByteString -> IO (Maybe CInt)
failureCode bytes = do
  result <- castRaw bytes testCtx 256
  pure $ case result of
    Left failure -> Just (cfCode failure)
    Right _ -> Nothing

castYieldsNoHandle :: BS.ByteString -> Expectation
castYieldsNoHandle bytes = do
  result <- castRaw bytes testCtx 128
  case result of
    Left failure -> cfCode failure `shouldSatisfy` (< 0)
    Right _ -> expectationFailure "a handle came back from a failing cast"

-- | The buffer, plus its guard region, after running an action over it.
withErrBuf :: Int -> (CString -> CInt -> IO a) -> IO (a, [Word8])
withErrBuf len k =
  allocaBytes (len + guardBytes) $ \buf -> do
    pokeArray buf (replicate (len + guardBytes) (fromIntegral fillByte :: CChar))
    a <- k buf (fromIntegral len)
    raw <- peekArray (len + guardBytes) buf
    pure (a, map fromIntegral raw)

-- | 'withErrBuf' plus the host's side of the deal: decode the C string.
withErrBufDecoded :: Int -> String -> IO (String, [Word8])
withErrBufDecoded len msg =
  withErrBuf len $ \buf n -> do
    writeErr buf n msg
    GHCF.peekCString utf8 buf

terminatesWithin :: Int -> Expectation
terminatesWithin len = do
  (_, raw) <- withErrBuf len (\buf n -> writeErr buf n multiByteMessage)
  drop len raw `shouldBe` replicate guardBytes fillByte
  if len == 0
    then take len raw `shouldBe` []
    else take len raw `shouldSatisfy` elem 0

decodesAsPrefix :: Int -> Expectation
decodesAsPrefix len = do
  (text, _) <- withErrBufDecoded len multiByteMessage
  text `shouldSatisfy` (`isPrefixOf` multiByteMessage)

-- | Length of the UTF-8 encoding, the unit @err_len@ is measured in.
utf8Length :: String -> Int
utf8Length = sum . map width
  where
    width c
      | c < '\x80' = 1
      | c < '\x800' = 2
      | c < '\x10000' = 3
      | otherwise = 4
