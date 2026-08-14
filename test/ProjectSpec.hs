-- | S1 (func-spec 0008 §8): the core projection surface.
--
-- Imported through 'Magic.Projection', the boundary re-export, so this
-- module doubles as proof that the shell's only doorway to the core
-- projection actually works — the executable may not depend on
-- magic-core (@BoundarySpec@).
--
-- Two laws carry the whole 2D story: 'orthographic' is a bit-exact
-- component selection (no arithmetic to drift), and 'depthOrder' is a
-- stable far-to-near permutation (deterministic painter's order).
module ProjectSpec (spec) where

import Data.List (sort)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Particle.Buffer (ParticleBuffer (..), emptyBuffer, fromParticles)
import Magic.Projection (ViewPlane (..), depthOrder, orthographic, project)
import Magic.Types (V2 (..), V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Tame coordinates: the laws are exact, and bounded inputs keep the
-- generated buffers small enough to shrink usefully.
newtype Coord = Coord Float
  deriving (Show)

instance Arbitrary Coord where
  arbitrary = Coord <$> choose (-100, 100)

genV3 :: Gen V3
genV3 = V3 <$> coord <*> coord <*> coord
  where
    coord = choose (-100, 100)

-- | Particles whose depths collide often, so stability is actually
-- exercised: z (and y) are drawn from a tiny set of values.
newtype Particles = Particles [(V3, Float, Float, Word32)]
  deriving (Show)

instance Arbitrary Particles where
  arbitrary = do
    n <- choose (0, 30)
    Particles <$> vectorOf n particle
    where
      particle = do
        x <- choose (-100, 100)
        y <- elements [-2, -1, 0, 1, 2, 3.5]
        z <- elements [-2, -1, 0, 1, 2, 3.5]
        s <- choose (0.01, 5)
        l <- choose (0, 1)
        c <- arbitrary
        pure (V3 x y z, s, l, c)

bufferOf :: Particles -> ParticleBuffer
bufferOf (Particles ps) = fromParticles ps

posAt :: ParticleBuffer -> Int -> V3
posAt pb i = V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i)

depthAt :: ViewPlane -> ParticleBuffer -> Int -> Float
depthAt plane pb i = snd (orthographic plane (posAt pb i))

-- | Both planes, as a generator rather than an 'Arbitrary' instance:
-- 'ViewPlane' is the core's type, so an instance here would be an orphan
-- and would collide with the one 'FlatQuadSpec' needs.
genPlane :: Gen ViewPlane
genPlane = elements [SideXY, TopXZ]

-- | Sorted-descending, but only asserting non-increase: the permutation
-- is what is being tested, not the comparison operator.
nonIncreasing :: [Float] -> Bool
nonIncreasing ds = and (zipWith (>=) ds (drop 1 ds))

spec :: Spec
spec = describe "Magic.Project (func-spec 0008 §4.1), through the boundary re-export" $ do
  describe "project stays the identity (0001 frozen stub = the 3D case)" $ do
    prop "returns its argument unchanged, componentwise" $
      forAll genV3 $ \v -> project v === v

  describe "orthographic" $ do
    prop "SideXY selects (x, y) and depth -z, bit for bit" $
      \(Coord x) (Coord y) (Coord z) ->
        orthographic SideXY (V3 x y z) === (V2 x y, negate z)

    prop "TopXZ selects (x, z) and depth -y, bit for bit" $
      \(Coord x) (Coord y) (Coord z) ->
        orthographic TopXZ (V3 x y z) === (V2 x z, negate y)

    it "the depth convention is 'larger is further away'" $ do
      -- SideXY looks from +Z towards -Z, so a smaller z is further.
      snd (orthographic SideXY (V3 0 0 (-5)))
        `shouldSatisfy` (> snd (orthographic SideXY (V3 0 0 5)))
      -- TopXZ looks down from +Y, so a smaller y is further.
      snd (orthographic TopXZ (V3 0 (-5) 0))
        `shouldSatisfy` (> snd (orthographic TopXZ (V3 0 5 0)))

  describe "depthOrder" $ do
    prop "is a permutation of [0 .. pbCount-1]" $ \ps ->
      forAll genPlane $ \plane ->
      let pb = bufferOf ps
       in sort (U.toList (depthOrder plane pb)) === [0 .. pbCount pb - 1]

    prop "orders the particles far to near" $ \ps ->
      forAll genPlane $ \plane ->
      let pb = bufferOf ps
          order = U.toList (depthOrder plane pb)
       in property (nonIncreasing (map (depthAt plane pb) order))

    prop "is stable: equal depths keep their buffer order" $ \ps ->
      forAll genPlane $ \plane ->
      let pb = bufferOf ps
          order = U.toList (depthOrder plane pb)
          groups d = [i | i <- order, depthAt plane pb i == d]
          depths = [depthAt plane pb i | i <- [0 .. pbCount pb - 1]]
       in conjoin [property (groups d == sort (groups d)) | d <- depths]

    it "an empty buffer produces an empty permutation" $ do
      U.toList (depthOrder SideXY emptyBuffer) `shouldBe` []
      U.toList (depthOrder TopXZ emptyBuffer) `shouldBe` []

    it "the two planes really disagree: the same buffer sorts differently" $ do
      -- Particle 0 is far in the side view and near in the top view.
      let pb =
            fromParticles
              [ (V3 0 0 (-5), 1, 1, 0xFFFFFFFF)
              , (V3 0 (-5) 5, 1, 1, 0xFFFFFFFF)
              ]
      U.toList (depthOrder SideXY pb) `shouldBe` [0, 1]
      U.toList (depthOrder TopXZ pb) `shouldBe` [1, 0]
