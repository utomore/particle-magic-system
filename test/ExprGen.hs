{-# OPTIONS_GHC -Wno-orphans #-}

-- | Sized 'Arbitrary' generator + shrinker for 'Expr' and 'ExprEnv'
-- (func-spec 0003 §8, foundation for every property in T1–T3). Not a
-- *Spec module, so hspec-discover does not pick it up.
--
-- Generated literals are finite and non-negative: the surface grammar has
-- no negative/NaN/Infinity literals (a negative constant is 'Neg' applied
-- to a literal), and the roundtrip property (T3) quantifies over exactly
-- the parser-producible ASTs. NaN/Inf still arise at evaluation time
-- through generated 'Div' / 'Pow' / 'FSqrt' nodes, which is what the
-- finiteness property needs.
module ExprGen (genExpr, genLeaf, genExprEnv, shrinkExpr) where

import Magic.Expr
import Magic.Types (Seed (..))
import Test.QuickCheck

instance Arbitrary Expr where
  arbitrary = sized genExpr
  shrink = shrinkExpr

instance Arbitrary ExprEnv where
  arbitrary = genExprEnv

-- | Size-bounded generator: @genExpr n@ yields an 'Expr' whose node count
-- is roughly bounded by @n@ (children split the budget).
genExpr :: Int -> Gen Expr
genExpr n
  | n <= 1 = genLeaf
  | otherwise =
      frequency
        [ (2, genLeaf)
        , (2, Neg <$> genExpr (n - 1))
        , (4, Bin <$> genEnum <*> half <*> half)
        , (3, Fun1 <$> genEnum <*> genExpr (n - 1))
        , (2, Fun2 <$> genEnum <*> half <*> half)
        , (1, Fun3 <$> genEnum <*> third <*> third <*> third)
        ]
  where
    half = genExpr (n `div` 2)
    third = genExpr (n `div` 3)

genLeaf :: Gen Expr
genLeaf =
  oneof
    [ Lit <$> genLit
    , Var <$> genEnum
    , Chan <$> chooseInt (0, 7)
    ]

-- | Finite, non-negative literals (see module header). Mixes small
-- integers (exact identities, exponent judgments) with arbitrary
-- magnitudes.
genLit :: Gen Float
genLit =
  oneof
    [ fromIntegral <$> chooseInt (0, 12)
    , abs <$> (arbitrary `suchThat` (\x -> not (isNaN x || isInfinite x)))
    ]

genEnum :: (Enum a, Bounded a) => Gen a
genEnum = elements [minBound .. maxBound]

genExprEnv :: Gen ExprEnv
genExprEnv = do
  t <- realToFrac <$> choose (-1e4 :: Double, 1e4)
  life <- realToFrac <$> choose (0 :: Double, 1)
  pidx <- chooseInt (0, 100000)
  sd <- arbitraryBoundedIntegral
  pure (ExprEnv t life pidx (Seed sd))

shrinkExpr :: Expr -> [Expr]
shrinkExpr e = case e of
  Lit x -> [Lit 0 | x /= 0]
  Var _ -> [Lit 0]
  Chan n -> Lit 0 : [Chan n' | n' <- shrink n, n' >= 0]
  Neg a -> a : [Neg a' | a' <- shrinkExpr a]
  Bin op a b ->
    a : b : [Bin op a' b | a' <- shrinkExpr a] ++ [Bin op a b' | b' <- shrinkExpr b]
  Fun1 f a -> a : [Fun1 f a' | a' <- shrinkExpr a]
  Fun2 f a b ->
    a : b : [Fun2 f a' b | a' <- shrinkExpr a] ++ [Fun2 f a b' | b' <- shrinkExpr b]
  Fun3 f a b c ->
    a
      : b
      : c
      : [Fun3 f a' b c | a' <- shrinkExpr a]
      ++ [Fun3 f a b' c | b' <- shrinkExpr b]
      ++ [Fun3 f a b c' | c' <- shrinkExpr c]
