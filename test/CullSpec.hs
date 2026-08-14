-- | S3 (func-spec 0010 §7): emitter time-window culling.
--
-- 'Magic.Particle.Analytic.aliveRanges' replaces a per-index
-- 'particleAge' scan with @O(log count)@ binary searches over the same
-- arithmetic. The whole round rests on it being an /exact/ substitution,
-- not a fast approximation, so the headline law here is the equivalence
-- with the full scan, over arbitrary envelopes at arbitrary ages —
-- including the awkward ones: zero-length windows, zero lifetimes,
-- respawn boundaries, times before the cast and long after the spell
-- has died out.
--
-- The second claim is the one that buys the performance: an emitter whose
-- window is dead produces no ranges at all, so nothing downstream pays
-- per particle for it.
module CullSpec (spec) where

import Data.Maybe (isJust)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Compile (CompiledSpell (..), EmitterSpec (..), compile)
import Magic.Particle.Analytic
  ( aliveRanges
  , aliveSlotIndices
  , aliveSlots
  , emitterOffsets
  , particleAge
  )
import Magic.Rune (Envelope (..), InnerRune (..))
import Magic.Types (Seconds (..), Time (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Envelopes across the whole shape space the compiler can produce:
-- degenerate durations and lifetimes included, since those are exactly
-- where a closed-form window is easy to get wrong.
newtype Env = Env Envelope
  deriving (Show)

instance Arbitrary Env where
  arbitrary = do
    delay <- frequency [(3, pure 0), (1, choose (0, 4))]
    duration <- frequency [(1, pure 0), (4, choose (0, 8))]
    lifetime <- frequency [(1, pure 0), (6, choose (0.001, 4))]
    pure (Env (Envelope (Seconds delay) (Seconds duration) (Seconds lifetime)))

-- | Counts small enough to scan exhaustively, but past the point where
-- the binary search has to actually recurse.
newtype Count = Count Int
  deriving (Show)

instance Arbitrary Count where
  arbitrary = Count <$> frequency [(1, pure 0), (1, pure 1), (6, choose (2, 200))]

newtype Age = Age Double
  deriving (Show)

instance Arbitrary Age where
  arbitrary = Age <$> frequency [(1, choose (-1, 0)), (8, choose (0, 16))]

-- | The pre-0010 answer: ask every index.
fullScan :: Envelope -> Int -> Time -> [Int]
fullScan env count t =
  [i | i <- [0 .. count - 1], isJust (particleAge env count i t)]

-- | The culled answer, expanded back to a plain index list.
culled :: Envelope -> Int -> Time -> [Int]
culled env count t = concat [[lo .. hi - 1] | (lo, hi) <- aliveRanges env count t]

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

-- | A phased spell: several emitters with different windows, so whole
-- emitters fall dead at different times.
phased :: CompiledSpell
phased =
  compiledOf
    emptyCircle
      { innerRings =
          TwoOf (Just (TimingRune (Envelope (Seconds 0.5) (Seconds 2) (Seconds 0.3)))) Nothing
      , circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))
      }

spec :: Spec
spec = describe "emitter time-window culling (func-spec 0010 §7 S3)" $ do
  describe "the equivalence law: culled ≡ full scan" $ do
    prop "same indices, same order, for any envelope × count × age" $
      \(Env env) (Count count) (Age t) ->
        culled env count (Time t) === fullScan env count (Time t)

    prop "the ranges are ascending, disjoint and non-empty" $
      \(Env env) (Count count) (Age t) ->
        let rs = aliveRanges env count (Time t)
         in conjoin
              [ counterexample "non-empty" (property (and [lo < hi | (lo, hi) <- rs]))
              , counterexample "in bounds" (property (and [lo >= 0 && hi <= count | (lo, hi) <- rs]))
              , counterexample "ascending, disjoint" $
                  property (and (zipWith (\(_, h) (l, _) -> h <= l) rs (drop 1 rs)))
              ]

    prop "at most two ranges (the index span is under one lifetime)" $
      \(Env env) (Count count) (Age t) ->
        length (aliveRanges env count (Time t)) <= 2

  describe "dead windows cost nothing" $ do
    let env = Envelope (Seconds 1) (Seconds 2) (Seconds 0.5)
        count = 4096

    it "before the first birth there are no ranges at all" $
      aliveRanges env count (Time 0.5) `shouldBe` []

    it "after the last batch has died there are no ranges at all" $ do
      -- window closes at delay + duration = 3, last batch dies by 3.5.
      aliveRanges env count (Time 4) `shouldBe` []
      aliveRanges env count (Time 40) `shouldBe` []

    it "a zero lifetime is a permanently dead window" $
      aliveRanges (Envelope (Seconds 0) (Seconds 5) (Seconds 0)) count (Time 1) `shouldBe` []

    it "mid-window it is emphatically not empty (the law is not vacuous)" $ do
      let rs = aliveRanges env count (Time 2)
      sum [hi - lo | (lo, hi) <- rs] `shouldSatisfy` (> 1000)

  describe "aliveSlots rides on the same windows" $ do
    prop "still equals the full scan over every emitter" $
      forAll (choose (0, 4)) $ \t ->
        aliveSlots phased (Time t)
          === [ (e, i)
              | (e, em) <- zip [0 ..] (V.toList (spellEmitters phased))
              , i <- fullScan (emSpawn em) (emCount em) (Time t)
              ]

    prop "aliveSlotIndices is aliveSlots flattened through emitterOffsets" $
      forAll (choose (0, 4)) $ \t ->
        let offsets = emitterOffsets phased
         in U.toList (aliveSlotIndices phased (Time t))
              === [offsets U.! e + i | (e, i) <- aliveSlots phased (Time t)]

    it "emitterOffsets is the prefix sum, last element = total slot count" $ do
      let offsets = U.toList (emitterOffsets phased)
          counts = map emCount (V.toList (spellEmitters phased))
      offsets `shouldBe` scanl (+) 0 counts
      last offsets `shouldBe` sum counts

    it "before the cast nothing is alive" $ do
      aliveSlots phased (Time (-0.5)) `shouldBe` []
      U.toList (aliveSlotIndices phased (Time (-0.5))) `shouldBe` []
