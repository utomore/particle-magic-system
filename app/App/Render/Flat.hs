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
  , buildFlatQuadsIn
  , screenOf
  , panBy
  , zoomAt
  , resizeTo
  , minPixelsPerUnit
  , maxPixelsPerUnit
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

-- | Slide the view by a screen-pixel delta: content follows the cursor,
-- which is what dragging a map does.
--
-- Only the origin moves, so the law is linearity —
-- @screenOf (panBy d fv) p == screenOf fv p + d@ — and a zero drag is
-- the identity on the nose.
panBy :: (Float, Float) -> FlatView -> FlatView
panBy (dx, dy) fv = fv {fvOrigin = (ox + dx, oy + dy)}
  where
    (ox, oy) = fvOrigin fv

-- | Wheel zoom about a screen point: @zoomAt cursor notches@ scales
-- 'fvPixelsPerUnit' and slides the origin so that the world point under
-- the cursor stays under the cursor.
--
-- That fixed-point law (@test\/FlatCameraSpec.hs@) is what makes zooming
-- feel like a magnifying glass instead of like a jump: every screen
-- position is @cursor + (position - cursor) * scale@, and at the cursor
-- itself the second term vanishes — exactly, not approximately, since
-- the origin is moved by the same factor the scale is.
zoomAt :: (Float, Float) -> Float -> FlatView -> FlatView
zoomAt (cx, cy) notches fv
  | notches == 0 = fv
  | otherwise =
      fv
        { fvPixelsPerUnit = ppu'
        , fvOrigin = (cx + (ox - cx) * s, cy + (oy - cy) * s)
        }
  where
    (ox, oy) = fvOrigin fv
    ppu = fvPixelsPerUnit fv
    ppu' = max minPixelsPerUnit (min maxPixelsPerUnit (ppu * (zoomPerNotch ** notches)))
    -- Derived from the clamped result, so a zoom that hits the stop
    -- still keeps its fixed point rather than sliding under the cursor.
    s = if ppu > 0 then ppu' / ppu else 1

-- | Follow a window resize, keeping whatever is in the middle of the
-- screen in the middle of the screen. Resizing to the same size is the
-- identity, so a demo nobody resizes renders exactly what it did before
-- the window became resizable.
resizeTo :: (Int, Int) -> FlatView -> FlatView
resizeTo (w, h) fv
  | (w, h) == fvScreenSize fv = fv
  | otherwise =
      fv
        { fvScreenSize = (w, h)
        , fvOrigin = (ox + (fromIntegral w - fromIntegral w0) * 0.5, oy + (fromIntegral h - fromIntegral h0) * 0.5)
        }
  where
    (w0, h0) = fvScreenSize fv
    (ox, oy) = fvOrigin fv

-- | Zoom range, in pixels per world unit. A spell is a couple of units
-- across, so this spans "the whole formation is a speck" to "one
-- particle fills the screen".
minPixelsPerUnit, maxPixelsPerUnit :: Float
minPixelsPerUnit = 5
maxPixelsPerUnit = 1200

-- | Scale factor of one wheel notch, multiplicative for the same reason
-- 'App.Camera.dolly' is.
zoomPerNotch :: Float
zoomPerNotch = 1.15

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
--
-- Colours are the buffer's, optionally darkened by depth
-- ('fvDepthTint'): the axis the projection drops carries no information
-- at all otherwise, which is what makes the top view read as a blob.
-- The darkening is linear in the batch's own depth range, so it uses the
-- full contrast the frame has to offer, and it touches RGB only — alpha
-- decides how much of the particle is there, which is not a depth cue
-- and must not become one. At the default tint of 0 the colour stream is
-- bit-identical to the untinted one (func-spec 0013 §1-4).
--
-- Func-spec 0021 S6 adds the second-tier cues, both of which move
-- /sizes/ and never positions: 'fvDepthScale' reintroduces the size
-- gradient orthographic projection deletes, and 'fvOutlineFloor' keeps
-- the result above the threshold where a quad stops having a readable
-- edge. Same discipline as the tint — at their defaults the geometry
-- stream is bit-identical to the pre-0021 one.
buildFlatQuads :: FlatView -> ParticleBuffer -> QuadBatch
buildFlatQuads fv = buildFlatQuadsIn fv (0, 0, 1, 1)

-- | 'buildFlatQuads' sampling a given rectangle of the texture rather
-- than the whole of it (func-spec 0023 S9).
--
-- The 2D path needs this for the same reason the 3D one does: since the
-- sprites moved into one atlas, "which shape is this" is carried by the
-- UVs. 'buildFlatQuads' keeps its own signature and passes the whole
-- texture, so every assertion written against it since func-spec 0008
-- still means what it meant.
buildFlatQuadsIn
  :: FlatView -> (Float, Float, Float, Float) -> ParticleBuffer -> QuadBatch
buildFlatQuadsIn fv (u0, v0, u1, v1) pb =
  QuadBatch
    { qbPositions = positions
    , qbColors = colors
    , qbTexcoords = texcoords
    , qbCount = n
    }
  where
    n = pbCount pb

    -- Same corner order as the 3D expansion, so one index buffer serves
    -- both paths.
    texcoords = S.create $ do
      mv <- SM.new (n * 8)
      forM_ [0 .. n - 1] $ \j -> do
        let !base = j * 8
        SM.write mv base u0
        SM.write mv (base + 1) v0
        SM.write mv (base + 2) u1
        SM.write mv (base + 3) v0
        SM.write mv (base + 4) u1
        SM.write mv (base + 5) v1
        SM.write mv (base + 6) u0
        SM.write mv (base + 7) v1
      pure mv
    order = depthOrder (fvPlane fv) pb
    ppu = fvPixelsPerUnit fv

    positions = S.create $ do
      mv <- SM.new (n * 12)
      forM_ [0 .. n - 1] $ \j -> do
        let !i = order U.! j
            (!sx, !sy) =
              screenOf fv (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i))
            !h = halfExtentAt i
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
        let !i = order U.! j
            !packed = pbColor pb U.! i
            !shade = shadeAt i
            !base = j * 16
        forM_ [0 .. 3 :: Int] $ \k -> do
          SM.write mv (base + k * 4) (dim shade (byteAt 24 packed))
          SM.write mv (base + k * 4 + 1) (dim shade (byteAt 16 packed))
          SM.write mv (base + k * 4 + 2) (dim shade (byteAt 8 packed))
          SM.write mv (base + k * 4 + 3) (byteAt 0 packed)
      pure mv

    -- Brightness factor of a particle, in (0, 1]: 1 at the near end of
    -- the batch, 1-tint at the far end. Off (and so exactly 1) when the
    -- tint is zero or the batch has no depth range to normalise against
    -- — including the single-particle case, where "far" and "near" are
    -- the same particle.
    tint = max 0 (min 1 (fvDepthTint fv))
    (dNear, dFar)
      | n == 0 = (0, 0)
      | otherwise = (depthOf (order U.! (n - 1)), depthOf (order U.! 0))
    range = dFar - dNear
    shadeAt i
      | tint <= 0 || range <= 0 = 1
      | otherwise = 1 - tint * ((depthOf i - dNear) / range)
    depthOf i =
      snd (orthographic (fvPlane fv) (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i)))

    -- Depth as a fraction of the batch's own range: 0 at the near end,
    -- 1 at the far end — the same normalisation 'shadeAt' uses, so the
    -- two cues agree about which particle is in front.
    depthFrac i = (depthOf i - dNear) / range

    -- Second-tier top-view readability (func-spec 0021 S6).
    --
    -- Zero-ripple law, the convention func-spec 0013 set for the tint:
    -- with both knobs at their defaults the whole thing branches away
    -- rather than multiplying by one, so the geometry stream is the one
    -- func-spec 0008 shipped, bit for bit — not merely equal to it.
    flatten = fvDepthScale fv
    outline = fvOutlineFloor fv
    readabilityOff = flatten == 1 && outline <= 0

    halfExtentAt i
      | readabilityOff = plain
      | otherwise = max (outline * 0.5) (plain * flattenAt i)
      where
        plain = (pbSize pb U.! i) * ppu * 0.5

    -- k at the near end, 1/k at the far end, 1 in the middle: a size
    -- gradient the orthographic projection cannot produce on its own,
    -- because it maps every depth to the same scale by definition. The
    -- exponent is linear in depth, so the ordering is preserved exactly.
    --
    -- Off (and so exactly 1) when the batch has no depth range to
    -- normalise against — the same guard 'shadeAt' takes, and for the
    -- same reason: with every particle at one depth there is no gradient
    -- to show, and scaling them all by the near-end factor would be a
    -- depth cue announcing a depth that is not there.
    flattenAt i
      | flatten <= 0 || range <= 0 = 1
      | otherwise = flatten ** (1 - 2 * depthFrac i)

-- | Scale a colour channel by a brightness factor. A factor of exactly 1
-- is the identity on every byte (@round (fromIntegral b * 1) == b@ for
-- all of @0..255@), which is what makes the untinted path bit-compatible
-- with func-spec 0008's output.
dim :: Float -> Word8 -> Word8
dim f b
  | f >= 1 = b
  | otherwise = fromIntegral (max 0 (min 255 (round (fromIntegral b * f) :: Int)))

byteAt :: Int -> Word32 -> Word8
byteAt bits c = fromIntegral ((c `shiftR` bits) .&. 0xFF)
