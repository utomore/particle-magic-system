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

    -- * Contract constants (mirrored in @include\/particle_magic.h@,
    -- guarded by @test\/FFIContractSpec.hs@)
  , pmAbiVersion
  , pmMaxParticles
  , pmOk
  , pmErrJson
  , pmErrBudget
  , pmErrCapacity
  , blendCode
  , shapeCode

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
import Foreign.Storable (peek, peekByteOff, poke, pokeByteOff, pokeElemOff)
import GHC.Float (float2Double)
import qualified GHC.Foreign as GHCF
import GHC.IO.Encoding (utf8)
import Magic.Codec (loadCircle, renderLoadError)
import Magic.Interface
  ( ActiveSpell
  , BillboardShape (..)
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

-- Contract constants ---------------------------------------------------------

-- | Bumped only by an ABI-breaking change; hosts check it at startup.
pmAbiVersion :: CInt
pmAbiVersion = 1

-- | Mirror of the core's @budgetCap@ — the third copy of that constant
-- (core, the demo's @gpuCapacity@, this header). ADR-0011 books the
-- synchronisation duty on the future throughput spec;
-- @test\/FFIContractSpec.hs@ ties all three together so the drift is
-- caught in CI, not in a host's memory corruption.
pmMaxParticles :: CInt
pmMaxParticles = 4096

pmOk, pmErrJson, pmErrBudget, pmErrCapacity :: CInt
pmOk = 0
pmErrJson = -1
pmErrBudget = -2
pmErrCapacity = -3

-- | Wire codes for 'BlendMode', declaration order of the core's
-- constructors (guarded by @test\/FFIContractSpec.hs@).
blendCode :: BlendMode -> CInt
blendCode = \case
  BlendAlpha -> 0
  BlendAdditive -> 1

-- | Wire codes for 'BillboardShape', declaration order.
shapeCode :: BillboardShape -> CInt
shapeCode = \case
  BillboardSquare -> 0

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

-- Marshalling helpers --------------------------------------------------------

-- | @CFloat@ and @Float@ share their representation, so the columns are
-- poked through a cast pointer: exact for every bit pattern, NaN and
-- infinities included (@realToFrac@ is not).
copyFloats :: Ptr CFloat -> Int -> U.Vector Float -> IO ()
copyFloats ptr offset = U.imapM_ (\i x -> pokeElemOff (castPtr ptr) (offset + i) x)

copyWords :: Ptr Word32 -> Int -> U.Vector Word32 -> IO ()
copyWords ptr offset = U.imapM_ (\i x -> pokeElemOff ptr (offset + i) x)

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
