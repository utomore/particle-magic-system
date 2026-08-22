-- | T2 (magic-semantics F002): the @"volume"@ key.
--
-- Fifth circle-level opt-in property, and the sixth time this repo states
-- the same compatibility law: a missing key and @null@ both mean "no
-- key", and every file written before the key existed decodes to exactly
-- what it decoded to before.
--
-- Where it parts company with every earlier opt-in key: there is nothing
-- inside the object to be right or wrong about. @"volume": {}@ and
-- @"volume": {"anything": 1}@ decode to the identical value, because the
-- type carries no field at all — the key's mere presence is the whole
-- signal.
module SigilVolumeCodecSpec (spec) where

import qualified Data.ByteString.Char8 as BSC
import Magic.Circle (Circle (..), PhaseConfig (..), SigilVolume (..), emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, saveCircle)
import Magic.Types (Seconds (..))
import Test.Hspec

-- | A spell file with the given @circle@ body.
fileWith :: String -> BSC.ByteString
fileWith body = BSC.pack ("{\"version\":1,\"circle\":{" ++ body ++ "}}")

loadBody :: String -> Either LoadError Circle
loadBody = loadCircle . fileWith

circleVolumeOf :: Either LoadError Circle -> Maybe (Maybe SigilVolume)
circleVolumeOf = either (const Nothing) (Just . circleVolume)

isLeftJson :: Either LoadError Circle -> Bool
isLeftJson result = case result of
  Left (JsonError _) -> True
  _ -> False

spec :: Spec
spec = describe "the \"volume\" key (magic-semantics F002 T2)" $ do
  describe "the compatibility law, once more" $ do
    it "a circle with no volume key is the pre-F002 circle" $
      loadBody "" `shouldBe` Right emptyCircle

    it "and an explicit null is the same as no key" $
      loadBody "\"volume\":null" `shouldBe` Right emptyCircle

    it "so a pre-F002 phased file decodes to what it always did" $
      loadBody "\"phases\":{\"draw\":1.0,\"converge\":0.5}"
        `shouldBe` Right emptyCircle {circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))}

  describe "presence is the whole signal" $ do
    it "\"volume\": {} decodes to Just SigilVolume" $
      circleVolumeOf (loadBody "\"volume\":{}") `shouldBe` Just (Just SigilVolume)

    it "and so does an object with unrecognised keys: the content is ignored" $
      circleVolumeOf (loadBody "\"volume\":{\"anything\":1,\"layers\":9}")
        `shouldBe` Just (Just SigilVolume)

  describe "the round trip" $ do
    it "loadCircle . saveCircle == Right, with volume on" $ do
      let c = emptyCircle {circleVolume = Just SigilVolume}
      loadCircle (saveCircle c) `shouldBe` Right c

    it "and with volume off" $
      loadCircle (saveCircle emptyCircle) `shouldBe` Right emptyCircle

    it "a circle with no volume writes a null that reads back as absence" $ do
      let bytes = saveCircle emptyCircle
      BSC.unpack bytes `shouldContain` "\"volume\":null"
      loadCircle bytes `shouldBe` Right emptyCircle

  describe "type errors" $ do
    it "rejects a volume that is not an object" $ do
      let result = loadBody "\"volume\":[]"
      result `shouldSatisfy` isLeftJson

    it "rejects a volume that is a bare scalar" $
      loadBody "\"volume\":true" `shouldSatisfy` isLeftJson
