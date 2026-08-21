-- | T6 (func-spec 0001 §8): fixed-timestep planner properties.
--
-- The frame-slicing invariance property is tested with dyadic rationals
-- (multiples of 1/256, dt = 1/64) so every intermediate Double is exact
-- and the property holds bit-for-bit — the actual determinism guarantee,
-- not an epsilon approximation.
module StepSpec (spec) where

import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
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

  it "float-noisy 60Hz clock deltas still run exactly 1 step per frame" $ do
    -- Timestamps built by repeated addition of 1/60 (like a real clock
    -- read) produce deltas an ulp off from dt; the planner's epsilon
    -- must absorb this.
    let dt = 1 / 60 :: Double
        times = take 601 (iterate (+ dt) 0)
        deltas = zipWith (-) (drop 1 times) times
        (total, _) = runFrames dt maxBound deltas
    total `shouldBe` 600

  -- B001 -----------------------------------------------------------------
  -- The clamp used to be decided AFTER `floor`: `n = floor (acc'/dt + eps)`
  -- and then `n > maxSteps`. But acc'/dt is two finite Doubles divided, so
  -- it ranges over all of Double -- including values `floor :: Double ->
  -- Int` cannot represent, where it answers with a meaningless bit pattern
  -- instead of saturating. The guard then never fired and the plan fell
  -- through to the "run n steps" branch carrying that garbage.
  --
  -- Every input below is one the C ABI accepts: dt > 0 and finite,
  -- max_steps >= 0, elapsed finite, acc_in >= 0 and finite. They are not
  -- realistic frame times; they are the smallest inputs that put the ratio
  -- outside Int, which is the only thing that has to be true for a shipped
  -- host to hit this.
  describe "B001: backlogs whose ratio to dt leaves Int's range" $ do
    it "clamps when the ratio overflows to Infinity (1e300 / 1e-300)" $
      -- The reported case. It answered `StepPlan 0 1.0e300`: no steps run
      -- AND the backlog handed straight back, so the next frame computes
      -- the same thing forever. The clamp exists to survive exactly this
      -- backlog; instead it froze on it.
      plan 1e-300 8 1e300 0 `shouldBe` StepPlan 8 0

    it "clamps when the ratio is finite but past Int (1e300 at 60Hz)" $
      -- 6e301 is a perfectly finite Double. `floor` it into an Int and
      -- GHC 9.14.1 hands back 0.
      plan (1 / 60) 8 1e300 0 `shouldBe` StepPlan 8 0

    it "never answers with a negative step count for a legal backlog" $
      -- One of these used to return -8742554432415203328, which a host
      -- spends as `while (steps-- > 0)`. Which one depends on how the
      -- garbage bits land, so the assertion sweeps the magnitudes rather
      -- than naming a single lucky value.
      mapM_
        (\elapsed -> (elapsed, plan (1 / 60) 8 elapsed 0) `shouldBe` (elapsed, StepPlan 8 0))
        [1e19, 1e20, 1e30, 1e100, 1e300]

    it "clamps instead of poisoning the accumulator when acc + elapsed overflows" $ do
      -- Both addends finite, their sum is not; the old code carried the
      -- Infinity out in accAfter, poisoning every later frame.
      accAfter (plan (1 / 60) 8 1e308 1e308) `shouldSatisfy` (not . isInfinite)
      plan (1 / 60) 8 1e308 1e308 `shouldBe` StepPlan 8 0

    prop "legal input always yields a usable plan, at any magnitude" $
      forAll genLegalCall $ \(dt, maxSteps, elapsed, acc) ->
        let p = plan dt maxSteps elapsed acc
         in counterexample (show (dt, maxSteps, elapsed, acc) ++ " -> " ++ show p) $
              stepsToRun p >= 0
                && stepsToRun p <= maxSteps
                && accAfter p >= 0
                && not (isInfinite (accAfter p))
                && not (isNaN (accAfter p))

  -- The other half of the fix: it may only change the inputs that were
  -- walking into the pathological branch. Everything else -- every legal
  -- input whose ratio does fit, and every illegal input the C ABI rejects
  -- (test/FFIStepPlanSpec.hs pins those as the reason it rejects them) --
  -- must come back bit for bit as before.
  describe "B001: results the fix must leave bit for bit unchanged" $ do
    it "reproduces the recorded answer for every pinned input" $
      mapM_
        ( \(label, dt, maxSteps, elapsed, acc, expectedSteps, expectedAccBits) -> do
            let p = plan dt maxSteps elapsed acc
            (label, stepsToRun p) `shouldBe` (label, expectedSteps)
            -- Bit pattern, not value: 0.0 and -0.0 compare equal and this
            -- is a claim about bits.
            (label, bits (accAfter p)) `shouldBe` (label, expectedAccBits)
        )
        pinnedPlans

    it "still hands a lone caller the answers the C ABI exists to refuse" $ do
      -- Mirrors test/FFIStepPlanSpec.hs's regression case. These are NOT
      -- in this bugfix's scope: they are non-finite or negative inputs,
      -- pm_plan_steps answers PM_ERR_ARGS for them, and that spec cites
      -- these very values as the reason. If the fix "improved" them it
      -- would silently invalidate that argument.
      accAfter (plan (0 / 0) 8 0.5 0.25) `shouldBe` 0
      accAfter (plan (1 / 60) 8 (1 / 0) 0.25) `shouldSatisfy` isInfinite
      accAfter (plan (1 / 60) 8 0.5 (1 / 0)) `shouldSatisfy` isInfinite
      stepsToRun (plan (1 / 60) (-3) 0.5 0.25) `shouldSatisfy` (< 0)
      stepsToRun (plan (1 / 60) 8 0.5 (-0.9)) `shouldSatisfy` (< 0)

-- B001 helpers ----------------------------------------------------------------

-- | @(label, dt, maxSteps, elapsed, acc, steps, accAfter as bits)@ —
-- recorded from the implementation as it stood before B001, across the
-- typical frame, the epsilon absorption, both clamp forms, the @dt <= 0@
-- guard, the degenerate @maxSteps == 0@, and the extremes of dt that do
-- NOT overflow the ratio.
pinnedPlans :: [(String, Double, Int, Double, Double, Int, Word64)]
pinnedPlans =
  [ ("60Hz two frames", 1 / 60, 8, 1 / 30, 0, 2, 0)
  , ("epsilon absorbs an ulp-shy backlog", 1 / 60, 8, 0, nextBelow (1 / 60), 1, 0)
  , ("dyadic clamp", 1 / 64, 8, 0.7, 0.013, 8, 0)
  , ("clamp drops the backlog", 1 / 60, 8, 10, 0, 8, 0)
  , ("half a second at 60Hz", 1 / 60, 8, 0.5, 0.25, 8, 0)
  , -- The only entry with a non-trivial accumulator: it is the one that
    -- would catch an off-by-an-ulp change in the residue arithmetic.
    ("144Hz partial frame", 1 / 144, 12, 1.73e-2, 1e-9, 2, 4570011911541362168)
  , -- The three rows that sit ON the clamp boundary. The fix rewrote
    -- `floor ratio > maxSteps` into `ratio >= maxSteps + 1`, and the whole
    -- bit-exactness claim is that those are the same question; an
    -- off-by-one there (`ratio > maxSteps`) would start clamping half a
    -- step early and confiscate the residue instead of carrying it, which
    -- is invisible everywhere except right here.
    ("exactly maxSteps, with a residue to carry", 1 / 60, 8, 8.5 / 60, 0, 8, 4575957461383581968)
  , ("exactly maxSteps, nothing left over", 1 / 64, 8, 8 / 64, 0, 8, 0)
  , ("one step under the clamp", 1 / 60, 8, 7.25 / 60, 0, 7, 4571453861756211472)
  , ("maxSteps = 0 with a sub-step backlog", 1 / 60, 0, 0.5 / 60, 0, 0, 4575957461383581969)
  , ("dt = 0 returns the accumulator untouched", 0, 8, 0.5, 0.25, 0, 4598175219545276416)
  , ("dt < 0 returns the accumulator untouched", -1 / 60, 8, 0.5, 0.25, 0, 4598175219545276416)
  , ("maxSteps = 0 clamps to nothing", 1 / 60, 0, 0.5, 0, 0, 0)
  , ("dt larger than the backlog", 1e308, 8, 0.5, 0.25, 0, 4604930618986332160)
  , ("denormal dt with no backlog", 5e-324, 8, 0, 0, 0, 0)
  , ("negative elapsed reads as zero", 1 / 60, 8, -1, 0.25, 8, 0)
  ]

-- | Exactly the domain @pm_plan_steps@ lets through: a positive finite
-- step, a non-negative clamp, a finite frame time and a non-negative
-- finite accumulator — spread over the whole exponent range rather than
-- the plausible one, because "plausible" is what hid this bug.
genLegalCall :: Gen (Double, Int, Double, Double)
genLegalCall = do
  dt <- genPositive
  maxSteps <- choose (0, 64)
  elapsed <- oneof [pure 0, genPositive, negate <$> genPositive]
  acc <- oneof [pure 0, genPositive]
  pure (dt, maxSteps, elapsed, acc)
  where
    genPositive = do
      -- 307 rather than 308: the mantissa multiplies on top, and this
      -- generator has to stay inside the finite domain it is asserting
      -- about (9.99e308 is Infinity, which the C ABI refuses anyway).
      e <- elements [-320, -300, -200, -100, -20, -3, -2, 0, 1, 3, 10, 19, 20, 100, 200, 300, 307]
      m <- choose (1, 9.99)
      pure (m * 10 ** fromIntegral (e :: Int))

-- | The largest 'Double' strictly below a positive one.
nextBelow :: Double -> Double
nextBelow x = castWord64ToDouble (castDoubleToWord64 x - 1)

bits :: Double -> Word64
bits = castDoubleToWord64
