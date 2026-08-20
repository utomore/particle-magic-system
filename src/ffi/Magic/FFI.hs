{-# LANGUAGE LambdaCase #-}

-- | C ABI shell (func-spec 0009 §4.1, ADR-0011): the whole system behind
-- a flat set of @foreign export ccall@ entry points, so non-Haskell hosts
-- (Unity, Godot, a hand-rolled C\/C++ engine) can drive
-- @pm_cast → pm_advance × n → pm_observe → pm_free@ against
-- @include\/particle_magic.h@ alone.
--
-- Three rules shape everything here:
--
--   * __Thin wrapper, zero new semantics.__ The only work done in this
--     module is type crossing (@CString@ → 'BS.ByteString', scalars →
--     'CastContext', @U.Vector@ → @Ptr@) and handle management. Every
--     behavioural decision comes from the frozen 'Magic.Interface'
--     functions. Any behaviour that exists only on the FFI side is a bug —
--     @test\/Acceptance9Spec.hs@ turns that sentence into an equivalence
--     law (ADR-0011 D8).
--   * __Handle = a generation-tagged index over an 'IORef'__ (ADR-0011 D4
--     as revised by ADR-022 D3). 'advanceSpell' is pure, hosts want
--     in-place advance, so the handle names a cell that @pm_advance@
--     reads-computes-writes back. The handle is no longer a live
--     'StablePtr': it is a word encoding kind, slot and generation, which
--     "Magic.FFI.Registry" resolves — so a freed, double-freed or forged
--     handle is an error code rather than undefined behaviour. One handle
--     is owned by one thread; there is no internal lock in v1.
--   * __copy-out, never borrow__ (ADR-0011 D3). 'Data.Vector.Unboxed' has
--     no pointer interface, so @pm_observe@ pokes element by element into
--     host-owned arrays.
--
-- The exported functions are ordinary Haskell functions too, which is how
-- the test-suite exercises them in-process (no DLL load needed — the test
-- runner's RTS is already up). Loading the real shared object is the
-- manual smoke of func-spec 0009 §8 S6.
--
-- __Frozen__ (spec 0009 §4.4): the @foreign export@ list below, the error
-- code values, the @batch_info@ layout and the handle lifecycle. Not
-- frozen: everything else in this module, including 'writeErr' and the
-- copy-out strategy.
module Magic.FFI
  ( -- * Entry points (the frozen C contract)
    pm_abi_version
  , pm_cast
  , pm_cast_ex
  , pm_advance
  , pm_is_finished
  , pm_age
  , pm_observe
  , pm_observe_ex
  , pm_free
  , pm_max_particles
  , pm_project
  , pm_depth_order

    -- * Scene entry points (func-spec 0018; the same contract, extended)
  , pm_scene_new
  , pm_scene_free
  , pm_scene_cast
  , pm_scene_cast_many
  , pm_scene_dismiss
  , pm_scene_advance
  , pm_scene_observe
  , pm_scene_budget
  , pm_scene_count
  , pm_scene_spells

    -- * Spatial summary entry points (func-spec 0025; add-only)
  , pm_spell_bounds
  , pm_spell_box
  , pm_emitter_count
  , pm_emitter_box
  , pm_occupancy
  , pm_occupancy_mask
  , pm_scene_spell_bounds

    -- * Contract constants (mirrored in @include\/particle_magic.h@,
    -- guarded by @test\/FFIContractSpec.hs@)
  , pmAbiVersion
  , pmMaxParticles
  , pmOk
  , pmErrJson
  , pmErrBudget
  , pmErrCapacity
  , pmErrArgs
  , pmErrQuota
  , pmErrInternal
  , pmErrState
  , pmOccupancyDimDefault
  , pmPlaneSideXY
  , pmPlaneTopXZ
  , blendCode
  , shapeCode
  , planeOf
  , refusalCode

    -- * Internals (not part of the C contract; exposed for testing)
  , SpellCell (..)
  , nullSpell
  , isNullSpell
  , SceneCell (..)
  , nullScene
  , isNullScene
  , writeErr

    -- * The exception firewall (host-runtime F001; not part of the C
    -- contract, exposed so the specs can hand it an action that throws)
  , firewall
  , firewallErr

    -- * Handle registry internals (host-runtime F002; not part of the C
    -- contract, exposed so the specs can drive the lifecycle directly)
  , newSpellHandle
  , freeSpellHandle
  , newSceneHandle
  , freeSceneHandle
  , spellRegistryStats
  , sceneRegistryStats
  ) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Monad (foldM, when)
import qualified Data.ByteString as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word64, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CDouble (..), CFloat (..), CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.StablePtr (StablePtr, castPtrToStablePtr, castStablePtrToPtr)
import Foreign.Storable (peek, peekByteOff, peekElemOff, poke, pokeByteOff, pokeElemOff)
import GHC.Float (float2Double)
import qualified GHC.Foreign as GHCF
import GHC.IO.Encoding (utf8)
import Magic.Codec (loadCircle, renderLoadError)
import Magic.Columns (fromColumns)
import Magic.FFI.Registry
  ( HandleKind (..)
  , Registry
  , Resolved (..)
  , newRegistry
  , registryInsert
  , registryRelease
  , registryResolve
  , registryStats
  )
import Magic.Interface
  ( ActiveSpell
  , BillboardShape
  , BlendMode (..)
  , CastContext (..)
  , CastRequest (..)
  , Circle
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (batches)
  , OccupancyGrid (..)
  , OrientedBox (..)
  , ParticleBuffer
      ( pbColor
      , pbCount
      , pbLife
      , pbPosX
      , pbPosY
      , pbPosZ
      , pbSize
      , pbVelX
      , pbVelY
      , pbVelZ
      )
  , RenderBatch (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , emitterBoxOf
  , emittersOf
  , isFinished
  , observeSpell
  , occupancyDimDefault
  , occupancyMask
  , occupancyOf
  , spellAge
  , spellBoundsOf
  , spellBoxOf
  )
import Magic.Projection (V2 (..), ViewPlane (..), depthOrder, orthographic)
import Magic.Scene
  ( CastRefusal (..)
  , Scene
  , SceneConfig (..)
  , SpellId (..)
  , advanceScene
  , castInto
  , castManyInto
  , dismiss
  , lookupSpell
  , newScene
  , observeScene
  , sceneBudget
  , sceneSpells
  )
import System.IO.Unsafe (unsafePerformIO)

-- Contract constants ---------------------------------------------------------

-- | Bumped only by an ABI-breaking change; hosts check it at startup.
pmAbiVersion :: CInt
pmAbiVersion = 1

-- | Mirror of the core's @budgetCap@ — the third copy of that constant
-- (core, the demo's @gpuCapacity@, this header). ADR-0011 books the
-- synchronisation duty on the future throughput spec;
-- @test\/FFIContractSpec.hs@ ties all three together so the drift is
-- caught in CI, not in a host's memory corruption.
--
-- Func-spec 0011 makes this the /queryable/ copy: 'pm_max_particles'
-- answers with it, and the contract spec asserts it equals the core's cap
-- (the mirror law). @PM_MAX_PARTICLES@ in the header stays pinned at the
-- first generation's 4096 forever — it is frozen — so when the core cap
-- rises it is this constant that follows, and hosts that size their
-- buffers from the query keep working with no recompile of the header.
-- Func-spec 0012 S1 is the first exercise of that design: the core cap
-- went 4096 → 16384 and this line is the entire FFI-side change. The
-- header was not touched.
pmMaxParticles :: CInt
pmMaxParticles = 16384

pmOk, pmErrJson, pmErrBudget, pmErrCapacity, pmErrArgs, pmErrQuota, pmErrInternal, pmErrState :: CInt
pmOk = 0
pmErrJson = -1
pmErrBudget = -2
pmErrCapacity = -3

-- | A @NULL@ pointer where one is needed, a negative length, or a plane
-- selector that is neither 'pmPlaneSideXY' nor 'pmPlaneTopXZ' (func-spec
-- 0011 §3). Only the array entry points can return it.
pmErrArgs = -4

-- | The spell compiled, but the scene's @global_cap@ has no room left for
-- it (func-spec 0018): 'Magic.Scene.QuotaExceeded' crossing the boundary.
-- Distinct from 'pmErrBudget' on purpose — a host can retry a quota
-- refusal after dismissing something, and cannot retry a compile failure
-- at all.
pmErrQuota = -5

-- | The firewall caught a Haskell exception (ADR-022 D2, host-runtime
-- C1.9): something inside the library is broken. Never the host's fault,
-- never worth retrying, and always worth a bug report — but the process
-- stays alive and the library stays usable, which is the whole point.
pmErrInternal = -6

-- | The host called out of order — the runtime is not up, or was shut
-- down, or is being configured a second time (host-runtime C1.9). The
-- semantics land with host-runtime F003 and F004; the constant is minted
-- here so the header, the Haskell mirror and the C# binding are reconciled
-- once instead of twice.
pmErrState = -7

-- | 'CastRefusal' → C code. A pure function, so the classification is
-- testable without a handle in sight, and so the /only/ decision the
-- scene entry points make is which of the frozen constants to hand back.
refusalCode :: CastRefusal -> CInt
refusalCode = \case
  CompileFailed _ -> pmErrBudget
  QuotaExceeded _ _ -> pmErrQuota

-- | The human-readable half of a refusal, for the host's @err_buf@. The
-- 'CompileFailed' text is the one 'pm_cast_ex' already writes, so the two
-- cast paths report a bad circle identically; 'QuotaExceeded' carries
-- both of its numbers, since @need@ is the one thing
-- 'pm_scene_budget' cannot tell the host afterwards (func-spec 0018 §8-2).
refusalMessage :: CastRefusal -> String
refusalMessage = \case
  CompileFailed err -> "spell compile error: " ++ show err
  QuotaExceeded need remaining ->
    "scene quota exceeded: needs "
      ++ show need
      ++ " particles, "
      ++ show remaining
      ++ " left"

-- | Mirror of the core's 'occupancyDimDefault' (func-spec 0025): the grid
-- dimension whose @3³ = 27@ cells fit in the single @uint32_t@
-- 'pm_occupancy_mask' returns. Pinned on both sides by
-- @test\/FFIContractSpec.hs@ — a host's bit indices are compiled in, so
-- this number moving would silently reinterpret every mask already
-- deployed.
pmOccupancyDimDefault :: CInt
pmOccupancyDimDefault = fromIntegral occupancyDimDefault

-- | Wire codes for 'ViewPlane', declaration order of the core's
-- constructors — same convention as 'blendCode' (guarded by
-- @test\/FFIContractSpec.hs@).
pmPlaneSideXY, pmPlaneTopXZ :: CInt
pmPlaneSideXY = 0
pmPlaneTopXZ = 1

-- | Decode a host's plane selector. Anything else is 'pmErrArgs' rather
-- than a silently substituted default: a host that passes garbage here
-- would otherwise get a plausible-looking picture along the wrong axis.
planeOf :: CInt -> Maybe ViewPlane
planeOf code
  | code == pmPlaneSideXY = Just SideXY
  | code == pmPlaneTopXZ = Just TopXZ
  | otherwise = Nothing

-- | Wire codes for 'BlendMode', declaration order of the core's
-- constructors (guarded by @test\/FFIContractSpec.hs@).
blendCode :: BlendMode -> CInt
blendCode = \case
  BlendAlpha -> 0
  BlendAdditive -> 1

-- | Wire codes for 'BillboardShape': the constructor's declaration index,
-- by definition rather than by convention (func-spec 0015 S3 — the core
-- derives 'Enum', so a new shape appended to the sum brings its code with
-- it, and @test\/FFIContractSpec.hs@ walks @[minBound .. maxBound]@
-- against the header's @PM_SHAPE_*@ defines in both directions).
shapeCode :: BillboardShape -> CInt
shapeCode = fromIntegral . fromEnum

-- Handle ---------------------------------------------------------------------

-- | What a @PmSpell*@ points at: a mutable cell holding the (immutable,
-- opaque) 'ActiveSpell'.
newtype SpellCell = SpellCell (IORef ActiveSpell)

-- | The @NULL@ handle. C sees it as a null pointer; every entry point
-- tolerates it (no-op or neutral value) so a host that forgot to check
-- @pm_cast@'s result gets a quiet failure rather than a crash.
--
-- Any /other/ invalid handle — freed, freed twice, forged, or a
-- @PmScene*@ where a @PmSpell*@ belongs — is recognised by
-- "Magic.FFI.Registry" and answered with 'pmErrArgs' (or, for the symbols
-- with no error channel, a neutral value). It is no longer undefined
-- behaviour (host-runtime C2.3, ADR-022 D3).
nullSpell :: StablePtr SpellCell
nullSpell = castPtrToStablePtr nullPtr

isNullSpell :: StablePtr SpellCell -> Bool
isNullSpell h = castStablePtrToPtr h == nullPtr

-- | The spell table. A module-level 'IORef' inside, which is also what
-- keeps the cells reachable: the registry is the GC root the 'StablePtr'
-- used to be, so a released handle's spell becomes collectable at exactly
-- the same moment it did before.
spellRegistry :: Registry SpellCell
spellRegistry = unsafePerformIO (newRegistry KindSpell)
{-# NOINLINE spellRegistry #-}

-- | Register a freshly cast spell and hand back its handle.
--
-- __Lazy in the spell__, deliberately: @newSpellHandle (error "…")@ yields
-- a perfectly legal handle whose contents are bottom, which is how a spec
-- reaches the code behind the handle check.
newSpellHandle :: ActiveSpell -> IO (StablePtr SpellCell)
newSpellHandle spell = do
  ref <- newIORef spell
  castPtrToStablePtr <$> registryInsert spellRegistry (SpellCell ref)

-- | The body of 'pm_free': a handle that does not resolve (NULL, forged,
-- already released) is a safe no-op.
freeSpellHandle :: StablePtr SpellCell -> IO ()
freeSpellHandle = registryRelease spellRegistry . castStablePtrToPtr

-- | @(live spell handles, slots ever allocated)@.
spellRegistryStats :: IO (Int, Int)
spellRegistryStats = registryStats spellRegistry

-- | Three-way handle resolution (host-runtime C2.3): the frozen @NULL@
-- answer, the invalid answer, or the cell. Every spell entry point that
-- takes a handle goes through here.
withCell :: StablePtr SpellCell -> b -> b -> (IORef ActiveSpell -> IO b) -> IO b
withCell h onNull onInvalid k =
  registryResolve spellRegistry (castStablePtrToPtr h) >>= \case
    ResNull -> pure onNull
    ResInvalid -> pure onInvalid
    ResLive (SpellCell ref) -> k ref

-- | What a @PmScene*@ points at (func-spec 0018 §3.3): the same shape as
-- 'SpellCell', for the same reason — 'Magic.Scene.Scene' is an immutable
-- pure value and hosts want to advance it in place, so the handle is a
-- cell the entry points read, compute and write back (ADR-0011 D4).
--
-- A scene owns its spells outright: they have no 'SpellCell' of their
-- own, which is what keeps @pm_free@ and @pm_scene_dismiss@ from ever
-- naming the same cast (func-spec 0018 §2).
newtype SceneCell = SceneCell (IORef Scene)

-- | The @NULL@ scene handle, tolerated by every @pm_scene_*@ entry point
-- exactly as 'nullSpell' is by the single-spell ones.
nullScene :: StablePtr SceneCell
nullScene = castPtrToStablePtr nullPtr

isNullScene :: StablePtr SceneCell -> Bool
isNullScene h = castStablePtrToPtr h == nullPtr

-- | The scene table — the same structure as 'spellRegistry', tagged with
-- the other kind bit so the two handle spaces cannot be confused.
sceneRegistry :: Registry SceneCell
sceneRegistry = unsafePerformIO (newRegistry KindScene)
{-# NOINLINE sceneRegistry #-}

-- | 'newSpellHandle' for scenes, and lazy in the scene for the same
-- reason.
newSceneHandle :: Scene -> IO (StablePtr SceneCell)
newSceneHandle scene = do
  ref <- newIORef scene
  castPtrToStablePtr <$> registryInsert sceneRegistry (SceneCell ref)

-- | The body of 'pm_scene_free'.
freeSceneHandle :: StablePtr SceneCell -> IO ()
freeSceneHandle = registryRelease sceneRegistry . castStablePtrToPtr

-- | @(live scene handles, slots ever allocated)@.
sceneRegistryStats :: IO (Int, Int)
sceneRegistryStats = registryStats sceneRegistry

withScene :: StablePtr SceneCell -> b -> b -> (IORef Scene -> IO b) -> IO b
withScene h onNull onInvalid k =
  registryResolve sceneRegistry (castStablePtrToPtr h) >>= \case
    ResNull -> pure onNull
    ResInvalid -> pure onInvalid
    ResLive (SceneCell ref) -> k ref

-- The exception firewall (host-runtime F001, ADR-022 D2) ---------------------
--
-- A Haskell exception crossing a @foreign export@ boundary is not an error
-- the host can handle: the RTS terminates the process and prints to a
-- stderr nobody is reading. The pure core is total and the boundary turns
-- errors into values, so nothing here is meant to throw — but heap
-- exhaustion, a deep recursion on hostile JSON and a future incomplete
-- pattern are not things a type can rule out, and P-1 says the library
-- never kills its host.
--
-- So every entry point runs inside one of the two combinators below. The
-- firewall is the /last/ line, not a control-flow device: catching
-- anything at all means there is a defect to fix.

-- | Run an entry point's body; answer @sentinel@ if it throws.
--
-- The sentinel is the type's own way of saying @PM_ERR_INTERNAL@ —
-- 'pmErrInternal' for the counting symbols, a @NULL@ handle for the two
-- that return one, @-6.0@ for 'pm_age', @0@ for 'pm_occupancy_mask' and
-- @()@ for the five that return @void@ and have nothing to say it with.
firewall :: a -> IO a -> IO a
firewall = firewallErr nullPtr 0

-- | 'firewall' for the entry points that carry a host error buffer: the
-- exception's text goes into @err_buf@ on the way out, through the same
-- truncation-safe 'writeErr' every other failure message uses. 'firewall'
-- is this with a @NULL@ buffer, which 'writeErr' already treats as a
-- no-op — so there is one implementation, not two.
--
-- __Not all-or-nothing.__ 'pm_observe' promises that a /capacity/ failure
-- writes no byte at all; the firewall promises no such thing, because an
-- exception raised half way through a copy leaves the host's arrays half
-- updated. On this path the library promises exactly two things: it
-- returns, and it says @PM_ERR_INTERNAL@.
firewallErr :: CString -> CInt -> a -> IO a -> IO a
firewallErr buf len sentinel action =
  -- 'evaluate' is load-bearing. GHC's foreign export wrapper unboxes the
  -- result /after/ the Haskell action returns, so a body that leaves its
  -- answer in a thunk (pm_age's @Time t@, pm_is_finished's conditional)
  -- would throw outside this 'try' and walk straight past the firewall.
  -- WHNF is enough: CInt, CDouble, Word32, StablePtr and () are complete
  -- at WHNF, which is why the shell needs no deepseq.
  tryAny (action >>= evaluate) >>= \case
    Right a -> pure a
    Left e -> do
      msg <- firewallMessage e
      writeErr buf len msg
      pure sentinel

-- | 'try' at 'SomeException', written once so the entry points need no
-- type annotations — and pinned to /every/ exception on purpose (ADR-022
-- D2): a C boundary has no later moment at which to rethrow, so letting
-- an asynchronous 'Control.Exception.ThreadKilled' through would kill the
-- host just as surely as an 'ErrorCall'.
tryAny :: IO a -> IO (Either SomeException a)
tryAny = try

-- | The caught exception as text, defensively.
--
-- 'displayException' is itself a pure computation over a value that just
-- proved it can explode, so it gets its own 'try': a bottom hiding inside
-- the exception's own message must not turn a caught defect into an
-- uncaught one. The text is bounded here as well as in 'writeErr', so
-- forcing it cannot run away. Its wording is not part of any contract —
-- only "readable UTF-8" is.
firewallMessage :: SomeException -> IO String
firewallMessage e =
  tryAny (evaluate (forceString (take firewallMessageLimit rendered))) >>= \case
    Right msg -> pure msg
    Left _ -> pure "internal error: exception message unavailable"
  where
    rendered = "internal error: " ++ displayException e

-- | Bound on the exception text the firewall will force and hand to
-- 'writeErr'. Generous next to any host's @err_buf@, and finite next to a
-- message that generates itself.
firewallMessageLimit :: Int
firewallMessageLimit = 512

-- | Force a string's spine /and/ its characters, so that a bottom
-- anywhere inside it surfaces under the 'try' that asked for it rather
-- than later, in 'writeErr', outside.
forceString :: String -> String
forceString s = go s `seq` s
  where
    go [] = ()
    go (c : cs) = c `seq` go cs

-- Entry points ---------------------------------------------------------------

-- Every export below carries an explicit external name, @pm_hs_*@, because
-- the C symbol a host links against is no longer this one: host-runtime
-- F003 puts a gate in front of it (@cbits\/pm_gate.c@) that answers
-- @PM_ERR_STATE@ when the runtime is not initialised or has been shut
-- down. That check cannot live here — calling into a Haskell export
-- before @hs_init@ or after @hs_exit@ terminates the process inside the
-- RTS, before any Haskell in this module runs. So @pm_advance@ the C
-- symbol is the gate; @pm_hs_advance@ is the function below.
--
-- @pm_hs_*@ names are INTERNAL: they are not in the header and not in
-- @particle-magic-ffi.def@. Nothing else changed — the Haskell names,
-- signatures and bodies are exactly what they were, so in-process callers
-- (the whole test suite) see no difference at all.

foreign export ccall "pm_hs_abi_version" pm_abi_version :: IO CInt

pm_abi_version :: IO CInt
pm_abi_version = firewall pmErrInternal (pure pmAbiVersion)

foreign export ccall "pm_hs_max_particles" pm_max_particles :: IO CInt

-- | The particle cap this build of the core actually enforces — the
-- capacity each of @pm_observe@'s six columns needs.
--
-- Today it answers @PM_MAX_PARTICLES@ (4096). The header constant is
-- frozen at that value; this query is not, so a host that allocates from
-- it survives a future cap rise without recompiling against a new header
-- (func-spec 0011 §2, roadmap §4.2).
pm_max_particles :: IO CInt
pm_max_particles = firewall pmErrInternal (pure pmMaxParticles)

foreign export ccall "pm_hs_cast" pm_cast
  :: CString
  -> Ptr CFloat
  -> Ptr CFloat
  -> Word64
  -> CString
  -> CInt
  -> IO (StablePtr SpellCell)

-- | Load a circle from UTF-8 JSON and cast it. Returns the 'nullSpell'
-- handle on failure, with the human-readable reason written (truncation
-- safe) into @err_buf@ — the same 'renderLoadError' text the demo HUD
-- shows (ADR-0011 D6).
pm_cast
  :: CString
  -- ^ circle JSON, NUL-terminated UTF-8
  -> Ptr CFloat
  -- ^ caster position, 3 floats
  -> Ptr CFloat
  -- ^ caster facing, 3 floats
  -> Word64
  -- ^ cast seed
  -> CString
  -- ^ error buffer (may be @NULL@)
  -> CInt
  -- ^ error buffer capacity in bytes, including the NUL
  -> IO (StablePtr SpellCell)
pm_cast json posPtr facingPtr sd errBuf errLen =
  -- Nested firewalls are deliberate and harmless: the body below is
  -- 'pm_cast_ex', which is already wrapped, so the inner one catches first
  -- and this one reads back the @NULL@ handle it left in @out@. Each
  -- exported symbol still carries its own, because the source audit in
  -- @test\/FFIFirewallSpec.hs@ asks every definition — not every call
  -- chain — to be protected.
  firewallErr errBuf errLen nullSpell $
    alloca $ \out -> do
      poke out nullSpell
      _ <- pm_cast_ex json posPtr facingPtr sd errBuf errLen out
      peek out

foreign export ccall "pm_hs_cast_ex" pm_cast_ex
  :: CString
  -> Ptr CFloat
  -> Ptr CFloat
  -> Word64
  -> CString
  -> CInt
  -> Ptr (StablePtr SpellCell)
  -> IO CInt

-- | 'pm_cast' with the failure /classified/: 'pmOk', 'pmErrJson' (the JSON
-- did not decode into a 'Magic.Interface.Circle') or 'pmErrBudget' (it did,
-- but asks for more particles than the core's cap). The handle is written
-- to @out_spell@, which is set to @NULL@ on any failure.
pm_cast_ex
  :: CString
  -> Ptr CFloat
  -> Ptr CFloat
  -> Word64
  -> CString
  -> CInt
  -> Ptr (StablePtr SpellCell)
  -- ^ out: the new handle, @NULL@ on failure
  -> IO CInt
pm_cast_ex json posPtr facingPtr sd errBuf errLen out =
  firewallErr errBuf errLen pmErrInternal $ do
    writeOut nullSpell
    if json == nullPtr
      then fail' pmErrJson "spell JSON error: null pointer"
      else do
        bytes <- BS.packCString json
        case loadCircle bytes of
          Left err -> fail' pmErrJson (renderLoadError err)
          Right circle -> do
            pos <- peekV3 posPtr
            facing <- peekV3 facingPtr
            let ctx = CastContext {casterPos = pos, casterFacing = facing, seed = Seed sd}
            case castSpell CastRequest {circleOf = circle, ctxOf = ctx} of
              Left err -> fail' pmErrBudget ("spell compile error: " ++ show err)
              Right spell -> do
                handle <- newSpellHandle spell
                if isNullSpell handle
                  then -- Unreachable in practice: the slot space runs to 2³⁰
                  -- live handles. Reported rather than aliased.
                    fail' pmErrCapacity "spell handle table exhausted"
                  else do
                    writeOut handle
                    pure pmOk
  where
    writeOut h = if out == nullPtr then pure () else poke out h
    fail' code msg = writeErr errBuf errLen msg >> pure code

foreign export ccall "pm_hs_advance" pm_advance :: StablePtr SpellCell -> CFloat -> IO ()

-- | Advance the spell's clock by @dt@ seconds, in place.
pm_advance :: StablePtr SpellCell -> CFloat -> IO ()
pm_advance h dt =
  firewall () $
    withCell h () () $ \ref -> do
      spell <- readIORef ref
      writeIORef ref $! advanceSpell (FrameInput (DeltaTime (cfloatToDouble dt))) spell

foreign export ccall "pm_hs_is_finished" pm_is_finished :: StablePtr SpellCell -> IO CInt

-- | 1 when the spell has outlived its lifetime, 0 while it is running.
-- A @NULL@ handle reports 1 — nothing left to run. An /invalid/ handle
-- reports 'pmErrArgs': that is a host bug, not a finished spell.
pm_is_finished :: StablePtr SpellCell -> IO CInt
pm_is_finished h =
  -- The sentinel is right here as well as safe: -6 is truthy in C, so a
  -- host's @while (!pm_is_finished(s))@ leaves the loop instead of
  -- spinning on a spell that can no longer answer.
  firewall pmErrInternal $
    withCell h 1 pmErrArgs $ \ref -> do
      spell <- readIORef ref
      pure (if isFinished spell then 1 else 0)

foreign export ccall "pm_hs_age" pm_age :: StablePtr SpellCell -> IO CDouble

-- | Seconds since this spell was cast. There is no error channel in a
-- @double@, so both a @NULL@ and an invalid handle answer 0 — safe, and
-- the same answer a spell that has not been advanced gives.
pm_age :: StablePtr SpellCell -> IO CDouble
pm_age h =
  -- @-6.0@ is PM_ERR_INTERNAL's float mirror: an age is never negative, so
  -- the value is unambiguous, and unlike NaN it will not poison whatever
  -- clock the host mixes it into.
  firewall (-6.0) $
    withCell h 0 0 $ \ref -> do
      spell <- readIORef ref
      let Time t = spellAge spell
      pure (CDouble t)

foreign export ccall "pm_hs_observe" pm_observe
  :: StablePtr SpellCell
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr Word32
  -> CInt
  -> Ptr CInt
  -> CInt
  -> IO CInt

-- | Sample the spell at its current age and copy the result into the
-- host's six SoA columns, plus one @batch_info@ record per batch
-- (@offset@, @count@, @blend@, @shape@ — four ints, in that order).
--
-- Returns the number of batches written (≥ 0), or 'pmErrCapacity' if the
-- particles do not fit in @capacity@ / the batches do not fit in
-- @max_batches@ / a needed output pointer is @NULL@. On the error path
-- __nothing is written at all__: the capacity check runs to completion
-- before the first poke, so a host never sees a half-updated frame.
pm_observe
  :: StablePtr SpellCell
  -> Ptr CFloat
  -- ^ out: position x
  -> Ptr CFloat
  -- ^ out: position y
  -> Ptr CFloat
  -- ^ out: position z
  -> Ptr CFloat
  -- ^ out: size
  -> Ptr CFloat
  -- ^ out: life fraction
  -> Ptr Word32
  -- ^ out: packed RGBA colour
  -> CInt
  -- ^ capacity of each of the six columns, in elements
  -> Ptr CInt
  -- ^ out: batch descriptors, 4 ints per batch
  -> CInt
  -- ^ capacity of @batch_info@, in batches
  -> IO CInt
pm_observe h px py pz psize plife pcolor capacity infoPtr maxBatches =
  firewall pmErrInternal $
    pm_observe_ex
      h
      px
      py
      pz
      psize
      plife
      pcolor
      nullPtr
      nullPtr
      nullPtr
      capacity
      infoPtr
      maxBatches

foreign export ccall "pm_hs_observe_ex" pm_observe_ex
  :: StablePtr SpellCell
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr Word32
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> CInt
  -> Ptr CInt
  -> CInt
  -> IO CInt

-- | 'pm_observe' with the three velocity columns func-spec 0023 added to
-- 'Magic.Interface.ParticleBuffer' — nine columns out instead of six.
--
-- Everything else is 'pm_observe', to the letter: the same batch
-- semantics, the same @batch_info@ layout and stride, the same
-- all-or-nothing capacity rule. The two share one 'copyOut', so that is
-- one implementation rather than two that agree (func-spec 0018 S3
-- extracted it, and this is the second time that paid).
--
-- The velocity pointers are optional and independent. Pass @NULL@ for all
-- three and this /is/ @pm_observe@, bit for bit — which is what lets a
-- host adopt the new entry point without deciding about trails first.
--
-- A spell with no 'Magic.Rune.BillboardTrail' computes no velocity. Asked
-- for it anyway, this writes zeros rather than reporting an error: whether
-- a particular spell happens to trail is the spell's business, and a host
-- should not have to change the shape of its call — or size a different
-- set of arrays — because the player loaded a different circle.
pm_observe_ex
  :: StablePtr SpellCell
  -> Ptr CFloat
  -- ^ out: position x
  -> Ptr CFloat
  -- ^ out: position y
  -> Ptr CFloat
  -- ^ out: position z
  -> Ptr CFloat
  -- ^ out: size
  -> Ptr CFloat
  -- ^ out: life fraction
  -> Ptr Word32
  -- ^ out: packed RGBA colour
  -> Ptr CFloat
  -- ^ out: velocity x, or @NULL@
  -> Ptr CFloat
  -- ^ out: velocity y, or @NULL@
  -> Ptr CFloat
  -- ^ out: velocity z, or @NULL@
  -> CInt
  -- ^ capacity of each column, in elements
  -> Ptr CInt
  -- ^ out: batch descriptors, 4 ints per batch
  -> CInt
  -- ^ capacity of @batch_info@, in batches
  -> IO CInt
pm_observe_ex h px py pz psize plife pcolor pvx pvy pvz capacity infoPtr maxBatches =
  firewall pmErrInternal $
    withCell h 0 pmErrArgs $ \ref -> do
      spell <- readIORef ref
      copyOut
        (batches (observeSpell spell))
        px
        py
        pz
        psize
        plife
        pcolor
        pvx
        pvy
        pvz
        capacity
        infoPtr
        maxBatches

-- | The copy-out shared by 'pm_observe' and 'pm_scene_observe' (func-spec
-- 0018 §3.3): a batch list into the host's six columns plus one
-- @batch_info@ record each, with the capacity check run to completion
-- /before/ the first poke — which is what makes the error path
-- all-or-nothing for both entry points at once.
--
-- Lifted out of 'pm_observe' unchanged; @test\/FFIObserveSpec.hs@ and
-- @test\/Acceptance9Spec.hs@ are the regression net for that move.
--
-- Func-spec 0023 widens it to nine columns. The three velocity pointers
-- are optional — @NULL@ means "this host does not want it", independently
-- per axis — and they are deliberately /not/ part of the
-- @columnsMissing@ check: a missing required column is a host bug, a
-- missing optional one is a host choice, and conflating them would make
-- @pm_observe@ (which passes @NULL@ for all three) fail.
copyOut
  :: [RenderBatch]
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr Word32
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> CInt
  -> Ptr CInt
  -> CInt
  -> IO CInt
copyOut bs px py pz psize plife pcolor pvx pvy pvz capacity infoPtr maxBatches = do
  let buffers = map rbParticles bs
      total = sum (map pbCount buffers)
      nBatches = length bs
      columns = [castPtr px, castPtr py, castPtr pz, castPtr psize, castPtr plife, castPtr pcolor] :: [Ptr ()]
      columnsMissing = total > 0 && any (== nullPtr) columns
      infoMissing = nBatches > 0 && infoPtr == nullPtr
  if total > fromIntegral capacity
    || nBatches > fromIntegral maxBatches
    || columnsMissing
    || infoMissing
    then pure pmErrCapacity
    else do
      let writeBatch offset (i, batch) = do
            let pb = rbParticles batch
                n = pbCount pb
            copyFloats px offset (pbPosX pb)
            copyFloats py offset (pbPosY pb)
            copyFloats pz offset (pbPosZ pb)
            copyFloats psize offset (pbSize pb)
            copyFloats plife offset (pbLife pb)
            copyWords pcolor offset (pbColor pb)
            copyVelocity pvx offset n (pbVelX pb)
            copyVelocity pvy offset n (pbVelY pb)
            copyVelocity pvz offset n (pbVelZ pb)
            pokeElemOff infoPtr (4 * i) (fromIntegral offset)
            pokeElemOff infoPtr (4 * i + 1) (fromIntegral n)
            pokeElemOff infoPtr (4 * i + 2) (blendCode (rbBlend batch))
            pokeElemOff infoPtr (4 * i + 3) (shapeCode (rbShape batch))
            pure (offset + n)
      _ <- foldM writeBatch 0 (zip [0 :: Int ..] bs)
      pure (fromIntegral nBatches)

foreign export ccall "pm_hs_free" pm_free :: StablePtr SpellCell -> IO ()

-- | Release a handle. Freeing @NULL@ is a no-op (C convention), and so is
-- freeing anything else that does not resolve — a handle freed twice, or
-- one this library never issued. @void@ leaves no room to report it, so
-- the promise here is the safe half of C2.3: nothing happens, and the host
-- process lives (ADR-022 D3, revising ADR-0011 D4).
pm_free :: StablePtr SpellCell -> IO ()
pm_free h = firewall () (freeSpellHandle h)

-- Scenes (func-spec 0018) ----------------------------------------------------
--
-- Ten entry points that are the item-for-item image of "Magic.Scene"'s
-- export list (§2 of the spec): every one crosses types, calls one frozen
-- boundary function, and crosses back. Nothing decides anything here —
-- admission, the quota arithmetic and the batch order all live in the
-- pure layer, which is what makes @test\/Acceptance18Spec.hs@'s
-- equivalence law provable rather than aspirational.

foreign export ccall "pm_hs_scene_new" pm_scene_new :: CInt -> IO (StablePtr SceneCell)

-- | Open a scene whose live spells may hold @global_cap@ particles in
-- total.
--
-- A negative cap is /not/ rejected: 'newScene' defines it as a scene that
-- admits nothing, and turning a defined behaviour into an argument error
-- here would be a semantic the Haskell path does not have (func-spec 0018
-- §2). Never returns the 'nullScene' handle in this generation.
pm_scene_new :: CInt -> IO (StablePtr SceneCell)
pm_scene_new cap =
  firewall nullScene (newSceneHandle (newScene (SceneConfig (fromIntegral cap))))

foreign export ccall "pm_hs_scene_free" pm_scene_free :: StablePtr SceneCell -> IO ()

-- | Release a scene and, with it, every spell still live inside it.
-- Freeing 'nullScene' is a no-op, and so is freeing a scene handle that
-- does not resolve — already freed, or forged (host-runtime C2.3).
pm_scene_free :: StablePtr SceneCell -> IO ()
pm_scene_free h = firewall () (freeSceneHandle h)

foreign export ccall "pm_hs_scene_cast" pm_scene_cast
  :: StablePtr SceneCell
  -> CString
  -> Ptr CFloat
  -> Ptr CFloat
  -> Word64
  -> CString
  -> CInt
  -> Ptr CInt
  -> IO CInt

-- | Cast one circle into the scene: 'pmOk' with the new
-- 'Magic.Scene.SpellId' written to @out_id@, or one of 'pmErrJson',
-- 'pmErrBudget', 'pmErrQuota' and 'pmErrArgs' with the reason in
-- @err_buf@. Every failure leaves the scene exactly as it was — that is
-- 'castInto''s own promise, kept here by not writing the cell back.
pm_scene_cast
  :: StablePtr SceneCell
  -> CString
  -- ^ circle JSON, NUL-terminated UTF-8
  -> Ptr CFloat
  -- ^ caster position, 3 floats
  -> Ptr CFloat
  -- ^ caster facing, 3 floats
  -> Word64
  -- ^ cast seed
  -> CString
  -- ^ error buffer (may be @NULL@)
  -> CInt
  -- ^ error buffer capacity in bytes, including the NUL
  -> Ptr CInt
  -- ^ out: the admitted spell's id
  -> IO CInt
pm_scene_cast h json posPtr facingPtr sd errBuf errLen outId =
  firewallErr errBuf errLen pmErrInternal $
    withCast h posPtr facingPtr sd errBuf errLen outId $ \ref ctx ->
      if json == nullPtr
        then castFail errBuf errLen pmErrJson "spell JSON error: null pointer"
        else do
          bytes <- BS.packCString json
          case loadCircle bytes of
            Left err -> castFail errBuf errLen pmErrJson (renderLoadError err)
            Right circle ->
              admitInto ref outId errBuf errLen (castInto CastRequest {circleOf = circle, ctxOf = ctx})

foreign export ccall "pm_hs_scene_cast_many" pm_scene_cast_many
  :: StablePtr SceneCell
  -> Ptr CString
  -> CInt
  -> Ptr CFloat
  -> Ptr CFloat
  -> Word64
  -> CString
  -> CInt
  -> Ptr CInt
  -> IO CInt

-- | 'pm_scene_cast' for a composition: @count@ circles compiled into one
-- spell, one id, one share of the quota ('castManyInto', func-spec 0012
-- §5). @count == 0@ casts the empty composition, which is legal and
-- costs nothing.
--
-- The first circle that fails to decode stops the whole cast with
-- 'pmErrJson'; nothing is admitted, since the composition is one spell.
pm_scene_cast_many
  :: StablePtr SceneCell
  -> Ptr CString
  -- ^ @count@ NUL-terminated UTF-8 circle JSONs
  -> CInt
  -- ^ how many
  -> Ptr CFloat
  -> Ptr CFloat
  -> Word64
  -> CString
  -> CInt
  -> Ptr CInt
  -> IO CInt
pm_scene_cast_many h jsons count posPtr facingPtr sd errBuf errLen outId =
  firewallErr errBuf errLen pmErrInternal body
  where
    body
      | count < 0 = castFail errBuf errLen pmErrArgs "scene cast error: negative count"
      | otherwise =
          withCast h posPtr facingPtr sd errBuf errLen outId $ \ref ctx ->
            if count > 0 && jsons == nullPtr
              then castFail errBuf errLen pmErrArgs "scene cast error: null circle array"
              else do
                ptrs <- traverse (peekElemOff jsons) [0 .. fromIntegral count - 1]
                loaded <- loadCircles ptrs
                case loaded of
                  Left msg -> castFail errBuf errLen pmErrJson msg
                  Right circles -> admitInto ref outId errBuf errLen (castManyInto circles ctx)

    -- The composition's circles, or the first decode failure's message.
    loadCircles :: [CString] -> IO (Either String [Circle])
    loadCircles = go id
      where
        go acc [] = pure (Right (acc []))
        go acc (p : ps)
          | p == nullPtr = pure (Left "spell JSON error: null pointer")
          | otherwise = do
              bytes <- BS.packCString p
              case loadCircle bytes of
                Left err -> pure (Left (renderLoadError err))
                Right circle -> go (acc . (circle :)) ps

-- | The argument check and cast-context assembly both scene cast entry
-- points share. @out_id@ is pre-set to @-1@ (never a 'SpellId', which
-- ascends from 0) so a host that ignores the return code still sees that
-- nothing was admitted.
withCast
  :: StablePtr SceneCell
  -> Ptr CFloat
  -> Ptr CFloat
  -> Word64
  -> CString
  -> CInt
  -> Ptr CInt
  -> (IORef Scene -> CastContext -> IO CInt)
  -> IO CInt
withCast h posPtr facingPtr sd errBuf errLen outId k
  | isNullScene h = castFail errBuf errLen pmErrArgs "scene cast error: null scene"
  | outId == nullPtr = castFail errBuf errLen pmErrArgs "scene cast error: null out_id"
  | otherwise =
      -- The handle is resolved /before/ @out_id@ is touched, so an invalid
      -- scene leaves the host's id word exactly as a NULL scene does: not
      -- written at all.
      registryResolve sceneRegistry (castStablePtrToPtr h) >>= \case
        ResNull -> castFail errBuf errLen pmErrArgs "scene cast error: null scene"
        ResInvalid -> castFail errBuf errLen pmErrArgs "scene cast error: invalid scene handle"
        ResLive (SceneCell ref) -> do
          poke outId (-1)
          pos <- peekV3 posPtr
          facing <- peekV3 facingPtr
          k ref CastContext {casterPos = pos, casterFacing = facing, seed = Seed sd}

-- | Commit an admission decision to the cell, or report the refusal.
admitInto
  :: IORef Scene
  -> Ptr CInt
  -> CString
  -> CInt
  -> (Scene -> Either CastRefusal (SpellId, Scene))
  -> IO CInt
admitInto ref outId errBuf errLen admit = do
  scene <- readIORef ref
  case admit scene of
    Left refusal -> castFail errBuf errLen (refusalCode refusal) (refusalMessage refusal)
    Right (SpellId sid, scene') -> do
      writeIORef ref $! scene'
      poke outId (fromIntegral sid)
      pure pmOk

castFail :: CString -> CInt -> CInt -> String -> IO CInt
castFail errBuf errLen code msg = writeErr errBuf errLen msg >> pure code

foreign export ccall "pm_hs_scene_dismiss" pm_scene_dismiss :: StablePtr SceneCell -> CInt -> IO ()

-- | Remove a spell early. An unknown id — stale, already finished, never
-- issued — is a no-op, because 'dismiss' says so and ids are never
-- reused; the C side therefore needs no generation counter.
pm_scene_dismiss :: StablePtr SceneCell -> CInt -> IO ()
pm_scene_dismiss h sid =
  firewall () $
    withScene h () () $ \ref -> do
      scene <- readIORef ref
      writeIORef ref $! dismiss (SpellId (fromIntegral sid)) scene

foreign export ccall "pm_hs_scene_advance" pm_scene_advance :: StablePtr SceneCell -> CFloat -> IO ()

-- | Advance every live spell by @dt@ seconds, in place, dropping the ones
-- that finished — which is also how their share of the quota comes back.
pm_scene_advance :: StablePtr SceneCell -> CFloat -> IO ()
pm_scene_advance h dt =
  firewall () $
    withScene h () () $ \ref -> do
      scene <- readIORef ref
      writeIORef ref $! advanceScene (FrameInput (DeltaTime (cfloatToDouble dt))) scene

foreign export ccall "pm_hs_scene_observe" pm_scene_observe
  :: StablePtr SceneCell
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr Word32
  -> CInt
  -> Ptr CInt
  -> CInt
  -> IO CInt

-- | Sample every live spell into the host's six columns — 'observeScene'
-- through the same 'copyOut' 'pm_observe' uses, so the layout, the
-- capacity rule and the all-or-nothing error path are not merely alike
-- but literally the same code.
--
-- Batches arrive concatenated in 'SpellId' order and are not merged
-- across spells. Which spell a batch came from is not reported: the
-- Haskell path does not know either, and the C side is not allowed to
-- know more (func-spec 0018 §0.3).
pm_scene_observe
  :: StablePtr SceneCell
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr Word32
  -> CInt
  -> Ptr CInt
  -> CInt
  -> IO CInt
pm_scene_observe h px py pz psize plife pcolor capacity infoPtr maxBatches =
  firewall pmErrInternal $
    withScene h 0 pmErrArgs $ \ref -> do
      scene <- readIORef ref
      -- No velocity out of the scene entry point this round: func-spec 0023
      -- widens the single-spell path only, so this passes the three @NULL@s
      -- that make 'copyOut' behave exactly as it did before (the scene
      -- counterpart is booked, not delivered — func-spec 0023 §10).
      copyOut
        (batches (observeScene scene))
        px
        py
        pz
        psize
        plife
        pcolor
        nullPtr
        nullPtr
        nullPtr
        capacity
        infoPtr
        maxBatches

foreign export ccall "pm_hs_scene_budget" pm_scene_budget
  :: StablePtr SceneCell -> Ptr CInt -> Ptr CInt -> IO CInt

-- | @(particles committed by the live spells, the scene's cap)@ —
-- 'sceneBudget' verbatim. Either out pointer may be @NULL@ for a host
-- that only wants the other one.
pm_scene_budget :: StablePtr SceneCell -> Ptr CInt -> Ptr CInt -> IO CInt
pm_scene_budget h outUsed outCap =
  firewall pmErrInternal $
    withScene h pmErrArgs pmErrArgs $ \ref -> do
      (used, cap) <- sceneBudget <$> readIORef ref
      when (outUsed /= nullPtr) (poke outUsed (fromIntegral used))
      when (outCap /= nullPtr) (poke outCap (fromIntegral cap))
      pure pmOk

foreign export ccall "pm_hs_scene_count" pm_scene_count :: StablePtr SceneCell -> IO CInt

-- | How many spells are live — the capacity 'pm_scene_spells' wants.
pm_scene_count :: StablePtr SceneCell -> IO CInt
pm_scene_count h =
  firewall pmErrInternal $
    withScene h 0 pmErrArgs $ \ref -> fromIntegral . length . sceneSpells <$> readIORef ref

foreign export ccall "pm_hs_scene_spells" pm_scene_spells :: StablePtr SceneCell -> Ptr CInt -> CInt -> IO CInt

-- | The live spells' ids in admission order. Returns how many were
-- written, or 'pmErrCapacity' with __nothing written at all__ when they
-- do not fit — the same all-or-nothing rule 'pm_observe' follows.
pm_scene_spells :: StablePtr SceneCell -> Ptr CInt -> CInt -> IO CInt
pm_scene_spells h outIds maxIds =
  firewall pmErrInternal $
    withScene h 0 pmErrArgs $ \ref -> do
      ids <- sceneSpells <$> readIORef ref
      let n = length ids
      if n > fromIntegral maxIds || (n > 0 && outIds == nullPtr)
        then pure pmErrCapacity
        else do
          mapM_
            (\(i, SpellId sid) -> pokeElemOff outIds i (fromIntegral sid))
            (zip [0 ..] ids)
          pure (fromIntegral n)

-- Spatial summary (func-spec 0025) -------------------------------------------
--
-- Seven entry points that carry the system's third output across the ABI:
-- where a spell is. Same rules as everything above — one frozen boundary
-- function each, a type crossing, and no decision taken here
-- (@test\/FFISpaceSpec.hs@ states that as an equivalence). Read-only in
-- the strongest sense: none of them advances a clock or writes a cell
-- back, so a host may call them between @pm_advance@ and @pm_observe@
-- without changing one particle.

foreign export ccall "pm_hs_spell_bounds" pm_spell_bounds
  :: StablePtr SpellCell -> Ptr CFloat -> Ptr CFloat -> IO CInt

-- | The whole spell's world axis-aligned box over its entire life, as two
-- corners. 'pmOk', or 'pmErrArgs' (@NULL@ handle or @NULL@ output) with
-- nothing written.
pm_spell_bounds :: StablePtr SpellCell -> Ptr CFloat -> Ptr CFloat -> IO CInt
pm_spell_bounds h outMin outMax = firewall pmErrInternal body
  where
    body
      | outMin == nullPtr || outMax == nullPtr = pure pmErrArgs
      | otherwise =
          withCell h pmErrArgs pmErrArgs $ \ref -> do
            spell <- readIORef ref
            let (lo, hi) = spellBoundsOf spell
            pokeV3 outMin lo
            pokeV3 outMax hi
            pure pmOk

foreign export ccall "pm_hs_spell_box" pm_spell_box
  :: StablePtr SpellCell -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> IO CInt

-- | The whole spell as an oriented box over its entire life: center,
-- three unit axes (3×3, row major — U, then V, then the normal) and three
-- half-extents. This is also the frame 'pm_occupancy' divides up, and it
-- does not change while the spell runs (func-spec 0025 §2.7).
pm_spell_box
  :: StablePtr SpellCell
  -> Ptr CFloat
  -- ^ out: center, 3 floats
  -> Ptr CFloat
  -- ^ out: axes, 9 floats
  -> Ptr CFloat
  -- ^ out: half-extents, 3 floats
  -> IO CInt
pm_spell_box h outCenter outAxes outHalf =
  firewall pmErrInternal $
    withCell h pmErrArgs pmErrArgs $ \ref -> do
      spell <- readIORef ref
      writeBox (spellBoxOf spell) outCenter outAxes outHalf

foreign export ccall "pm_hs_emitter_count" pm_emitter_count :: StablePtr SpellCell -> IO CInt

-- | How many emitters this spell compiled to — the index range
-- 'pm_emitter_box' accepts. 0 for a @NULL@ handle.
pm_emitter_count :: StablePtr SpellCell -> IO CInt
pm_emitter_count h =
  firewall pmErrInternal $
    withCell h 0 pmErrArgs $ \ref -> fromIntegral . length . emittersOf <$> readIORef ref

foreign export ccall "pm_hs_emitter_box" pm_emitter_box
  :: StablePtr SpellCell -> CInt -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> IO CInt

-- | One emitter's fitted oriented box at the cast's current age, in the
-- same layout as 'pm_spell_box'. An index outside
-- @[0, pm_emitter_count)@ is 'pmErrArgs' with nothing written.
pm_emitter_box
  :: StablePtr SpellCell
  -> CInt
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> IO CInt
pm_emitter_box h index outCenter outAxes outHalf =
  firewall pmErrInternal $
    withCell h pmErrArgs pmErrArgs $ \ref -> do
      spell <- readIORef ref
      let ems = emittersOf spell
          i = fromIntegral index :: Int
      if i < 0 || i >= length ems
        then pure pmErrArgs
        else writeBox (emitterBoxOf spell (ems !! i)) outCenter outAxes outHalf

-- | The copy-out shared by the two box entry points: nothing is written
-- until every output pointer has been checked, so the error path leaves
-- the host's arrays untouched — the same all-or-nothing rule
-- 'pm_observe' follows.
writeBox :: OrientedBox -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> IO CInt
writeBox box outCenter outAxes outHalf
  | outCenter == nullPtr || outAxes == nullPtr || outHalf == nullPtr = pure pmErrArgs
  | otherwise = do
      pokeV3 outCenter (obCenter box)
      pokeV3 outAxes (obAxisU box)
      pokeV3 (advanceFloats outAxes 3) (obAxisV box)
      pokeV3 (advanceFloats outAxes 6) (obAxisN box)
      pokeV3 outHalf (V3 (obHalfU box) (obHalfV box) (obHalfN box))
      pure pmOk

foreign export ccall "pm_hs_occupancy" pm_occupancy
  :: StablePtr SpellCell -> CInt -> Ptr CInt -> CInt -> IO CInt

-- | @dim³@ occupancy counts of the spell's currently live particles, in
-- the fixed 'pm_spell_box' frame; cell @(k*dim + j)*dim + i@ counts the
-- particles whose position falls in it, with @i@ along the box's U axis,
-- @j@ along V and @k@ along the normal.
--
-- Returns the number of cells written, 'pmErrArgs' for a non-positive
-- @dim@ or a @NULL@ handle, or 'pmErrCapacity' when @capacity < dim³@ —
-- in which case __nothing is written at all__.
pm_occupancy :: StablePtr SpellCell -> CInt -> Ptr CInt -> CInt -> IO CInt
pm_occupancy h dim outCounts capacity = firewall pmErrInternal body
  where
    body
      | dim <= 0 = pure pmErrArgs
      | otherwise =
          withCell h pmErrArgs pmErrArgs $ \ref -> do
            let n = fromIntegral dim :: Int
                cells = n * n * n
            if cells > fromIntegral capacity || outCounts == nullPtr
              then pure pmErrCapacity
              else do
                spell <- readIORef ref
                let counts = ogCounts (occupancyOf n spell)
                U.imapM_ (\i c -> pokeElemOff outCounts i (fromIntegral c)) counts
                pure (fromIntegral cells)

foreign export ccall "pm_hs_occupancy_mask" pm_occupancy_mask :: StablePtr SpellCell -> IO Word32

-- | The @PM_OCCUPANCY_DIM_DEFAULT@ fast path: bit @c@ is set when cell
-- @c@ of a @3³@ 'pm_occupancy' would be non-zero. 0 for a @NULL@ handle,
-- which is also what an empty spell answers — "nothing anywhere" is the
-- honest reading of both.
pm_occupancy_mask :: StablePtr SpellCell -> IO Word32
-- The firewall's sentinel here is 0 as well: there is no negative
-- @uint32_t@ to spend, and "nothing anywhere" is the fail-safe answer for
-- an overlap test — it under-claims rather than over-claims.
pm_occupancy_mask h =
  firewall 0 $ withCell h 0 0 $ \ref -> occupancyMask <$> readIORef ref

foreign export ccall "pm_hs_scene_spell_bounds" pm_scene_spell_bounds
  :: StablePtr SceneCell -> CInt -> Ptr CFloat -> Ptr CFloat -> IO CInt

-- | 'pm_spell_bounds' for one spell inside a scene: 'pm_scene_spells'
-- hands out the ids, this hands out the boxes. An unknown id — stale,
-- finished, never issued — is 'pmErrArgs' with nothing written.
--
-- There is deliberately no whole-scene union (func-spec 0025 §7-10):
-- folding these is three lines in the host, and a scene-wide box is a
-- number almost nothing can use.
pm_scene_spell_bounds
  :: StablePtr SceneCell -> CInt -> Ptr CFloat -> Ptr CFloat -> IO CInt
pm_scene_spell_bounds h sid outMin outMax = firewall pmErrInternal body
  where
    body
      | outMin == nullPtr || outMax == nullPtr = pure pmErrArgs
      | otherwise =
          withScene h pmErrArgs pmErrArgs $ \ref -> do
            scene <- readIORef ref
            case lookupSpell (SpellId (fromIntegral sid)) scene of
              Nothing -> pure pmErrArgs
              Just spell -> do
                let (lo, hi) = spellBoundsOf spell
                pokeV3 outMin lo
                pokeV3 outMax hi
                pure pmOk

-- Projection (func-spec 0011 §3) ---------------------------------------------
--
-- Two entry points that take no handle at all: projection is a function of
-- positions, not of spell state, so a host may feed them any columns it
-- has — @pm_observe@'s output, a subrange of it, or its own particles.
-- Both are 'Magic.Projection' called through a type crossing and nothing
-- more (the zero-new-semantics rule; @test\/FFIProjectSpec.hs@ states it
-- as an equivalence).

foreign export ccall "pm_hs_project" pm_project
  :: CInt
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> CInt
  -> Ptr CFloat
  -> Ptr CFloat
  -> Ptr CFloat
  -> IO CInt

-- | Orthographic projection of @count@ abstract-space positions onto the
-- chosen 'ViewPlane' (ADR-0008): plane coordinates into @out_x@ \/
-- @out_y@, the painter's depth into @out_depth@ (larger = further away).
--
-- Returns 'pmOk', or 'pmErrArgs' with __nothing written at all__ — the
-- argument check runs to completion before the first poke, as in
-- 'pm_observe'.
--
-- Aliasing an input column onto an output column is safe for @out_x@ (the
-- read of element @i@ precedes its write), and is /not/ safe in general;
-- hosts should hand over distinct arrays.
pm_project
  :: CInt
  -- ^ 'pmPlaneSideXY' or 'pmPlaneTopXZ'
  -> Ptr CFloat
  -- ^ position x
  -> Ptr CFloat
  -- ^ position y
  -> Ptr CFloat
  -- ^ position z
  -> CInt
  -- ^ number of positions
  -> Ptr CFloat
  -- ^ out: plane u
  -> Ptr CFloat
  -- ^ out: plane v
  -> Ptr CFloat
  -- ^ out: depth
  -> IO CInt
pm_project plane inX inY inZ count outU outV outDepth =
  firewall pmErrInternal $
    withColumns plane count [inX, inY, inZ, outU, outV, outDepth] $ \viewPlane n ->
      let go i
            | i >= n = pure pmOk
            | otherwise = do
                x <- peekFloat inX i
                y <- peekFloat inY i
                z <- peekFloat inZ i
                let (V2 u v, depth) = orthographic viewPlane (V3 x y z)
                pokeFloat outU i u
                pokeFloat outV i v
                pokeFloat outDepth i depth
                go (i + 1)
       in go 0

foreign export ccall "pm_hs_depth_order" pm_depth_order
  :: CInt -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> CInt -> Ptr CInt -> IO CInt

-- | The painter's permutation for @count@ positions: the indices
-- @[0 .. count-1]@ ordered far to near, equal depths keeping their input
-- order. Draw the particles in this order and nearer ones land on top
-- without a depth buffer.
--
-- Only the position columns matter to 'depthOrder', so the buffer it
-- sorts is completed with zero size\/life\/colour columns — a padding
-- that provably cannot reach the result (@test\/FFIProjectSpec.hs@).
--
-- Returns 'pmOk', or 'pmErrArgs' with nothing written.
pm_depth_order
  :: CInt
  -- ^ 'pmPlaneSideXY' or 'pmPlaneTopXZ'
  -> Ptr CFloat
  -- ^ position x
  -> Ptr CFloat
  -- ^ position y
  -> Ptr CFloat
  -- ^ position z
  -> CInt
  -- ^ number of positions
  -> Ptr CInt
  -- ^ out: @count@ indices, far to near
  -> IO CInt
pm_depth_order plane inX inY inZ count outIndices =
  firewall pmErrInternal $
    withColumns plane count [inX, inY, inZ, castPtr outIndices] $ \viewPlane n -> do
      xs <- readFloats inX n
      ys <- readFloats inY n
      zs <- readFloats inZ n
      let blank = U.replicate n 0
      case fromColumns xs ys zs blank blank (U.replicate n 0) of
        -- Unreachable: the six columns are built to one length. Reported
        -- rather than thrown, because an exception crossing back into C
        -- used to be undefined behaviour — since host-runtime F001 it is
        -- PM_ERR_INTERNAL, but reporting a value the caller can classify
        -- is still the better answer.
        Left _ -> pure pmErrArgs
        Right pb -> do
          U.imapM_ (\i j -> pokeElemOff outIndices i (fromIntegral j)) (depthOrder viewPlane pb)
          pure pmOk

-- | The shared argument check of the two array entry points: decode the
-- plane, reject a negative length, and — only when there is an element to
-- touch — reject a @NULL@ among the columns. @NULL@ with @count == 0@ is
-- accepted, matching 'pm_observe', where a host with nothing to draw need
-- not own arrays at all.
--
-- Nothing is written before the continuation runs, which is what makes
-- the error path all-or-nothing.
withColumns :: CInt -> CInt -> [Ptr a] -> (ViewPlane -> Int -> IO CInt) -> IO CInt
withColumns plane count ptrs k =
  case planeOf plane of
    Nothing -> pure pmErrArgs
    Just viewPlane
      | count < 0 -> pure pmErrArgs
      | n > 0 && any (== nullPtr) ptrs -> pure pmErrArgs
      | otherwise -> k viewPlane n
      where
        n = fromIntegral count

-- Marshalling helpers --------------------------------------------------------

-- | @CFloat@ and @Float@ share their representation, so the columns are
-- poked through a cast pointer: exact for every bit pattern, NaN and
-- infinities included (@realToFrac@ is not).
copyFloats :: Ptr CFloat -> Int -> U.Vector Float -> IO ()
copyFloats ptr offset = U.imapM_ (\i x -> pokeElemOff (castPtr ptr) (offset + i) x)

-- | One optional velocity column of one batch (func-spec 0023 S4).
--
-- Three cases, and the third is the one worth naming: a @NULL@ pointer
-- writes nothing, a present column copies, and an /absent/ column with a
-- present pointer writes @n@ zeros. That last one is why the host's
-- arrays are always fully defined over @[0, total)@ after a successful
-- call — a host that reads velocity for a batch of a trail-free spell
-- gets zero, not whatever was in its buffer last frame.
copyVelocity :: Ptr CFloat -> Int -> Int -> U.Vector Float -> IO ()
copyVelocity ptr offset n column
  | ptr == nullPtr = pure ()
  | U.null column = mapM_ (\i -> pokeElemOff (castPtr ptr) (offset + i) (0 :: Float)) [0 .. n - 1]
  | otherwise = copyFloats ptr offset column

copyWords :: Ptr Word32 -> Int -> U.Vector Word32 -> IO ()
copyWords ptr offset = U.imapM_ (\i x -> pokeElemOff ptr (offset + i) x)

-- | Element access through the same cast pointer 'copyFloats' uses, for
-- the same reason: @CFloat@ and @Float@ share a representation, so every
-- bit pattern survives the crossing untouched.
peekFloat :: Ptr CFloat -> Int -> IO Float
peekFloat ptr = peekElemOff (castPtr ptr)

pokeFloat :: Ptr CFloat -> Int -> Float -> IO ()
pokeFloat ptr = pokeElemOff (castPtr ptr)

-- | A host column read into the unboxed vector the core works in.
readFloats :: Ptr CFloat -> Int -> IO (U.Vector Float)
readFloats ptr n = U.generateM n (peekFloat ptr)

-- | A @NULL@ vector reads as the origin, so a host may pass @NULL@ for a
-- cast at the world origin facing +Z.
peekV3 :: Ptr CFloat -> IO V3
peekV3 p
  | p == nullPtr = pure (V3 0 0 0)
  | otherwise = do
      let q = castPtr p :: Ptr Float
      x <- peekByteOff q 0
      y <- peekByteOff q 4
      z <- peekByteOff q 8
      pure (V3 x y z)

-- | Three floats into a host-owned array, through the same cast pointer
-- 'copyFloats' uses and for the same reason: @CFloat@ and @Float@ share a
-- representation, so every bit pattern (infinities included — an
-- unbounded formula's box legitimately has them) survives the crossing.
pokeV3 :: Ptr CFloat -> V3 -> IO ()
pokeV3 p (V3 x y z) = do
  pokeFloat p 0 x
  pokeFloat p 1 y
  pokeFloat p 2 z

-- | The same array, @n@ elements along.
advanceFloats :: Ptr CFloat -> Int -> Ptr CFloat
advanceFloats p n = castPtr (plusPtr (castPtr p :: Ptr Float) (n * 4))

-- | Widening a host's @float@ dt to the core's @Double@ clock. Exact for
-- every finite value (and for NaN\/infinities, which @realToFrac@ would
-- mangle) because it unwraps the newtype instead of going through
-- 'Rational'.
cfloatToDouble :: CFloat -> Double
cfloatToDouble (CFloat f) = float2Double f

-- | Write a message into a caller-owned buffer as NUL-terminated UTF-8.
--
-- Truncation safe in three senses, all property-tested in
-- @test\/FFIErrorSpec.hs@: at most @len@ bytes are ever touched, the
-- result is always NUL-terminated when @len > 0@, and the kept prefix
-- never ends inside a multi-byte sequence (the tail is backed off to a
-- character boundary), so the host always decodes valid UTF-8.
writeErr :: CString -> CInt -> String -> IO ()
writeErr buf len msg
  | buf == nullPtr || len <= 0 = pure ()
  | otherwise = GHCF.withCStringLen utf8 msg $ \(src, n) -> do
      let room = fromIntegral len - 1
      keep <-
        if n <= room
          then pure n
          else charBoundaryBefore src room
      copyBytes buf src keep
      pokeByteOff buf keep (0 :: CChar)

-- | Largest @k ≤ i@ such that byte @k@ of the UTF-8 sequence starts a
-- character (i.e. is not a @10xxxxxx@ continuation byte).
charBoundaryBefore :: Ptr CChar -> Int -> IO Int
charBoundaryBefore src = go
  where
    go i
      | i <= 0 = pure 0
      | otherwise = do
          b <- peekByteOff src i :: IO Word8
          if b >= 0x80 && b < 0xC0 then go (i - 1) else pure i
