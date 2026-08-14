-- | S1 (func-spec 0006 §8): the lifecycle vocabulary — 'Phase',
-- 'PhasePlan' and the total classification function 'phaseAt' — plus the
-- 'Circle' addition ('circlePhases').
module PhasePlanSpec (spec) where

import Magic.Circle (circlePhases, emptyCircle)
import Magic.Compile (Phase (..), PhasePlan (..), phaseAt)
import Magic.Types (Seconds (..), Time (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Monotonic landmarks: four nonnegative gaps summed, matching the
-- 'PhasePlan' invariant by construction.
data AnyPlan = AnyPlan !PhasePlan !Double !Double !Double !Double
  deriving (Show)

instance Arbitrary AnyPlan where
  arbitrary = do
    d0 <- choose (0, 5)
    d1 <- choose (0, 5)
    d2 <- choose (0, 5)
    d3 <- choose (0, 5)
    let a = d0
        b = a + d1
        c = b + d2
        e = c + d3
    pure $
      AnyPlan
        PhasePlan {ppDrawEnd = Seconds a, ppConvergeEnd = Seconds b, ppCastingEnd = Seconds c, ppEnd = Seconds e}
        a
        b
        c
        e

degeneratePlan :: Double -> Double -> PhasePlan
degeneratePlan castingEnd ppEndV =
  PhasePlan
    { ppDrawEnd = Seconds 0
    , ppConvergeEnd = Seconds 0
    , ppCastingEnd = Seconds castingEnd
    , ppEnd = Seconds ppEndV
    }

spec :: Spec
spec = describe "Phase/PhasePlan/phaseAt (spec 0006 S1)" $ do
  it "emptyCircle has circlePhases = Nothing" $
    circlePhases emptyCircle `shouldBe` Nothing

  it "concrete boundary trace: draw 1.2s, converge 0.6s (castStart 1.8s)" $ do
    let plan =
          PhasePlan
            { ppDrawEnd = Seconds 1.2
            , ppConvergeEnd = Seconds 1.8
            , ppCastingEnd = Seconds 5.8
            , ppEnd = Seconds 7.8
            }
    phaseAt plan (Time (-1)) `shouldBe` Drawing
    phaseAt plan (Time 0) `shouldBe` Drawing
    phaseAt plan (Time 0.6) `shouldBe` Drawing
    phaseAt plan (Time 1.2) `shouldBe` Converging
    phaseAt plan (Time 1.5) `shouldBe` Converging
    phaseAt plan (Time 1.8) `shouldBe` Casting
    phaseAt plan (Time 4.0) `shouldBe` Casting
    phaseAt plan (Time 5.8) `shouldBe` Dissipating
    phaseAt plan (Time 100) `shouldBe` Dissipating

  it "degenerate plan (Nothing circlePhases): t >= 0 is immediately Casting (skip rule)" $ do
    let plan = degeneratePlan 8 10
    phaseAt plan (Time 0) `shouldBe` Casting
    phaseAt plan (Time (-5)) `shouldBe` Casting
    phaseAt plan (Time 7.999) `shouldBe` Casting
    phaseAt plan (Time 8) `shouldBe` Dissipating

  prop "totality: t < 0 classifies exactly as t = 0" $
    \(AnyPlan plan _ _ _ _) -> forAll (choose (-50, 0)) $ \t ->
      phaseAt plan (Time t) === phaseAt plan (Time 0)

  prop "the interior of [0, drawEnd) classifies Drawing" $
    \(AnyPlan plan a _ _ _) ->
      a > 1e-6 ==> forAll (choose (0, a * 0.999)) $ \t ->
        phaseAt plan (Time t) === Drawing

  prop "the interior of [drawEnd, convergeEnd) classifies Converging" $
    \(AnyPlan plan a b _ _) ->
      b - a > 1e-6 ==> forAll (choose (a, a + (b - a) * 0.999)) $ \t ->
        phaseAt plan (Time t) === Converging

  prop "the interior of [convergeEnd, castingEnd) classifies Casting" $
    \(AnyPlan plan _ b c _) ->
      c - b > 1e-6 ==> forAll (choose (b, b + (c - b) * 0.999)) $ \t ->
        phaseAt plan (Time t) === Casting

  prop "t >= castingEnd classifies Dissipating" $
    \(AnyPlan plan _ _ c _) -> forAll (choose (c, c + 50)) $ \t ->
      phaseAt plan (Time t) === Dissipating

  prop "degenerate plans (drawEnd = convergeEnd = 0) never classify Drawing or Converging for t >= 0" $
    forAll (choose (0.1, 20)) $ \c ->
      forAll (choose (c, c + 20)) $ \e ->
        forAll (choose (0, c + 20)) $ \t ->
          let plan = degeneratePlan c e
              phase = phaseAt plan (Time t)
           in phase `elem` [Casting, Dissipating]
