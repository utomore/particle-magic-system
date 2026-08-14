-- | Depth ordering for the 3D path (func-spec 0013 §2), the last piece
-- of alpha blending the demo was missing.
--
-- Alpha-blended quads only composite correctly when they are drawn back
-- to front; drawn in buffer order they show the seams of whatever order
-- the emitter happened to fill the SoA in. 'Magic.Projection.depthOrder'
-- already solves this for the 2D path, but its depth is an axis of the
-- abstract space — the core has no notion of a camera and must not grow
-- one (ADR-0008). So the view-space variant lives here, in the shell,
-- where the camera does exist. Same shape, same stability law, same
-- "return a permutation, never copy the SoA" discipline (ADR-0006).
--
-- Sorting stays on the staging side (ADR-0009): the sorted permutation
-- feeds 'buildQuadsOrdered', and the IO half's one-mesh-update-plus-one
-- draw-call budget is untouched.
module App.Render.Order
  ( viewOrder
  , identityOrder
  , orderedQuads
  ) where

import Data.List (sortOn)
import Data.Ord (Down (..))
import qualified Data.Vector.Unboxed as U

import App.Effects (Camera (..))
import App.Render.Quads (QuadBatch, buildQuads, buildQuadsOrdered)
import Magic.Interface
  ( BlendMode (..)
  , ParticleBuffer
  , RenderBatch (..)
  , V3 (..)
  , pbCount
  , pbPosX
  , pbPosY
  , pbPosZ
  )

-- | The identity permutation of @n@ slots — what 'viewOrder' returns for
-- a buffer that is already in view order, and the reference the
-- @buildQuadsOrdered ≡ buildQuads@ law is stated against.
identityOrder :: Int -> U.Vector Int
identityOrder n = U.enumFromN 0 (max 0 n)

-- | The indices @[0 .. pbCount-1]@ ordered by distance along the view
-- axis, far to near — the 3D counterpart of
-- 'Magic.Projection.depthOrder'.
--
-- Depth is the particle's offset from the camera projected onto the view
-- direction, not the euclidean distance to the camera: that is the depth
-- the rasterizer itself compares, so the staged order agrees with the
-- depth buffer instead of fighting it near the edges of the frustum.
--
-- Stable: equal depths keep their buffer order, so the frame a given
-- simulation state renders to is a function of that state alone. A
-- degenerate camera (position on top of its target) falls back to a
-- fixed direction rather than producing NaN keys, which would make the
-- comparison — and therefore the frame — order-dependent.
viewOrder :: Camera -> ParticleBuffer -> U.Vector Int
viewOrder cam pb = U.fromList (map fst (sortOn (Down . snd) keyed))
  where
    keyed = [(i, depthAt i) | i <- [0 .. pbCount pb - 1]]
    V3 fx fy fz = viewDirection cam
    V3 ex ey ez = camPos cam
    depthAt i =
      (pbPosX pb U.! i - ex) * fx
        + (pbPosY pb U.! i - ey) * fy
        + (pbPosZ pb U.! i - ez) * fz

-- | Unit vector from the camera towards its target, with the same
-- fallback 'App.Render.Quads.billboardBasis' uses so the two agree on
-- what a degenerate camera looks at.
viewDirection :: Camera -> V3
viewDirection cam
  | n < 1e-6 = V3 0 0 (-1)
  | otherwise = V3 (dx / n) (dy / n) (dz / n)
  where
    V3 tx ty tz = camTarget cam
    V3 px py pz = camPos cam
    (dx, dy, dz) = (tx - px, ty - py, tz - pz)
    n = sqrt (dx * dx + dy * dy + dz * dz)

-- | One batch's camera-facing quads, depth-sorted if and only if the
-- batch needs it.
--
-- Additive blending is commutative — the framebuffer sums the same
-- numbers whatever order they arrive in — and the 3D backend already
-- draws additive batches with the depth mask off, so sorting them would
-- cost an @O(n log n)@ pass to produce a bit-identical image. Alpha
-- batches are the ones where order is the image.
orderedQuads :: Camera -> RenderBatch -> QuadBatch
orderedQuads cam batch
  | rbBlend batch == BlendAdditive = buildQuads pos target up pb
  | otherwise = buildQuadsOrdered (viewOrder cam pb) pos target up pb
  where
    pb = rbParticles batch
    (pos, target, up) = (camPos cam, camTarget cam, camUp cam)
