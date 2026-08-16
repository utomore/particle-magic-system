-- | S2 (func-spec 0022 §6): common-subexpression elimination.
--
-- 'Magic.Expr.Code.cse' hash-conses the formula into a DAG so a repeated
-- subterm is evaluated once instead of once per occurrence. Like every rung
-- of architecture §8.2's ladder it is only allowed to be an optimization, so
-- the law is an equality of /values/, bit for bit:
--
-- > evalDag (cse e) env  ≡  evalExpr e env
--
-- The one real correctness trap is the hash (§2.6): a hit must be confirmed
-- by a structural comparison, because merging two subterms that merely
-- collided is not a slower answer but a wrong one. That is witnessed here
-- the strongest way available — 'cseBuckets' @1@ forces /every/ pair of nodes
-- into the same bucket, so the structural comparison is the only thing left
-- standing between the DAG and nonsense, and the result must still be
-- identical to the auto-sized one.
module ExprCseSpec (spec) where

import qualified Data.Vector as V
import Data.Word (Word32)
import GHC.Float (castFloatToWord32)
import Magic.Expr
  ( BinOp (..)
  , Expr (..)
  , ExprEnv (..)
  , Fun1 (..)
  , Var (..)
  , evalExpr
  , exprSize
  , foldConstants
  )
import Magic.Expr.Code
  ( DagNode (..)
  , ExprCode (..)
  , ExprDag (..)
  , codeSize
  , compileDag
  , compileExpr
  , cse
  , cseBuckets
  , dagNodeCount
  , evalDag
  )
import Magic.Types (Seed (..))

import ExprGen ()
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

bits :: Float -> Word32
bits = castFloatToWord32

env0 :: ExprEnv
env0 = ExprEnv {envT = 1.25, envLife = 0.5, envPIndex = 7, envSeed = Seed 2026}

-- | @sin(t)·sin(t) + sin(t)@: one subterm, three occurrences.
repeated :: Expr
repeated = Bin Add (Bin Mul s s) s
  where
    s = Fun1 FSin (Var VarT)

spec :: Spec
spec = describe "Expr common-subexpression elimination (func-spec 0022 §6 S2)" $ do
  describe "the law" $ do
    prop "evalDag . cse ≡ evalExpr, bit for bit, for any expr × env" $
      \e env -> bits (evalDag (cse e) env) === bits (evalExpr e env)

    prop "for the same expr across many environments at once" $
      \e -> forAll (vectorOf 8 arbitrary) $ \envs ->
        map (bits . evalDag (cse e)) envs === map (bits . evalExpr e) envs

    prop "the foldConstants → cse composition is still bit-identical" $
      \e env -> bits (evalDag (cse (foldConstants e)) env) === bits (evalExpr e env)

    it "shares NaN and negative zero correctly rather than numerically" $ do
      -- 0.0 and -0.0 are equal under (==) and different values, so merging
      -- them would be wrong; two NaNs are unequal under (==) and the same
      -- value, so refusing to merge them is only a missed share.
      let zeros = Bin Sub (Lit 0) (Lit (-0.0))
      dagNodeCount (cse zeros) `shouldBe` 3 -- Lit 0.0, Lit -0.0, Sub: no merge
      dagNodeCount (cse (Bin Sub (Lit 0) (Lit 0))) `shouldBe` 2 -- same bits: merged
      bits (evalDag (cse zeros) env0) `shouldBe` bits (evalExpr zeros env0)
      let nans = Bin Add (Bin Div (Lit 0) (Lit 0)) (Bin Div (Lit 0) (Lit 0))
      bits (evalDag (cse nans) env0) `shouldBe` bits (evalExpr nans env0)

  describe "it actually shares" $ do
    it "collapses the repeated subterm to one node" $ do
      exprSize repeated `shouldBe` 8 -- Add, Mul, and three copies of sin(t) at 2 nodes each
      dagNodeCount (cse repeated) `shouldBe` 4 -- t, sin, mul, add
      bits (evalDag (cse repeated) env0) `shouldBe` bits (evalExpr repeated env0)

    prop "never invents nodes: the DAG is no bigger than the tree" $
      \e -> dagNodeCount (cse e) <= exprSize e

    prop "and it is smaller exactly when the tree repeats itself" $
      \e -> (dagNodeCount (cse e) < exprSize e) === hasRepeat e

    it "the bytecode gets shorter, which is where the saving is spent" $ do
      -- The unshared flattening would emit sin(t) three times over; the
      -- shared one emits it once and loads it twice.
      let shared = compileExpr repeated
          unshared = compileDag (noSharing repeated)
      codeSize shared `shouldSatisfy` (< codeSize unshared)
      ecSlots shared `shouldBe` 1
      ecSlots unshared `shouldBe` 0

    prop "no two distinct nodes of a DAG are structurally equal" $
      \e -> let ns = V.toList (dagNodes (cse e)) in length ns === length (nubNodes ns)

    prop "children always precede their parent (the DAG is topologically ordered)" $
      \e ->
        let ns = V.toList (dagNodes (cse e))
         in property (and [all (< i) (childrenOf nd) | (i, nd) <- zip [0 ..] ns])

  describe "collision handling" $ do
    -- The witness func-spec 0022 §2.6 asks for, in its stronger form: one
    -- bucket means the hash discriminates nothing at all.
    prop "one bucket (every node collides) still gives the identical DAG" $
      \e -> cseBuckets 1 e === cse e

    prop "one bucket still evaluates bit-identically" $
      \e env -> bits (evalDag (cseBuckets 1 e) env) === bits (evalExpr e env)

    prop "a tiny bucket table changes nothing but the lookup cost" $
      \e -> forAll (chooseInt (1, 4)) $ \b -> cseBuckets b e === cse e

    it "a hand-built pair of colliding-by-force nodes is not merged" $ do
      -- Two structurally different subterms; with one bucket they are
      -- compared against each other on every insert and must stay distinct.
      let e = Bin Add (Fun1 FSin (Var VarT)) (Fun1 FCos (Var VarT))
          dag = cseBuckets 1 e
      dagNodeCount dag `shouldBe` 4 -- t, sin, cos, add
      bits (evalDag dag env0) `shouldBe` bits (evalExpr e env0)

  describe "idempotence" $ do
    prop "cse . cse ≡ cse (re-running on the flattened DAG finds nothing new)" $
      \e -> dagNodeCount (cse (rebuild (cse e))) === dagNodeCount (cse e)

    prop "compiling twice yields the same program" $
      \e -> compileExpr (rebuild (cse e)) === compileExpr e

-- | Expand a DAG back into a tree, so 'cse' can be run on it a second time.
-- Re-sharing it must find exactly the same DAG — that is what idempotence
-- means for a function whose input and output are different types.
rebuild :: ExprDag -> Expr
rebuild (ExprDag nodes root) = at root
  where
    at i = case V.unsafeIndex nodes i of
      DLit x -> Lit x
      DVar v -> Var v
      DChan n -> Chan n
      DNeg a -> Neg (at a)
      DBin o a b -> Bin o (at a) (at b)
      DFun1 f a -> Fun1 f (at a)
      DFun2 f a b -> Fun2 f (at a) (at b)
      DFun3 f a b c -> Fun3 f (at a) (at b) (at c)

-- | The same tree as a DAG with no sharing at all: one node per AST node,
-- in post-order. The baseline the shared flattening is measured against.
noSharing :: Expr -> ExprDag
noSharing e = ExprDag (V.fromList (reverse nodes)) (count - 1)
  where
    (nodes, count) = go e ([], 0)
    go expr (acc, k) = case expr of
      Lit x -> (DLit x : acc, k + 1)
      Var v -> (DVar v : acc, k + 1)
      Chan n -> (DChan n : acc, k + 1)
      Neg a -> let (acc', k') = go a (acc, k) in (DNeg (k' - 1) : acc', k' + 1)
      Bin o a b ->
        let (acc1, k1) = go a (acc, k)
            (acc2, k2) = go b (acc1, k1)
         in (DBin o (k1 - 1) (k2 - 1) : acc2, k2 + 1)
      Fun1 f a -> let (acc', k') = go a (acc, k) in (DFun1 f (k' - 1) : acc', k' + 1)
      Fun2 f a b ->
        let (acc1, k1) = go a (acc, k)
            (acc2, k2) = go b (acc1, k1)
         in (DFun2 f (k1 - 1) (k2 - 1) : acc2, k2 + 1)
      Fun3 f a b c ->
        let (acc1, k1) = go a (acc, k)
            (acc2, k2) = go b (acc1, k1)
            (acc3, k3) = go c (acc2, k2)
         in (DFun3 f (k1 - 1) (k2 - 1) (k3 - 1) : acc3, k3 + 1)

childrenOf :: DagNode -> [Int]
childrenOf nd = case nd of
  DLit _ -> []
  DVar _ -> []
  DChan _ -> []
  DNeg a -> [a]
  DBin _ a b -> [a, b]
  DFun1 _ a -> [a]
  DFun2 _ a b -> [a, b]
  DFun3 _ a b c -> [a, b, c]

-- | Nodes compared the way 'cse' compares them (literals by bit pattern).
nubNodes :: [DagNode] -> [DagNode]
nubNodes = foldr (\x acc -> if any (same x) acc then acc else x : acc) []
  where
    same (DLit x) (DLit y) = bits x == bits y
    same a b = a == b

-- | Does the tree contain the same subterm twice? The predicate the
-- "smaller exactly when it repeats" property is stated against — written
-- independently of 'cse', by brute force over the subterm list.
hasRepeat :: Expr -> Bool
hasRepeat e = length subs /= length (nubExprs subs)
  where
    subs = allSubterms e
    nubExprs = foldr (\x acc -> if any (sameExpr x) acc then acc else x : acc) []

allSubterms :: Expr -> [Expr]
allSubterms e = e : concatMap allSubterms kids
  where
    kids = case e of
      Lit _ -> []
      Var _ -> []
      Chan _ -> []
      Neg a -> [a]
      Bin _ a b -> [a, b]
      Fun1 _ a -> [a]
      Fun2 _ a b -> [a, b]
      Fun3 _ a b c -> [a, b, c]

-- | Structural equality with literals compared by bit pattern — the same
-- notion 'cse' uses, so the two agree on NaN and on negative zero.
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
