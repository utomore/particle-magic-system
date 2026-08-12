-- | T1 (func-spec 0003 §8): AST and evaluator semantics — algebraic
-- judgments, variable lookup, 'Chan' = 'hashChan', bit-for-bit
-- determinism, 'evalFinite' finiteness (with deliberate NaN/Inf paths),
-- 'exprSize', and deep-tree evaluation.
module ExprEvalSpec (spec) where

import ExprGen ()
import GHC.Float (castFloatToWord32)
import Magic.Expr
import Magic.Types (Seed (..), hashChan)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | A fixed environment for judgment cases.
env0 :: ExprEnv
env0 = ExprEnv {envT = 2.5, envLife = 0.25, envPIndex = 7, envSeed = Seed 42}

evalIn :: Expr -> Float
evalIn e = evalExpr e env0

spec :: Spec
spec = describe "Magic.Expr (AST + evaluator, func-spec 0003 §4)" $ do
  describe "algebraic judgments" $ do
    prop "x + 0 keeps the finite value (additive identity)" $
      \e env -> evalFinite (Bin Add e (Lit 0)) env == evalFinite e env

    prop "x * 1 keeps the finite value (multiplicative identity)" $
      \e env -> evalFinite (Bin Mul e (Lit 1)) env == evalFinite e env

    prop "Neg . Neg == id (semantically)" $
      \e env -> evalFinite (Neg (Neg e)) env == evalFinite e env

    it "evaluates a compound formula: 2*3 + 4/2 - 1 = 7" $
      evalIn
        ( Bin
            Sub
            (Bin Add (Bin Mul (Lit 2) (Lit 3)) (Bin Div (Lit 4) (Lit 2)))
            (Lit 1)
        )
        `shouldBe` 7

  describe "variables" $ do
    it "Var VarT reads envT" $ evalIn (Var VarT) `shouldBe` 2.5
    it "Var VarLife reads envLife" $ evalIn (Var VarLife) `shouldBe` 0.25
    it "Var VarPIndex reads envPIndex (as Float)" $
      evalIn (Var VarPIndex) `shouldBe` 7

  describe "Chan (deterministic random channels)" $ do
    prop "Chan n == hashChan seed pindex n" $
      \env (NonNegative n) ->
        evalExpr (Chan n) env == hashChan (envSeed env) (envPIndex env) n

    prop "Chan n lands in [0, 1)" $
      \env (NonNegative n) ->
        let v = evalExpr (Chan n) env in v >= 0 && v < 1

  describe "determinism" $ do
    prop "same (Expr, env) evaluates bit-for-bit equal twice" $
      \e env ->
        castFloatToWord32 (evalExpr e env)
          == castFloatToWord32 (evalExpr e env)

  describe "evalFinite (consumption contract)" $ do
    prop "always finite for arbitrary Expr × env" $
      \e env ->
        let v = evalFinite e env
         in not (isNaN v) && not (isInfinite v)

    it "1/0 (+Inf) is flushed to 0" $
      evalFinite (Bin Div (Lit 1) (Lit 0)) env0 `shouldBe` 0
    it "(-1)/0 (-Inf) is flushed to 0" $
      evalFinite (Bin Div (Neg (Lit 1)) (Lit 0)) env0 `shouldBe` 0
    it "0/0 (NaN) is flushed to 0" $
      evalFinite (Bin Div (Lit 0) (Lit 0)) env0 `shouldBe` 0
    it "(-2)^0.5 (NaN) is flushed to 0" $
      evalFinite (Bin Pow (Neg (Lit 2)) (Lit 0.5)) env0 `shouldBe` 0
    it "sqrt(-1) (NaN) is flushed to 0" $
      evalFinite (Fun1 FSqrt (Neg (Lit 1))) env0 `shouldBe` 0
    it "evalExpr itself is IEEE-total: 1/0 really is +Inf" $
      evalIn (Bin Div (Lit 1) (Lit 0)) `shouldSatisfy` isInfinite

  describe "function semantics (§4.3 spot checks)" $ do
    it "floor 2.7 = 2, floor (-2.3) = -3" $ do
      evalIn (Fun1 FFloor (Lit 2.7)) `shouldBe` 2
      evalIn (Fun1 FFloor (Neg (Lit 2.3))) `shouldBe` (-3)
    it "floor at |x| >= 2^23 returns x unchanged" $ do
      evalIn (Fun1 FFloor (Lit 16777216)) `shouldBe` 16777216
      evalIn (Fun1 FFloor (Neg (Lit 16777216))) `shouldBe` (-16777216)
    it "floor is total on non-finite input (+Inf stays +Inf)" $
      evalIn (Fun1 FFloor (Bin Div (Lit 1) (Lit 0))) `shouldSatisfy` isInfinite
    it "sign: -1 / 0 / 1" $ do
      evalIn (Fun1 FSign (Neg (Lit 3))) `shouldBe` (-1)
      evalIn (Fun1 FSign (Lit 0)) `shouldBe` 0
      evalIn (Fun1 FSign (Lit 3)) `shouldBe` 1
    it "min/max" $ do
      evalIn (Fun2 FMin (Lit 2) (Lit 3)) `shouldBe` 2
      evalIn (Fun2 FMax (Lit 2) (Lit 3)) `shouldBe` 3
    it "clamp keeps the middle, clips both ends" $ do
      evalIn (Fun3 FClamp (Lit 0.5) (Lit 0) (Lit 1)) `shouldBe` 0.5
      evalIn (Fun3 FClamp (Neg (Lit 2)) (Lit 0) (Lit 1)) `shouldBe` 0
      evalIn (Fun3 FClamp (Lit 2) (Lit 0) (Lit 1)) `shouldBe` 1

  describe "exprSize" $ do
    it "leaves count 1" $ do
      exprSize (Lit 1) `shouldBe` 1
      exprSize (Var VarT) `shouldBe` 1
      exprSize (Chan 0) `shouldBe` 1
    it "sin(t*2 + 1) has 6 nodes" $
      exprSize (Fun1 FSin (Bin Add (Bin Mul (Var VarT) (Lit 2)) (Lit 1)))
        `shouldBe` 6
    it "clamp(t, 0, 1) has 4 nodes" $
      exprSize (Fun3 FClamp (Var VarT) (Lit 0) (Lit 1)) `shouldBe` 4

  describe "deep trees" $ do
    it "evaluates a ~1201-node chain (600 × (+1) over 0)" $ do
      let deep = foldl (\acc _ -> Bin Add acc (Lit 1)) (Lit 0) [1 .. 600 :: Int]
      exprSize deep `shouldBe` 1201
      evalIn deep `shouldBe` 600
