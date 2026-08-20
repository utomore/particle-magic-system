{-# LANGUAGE LambdaCase #-}

-- | host-runtime F001: the exception firewall.
--
-- A Haskell exception crossing a @foreign export@ boundary is not an error
-- a host can handle — the RTS terminates the process and prints to a
-- stderr nobody is reading. The subsystem's first acceptance criterion
-- (P-1) says the library never does that to its host, so every one of the
-- 29 exported symbols now runs inside 'firewall' or 'firewallErr', which
-- answer @PM_ERR_INTERNAL@ (or the sentinel that stands for it in the
-- return type) instead of letting anything through.
--
-- The cases below are the feature's TodoList, one to one: the combinator
-- against every kind of exception, the error buffer, the source audit that
-- keeps future symbols from escaping the rule, the per-symbol answers for
-- a handle whose contents are bottom, and the bit-for-bit regression that
-- says a legal call did not change.
module FFIFirewallSpec (spec) where

import Control.Exception (Exception, SomeException, evaluate, throwIO, try)
import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.Either (isRight)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Vector.Unboxed as U
import FFIContractSpec (readUtf8)
import FFIHarness
  ( Observed (..)
  , batchTuples
  , castOk
  , observeRaw
  , referenceAt
  , referenceSpell
  , spellBytes
  , testCtx
  )
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CDouble, CFloat (..), CInt (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray, pokeArray)
import Foreign.Ptr (Ptr, nullPtr, plusPtr)
import Foreign.StablePtr (StablePtr)
import GHC.Float (castFloatToWord32)
import qualified GHC.Foreign as GHCF
import GHC.IO.Encoding (utf8)
import Magic.FFI
  ( SceneCell
  , SpellCell
  , blendCode
  , firewall
  , firewallErr
  , freeSceneHandle
  , freeSpellHandle
  , newSceneHandle
  , isNullSpell
  , newSpellHandle
  , nullSpell
  , pmErrInternal
  , pmMaxParticles
  , pm_advance
  , pm_age
  , pm_emitter_box
  , pm_emitter_count
  , pm_free
  , pm_is_finished
  , pm_observe
  , pm_observe_ex
  , pm_occupancy
  , pm_occupancy_mask
  , pm_scene_advance
  , pm_scene_budget
  , pm_scene_cast
  , pm_scene_cast_many
  , pm_scene_count
  , pm_scene_dismiss
  , pm_scene_free
  , pm_scene_observe
  , pm_scene_spell_bounds
  , pm_scene_spells
  , pm_spell_bounds
  , pm_spell_box
  , shapeCode
  )
import Magic.Interface
  ( ActiveSpell
  , ParticleBuffer (pbColor, pbCount, pbLife, pbPosX, pbPosY, pbPosZ, pbSize)
  , RenderBatch (..)
  , batches
  , observeSpell
  )
import Magic.Scene (Scene)
import Test.Hspec

spec :: Spec
spec = describe "exception firewall (host-runtime F001)" $ do
  -- T3 -------------------------------------------------------------------
  it "maps every kind of Haskell exception to the sentinel" $ do
    -- A thrown exception of the host's own making, an `error` call, an
    -- `undefined`, and — the one that motivates 'evaluate' — an action
    -- that returns perfectly well and hides the bottom in its result. The
    -- last case is the regression: drop the 'evaluate' from the combinator
    -- and the exception is raised when GHC's foreign export wrapper
    -- unboxes the result, which is outside the 'try'.
    firewall sentinel (throwIO Boom) `shouldReturn` sentinel
    firewall sentinel (error "boom" :: IO CInt) `shouldReturn` sentinel
    firewall sentinel (undefined :: IO CInt) `shouldReturn` sentinel
    firewall sentinel (pure (error "thunk" :: CInt)) `shouldReturn` sentinel

    -- The sentinel is the return type's own, not a number: the two handle
    -- symbols answer NULL, pm_age answers -6.0, pm_occupancy_mask answers
    -- 0 and the void ones answer nothing at all.
    (firewall nullSpell (throwIO Boom) >>= evaluate)
      >>= \h -> isNullSpell h `shouldBe` True
    firewall (-6.0 :: CDouble) (pure (error "thunk")) `shouldReturn` (-6.0)
    firewall (0 :: Word) (throwIO Boom) `shouldReturn` 0
    firewall () (throwIO Boom) `shouldReturn` ()

    -- Nothing escapes, in any of those shapes.
    caught <- try (mapM_ (firewall sentinel) throwers) :: IO (Either SomeException ())
    caught `shouldSatisfy` isRight

    -- And a body that does not throw is handed straight back.
    firewall sentinel (pure 7) `shouldReturn` 7
    firewallErr nullPtr 0 sentinel (pure 7) `shouldReturn` 7

  -- T4 -------------------------------------------------------------------
  it "writes the exception text into err_buf, truncation safe" $ do
    (msg, guardRegion) <-
      withErrBuf 256 $ \buf len ->
        firewallErr buf len sentinel (error "the circle came apart")
          `shouldReturn` sentinel
    msg `shouldSatisfy` isInfixOf "internal error: "
    msg `shouldSatisfy` isInfixOf "the circle came apart"
    guardRegion `shouldBe` replicate guardBytes bang

    -- Truncation lands on a character boundary even when the message is
    -- multi-byte throughout: peekCString would throw on a split sequence,
    -- so decoding at all is the assertion.
    (short, shortGuard) <-
      withErrBuf 12 $ \buf len ->
        firewallErr buf len sentinel (error "魔法陣が壊れました")
          `shouldReturn` sentinel
    length short `shouldSatisfy` (< 12)
    shortGuard `shouldBe` replicate guardBytes bang

    -- The message-rendering path is itself protected: an exception whose
    -- own text explodes must not turn a caught defect into an uncaught one.
    (fallback, _) <-
      withErrBuf 256 $ \buf len ->
        firewallErr buf len sentinel (throwIO (Cursed (error "message bottom")))
          `shouldReturn` sentinel
    fallback `shouldSatisfy` isInfixOf "internal error"

    -- A NULL buffer and a zero capacity are no-ops, not crashes: that is
    -- what lets 'firewall' be 'firewallErr' with nothing to write to.
    firewallErr nullPtr 512 sentinel (throwIO Boom) `shouldReturn` sentinel
    (_, zeroGuard) <-
      withErrBuf 0 $ \buf len ->
        firewallErr buf len sentinel (throwIO Boom) `shouldReturn` sentinel
    zeroGuard `shouldBe` replicate guardBytes bang

  -- T5 -------------------------------------------------------------------
  it "every foreign export goes through the firewall (source audit)" $ do
    ls <- lines <$> readUtf8 ffiSource
    let exports = foreignExports ls
    length exports `shouldBe` 29
    mapM_
      (\name -> (name, definitionHasFirewall ls name) `shouldBe` (name, Just True))
      exports

  -- T6 -------------------------------------------------------------------
  it "every handle-taking symbol answers its sentinel for a poisoned handle" $ do
    -- The registry is lazy in the cell's contents (host-runtime F002), so
    -- a bottom behind a perfectly legal handle is the in-process way to
    -- reach the firewall without inventing a symbol for it: no build flag,
    -- no environment variable, no new semantics in the shipped library.
    json <- spellBytes "ring-fire"
    mapM_ (\(name, act) -> withPoisonedSpell (labelled name . act)) poisonedSpellCases
    mapM_ (\(name, act) -> withPoisonedScene (labelled name . act json)) poisonedSceneCases
    -- Reaching this line at all is the acceptance criterion: 22 symbols
    -- were driven over a bottom and the process is still here.
    length poisonedSpellCases + length poisonedSceneCases `shouldBe` 22

  -- T7 -------------------------------------------------------------------
  it "legal input is bit-identical with the firewall in place" $
    mapM_ bitIdentical ["ring-fire", "spiral-spark", "grand-sigil", "converge-flame"]

-- Fixtures --------------------------------------------------------------------

ffiSource :: FilePath
ffiSource = "src/ffi/Magic/FFI.hs"

-- | The counting symbols' sentinel, the one this spec uses most.
sentinel :: CInt
sentinel = pmErrInternal

-- | An exception of the host's own making — nothing about the firewall may
-- depend on which exception type arrives.
data Boom = Boom
  deriving (Show)

instance Exception Boom

-- | An exception whose own rendering explodes, which is why
-- 'displayException' is called under a second 'try'.
newtype Cursed = Cursed String

instance Show Cursed where
  show (Cursed s) = s

instance Exception Cursed

throwers :: [IO CInt]
throwers =
  [ throwIO Boom
  , error "boom"
  , undefined
  , pure (error "thunk")
  , throwIO (Cursed (error "message bottom"))
  ]

-- Error buffer ----------------------------------------------------------------

guardBytes :: Int
guardBytes = 8

-- | The fill byte, @'!'@ — a byte 'writeErr' would never produce, so a
-- guard slot still holding it proves nothing was written there.
bang :: CChar
bang = 0x21

-- | Run an action against a buffer of @len@ usable bytes followed by
-- 'guardBytes' more, every byte pre-filled with 'bang'. Gives back what
-- the buffer decodes to and the guard region's raw bytes.
withErrBuf :: Int -> (CString -> CInt -> IO ()) -> IO (String, [CChar])
withErrBuf len k =
  allocaBytes (len + guardBytes) $ \buf -> do
    pokeArray buf (replicate (len + guardBytes) bang)
    k buf (fromIntegral len)
    msg <- if len > 0 then GHCF.peekCString utf8 buf else pure ""
    guardRegion <- peekArray guardBytes (buf `plusPtr` len)
    pure (msg, guardRegion)

-- Source audit ----------------------------------------------------------------

-- | Names in @foreign export ccall <name>@ declarations. Deliberately not
-- a written-down list: a symbol added by a later feature joins the audit
-- by existing, and fails it until it carries a firewall of its own.
foreignExports :: [String] -> [String]
foreignExports ls =
  [name | l <- ls, ("foreign" : "export" : "ccall" : name : _) <- [words (trim l)]]

-- | Does the named symbol's own definition block mention a firewall
-- combinator? The block runs from the first line that starts with
-- @name @ (its type signature excluded) to the next top-level definition.
--
-- Nesting is not accepted as a substitute — @pm_cast@ delegates to
-- @pm_cast_ex@, which is protected, and both are still asked to carry one,
-- because "the body I can see is wrapped" is a property a reviewer can
-- check locally and a call chain is not.
definitionHasFirewall :: [String] -> String -> Maybe Bool
definitionHasFirewall ls name =
  case break isDefinition ls of
    (_, []) -> Nothing
    (_, start : rest) ->
      Just (any ("firewall" `isInfixOf`) (start : takeWhile continues rest))
  where
    isDefinition l = (name ++ " ") `isPrefixOf` l && not ((name ++ " ::") `isPrefixOf` l)
    continues l = null (trim l) || (take 1 l `elem` [" ", "\t"])

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- Poisoned handles --------------------------------------------------------------

-- | A spell nobody can look at without falling over.
poisonedSpell :: ActiveSpell
poisonedSpell = error "FFIFirewallSpec: poisoned spell"

poisonedScene :: Scene
poisonedScene = error "FFIFirewallSpec: poisoned scene"

-- | A fresh poisoned handle per case, released afterwards, so a case that
-- happens to free its handle (@pm_free@) cannot disturb the next one.
withPoisonedSpell :: (StablePtr SpellCell -> IO ()) -> IO ()
withPoisonedSpell k = do
  h <- newSpellHandle poisonedSpell
  k h
  freeSpellHandle h

withPoisonedScene :: (StablePtr SceneCell -> IO ()) -> IO ()
withPoisonedScene k = do
  h <- newSceneHandle poisonedScene
  k h
  freeSceneHandle h

-- | Name the symbol when an expectation fails; a table-driven sweep
-- otherwise reports only "expected -6".
labelled :: String -> IO () -> IO ()
labelled name act =
  try act >>= \case
    Right () -> pure ()
    Left e -> expectationFailure (name ++ ": " ++ show (e :: SomeException))

-- | The twelve entry points that take a @PmSpell*@, each with the answer
-- the sentinel table assigns it. The five that return @void@ can only be
-- asked to return at all — which is the promise, for a symbol C gave no
-- room to report in.
poisonedSpellCases :: [(String, StablePtr SpellCell -> IO ())]
poisonedSpellCases =
  [ ("pm_advance", \h -> pm_advance h 0.016 `shouldReturn` ())
  , ("pm_is_finished", \h -> pm_is_finished h `shouldReturn` pmErrInternal)
  , ("pm_age", \h -> pm_age h `shouldReturn` (-6.0))
  , ("pm_observe", \h -> observeAll h `shouldReturn` pmErrInternal)
  , ("pm_observe_ex", \h -> observeExAll h `shouldReturn` pmErrInternal)
  , -- Releasing a handle never touches what is behind it, so this one is
    -- a plain success: the firewall is present and has nothing to catch.
    ("pm_free", \h -> pm_free h `shouldReturn` ())
  ,
    ( "pm_spell_bounds"
    , \h -> allocaArray 3 $ \lo ->
        allocaArray 3 $ \hi -> pm_spell_bounds h lo hi `shouldReturn` pmErrInternal
    )
  , ("pm_spell_box", \h -> withBoxOut (pm_spell_box h) `shouldReturn` pmErrInternal)
  , ("pm_emitter_count", \h -> pm_emitter_count h `shouldReturn` pmErrInternal)
  , ("pm_emitter_box", \h -> withBoxOut (pm_emitter_box h 0) `shouldReturn` pmErrInternal)
  ,
    ( "pm_occupancy"
    , \h -> allocaArray 27 $ \out -> pm_occupancy h 3 out 27 `shouldReturn` pmErrInternal
    )
  , ("pm_occupancy_mask", \h -> pm_occupancy_mask h `shouldReturn` 0)
  ]

-- | The ten entry points that take a @PmScene*@. The two cast entry points
-- need real JSON to get as far as the scene, which is why the bytes are
-- threaded through.
poisonedSceneCases :: [(String, BS.ByteString -> StablePtr SceneCell -> IO ())]
poisonedSceneCases =
  [ ("pm_scene_free", \_ h -> pm_scene_free h `shouldReturn` ())
  ,
    ( "pm_scene_cast"
    , \json h -> BS.useAsCString json $ \c -> alloca $ \outId ->
        pm_scene_cast h c nullPtr nullPtr 0 nullPtr 0 outId `shouldReturn` pmErrInternal
    )
  ,
    ( "pm_scene_cast_many"
    , \_ h -> alloca $ \outId ->
        pm_scene_cast_many h nullPtr 0 nullPtr nullPtr 0 nullPtr 0 outId
          `shouldReturn` pmErrInternal
    )
  , ("pm_scene_dismiss", \_ h -> pm_scene_dismiss h 0 `shouldReturn` ())
  , ("pm_scene_advance", \_ h -> pm_scene_advance h 0.016 `shouldReturn` ())
  ,
    ( "pm_scene_observe"
    , \_ h ->
        pm_scene_observe h nullPtr nullPtr nullPtr nullPtr nullPtr nullPtr 0 nullPtr 0
          `shouldReturn` pmErrInternal
    )
  ,
    ( "pm_scene_budget"
    , \_ h -> alloca $ \used ->
        alloca $ \capacity -> pm_scene_budget h used capacity `shouldReturn` pmErrInternal
    )
  , ("pm_scene_count", \_ h -> pm_scene_count h `shouldReturn` pmErrInternal)
  ,
    ( "pm_scene_spells"
    , \_ h -> allocaArray 4 $ \ids -> pm_scene_spells h ids 4 `shouldReturn` pmErrInternal
    )
  ,
    ( "pm_scene_spell_bounds"
    , \_ h -> allocaArray 3 $ \lo ->
        allocaArray 3 $ \hi -> pm_scene_spell_bounds h 0 lo hi `shouldReturn` pmErrInternal
    )
  ]

withBoxOut :: (Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> IO CInt) -> IO CInt
withBoxOut k =
  allocaArray 3 $ \center ->
    allocaArray 9 $ \axes ->
      allocaArray 3 $ \halfExtents -> k center axes halfExtents

observeAll :: StablePtr SpellCell -> IO CInt
observeAll h =
  pm_observe h nullPtr nullPtr nullPtr nullPtr nullPtr nullPtr 0 nullPtr 0

observeExAll :: StablePtr SpellCell -> IO CInt
observeExAll h =
  pm_observe_ex
    h
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    0
    nullPtr
    0

-- The bit-for-bit regression ----------------------------------------------------

dt :: Float
dt = 1 / 60

frames, maxBatches :: Int
frames = 120
maxBatches = 64

-- | A legal call's output through the C ABI, compared with the plain
-- 'Magic.Interface' path bit pattern by bit pattern (a 'Float' comparison
-- would let a @-0.0@ through). The firewall adds one 'try' and one
-- 'evaluate' of an already-evaluated value to the success path, and this
-- is the assertion that says so.
bitIdentical :: String -> IO ()
bitIdentical name = do
  bytes <- spellBytes name
  handle <- castOk bytes testCtx
  mapM_ (\_ -> pm_advance handle (CFloat dt)) [1 .. frames]
  obs <- observeRaw handle (fromIntegral pmMaxParticles) maxBatches
  pm_free handle

  let reference = referenceAt (referenceSpell bytes testCtx) (replicate frames dt)
      refBatches = batches (observeSpell reference)
      buffers = map rbParticles refBatches
      column f = concatMap (U.toList . f) buffers
      written = sum (map pbCount buffers)
      counts = map pbCount buffers
      offsets = scanl (+) 0 counts
      bits = map castFloatToWord32

  obCode obs `shouldBe` fromIntegral (length refBatches)
  -- guard against a vacuously green comparison
  (name, written) `shouldSatisfy` ((> 0) . snd)
  same name "pos.x" (bits (take written (obPosX obs))) (bits (column pbPosX))
  same name "pos.y" (bits (take written (obPosY obs))) (bits (column pbPosY))
  same name "pos.z" (bits (take written (obPosZ obs))) (bits (column pbPosZ))
  same name "size" (bits (take written (obSize obs))) (bits (column pbSize))
  same name "life" (bits (take written (obLife obs))) (bits (column pbLife))
  same name "color" (take written (obColor obs)) (column pbColor)
  batchTuples (length refBatches) obs
    `shouldBe` [ (off, n, fromIntegral (blendCode (rbBlend b)), fromIntegral (shapeCode (rbShape b)))
               | (off, n, b) <- zip3 offsets counts refBatches
               ]

same :: (Eq a) => String -> String -> a -> a -> Expectation
same name field actual expected =
  if actual == expected
    then pure ()
    else expectationFailure (name ++ ": " ++ field ++ " is not bit-identical")
