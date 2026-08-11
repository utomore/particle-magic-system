-- | SoA particle buffer (func-spec 0001 §4.4, ADR-0006). Permanent type.
--
-- Invariant (guarded by test T3): all six field vectors have length
-- 'pbCount'.
module Magic.Particle.Buffer
  ( ParticleBuffer (..)
  , emptyBuffer
  , bufferInvariant
  , fromParticles
  ) where

import Control.DeepSeq (NFData (..))
import qualified Data.Vector.Unboxed as U
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
  , pbCount :: !Int
  }
  deriving (Eq, Show)

instance NFData ParticleBuffer where
  rnf (ParticleBuffer x y z s l c n) =
    x `seq` y `seq` z `seq` s `seq` l `seq` c `seq` n `seq` ()

emptyBuffer :: ParticleBuffer
emptyBuffer =
  ParticleBuffer
    { pbPosX = U.empty
    , pbPosY = U.empty
    , pbPosZ = U.empty
    , pbSize = U.empty
    , pbLife = U.empty
    , pbColor = U.empty
    , pbCount = 0
    }

-- | The invariant every 'ParticleBuffer' must satisfy.
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

-- | Build a buffer from a list of @(position, size, life, color)@ tuples.
-- Establishes the invariant by construction.
fromParticles :: [(V3, Float, Float, Word32)] -> ParticleBuffer
fromParticles ps =
  ParticleBuffer
    { pbPosX = U.fromList [x | (V3 x _ _, _, _, _) <- ps]
    , pbPosY = U.fromList [y | (V3 _ y _, _, _, _) <- ps]
    , pbPosZ = U.fromList [z | (V3 _ _ z, _, _, _) <- ps]
    , pbSize = U.fromList [s | (_, s, _, _) <- ps]
    , pbLife = U.fromList [l | (_, _, l, _) <- ps]
    , pbColor = U.fromList [c | (_, _, _, c) <- ps]
    , pbCount = length ps
    }
