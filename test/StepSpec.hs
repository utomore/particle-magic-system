-- | T6 (func-spec 0001 §8): fixed-timestep planner properties.
--
-- The frame-slicing invariance property is tested with dyadic rationals
-- (multiples of 1/256, dt = 1/64) so every intermediate Double is exact
-- and the property holds bit-for-bit — the actual determinism guarantee,
-- not an epsilon approximation.
module StepSpec (spec) where

import Magic.Step (StepPlan (..), plan)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Frame slices that are exactly representable: k/256 seconds, k ≤ 512.
genDyadicSlices :: Gen [Double]
genDyadicSlices = listOf ((/ 256) . fromIntegral <$> choose (0 :: Int, 512))

-- | Run a sequence of frames through the planner, threading the
-- accumulator; returns total steps and every intermediate plan.
runFrames :: Double -> Int -> [Double] -> (Int, [StepPlan])
runFrames dt maxSteps = go 0 0 []
  where
    go total acc plans [] = (total, reverse plans)
    go total acc plans (e : es) =
      let p = plan dt maxSteps e acc
       in go (total + stepsToRun p) (accAfter p) (p : plans) es

spec :: Spec
spec = describe "Magic.Step.plan (fixed timestep accumulator)" $ do
  prop "total steps == floor(total time / dt) regardless of frame slicing (no clamp)" $
    forAll genDyadicSlices $ \slices ->
      let dt = 1 / 64
          (total, _) = runFrames dt maxBound slices
       in total === floor (sum slices / dt)

  prop "two different slicings of the same total time simulate the same step count" $
    forAll genDyadicSlices $ \slices ->
      let dt = 1 / 64
          (asOne, _) = runFrames dt maxBound [sum slices]
          (asMany, _) = runFrames dt maxBound slices
       in asOne === asMany

  prop "accumulator stays in [0, dt) after every frame (no clamp)" $
    forAll genDyadicSlices $ \slices ->
      let dt = 1 / 64
          (_, plans) = runFrames dt maxBound slices
       in all (\p -> accAfter p >= 0 && accAfter p < dt) plans

  prop "clamp caps stepsToRun at maxSteps" $
    forAll (choose (0 :: Int, 8)) $ \maxSteps ->
      forAll (choose (0 :: Double, 10)) $ \elapsed ->
        forAll (choose (0 :: Double, 1)) $ \acc ->
          let p = plan (1 / 60) maxSteps elapsed acc
           in stepsToRun p <= maxSteps

  it "clamp drops the backlog (accumulator resets to 0)" $
    plan (1 / 60) 8 10 0 `shouldBe` StepPlan 8 0

  it "typical frame: 1/30s elapsed at 60Hz sim runs exactly 2 steps" $ do
    let p = plan (1 / 60) 8 (1 / 30) 0
    stepsToRun p `shouldBe` 2

  it "negative elapsed time is treated as zero" $
    plan (1 / 60) 8 (-1) 0.5 `shouldBe` plan (1 / 60) 8 0 0.5
