{-# LANGUAGE BangPatterns #-}

-- | Flat (2D) staging (func-spec 0008 §4.3): the pure half of the
-- orthographic render path, mirroring what 'App.Render.Quads' does for
-- the 3D one.
--
-- The split follows architecture §8.6: the projection strategy — which
-- axis is dropped, and in which order the particles must be drawn — is
-- core business ('Magic.Project'); the screen mapping (origin,
-- pixels-per-unit, the y-flip) is a shell presentation choice and lives
-- here. Output is the 0005 'QuadBatch', so the IO side uploads and draws
-- it with exactly the same code the 3D path uses.
--
-- Quads are emitted in painter's order (far to near), so drawing them
-- back to front needs no depth buffer — which is precisely what a 2D host
-- would do with our output.
module App.Render.Flat
  ( buildFlatQuads
  , screenOf
  ) where

import Control.Monad (forM_)
import Data.Bits (shiftR, (.&.))
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as SM
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word8)
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
import Magic.Projection (V2 (..), depthOrder, orthographic)

import App.Effects (FlatView (..))
import App.Render.Quads (QuadBatch (..))

-- | Where a world point lands on screen, in pixels: the plane
-- coordinates scaled by 'fvPixelsPerUnit' around 'fvOrigin', with the y
-- axis flipped so world-up is screen-up.
screenOf :: FlatView -> V3 -> (Float, Float)
screenOf fv v = (ox + px * ppu, oy - py * ppu)
  where
    (V2 px py, _) = orthographic (fvPlane fv) v
    (ox, oy) = fvOrigin fv
    ppu = fvPixelsPerUnit fv

-- | Expand every particle into an axis-aligned screen-space quad, in
-- painter's order.
--
-- Vertices are @z = 0@ pixel coordinates: raylib's default (2D) state is
-- already a screen-pixel orthographic projection with depth testing off,
-- so the same dynamic mesh draws them unchanged.
--
-- Vertex order per particle is the 'App.Render.Quads' one — @(-r,-u),
-- (+r,-u), (+r,+u), (-r,+u)@ with half-extent @pbSize*ppu/2@ — so the
-- static index pattern still applies. The y-flip turns that winding
-- clockwise on screen, which is why the IO side disables backface
-- culling around the draw.
buildFlatQuads :: FlatView -> ParticleBuffer -> QuadBatch
buildFlatQuads fv pb =
  QuadBatch {qbPositions = positions, qbColors = colors, qbCount = n}
  where
    n = pbCount pb
    order = depthOrder (fvPlane fv) pb
    ppu = fvPixelsPerUnit fv

    positions = S.create $ do
      mv <- SM.new (n * 12)
      forM_ [0 .. n - 1] $ \j -> do
        let !i = order U.! j
            (!sx, !sy) =
              screenOf fv (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i))
            !h = (pbSize pb U.! i) * ppu * 0.5
            !base = j * 12
            -- su is the world-up sign, so it subtracts on screen.
            vertex k sr su = do
              SM.write mv (base + k * 3) (sx + sr * h)
              SM.write mv (base + k * 3 + 1) (sy - su * h)
              SM.write mv (base + k * 3 + 2) 0
        vertex 0 (-1) (-1)
        vertex 1 1 (-1)
        vertex 2 1 1
        vertex 3 (-1) 1
      pure mv

    colors = S.create $ do
      mv <- SM.new (n * 16)
      forM_ [0 .. n - 1] $ \j -> do
        let !packed = pbColor pb U.! (order U.! j)
            !base = j * 16
        forM_ [0 .. 3 :: Int] $ \k -> do
          SM.write mv (base + k * 4) (byteAt 24 packed)
          SM.write mv (base + k * 4 + 1) (byteAt 16 packed)
          SM.write mv (base + k * 4 + 2) (byteAt 8 packed)
          SM.write mv (base + k * 4 + 3) (byteAt 0 packed)
      pure mv

byteAt :: Int -> Word32 -> Word8
byteAt bits c = fromIntegral ((c `shiftR` bits) .&. 0xFF)
