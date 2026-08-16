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

    -- * Cross-batch interleaving (func-spec 0023 S9)
  , DrawGroup (..)
  , crossBatchPicks
  , frameDraws
  ) where

import Data.List (sortOn)
import Data.Ord (Down (..))
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

import App.Effects (Camera (..))
import App.Render.Post (VisualSettings (..))
import App.Render.Quads
  ( QuadBatch
  , QuadSource (..)
  , buildMergedQuads
  , buildQuads
  , buildQuadsOrdered
  )
import App.Render.Sprite (atlasRect)
import Magic.Interface
  ( BillboardShape (..)
  , BlendMode (..)
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
    keyed = [(i, depthOf cam pb i) | i <- [0 .. pbCount pb - 1]]

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

-- Cross-batch interleaving (func-spec 0023 S9) --------------------------------

-- | One draw call: a vertex stream and the blend state it needs.
--
-- A frame is at most two of these — the alpha particles and the additive
-- ones — however many batches 'Magic.Interface.observeSpell' produced.
-- That is fewer draw calls than before this round, not more, so
-- ADR-0009's "draw calls = batches, never particles" is kept with room to
-- spare.
data DrawGroup = DrawGroup
  { dgQuads :: !QuadBatch
  , dgBlend :: !BlendMode
  }

-- | The frame's alpha particles as @(batch, particle)@ pairs, sorted far
-- to near across every batch at once.
--
-- __The problem.__ Since func-spec 0015 one spell can produce several
-- batches, and 'orderedQuads' sorts each on its own. Two alpha batches
-- therefore composite in /batch/ order regardless of depth: a far trail
-- drawn after a near light point covers it. Sorting inside each batch
-- cannot fix that, because the comparison that matters is between
-- particles of different batches.
--
-- __Why per-batch permutations are not enough.__ Func-spec 0023 §2.7
-- proposed pooling, sorting, and splitting back into one permutation per
-- batch. That does not deliver the ordering: a batch still draws
-- contiguously, so the frame is still "all of batch 0, then all of batch
-- 1", whatever order the particles take /within/ each. The global order
-- can only be realized by a single draw — which is what the sprite atlas
-- (func-spec 0023 S9, 'App.Render.Sprite.atlasRect') makes possible, and
-- why this returns picks rather than permutations (§10 records the
-- deviation).
--
-- Stable: equal depths keep pool order, which is batch order then index
-- order — the order the frame would have had with no sorting at all. That
-- is what keeps the frame a function of the simulation state alone.
crossBatchPicks :: Camera -> [RenderBatch] -> [(Int, Int)]
crossBatchPicks cam bs = map fst (sortOn (Down . snd) pooled)
  where
    pooled =
      [ ((k, i), depthOf cam (rbParticles b) i)
      | (k, b) <- zip [0 :: Int ..] bs
      , rbBlend b /= BlendAdditive
      , i <- [0 .. pbCount (rbParticles b) - 1]
      ]

-- | The whole frame as draw groups: the alpha particles depth-sorted into
-- one, the additive ones concatenated into another.
--
-- __Additive is not sorted.__ Addition is commutative, so the order of an
-- additive batch is not the image, and the 3D backend already draws them
-- with the depth mask off. Sorting them would be an @O(n log n)@ pass to
-- produce an identical picture. They are still /merged/, because merging
-- costs nothing and saves a draw call.
--
-- Each particle carries its own shape (as an atlas rectangle) and its own
-- stretch (from the trail switch and its batch's shape), so nothing that
-- used to force a draw-call boundary survives.
frameDraws :: VisualSettings -> Camera -> [RenderBatch] -> [DrawGroup]
frameDraws settings cam bs =
  [ DrawGroup (build alphaPicks) BlendAlpha
  , DrawGroup (build additivePicks) BlendAdditive
  ]
  where
    sources =
      V.fromList
        [ QuadSource
            { qsBuffer = rbParticles b
            , qsRect = atlasRect (rbShape b)
            , qsStretch = vsTrails settings && rbShape b == BillboardTrail
            }
        | b <- bs
        ]

    alphaPicks = crossBatchPicks cam bs

    -- Input order, which for an additive group is as good as any other.
    additivePicks =
      [ (k, i)
      | (k, b) <- zip [0 :: Int ..] bs
      , rbBlend b == BlendAdditive
      , i <- [0 .. pbCount (rbParticles b) - 1]
      ]

    build = buildMergedQuads (camPos cam) (camTarget cam) (camUp cam) sources

-- | Depth of one particle of a buffer along the view axis — the key
-- 'viewOrder' sorts on, lifted out so the cross-batch pool computes it
-- the same way rather than a second way.
depthOf :: Camera -> ParticleBuffer -> Int -> Float
depthOf cam pb i =
  (pbPosX pb U.! i - ex) * fx
    + (pbPosY pb U.! i - ey) * fy
    + (pbPosZ pb U.! i - ez) * fz
  where
    V3 fx fy fz = viewDirection cam
    V3 ex ey ez = camPos cam

