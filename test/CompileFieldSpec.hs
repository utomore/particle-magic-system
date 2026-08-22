-- | S4 (func-spec 0007 §8): 'circleFields' reaches 'spellFields' intact
-- and changes nothing else. Fields are compiled data, not a fold input
-- (ADR-0010 D4), so the interpreter's every other output must be
-- literally the value spec 0006 produced.
module CompileFieldSpec (spec) where

import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Compile (CompiledSpell (..), compile)
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , ForceField (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..), V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Arbitrary (..), Gen, choose, elements, listOf, oneof, resize, sized)

-- | A spread of circles covering the empty fold, a phased fold and a
-- fully-loaded fold — the three shapes whose compiled output differs.
newtype AnyCircle = AnyCircle Circle
  deriving (Show)

instance Arbitrary AnyCircle where
  arbitrary =
    AnyCircle
      <$> oneof
        [ pure emptyCircle
        , pure loadedCircle
        , pure (loadedCircle {circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))})
        , pure (emptyCircle {circlePhases = Just (PhaseConfig (Seconds 0.8) (Seconds 0))})
        , do
            power <- choose (0.1, 4)
            element <- elements [Neutral, Fire, Water, Lightning]
            pure emptyCircle {core = Core (Just (EssenceRune element power)) noNodes}
        ]

noNodes :: Nodes (Maybe NodeRune)
noNodes = Nodes Nothing Nothing Nothing Nothing

loadedCircle :: Circle
loadedCircle =
  Circle
    { outerRings =
        TwoOf (Just (ShapeRune (Ring 1 1.5))) (Just (RadiateRune AlongNormal))
    , interLayer = Just (PhaseRune (Seconds 0.5))
    , innerRings =
        TwoOf
          (Just (TrajectoryRune (Spiral 6 0.4 2)))
          (Just (TimingRune (Envelope (Seconds 0) (Seconds 4) (Seconds 2))))
    , core =
        Core
          { coreCenter = Just (EssenceRune Fire 1.5)
          , coreNodes = Nodes (Just (DirBias 0.4)) Nothing (Just (DirBias 0.2)) Nothing
          }
    , circlePhases = Nothing
    , circleFields = []
    , circleAnchors = Nothing
    , circleSigil = Nothing
    , circleVolume = Nothing
    }

newtype AnyFields = AnyFields [ForceField]
  deriving (Show)

instance Arbitrary AnyFields where
  arbitrary = AnyFields <$> sized (\n -> resize (min n 4) (listOf genField))

genField :: Gen ForceField
genField =
  oneof
    [ Gravity <$> genV3
    , PointAttractor <$> genV3 <*> choose (-10, 10) <*> choose (0.1, 2)
    , Vortex <$> genV3 <*> genV3 <*> choose (-8, 8) <*> choose (0, 3)
    ]
  where
    genV3 = V3 <$> coord <*> coord <*> coord
    coord = choose (-5, 5)

spec :: Spec
spec = describe "compile: circleFields passes through to spellFields (spec 0007 S4)" $ do
  it "emptyCircle carries no fields" $
    circleFields emptyCircle `shouldBe` []

  it "the empty circle compiles to a spell with no fields" $
    fmap spellFields (compile emptyCircle) `shouldBe` Right []

  prop "any field list arrives at spellFields verbatim, in order" $
    \(AnyCircle c) (AnyFields fs) ->
      fmap spellFields (compile c {circleFields = fs}) == Right fs

  prop "fields change nothing else the interpreter produces" $
    \(AnyCircle c) (AnyFields fs) ->
      let withFields = compile c {circleFields = fs}
          without = compile c {circleFields = []}
          strip spell = spell {spellFields = []}
       in fmap strip withFields == fmap strip without

  prop "in particular lifetime, budget, emitters and the phase plan are untouched" $
    \(AnyCircle c) (AnyFields fs) ->
      let key spell =
            ( spellLifetime spell
            , spellBudget spell
            , spellEmitters spell
            , spellPhases spell
            )
       in fmap key (compile c {circleFields = fs}) == fmap key (compile c)

  it "a field list survives compilation of a fully-loaded circle unchanged" $ do
    let fs =
          [ Gravity (V3 0 (-3) 0)
          , PointAttractor (V3 0 0 4) 6 0.5
          , Vortex (V3 0 0 0) (V3 0 0 1) 2 0.3
          ]
    fmap spellFields (compile loadedCircle {circleFields = fs}) `shouldBe` Right fs
