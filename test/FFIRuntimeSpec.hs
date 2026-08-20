-- | host-runtime F003: the runtime is the host's, and calling out of order
-- is an error code rather than a dead process.
--
-- Everything here goes through the C symbols — @pm_init_ex@, @pm_init@,
-- @pm_shutdown@ and the gate in @cbits\/pm_gate.c@ — not through the
-- Haskell functions of "Magic.FFI" the rest of the suite calls. That is
-- the whole point: the gate exists because entering a @foreign export@
-- before @hs_init@ or after @hs_exit@ terminates the process from inside
-- the RTS, so the check has to be on the C side of the boundary and only a
-- C call can observe it.
--
-- Two facts shape every case below, and both are properties of running
-- in-process rather than of the implementation:
--
--   * This process already has a runtime (hspec is a Haskell executable),
--     so @pm_init_ex@ always takes the "the host got here first" branch:
--     the capability count is applied through the runtime's own API and
--     the nursery, GC mode and statistics flag cannot be, which is exactly
--     the degradation C2.4 requires to be reported rather than ignored.
--     The other branch — the runtime started by this library — is only
--     reachable from a fresh process and belongs to host-runtime F006.
--   * The state machine moves UNINIT → RUNNING → CLOSED once per process.
--     So the cases run in declaration order, the one initialisation that
--     can take effect is the racing one, and shutdown is last: after it
--     the gate answers sentinels for the rest of the process. No other
--     spec module is affected, because no other one calls the C symbols.
module FFIRuntimeSpec (spec) where

import qualified Data.ByteString as BS
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Monad (forM_, void)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Word (Word32, Word64)
import FFIContractSpec (readUtf8)
import FFIHarness (spellBytes)
import Magic.FFI (pmMaxParticles)
import Foreign.C.String (CString, peekCAString)
import Foreign.C.Types (CChar, CDouble (..), CFloat (..), CInt (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (pokeArray)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (Storable (..))
import GHC.Conc (getNumCapabilities)
import GHC.Stats (getRTSStatsEnabled)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

spec :: Spec
spec = describe "runtime lifecycle (host-runtime F003)" $ do
  -- T7 -------------------------------------------------------------------
  it "answers a sentinel instead of killing the process before init" $ do
    -- Every one of these used to end the process with "newBoundTask: RTS
    -- is not initialised", on both platforms. Reaching the end of this
    -- case at all is the acceptance criterion.
    c_pm_max_particles `shouldReturn` pmErrState
    c_pm_is_finished nullPtr `shouldReturn` pmErrState
    c_pm_emitter_count nullPtr `shouldReturn` pmErrState
    c_pm_scene_count nullPtr `shouldReturn` pmErrState
    c_pm_project 0 nullPtr nullPtr nullPtr 0 nullPtr nullPtr nullPtr
      `shouldReturn` pmErrState
    c_pm_depth_order 0 nullPtr nullPtr nullPtr 0 nullPtr `shouldReturn` pmErrState

    -- The types with no error channel answer their own equivalent.
    c_pm_age nullPtr `shouldReturn` (-7.0)
    c_pm_occupancy_mask nullPtr `shouldReturn` 0
    c_pm_advance nullPtr 0.016 `shouldReturn` ()
    c_pm_free nullPtr `shouldReturn` ()
    c_pm_scene_free nullPtr `shouldReturn` ()
    c_pm_scene_dismiss nullPtr 0 `shouldReturn` ()
    c_pm_scene_advance nullPtr 0.016 `shouldReturn` ()
    c_pm_scene_new 128 `shouldReturn` nullPtr

    -- pm_cast has an err_buf, so the refusal is readable: fixed ASCII,
    -- NUL terminated, and inside the buffer it was given.
    json <- spellBytes "ring-fire"
    (handle, reason) <-
      BS.useAsCString json $ \circle ->
        allocaBytes 256 $ \err -> do
          pokeArray err (replicate 256 (0x21 :: CChar))
          h <- c_pm_cast circle nullPtr nullPtr 7 err 256
          msg <- peekCAString err
          pure (h, msg)
    handle `shouldBe` nullPtr
    reason `shouldSatisfy` (\m -> "pm_init" `isInfixOf'` m && length m < 256)

    -- The one symbol the gate does not close. A host is told to compare
    -- generations at startup, which is before pm_init, so this has to be
    -- answerable without a runtime.
    c_pm_abi_version `shouldReturn` 1

  -- T3 -------------------------------------------------------------------
  it "answers PM_ERR_ARGS for every out-of-range config and starts nothing" $ do
    c_pm_init_ex nullPtr `shouldReturn` pmErrArgs
    forM_ badConfigs $ \(label, cfg) -> do
      rc <- withConfig cfg c_pm_init_ex
      (label, rc) `shouldBe` (label, pmErrArgs)
    -- Refused before the state machine, so nothing started: the gate is
    -- still shut and the initialisation below can still be the first one.
    c_pm_max_particles `shouldReturn` pmErrState

  -- T2 (the atomicity the state machine buys) -----------------------------
  it "lets only one of two racing initialisations win" $ do
    caps0 <- getNumCapabilities
    statsBefore <- getRTSStatsEnabled
    writeIORef baselineCaps caps0
    writeIORef baselineStats statsBefore

    -- The two threads ask for different capability counts, which is what
    -- makes "exactly one of you got through" observable: only the winner
    -- reaches the runtime, so afterwards the count is one of the two asked
    -- for and never both, and never the count we started with.
    gate <- newEmptyMVar
    boxes <- mapM (const newEmptyMVar) [1 :: Int, 2]
    forM_ (zip [caps0 + 1, caps0 + 2] boxes) $ \(want, box) ->
      void $ forkIO $ do
        () <- readMVar gate
        rc <- withConfig (degraded want) c_pm_init_ex
        putMVar box rc
    putMVar gate ()
    codes <- mapM takeMVar boxes

    -- Both answer PM_ERR_STATE, for the two different reasons the header
    -- spells out: the winner could not honour the nursery and the GC mode
    -- (this process's runtime was already up), the loser did nothing at
    -- all. Neither crashed, which is the acceptance criterion.
    codes `shouldBe` [pmErrState, pmErrState]
    caps1 <- getNumCapabilities
    caps1 `shouldSatisfy` (`elem` [caps0 + 1, caps0 + 2])

  -- T4 -------------------------------------------------------------------
  it "applies the capability count and reports the fields it could not honour" $ do
    caps0 <- readIORef baselineCaps
    caps1 <- getNumCapabilities
    -- What the degraded call DID do: the capability count took effect
    -- through the runtime's own API, exactly as C2.4's degradation clause
    -- promises, even though the call reported PM_ERR_STATE.
    caps1 `shouldSatisfy` (> caps0)

    -- ... and what it did not do: the library is up and completely
    -- usable. A whole lifecycle through the gate, C symbol by C symbol.
    json <- spellBytes "ring-fire"
    -- The gate forwards rather than answering: this is the Haskell side's
    -- own number coming back through the C symbol.
    c_pm_max_particles `shouldReturn` pmMaxParticles
    spell <- BS.useAsCString json $ \circle ->
      allocaBytes 256 $ \err -> c_pm_cast circle nullPtr nullPtr 7 err 256
    spell `shouldNotBe` nullPtr
    emitters <- c_pm_emitter_count spell
    emitters `shouldSatisfy` (> 0)
    c_pm_is_finished spell `shouldReturn` 0
    c_pm_advance spell 0.016
    age <- c_pm_age spell
    age `shouldSatisfy` (> 0)
    c_pm_free spell

    scene <- c_pm_scene_new 4096
    scene `shouldNotBe` nullPtr
    c_pm_scene_count scene `shouldReturn` 0
    c_pm_scene_free scene

  -- T2 -------------------------------------------------------------------
  it "refuses a second initialisation instead of silently ignoring it" $ do
    caps1 <- getNumCapabilities
    -- The runtime's own hs_init_ghc ignores a second call's settings in
    -- silence and just bumps a reference count. The state machine refuses
    -- instead, and the capability count proves nothing was applied.
    withConfig (plain (caps1 + 4)) c_pm_init_ex `shouldReturn` pmErrState
    getNumCapabilities `shouldReturn` caps1
    -- The frozen void one keeps its old promise: idempotent, no-op.
    c_pm_init
    getNumCapabilities `shouldReturn` caps1
    -- The gate forwards rather than answering: this is the Haskell side's
    -- own number coming back through the C symbol.
    c_pm_max_particles `shouldReturn` pmMaxParticles

  -- T12 ------------------------------------------------------------------
  it "only reports GC numbers when the host asked for statistics at init" $ do
    statsBefore <- readIORef baselineStats
    enabled <- getRTSStatsEnabled
    -- The flag never changes after startup, in either direction: that is
    -- the fact PmConfig.stats exists for. This suite's own runtime is
    -- started with -T (see the cabal file), so what the racing PM_STATS_ON
    -- call exercised is the header's "the host's runtime already collects
    -- them" row -- asking was not a degradation, and asking did not turn
    -- anything on either.
    enabled `shouldBe` statsBefore

    caps <- getNumCapabilities
    withConfig ((plain caps) {cfgStats = pmStatsOff}) c_pm_init_ex
      `shouldReturn` pmErrState
    getRTSStatsEnabled `shouldReturn` statsBefore
    c_pm_init
    getRTSStatsEnabled `shouldReturn` statsBefore

    -- The criterion host-runtime F011 has to implement pm_stats against,
    -- pinned where F011 will read it. getRTSStats() answers a zero pause
    -- time when statistics are off, which is indistinguishable from a real
    -- zero, so the flag -- not the field -- is the only honest test.
    header <- readUtf8 "include/particle_magic.h"
    header `shouldSatisfy` isInfixOf' "getRTSStatsEnabled"
    header `shouldSatisfy` isInfixOf' "UNAVAILABLE"
    header `shouldSatisfy` isInfixOf' "PM_STATS_ON"

  -- T11 ------------------------------------------------------------------
  it "documents the runtime contract per platform in the integration guide" $ do
    doc <- readUtf8 "docs/integration.md"
    mapM_
      (\needle -> doc `shouldSatisfy` isInfixOf' needle)
      [ "pm_init_ex"
      , "PmConfig"
      , "PM_STATS_ON"
      , "PM_GC_NONMOVING"
      , "PM_ERR_STATE"
      , "8192"
      ]
    -- The old rule said the runtime cannot be restarted and stopped
    -- there, leaving what actually happens (the process died) unsaid.
    doc `shouldSatisfy` isInfixOf' "pm_shutdown"

  -- T5 (LAST: shutdown is a one-way door for the whole process) ----------
  it "makes shutdown one-way, identically on Windows and Linux" $ do
    caps <- getNumCapabilities
    c_pm_shutdown

    -- Every sentinel is back, which is the two platforms' shared answer:
    -- it comes from the state machine, not from whether the runtime under
    -- it actually stopped.
    c_pm_max_particles `shouldReturn` pmErrState
    c_pm_is_finished nullPtr `shouldReturn` pmErrState
    c_pm_age nullPtr `shouldReturn` (-7.0)
    c_pm_occupancy_mask nullPtr `shouldReturn` 0
    c_pm_scene_new 128 `shouldReturn` nullPtr
    c_pm_advance nullPtr 0.016 `shouldReturn` ()

    -- Re-initialising used to kill the process ("reinitializing the RTS
    -- after shutdown is not currently supported"). Now it is a code, and
    -- the settings in it are not applied.
    withConfig (plain (caps + 3)) c_pm_init_ex `shouldReturn` pmErrState
    getNumCapabilities `shouldReturn` caps
    c_pm_init
    c_pm_max_particles `shouldReturn` pmErrState

    -- Shutting down twice never reaches hs_exit a second time, so the
    -- runtime's "too many hs_exit()s" warning cannot happen.
    c_pm_shutdown
    c_pm_max_particles `shouldReturn` pmErrState

    -- And the process is still here to say so.
    c_pm_abi_version `shouldReturn` 1

-- Error codes and enums (literals on purpose: this spec is the C side's
-- mirror, so it must not be derived from the Haskell constants it checks)

pmErrArgs, pmErrState :: CInt
pmErrArgs = -4
pmErrState = -7

pmGcDefault, pmGcNonmoving, pmStatsOff, pmStatsOn :: Word32
pmGcDefault = 0
pmGcNonmoving = 1
pmStatsOff = 0
pmStatsOn = 1

-- The configuration struct ----------------------------------------------------

-- | @PmConfig@ as the header lays it out: 4 + 4 + 8 + 4 + 4 = 24 bytes,
-- no padding on any Tier 1 ABI. The offsets are written out rather than
-- derived, because being wrong about them is precisely the drift this
-- spec is here to catch.
data PmConfig = PmConfig
  { cfgSize :: Word32
  , cfgCapabilities :: Word32
  , cfgNurseryBytes :: Word64
  , cfgGcMode :: Word32
  , cfgStats :: Word32
  }

instance Storable PmConfig where
  sizeOf _ = 24
  alignment _ = 8
  peek p =
    PmConfig
      <$> peekByteOff p 0
      <*> peekByteOff p 4
      <*> peekByteOff p 8
      <*> peekByteOff p 16
      <*> peekByteOff p 20
  poke p c = do
    pokeByteOff p 0 (cfgSize c)
    pokeByteOff p 4 (cfgCapabilities c)
    pokeByteOff p 8 (cfgNurseryBytes c)
    pokeByteOff p 16 (cfgGcMode c)
    pokeByteOff p 20 (cfgStats c)

withConfig :: PmConfig -> (Ptr PmConfig -> IO a) -> IO a
withConfig cfg k = alloca $ \p -> poke p cfg >> k p

-- | A well-formed config asking for nothing this process cannot give.
plain :: Int -> PmConfig
plain caps =
  PmConfig
    { cfgSize = 24
    , cfgCapabilities = fromIntegral caps
    , cfgNurseryBytes = 0
    , cfgGcMode = pmGcDefault
    , cfgStats = pmStatsOn
    }

-- | A well-formed config asking for three things a runtime that is already
-- running cannot be given: the nursery size, the collector and (in a
-- process without -T) the statistics flag.
degraded :: Int -> PmConfig
degraded caps =
  (plain caps)
    { cfgNurseryBytes = 64 * 1024 * 1024
    , cfgGcMode = pmGcNonmoving
    , cfgStats = pmStatsOn
    }

-- | The error table's PM_ERR_ARGS rows, one config each. Every bound is
-- one the runtime would otherwise enforce by aborting the whole process.
badConfigs :: [(String, PmConfig)]
badConfigs =
  [ ("size 0", (plain 1) {cfgSize = 0})
  , ("size too small", (plain 1) {cfgSize = 16})
  , ("size too large", (plain 1) {cfgSize = 32})
  , ("capabilities above PM_MAX_CAPABILITIES", (plain 1) {cfgCapabilities = 257})
  , ("nursery below PM_NURSERY_MIN_BYTES", (plain 1) {cfgNurseryBytes = 8191})
  , ("nursery above PM_NURSERY_MAX_BYTES", (plain 1) {cfgNurseryBytes = 1073741825})
  , ("unknown gc_mode", (plain 1) {cfgGcMode = 2})
  , ("unknown stats", (plain 1) {cfgStats = 2})
  ]

-- Cross-case state ------------------------------------------------------------

-- | The capability count and statistics flag as they were before the one
-- initialisation this process can perform. Recorded rather than recomputed
-- because the initialisation changes the first of them, and the cases that
-- check what it changed run afterwards.
{-# NOINLINE baselineCaps #-}
baselineCaps :: IORef Int
baselineCaps = unsafePerformIO (newIORef 0)

{-# NOINLINE baselineStats #-}
baselineStats :: IORef Bool
baselineStats = unsafePerformIO (newIORef False)

-- The C symbols ---------------------------------------------------------------

-- Imported by their C names, so these go through cbits/pm_gate.c and
-- cbits/pm_init.c — the real gate and the real state machine, linked into
-- this executable from the same two c-sources the foreign library uses.
-- The handle arguments are opaque here on purpose: outside RUNNING the
-- gate returns before anything looks at them.

foreign import ccall "pm_init" c_pm_init :: IO ()

foreign import ccall "pm_init_ex" c_pm_init_ex :: Ptr PmConfig -> IO CInt

foreign import ccall "pm_shutdown" c_pm_shutdown :: IO ()

foreign import ccall "pm_abi_version" c_pm_abi_version :: IO CInt

foreign import ccall "pm_max_particles" c_pm_max_particles :: IO CInt

foreign import ccall "pm_cast"
  c_pm_cast ::
    CString -> Ptr CFloat -> Ptr CFloat -> Word64 -> CString -> CInt -> IO (Ptr ())

foreign import ccall "pm_advance" c_pm_advance :: Ptr () -> CFloat -> IO ()

foreign import ccall "pm_is_finished" c_pm_is_finished :: Ptr () -> IO CInt

foreign import ccall "pm_age" c_pm_age :: Ptr () -> IO CDouble

foreign import ccall "pm_free" c_pm_free :: Ptr () -> IO ()

foreign import ccall "pm_emitter_count" c_pm_emitter_count :: Ptr () -> IO CInt

foreign import ccall "pm_occupancy_mask" c_pm_occupancy_mask :: Ptr () -> IO Word32

foreign import ccall "pm_scene_new" c_pm_scene_new :: CInt -> IO (Ptr ())

foreign import ccall "pm_scene_free" c_pm_scene_free :: Ptr () -> IO ()

foreign import ccall "pm_scene_count" c_pm_scene_count :: Ptr () -> IO CInt

foreign import ccall "pm_scene_dismiss" c_pm_scene_dismiss :: Ptr () -> CInt -> IO ()

foreign import ccall "pm_scene_advance" c_pm_scene_advance :: Ptr () -> CFloat -> IO ()

foreign import ccall "pm_project"
  c_pm_project ::
    CInt ->
    Ptr CFloat ->
    Ptr CFloat ->
    Ptr CFloat ->
    CInt ->
    Ptr CFloat ->
    Ptr CFloat ->
    Ptr CFloat ->
    IO CInt

foreign import ccall "pm_depth_order"
  c_pm_depth_order ::
    CInt -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> CInt -> Ptr CInt -> IO CInt

isInfixOf' :: String -> String -> Bool
isInfixOf' needle haystack = any (needle `prefixes`) (tails' haystack)
  where
    prefixes [] _ = True
    prefixes _ [] = False
    prefixes (a : as) (b : bs) = a == b && prefixes as bs
    tails' [] = [[]]
    tails' xs@(_ : rest) = xs : tails' rest
