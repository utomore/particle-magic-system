-- | S1 (func-spec 0013 §7): view-space depth ordering for the 3D path.
--
-- Two contracts are pinned here. The permutation one — 'viewOrder' is a
-- real permutation, far to near, stable — mirrors what @ProjectSpec@
-- asserts about 'Magic.Projection.depthOrder', because the shell-side
-- camera variant has to be exactly as trustworthy as the core-side axis
-- one. And the compatibility one: 'buildQuadsOrdered' handed the
-- identity permutation is 'buildQuads', bit for bit, so introducing the
-- sort cannot have changed what an already-ordered frame looks like.
module OrderSpec (spec) where

import Data.List (sort)
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Interface
  ( BillboardShape (..)
  , BlendMode (..)
  , RenderBatch (..)
  , V3 (..)
  )
import Magic.Particle.Buffer (ParticleBuffer (..), emptyBuffer, fromParticles)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Effects (Camera (..))
import App.Render.Order (identityOrder, orderedQuads, viewOrder)
import App.Render.Quads (QuadBatch (..), buildQuads, buildQuadsOrdered)

-- | A camera down the @-Z@ axis: view depth is then simply @-z@ offset
-- from the eye, which makes the expected order readable by hand.
downZ :: Camera
downZ =
  Camera
    { camPos = V3 0 0 10
    , camTarget = V3 0 0 0
    , camUp = V3 0 1 0
    , camFovY = 45
    }

-- | An off-axis camera, so the tests do not accidentally only cover the
-- case where the view axis is a coordinate axis.
oblique :: Camera
oblique = downZ {camPos = V3 6 4 6, camTarget = V3 0 2 0}

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

bufferOf :: Particles -> ParticleBuffer
bufferOf (Particles ps) = fromParticles ps

-- | The depth key 'viewOrder' sorts on, recomputed independently.
viewDepth :: Camera -> ParticleBuffer -> Int -> Float
viewDepth cam pb i = (px - ex) * fx + (py - ey) * fy + (pz - ez) * fz
  where
    (px, py, pz) = (pbPosX pb U.! i, pbPosY pb U.! i, pbPosZ pb U.! i)
    V3 ex ey ez = camPos cam
    V3 tx ty tz = camTarget cam
    (dx, dy, dz) = (tx - ex, ty - ey, tz - ez)
    n = sqrt (dx * dx + dy * dy + dz * dz)
    (fx, fy, fz) = (dx / n, dy / n, dz / n)

batchOf :: BlendMode -> ParticleBuffer -> RenderBatch
batchOf blend pb =
  RenderBatch {rbParticles = pb, rbBlend = blend, rbShape = BillboardSquare}

quadsFor :: Camera -> ParticleBuffer -> QuadBatch
quadsFor cam = buildQuads (camPos cam) (camTarget cam) (camUp cam)

spec :: Spec
spec = do
  describe "viewOrder (func-spec 0013 §2)" $ do
    prop "is a permutation of the buffer's indices" $ \ps ->
      forAll (elements [downZ, oblique]) $ \cam ->
        let pb = bufferOf ps
         in sort (U.toList (viewOrder cam pb)) === [0 .. pbCount pb - 1]

    prop "emits far to near: the depth key never increases" $ \ps ->
      forAll (elements [downZ, oblique]) $ \cam ->
        let pb = bufferOf ps
            depths = map (viewDepth cam pb) (U.toList (viewOrder cam pb))
         in property (and (zipWith (>=) depths (drop 1 depths)))

    it "is stable: particles at the same depth keep their buffer order" $ do
      -- All four sit on the same plane facing the camera, so every depth
      -- key is equal and only the tie-break decides.
      let pb = fromParticles [(V3 (fromIntegral k) 0 0, 1, 1, 0) | k <- [0 .. 3 :: Int]]
      U.toList (viewOrder downZ pb) `shouldBe` [0, 1, 2, 3]

    it "puts the furthest particle first, whatever slot it came in" $ do
      let pb =
            fromParticles
              [ (V3 0 0 5, 1, 1, 0) -- nearest to a camera at z = 10
              , (V3 0 0 (-5), 1, 1, 0) -- furthest
              , (V3 0 0 0, 1, 1, 0)
              ]
      U.toList (viewOrder downZ pb) `shouldBe` [1, 2, 0]

    it "sorts along the view axis, not by distance to the camera" $ do
      -- Both are 5 units from the eye; only the one further along the
      -- view direction is 'further away' for compositing.
      let pb =
            fromParticles
              [ (V3 5 0 10, 1, 1, 0) -- beside the camera: depth 0
              , (V3 0 0 5, 1, 1, 0) -- straight ahead: depth 5
              ]
      U.toList (viewOrder downZ pb) `shouldBe` [1, 0]

    it "a camera sitting on its target still yields a total order" $ do
      let degenerate = downZ {camPos = V3 0 0 0}
          pb = fromParticles [(V3 0 0 (-3), 1, 1, 0), (V3 0 0 1, 1, 1, 0)]
      sort (U.toList (viewOrder degenerate pb)) `shouldBe` [0, 1]

    it "an empty buffer orders to an empty permutation" $
      U.toList (viewOrder downZ emptyBuffer) `shouldBe` []

  describe "buildQuadsOrdered (func-spec 0013 §3)" $ do
    prop "with the identity permutation it IS buildQuads, bit for bit" $ \ps ->
      forAll (elements [downZ, oblique]) $ \cam ->
        let pb = bufferOf ps
            plain = quadsFor cam pb
            ordered =
              buildQuadsOrdered
                (identityOrder (pbCount pb))
                (camPos cam)
                (camTarget cam)
                (camUp cam)
                pb
         in qbCount ordered === qbCount plain
              .&&. S.toList (qbPositions ordered) === S.toList (qbPositions plain)
              .&&. S.toList (qbColors ordered) === S.toList (qbColors plain)

    prop "keeps the 0005 QuadBatch length invariants under any order" $ \ps ->
      let pb = bufferOf ps
          qb = buildQuadsOrdered (viewOrder oblique pb) (camPos oblique) (camTarget oblique) (camUp oblique) pb
       in qbCount qb === pbCount pb
            .&&. S.length (qbPositions qb) === pbCount pb * 4 * 3
            .&&. S.length (qbColors qb) === pbCount pb * 4 * 4

    prop "is a permutation of the quads: same multiset, different order" $ \ps ->
      let pb = bufferOf ps
          plain = quadsFor oblique pb
          sorted = buildQuadsOrdered (viewOrder oblique pb) (camPos oblique) (camTarget oblique) (camUp oblique) pb
          quadsOf qb = sort [S.toList (S.slice (j * 12) 12 (qbPositions qb)) | j <- [0 .. qbCount qb - 1]]
       in quadsOf sorted === quadsOf plain

    it "emits the far particle's quad first" $ do
      let far = 0x0000FFFF
          near = 0xFF0000FF
          pb = fromParticles [(V3 0 0 5, 1, 1, near), (V3 0 0 (-5), 1, 1, far)]
          qb = buildQuadsOrdered (viewOrder downZ pb) (camPos downZ) (camTarget downZ) (camUp downZ) pb
      -- First quad's first vertex colour is the far particle's blue.
      [qbColors qb S.! k | k <- [0 .. 3]] `shouldBe` [0x00, 0x00, 0xFF, 0xFF]

  describe "orderedQuads: which batches are sorted at all" $ do
    prop "an alpha batch comes out in view order" $ \ps ->
      let pb = bufferOf ps
          expected =
            buildQuadsOrdered (viewOrder oblique pb) (camPos oblique) (camTarget oblique) (camUp oblique) pb
       in orderedQuads oblique (batchOf BlendAlpha pb) === expected

    prop "an additive batch is left in buffer order: the sum is the same either way" $ \ps ->
      let pb = bufferOf ps
       in orderedQuads oblique (batchOf BlendAdditive pb) === quadsFor oblique pb

    it "the two paths differ for a buffer that is not already sorted" $ do
      let pb = fromParticles [(V3 0 0 5, 1, 1, 0xFF0000FF), (V3 0 0 (-5), 1, 1, 0x0000FFFF)]
          alpha = orderedQuads downZ (batchOf BlendAlpha pb)
          additive = orderedQuads downZ (batchOf BlendAdditive pb)
      qbColors alpha `shouldNotBe` qbColors additive
