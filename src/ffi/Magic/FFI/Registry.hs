{-# LANGUAGE LambdaCase #-}

-- | Generation-tagged handle registry (subsystem @host-runtime@ F002,
-- ADR-022 D3, Level 2 contract C2.3).
--
-- A @PmSpell*@ / @PmScene*@ used to /be/ a 'Foreign.StablePtr.StablePtr'
-- into the RTS stable pointer table, which made a freed or forged handle
-- undefined behaviour: @deRefStablePtr@ on a released entry can read
-- anything, and @freeStablePtr@ twice corrupts the table. Both kill the
-- host process, and the subsystem's first acceptance criterion is that the
-- library never does that.
--
-- So the handle stops being a pointer at all. Its /value/ encodes
--
-- > bit 0        synthetic bit, always 1  (never 0, never aligned)
-- > bit 1        kind: 0 = spell, 1 = scene
-- > bits 2..h-1  slot index
-- > bits h..w-1  generation, from 1, +1 on every release
--
-- where @w@ is the machine word width and @h = w \/ 2@ (so 1\/1\/30\/32 on
-- every shipping platform). Two module-level tables map the slot index
-- back to the cell; a generation that does not match the slot's is a
-- handle that has been freed, and anything that fails the cheap word
-- checks was never issued by this library.
--
-- Two consequences worth naming:
--
--   * The word is always __odd__, so it can never be a NULL pointer and
--     never an aligned heap address — a host that dereferences it anyway
--     faults loudly in its own process instead of quietly reading someone
--     else's object.
--   * Slot indices are recycled but handle /values/ never repeat: a reused
--     slot always carries the incremented generation. That pins the table
--     size to the peak number of live handles rather than to the number of
--     casts a session ever made.
--
-- __Concurrency__ (host-runtime F004, C2.2): 'registryResolve' is
-- read-only — one 'readIORef' and one vector read, no lock, which is what
-- keeps the per-frame path free of synchronisation. Every mutation is
-- confined to 'registryInsert' and 'registryRelease', and those two hold
-- the table's own 'MVar' for their duration, so two threads casting or
-- freeing at once cannot lose a slot, hand the same slot to both, or leave
-- @tLive@ short. No call site changed to get that: the lock lives inside
-- the 'Registry' value, one per table, so the spell table and the scene
-- table never wait on each other.
--
-- The lock is deliberately /not/ the top-level 'IORef' turned into an
-- 'MVar'. Resolution runs on every @pm_advance@ and every @pm_observe@;
-- making it take and put an 'MVar' would put a lock on the per-frame path
-- and let a cast block a frame, which is exactly what C2.2 forbids.
--
-- Two consequences a host has to know, both documented in the header's
-- thread-model section. A resolver reading the table without a lock has no
-- memory barrier, so handing a fresh handle to another thread needs the
-- host's own synchronisation (a queue, a lock, a job dependency — any real
-- primitive carries the barrier). And a resolver that read the table just
-- before an 'ensureRoom' sees the pre-growth vector: correct for every
-- slot that already existed, and the only slots it cannot see are ones
-- whose handles it could not legally have yet.
module Magic.FFI.Registry
  ( -- * The tables
    Registry
  , HandleKind (..)
  , Resolved (..)
  , newRegistry
  , registryInsert
  , registryRelease
  , registryResolve
  , registryStats

    -- * The handle word (pure; the specs drive it directly)
  , Decoded (..)
  , encodeHandle
  , decodeHandle
  , handleWordBits
  , handleSlotBits
  , handleSlotLimit
  , handleGenerationLimit
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.Bits (finiteBitSize, shiftL, shiftR, (.&.), (.|.))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Vector.Mutable as MV
import Foreign.Ptr (Ptr, ptrToWordPtr, wordPtrToPtr)

-- | Which of the two tables a handle belongs to. The kind travels inside
-- the handle word, so handing a @PmScene*@ to @pm_free@ is caught as a
-- forgery rather than resolved against the wrong table.
data HandleKind = KindSpell | KindScene
  deriving (Eq, Show)

kindBit :: HandleKind -> Word
kindBit KindSpell = 0
kindBit KindScene = 1

-- Word layout ----------------------------------------------------------------

-- | Machine word width. The layout is expressed in halves of it rather
-- than as literal 30\/32 so that a 32-bit build compiles to 14\/16 instead
-- of silently truncating (32-bit is not a shipping platform).
handleWordBits :: Int
handleWordBits = finiteBitSize (0 :: Word)

handleHalfBits :: Int
handleHalfBits = handleWordBits `div` 2

-- | Bits available to the slot index: the low half, less the synthetic and
-- kind bits.
handleSlotBits :: Int
handleSlotBits = handleHalfBits - 2

-- | One past the largest representable slot index.
handleSlotLimit :: Int
handleSlotLimit = 1 `shiftL` handleSlotBits

-- | One past the largest representable generation. Reaching it retires the
-- slot for good (see 'registryRelease').
handleGenerationLimit :: Word
handleGenerationLimit = 1 `shiftL` (handleWordBits - handleHalfBits)

slotMask :: Word
slotMask = fromIntegral handleSlotLimit - 1

generationMask :: Word
generationMask = handleGenerationLimit - 1

-- | What a handle word decoded to.
data Decoded
  = -- | The word is zero: the NULL handle, whose per-symbol behaviour is
    -- frozen in the header and is /not/ this module's business.
    DecNull
  | -- | Never issued by this library: even word, wrong kind, or an index
    -- past everything ever allocated.
    DecForged
  | -- | Structurally sound; the table still has to agree about the
    -- generation.
    DecSlot !Int !Word
  deriving (Eq, Show)

-- | Pack a handle word. The slot and generation are masked into their
-- fields, which only matters for the specs' deliberately out-of-range
-- inputs — 'registryInsert' never offers one.
encodeHandle :: HandleKind -> Int -> Word -> Word
encodeHandle kind slot gen =
  1
    .|. (kindBit kind `shiftL` 1)
    .|. ((fromIntegral slot .&. slotMask) `shiftL` 2)
    .|. ((gen .&. generationMask) `shiftL` handleHalfBits)

-- | Unpack a handle word, given the kind the caller expects. Steps 1–3 of
-- the resolution ladder (C2.3): pure word arithmetic, no allocation, no
-- table access.
decodeHandle :: HandleKind -> Word -> Decoded
decodeHandle kind w
  | w == 0 = DecNull
  | w .&. 1 == 0 = DecForged
  | (w `shiftR` 1) .&. 1 /= kindBit kind = DecForged
  | otherwise =
      DecSlot
        (fromIntegral ((w `shiftR` 2) .&. slotMask))
        ((w `shiftR` handleHalfBits) .&. generationMask)

-- The table ------------------------------------------------------------------

-- | A slot either holds a live cell under its generation, or is vacant and
-- carries the generation the /next/ occupant will be issued.
data Slot a
  = Vacant !Word
  | Occupied !Word a

-- | The mutable half of a registry. Boxed vector because the elements are
-- boxed cells; @vector@ is already on the foreign library's dependency
-- whitelist, and @IntMap@ would both break that whitelist and cost
-- @O(log n)@ where the contract asks for one lookup.
data Table a = Table
  { tSlots :: !(MV.IOVector (Slot a))
  , tCount :: !Int
  -- ^ How much of 'tSlots' has ever been handed out; nothing at or past
  -- this index is ever read.
  , tFree :: ![Int]
  , tLive :: !Int
  }

-- | A table, plus the write lock that serialises the two functions which
-- change it. The 'IORef' stays an 'IORef' so that reads need no lock at
-- all; the 'MVar' holds nothing but the right to write.
data Registry a = Registry !HandleKind !(MVar ()) !(IORef (Table a))

newRegistry :: HandleKind -> IO (Registry a)
newRegistry kind = do
  slots <- MV.new 0
  lock <- newMVar ()
  Registry kind lock
    <$> newIORef Table {tSlots = slots, tCount = 0, tFree = [], tLive = 0}

-- | Register a cell and return its handle word as an opaque pointer.
--
-- The cell is stored as given: this function is __lazy in the cell's
-- contents__ on purpose, so a spec can register a bottom and still get a
-- legal handle (that is how the exception firewall gets something to
-- catch).
--
-- Returns the NULL word if the slot space is exhausted — 2³⁰ live handles
-- on a 64-bit build, i.e. long after the boxed cells themselves exhausted
-- the address space. Aliasing a live handle would be far worse than
-- reporting failure.
registryInsert :: Registry a -> a -> IO (Ptr b)
registryInsert (Registry kind lock ref) x = withMVar lock $ \_ -> do
  t0 <- readIORef ref
  placed <- case tFree t0 of
    (i : rest) -> do
      gen <-
        MV.read (tSlots t0) i >>= \case
          Vacant g -> pure g
          Occupied g _ -> pure g -- unreachable: free-listed slots are vacant
      pure (Just (i, gen, t0 {tFree = rest}))
    []
      | tCount t0 >= handleSlotLimit -> pure Nothing
      | otherwise -> do
          let i = tCount t0
          slots <- ensureRoom (tSlots t0) (i + 1)
          pure (Just (i, 1, t0 {tSlots = slots, tCount = i + 1}))
  case placed of
    Nothing -> pure (wordPtrToPtr 0)
    Just (i, gen, t1) -> do
      MV.write (tSlots t1) i (Occupied gen x)
      writeIORef ref $! t1 {tLive = tLive t1 + 1}
      pure (wordPtrToPtr (fromIntegral (encodeHandle kind i gen)))

-- | Release a handle. Anything that does not resolve — NULL, forged,
-- already freed — is a safe no-op, which is precisely what makes a double
-- free harmless: the second call finds the slot vacant at a newer
-- generation.
registryRelease :: Registry a -> Ptr b -> IO ()
registryRelease (Registry kind lock ref) p =
  case decodeHandle kind (handleWord p) of
    DecSlot i gen -> withMVar lock $ \_ -> do
      t <- readIORef ref
      if i >= tCount t
        then pure ()
        else
          MV.read (tSlots t) i >>= \case
            Occupied g _ | g == gen -> do
              let gen' = gen + 1
                  -- Generation overflow retires the slot for good: one
                  -- slot's memory is a far better price than a handle
                  -- value that repeats.
                  retired = gen' >= handleGenerationLimit
              MV.write (tSlots t) i (Vacant gen')
              writeIORef ref $!
                t
                  { tFree = if retired then tFree t else i : tFree t
                  , tLive = tLive t - 1
                  }
            _ -> pure ()
    _ -> pure ()

-- | The outcome of looking a handle up.
data Resolved a = ResNull | ResInvalid | ResLive a

-- | Steps 1–6 of the resolution ladder. Read-only and lock-free: at most
-- one 'readIORef' and one vector read, whatever the table's size.
registryResolve :: Registry a -> Ptr b -> IO (Resolved a)
registryResolve (Registry kind _ ref) p =
  case decodeHandle kind (handleWord p) of
    DecNull -> pure ResNull
    DecForged -> pure ResInvalid
    DecSlot i gen -> do
      t <- readIORef ref
      if i >= tCount t
        then pure ResInvalid
        else
          MV.read (tSlots t) i >>= \case
            Occupied g x | g == gen -> pure (ResLive x)
            _ -> pure ResInvalid

-- | @(live handles, slots ever allocated)@. Not part of any C contract;
-- the specs use it to show that slots are recycled.
registryStats :: Registry a -> IO (Int, Int)
registryStats (Registry _ _ ref) = do
  t <- readIORef ref
  pure (tLive t, tCount t)

handleWord :: Ptr b -> Word
handleWord = fromIntegral . ptrToWordPtr

-- | Doubling growth. Elements past 'tCount' are never read, so the freshly
-- grown region needs no initialisation.
ensureRoom :: MV.IOVector (Slot a) -> Int -> IO (MV.IOVector (Slot a))
ensureRoom v needed
  | MV.length v >= needed = pure v
  | otherwise = MV.grow v (max 8 (MV.length v))
