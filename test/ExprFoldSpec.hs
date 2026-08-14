-- | S6 (func-spec 0010 §7): constant folding in the formula language.
--
-- 'Magic.Expr.foldConstants' is the first rung of architecture §8.2's
-- acceleration ladder: pre-evaluate what does not depend on the
-- environment, at compile time, so the per-particle evaluator has fewer
-- nodes to walk. It is only allowed to be an optimization, so the law is
-- an equality of /values/, bit for bit, over arbitrary formulas and
-- arbitrary environments — NaN and ±Infinity included, since those are
-- ordinary values inside 'evalExpr' and only 'evalFinite' flushes them.
--
-- The comparison is on raw bit patterns rather than @(==)@: @0.0@ and
-- @-0.0@ compare equal numerically but are not the same value, and NaN
-- compares equal to nothing at all — neither would notice a fold that
-- silently changed the answer.
module ExprFoldSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import Data.Word (Word32)
import GHC.Float (castFloatToWord32)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( Appearance (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Motion (..)
  , compile
  )
import Magic.Expr
  ( BinOp (..)
  , Expr (..)
  , ExprEnv (..)
  , ExprV3 (..)
  , Fun1 (..)
  , Fun2 (..)
  , Fun3 (..)
  , Var (..)
  , evalExpr
  , exprSize
  , foldConstants
  )
import Magic.Rune (Trajectory (..))
import Magic.Types (Seed (..))
import ExprGen ()
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Bit-pattern equality of two evaluations.
bits :: Float -> Word32
bits = castFloatToWord32

-- | Structural equality that treats NaN literals as equal to themselves
-- (the derived 'Eq' does not), used for the idempotence law.
sameExpr :: Expr -> Expr -> Bool
sameExpr a b = case (a, b) of
  (Lit x, Lit y) -> bits x == bits y
  (Var x, Var y) -> x == y
  (Chan x, Chan y) -> x == y
  (Neg x, Neg y) -> sameExpr x y
  (Bin o x y, Bin o' x' y') -> o == o' && sameExpr x x' && sameExpr y y'
  (Fun1 f x, Fun1 f' x') -> f == f' && sameExpr x x'
  (Fun2 f x y, Fun2 f' x' y') -> f == f' && sameExpr x x' && sameExpr y y'
  (Fun3 f x y z, Fun3 f' x' y' z') ->
    f == f' && sameExpr x x' && sameExpr y y' && sameExpr z z'
  _ -> False

-- | Does the tree still contain a foldable node — a non-leaf whose every
-- child is a literal?
hasFoldable :: Expr -> Bool
hasFoldable e = case e of
  Lit _ -> False
  Var _ -> False
  Chan _ -> False
  _ -> all isLit kids || any hasFoldable kids
  where
    kids = kidsOf e
    isLit (Lit _) = True
    isLit _ = False

kidsOf :: Expr -> [Expr]
kidsOf e = case e of
  Lit _ -> []
  Var _ -> []
  Chan _ -> []
  Neg a -> [a]
  Bin _ a b -> [a, b]
  Fun1 _ a -> [a]
  Fun2 _ a b -> [a, b]
  Fun3 _ a b c -> [a, b, c]

-- | Every formula a compiled spell carries.
exprsOf :: CompiledSpell -> [Expr]
exprsOf spell = concatMap emitterExprs (V.toList (spellEmitters spell))
  where
    emitterExprs em =
      concat
        [ maybe [] pure (motRange (emMotion em))
        , maybe [] pure (motConverge (emMotion em))
        , maybe [] pure (appAmplify (emAppearance em))
        , case motTraject (emMotion em) of
            Formula (ExprV3 x y z) -> [x, y, z]
            _ -> []
        ]

examples :: [String]
examples =
  [ "bare-sigil"
  , "converge-flame"
  , "empty"
  , "grand-sigil"
  , "gravity-well"
  , "lissajous"
  , "pulse-ring"
  , "ring-fire"
  , "spiral-spark"
  , "square-burst"
  ]

compiledExample :: String -> IO CompiledSpell
compiledExample name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (compile circle)

spec :: Spec
spec = describe "Expr constant folding (func-spec 0010 §7 S6)" $ do
  describe "the equivalence law" $ do
    prop "eval . foldConstants ≡ eval, bit for bit, for any expr × env" $
      \e env -> bits (evalExpr (foldConstants e) env) === bits (evalExpr e env)

    prop "and for the same expr across many environments at once" $
      \e -> forAll (vectorOf 8 arbitrary) $ \envs ->
        map (bits . evalExpr (foldConstants e)) envs === map (bits . evalExpr e) envs

    it "keeps NaN and Infinity as values rather than flushing them early" $ do
      -- 1/0 and 0/0 are closed subtrees; folding must substitute the
      -- IEEE value, not 0 — 'evalFinite' is the only place that flushes.
      foldConstants (Bin Div (Lit 1) (Lit 0)) `shouldSatisfy` isInfiniteLit
      foldConstants (Bin Div (Lit 0) (Lit 0)) `shouldSatisfy` isNaNLit
      -- and the value the sampler would see is unchanged either way
      let e = Fun2 FMax (Bin Div (Lit 1) (Lit 0)) (Var VarT)
          env = ExprEnv {envT = 3, envLife = 0.5, envPIndex = 7, envSeed = Seed 99}
      bits (evalExpr (foldConstants e) env) `shouldBe` bits (evalExpr e env)

  describe "it is actually a simplification" $ do
    prop "never grows the tree" $
      \e -> exprSize (foldConstants e) <= exprSize e

    prop "leaves nothing foldable behind" $
      \e -> not (hasFoldable (foldConstants e))

    prop "is idempotent" $
      \e -> property (sameExpr (foldConstants (foldConstants e)) (foldConstants e))

    prop "leaves variable-carrying trees the same size" $
      \e -> not (hasFoldable e) ==> exprSize (foldConstants e) === exprSize e

    it "collapses a fully closed formula to a single literal" $ do
      let e = Fun3 FClamp (Bin Mul (Lit 3) (Bin Add (Lit 1) (Lit 1))) (Lit 0) (Lit 10)
      exprSize e `shouldBe` 8
      foldConstants e `shouldBe` Lit 6

    it "folds under a variable without touching the variable" $ do
      let e = Bin Add (Var VarT) (Fun1 FSqrt (Bin Mul (Lit 4) (Lit 4)))
      foldConstants e `shouldBe` Bin Add (Var VarT) (Lit 4)

    it "does not fold a Chan node: it depends on the seed and index" $
      foldConstants (Bin Mul (Chan 0) (Lit 2))
        `shouldBe` Bin Mul (Chan 0) (Lit 2)

  describe "compile applies it" $ do
    it "every formula in every shipped example comes out fully folded" $
      mapM_
        ( \name -> do
            spell <- compiledExample name
            filter hasFoldable (exprsOf spell) `shouldBe` []
        )
        examples

    it "the shipped examples do carry formulas (the check is not vacuous)" $ do
      spells <- mapM compiledExample examples
      length (concatMap exprsOf spells) `shouldSatisfy` (> 0)

isInfiniteLit :: Expr -> Bool
isInfiniteLit (Lit x) = isInfinite x
isInfiniteLit _ = False

isNaNLit :: Expr -> Bool
isNaNLit (Lit x) = isNaN x
isNaNLit _ = False
