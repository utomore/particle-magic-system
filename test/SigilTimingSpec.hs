-- | T1 (func-spec 0026): the type and the field.
--
-- 'SigilTiming' is the fourth circle-level property, and the whole of
-- this file is the claim that it behaves like the three before it: it is
-- absent from 'emptyCircle', it is set with a record update, and setting
-- it disturbs nothing else. Small assertions, but they are the ones the
-- rest of the round quotes — every later law is phrased as "the same
-- circle with @circleSigil@ changed", and that phrase only means
-- something if changing it changes nothing else.
module SigilTimingSpec (spec) where

import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), SigilTiming (..), emptyCircle)
import Magic.Rune (Anchor (..), ForceField (..))
import Magic.Types (Seconds (..), V3 (..))
import Test.Hspec

-- | A circle with all three earlier circle-level properties occupied, so
-- "nothing else moved" is a statement about something.
furnished :: Circle
furnished =
  emptyCircle
    { circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))
    , circleFields = [Gravity (V3 0 (-9) 0)]
    , circleAnchors = Just [Anchor (V3 0.6 0 0) (V3 0 0 1)]
    }

held :: SigilTiming
held = SigilTiming (Seconds 2.5) True

spec :: Spec
spec = describe "SigilTiming, the fourth circle-level property (func-spec 0026 T1)" $ do
  describe "the type" $ do
    it "compares by both members" $ do
      held `shouldBe` SigilTiming (Seconds 2.5) True
      held `shouldNotBe` SigilTiming (Seconds 2.5) False
      held `shouldNotBe` SigilTiming (Seconds 2.4) True

    it "shows both members, so a failing assertion names the value" $ do
      show held `shouldContain` "2.5"
      show held `shouldContain` "True"

  describe "the field" $ do
    it "is absent from emptyCircle: the opt-in default is the pre-0026 path" $
      circleSigil emptyCircle `shouldBe` Nothing

    it "is set by record update" $
      circleSigil (emptyCircle {circleSigil = Just held}) `shouldBe` Just held

    it "and setting it leaves the other three circle-level properties alone" $ do
      let updated = furnished {circleSigil = Just held}
      circlePhases updated `shouldBe` circlePhases furnished
      circleFields updated `shouldBe` circleFields furnished
      circleAnchors updated `shouldBe` circleAnchors furnished

    it "nor does it disturb the slots or the core" $ do
      let updated = furnished {circleSigil = Just held}
      outerRings updated `shouldBe` outerRings furnished
      interLayer updated `shouldBe` interLayer furnished
      innerRings updated `shouldBe` innerRings furnished
      coreCenter (core updated) `shouldBe` coreCenter (core furnished)
      north (coreNodes (core updated)) `shouldBe` north (coreNodes (core furnished))

    it "and the other three do not disturb it" $ do
      let base = emptyCircle {circleSigil = Just held}
      circleSigil (base {circlePhases = Just (PhaseConfig (Seconds 1) (Seconds 0))})
        `shouldBe` Just held
      circleSigil (base {circleFields = [Gravity (V3 0 (-1) 0)]}) `shouldBe` Just held
      circleSigil (base {circleAnchors = Just [Anchor (V3 0 0 0) (V3 0 0 1)]})
        `shouldBe` Just held

    it "so two circles differing only in it are otherwise equal" $ do
      let a = furnished {circleSigil = Just held}
          b = furnished {circleSigil = Just (SigilTiming (Seconds 0) False)}
      a `shouldNotBe` b
      a {circleSigil = Nothing} `shouldBe` b {circleSigil = Nothing}
