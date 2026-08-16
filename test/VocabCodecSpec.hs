{-# LANGUAGE OverloadedStrings #-}

-- | S5 (func-spec 0021 §7): the JSON surface of all eighteen new
-- constructors, plus the two new radiation modes.
--
-- Three obligations, one per column of the round's ledger:
--
--   * every new constructor survives @saveCircle@ → @loadCircle@
--     unchanged, so a spell written with the new vocabulary is a spell
--     that can be saved and re-opened;
--   * every parameter the samplers assume is checked at the boundary,
--     with a message that names the offending key — the core does no
--     defensive checks, so this is where a degenerate polygon is stopped;
--   * an unknown tag is still the existing located load error listing
--     what /is/ valid, which is what makes a typo in a spell file a
--     five-second fix rather than a silent no-op.
--
-- The fourth obligation of S5 — that @docs\/spell-schema.md@ mentions
-- every key used here — is mechanised by "SchemaDocSpec" against the
-- shipped examples, and goes red on its own if the document falls behind.
module VocabCodecSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (isInfixOf)
import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..), emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, saveCircle)
import Magic.Rune
  ( Element (..)
  , EssenceRune (..)
  , FaceShape (..)
  , ForceField (..)
  , InnerRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- Circles carrying one piece of vocabulary each ---------------------------

withOuter :: OuterRune -> Circle
withOuter rune = emptyCircle {outerRings = TwoOf (Just rune) Nothing}

withInner :: InnerRune -> Circle
withInner rune = emptyCircle {innerRings = TwoOf (Just rune) Nothing}

withElement :: Element -> Circle
withElement element =
  emptyCircle
    { core = Core (Just (EssenceRune element 1.0)) (Nodes Nothing Nothing Nothing Nothing)
    }

withField :: ForceField -> Circle
withField field = emptyCircle {circleFields = [field]}

roundTrips :: Circle -> Expectation
roundTrips circle = loadCircle (saveCircle circle) `shouldBe` Right circle

shouldFailContaining :: BS.ByteString -> [String] -> Expectation
shouldFailContaining doc fragments = case loadCircle doc of
  Left (JsonError msg) ->
    mapM_ (\frag -> msg `shouldSatisfy` (frag `isInfixOf`)) fragments
  other -> expectationFailure ("expected JsonError, got: " ++ show other)

-- | A spell file wrapping one outer-ring rune, so a rejected parameter
-- reports a path through @$.circle.outer[0]@ rather than a bare message.
outerDoc :: BS.ByteString -> BS.ByteString
outerDoc rune = "{\"version\":1,\"circle\":{\"outer\":[" <> rune <> "]}}"

innerDoc :: BS.ByteString -> BS.ByteString
innerDoc rune = "{\"version\":1,\"circle\":{\"inner\":[" <> rune <> "]}}"

fieldsDoc :: BS.ByteString -> BS.ByteString
fieldsDoc field = "{\"version\":1,\"circle\":{\"fields\":[" <> field <> "]}}"

shapeDoc :: BS.ByteString -> BS.ByteString
shapeDoc shape = outerDoc ("{\"rune\":\"shape\",\"shape\":" <> shape <> "}")

-- Generators for the round-trip property -----------------------------------

newtype NewShape = NewShape FaceShape
  deriving (Show)

instance Arbitrary NewShape where
  arbitrary =
    NewShape
      <$> oneof
        [ Polygon <$> choose (3, 12) <*> positiveD
        , do
            points <- choose (2, 9)
            inner <- choose (0, 3)
            delta <- choose (0.1, 2)
            pure (Star points (inner + delta) inner)
        , Cross <$> positiveD <*> positiveD
        , do
            inner <- choose (0, 3)
            delta <- choose (0.1, 2)
            Sector inner (inner + delta) <$> choose (0.1, 6.28)
        ]
    where
      positiveD = choose (0.1, 5)

newtype NewTrajectory = NewTrajectory Trajectory
  deriving (Show)

instance Arbitrary NewTrajectory where
  arbitrary =
    NewTrajectory
      <$> oneof
        [ Wave <$> anyD <*> anyD <*> freqD
        , Ballistic <$> anyD <*> anyD
        , Pulse <$> anyD <*> freqD
        , Zigzag <$> anyD <*> anyD <*> freqD
        ]
    where
      anyD = choose (-10, 10)
      freqD = choose (0, 8)

newtype NewField = NewField ForceField
  deriving (Show)

instance Arbitrary NewField where
  arbitrary =
    NewField
      <$> oneof
        [ Wind <$> nonZeroVec <*> coord <*> choose (0, 4)
        , Turbulence <$> coord <*> choose (0.1, 8)
        , Spring <$> vec <*> choose (0.1, 8)
        ]
    where
      coord = choose (-20, 20)
      vec = V3 <$> coord <*> coord <*> coord
      nonZeroVec = do
        v@(V3 x y z) <- vec
        pure (if x == 0 && y == 0 && z == 0 then V3 0 0 1 else v)

newElements :: [Element]
newElements = [Metal, Wood, Earth, Yin, Yang]

newModes :: [RadiationMode]
newModes = [RadialInward, TangentialSwirl]

spec :: Spec
spec = describe "JSON surface of the new vocabulary (func-spec 0021 S5)" $ do
  describe "round-trip: every new constructor survives save then load" $ do
    it "the five new elements" $
      mapM_ (roundTrips . withElement) newElements

    it "the two new radiation modes" $
      mapM_ (roundTrips . withOuter . RadiateRune) newModes

    prop "the four new face shapes" $ \(NewShape s) ->
      loadCircle (saveCircle (withOuter (ShapeRune s)))
        === Right (withOuter (ShapeRune s))

    prop "the four new trajectories" $ \(NewTrajectory t) ->
      loadCircle (saveCircle (withInner (TrajectoryRune t)))
        === Right (withInner (TrajectoryRune t))

    prop "the three new force fields" $ \(NewField f) ->
      loadCircle (saveCircle (withField f)) === Right (withField f)

  describe "the elements' own tags" $ do
    it "decodes each of the five new names" $
      mapM_
        ( \(name, element) ->
            fmap (coreCenter . core) (loadCircle (elementDoc name))
              `shouldBe` Right (Just (EssenceRune element 1.0))
        )
        (zip ["metal", "wood", "earth", "yin", "yang"] newElements)

    it "still rejects an unknown element, listing all nine" $
      shouldFailContaining
        (elementDoc "plasma")
        ["unknown element", "plasma", "metal", "yin", "yang", "neutral"]

  describe "parameter validation, one failing witness each" $ do
    it "polygon needs at least three sides" $
      shouldFailContaining
        (shapeDoc "{\"kind\":\"polygon\",\"sides\":2,\"radius\":1}")
        ["sides", ">= 3", "$.circle.outer"]

    it "polygon needs a positive radius" $
      shouldFailContaining
        (shapeDoc "{\"kind\":\"polygon\",\"sides\":5,\"radius\":0}")
        ["radius", "> 0", "$.circle.outer"]

    it "star needs at least two points" $
      shouldFailContaining
        (shapeDoc "{\"kind\":\"star\",\"points\":1,\"outer\":2,\"inner\":1}")
        ["points", ">= 2", "$.circle.outer"]

    it "star needs inner < outer" $
      shouldFailContaining
        (shapeDoc "{\"kind\":\"star\",\"points\":5,\"outer\":1,\"inner\":2}")
        ["star needs inner < outer", "$.circle.outer"]

    it "cross needs a positive width" $
      shouldFailContaining
        (shapeDoc "{\"kind\":\"cross\",\"length\":2,\"width\":0}")
        ["width", "> 0", "$.circle.outer"]

    it "sector rejects a zero sweep" $
      shouldFailContaining
        (shapeDoc "{\"kind\":\"sector\",\"inner\":0.5,\"outer\":1.5,\"sweep\":0}")
        ["sweep", "$.circle.outer"]

    it "sector rejects a sweep past a full turn" $
      shouldFailContaining
        (shapeDoc "{\"kind\":\"sector\",\"inner\":0.5,\"outer\":1.5,\"sweep\":7}")
        ["sweep", "$.circle.outer"]

    it "sector needs inner < outer" $
      shouldFailContaining
        (shapeDoc "{\"kind\":\"sector\",\"inner\":2,\"outer\":1,\"sweep\":1}")
        ["sector needs inner < outer", "$.circle.outer"]

    it "wave rejects a negative frequency" $
      shouldFailContaining
        (innerDoc "{\"rune\":\"trajectory\",\"kind\":\"wave\",\"speed\":1,\"amplitude\":1,\"freq\":-1}")
        ["freq", ">= 0", "$.circle.inner"]

    it "pulse rejects a negative frequency" $
      shouldFailContaining
        (innerDoc "{\"rune\":\"trajectory\",\"kind\":\"pulse\",\"speed\":1,\"freq\":-2}")
        ["freq", ">= 0", "$.circle.inner"]

    it "zigzag rejects a negative frequency" $
      shouldFailContaining
        (innerDoc "{\"rune\":\"trajectory\",\"kind\":\"zigzag\",\"speed\":1,\"amplitude\":1,\"freq\":-0.5}")
        ["freq", ">= 0", "$.circle.inner"]

    it "wind rejects a zero direction, like vortex rejects a zero axis" $
      shouldFailContaining
        (fieldsDoc "{\"kind\":\"wind\",\"dir\":[0,0,0],\"strength\":1,\"turbulence\":0}")
        ["non-zero", "$.circle.fields"]

    it "wind rejects negative turbulence" $
      shouldFailContaining
        (fieldsDoc "{\"kind\":\"wind\",\"dir\":[0,1,0],\"strength\":1,\"turbulence\":-1}")
        ["turbulence", ">= 0", "$.circle.fields"]

    it "turbulence needs a positive scale" $
      shouldFailContaining
        (fieldsDoc "{\"kind\":\"turbulence\",\"strength\":1,\"scale\":0}")
        ["scale", "> 0", "$.circle.fields"]

    it "spring needs a positive stiffness" $
      shouldFailContaining
        (fieldsDoc "{\"kind\":\"spring\",\"center\":[0,0,0],\"k\":0}")
        ["k", "> 0", "$.circle.fields"]

  describe "unknown tags still list what is valid" $ do
    it "an unknown shape kind names all eight" $
      shouldFailContaining
        (shapeDoc "{\"kind\":\"hexagram\",\"size\":1}")
        ["unknown shape kind", "hexagram", "polygon", "star", "cross", "sector", "ring"]

    it "an unknown trajectory kind names all seven built-ins" $
      shouldFailContaining
        (innerDoc "{\"rune\":\"trajectory\",\"kind\":\"corkscrew\",\"speed\":1}")
        ["unknown trajectory kind", "corkscrew", "wave", "ballistic", "pulse", "zigzag"]

    it "an unknown field kind names all six" $
      shouldFailContaining
        (fieldsDoc "{\"kind\":\"magnetism\",\"strength\":1}")
        ["unknown force field kind", "magnetism", "wind", "turbulence", "spring"]

    it "an unknown radiation mode names all four" $
      shouldFailContaining
        (outerDoc "{\"rune\":\"radiate\",\"mode\":\"sideways\"}")
        ["unknown radiation mode", "sideways", "radial-inward", "tangential-swirl"]
  where
    elementDoc name =
      "{\"version\":1,\"circle\":{\"core\":{\"center\":{\"element\":\""
        <> name
        <> "\",\"power\":1.0}}}}"
