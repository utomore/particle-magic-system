-- | SoA particle buffer (func-spec 0001 §4.4, ADR-0006). Permanent type.
--
-- Invariant (guarded by test T3): all six field vectors have length
-- 'pbCount'.
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
        <*> pure n
{-# INLINE buildBuffer #-}

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
