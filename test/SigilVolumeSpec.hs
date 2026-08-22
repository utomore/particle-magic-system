-- | T1 (magic-semantics F002): the type and the field.
--
-- 'SigilVolume' is the fifth circle-level property, and the whole of this
-- file is the claim that it behaves like the four before it: it is absent
-- from 'emptyCircle', it is set with a record update, and setting it
-- disturbs nothing else.
module SigilVolumeSpec (spec) where

import Magic.Circle
  ( Circle (..)
  , Core (..)
  , Nodes (..)
  , PhaseConfig (..)
  , SigilTiming (..)
  , SigilVolume (..)
  , emptyCircle
  )
import Magic.Rune (Anchor (..), ForceField (..))
import Magic.Types (Seconds (..), V3 (..))
import Test.Hspec

-- | A circle with all four earlier circle-level properties occupied, so
-- "nothing else moved" is a statement about something.
furnished :: Circle
furnished =
  emptyCircle
    { circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))
    , circleFields = [Gravity (V3 0 (-9) 0)]
    , circleAnchors = Just [Anchor (V3 0.6 0 0) (V3 0 0 1)]
    , circleSigil = Just (SigilTiming (Seconds 2.5) True)
    }

spec :: Spec
spec = describe "SigilVolume, the fifth circle-level property (magic-semantics F002 T1)" $ do
  describe "the type" $ do
    it "has exactly one value" $
      SigilVolume `shouldBe` SigilVolume

    it "shows, so a failing assertion names the value" $
      show SigilVolume `shouldContain` "SigilVolume"

  describe "the field" $ do
    it "is absent from emptyCircle: the opt-in default is the single-plane path" $
      circleVolume emptyCircle `shouldBe` Nothing

    it "is set by record update" $
      circleVolume (emptyCircle {circleVolume = Just SigilVolume}) `shouldBe` Just SigilVolume

    it "and setting it leaves the other four circle-level properties alone" $ do
      let updated = furnished {circleVolume = Just SigilVolume}
      circlePhases updated `shouldBe` circlePhases furnished
      circleFields updated `shouldBe` circleFields furnished
      circleAnchors updated `shouldBe` circleAnchors furnished
      circleSigil updated `shouldBe` circleSigil furnished

    it "nor does it disturb the slots or the core" $ do
      let updated = furnished {circleVolume = Just SigilVolume}
      outerRings updated `shouldBe` outerRings furnished
      interLayer updated `shouldBe` interLayer furnished
      innerRings updated `shouldBe` innerRings furnished
      coreCenter (core updated) `shouldBe` coreCenter (core furnished)
      north (coreNodes (core updated)) `shouldBe` north (coreNodes (core furnished))

    it "and the other four do not disturb it" $ do
      let base = emptyCircle {circleVolume = Just SigilVolume}
      circleVolume (base {circlePhases = Just (PhaseConfig (Seconds 1) (Seconds 0))})
        `shouldBe` Just SigilVolume
      circleVolume (base {circleFields = [Gravity (V3 0 (-1) 0)]}) `shouldBe` Just SigilVolume
      circleVolume (base {circleAnchors = Just [Anchor (V3 0 0 0) (V3 0 0 1)]})
        `shouldBe` Just SigilVolume
      circleVolume (base {circleSigil = Just (SigilTiming (Seconds 1) False)})
        `shouldBe` Just SigilVolume

    it "so two circles differing only in it are otherwise equal" $ do
      let a = furnished {circleVolume = Just SigilVolume}
          b = furnished {circleVolume = Nothing}
      a `shouldNotBe` b
      a {circleVolume = Nothing} `shouldBe` b
