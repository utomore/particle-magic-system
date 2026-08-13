{-# LANGUAGE OverloadedStrings #-}

-- | S2 (func-spec 0006 §8): the @"phases"@ JSON surface — missing
-- key/null decode to 'Nothing', validation errors carry a JSON position,
-- roundtrip, and 'saveCircle' encodes 'Nothing' as an explicit null.
module PhaseCodecSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.List (isInfixOf)
import Magic.Circle (Circle (..), PhaseConfig (..), emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, saveCircle)
import Magic.Types (Seconds (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

shouldFailContaining :: BS.ByteString -> [String] -> Expectation
shouldFailContaining doc fragments = case loadCircle doc of
  Left (JsonError msg) ->
    mapM_ (\frag -> msg `shouldSatisfy` (frag `isInfixOf`)) fragments
  other -> expectationFailure ("expected JsonError, got: " ++ show other)

genPhaseConfig :: Gen PhaseConfig
genPhaseConfig =
  PhaseConfig
    <$> (Seconds <$> choose (0.05, 5))
    <*> (Seconds <$> choose (0, 5))

newtype PhasedCircle = PhasedCircle Circle
  deriving (Show)

instance Arbitrary PhasedCircle where
  arbitrary = do
    pc <- genPhaseConfig
    pure (PhasedCircle emptyCircle {circlePhases = Just pc})

spec :: Spec
spec = describe "Magic.Codec \"phases\" surface (spec 0006 S2)" $ do
  it "a missing \"phases\" key decodes to Nothing" $
    loadCircle "{\"version\":1,\"circle\":{}}"
      `shouldBe` Right emptyCircle

  it "an explicit null \"phases\" decodes to Nothing" $
    loadCircle "{\"version\":1,\"circle\":{\"phases\":null}}"
      `shouldBe` Right emptyCircle

  it "decodes a populated phases object" $
    loadCircle "{\"version\":1,\"circle\":{\"phases\":{\"draw\":1.2,\"converge\":0.6}}}"
      `shouldBe` Right emptyCircle {circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))}

  it "converge = 0 is valid (instant snap)" $
    loadCircle "{\"version\":1,\"circle\":{\"phases\":{\"draw\":1.0,\"converge\":0}}}"
      `shouldBe` Right emptyCircle {circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0))}

  it "rejects draw <= 0 with the position and the reason" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"phases\":{\"draw\":0,\"converge\":0.5}}}"
      ["$.circle.phases", "draw", "> 0"]

  it "rejects a negative converge with the position and the reason" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"phases\":{\"draw\":1.0,\"converge\":-0.1}}}"
      ["$.circle.phases", "converge", ">= 0"]

  it "rejects a missing draw field with the position" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"phases\":{\"converge\":0.5}}}"
      ["$.circle.phases", "draw"]

  it "rejects a missing converge field with the position" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"phases\":{\"draw\":1.0}}}"
      ["$.circle.phases", "converge"]

  it "saveCircle encodes Nothing as an explicit \"phases\":null" $
    BSC.unpack (saveCircle emptyCircle) `shouldSatisfy` ("\"phases\":null" `isInfixOf`)

  prop "roundtrips any circle carrying phases: loadCircle . saveCircle == Right" $
    \(PhasedCircle c) -> loadCircle (saveCircle c) === Right c
