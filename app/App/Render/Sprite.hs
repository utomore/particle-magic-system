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
module App.Render.Sprite
  ( spriteSize
  , spriteTexels
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
