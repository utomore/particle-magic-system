-- | Procedurally generated billboard sprites (func-spec 0015 S4): the
-- pure pixels behind the shell's per-shape textures. No image assets, no
-- file paths — a host integrating the core never learns these exist.
--
-- The RGB channels are always 255: all the shape information lives in
-- alpha, so the vertex color the default raylib shader multiplies in
-- stays the only source of color, and 'Magic.Compile.ColorRamp' keeps its
-- meaning ('BillboardSquare' proves the rule by not even having a
-- texture — the default material's 1×1 white one is the identity of this
-- scheme).
--
-- Everything here is a pure function of @(shape, resolution)@, which is
-- what makes the S4 risk testable headless (@test\/SpriteSpec.hs@); the
-- IO side only uploads the three non-square results once at startup.
-- Func-spec 0023 S9 adds the atlas. Every shape's sprite is packed into
-- one texture side by side, so a draw no longer has to bind a particular
-- shape's texture — which is what lets particles of /different/ shapes
-- share a single draw call and therefore a single depth sort. The
-- per-shape pixels are unchanged: 'atlasTexels' places exactly what
-- 'spriteTexels' produces, and 'spriteTexels' is still the definition.
module App.Render.Sprite
  ( spriteSize
  , spriteTexels

    -- * The atlas (func-spec 0023 S9)
  , atlasShapes
  , atlasSize
  , atlasTexels
  , atlasRect
  ) where

import qualified Data.Vector.Storable as S
import Data.Word (Word8)
import Magic.Interface (BillboardShape (..))

-- | Texture edge length the demo uploads at: 64×64 RGBA = 16 KB a sprite.
spriteSize :: Int
spriteSize = 64

-- | The @n@×@n@ RGBA texels of a shape, row-major from the top-left,
-- 4 bytes a pixel (length @n*n*4@).
spriteTexels :: BillboardShape -> Int -> S.Vector Word8
spriteTexels shape n = S.generate (n * n * 4) texel
  where
    texel j =
      let (pixel, channel) = j `divMod` 4
          (row, col) = pixel `divMod` n
       in if channel < 3 then 255 else alphaAt shape n col row

-- | Alpha of the pixel at @(col, row)@, from the shape's profile over the
-- pixel-center coordinates mapped to [-1, 1]².
alphaAt :: BillboardShape -> Int -> Int -> Int -> Word8
alphaAt shape n col row = case shape of
  -- Fully opaque: with the default shader this is indistinguishable from
  -- the textureless pre-0015 quad, which is the opt-in law's IO half.
  BillboardSquare -> 255
  -- Radial falloff, monotone in r, saturated (255) inside r <= 0.1 so the
  -- center is exactly full despite pixel centers never hitting r = 0.
  BillboardSoftDot -> quantize (clamp01 ((1 - r) / 0.9) ^ (2 :: Int))
  -- A band peaking at r = 0.5, soft on both flanks.
  BillboardRing -> quantize (clamp01 (1 - abs (r - 0.5) / 0.18) ^ (2 :: Int))
  -- Two perpendicular rays through the center: thin across, fading along.
  BillboardSpark -> quantize (max (ray x y) (ray y x))
  -- The comet profile (func-spec 0023 S6). Read on a quad that
  -- 'App.Render.Quads' has already stretched along the particle's
  -- velocity, so +x is the direction of travel: opaque at the head,
  -- fading linearly to nothing at the tail, and soft across its width.
  --
  -- The gradient lives in the sprite rather than in the geometry because
  -- the geometry is four vertices and a trail needs to fade along its
  -- length — the same division of labour every shape here follows, and
  -- the reason the vertex color still carries all the colour.
  BillboardTrail -> quantize (clamp01 ((x + 1) / 2) * (clamp01 (1 - abs y) ^ (2 :: Int)))
  where
    x = pixelCenter n col
    y = pixelCenter n row
    r = sqrt (x * x + y * y)
    ray along across =
      (clamp01 (1 - abs across / 0.14) ^ (2 :: Int)) * clamp01 (1 - abs along)
    quantize a = round (255 * a)
    clamp01 v = max 0 (min 1 v)

pixelCenter :: Int -> Int -> Double
pixelCenter n i = (2 * (fromIntegral i + 0.5) / fromIntegral n) - 1

-- The atlas (func-spec 0023 S9) ----------------------------------------------

-- | Every shape, in wire-code order, each occupying one cell of the
-- atlas strip.
--
-- 'BillboardSquare' is included even though it is a solid block of
-- opaque pixels. Before the atlas it was the one shape with /no/ texture
-- (it used the default material's 1×1 white one, which is why it cost
-- nothing); now that all shapes share one texture there is no such thing
-- as "no texture", and giving the square its own cell is what lets a
-- square particle and a soft dot sit in the same draw call. That is the
-- whole point of the atlas.
atlasShapes :: [BillboardShape]
atlasShapes = [minBound .. maxBound]

-- | Atlas dimensions in pixels: a horizontal strip, one 'spriteSize' cell
-- per shape.
--
-- A strip rather than a grid because the strip's arithmetic is one
-- division and its growth is one direction: a sixth shape appends a cell
-- and moves nobody's UVs but its own, which is the same append-only rule
-- the wire codes follow (ADR-0013).
atlasSize :: (Int, Int)
atlasSize = (spriteSize * length atlasShapes, spriteSize)

-- | The whole atlas as RGBA texels, row-major from the top-left.
--
-- Each cell is exactly what 'spriteTexels' produces for that shape, so
-- the atlas cannot disagree with the per-shape definition — it places it
-- rather than reimplementing it.
atlasTexels :: S.Vector Word8
atlasTexels = S.generate (width * height * 4) texel
  where
    (width, height) = atlasSize
    n = spriteSize

    texel j =
      let (pixel, channel) = j `divMod` 4
          (row, col) = pixel `divMod` width
          (cell, colInCell) = col `divMod` n
       in case drop cell atlasShapes of
            (shape : _) ->
              if channel < 3 then 255 else alphaAt shape n colInCell row
            -- Unreachable: width is exactly the cell count times the cell
            -- width. Transparent rather than an error, because a renderer
            -- must never be handed a partial texture.
            [] -> 0

-- | The UV rectangle of one shape's cell, as @(u0, v0, u1, v1)@.
--
-- Inset by half a texel on each side. Without the inset a bilinear sample
-- at a cell's edge reaches into its neighbour, and every soft dot would
-- pick up a sliver of the ring beside it — the classic atlas bleed, and
-- the reason a naive atlas looks subtly dirty.
atlasRect :: BillboardShape -> (Float, Float, Float, Float)
atlasRect shape = (u0 + inset, 0 + insetV, u1 - inset, 1 - insetV)
  where
    (width, height) = atlasSize
    cell = fromEnum shape
    u0 = fromIntegral (cell * spriteSize) / fromIntegral width
    u1 = fromIntegral ((cell + 1) * spriteSize) / fromIntegral width
    inset = 0.5 / fromIntegral width
    insetV = 0.5 / fromIntegral height
