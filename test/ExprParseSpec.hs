{-# LANGUAGE OverloadedStrings #-}

-- | T2 (func-spec 0003 §8): parser and gates — the three frozen §4.4
-- judgments, precedence/associativity table, whitespace tolerance, and
-- the four gates (unknown names with legal-name list, arity, chan
-- literal-only, node budget).
module ExprParseSpec (spec) where

import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Magic.Expr
import Magic.Expr.Parse
import Magic.Types (Seed (..))
import Test.Hspec

parsesTo :: Text -> Expr -> Expectation
parsesTo s e = parseExpr s `shouldBe` Right e

failsWith :: Text -> (String -> Bool) -> Expectation
failsWith s p = case parseExpr s of
  Right e -> expectationFailure ("expected a parse error, got: " ++ show e)
  Left err -> renderExprParseError err `shouldSatisfy` p

lit :: Float -> Expr
lit = Lit

spec :: Spec
spec = describe "Magic.Expr.Parse (parser + gates, func-spec 0003 §4.4)" $ do
  describe "frozen judgments" $ do
    it "-t^2 parses as -(t^2)" $
      "-t^2" `parsesTo` Neg (Bin Pow (Var VarT) (lit 2))

    it "2^3^2 parses right-associative, evaluating to 512" $ do
      "2^3^2" `parsesTo` Bin Pow (lit 2) (Bin Pow (lit 3) (lit 2))
      let env = ExprEnv 0 0 0 (Seed 0)
      either (const 0) (`evalExpr` env) (parseExpr "2^3^2") `shouldBe` 512

    it "2^-3 is a syntax error (exponent negation needs parentheses)" $
      failsWith "2^-3" (const True)

    it "2^(-3) is fine" $
      "2^(-3)" `parsesTo` Bin Pow (lit 2) (Neg (lit 3))

  describe "precedence and associativity" $ do
    it "1+2*3 = 1+(2*3)" $
      "1+2*3" `parsesTo` Bin Add (lit 1) (Bin Mul (lit 2) (lit 3))
    it "1-2-3 = (1-2)-3 (left)" $
      "1-2-3" `parsesTo` Bin Sub (Bin Sub (lit 1) (lit 2)) (lit 3)
    it "8/4/2 = (8/4)/2 (left)" $
      "8/4/2" `parsesTo` Bin Div (Bin Div (lit 8) (lit 4)) (lit 2)
    it "2*3^2 = 2*(3^2)" $
      "2*3^2" `parsesTo` Bin Mul (lit 2) (Bin Pow (lit 3) (lit 2))
    it "-t*3 = (-t)*3 (unary minus binds tighter than *)" $
      "-t*3" `parsesTo` Bin Mul (Neg (Var VarT)) (lit 3)
    it "1 + -2 = 1 + (-2)" $
      "1 + -2" `parsesTo` Bin Add (lit 1) (Neg (lit 2))
    it "(1+2)*3 respects parentheses" $
      "(1+2)*3" `parsesTo` Bin Mul (Bin Add (lit 1) (lit 2)) (lit 3)

  describe "lexicon" $ do
    it "integer, decimal and exponent literals" $ do
      "3" `parsesTo` lit 3
      "1.5" `parsesTo` lit 1.5
      "2e-3" `parsesTo` lit 2e-3
      "1.5e2" `parsesTo` lit 150
    it "pi parses as a literal" $
      "pi" `parsesTo` lit pi
    it "the three variables" $ do
      "t" `parsesTo` Var VarT
      "life" `parsesTo` Var VarLife
      "pindex" `parsesTo` Var VarPIndex
    it "function calls of each arity" $ do
      "sin(t)" `parsesTo` Fun1 FSin (Var VarT)
      "min(1, 2)" `parsesTo` Fun2 FMin (lit 1) (lit 2)
      "clamp(t, 0, 1)" `parsesTo` Fun3 FClamp (Var VarT) (lit 0) (lit 1)
      "chan(3)" `parsesTo` Chan 3
    it "a leading dot is not a number" $
      failsWith ".5" (const True)

  describe "whitespace tolerance" $ do
    it "arbitrary spaces are fine" $
      "  sin (  t )  +   1 " `parsesTo` Bin Add (Fun1 FSin (Var VarT)) (lit 1)

  describe "gate: unknown names" $ do
    it "unknown variable lists the legal variable names, with position" $
      failsWith "foo + 1" $ \msg ->
        "foo" `isInfixOf` msg
          && "pindex" `isInfixOf` msg
          && "life" `isInfixOf` msg
          && "1:1" `isInfixOf` msg
    it "unknown function lists the legal function names" $
      failsWith "warp(1)" $ \msg ->
        "warp" `isInfixOf` msg && "clamp" `isInfixOf` msg && "chan" `isInfixOf` msg
    it "identifiers are lowercase-only (T is unknown)" $
      failsWith "T + 1" ("legal names" `isInfixOf`)

  describe "gate: arity" $ do
    it "sin(1,2) reports expected 1, got 2" $
      failsWith "sin(1,2)" $ \msg ->
        "expects 1 argument" `isInfixOf` msg && "got 2" `isInfixOf` msg
    it "min(1) reports expected 2, got 1" $
      failsWith "min(1)" $ \msg ->
        "expects 2 arguments" `isInfixOf` msg && "got 1" `isInfixOf` msg
    it "clamp(1,2) reports expected 3, got 2" $
      failsWith "clamp(1,2)" $ \msg ->
        "expects 3 arguments" `isInfixOf` msg && "got 2" `isInfixOf` msg

  describe "gate: chan literal-only" $ do
    it "chan(t) is rejected" $
      failsWith "chan(t)" ("integer literal" `isInfixOf`)
    it "chan(-1) is rejected" $
      failsWith "chan(-1)" ("integer literal" `isInfixOf`)
    it "chan(1.5) is rejected" $
      failsWith "chan(1.5)" (const True)

  describe "gate: node budget (maxExprNodes = 512)" $ do
    it "exposes the frozen budget value" $
      maxExprNodes `shouldBe` 512
    it "511 nodes (256 summands) still parse" $ do
      let src = T.intercalate " + " (replicate 256 "1")
      fmap exprSize (parseExpr src) `shouldBe` Right 511
    it "513 nodes (257 summands) are rejected, message names the limit" $ do
      let src = T.intercalate " + " (replicate 257 "1")
      failsWith src $ \msg ->
        "512" `isInfixOf` msg && "too large" `isInfixOf` msg
