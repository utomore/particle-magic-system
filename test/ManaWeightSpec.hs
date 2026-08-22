-- | T1 (magic-semantics F003): 'manaCost' — the mana weight table over the
-- five rune slots. Purely structural: it looks only at which constructors
-- occupy which slots, never at particle counts or 'essPower'.
module ManaWeightSpec (spec) where

import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..), emptyCircle)
import Magic.Compile (manaCost)
import Magic.Expr (Expr (..), ExprV3 (..))
import Magic.Rune
  ( BillboardShape (..)
  , BridgeRune (..)
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
import Magic.Types (Seconds (..))
import Test.Hspec

noNodes :: Nodes (Maybe NodeRune)
noNodes = Nodes Nothing Nothing Nothing Nothing

sampleExpr :: Expr
sampleExpr = Lit 1

withOuterA :: OuterRune -> Circle
withOuterA r = emptyCircle {outerRings = TwoOf (Just r) Nothing}

withBridge :: BridgeRune -> Circle
withBridge r = emptyCircle {interLayer = Just r}

withInnerA :: InnerRune -> Circle
withInnerA r = emptyCircle {innerRings = TwoOf (Just r) Nothing}

withEssence :: Double -> Element -> Circle
withEssence power e = emptyCircle {core = Core (Just (EssenceRune e power)) noNodes}

withNorthNode :: Double -> Circle
withNorthNode bias = emptyCircle {core = Core Nothing (noNodes {north = Just (DirBias bias)})}

spec :: Spec
spec = describe "manaCost (magic-semantics F003 T1)" $ do
  it "the all-empty circle costs 0 mana" $
    manaCost emptyCircle `shouldBe` 0

  describe "OuterRune weight table" $ do
    it "ShapeRune costs 2" $
      manaCost (withOuterA (ShapeRune (HollowSquare 1))) `shouldBe` 2
    it "RadiateRune costs 1" $
      manaCost (withOuterA (RadiateRune AlongNormal)) `shouldBe` 1
    it "RangeRune costs 3" $
      manaCost (withOuterA (RangeRune sampleExpr)) `shouldBe` 3
    it "StyleRune costs 1" $
      manaCost (withOuterA (StyleRune BillboardSquare)) `shouldBe` 1

  describe "BridgeRune weight table" $ do
    it "PhaseRune costs 1" $
      manaCost (withBridge (PhaseRune (Seconds 1))) `shouldBe` 1
    it "ConvergeRune costs 3" $
      manaCost (withBridge (ConvergeRune sampleExpr)) `shouldBe` 3
    it "AmplifyRune costs 3" $
      manaCost (withBridge (AmplifyRune sampleExpr)) `shouldBe` 3

  describe "InnerRune weight table" $ do
    it "TrajectoryRune costs 2" $
      manaCost (withInnerA (TrajectoryRune (Forward 1))) `shouldBe` 2
    it "TimingRune costs 1" $
      manaCost
        (withInnerA (TimingRune (Envelope (Seconds 0) (Seconds 1) (Seconds 1))))
        `shouldBe` 1
    it "FormulaRune costs 4" $
      manaCost (withInnerA (FormulaRune (ExprV3 sampleExpr sampleExpr sampleExpr))) `shouldBe` 4

  describe "EssenceRune weight table (by element)" $ do
    it "Neutral costs 0" $
      manaCost (withEssence 1.0 Neutral) `shouldBe` 0
    mapM_
      (\e -> it (show e ++ " costs 2 (五行)") $ manaCost (withEssence 1.0 e) `shouldBe` 2)
      [Fire, Water, Metal, Wood, Earth]
    mapM_
      (\e -> it (show e ++ " costs 3") $ manaCost (withEssence 1.0 e) `shouldBe` 3)
      [Lightning, Yin, Yang]

  it "essPower does not affect manaCost, only which element is chosen" $
    manaCost (withEssence 0.1 Fire) `shouldBe` manaCost (withEssence 99.0 Fire)

  describe "NodeRune weight table" $ do
    it "each active node costs 1" $
      manaCost (withNorthNode 1.0) `shouldBe` 1
    it "all four active nodes cost 4" $
      manaCost
        emptyCircle
          { core =
              Core
                Nothing
                ( Nodes
                    { north = Just (DirBias 1)
                    , south = Just (DirBias 1)
                    , east = Just (DirBias 1)
                    , west = Just (DirBias 1)
                    }
                )
          }
        `shouldBe` 4

  it "multiple occupied slots sum their weights" $
    manaCost
      emptyCircle
        { outerRings = TwoOf (Just (ShapeRune (HollowSquare 1))) (Just (StyleRune BillboardSquare))
        , interLayer = Just (PhaseRune (Seconds 1))
        , innerRings = TwoOf (Just (TrajectoryRune (Forward 1))) Nothing
        , core =
            Core
              (Just (EssenceRune Fire 1.0))
              (Nodes {north = Just (DirBias 1), south = Nothing, east = Nothing, west = Nothing})
        }
      `shouldBe` (2 + 1 + 1 + 2 + 2 + 1)
