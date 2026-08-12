{-# LANGUAGE OverloadedStrings #-}

-- | T4 (func-spec 0003 §8): semantic golden cases — typical magic
-- formulas parsed from text and sampled at fixed env points against
-- expectations computed straight from the §4.3 semantics table (1e-5
-- tolerance). These cases double as the semantic baseline for any future
-- evaluator optimization (staged/bytecode, architecture.md §8).
module ExprGoldenSpec (spec) where

import Data.Text (Text)
import Magic.Expr
import Magic.Expr.Parse
import Magic.Types (Seed (..), hashChan)
import Test.Hspec

-- | Parse the formula, evaluate at the env, compare within 1e-5.
golden :: Text -> ExprEnv -> Float -> Expectation
golden src env expected = case parseExpr src of
  Left err -> expectationFailure (renderExprParseError err)
  Right e -> do
    let actual = evalFinite e env
    abs (actual - expected) `shouldSatisfy` (<= 1e-5)

envAt :: Float -> Float -> Int -> Seed -> ExprEnv
envAt t life pidx sd =
  ExprEnv {envT = t, envLife = life, envPIndex = pidx, envSeed = sd}

seed0 :: Seed
seed0 = Seed 0xBADC0FFEE

spec :: Spec
spec = describe "Expr golden formulas (func-spec 0003 §8 T4)" $ do
  describe "pulse: abs(sin(t*pi))" $ do
    let pulse t = golden "abs(sin(t*pi))" (envAt t 0 0 seed0) (abs (sin (t * pi)))
    it "t = 0.0" $ pulse 0
    it "t = 0.25 (rising)" $ pulse 0.25
    it "t = 0.5 (peak 1)" $ pulse 0.5
    it "t = 1.0 (zero crossing)" $ pulse 1
    it "t = 1.75 (second period)" $ pulse 1.75

  describe "decay: (1 - life)^2" $ do
    let decay life = golden "(1 - life)^2" (envAt 0 life 0 seed0) ((1 - life) ** 2)
    it "life = 0.0 (full)" $ decay 0
    it "life = 0.25" $ decay 0.25
    it "life = 0.5 (quarter)" $ decay 0.5
    it "life = 1.0 (spent)" $ decay 1

  describe "per-particle phase: sin(t*6.0 + chan(0)*6.28318)" $ do
    let phase t pidx =
          golden
            "sin(t*6.0 + chan(0)*6.28318)"
            (envAt t 0 pidx seed0)
            (sin (t * 6.0 + hashChan seed0 pidx 0 * 6.28318))
    it "t = 0.0, pindex = 0" $ phase 0 0
    it "t = 0.0, pindex = 1 (different phase)" $ phase 0 1
    it "t = 0.7, pindex = 41" $ phase 0.7 41
    it "t = 3.2, pindex = 4095" $ phase 3.2 4095

  describe "clamp boundaries: clamp(t, 0.0, 1.0)" $ do
    let clamped t expected = golden "clamp(t, 0.0, 1.0)" (envAt t 0 0 seed0) expected
    it "below the range clips to lo" $ clamped (-0.5) 0
    it "at lo stays lo" $ clamped 0 0
    it "inside passes through" $ clamped 0.5 0.5
    it "at hi stays hi" $ clamped 1 1
    it "above the range clips to hi" $ clamped 2 1

  describe "cross-check against the §4.3 table on compound formulas" $ do
    it "floor(t*4)/4 quantizes" $
      golden "floor(t*4)/4" (envAt 0.9 0 0 seed0) 0.75
    it "sign(t - 0.5) flips at the threshold" $ do
      golden "sign(t - 0.5)" (envAt 0.2 0 0 seed0) (-1)
      golden "sign(t - 0.5)" (envAt 0.8 0 0 seed0) 1
    it "min/max nest: max(0.2, min(t, 0.8))" $ do
      golden "max(0.2, min(t, 0.8))" (envAt 0.05 0 0 seed0) 0.2
      golden "max(0.2, min(t, 0.8))" (envAt 0.5 0 0 seed0) 0.5
      golden "max(0.2, min(t, 0.8))" (envAt 0.95 0 0 seed0) 0.8
    it "sqrt(life) eases" $
      golden "sqrt(life)" (envAt 0 0.25 0 seed0) 0.5
    it "1/t at t=0 hits the evalFinite guard (Inf -> 0)" $
      golden "1/t" (envAt 0 0 0 seed0) 0
