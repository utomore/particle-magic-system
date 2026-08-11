-- | Permanent core vocabulary (func-spec 0001 §4.1).
--
-- Everything here is a frozen interface once spec 0001 is delivered:
-- 'V3', 'Time', 'DeltaTime', 'Seconds', 'Seed', 'CastContext', 'hashChan'.
module Magic.Types
  ( -- * Abstract 3D space (ADR-0008)
    V3 (..)
  , vscale
  , dot
  , cross
  , norm
  , normalize

    -- * Time and randomness
  , Time (..)
  , DeltaTime (..)
  , Seconds (..)
  , Seed (..)

    -- * Cast context
  , CastContext (..)

    -- * Deterministic random channels
  , hashChan
  ) where

import Control.DeepSeq (NFData (..))
import Data.Bits (shiftR, xor)
import Data.Word (Word64)

-- | A point/vector in the abstract 3D space the core simulates in
-- (ADR-0008: the core never knows whether it is projected to 2D or 3D).
data V3 = V3 !Float !Float !Float
  deriving (Eq, Show)

instance NFData V3 where
  rnf (V3 _ _ _) = ()

-- | Componentwise arithmetic; 'fromInteger' broadcasts to all components.
instance Num V3 where
  V3 ax ay az + V3 bx by bz = V3 (ax + bx) (ay + by) (az + bz)
  {-# INLINE (+) #-}
  V3 ax ay az - V3 bx by bz = V3 (ax - bx) (ay - by) (az - bz)
  {-# INLINE (-) #-}
  V3 ax ay az * V3 bx by bz = V3 (ax * bx) (ay * by) (az * bz)
  {-# INLINE (*) #-}
  negate (V3 x y z) = V3 (negate x) (negate y) (negate z)
  {-# INLINE negate #-}
  abs (V3 x y z) = V3 (abs x) (abs y) (abs z)
  signum (V3 x y z) = V3 (signum x) (signum y) (signum z)
  fromInteger n = let f = fromInteger n in V3 f f f

-- | Scalar multiplication.
vscale :: Float -> V3 -> V3
vscale s (V3 x y z) = V3 (s * x) (s * y) (s * z)
{-# INLINE vscale #-}

dot :: V3 -> V3 -> Float
dot (V3 ax ay az) (V3 bx by bz) = ax * bx + ay * by + az * bz
{-# INLINE dot #-}

cross :: V3 -> V3 -> V3
cross (V3 ax ay az) (V3 bx by bz) =
  V3 (ay * bz - az * by) (az * bx - ax * bz) (ax * by - ay * bx)
{-# INLINE cross #-}

norm :: V3 -> Float
norm v = sqrt (dot v v)
{-# INLINE norm #-}

-- | Unit vector in the same direction; the zero vector maps to zero.
normalize :: V3 -> V3
normalize v =
  let n = norm v
   in if n == 0 then V3 0 0 0 else vscale (1 / n) v
{-# INLINE normalize #-}

-- | Seconds since the spell was cast.
newtype Time = Time Double
  deriving (Eq, Ord, Show)

newtype DeltaTime = DeltaTime Double
  deriving (Eq, Ord, Show)

-- | A duration, in seconds.
newtype Seconds = Seconds Double
  deriving (Eq, Ord, Show)

-- | Deterministic random seed for a cast.
newtype Seed = Seed Word64
  deriving (Eq, Show)

-- | Everything about the caster a spell needs (architecture §4.7).
data CastContext = CastContext
  { casterPos :: !V3
  , casterFacing :: !V3
  , seed :: !Seed
  }
  deriving (Eq, Show)

-- | Deterministic random channel: @hashChan seed particleIndex channel@
-- yields a value in @[0, 1)@. This is the final randomness mechanism
-- (architecture §4.3): evaluation is stateless, so determinism and
-- replayability are never broken by randomness.
hashChan :: Seed -> Int -> Int -> Float
hashChan (Seed s) i c =
  let z0 =
        s
          + fromIntegral i * 0x9E3779B97F4A7C15
          + fromIntegral c * 0xC2B2AE3D27D4EB4F
      z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
      z3 = z2 `xor` (z2 `shiftR` 31) :: Word64
   in fromIntegral (z3 `shiftR` 40) / 16777216
{-# INLINE hashChan #-}
