-- | SoA particle buffer (func-spec 0001 §4.4, ADR-0006). Permanent type.
--
-- Invariant (guarded by test T3): all six field vectors have length
-- 'pbCount'.
--
-- Func-spec 0023 widens the layout to nine columns: three velocities join
-- the six that were frozen in 0001. architecture §11 lists this layout as
-- a hard point, so the widening is done the only way that costs the
-- existing consumers nothing (ADR-0018):
--
--   * the six original columns keep their names, types, order and
--     meaning, to the bit;
--   * the velocity columns are /opt-in/ — a spell with no
--     'Magic.Rune.BillboardTrail' leaves them empty and pays exactly what
--     it paid before (no allocation, no write, no branch inside the
--     per-particle loop, since the choice is made once in 'buildBuffer'
--     versus 'buildBufferWithVelocity');
--   * that opt-in is an /invariant/ rather than a convention: each
--     velocity column's length is 0 or 'pbCount', and the three agree.
--     A half-filled velocity column cannot be built by accident.
--
-- Func-spec 0010 §2 adds the count-then-fill constructor 'buildBuffer':
-- the caller states the exact row count up front, six exact-size mutable
-- columns are allocated once, and every row is written exactly once in
-- place. No boxed intermediate ever exists, and the 'ST' region is closed
-- ('runST'), so the function is pure — ADR-0007's "no @Eff@ in the core"
-- is about effects escaping, not about internal mutation.
--
-- 'fromParticles' survives as a thin wrapper over it: the compatibility
-- entry point for callers that already hold a list (tests, tools), no
-- longer the sampler's path.
module Magic.Particle.Buffer
  ( ParticleBuffer (..)
  , emptyBuffer
  , bufferInvariant
  , fromParticles

    -- * Count-then-fill construction (func-spec 0010 S2)
  , WriteRow
  , buildBuffer

    -- * Velocity columns (func-spec 0023 S1)
  , WriteVel
  , buildBufferWithVelocity
  , hasVelocity
  ) where

import Control.DeepSeq (NFData (..))
import Control.Monad.ST (ST, runST)
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MU
import Data.Word (Word32)
import Magic.Types (V3 (..))

-- | Structure-of-arrays particle buffer. Positions are coordinates in the
-- abstract 3D space (ADR-0008); color is packed RGBA.
data ParticleBuffer = ParticleBuffer
  { pbPosX :: !(U.Vector Float)
  , pbPosY :: !(U.Vector Float)
  , pbPosZ :: !(U.Vector Float)
  , pbSize :: !(U.Vector Float)
  , pbLife :: !(U.Vector Float)
  , pbColor :: !(U.Vector Word32)
  , pbVelX :: !(U.Vector Float)
  -- ^ Velocity, in units per second (func-spec 0023 S1). Empty when this
  -- spell asked for none — see the module header's opt-in note and
  -- 'hasVelocity'.
  , pbVelY :: !(U.Vector Float)
  , pbVelZ :: !(U.Vector Float)
  , pbCount :: !Int
  }
  deriving (Eq, Show)

instance NFData ParticleBuffer where
  rnf (ParticleBuffer x y z s l c vx vy vz n) =
    x
      `seq` y
      `seq` z
      `seq` s
      `seq` l
      `seq` c
      `seq` vx
      `seq` vy
      `seq` vz
      `seq` n
      `seq` ()

emptyBuffer :: ParticleBuffer
emptyBuffer =
  ParticleBuffer
    { pbPosX = U.empty
    , pbPosY = U.empty
    , pbPosZ = U.empty
    , pbSize = U.empty
    , pbLife = U.empty
    , pbColor = U.empty
    , pbVelX = U.empty
    , pbVelY = U.empty
    , pbVelZ = U.empty
    , pbCount = 0
    }

-- | The invariant every 'ParticleBuffer' must satisfy.
--
-- Two clauses since func-spec 0023. The six original columns are all
-- 'pbCount' long, as they have been since 0001. The three velocity
-- columns are either all empty (this spell computes no velocity) or all
-- 'pbCount' long — never a mixture, and never half filled. That is what
-- makes "opt-in" a property of the type rather than a convention every
-- consumer has to remember: a reader only ever has to ask
-- 'hasVelocity' once.
bufferInvariant :: ParticleBuffer -> Bool
bufferInvariant pb =
  all
    (== pbCount pb)
    [ U.length (pbPosX pb)
    , U.length (pbPosY pb)
    , U.length (pbPosZ pb)
    , U.length (pbSize pb)
    , U.length (pbLife pb)
    , U.length (pbColor pb)
    ]
    && (velLengths == [0, 0, 0] || velLengths == replicate 3 (pbCount pb))
  where
    velLengths =
      [ U.length (pbVelX pb)
      , U.length (pbVelY pb)
      , U.length (pbVelZ pb)
      ]

-- | Whether this buffer carries velocity columns (func-spec 0023 S1).
--
-- The invariant makes one column enough to decide for all three, and
-- makes @not . hasVelocity@ exactly "the six-column buffer every spell
-- without a trail produces".
--
-- A buffer of zero particles reports 'False' — with no rows there is
-- nothing to distinguish the two cases, and 'False' is the answer that
-- keeps a consumer on the path it would take for an empty six-column
-- buffer.
hasVelocity :: ParticleBuffer -> Bool
hasVelocity pb = not (U.null (pbVelX pb))

-- | Write one row: @writeRow index position size life color@. Handed to
-- the fill action by 'buildBuffer'; valid only inside it.
type WriteRow s = Int -> V3 -> Float -> Float -> Word32 -> ST s ()

-- | @buildBuffer n fill@ allocates exactly @n@ rows and runs @fill@ once
-- with a row writer. Rows the fill action never writes stay zero (the
-- columns are zero-initialized rather than raw), so an under-filling
-- caller degrades to blank particles instead of to non-deterministic
-- memory — determinism is this system's central contract and must not
-- depend on a caller getting its own count right.
--
-- Establishes 'bufferInvariant' by construction.
buildBuffer :: Int -> (forall s. WriteRow s -> ST s ()) -> ParticleBuffer
buildBuffer n fill
  | n <= 0 = emptyBuffer
  | otherwise = runST $ do
      px <- MU.replicate n 0
      py <- MU.replicate n 0
      pz <- MU.replicate n 0
      sz <- MU.replicate n 0
      lf <- MU.replicate n 0
      cl <- MU.replicate n 0
      fill $ \i (V3 x y z) s l c -> do
        MU.write px i x
        MU.write py i y
        MU.write pz i z
        MU.write sz i s
        MU.write lf i l
        MU.write cl i c
      ParticleBuffer
        <$> U.unsafeFreeze px
        <*> U.unsafeFreeze py
        <*> U.unsafeFreeze pz
        <*> U.unsafeFreeze sz
        <*> U.unsafeFreeze lf
        <*> U.unsafeFreeze cl
        <*> pure U.empty
        <*> pure U.empty
        <*> pure U.empty
        <*> pure n
{-# INLINE buildBuffer #-}

-- | Write one row's velocity: @writeVel index velocity@. Handed to the
-- fill action by 'buildBufferWithVelocity'; valid only inside it.
--
-- A second writer rather than three more arguments on 'WriteRow': the
-- six-column writer is the frozen hot path of func-spec 0010 and its
-- callers must keep compiling to the same loop. Splitting the widening
-- into a second, separately-passed function is what lets
-- 'buildBuffer' stay literally the code it was.
type WriteVel s = Int -> V3 -> ST s ()

-- | 'buildBuffer' with the three velocity columns allocated as well
-- (func-spec 0023 S1).
--
-- Rows the fill action never writes keep zero velocity, for the same
-- reason 'buildBuffer' zero-initializes: determinism must not depend on a
-- caller getting its own count right.
--
-- Establishes 'bufferInvariant' — including its velocity clause — by
-- construction: the three columns are allocated together at length @n@ or
-- not at all.
buildBufferWithVelocity
  :: Int -> (forall s. WriteRow s -> WriteVel s -> ST s ()) -> ParticleBuffer
buildBufferWithVelocity n fill
  | n <= 0 = emptyBuffer
  | otherwise = runST $ do
      px <- MU.replicate n 0
      py <- MU.replicate n 0
      pz <- MU.replicate n 0
      sz <- MU.replicate n 0
      lf <- MU.replicate n 0
      cl <- MU.replicate n 0
      vx <- MU.replicate n 0
      vy <- MU.replicate n 0
      vz <- MU.replicate n 0
      fill
        ( \i (V3 x y z) s l c -> do
            MU.write px i x
            MU.write py i y
            MU.write pz i z
            MU.write sz i s
            MU.write lf i l
            MU.write cl i c
        )
        ( \i (V3 x y z) -> do
            MU.write vx i x
            MU.write vy i y
            MU.write vz i z
        )
      ParticleBuffer
        <$> U.unsafeFreeze px
        <*> U.unsafeFreeze py
        <*> U.unsafeFreeze pz
        <*> U.unsafeFreeze sz
        <*> U.unsafeFreeze lf
        <*> U.unsafeFreeze cl
        <*> U.unsafeFreeze vx
        <*> U.unsafeFreeze vy
        <*> U.unsafeFreeze vz
        <*> pure n
{-# INLINE buildBufferWithVelocity #-}

-- | Build a buffer from a list of @(position, size, life, color)@ tuples.
-- Establishes the invariant by construction.
--
-- Since func-spec 0010 this is a compatibility wrapper over
-- 'buildBuffer', not the sampler's path: it still walks the (boxed) list
-- twice — once for the length, once to fill — which is what a list-shaped
-- input costs.
fromParticles :: [(V3, Float, Float, Word32)] -> ParticleBuffer
fromParticles ps = buildBuffer (length ps) $ \write ->
  let go _ [] = pure ()
      go !i ((p, s, l, c) : rest) = write i p s l c >> go (i + 1) rest
   in go (0 :: Int) ps
