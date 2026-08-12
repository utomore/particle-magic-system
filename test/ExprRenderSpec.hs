{-# LANGUAGE OverloadedStrings #-}

-- | T3 (func-spec 0003 §8): renderer — the roundtrip property
-- @parseExpr (renderExpr e) == Right e@ over arbitrary parser-producible
-- ASTs (the mechanical proof that the frozen grammar and the printer
-- agree), plus minimal-parentheses spot checks.
module ExprRenderSpec (spec) where

import ExprGen ()
import Magic.Expr
import Magic.Expr.Parse
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)

spec :: Spec
spec = describe "Magic.Expr.Parse (renderer, func-spec 0003 §4.4)" $ do
  describe "roundtrip" $ do
    modifyMaxSuccess (const 1000) $
      prop "parseExpr (renderExpr e) == Right e" $
        \e -> parseExpr (renderExpr e) `shouldBe` Right e

  describe "minimal parentheses (spot checks)" $ do
    it "a*b + c stays flat" $
      renderExpr
        (Bin Add (Bin Mul (Var VarT) (Var VarLife)) (Lit 1))
        `shouldBe` "t*life + 1.0"

    it "left-associative chains need no parens" $
      renderExpr
        (Bin Sub (Bin Sub (Lit 1) (Lit 2)) (Lit 3))
        `shouldBe` "1.0 - 2.0 - 3.0"

    it "right-nested subtraction is parenthesized" $
      renderExpr
        (Bin Sub (Lit 1) (Bin Sub (Lit 2) (Lit 3)))
        `shouldBe` "1.0 - (2.0 - 3.0)"

    it "a*(b + c) keeps the necessary parens" $
      renderExpr
        (Bin Mul (Var VarT) (Bin Add (Var VarLife) (Lit 1)))
        `shouldBe` "t*(life + 1.0)"

    it "-(t^2) renders bare (unary minus is looser than ^)" $
      renderExpr (Neg (Bin Pow (Var VarT) (Lit 2))) `shouldBe` "-t^2.0"

    it "(-t)^2 keeps the parens" $
      renderExpr (Bin Pow (Neg (Var VarT)) (Lit 2)) `shouldBe` "(-t)^2.0"

    it "right-associative ^ chain stays flat, left-nested ^ is parenthesized" $ do
      renderExpr (Bin Pow (Lit 2) (Bin Pow (Lit 3) (Lit 2)))
        `shouldBe` "2.0^3.0^2.0"
      renderExpr (Bin Pow (Bin Pow (Lit 2) (Lit 3)) (Lit 2))
        `shouldBe` "(2.0^3.0)^2.0"

    it "negative exponent is parenthesized (2^-3 is not valid syntax)" $
      renderExpr (Bin Pow (Lit 2) (Neg (Lit 3))) `shouldBe` "2.0^(-3.0)"

    it "function calls render readably" $
      renderExpr
        ( Fun3
            FClamp
            (Fun1 FSin (Bin Mul (Var VarT) (Lit 6)))
            (Lit 0)
            (Fun2 FMax (Var VarLife) (Chan 2))
        )
        `shouldBe` "clamp(sin(t*6.0), 0.0, max(life, chan(2)))"
