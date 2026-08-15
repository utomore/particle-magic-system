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
--   * __Handle = 'StablePtr' over an 'IORef'__ (ADR-0011 D4). 'advanceSpell'
--     is pure, hosts want in-place advance, so the handle points at a cell
--     that @pm_advance@ reads-computes-writes back. One handle is owned by
--     one thread; there is no internal lock in v1.
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
  , pm_free
  , pm_max_particles
  , pm_project
  , pm_depth_order

    -- * Contract constants (mirrored in @include\/particle_magic.h@,
    -- guarded by @test\/FFIContractSpec.hs@)
  , pmAbiVersion
  , pmMaxParticles
  , pmOk
  , pmErrJson
  , pmErrBudget
  , pmErrCapacity
  , pmErrArgs
  , pmPlaneSideXY
  , pmPlaneTopXZ
  , blendCode
  , shapeCode
  , planeOf

    -- * Internals (not part of the C contract; exposed for testing)
  , SpellCell (..)
  , nullSpell
  , isNullSpell
  , writeErr
  ) where

import Control.Monad (foldM)
import qualified Data.ByteString as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word64, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CDouble (..), CFloat (..), CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.StablePtr
  ( StablePtr
  , castPtrToStablePtr
  , castStablePtrToPtr
  , deRefStablePtr
  , freeStablePtr
  , newStablePtr
  )
import Foreign.Storable (peek, peekByteOff, peekElemOff, poke, pokeByteOff, pokeElemOff)
import GHC.Float (float2Double)
import qualified GHC.Foreign as GHCF
import GHC.IO.Encoding (utf8)
import Magic.Codec (loadCircle, renderLoadError)
import Magic.Columns (fromColumns)
import Magic.Interface
  ( ActiveSpell
  , BillboardShape
  , BlendMode (..)
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (batches)
  , ParticleBuffer (pbColor, pbCount, pbLife, pbPosX, pbPosY, pbPosZ, pbSize)
  , RenderBatch (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , isFinished
  , observeSpell
  , spellAge
  )
import Magic.Projection (V2 (..), ViewPlane (..), depthOrder, orthographic)

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

pmOk, pmErrJson, pmErrBudget, pmErrCapacity, pmErrArgs :: CInt
pmOk = 0
pmErrJson = -1
pmErrBudget = -2
pmErrCapacity = -3

-- | A @NULL@ pointer where one is needed, a negative length, or a plane
-- selector that is neither 'pmPlaneSideXY' nor 'pmPlaneTopXZ' (func-spec
-- 0011 §3). Only the array entry points can return it.
pmErrArgs = -4

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
-- @pm_cast@'s result gets a quiet failure rather than a crash. Any /other/
-- invalid handle (freed, forged) is undefined behaviour, as in any C API.
nullSpell :: StablePtr SpellCell
nullSpell = castPtrToStablePtr nullPtr

isNullSpell :: StablePtr SpellCell -> Bool
isNullSpell h = castStablePtrToPtr h == nullPtr

withCell :: StablePtr SpellCell -> b -> (IORef ActiveSpell -> IO b) -> IO b
withCell h fallback k
  | isNullSpell h = pure fallback
  | otherwise = do
      SpellCell ref <- deRefStablePtr h
      k ref

-- Entry points ---------------------------------------------------------------

foreign export ccall pm_abi_version :: IO CInt

pm_abi_version :: IO CInt
pm_abi_version = pure pmAbiVersion

foreign export ccall pm_max_particles :: IO CInt

-- | The particle cap this build of the core actually enforces — the
-- capacity each of @pm_observe@'s six columns needs.
--
-- Today it answers @PM_MAX_PARTICLES@ (4096). The header constant is
-- frozen at that value; this query is not, so a host that allocates from
-- it survives a future cap rise without recompiling against a new header
-- (func-spec 0011 §2, roadmap §4.2).
pm_max_particles :: IO CInt
pm_max_particles = pure pmMaxParticles

foreign export ccall pm_cast
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
  alloca $ \out -> do
    poke out nullSpell
    _ <- pm_cast_ex json posPtr facingPtr sd errBuf errLen out
    peek out

foreign export ccall pm_cast_ex
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
pm_cast_ex json posPtr facingPtr sd errBuf errLen out = do
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
              handle <- newStablePtr . SpellCell =<< newIORef spell
              writeOut handle
              pure pmOk
  where
    writeOut h = if out == nullPtr then pure () else poke out h
    fail' code msg = writeErr errBuf errLen msg >> pure code

foreign export ccall pm_advance :: StablePtr SpellCell -> CFloat -> IO ()

-- | Advance the spell's clock by @dt@ seconds, in place.
pm_advance :: StablePtr SpellCell -> CFloat -> IO ()
pm_advance h dt =
  withCell h () $ \ref -> do
    spell <- readIORef ref
    writeIORef ref $! advanceSpell (FrameInput (DeltaTime (cfloatToDouble dt))) spell

foreign export ccall pm_is_finished :: StablePtr SpellCell -> IO CInt

-- | 1 when the spell has outlived its lifetime, 0 while it is running.
-- A @NULL@ handle reports 1 — nothing left to run.
pm_is_finished :: StablePtr SpellCell -> IO CInt
pm_is_finished h =
  withCell h 1 $ \ref -> do
    spell <- readIORef ref
    pure (if isFinished spell then 1 else 0)

foreign export ccall pm_age :: StablePtr SpellCell -> IO CDouble

-- | Seconds since this spell was cast.
pm_age :: StablePtr SpellCell -> IO CDouble
pm_age h =
  withCell h 0 $ \ref -> do
    spell <- readIORef ref
    let Time t = spellAge spell
    pure (CDouble t)

foreign export ccall pm_observe
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
  withCell h 0 $ \ref -> do
    spell <- readIORef ref
    let bs = batches (observeSpell spell)
        buffers = map rbParticles bs
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
              pokeElemOff infoPtr (4 * i) (fromIntegral offset)
              pokeElemOff infoPtr (4 * i + 1) (fromIntegral n)
              pokeElemOff infoPtr (4 * i + 2) (blendCode (rbBlend batch))
              pokeElemOff infoPtr (4 * i + 3) (shapeCode (rbShape batch))
              pure (offset + n)
        _ <- foldM writeBatch 0 (zip [0 :: Int ..] bs)
        pure (fromIntegral nBatches)

foreign export ccall pm_free :: StablePtr SpellCell -> IO ()

-- | Release a handle. Freeing @NULL@ is a no-op (C convention); freeing
-- twice is undefined behaviour (ADR-0011 D4).
pm_free :: StablePtr SpellCell -> IO ()
pm_free h
  | isNullSpell h = pure ()
  | otherwise = freeStablePtr h

-- Projection (func-spec 0011 §3) ---------------------------------------------
--
-- Two entry points that take no handle at all: projection is a function of
-- positions, not of spell state, so a host may feed them any columns it
-- has — @pm_observe@'s output, a subrange of it, or its own particles.
-- Both are 'Magic.Projection' called through a type crossing and nothing
-- more (the zero-new-semantics rule; @test\/FFIProjectSpec.hs@ states it
-- as an equivalence).

foreign export ccall pm_project
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

foreign export ccall pm_depth_order
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
  withColumns plane count [inX, inY, inZ, castPtr outIndices] $ \viewPlane n -> do
    xs <- readFloats inX n
    ys <- readFloats inY n
    zs <- readFloats inZ n
    let blank = U.replicate n 0
    case fromColumns xs ys zs blank blank (U.replicate n 0) of
      -- Unreachable: the six columns are built to one length. Reported
      -- rather than thrown, because an exception crossing back into C is
      -- undefined behaviour.
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
