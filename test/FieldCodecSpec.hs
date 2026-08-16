{-# LANGUAGE OverloadedStrings #-}

-- | S5 (func-spec 0007 §8): the @"fields"@ JSON surface. A pure v1
-- extension (§4.6), so the first thing it has to prove is that every
-- spell file written before it still decodes to "no fields" — that is
-- half of the ADR-0010 D9 compatibility law, established at the boundary.
-- Then: the three kinds decode and roundtrip, and the boundary rejects
-- the parameters that would make the core's arithmetic degenerate, with
-- a JSON path pointing at the offender.
module FieldCodecSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.List (isInfixOf)
import Magic.Circle (Circle (..), emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, saveCircle)
import Magic.Rune (ForceField (..))
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

shouldFailContaining :: BS.ByteString -> [String] -> Expectation
shouldFailContaining doc fragments = case loadCircle doc of
  Left (JsonError msg) ->
    mapM_ (\frag -> msg `shouldSatisfy` (frag `isInfixOf`)) fragments
  other -> expectationFailure ("expected JsonError, got: " ++ show other)

withFields :: BS.ByteString -> BS.ByteString
withFields fieldsDoc = "{\"version\":1,\"circle\":{\"fields\":" <> fieldsDoc <> "}}"

fieldsOf :: BS.ByteString -> Either LoadError [ForceField]
fieldsOf doc = fmap circleFields (loadCircle doc)

-- | Values that survive the Float/Double roundtrip exactly (they are
-- generated as Float and encoded through 'Double'), so the property can
-- assert equality rather than approximation.
coord :: Gen Float
coord = choose (-20, 20)

genV3 :: Gen V3
genV3 = V3 <$> coord <*> coord <*> coord

genField :: Gen ForceField
genField =
  oneof
    [ Gravity <$> genV3
    , PointAttractor <$> genV3 <*> choose (-25, 25) <*> choose (0.01, 5)
    , Vortex <$> genV3 <*> genNonZeroV3 <*> choose (-25, 25) <*> choose (0, 5)
    ]
  where
    genNonZeroV3 = genV3 `suchThat` (\(V3 x y z) -> x /= 0 || y /= 0 || z /= 0)

newtype FieldCircle = FieldCircle Circle
  deriving (Show)

instance Arbitrary FieldCircle where
  arbitrary = do
    fs <- resize 4 (listOf genField)
    pure (FieldCircle emptyCircle {circleFields = fs})

allAssets :: [FilePath]
allAssets =
  [ "assets/spells/bare-sigil.json"
  , "assets/spells/converge-flame.json"
  , "assets/spells/empty.json"
  , "assets/spells/grand-sigil.json"
  , "assets/spells/lissajous.json"
  , "assets/spells/pulse-ring.json"
  , "assets/spells/ring-fire.json"
  , "assets/spells/spiral-spark.json"
  , "assets/spells/square-burst.json"
  ]

spec :: Spec
spec = describe "Magic.Codec \"fields\" surface (spec 0007 S5)" $ do
  describe "the compatibility case: no fields" $ do
    it "a missing \"fields\" key decodes to []" $
      fieldsOf "{\"version\":1,\"circle\":{}}" `shouldBe` Right []

    it "an explicit null decodes to []" $
      fieldsOf (withFields "null") `shouldBe` Right []

    it "an empty array decodes to []" $
      fieldsOf (withFields "[]") `shouldBe` Right []

    it "every shipped pre-0007 asset decodes to no fields" $
      mapM_
        ( \path -> do
            bytes <- BS.readFile path
            case loadCircle bytes of
              Right circle -> circleFields circle `shouldBe` []
              Left err -> expectationFailure (path ++ ": " ++ show err)
        )
        allAssets

  describe "the three kinds decode" $ do
    it "gravity" $
      fieldsOf (withFields "[{\"kind\":\"gravity\",\"accel\":[0,-3.0,0]}]")
        `shouldBe` Right [Gravity (V3 0 (-3) 0)]

    it "attractor" $
      fieldsOf
        (withFields "[{\"kind\":\"attractor\",\"center\":[0,0,4],\"strength\":6.0,\"softening\":0.5}]")
        `shouldBe` Right [PointAttractor (V3 0 0 4) 6 0.5]

    it "vortex" $
      fieldsOf
        ( withFields
            "[{\"kind\":\"vortex\",\"center\":[0,0,0],\"axis\":[0,0,1],\"strength\":2.0,\"falloff\":0.3}]"
        )
        `shouldBe` Right [Vortex (V3 0 0 0) (V3 0 0 1) 2 0.3]

    it "several fields keep their order" $
      fieldsOf
        ( withFields
            "[{\"kind\":\"gravity\",\"accel\":[1,0,0]},{\"kind\":\"gravity\",\"accel\":[0,2,0]}]"
        )
        `shouldBe` Right [Gravity (V3 1 0 0), Gravity (V3 0 2 0)]

  describe "roundtrip" $ do
    prop "loadCircle . saveCircle is the identity on fields" $
      \(FieldCircle c) -> loadCircle (saveCircle c) === Right c

    it "saveCircle writes an explicit empty array for a fieldless circle" $ do
      let doc = BSC.unpack (saveCircle emptyCircle)
      doc `shouldSatisfy` ("\"fields\":[]" `isInfixOf`)

  describe "boundary validation (errors carry a JSON path)" $ do
    it "rejects softening = 0 (the attractor's singularity guard)" $
      shouldFailContaining
        (withFields "[{\"kind\":\"attractor\",\"center\":[0,0,0],\"strength\":1,\"softening\":0}]")
        ["$.circle.fields[0]", "softening must be > 0"]

    it "rejects negative softening" $
      shouldFailContaining
        (withFields "[{\"kind\":\"attractor\",\"center\":[0,0,0],\"strength\":1,\"softening\":-0.5}]")
        ["$.circle.fields[0]", "softening must be > 0"]

    it "rejects a negative falloff" $
      shouldFailContaining
        ( withFields
            "[{\"kind\":\"gravity\",\"accel\":[0,-1,0]},\
            \{\"kind\":\"vortex\",\"center\":[0,0,0],\"axis\":[0,0,1],\"strength\":1,\"falloff\":-1}]"
        )
        ["$.circle.fields[1]", "falloff must be >= 0"]

    it "rejects a zero axis" $
      shouldFailContaining
        ( withFields
            "[{\"kind\":\"vortex\",\"center\":[0,0,0],\"axis\":[0,0,0],\"strength\":1,\"falloff\":0}]"
        )
        ["$.circle.fields[0].axis", "non-zero"]

    it "rejects an unknown field kind and lists the valid ones" $
      shouldFailContaining
        -- "wind" was the stand-in for an unknown kind until func-spec
        -- 0021 made it a real one; "magnetism" is deliberately still
        -- unknown, and 0021 §7-2 records why it stays that way.
        (withFields "[{\"kind\":\"magnetism\"}]")
        ["$.circle.fields[0]", "gravity, attractor, vortex, wind, turbulence, spring"]

    it "rejects a vector that is not three numbers" $
      shouldFailContaining
        (withFields "[{\"kind\":\"gravity\",\"accel\":[0,-3]}]")
        ["$.circle.fields[0].accel", "3 numbers"]

    it "rejects a non-array \"fields\" value" $
      shouldFailContaining
        (withFields "{\"kind\":\"gravity\"}")
        ["$.circle.fields", "array of force fields"]
