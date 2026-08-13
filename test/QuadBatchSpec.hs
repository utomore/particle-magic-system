-- | S2 (func-spec 0005 §8): the pure billboarding geometry.
--
-- 'buildQuads' is the whole CPU side of the render path, so its contract
-- is pinned down here rather than trusted to a look at the window: four
-- vertices centred on the particle, lying in the plane facing the camera,
-- one particle-size across, carrying the particle's color.
module QuadBatchSpec (spec) where

import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word8)
import Magic.Interface (V3 (..))
import Magic.Particle.Buffer (ParticleBuffer (..), emptyBuffer, fromParticles)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Render.Quads (QuadBatch (..), billboardBasis, buildQuads, quadIndices)

camPos, camTarget, camUp :: V3
camPos = V3 6 4 6
camTarget = V3 0 2 0
camUp = V3 0 1 0

-- | Particles with tame magnitudes: the geometry laws are exact in exact
-- arithmetic, and bounded inputs keep float error inside the epsilons.
newtype Particles = Particles [(V3, Float, Float, Word32)]
  deriving (Show)

instance Arbitrary Particles where
  arbitrary = do
    n <- choose (0, 40)
    Particles <$> vectorOf n particle
    where
      coord = choose (-50, 50)
      particle = do
        p <- V3 <$> coord <*> coord <*> coord
        s <- choose (0.01, 5)
        l <- choose (0, 1)
        c <- arbitrary
        pure (p, s, l, c)

bufferOf :: Particles -> ParticleBuffer
bufferOf (Particles ps) = fromParticles ps

build :: ParticleBuffer -> QuadBatch
build = buildQuads camPos camTarget camUp

-- Vector helpers ------------------------------------------------------------

vAdd, vSub :: V3 -> V3 -> V3
vAdd (V3 ax ay az) (V3 bx by bz) = V3 (ax + bx) (ay + by) (az + bz)
vSub (V3 ax ay az) (V3 bx by bz) = V3 (ax - bx) (ay - by) (az - bz)

vDot :: V3 -> V3 -> Float
vDot (V3 ax ay az) (V3 bx by bz) = ax * bx + ay * by + az * bz

vNorm :: V3 -> Float
vNorm v = sqrt (vDot v v)

vScale :: Float -> V3 -> V3
vScale k (V3 x y z) = V3 (k * x) (k * y) (k * z)

forwardOf :: V3 -> V3 -> V3
forwardOf pos target =
  let d = target `vSub` pos
   in vScale (1 / vNorm d) d

-- Accessors -----------------------------------------------------------------

vertexAt :: QuadBatch -> Int -> Int -> V3
vertexAt qb i k =
  V3 (at base) (at (base + 1)) (at (base + 2))
  where
    base = i * 12 + k * 3
    at = (qbPositions qb S.!)

colorAt :: QuadBatch -> Int -> Int -> [Word8]
colorAt qb i k = [qbColors qb S.! (base + j) | j <- [0 .. 3]]
  where
    base = i * 16 + k * 4

centerOf :: QuadBatch -> Int -> V3
centerOf qb i = vScale 0.25 (foldr1 vAdd (map (vertexAt qb i) [0 .. 3]))

particlePos :: ParticleBuffer -> Int -> V3
particlePos pb i = V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i)

-- | Packed RGBA, most significant byte first — the core's convention.
expectedColor :: Word32 -> [Word8]
expectedColor c =
  [ fromIntegral (c `div` 0x1000000)
  , fromIntegral ((c `div` 0x10000) `mod` 0x100)
  , fromIntegral ((c `div` 0x100) `mod` 0x100)
  , fromIntegral (c `mod` 0x100)
  ]

-- | Relative epsilon: coordinates run to ±50 with sizes up to 5, so a
-- fixed absolute epsilon would be either too tight or meaningless.
closeTo :: Float -> Float -> Float -> Bool
closeTo eps a b = abs (a - b) <= eps * (1 + max (abs a) (abs b))

-- | Vertices are @center ± offset@ in Float, so anything derived from a
-- difference of two vertices carries the center's rounding error, not the
-- quad's. Bound the tolerance by the magnitudes actually involved.
floatTolerance :: ParticleBuffer -> Int -> Float
floatTolerance pb i = 1e-4 * (pbSize pb U.! i + vNorm (particlePos pb i))

forEachParticle :: Particles -> (ParticleBuffer -> QuadBatch -> Int -> Bool) -> Property
forEachParticle ps k =
  let pb = bufferOf ps
      qb = build pb
   in conjoin [property (k pb qb i) | i <- [0 .. pbCount pb - 1]]

spec :: Spec
spec = describe "camera-facing quad expansion (func-spec 0005 §4.5)" $ do
  prop "one quad per particle, four vertices each" $ \ps ->
    let pb = bufferOf ps
        qb = build pb
     in qbCount qb === pbCount pb
          .&&. S.length (qbPositions qb) === pbCount pb * 4 * 3
          .&&. S.length (qbColors qb) === pbCount pb * 4 * 4

  prop "the four vertices average back to the particle position" $ \ps ->
    forEachParticle ps $ \pb qb i ->
      let V3 cx cy cz = centerOf qb i
          V3 px py pz = particlePos pb i
       in closeTo 1e-5 cx px && closeTo 1e-5 cy py && closeTo 1e-5 cz pz

  prop "both diagonals are perpendicular to the camera forward axis" $ \ps ->
    forEachParticle ps $ \pb qb i ->
      let fwd = forwardOf camPos camTarget
          d02 = vertexAt qb i 2 `vSub` vertexAt qb i 0
          d13 = vertexAt qb i 3 `vSub` vertexAt qb i 1
          tol = floatTolerance pb i
       in abs (vDot d02 fwd) <= tol && abs (vDot d13 fwd) <= tol

  prop "every edge is exactly the particle size long" $ \ps ->
    forEachParticle ps $ \pb qb i ->
      let s = pbSize pb U.! i
          tol = floatTolerance pb i
          edge a b = vNorm (vertexAt qb i b `vSub` vertexAt qb i a)
       in all (\e -> abs (edge (fst e) (snd e) - s) <= tol) [(0, 1), (1, 2), (2, 3), (3, 0)]

  prop "all four vertices carry the particle's RGBA" $ \ps ->
    forEachParticle ps $ \pb qb i ->
      let want = expectedColor (pbColor pb U.! i)
       in all (\k -> colorAt qb i k == want) [0 .. 3]

  it "an empty buffer produces empty streams instead of failing" $ do
    let qb = build emptyBuffer
    qbCount qb `shouldBe` 0
    S.length (qbPositions qb) `shouldBe` 0
    S.length (qbColors qb) `shouldBe` 0

  describe "billboard basis" $ do
    it "right and up are orthonormal and perpendicular to forward" $ do
      let (right, up) = billboardBasis camPos camTarget camUp
          fwd = forwardOf camPos camTarget
      vNorm right `shouldSatisfy` closeTo 1e-6 1
      vNorm up `shouldSatisfy` closeTo 1e-6 1
      abs (vDot right up) `shouldSatisfy` (< 1e-6)
      abs (vDot right fwd) `shouldSatisfy` (< 1e-6)
      abs (vDot up fwd) `shouldSatisfy` (< 1e-6)

    it "an up vector parallel to the view still yields a finite basis" $ do
      -- Looking straight down with up = +Y: the usual cross product is
      -- degenerate and must not produce NaNs.
      let (right, up) = billboardBasis (V3 0 10 0) (V3 0 0 0) (V3 0 1 0)
      vNorm right `shouldSatisfy` closeTo 1e-6 1
      vNorm up `shouldSatisfy` closeTo 1e-6 1
      abs (vDot right up) `shouldSatisfy` (< 1e-6)

    it "a zero-length view vector still yields a finite basis" $ do
      let (right, up) = billboardBasis (V3 1 1 1) (V3 1 1 1) (V3 0 1 0)
      vNorm right `shouldSatisfy` closeTo 1e-6 1
      vNorm up `shouldSatisfy` closeTo 1e-6 1

  describe "static index pattern" $ do
    it "is 0,1,2, 0,2,3 per quad, offset by four vertices each" $
      S.toList (quadIndices 3)
        `shouldBe` [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7, 8, 9, 10, 8, 10, 11]

    it "stays inside Word16 at the 4096-particle budget cap" $ do
      let idx = quadIndices 4096
      S.length idx `shouldBe` 4096 * 6
      S.maximum idx `shouldBe` 4096 * 4 - 1
