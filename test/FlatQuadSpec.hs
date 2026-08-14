-- | S2 (func-spec 0008 §8): the pure 2D staging.
--
-- 'buildFlatQuads' is the whole CPU side of the flat render path, so its
-- contract is pinned here rather than trusted to a look at the window:
-- the 0005 'QuadBatch' invariants still hold, every vertex is a flat
-- @z = 0@ pixel coordinate, the y axis is flipped (world up = screen up)
-- and the quads come out in painter's order.
module FlatQuadSpec (spec) where

import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word8)
import Magic.Particle.Buffer (ParticleBuffer (..), emptyBuffer, fromParticles)
import Magic.Projection (ViewPlane (..), depthOrder)
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Effects (FlatView (..))
import App.Render.Flat (buildFlatQuads, screenOf)
import App.Render.Quads (QuadBatch (..))

sideView :: FlatView
sideView =
  FlatView
    { fvPlane = SideXY
    , fvScreenSize = (1280, 720)
    , fvOrigin = (640, 576)
    , fvPixelsPerUnit = 60
    }

topView :: FlatView
topView = sideView {fvPlane = TopXZ, fvOrigin = (640, 360)}

newtype Particles = Particles [(V3, Float, Float, Word32)]
  deriving (Show)

instance Arbitrary Particles where
  arbitrary = do
    n <- choose (0, 30)
    Particles <$> vectorOf n particle
    where
      particle = do
        p <- V3 <$> choose (-8, 8) <*> choose (-8, 8) <*> choose (-8, 8)
        s <- choose (0.01, 2)
        l <- choose (0, 1)
        c <- arbitrary
        pure (p, s, l, c)

-- | Both planes, as a generator rather than an 'Arbitrary' instance: the
-- type is the core's, and an orphan instance would collide with the one
-- 'ProjectSpec' would need.
genPlane :: Gen ViewPlane
genPlane = elements [SideXY, TopXZ]

bufferOf :: Particles -> ParticleBuffer
bufferOf (Particles ps) = fromParticles ps

viewFor :: ViewPlane -> FlatView
viewFor SideXY = sideView
viewFor TopXZ = topView

vertexAt :: QuadBatch -> Int -> Int -> (Float, Float, Float)
vertexAt qb j k =
  (at base, at (base + 1), at (base + 2))
  where
    base = j * 12 + k * 3
    at = (qbPositions qb S.!)

centerOf :: QuadBatch -> Int -> (Float, Float)
centerOf qb j =
  (sumOf (\(x, _, _) -> x) * 0.25, sumOf (\(_, y, _) -> y) * 0.25)
  where
    sumOf f = sum [f (vertexAt qb j k) | k <- [0 .. 3]]

colorAt :: QuadBatch -> Int -> Int -> [Word8]
colorAt qb j k = [qbColors qb S.! (base + i) | i <- [0 .. 3]]
  where
    base = j * 16 + k * 4

expectedColor :: Word32 -> [Word8]
expectedColor c =
  [ fromIntegral (c `div` 0x1000000)
  , fromIntegral ((c `div` 0x10000) `mod` 0x100)
  , fromIntegral ((c `div` 0x100) `mod` 0x100)
  , fromIntegral (c `mod` 0x100)
  ]

posAt :: ParticleBuffer -> Int -> V3
posAt pb i = V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i)

close :: Float -> Float -> Float -> Bool
close eps a b = abs (a - b) <= eps * (1 + max (abs a) (abs b))

-- | Vertices are @screen position ± half extent@, so a quad's own edge
-- length is a difference of two numbers of screen magnitude: the
-- rounding error it carries is the position's, not the edge's. Bound the
-- tolerance by the magnitudes actually involved (the 0005 'QuadBatchSpec'
-- does the same for the 3D path).
nearPixels :: FlatView -> Float -> Float -> Float -> Bool
nearPixels fv screenMag a b = abs (a - b) <= 1e-4 * (1 + abs screenMag + fvPixelsPerUnit fv)

-- | @(quad slot, source particle)@ pairs, in emission order.
slots :: FlatView -> ParticleBuffer -> [(Int, Int)]
slots fv pb = zip [0 ..] (U.toList (depthOrder (fvPlane fv) pb))

spec :: Spec
spec = describe "flat (2D) quad staging (func-spec 0008 §4.3)" $ do
  prop "keeps the 0005 QuadBatch length invariants" $ \ps ->
    forAll genPlane $ \plane ->
    let pb = bufferOf ps
        qb = buildFlatQuads (viewFor plane) pb
     in qbCount qb === pbCount pb
          .&&. S.length (qbPositions qb) === pbCount pb * 4 * 3
          .&&. S.length (qbColors qb) === pbCount pb * 4 * 4

  prop "every vertex is flat: z = 0" $ \ps ->
    forAll genPlane $ \plane ->
    let qb = buildFlatQuads (viewFor plane) (bufferOf ps)
     in property (all (== 0) [z | j <- [0 .. qbCount qb - 1], k <- [0 .. 3], let (_, _, z) = vertexAt qb j k])

  prop "each quad is centred on its particle's screen position" $ \ps ->
    forAll genPlane $ \plane ->
    let fv = viewFor plane
        pb = bufferOf ps
        qb = buildFlatQuads fv pb
     in conjoin
          [ let (cx, cy) = centerOf qb j
                (sx, sy) = screenOf fv (posAt pb i)
             in property (close 1e-5 cx sx && close 1e-5 cy sy)
          | (j, i) <- slots fv pb
          ]

  prop "each quad is size*ppu across, axis aligned" $ \ps ->
    forAll genPlane $ \plane ->
    let fv = viewFor plane
        pb = bufferOf ps
        qb = buildFlatQuads fv pb
     in conjoin
          [ let side = (pbSize pb U.! i) * fvPixelsPerUnit fv
                (x0, y0, _) = vertexAt qb j 0
                (x1, y1, _) = vertexAt qb j 1
                (x2, y2, _) = vertexAt qb j 2
                near = nearPixels fv (max (abs x0) (abs y0))
             in property
                  ( near (abs (x1 - x0)) side
                      && near (abs (y2 - y1)) side
                      && near y0 y1
                      && near x1 x2
                  )
          | (j, i) <- slots fv pb
          ]

  prop "the colour stream follows the painter's order, not the buffer order" $ \ps ->
    forAll genPlane $ \plane ->
    let fv = viewFor plane
        pb = bufferOf ps
        qb = buildFlatQuads fv pb
     in conjoin
          [ property (all (\k -> colorAt qb j k == expectedColor (pbColor pb U.! i)) [0 .. 3])
          | (j, i) <- slots fv pb
          ]

  prop "doubling pixels-per-unit scales offsets from the origin by two" $ \ps ->
    forAll genPlane $ \plane ->
    let fv = viewFor plane
        fv2 = fv {fvPixelsPerUnit = fvPixelsPerUnit fv * 2}
        pb = bufferOf ps
        (qb, qb2) = (buildFlatQuads fv pb, buildFlatQuads fv2 pb)
        (ox, oy) = fvOrigin fv
     in conjoin
          [ let (x, y, _) = vertexAt qb j k
                (x2, y2, _) = vertexAt qb2 j k
             in property (close 1e-4 (x2 - ox) (2 * (x - ox)) && close 1e-4 (y2 - oy) (2 * (y - oy)))
          | j <- [0 .. qbCount qb - 1]
          , k <- [0 .. 3]
          ]

  describe "the y axis is flipped, so world up reads as screen up" $ do
    it "a particle above the caster sits above the side view's origin" $ do
      let pb = fromParticles [(V3 0 3 0, 1, 1, 0xFFFFFFFF)]
          qb = buildFlatQuads sideView pb
          (_, cy) = centerOf qb 0
      cy `shouldSatisfy` (< snd (fvOrigin sideView))
      abs (cy - (576 - 3 * 60)) `shouldSatisfy` (< 1e-3)

    it "in the top view it is +z that goes down the screen" $ do
      let pb = fromParticles [(V3 0 0 3, 1, 1, 0xFFFFFFFF)]
          qb = buildFlatQuads topView pb
          (_, cy) = centerOf qb 0
      cy `shouldSatisfy` (< snd (fvOrigin topView))

  describe "painter's order" $ do
    it "emits the far particle first, whichever buffer slot it is in" $ do
      -- Red is near (z = +5), blue is far (z = -5): blue must come first.
      let red = 0xFF0000FF
          blue = 0x0000FFFF
          pb =
            fromParticles
              [ (V3 0 0 5, 1, 1, red)
              , (V3 0 0 (-5), 1, 1, blue)
              ]
          qb = buildFlatQuads sideView pb
      colorAt qb 0 0 `shouldBe` expectedColor blue
      colorAt qb 1 0 `shouldBe` expectedColor red

    it "the same buffer emits in a different order under the top view" $ do
      let red = 0xFF0000FF
          blue = 0x0000FFFF
          pb =
            fromParticles
              [ (V3 0 0 5, 1, 1, red) -- near in side, low in top
              , (V3 0 5 (-5), 1, 1, blue) -- far in side, high in top
              ]
      colorAt (buildFlatQuads sideView pb) 0 0 `shouldBe` expectedColor blue
      colorAt (buildFlatQuads topView pb) 0 0 `shouldBe` expectedColor red

  it "an empty buffer produces empty streams instead of failing" $ do
    let qb = buildFlatQuads sideView emptyBuffer
    qbCount qb `shouldBe` 0
    S.length (qbPositions qb) `shouldBe` 0
    S.length (qbColors qb) `shouldBe` 0
