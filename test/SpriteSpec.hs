-- | S4 (func-spec 0015 §7): the procedurally generated sprites and the
-- static texcoord stream — the whole headless half of the differentiated
-- render path. What the GPU then does with them is the S0/§9 manual
-- smoke; everything a pure function can promise is promised here:
--
--   * texel count is @n*n*4@;
--   * RGB is always 255 — the vertex color stays the only color source;
--   * 'BillboardSquare' is fully opaque (the opt-in law's IO half);
--   * 'BillboardSoftDot' fades monotonically with radius, full center;
--   * 'BillboardRing' peaks on the r ≈ 0.5 band;
--   * 'BillboardSpark' is mirror-symmetric about both axes;
--   * 'quadTexcoords' is @cap*8@ floats of the per-quad corner pattern.
module SpriteSpec (spec) where

import App.Render.Quads (quadTexcoords)
import App.Render.Sprite (spriteSize, spriteTexels)
import qualified Data.List as List
import qualified Data.Vector.Storable as S
import Data.Word (Word8)
import Magic.Interface (BillboardShape (..))
import Test.Hspec

shapes :: [BillboardShape]
shapes = [minBound .. maxBound]

-- | Alpha of the pixel at @(col, row)@ in an @n@×@n@ sprite.
alphaAt :: BillboardShape -> Int -> Int -> Int -> Word8
alphaAt shape n col row = spriteTexels shape n S.! (((row * n) + col) * 4 + 3)

-- | Pixel-center radius from the sprite center, in the [-1, 1]² frame the
-- sprites are defined over.
radiusAt :: Int -> Int -> Int -> Double
radiusAt n col row = sqrt (x * x + y * y)
  where
    x = (2 * (fromIntegral col + 0.5) / fromIntegral n) - 1
    y = (2 * (fromIntegral row + 0.5) / fromIntegral n) - 1

allPixels :: Int -> [(Int, Int)]
allPixels n = [(col, row) | row <- [0 .. n - 1], col <- [0 .. n - 1]]

n64 :: Int
n64 = spriteSize

spec :: Spec
spec = describe "procedural sprites and texcoords (func-spec 0015 S4)" $ do
  it "produces n*n*4 RGBA bytes, at the shipped size and others" $
    mapM_
      ( \shape ->
          mapM_
            (\n -> S.length (spriteTexels shape n) `shouldBe` n * n * 4)
            [16, 32, n64]
      )
      shapes

  it "keeps RGB at 255 everywhere: color comes from the vertices alone" $
    mapM_
      ( \shape -> do
          let texels = spriteTexels shape n64
              rgb = [texels S.! j | p <- [0 .. n64 * n64 - 1], c <- [0, 1, 2], let j = p * 4 + c]
          rgb `shouldSatisfy` all (== 255)
      )
      shapes

  it "Square is fully opaque — the textureless look, exactly" $ do
    let texels = spriteTexels BillboardSquare n64
    [texels S.! (p * 4 + 3) | p <- [0 .. n64 * n64 - 1]] `shouldSatisfy` all (== 255)

  it "SoftDot alpha is monotone non-increasing along the radius, 255 at the center" $ do
    let byRadius =
          List.sortOn fst
            [ (radiusAt n64 col row, alphaAt BillboardSoftDot n64 col row)
            | (col, row) <- allPixels n64
            ]
        alphas = map snd byRadius
    zipWith (>=) alphas (drop 1 alphas) `shouldSatisfy` and
    -- The four pixels around the exact center all sit inside the
    -- saturated cap, so the dot's center is genuinely full.
    let mid = n64 `div` 2
    [alphaAt BillboardSoftDot n64 c r | c <- [mid - 1, mid], r <- [mid - 1, mid]]
      `shouldSatisfy` all (== 255)

  it "Ring's brightest alpha sits on the r = 0.5 band" $ do
    let pixels =
          [ (radiusAt n64 col row, alphaAt BillboardRing n64 col row)
          | (col, row) <- allPixels n64
          ]
        peak = maximum (map snd pixels)
    peak `shouldSatisfy` (> 200)
    [r | (r, a) <- pixels, a == peak] `shouldSatisfy` all (\r -> r > 0.4 && r < 0.6)

  it "Spark is mirror-symmetric about both axes (and their swap)" $ do
    let a = alphaAt BillboardSpark n64
    mapM_
      ( \(col, row) -> do
          a col row `shouldBe` a (n64 - 1 - col) row
          a col row `shouldBe` a col (n64 - 1 - row)
          a col row `shouldBe` a row col
      )
      (allPixels n64)

  it "quadTexcoords is cap*8 floats of the per-quad corner pattern" $
    mapM_
      ( \cap -> do
          let uv = quadTexcoords cap
          S.length uv `shouldBe` cap * 8
          mapM_
            ( \q ->
                [uv S.! (q * 8 + k) | k <- [0 .. 7]]
                  `shouldBe` [0, 0, 1, 0, 1, 1, 0, 1]
            )
            [0 .. cap - 1]
      )
      [1, 3, 64]
