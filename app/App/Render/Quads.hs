{-# LANGUAGE BangPatterns #-}

-- | Camera-facing quad expansion (func-spec 0005 §4.5): the pure half of
-- the render path. The SoA 'ParticleBuffer' (ADR-0006) is expanded into a
-- flat vertex stream that the raylib backend hands to the GPU in one
-- @UpdateMeshBuffer@ per attribute.
--
-- Deliberately free of h-raylib and of any effect: billboarding is CPU
-- arithmetic over our own 'V3', so the whole geometry contract is
-- property-testable headless (@test\/QuadBatchSpec.hs@).
module App.Render.Quads
  ( QuadBatch (..)
  , buildQuads
  , buildQuadsOrdered
  , billboardBasis
  , quadIndices
  , quadTexcoords

    -- * Velocity-stretched trails (func-spec 0023 S6)
  , buildTrailQuads
  , buildTrailQuadsOrdered
  , trailStretchPerUnit
  , trailMaxStretch
  , trailStretchOf
  , trailAxes

    -- * Merged, multi-shape batches (func-spec 0023 S9)
  , QuadSource (..)
  , buildMergedQuads
  , wholeSprite
  ) where

import Control.Monad (forM_)
import qualified Data.Vector as V
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as SM
import qualified Data.Vector.Unboxed as U
import Data.Bits (shiftR, (.&.))
import Data.Word (Word16, Word32, Word8)
import Magic.Interface
  ( ParticleBuffer
  , V3 (..)
  , pbColor
  , pbCount
  , pbPosX
  , pbPosY
  , pbPosZ
  , pbSize
  , pbVelX
  , pbVelY
  , pbVelZ
  )

-- | Staging data for one batch: the interleave-free vertex streams that
-- map 1:1 onto the mesh's position and color VBOs.
--
-- Invariants (guarded by @QuadBatchSpec@):
-- @S.length qbPositions == qbCount * 4 * 3@ and
-- @S.length qbColors == qbCount * 4 * 4@.
data QuadBatch = QuadBatch
  { qbPositions :: !(S.Vector Float)
  -- ^ @qbCount*4@ vertices × (x, y, z).
  , qbColors :: !(S.Vector Word8)
  -- ^ @qbCount*4@ vertices × (r, g, b, a).
  , qbTexcoords :: !(S.Vector Float)
  -- ^ @qbCount*4@ vertices × (u, v) — func-spec 0023 S9.
  --
  -- Per frame rather than written once at mesh upload, as it was from
  -- func-spec 0015 until now. The reason is the atlas: a quad's UVs now
  -- say /which shape/ it is, so particles of different shapes can share
  -- one draw call and therefore one depth sort. The cost is one more
  -- 'Data.Vector.Storable.unsafeWith' upload per draw, against a saving
  -- of one draw call per shape — and the correct picture, which the
  -- per-shape texture binding could not produce (§2.7).
  , qbCount :: !Int
  -- ^ Number of quads == @pbCount@ of the source buffer.
  }
  deriving (Eq, Show)

-- | Camera right/up unit basis for billboarding, from a look-at triple.
--
-- @forward = normalize (target - pos)@, @right = normalize (forward × up)@,
-- @up' = right × forward@ — the gluLookAt convention, so the expanded
-- quads are front-facing (counter-clockwise) as seen from the camera.
--
-- Degenerate inputs (zero-length view vector, or an up vector parallel to
-- it) fall back to a fixed basis instead of producing NaNs: a renderer
-- must never be handed a non-finite vertex.
billboardBasis :: V3 -> V3 -> V3 -> (V3, V3)
billboardBasis pos target up = (right, upv)
  where
    forward = normalizeOr (V3 0 0 (-1)) (target `sub` pos)
    right =
      let r = forward `cross` up
       in if norm r < 1e-6
            then -- up ∥ forward: any vector orthogonal to forward will do.
              normalizeOr (V3 1 0 0) (forward `cross` V3 0 0 1)
            else scale (1 / norm r) r
    upv = right `cross` forward

-- | Expand every particle of the buffer into a camera-facing quad.
--
-- Vertex order per particle is @(-r,-u), (+r,-u), (+r,+u), (-r,+u)@ with
-- half-extent @pbSize/2@, matching the static index pattern of
-- 'quadIndices'.
buildQuads :: V3 -> V3 -> V3 -> ParticleBuffer -> QuadBatch
buildQuads camPos camTarget camUp pb =
  buildQuadsWith squareAxes id (pbCount pb) camPos camTarget camUp pb

-- | 'buildQuads', emitting the quads in the order given by an index
-- permutation instead of in buffer order (func-spec 0013 §3).
--
-- This is what makes alpha blending composite correctly: the caller
-- (@App.Render.Order@) hands in the far-to-near view order, and the
-- vertex stream comes out already sorted, so the IO half still does one
-- mesh update and one draw call. @order@ must be a permutation of
-- @[0 .. pbCount-1]@; slots beyond its length are not emitted.
--
-- Law (@test\/OrderSpec.hs@): with the identity permutation the result is
-- bit-identical to 'buildQuads' — the two share one worker, so the
-- ordered path cannot silently drift away from the unordered one.
buildQuadsOrdered :: U.Vector Int -> V3 -> V3 -> V3 -> ParticleBuffer -> QuadBatch
buildQuadsOrdered order camPos camTarget camUp pb =
  buildQuadsWith squareAxes (order U.!) n camPos camTarget camUp pb
  where
    n = min (U.length order) (pbCount pb)

-- | The half-axes of one particle's quad: @axesOf right up i halfExtent@
-- gives the vectors the four corners are placed at @±@ along.
--
-- A function rather than a flag, so 'buildQuads' and 'buildTrailQuads'
-- share one expansion worker and cannot drift apart in vertex order,
-- winding or index layout — the same technique the @srcOf@ permutation
-- uses one argument along.
type AxesOf = V3 -> V3 -> Int -> Float -> (V3, V3)

-- | The camera-facing square every shape but the trail draws: the
-- billboard basis scaled by the half-extent, ignoring the particle.
squareAxes :: AxesOf
squareAxes right up _ h = (scale h right, scale h up)
{-# INLINE squareAxes #-}

-- | The shared quad-expansion worker, parameterised by which source
-- particle fills each output slot and by how that particle's half-axes
-- are chosen. Inlined at every (saturated) call site, so 'buildQuads'
-- compiles to what it always did: the identity index function and the
-- square axes leave no trace.
{-# INLINE buildQuadsWith #-}
buildQuadsWith
  :: AxesOf
  -- ^ How to orient and size one particle's quad.
  -> (Int -> Int)
  -- ^ Output slot -> source particle index.
  -> Int
  -- ^ How many slots to emit.
  -> V3
  -> V3
  -> V3
  -> ParticleBuffer
  -> QuadBatch
buildQuadsWith axesOf srcOf n camPos camTarget camUp pb =
  buildQuadsUV axesOf (const wholeSprite) srcOf n camPos camTarget camUp pb

-- | The whole texture, which is what a quad's UVs meant before the atlas
-- and what they still mean on the 2D path.
wholeSprite :: (Float, Float, Float, Float)
wholeSprite = (0, 0, 1, 1)

-- | 'buildQuadsWith' with per-particle texture coordinates as well
-- (func-spec 0023 S9) — the form a merged, multi-shape batch needs.
{-# INLINE buildQuadsUV #-}
buildQuadsUV
  :: AxesOf
  -> (Int -> (Float, Float, Float, Float))
  -- ^ Source particle -> its atlas rect @(u0, v0, u1, v1)@.
  -> (Int -> Int)
  -> Int
  -> V3
  -> V3
  -> V3
  -> ParticleBuffer
  -> QuadBatch
buildQuadsUV axesOf uvOf srcOf n camPos camTarget camUp pb =
  QuadBatch
    { qbPositions = positions
    , qbColors = colors
    , qbTexcoords = texcoords
    , qbCount = n
    }
  where
    (right, up) = billboardBasis camPos camTarget camUp

    -- Corner order matches 'buildQuadsWith''s vertex order exactly:
    -- (-a,-b), (+a,-b), (+a,+b), (-a,+b) -> (u0,v0), (u1,v0), (u1,v1),
    -- (u0,v1). Same mapping 'quadTexcoords' has always written, now
    -- pointed at a sub-rectangle instead of the whole texture.
    texcoords = S.create $ do
      mv <- SM.new (n * 8)
      forM_ [0 .. n - 1] $ \j -> do
        let (u0, v0, u1, v1) = uvOf (srcOf j)
            !base = j * 8
        SM.write mv base u0
        SM.write mv (base + 1) v0
        SM.write mv (base + 2) u1
        SM.write mv (base + 3) v0
        SM.write mv (base + 4) u1
        SM.write mv (base + 5) v1
        SM.write mv (base + 6) u0
        SM.write mv (base + 7) v1
      pure mv

    positions = S.create $ do
      mv <- SM.new (n * 12)
      forM_ [0 .. n - 1] $ \j -> do
        let !i = srcOf j
            !cx = pbPosX pb U.! i
            !cy = pbPosY pb U.! i
            !cz = pbPosZ pb U.! i
            !h = (pbSize pb U.! i) * 0.5
            (V3 hrx hry hrz, V3 hux huy huz) = axesOf right up i h
            !base = j * 12
            vertex k sr su = do
              SM.write mv (base + k * 3) (cx + sr * hrx + su * hux)
              SM.write mv (base + k * 3 + 1) (cy + sr * hry + su * huy)
              SM.write mv (base + k * 3 + 2) (cz + sr * hrz + su * huz)
        vertex 0 (-1) (-1)
        vertex 1 1 (-1)
        vertex 2 1 1
        vertex 3 (-1) 1
      pure mv

    colors = S.create $ do
      mv <- SM.new (n * 16)
      forM_ [0 .. n - 1] $ \j -> do
        let !packed = pbColor pb U.! srcOf j
            !base = j * 16
        forM_ [0 .. 3 :: Int] $ \k -> do
          SM.write mv (base + k * 4) (byteAt 24 packed)
          SM.write mv (base + k * 4 + 1) (byteAt 16 packed)
          SM.write mv (base + k * 4 + 2) (byteAt 8 packed)
          SM.write mv (base + k * 4 + 3) (byteAt 0 packed)
      pure mv

-- Velocity-stretched trails (func-spec 0023 S6) ------------------------------

-- | How much a particle's quad lengthens per world unit per second of
-- speed. __Frozen__ with 'trailMaxStretch' (func-spec 0023 S6): together
-- they are the entire mapping from velocity to trail length, and a spell
-- that trails a certain way must keep trailing that way.
--
-- Note what is /not/ a knob here. Func-spec 0015 wanted a per-batch
-- stretch parameter and could not have one, because @batch_info@'s stride
-- is frozen at four ints (ADR-0013 D1). This round does not want one
-- either: the length comes from the particle's own speed, so an author
-- who wants a longer tail makes the particle faster — which is the same
-- thing a longer tail /means/.
trailStretchPerUnit :: Float
trailStretchPerUnit = 0.35

-- | Longest a trail may get, as a multiple of the particle's own size.
--
-- The bound is not a nicety. A spell may legitimately produce very fast
-- particles (a @formula@ trajectory is a player-written expression), and
-- without a cap one of them draws a quad across the entire frame — which
-- reads as a rendering failure, not as a fast particle.
trailMaxStretch :: Float
trailMaxStretch = 6

-- | The stretch multiple for a speed: @1 + speed·k@, capped.
--
-- Starts at 1 rather than 0, so a barely-moving particle is its own
-- square rather than a sliver — the trail grows /out of/ the particle
-- instead of replacing it.
trailStretchOf :: Float -> Float
trailStretchOf speed = min trailMaxStretch (1 + max 0 speed * trailStretchPerUnit)

-- | Below this projected speed a particle is treated as not moving.
--
-- Not an optimization: a velocity of exactly zero has no direction, and
-- normalizing it would produce NaN vertices. The threshold is what makes
-- "a still particle draws the square it always drew" true by construction
-- rather than by luck.
trailEpsilon :: Float
trailEpsilon = 1e-6

-- | Half-axes of one trailing particle's quad: lengthwise along the
-- velocity as seen by the camera, crosswise at the particle's own size.
--
-- The velocity is /projected onto the billboard plane/ before it is used.
-- A trail is a screen-space smear of where the particle has been, so the
-- component coming towards the camera contributes nothing to how long it
-- looks — and projecting is also what keeps the quad camera-facing, i.e.
-- still a billboard, so 'quadTexcoords' and the winding are untouched.
--
-- The first axis is the direction of travel, which puts the sprite's @+x@
-- (its opaque end, see 'App.Render.Sprite') at the head of the trail.
--
-- __Degenerate case:__ a particle whose projected velocity is under
-- 'trailEpsilon' gets 'squareAxes' — the same expression, not an
-- equivalent one — so a trail batch with no motion in it is bit-for-bit
-- the batch func-spec 0015 drew.
trailAxes :: U.Vector Float -> U.Vector Float -> U.Vector Float -> AxesOf
trailAxes vxs vys vzs right up i h
  | speed < trailEpsilon = squareAxes right up i h
  | otherwise = (scale (h * trailStretchOf speed) along, scale h across)
  where
    v = V3 (component vxs) (component vys) (component vzs)
    component col
      | i < U.length col = col U.! i
      | otherwise = 0

    -- Drop the component along the view direction: right × up is the
    -- billboard's normal, and (dot v right, dot v up) is what is left.
    planar = scale (v `dot` right) right + scale (v `dot` up) up
    speed = norm planar
    along = scale (1 / speed) planar
    -- The in-plane perpendicular, so the quad stays planar and its
    -- corners stay in the same rotational order.
    across = cross (cross right up) along
{-# INLINE trailAxes #-}

-- | 'buildQuads' with every particle stretched along its own velocity
-- (func-spec 0023 S6).
--
-- The buffer's velocity columns are optional (func-spec 0023 S1); an
-- absent one reads as zero, so a trail-tagged batch of a spell that
-- computed no velocity draws squares rather than failing. That is the
-- same forgiving rule @pm_observe_ex@ follows on the C side, for the same
-- reason: which spell is loaded is not the renderer's business.
buildTrailQuads :: V3 -> V3 -> V3 -> ParticleBuffer -> QuadBatch
buildTrailQuads camPos camTarget camUp pb =
  buildQuadsWith (velocityAxes pb) id (pbCount pb) camPos camTarget camUp pb

-- | 'buildTrailQuads' in a given draw order — the trail counterpart of
-- 'buildQuadsOrdered', so an alpha trail batch can still be depth-sorted.
buildTrailQuadsOrdered
  :: U.Vector Int -> V3 -> V3 -> V3 -> ParticleBuffer -> QuadBatch
buildTrailQuadsOrdered order camPos camTarget camUp pb =
  buildQuadsWith (velocityAxes pb) (order U.!) n camPos camTarget camUp pb
  where
    n = min (U.length order) (pbCount pb)

velocityAxes :: ParticleBuffer -> AxesOf
velocityAxes pb = trailAxes (pbVelX pb) (pbVelY pb) (pbVelZ pb)
{-# INLINE velocityAxes #-}

-- Merged, multi-shape batches (func-spec 0023 S9) -----------------------------

-- | One source of particles for a merged draw: a buffer, the atlas cell
-- its particles sample, and whether they stretch along their velocity.
--
-- Everything that used to differ /between/ draw calls, expressed as data
-- attached to the particle instead. That is the whole trick: with the
-- shape in the UVs and the stretch in the geometry, two particles of
-- different shapes have nothing left that a draw call has to switch, so
-- they can be sorted against each other and drawn together.
data QuadSource = QuadSource
  { qsBuffer :: !ParticleBuffer
  , qsRect :: !(Float, Float, Float, Float)
  -- ^ Atlas cell, from 'App.Render.Sprite.atlasRect'.
  , qsStretch :: !Bool
  -- ^ Whether these particles are drawn as velocity trails.
  }

-- | Expand particles drawn from several buffers into one vertex stream,
-- in the exact order given (func-spec 0023 S9).
--
-- @picks@ is a list of @(source index, particle index)@ in /draw order/ —
-- typically the frame's alpha particles sorted far to near across every
-- batch. Because the result is a single 'QuadBatch', that order is
-- realized as one mesh upload and one draw call, which is what makes
-- cross-batch depth interleaving expressible at all: split back into
-- per-batch permutations it is not, since a batch still draws
-- contiguously (func-spec 0023 §10).
buildMergedQuads
  :: V3 -> V3 -> V3 -> V.Vector QuadSource -> [(Int, Int)] -> QuadBatch
buildMergedQuads camPos camTarget camUp sources picks =
  QuadBatch
    { qbPositions = positions
    , qbColors = colors
    , qbTexcoords = texcoords
    , qbCount = n
    }
  where
    (right, up) = billboardBasis camPos camTarget camUp
    order = V.fromList picks
    n = V.length order

    positions = S.create $ do
      mv <- SM.new (n * 12)
      forM_ [0 .. n - 1] $ \j -> do
        let (s, i) = order V.! j
            src = sources V.! s
            pb = qsBuffer src
            !cx = pbPosX pb U.! i
            !cy = pbPosY pb U.! i
            !cz = pbPosZ pb U.! i
            !h = (pbSize pb U.! i) * 0.5
            (V3 hrx hry hrz, V3 hux huy huz) =
              if qsStretch src
                then velocityAxes pb right up i h
                else squareAxes right up i h
            !base = j * 12
            vertex k sr su = do
              SM.write mv (base + k * 3) (cx + sr * hrx + su * hux)
              SM.write mv (base + k * 3 + 1) (cy + sr * hry + su * huy)
              SM.write mv (base + k * 3 + 2) (cz + sr * hrz + su * huz)
        vertex 0 (-1) (-1)
        vertex 1 1 (-1)
        vertex 2 1 1
        vertex 3 (-1) 1
      pure mv

    colors = S.create $ do
      mv <- SM.new (n * 16)
      forM_ [0 .. n - 1] $ \j -> do
        let (s, i) = order V.! j
            !packed = pbColor (qsBuffer (sources V.! s)) U.! i
            !base = j * 16
        forM_ [0 .. 3 :: Int] $ \k -> do
          SM.write mv (base + k * 4) (byteAt 24 packed)
          SM.write mv (base + k * 4 + 1) (byteAt 16 packed)
          SM.write mv (base + k * 4 + 2) (byteAt 8 packed)
          SM.write mv (base + k * 4 + 3) (byteAt 0 packed)
      pure mv

    texcoords = S.create $ do
      mv <- SM.new (n * 8)
      forM_ [0 .. n - 1] $ \j -> do
        let (s, _) = order V.! j
            (u0, v0, u1, v1) = qsRect (sources V.! s)
            !base = j * 8
        SM.write mv base u0
        SM.write mv (base + 1) v0
        SM.write mv (base + 2) u1
        SM.write mv (base + 3) v0
        SM.write mv (base + 4) u1
        SM.write mv (base + 5) v1
        SM.write mv (base + 6) u0
        SM.write mv (base + 7) v1
      pure mv

-- | Static triangle index pattern for @cap@ quads: @0,1,2, 0,2,3@ per
-- quad. Written to the GPU once at mesh upload; the per-frame particle
-- count is expressed by the draw length, not by re-uploading indices.
--
-- @cap*4 <= 65536@ is required for 'Word16' indices (func-spec 0005 §0.2
-- point 5: the 4096-particle budget cap needs 16384 vertices).
quadIndices :: Int -> S.Vector Word16
quadIndices cap = S.generate (cap * 6) idx
  where
    idx j =
      let (q, k) = j `divMod` 6
          v = case k of
            0 -> 0
            1 -> 1
            2 -> 2
            3 -> 0
            4 -> 2
            _ -> 3
       in fromIntegral (q * 4 + v)

-- | Static texture coordinates for @cap@ quads: every quad maps its four
-- corners onto the whole [0,1]² sprite, in 'buildQuads'' vertex order
-- @(-r,-u), (+r,-u), (+r,+u), (-r,+u)@ → @(0,0), (1,0), (1,1), (0,1)@.
--
-- Like 'quadIndices' this is a pure function of the capacity, not of any
-- frame's particles (func-spec 0015 S4): written to the GPU once at mesh
-- upload, never updated — which is why 'QuadBatch' carries no texcoords
-- and the per-frame upload cost is untouched.
quadTexcoords :: Int -> S.Vector Float
quadTexcoords cap = S.generate (cap * 8) uv
  where
    uv j =
      let (_, k) = j `divMod` 8
       in case k of
            0 -> 0 -- (0,0)
            1 -> 0
            2 -> 1 -- (1,0)
            3 -> 0
            4 -> 1 -- (1,1)
            5 -> 1
            6 -> 0 -- (0,1)
            _ -> 1

byteAt :: Int -> Word32 -> Word8
byteAt bits c = fromIntegral ((c `shiftR` bits) .&. 0xFF)

sub :: V3 -> V3 -> V3
sub (V3 ax ay az) (V3 bx by bz) = V3 (ax - bx) (ay - by) (az - bz)

dot :: V3 -> V3 -> Float
dot (V3 ax ay az) (V3 bx by bz) = ax * bx + ay * by + az * bz

cross :: V3 -> V3 -> V3
cross (V3 ax ay az) (V3 bx by bz) =
  V3 (ay * bz - az * by) (az * bx - ax * bz) (ax * by - ay * bx)

scale :: Float -> V3 -> V3
scale k (V3 x y z) = V3 (k * x) (k * y) (k * z)

norm :: V3 -> Float
norm (V3 x y z) = sqrt (x * x + y * y + z * z)

normalizeOr :: V3 -> V3 -> V3
normalizeOr fallback v
  | n < 1e-6 = fallback
  | otherwise = scale (1 / n) v
  where
    n = norm v
