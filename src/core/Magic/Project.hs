-- | Projection abstraction (ADR-0008): the core simulates in an abstract
-- 3D space and never knows which dimension the host renders in. This
-- module is where "which dimension" is decided — and it is pure, so the
-- decision is property-testable without a window.
--
-- 'project' is the 3D case (identity: the raylib backend consumes
-- abstract-space coordinates and lets the GPU do the perspective).
-- Func-spec 0008 adds the 2D case: an orthographic 'ViewPlane' selection
-- plus the painter's-order permutation a flat renderer needs, which is
-- exactly ADR-0008's "2D = orthographic projection: drop one axis and
-- pick a depth-sorting strategy".
--
-- Deliberately pixel-free: screen origin, pixels-per-unit and the y-flip
-- belong to the shell (@App.Render.Flat@), not to the core.
module Magic.Project
  ( project
  , ViewPlane (..)
  , orthographic
  , depthOrder

    -- * Re-export
  , V2 (..)
  -- ^ The plane coordinate type ('Magic.Types', 0001 vocabulary).
  -- Re-exported so the shell — which may only depend on magic-boundary —
  -- can pattern match on what 'orthographic' returns.
  ) where

import Data.List (sortOn)
import Data.Ord (Down (..))
import qualified Data.Vector.Unboxed as U
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Types (V2 (..), V3 (..))

-- | The 3D case: no projection of our own.
project :: V3 -> V3
project = id

-- | Which axis the orthographic camera looks along.
data ViewPlane
  = SideXY
  -- ^ Viewer at @+Z@ looking towards @-Z@: plane = @(x, y)@, Z dropped.
  -- The default — spells fire upwards, so this is the natural side view.
  | TopXZ
  -- ^ Viewer at @+Y@ looking down: plane = @(x, z)@, Y dropped.
  deriving (Eq, Show)

-- | Plane coordinates plus a depth. Convention: larger depth is further
-- away (SideXY: @depth = -z@; TopXZ: @depth = -y@).
--
-- Componentwise selection, no arithmetic beyond the sign flip — the
-- projected coordinates are bit-identical to the source ones.
orthographic :: ViewPlane -> V3 -> (V2, Float)
orthographic SideXY (V3 x y z) = (V2 x y, negate z)
orthographic TopXZ (V3 x y z) = (V2 x z, negate y)

-- | Painter's permutation: the indices @[0 .. pbCount-1]@ ordered by
-- depth, far to near (decreasing depth), so drawing them in this order
-- puts nearer particles on top without a depth buffer.
--
-- Stable: equal depths keep their buffer order, which is what makes the
-- rendering deterministic. Returns an index permutation rather than a
-- reordered buffer, so the SoA layout (ADR-0006) is never copied and the
-- permutation laws can be asserted directly.
--
-- Implementation note: 'sortOn' allocates a boxed list of the batch. That
-- is inside budget at the 4096-particle cap; a faster in-place sort is
-- booked to the future throughput spec (func-spec 0008 §9).
depthOrder :: ViewPlane -> ParticleBuffer -> U.Vector Int
depthOrder plane pb =
  U.fromList (map fst (sortOn (Down . snd) keyed))
  where
    keyed = [(i, depthAt i) | i <- [0 .. pbCount pb - 1]]
    depthAt i =
      snd
        ( orthographic
            plane
            (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i))
        )
