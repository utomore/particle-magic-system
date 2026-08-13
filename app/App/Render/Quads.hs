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
  , billboardBasis
  , quadIndices
  ) where

import Control.Monad (forM_)
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
  QuadBatch {qbPositions = positions, qbColors = colors, qbCount = n}
  where
    n = pbCount pb
    (V3 rx ry rz, V3 ux uy uz) = billboardBasis camPos camTarget camUp

    positions = S.create $ do
      mv <- SM.new (n * 12)
      forM_ [0 .. n - 1] $ \i -> do
        let !cx = pbPosX pb U.! i
            !cy = pbPosY pb U.! i
            !cz = pbPosZ pb U.! i
            !h = (pbSize pb U.! i) * 0.5
            !hrx = rx * h
            !hry = ry * h
            !hrz = rz * h
            !hux = ux * h
            !huy = uy * h
            !huz = uz * h
            !base = i * 12
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
      forM_ [0 .. n - 1] $ \i -> do
        let !packed = pbColor pb U.! i
            !base = i * 16
        forM_ [0 .. 3 :: Int] $ \k -> do
          SM.write mv (base + k * 4) (byteAt 24 packed)
          SM.write mv (base + k * 4 + 1) (byteAt 16 packed)
          SM.write mv (base + k * 4 + 2) (byteAt 8 packed)
          SM.write mv (base + k * 4 + 3) (byteAt 0 packed)
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

byteAt :: Int -> Word32 -> Word8
byteAt bits c = fromIntegral ((c `shiftR` bits) .&. 0xFF)

sub :: V3 -> V3 -> V3
sub (V3 ax ay az) (V3 bx by bz) = V3 (ax - bx) (ay - by) (az - bz)

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
