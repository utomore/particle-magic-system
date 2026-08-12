{-# LANGUAGE OverloadedStrings #-}

-- | T-S2 (func-spec 0002 §8): the full slot JSON schema — roundtrip
-- property, backward compatibility with the 0001 skeleton subset, and
-- load errors (unknown tag, misplaced tag, invalid parameters, oversized
-- ring array) with JSON positions in the message.
module CircleCodecSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (isInfixOf)
import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..), emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, saveCircle)
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..), V2 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- Generators -----------------------------------------------------------------
-- Only codec-valid values: geometry positive (rInner < rOuter), power > 0,
-- envelope fields >= 0 with lifetime > 0, shift >= 0.

genPositive :: Gen Double
genPositive = choose (0.05, 50)

genPositiveF :: Gen Float
genPositiveF = realToFrac <$> genPositive

genSigned :: Gen Double
genSigned = choose (-20, 20)

genShape :: Gen FaceShape
genShape =
  oneof
    [ HollowSquare <$> genPositive
    , Rect <$> (V2 <$> genPositiveF <*> genPositiveF)
    , do
        rIn <- genPositive
        extra <- genPositive
        pure (Ring rIn (rIn + extra))
    , Diamond <$> genPositive
    ]

genOuter :: Gen OuterRune
genOuter =
  oneof
    [ ShapeRune <$> genShape
    , RadiateRune <$> elements [AlongNormal, RadialOutward]
    ]

genTrajectory :: Gen Trajectory
genTrajectory =
  oneof
    [ Forward <$> genSigned
    , Spiral <$> genSigned <*> genPositive <*> genSigned
    , Orbit <$> genPositive <*> genSigned
    ]

genEnvelope :: Gen Envelope
genEnvelope = do
  delay <- choose (0, 5)
  duration <- choose (0, 10)
  lifetime <- genPositive
  pure (Envelope (Seconds delay) (Seconds duration) (Seconds lifetime))

genInner :: Gen InnerRune
genInner = oneof [TrajectoryRune <$> genTrajectory, TimingRune <$> genEnvelope]

genBridge :: Gen BridgeRune
genBridge = PhaseRune . Seconds <$> choose (0, 5)

genEssence :: Gen EssenceRune
genEssence =
  EssenceRune
    <$> elements [Neutral, Fire, Water, Lightning]
    <*> choose (0.05, 10)

genNode :: Gen NodeRune
genNode = DirBias <$> genSigned

genCircle :: Gen Circle
genCircle =
  Circle
    <$> (TwoOf <$> genMaybe genOuter <*> genMaybe genOuter)
    <*> genMaybe genBridge
    <*> (TwoOf <$> genMaybe genInner <*> genMaybe genInner)
    <*> (Core <$> genMaybe genEssence <*> genNodes)
  where
    genMaybe g = oneof [pure Nothing, Just <$> g]
    genNodes =
      Nodes
        <$> genMaybe genNode
        <*> genMaybe genNode
        <*> genMaybe genNode
        <*> genMaybe genNode

newtype AnyCircle = AnyCircle Circle
  deriving (Show)

instance Arbitrary AnyCircle where
  arbitrary = AnyCircle <$> genCircle

-- Helpers --------------------------------------------------------------------

shouldFailContaining :: BS.ByteString -> [String] -> Expectation
shouldFailContaining doc fragments = case loadCircle doc of
  Left (JsonError msg) ->
    mapM_ (\frag -> msg `shouldSatisfy` (frag `isInfixOf`)) fragments
  other -> expectationFailure ("expected JsonError, got: " ++ show other)

spec :: Spec
spec = describe "Magic.Codec full slot schema (spec 0002 S2)" $ do
  prop "roundtrips any circle: loadCircle . saveCircle == Right" $
    \(AnyCircle c) -> loadCircle (saveCircle c) === Right c

  it "decodes the 0001 skeleton subset: empty circle object" $
    loadCircle "{\"version\":1,\"name\":\"x\",\"circle\":{}}"
      `shouldBe` Right emptyCircle

  it "loads the shipped assets/spells/empty.json byte-for-byte unchanged" $ do
    bytes <- BS.readFile "assets/spells/empty.json"
    loadCircle bytes `shouldBe` Right emptyCircle

  it "treats missing keys and explicit nulls as empty slots" $
    loadCircle
      "{\"version\":1,\"circle\":{\"outer\":null,\"bridge\":null,\"inner\":[null],\"core\":{\"center\":null,\"nodes\":{\"north\":null}}}}"
      `shouldBe` Right emptyCircle

  it "decodes the spec §4.7 full example" $ do
    let doc =
          "{\"version\":1,\"name\":\"ring-fire\",\"circle\":{\
          \\"outer\":[{\"rune\":\"shape\",\"shape\":{\"kind\":\"ring\",\"rInner\":1.0,\"rOuter\":1.5}},\
          \{\"rune\":\"radiate\",\"mode\":\"along-normal\"}],\
          \\"bridge\":{\"rune\":\"phase\",\"shift\":0.5},\
          \\"inner\":[{\"rune\":\"trajectory\",\"kind\":\"spiral\",\"speed\":6.0,\"radius\":0.4,\"freq\":2.0},\
          \{\"rune\":\"timing\",\"delay\":0.0,\"duration\":4.0,\"lifetime\":2.0}],\
          \\"core\":{\"center\":{\"element\":\"fire\",\"power\":1.5},\
          \\"nodes\":{\"north\":{\"rune\":\"dir-bias\",\"strength\":0.4},\"south\":null,\"east\":null,\"west\":null}}}}"
    loadCircle doc
      `shouldBe` Right
        Circle
          { outerRings =
              TwoOf
                (Just (ShapeRune (Ring 1.0 1.5)))
                (Just (RadiateRune AlongNormal))
          , interLayer = Just (PhaseRune (Seconds 0.5))
          , innerRings =
              TwoOf
                (Just (TrajectoryRune (Spiral 6.0 0.4 2.0)))
                (Just (TimingRune (Envelope (Seconds 0) (Seconds 4) (Seconds 2))))
          , core =
              Core
                { coreCenter = Just (EssenceRune Fire 1.5)
                , coreNodes = Nodes (Just (DirBias 0.4)) Nothing Nothing Nothing
                }
          }

  it "rejects an unknown rune tag with the position and the valid tags" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"inner\":[{\"rune\":\"formula\"}]}}"
      ["$.circle.inner[0]", "formula", "trajectory, timing"]

  it "rejects a misplaced tag (behavior rune in the outer ring)" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"trajectory\",\"kind\":\"forward\",\"speed\":1}]}}"
      ["$.circle.outer[0]", "shape, radiate"]

  it "rejects a negative radius with the position in the error" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"shape\",\"shape\":{\"kind\":\"ring\",\"rInner\":-1,\"rOuter\":2}}]}}"
      ["$.circle.outer[0]", "rInner", "> 0"]

  it "rejects rInner >= rOuter" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"shape\",\"shape\":{\"kind\":\"ring\",\"rInner\":2,\"rOuter\":2}}]}}"
      ["$.circle.outer[0]", "rInner < rOuter"]

  it "rejects power <= 0" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"core\":{\"center\":{\"element\":\"fire\",\"power\":0}}}}"
      ["$.circle.core", "power", "> 0"]

  it "rejects a zero-lifetime envelope" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"inner\":[{\"rune\":\"timing\",\"delay\":0,\"duration\":1,\"lifetime\":0}]}}"
      ["$.circle.inner[0]", "lifetime"]

  it "rejects an outer ring array of length 3" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"outer\":[null,null,null]}}"
      ["$.circle.outer", "at most 2"]

  it "still rejects version /= 1" $
    loadCircle "{\"version\":7,\"circle\":{}}"
      `shouldBe` Left (UnsupportedVersion 7)
