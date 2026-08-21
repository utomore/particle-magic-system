-- | host-runtime B002: on the "the runtime was ALREADY running" row, a
-- capability count of 0 is a request — @follow the hardware@ — and not a
-- blank.
--
-- Why this is a module of its own rather than another case in
-- "FFIRuntimeSpec": the state machine allows exactly ONE initialisation
-- per process, and "FFIRuntimeSpec" spends it on the racing pair (T2). So
-- @pm_init_ex@ can be asked for one configuration per process and no
-- in-process spec can enumerate the degradation branch. B002 lived there:
-- @capabilities == 0@ was neither applied nor counted into
-- @PM_ERR_STATE@, and T4 only ever asked for a non-zero count.
--
-- What is called here is therefore the branch itself —
-- @pm_runtime_apply_to_running@ from @cbits\/pm_runtime.h@, the function
-- @pm_rt_start@ delegates that row to. It is internal: not in
-- @include\/particle_magic.h@, not in @particle-magic-ffi.def@, no
-- @PM_EXPORT@, so it joins neither the ABI nor the export face. The
-- end-to-end version of the same assertion is the Linux-only
-- @rts-prestarted-zero-caps@ probe in @test\/oop\/oop_smoke.c@, which can
-- own a fresh process and read @n_capabilities@ through @dlsym@.
--
-- This module runs before "FFIRuntimeSpec" (hspec-discover orders modules
-- alphabetically) and touches no part of the state machine, so the one
-- initialisation is still that spec's to spend. The capability count it
-- moves is put back before any expectation can throw.
module FFIRuntimeCapsSpec (spec) where

import Control.Exception (bracket_)
import Data.Word (Word32, Word64)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (Storable (..))
import GHC.Conc (getNumCapabilities, getNumProcessors, setNumCapabilities)
import Test.Hspec

spec :: Spec
spec = describe "the already-running runtime row (host-runtime B002)" $ do
  -- B002 T1 ---------------------------------------------------------------
  it "applies capabilities = 0 as 'follow the hardware' instead of dropping it" $ do
    procs <- getNumProcessors
    -- The suite's own runtime starts at -N, i.e. already at the hardware's
    -- count, so the request has to be made from below to be observable.
    (rc, applied) <- fromOneCapability (withConfig zeroed c_apply)
    -- Nothing was refused: on this row the capability count is the field
    -- the runtime's own API can still be given, so a config that asks for
    -- nothing else is a complete success and not a degradation.
    rc `shouldBe` pmOk
    -- The whole bug in one line. Before the fix this stayed at 1: the
    -- request was neither applied nor reported.
    applied `shouldBe` procs

  -- B002 T4 ---------------------------------------------------------------
  it "still applies a non-zero capability count" $ do
    procs <- getNumProcessors
    let want = min 2 (max 1 procs)
    (rc, applied) <- fromOneCapability (withConfig (zeroed {cfgCapabilities = fromIntegral want}) c_apply)
    rc `shouldBe` pmOk
    applied `shouldBe` want

  -- B002 T5 ---------------------------------------------------------------
  it "keeps pm_init's own call a no-op" $ do
    -- pm_init passes NULL: conservative defaults, frozen behaviour. A
    -- config the host never wrote is the one case where "nothing was
    -- asked for" is true, so nothing may be applied and nothing reported.
    (rc, applied) <- fromOneCapability (c_apply nullPtr)
    rc `shouldBe` pmOk
    applied `shouldBe` 1

  -- B002 T6 ---------------------------------------------------------------
  it "reports the fields this row cannot honour, with or without a capability count" $ do
    procs <- getNumProcessors
    -- The degradation report is unchanged by the fix, and it is orthogonal
    -- to the capability count: asking for 0 does not suppress it, and the
    -- count is applied anyway.
    let nursery = zeroed {cfgNurseryBytes = 64 * 1024 * 1024}
        nonmoving = zeroed {cfgGcMode = pmGcNonmoving}
    (rcNursery, appliedNursery) <- fromOneCapability (withConfig nursery c_apply)
    rcNursery `shouldBe` pmErrState
    appliedNursery `shouldBe` procs
    (rcGc, appliedGc) <- fromOneCapability (withConfig nonmoving c_apply)
    rcGc `shouldBe` pmErrState
    appliedGc `shouldBe` procs
    -- This suite's runtime is started with -T (see particle-magic.cabal),
    -- so asking for statistics is not a degradation here: the host's
    -- runtime already collects them.
    (rcStats, _) <- fromOneCapability (withConfig (zeroed {cfgStats = pmStatsOn}) c_apply)
    rcStats `shouldBe` pmOk

-- Driving the branch ----------------------------------------------------------

-- | Run one application from a runtime that is deliberately down to a
-- single capability, and report what it answered together with the count
-- it left behind. The count is restored before the caller can assert on
-- anything, so a failing expectation cannot leak a changed runtime into
-- the rest of the suite (@ParallelSampleSpec@ varies the same number).
fromOneCapability :: IO CInt -> IO (CInt, Int)
fromOneCapability act = do
  original <- getNumCapabilities
  bracket_ (setNumCapabilities 1) (setNumCapabilities original) $ do
    rc <- act
    applied <- getNumCapabilities
    pure (rc, applied)

-- Error codes (literals on purpose, as in FFIRuntimeSpec: this is the C
-- side's mirror and must not be derived from the constants it checks)

pmOk, pmErrState :: CInt
pmOk = 0
pmErrState = -7

pmGcNonmoving, pmStatsOn :: Word32
pmGcNonmoving = 1
pmStatsOn = 1

-- The configuration struct ----------------------------------------------------

-- | @PmConfig@ as the header lays it out: 4 + 4 + 8 + 4 + 4 = 24 bytes.
-- Written out rather than derived, for the reason "FFIRuntimeSpec" gives
-- for its own copy.
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

-- | Exactly what the header tells a host to write: zero the struct, set
-- @size@, fill in what you care about — and care about nothing. That makes
-- @capabilities@ 0, which is "follow the hardware" and is the request B002
-- dropped.
zeroed :: PmConfig
zeroed =
  PmConfig
    { cfgSize = 24
    , cfgCapabilities = 0
    , cfgNurseryBytes = 0
    , cfgGcMode = 0
    , cfgStats = 0
    }

withConfig :: PmConfig -> (Ptr PmConfig -> IO a) -> IO a
withConfig cfg k = alloca $ \p -> poke p cfg >> k p

-- The internal seam -----------------------------------------------------------

-- Imported by its C name, so this is the same translation unit
-- @pm_init_ex@ calls into: cbits/pm_init.c is one of this suite's
-- c-sources.
foreign import ccall "pm_runtime_apply_to_running"
  c_apply :: Ptr PmConfig -> IO CInt
