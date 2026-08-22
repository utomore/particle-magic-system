-- | T-S1 (func-spec 0004 §8): the Expr runes' fold landing spots — one
-- judgment per row of the §4.3 table, the same-kind override rule for
-- 'FormulaRune' × 'TrajectoryRune', and the backward-compatibility
-- guarantee that circles without Expr runes compile with every new field
-- 'Nothing'.
module CompileExprSpec (spec) where

import qualified Data.Vector as V
import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( Appearance (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , compile
  )
import Magic.Expr (BinOp (..), Expr (..), ExprV3 (..), Var (..))
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , EssenceRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..))
import Test.Hspec

theEmitter :: Circle -> EmitterSpec
theEmitter c = case compile c of
  Right spell | V.length (spellEmitters spell) == 1 -> V.head (spellEmitters spell)
  other -> error ("expected exactly one emitter, got: " ++ show other)

-- Small distinct formulas so landing spots are unmistakable.
eA, eB :: Expr
eA = Bin Mul (Var VarT) (Lit 2)
eB = Bin Add (Lit 1) (Var VarLife)

v3A, v3B :: ExprV3
v3A = ExprV3 (Var VarT) (Lit 0) (Lit 1)
v3B = ExprV3 (Lit 5) (Var VarLife) (Var VarT)

isFormula :: Trajectory -> Bool
isFormula t = case t of
  Formula _ -> True
  _ -> False

spec :: Spec
spec = describe "Expr rune fold landing spots (spec 0004 S1)" $ do
  describe "the §4.3 table, row by row" $ do
    it "RangeRune (outer) lands on motRange" $ do
      let em = theEmitter emptyCircle {outerRings = TwoOf (Just (RangeRune eA)) Nothing}
      motRange (emMotion em) `shouldBe` Just eA
      -- The other new fields stay empty.
      motConverge (emMotion em) `shouldBe` Nothing
      appAmplify (emAppearance em) `shouldBe` Nothing

    it "ConvergeRune (bridge) lands on motConverge" $ do
      let em = theEmitter emptyCircle {interLayer = Just (ConvergeRune eA)}
      motConverge (emMotion em) `shouldBe` Just eA
      motRange (emMotion em) `shouldBe` Nothing
      appAmplify (emAppearance em) `shouldBe` Nothing

    it "AmplifyRune (bridge) lands on appAmplify" $ do
      let em = theEmitter emptyCircle {interLayer = Just (AmplifyRune eB)}
      appAmplify (emAppearance em) `shouldBe` Just eB
      motRange (emMotion em) `shouldBe` Nothing
      motConverge (emMotion em) `shouldBe` Nothing

    it "FormulaRune (inner) lands on motTraject as Formula" $ do
      let em = theEmitter emptyCircle {innerRings = TwoOf (Just (FormulaRune v3A)) Nothing}
      motTraject (emMotion em) `shouldBe` Formula v3A

  describe "same-kind override: FormulaRune and TrajectoryRune share a kind" $ do
    let combos =
          [ ("trajectory then formula", TrajectoryRune (Forward 1), FormulaRune v3B, Formula v3B)
          , ("formula then trajectory", FormulaRune v3A, TrajectoryRune (Orbit 2 3), Orbit 2 3)
          , ("formula then formula", FormulaRune v3A, FormulaRune v3B, Formula v3B)
          , ("trajectory then trajectory", TrajectoryRune (Forward 1), TrajectoryRune (Orbit 2 3), Orbit 2 3)
          ]
    mapM_
      ( \(name, ringA', ringB', expected) ->
          it (name ++ ": ringB wins") $ do
            let c = emptyCircle {innerRings = TwoOf (Just ringA') (Just ringB')}
            motTraject (emMotion (theEmitter c)) `shouldBe` expected
      )
      combos

    it "a FormulaRune does not disturb a different-kind TimingRune" $ do
      let timing = Envelope (Seconds 1) (Seconds 4) (Seconds 2)
          c = emptyCircle {innerRings = TwoOf (Just (TimingRune timing)) (Just (FormulaRune v3A))}
          em = theEmitter c
      motTraject (emMotion em) `shouldBe` Formula v3A
      emSpawn em `shouldBe` timing

  it "two RangeRunes: ringB wins" $ do
    let c = emptyCircle {outerRings = TwoOf (Just (RangeRune eA)) (Just (RangeRune eB))}
    motRange (emMotion (theEmitter c)) `shouldBe` Just eB

  describe "no Expr runes → every new field is Nothing (0002 behavior intact)" $ do
    it "the empty circle" $ do
      let em = theEmitter emptyCircle
      motRange (emMotion em) `shouldBe` Nothing
      motConverge (emMotion em) `shouldBe` Nothing
      appAmplify (emAppearance em) `shouldBe` Nothing
      motTraject (emMotion em) `shouldSatisfy` (not . isFormula)

    it "a circle using every 0002 rune" $ do
      let c =
            Circle
              { outerRings =
                  TwoOf (Just (ShapeRune (Ring 1 2))) (Just (RadiateRune RadialOutward))
              , interLayer = Just (PhaseRune (Seconds 0.5))
              , innerRings =
                  TwoOf
                    (Just (TrajectoryRune (Spiral 6 0.4 2)))
                    (Just (TimingRune (Envelope (Seconds 0) (Seconds 4) (Seconds 2))))
              , core =
                  Core
                    { coreCenter = Just (EssenceRune Fire 1.5)
                    , coreNodes = Nodes Nothing Nothing Nothing Nothing
                    }
              , circlePhases = Nothing
              , circleFields = []
              , circleAnchors = Nothing
              , circleSigil = Nothing
              , circleVolume = Nothing
              }
          em = theEmitter c
      motRange (emMotion em) `shouldBe` Nothing
      motConverge (emMotion em) `shouldBe` Nothing
      appAmplify (emAppearance em) `shouldBe` Nothing
      motTraject (emMotion em) `shouldBe` Spiral 6 0.4 2
