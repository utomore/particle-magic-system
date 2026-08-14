-- | Shared marshalling harness for the func-spec 0009 specs (S1, S2, S3,
-- S5). The C ABI is exercised /in process/: the foreign-exported functions
-- are ordinary Haskell functions, so the tests allocate real CStrings and
-- Ptrs and call them exactly as a C host would, without loading the built
-- shared object (that is S6, the manual smoke).
--
-- Every buffer allocated here is over-sized by 'guardSlots' elements and
-- pre-filled with a sentinel, so a spec can assert both "the right values
-- landed in the right slots" and "nothing outside the promised range was
-- touched".
module FFIHarness
  ( -- * Casting
    testCtx
  , spellBytes
  , castOk
  , castRaw
  , castCode
  , CastFailure (..)

    -- * Observing
  , Observed (..)
  , observeRaw
  , batchTuples
  , guardSlots
  , floatSentinel
  , wordSentinel
  , intSentinel

    -- * Reference path (plain 'Magic.Interface')
  , referenceSpell
  , referenceAt
  , referenceStates
  ) where

import qualified Data.ByteString as BS
import Data.Word (Word32, Word64)
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CFloat (..), CInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (peekArray, pokeArray, withArray)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.StablePtr (StablePtr)
import Foreign.Storable (peek)
import GHC.Float (float2Double)
import qualified GHC.Foreign as GHCF
import GHC.IO.Encoding (utf8)
import Magic.Codec (loadCircle)
import Magic.FFI
  ( SpellCell
  , isNullSpell
  , nullSpell
  , pm_cast_ex
  , pm_free
  , pm_observe
  , pmOk
  )
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  )

-- | The cast context every 0009 spec uses, on both sides of the boundary.
testCtx :: CastContext
testCtx =
  CastContext
    { casterPos = V3 1.5 0.25 (-2)
    , casterFacing = V3 0 0 1
    , seed = Seed 20260814
    }

-- | Bytes of a shipped example spell.
spellBytes :: FilePath -> IO BS.ByteString
spellBytes name = BS.readFile ("assets/spells/" ++ name ++ ".json")

-- | Why a 'castRaw' failed: the classified code plus the message the
-- library wrote into the host's buffer.
data CastFailure = CastFailure
  { cfCode :: CInt
  , cfMessage :: String
  }
  deriving (Eq, Show)

-- | Cast through the C ABI. @errLen@ is the size of the error buffer the
-- "host" provides.
castRaw :: BS.ByteString -> CastContext -> Int -> IO (Either CastFailure (StablePtr SpellCell))
castRaw bytes ctx errLen =
  withCStringBytes bytes $ \json ->
    withV3 (casterPos ctx) $ \posPtr ->
      withV3 (casterFacing ctx) $ \facingPtr ->
        allocaBytes (max 1 errLen) $ \errBuf -> do
          fillErr errBuf errLen
          with nullSpell $ \out -> do
            let Seed s = seed ctx
            code <- pm_cast_ex json posPtr facingPtr s errBuf (fromIntegral errLen) out
            handle <- peek out
            if isNullSpell handle
              then do
                msg <- if errLen > 0 then GHCF.peekCString utf8 errBuf else pure ""
                pure (Left (CastFailure code msg))
              else pure (Right handle)

-- | 'castRaw' for the happy path; fails loudly if the cast did not.
castOk :: BS.ByteString -> CastContext -> IO (StablePtr SpellCell)
castOk bytes ctx = do
  result <- castRaw bytes ctx 512
  case result of
    Left failure -> error ("cast failed unexpectedly: " ++ show failure)
    Right handle -> pure handle

-- | The status code 'pm_cast_ex' answers with, handle released.
castCode :: BS.ByteString -> CastContext -> IO CInt
castCode bytes ctx = do
  result <- castRaw bytes ctx 512
  case result of
    Left failure -> pure (cfCode failure)
    Right handle -> pm_free handle >> pure pmOk

-- | Everything @pm_observe@ wrote, buffers included in full (promised
-- range /and/ guard region), so callers can check both.
data Observed = Observed
  { obCode :: CInt
  , obPosX :: [Float]
  , obPosY :: [Float]
  , obPosZ :: [Float]
  , obSize :: [Float]
  , obLife :: [Float]
  , obColor :: [Word32]
  , obInfo :: [CInt]
  }
  deriving (Eq, Show)

-- | Slots allocated past the capacity handed to the library. Nothing may
-- ever write here.
guardSlots :: Int
guardSlots = 4

floatSentinel :: Float
floatSentinel = -12345.5

wordSentinel :: Word32
wordSentinel = 0xDEADBEEF

intSentinel :: CInt
intSentinel = -999

-- | Call @pm_observe@ with the given host capacities.
observeRaw :: StablePtr SpellCell -> Int -> Int -> IO Observed
observeRaw handle capacity maxBatches = do
  let slots = max 0 capacity + guardSlots
      infoSlots = 4 * max 0 maxBatches + guardSlots
  withArray (replicate slots (CFloat floatSentinel)) $ \px ->
    withArray (replicate slots (CFloat floatSentinel)) $ \py ->
      withArray (replicate slots (CFloat floatSentinel)) $ \pz ->
        withArray (replicate slots (CFloat floatSentinel)) $ \psize ->
          withArray (replicate slots (CFloat floatSentinel)) $ \plife ->
            withArray (replicate slots wordSentinel) $ \pcolor ->
              withArray (replicate infoSlots intSentinel) $ \pinfo -> do
                code <-
                  pm_observe
                    handle
                    px
                    py
                    pz
                    psize
                    plife
                    pcolor
                    (fromIntegral capacity)
                    pinfo
                    (fromIntegral maxBatches)
                let floats p = map (\(CFloat f) -> f) <$> peekArray slots p
                Observed code
                  <$> floats px
                  <*> floats py
                  <*> floats pz
                  <*> floats psize
                  <*> floats plife
                  <*> peekArray slots pcolor
                  <*> peekArray infoSlots pinfo

-- | The batch descriptors as @(offset, count, blend, shape)@ tuples.
batchTuples :: Int -> Observed -> [(Int, Int, Int, Int)]
batchTuples n obs =
  [ (at (4 * i), at (4 * i + 1), at (4 * i + 2), at (4 * i + 3))
  | i <- [0 .. n - 1]
  ]
  where
    at i = fromIntegral (obInfo obs !! i)

-- | The same spell through plain 'Magic.Interface' — the reference every
-- FFI result is compared against.
referenceSpell :: BS.ByteString -> CastContext -> ActiveSpell
referenceSpell bytes ctx =
  case loadCircle bytes of
    Left err -> error ("reference load failed: " ++ show err)
    Right circle -> case castSpell CastRequest {circleOf = circle, ctxOf = ctx} of
      Left err -> error ("reference cast failed: " ++ show err)
      Right spell -> spell

-- | The reference spell advanced by a sequence of dt values, each widened
-- from @float@ exactly as the C ABI widens it.
referenceAt :: ActiveSpell -> [Float] -> ActiveSpell
referenceAt = foldl step

step :: ActiveSpell -> Float -> ActiveSpell
step spell dt = advanceSpell (FrameInput (DeltaTime (float2Double dt))) spell

-- | The reference spell's state after each prefix of the frame sequence
-- (the initial state excluded, so the list lines up with a host loop that
-- advances and then observes).
referenceStates :: BS.ByteString -> [Float] -> [ActiveSpell]
referenceStates bytes dts = drop 1 (scanl step (referenceSpell bytes testCtx) dts)

-- Marshalling ---------------------------------------------------------------

-- | Hand raw JSON bytes over as a NUL-terminated C string.
withCStringBytes :: BS.ByteString -> (CString -> IO a) -> IO a
withCStringBytes bytes =
  withArray (map fromIntegral (BS.unpack bytes) ++ [0] :: [CChar])

withV3 :: V3 -> (Ptr CFloat -> IO a) -> IO a
withV3 (V3 x y z) = withArray [CFloat x, CFloat y, CFloat z]

-- | Pre-fill the error buffer so a spec can tell "wrote nothing" from
-- "wrote an empty string".
fillErr :: CString -> Int -> IO ()
fillErr buf len
  | buf == nullPtr || len <= 0 = pure ()
  | otherwise = pokeArray buf (replicate len 0x21) -- '!'
