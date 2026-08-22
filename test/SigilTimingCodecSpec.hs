-- | T2 (func-spec 0026): the @"sigil"@ key.
--
-- Fourth circle-level opt-in property, and the fifth time this repo
-- states the same compatibility law: a missing key and @null@ both mean
-- "no key", and every file written before the key existed decodes to
-- exactly what it decoded to before.
--
-- Where it deliberately parts company with 'AnchorCodecSpec' is the
-- /empty/ shape. @[]@ is a load error for @anchors@ because it would
-- carry a second meaning that collides with absence; @{}@ is legal here
-- because @SigilTiming 0 False@ /is/ absence, behaviourally. Refusing it
-- would buy nothing and cost one more exception to remember, so the
-- asymmetry is asserted rather than assumed.
module SigilTimingCodecSpec (spec) where

import qualified Data.ByteString.Char8 as BSC
import Data.List (isInfixOf)
import Magic.Circle (Circle (..), PhaseConfig (..), SigilTiming (..), emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, saveCircle)
import Magic.Types (Seconds (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | A spell file with the given @circle@ body.
fileWith :: String -> BSC.ByteString
fileWith body = BSC.pack ("{\"version\":1,\"circle\":{" ++ body ++ "}}")

loadBody :: String -> Either LoadError Circle
loadBody = loadCircle . fileWith

errorText :: Either LoadError Circle -> String
errorText result = case result of
  Left (JsonError msg) -> msg
  Left other -> show other
  Right _ -> "<decoded successfully>"

newtype AnyTiming = AnyTiming SigilTiming
  deriving (Show)

instance Arbitrary AnyTiming where
  arbitrary = do
    -- Eighths: exact in binary, so the round trip is about the codec and
    -- not about float printing. The cap is 60, so this stays well inside
    -- it and the range check is tested on its own below.
    n <- choose (-400, 400 :: Int)
    hold <- arbitrary
    pure (AnyTiming (SigilTiming (Seconds (fromIntegral n / 8)) hold))

spec :: Spec
spec = describe "the \"sigil\" key (func-spec 0026 T2)" $ do
  describe "the compatibility law, once more" $ do
    it "a circle with no sigil key is the pre-0026 circle" $
      loadBody "" `shouldBe` Right emptyCircle

    it "and an explicit null is the same as no key" $
      loadBody "\"sigil\":null" `shouldBe` Right emptyCircle

    it "so a pre-0026 sigil file decodes to what it always did" $
      -- bare-sigil.json, spelled out: the file the key could most easily
      -- have disturbed, and it decodes with the sigil field empty.
      loadBody "\"phases\":{\"draw\":1.0,\"converge\":0.5}"
        `shouldBe` Right emptyCircle {circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))}

  describe "the empty object is legal and does nothing" $ do
    it "\"sigil\": {} decodes to both defaults" $
      circleSigilOf (loadBody "\"sigil\":{}")
        `shouldBe` Just (Just (SigilTiming (Seconds 0) False))

    it "and so does a sigil naming only one of the two" $ do
      circleSigilOf (loadBody "\"sigil\":{\"linger\":1.5}")
        `shouldBe` Just (Just (SigilTiming (Seconds 1.5) False))
      circleSigilOf (loadBody "\"sigil\":{\"hold\":true}")
        `shouldBe` Just (Just (SigilTiming (Seconds 0) True))

  describe "the round trip" $ do
    prop "loadCircle . saveCircle == Right, for any timing" $
      \(AnyTiming st) ->
        let c = emptyCircle {circleSigil = Just st}
         in loadCircle (saveCircle c) === Right c

    it "and a circle with no sigil writes a null that reads back as absence" $ do
      let bytes = saveCircle emptyCircle
      BSC.unpack bytes `shouldContain` "\"sigil\":null"
      loadCircle bytes `shouldBe` Right emptyCircle

  describe "linger's range" $ do
    it "accepts the caps themselves, on both sides" $ do
      circleSigilOf (loadBody "\"sigil\":{\"linger\":60}")
        `shouldBe` Just (Just (SigilTiming (Seconds 60) False))
      circleSigilOf (loadBody "\"sigil\":{\"linger\":-60}")
        `shouldBe` Just (Just (SigilTiming (Seconds (-60)) False))

    it "rejects a value past the cap, naming the key path" $ do
      let result = loadBody "\"sigil\":{\"linger\":600}"
      result `shouldSatisfy` isLeftJson
      errorText result `shouldSatisfy` ("$.circle.sigil.linger" `isInfixOf`)
      errorText result `shouldSatisfy` ("linger" `isInfixOf`)
      errorText result `shouldSatisfy` ("60" `isInfixOf`)

    it "and past the cap on the negative side too" $ do
      let result = loadBody "\"sigil\":{\"linger\":-600}"
      result `shouldSatisfy` isLeftJson
      errorText result `shouldSatisfy` ("$.circle.sigil.linger" `isInfixOf`)

  describe "type errors" $ do
    it "rejects a non-boolean hold" $ do
      let result = loadBody "\"sigil\":{\"hold\":\"yes\"}"
      result `shouldSatisfy` isLeftJson
      errorText result `shouldSatisfy` ("$.circle.sigil" `isInfixOf`)

    it "rejects a non-numeric linger" $
      loadBody "\"sigil\":{\"linger\":\"soon\"}" `shouldSatisfy` isLeftJson

    it "rejects a sigil that is not an object" $ do
      let result = loadBody "\"sigil\":[]"
      result `shouldSatisfy` isLeftJson
      errorText result `shouldSatisfy` ("$.circle.sigil" `isInfixOf`)

circleSigilOf :: Either LoadError Circle -> Maybe (Maybe SigilTiming)
circleSigilOf = either (const Nothing) (Just . circleSigil)

isLeftJson :: Either LoadError Circle -> Bool
isLeftJson result = case result of
  Left (JsonError _) -> True
  _ -> False
