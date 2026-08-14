-- | S5 (func-spec 0010 §7): 'depthOrder' as an in-place introsort.
--
-- Func-spec 0008 froze the painter's permutation as a law, not as an
-- implementation: far to near, and equal depths keep their buffer order.
-- This round swaps 'Data.List.sortOn' for a hand-written introsort over
-- one unboxed @(depth, index)@ vector, so the obligation is to show the
-- new permutation is the /same/ permutation — which is what the reference
-- property below asserts, against the exact expression the old
-- implementation used.
--
-- The stability half deserves a note: the new comparison breaks ties on
-- the buffer index, so no two rows ever compare equal and the sorted
-- order is unique. Stability is therefore not a property of the algorithm
-- any more — it is a property of the ordering, which is why an unstable
-- quicksort is allowed to implement it. The generators below make depth
-- collisions the common case so that claim is actually exercised.
module DepthSortSpec (spec) where

import Data.List (sort, sortOn)
import Data.Ord (Down (..))
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Particle.Buffer (ParticleBuffer (..), emptyBuffer, fromParticles)
import Magic.Projection (ViewPlane (..), depthOrder, orthographic)
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Buffers whose depths collide constantly: z (and y) come from a tiny
-- set, so ties are the rule and the tie-break carries the ordering.
newtype Particles = Particles [(V3, Float, Float, Word32)]
  deriving (Show)

instance Arbitrary Particles where
  arbitrary = do
    n <- frequency [(1, pure 0), (1, pure 1), (6, choose (2, 400))]
    Particles <$> vectorOf n particle
    where
      particle = do
        x <- choose (-100, 100)
        y <- elements [-2, -1, 0, 1, 2, 3.5]
        z <- elements [-2, -1, 0, 1, 2, 3.5]
        pure (V3 x y z, 1, 1, 0xFFFFFFFF)

-- | Big enough to leave insertion sort and recurse for real, and already
-- sorted / reverse sorted so the median-of-three pivot is exercised on
-- its classic adversaries.
newtype Adversarial = Adversarial [(V3, Float, Float, Word32)]
  deriving (Show)

instance Arbitrary Adversarial where
  arbitrary = do
    n <- choose (17, 4096 :: Int)
    shape <- elements [ascending, descending, allEqual, sawtooth]
    pure (Adversarial [(V3 0 0 (shape n i), 1, 1, 0xFFFFFFFF) | i <- [0 .. n - 1]])
    where
      ascending, descending, allEqual, sawtooth :: Int -> Int -> Float
      ascending _ i = fromIntegral i
      descending n i = fromIntegral (n - i)
      allEqual _ _ = 7
      sawtooth _ i = fromIntegral (i `mod` 8)

bufferOf :: [(V3, Float, Float, Word32)] -> ParticleBuffer
bufferOf = fromParticles

-- | The pre-0010 implementation, written out again.
reference :: ViewPlane -> ParticleBuffer -> U.Vector Int
reference plane pb = U.fromList (map fst (sortOn (Down . snd) keyed))
  where
    keyed = [(i, depthAt plane pb i) | i <- [0 .. pbCount pb - 1]]

depthAt :: ViewPlane -> ParticleBuffer -> Int -> Float
depthAt plane pb i =
  snd (orthographic plane (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i)))

genPlane :: Gen ViewPlane
genPlane = elements [SideXY, TopXZ]

nonIncreasing :: [Float] -> Bool
nonIncreasing ds = and (zipWith (>=) ds (drop 1 ds))

spec :: Spec
spec = describe "depthOrder as an in-place introsort (func-spec 0010 §7 S5)" $ do
  describe "the equivalence law: new ≡ the pre-0010 sortOn" $ do
    prop "same permutation, index for index, with depths colliding" $
      \(Particles ps) ->
        forAll genPlane $ \plane ->
          let pb = bufferOf ps
           in depthOrder plane pb === reference plane pb

    prop "same permutation on sorted, reversed, constant and sawtooth inputs" $
      \(Adversarial ps) ->
        forAll genPlane $ \plane ->
          let pb = bufferOf ps
           in depthOrder plane pb === reference plane pb

  describe "the frozen 0008 laws still hold directly" $ do
    prop "is a permutation of [0 .. pbCount-1]" $
      \(Particles ps) ->
        forAll genPlane $ \plane ->
          let pb = bufferOf ps
           in sort (U.toList (depthOrder plane pb)) === [0 .. pbCount pb - 1]

    prop "orders the particles far to near" $
      \(Particles ps) ->
        forAll genPlane $ \plane ->
          let pb = bufferOf ps
           in property (nonIncreasing (map (depthAt plane pb) (U.toList (depthOrder plane pb))))

    prop "is stable: equal depths keep their buffer order" $
      \(Particles ps) ->
        forAll genPlane $ \plane ->
          let pb = bufferOf ps
              order = U.toList (depthOrder plane pb)
              groups d = [i | i <- order, depthAt plane pb i == d]
              depths = [depthAt plane pb i | i <- [0 .. pbCount pb - 1]]
           in conjoin [property (groups d == sort (groups d)) | d <- depths]

  describe "the boundaries" $ do
    it "an empty buffer produces an empty permutation" $ do
      U.toList (depthOrder SideXY emptyBuffer) `shouldBe` []
      U.toList (depthOrder TopXZ emptyBuffer) `shouldBe` []

    it "a single particle is its own permutation" $
      U.toList (depthOrder SideXY (bufferOf [(V3 1 2 3, 1, 1, 0)])) `shouldBe` [0]

    it "a fully loaded 4096-particle batch, all at the same depth, keeps buffer order" $ do
      let pb = bufferOf [(V3 (fromIntegral i) 0 0, 1, 1, 0) | i <- [0 .. 4095 :: Int]]
      U.toList (depthOrder SideXY pb) `shouldBe` [0 .. 4095]

    it "an infinite depth sorts furthest, not into a loop" $ do
      let pb = bufferOf [(V3 0 0 0, 1, 1, 0), (V3 0 0 (-1 / 0), 1, 1, 0)]
      U.toList (depthOrder SideXY pb) `shouldBe` [1, 0]

    it "a NaN depth is deterministic and still a valid permutation" $ do
      -- Unreachable through the analytic layer (evalFinite flushes NaN);
      -- asserted so the sort is total for any host-supplied buffer.
      let nan = 0 / 0 :: Float
          pb = bufferOf [(V3 0 0 1, 1, 1, 0), (V3 0 0 nan, 1, 1, 0), (V3 0 0 (-1), 1, 1, 0)]
          order = U.toList (depthOrder SideXY pb)
      sort order `shouldBe` [0, 1, 2]
      order `shouldBe` U.toList (depthOrder SideXY pb)
      -- NaN folds to -Infinity, i.e. nearest: it sorts last.
      order `shouldBe` [2, 0, 1]
