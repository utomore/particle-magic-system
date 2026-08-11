{-# LANGUAGE OverloadedStrings #-}

-- | T4 (func-spec 0001 §8): minimal JSON v1 contract.
module CodecSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Magic.Circle (emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, renderLoadError, saveCircle)
import Test.Hspec

spec :: Spec
spec = describe "Magic.Codec (spell JSON v1, skeleton subset)" $ do
  it "roundtrips: loadCircle . saveCircle == Right" $
    loadCircle (saveCircle emptyCircle) `shouldBe` Right emptyCircle

  it "loads the minimal v1 document" $
    loadCircle "{\"version\":1,\"name\":\"x\",\"circle\":{}}"
      `shouldBe` Right emptyCircle

  it "loads a document without the optional name" $
    loadCircle "{\"version\":1,\"circle\":{}}" `shouldBe` Right emptyCircle

  it "rejects version /= 1 and the error mentions the version" $ do
    let result = loadCircle "{\"version\":7,\"circle\":{}}"
    result `shouldBe` Left (UnsupportedVersion 7)
    case result of
      Left err -> renderLoadError err `shouldSatisfy` ("7" `isInfixOf`)
      Right _ -> expectationFailure "expected a LoadError"

  it "rejects a missing version field" $
    loadCircle "{\"circle\":{}}" `shouldSatisfy` isLeft

  it "rejects malformed JSON with a position in the error" $ do
    let result = loadCircle "{\"version\":1, oops"
    case result of
      Left (JsonError msg) -> do
        msg `shouldSatisfy` ("line 1" `isInfixOf`)
        msg `shouldSatisfy` ("column" `isInfixOf`)
      other -> expectationFailure ("expected JsonError, got: " ++ show other)

  it "reports the line of an error in multi-line JSON" $ do
    -- The parser stops at the trailing comma on line 2 (a key literal must
    -- follow it); the reported position is that stop point.
    let result = loadCircle "{\n  \"version\": 1,\n  oops\n}"
    case result of
      Left (JsonError msg) -> do
        msg `shouldSatisfy` ("line 2" `isInfixOf`)
        msg `shouldSatisfy` ("column" `isInfixOf`)
      other -> expectationFailure ("expected JsonError, got: " ++ show other)

  it "rejects a non-object circle with the JSON path in the error" $ do
    let result = loadCircle "{\"version\":1,\"circle\":3}"
    case result of
      Left (JsonError msg) -> msg `shouldSatisfy` ("$" `isInfixOf`)
      other -> expectationFailure ("expected JsonError, got: " ++ show other)

  it "loads the shipped sample assets/spells/empty.json" $ do
    bytes <- BS.readFile "assets/spells/empty.json"
    loadCircle bytes `shouldBe` Right emptyCircle

  it "sample file is the documented skeleton schema (version 1)" $ do
    bytes <- BS.readFile "assets/spells/empty.json"
    BSC.unpack bytes `shouldSatisfy` ("\"version\"" `isInfixOf`)
