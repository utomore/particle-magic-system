-- | S1 (func-spec 0022 §6): the bytecode evaluator, and __law 1__ — the
-- whole point of the round's first half.
--
-- > evalCode (compileExpr (foldConstants e)) env  ≡  evalExpr e env
--
-- Bit for bit. The comparison is on raw bit patterns rather than @(==)@
-- because @0.0@ and @-0.0@ compare equal numerically while being different
-- values, and NaN compares equal to nothing at all — neither would notice an
-- evaluator that silently changed the answer. 'Magic.Expr.evalExpr' is the
-- reference implementation (§2.1): the fast path must prove it equals the
-- slow one, never the other way round.
--
-- Beyond the law this checks the structural promises the speed rests on:
-- 'ecMaxDepth' really bounds the operand stack (the evaluator allocates
-- exactly that much and then never checks again), and evaluation allocates
-- nothing per instruction — a program ~50× longer costs the same handful of
-- bytes, which is what "no boxed intermediate" means in numbers.
module ExprCodeSpec (spec) where

import Control.Exception (evaluate)
import Control.Monad (unless)
import Data.Bits (shiftR)
import qualified Data.Bits as Bits
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import GHC.Float (castFloatToWord32)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
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
  , evalFinite
  , evalFiniteV3
  , foldConstants
  )
import Magic.Expr.Code
  ( ExprCode (..)
  , codeSize
  , compileExpr
  , compileExprV3
  , cse
  , evalCode
  , evalCodeFinite
  , evalCodeFiniteV3
  , evalCodeV3
  , compileDag
  )
import Magic.Types (Seed (..), V3 (..), hashChan)
import System.Mem (performGC)

import ExprGen ()
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Bit-pattern equality: the only equality strong enough to state the law.
bits :: Float -> Word32
bits = castFloatToWord32

bits3 :: V3 -> (Word32, Word32, Word32)
bits3 (V3 x y z) = (bits x, bits y, bits z)

env0 :: ExprEnv
env0 = ExprEnv {envT = 1.25, envLife = 0.5, envPIndex = 7, envSeed = Seed 2026}

-- | The production pipeline of §2.6, in order.
compiled :: Expr -> ExprCode
compiled = compileExpr . foldConstants

spec :: Spec
spec = describe "Expr bytecode (func-spec 0022 §6 S1)" $ do
  describe "law 1: evalCode . compileExpr ≡ evalExpr, bit for bit" $ do
    prop "for any expr × any env" $
      \e env -> bits (evalCode (compileExpr e) env) === bits (evalExpr e env)

    prop "and through the whole foldConstants → cse → compileExpr pipeline" $
      \e env -> bits (evalCode (compiled e) env) === bits (evalExpr e env)

    prop "for the same expr across many environments at once" $
      \e -> forAll (vectorOf 8 arbitrary) $ \envs ->
        map (bits . evalCode (compiled e)) envs === map (bits . evalExpr e) envs

    it "keeps NaN, ±Infinity and negative zero as the values they are" $ do
      let cases =
            [ Bin Div (Lit 1) (Lit 0) -- +Infinity
            , Neg (Bin Div (Lit 1) (Lit 0)) -- -Infinity
            , Bin Div (Lit 0) (Lit 0) -- NaN
            , Fun1 FSqrt (Neg (Lit 4)) -- NaN
            , Bin Pow (Neg (Lit 2)) (Lit 0.5) -- NaN
            , Neg (Lit 0) -- -0.0, distinct bits from 0.0
            , Bin Mul (Neg (Lit 0)) (Lit 1)
            , Fun1 FSign (Bin Div (Lit 0) (Lit 0)) -- signum NaN
            ]
      mapM_
        (\e -> bits (evalCode (compileExpr e) env0) `shouldBe` bits (evalExpr e env0))
        cases
      -- and the negative zero really is one, so the case is not vacuous
      bits (evalCode (compileExpr (Neg (Lit 0))) env0) `shouldBe` 0x80000000

    it "agrees at the extremes of the exponent range" $ do
      let extremes =
            [ 0, 1, -1, 1 / 0, 3.4028235e38, 1.1754944e-38, 1.0e-45, 8388608, 16777216 ]
          cases =
            concat
              [ [Fun1 f (Lit x) | f <- [minBound .. maxBound], x <- extremes]
                  ++ [Fun1 f (Neg (Lit x)) | f <- [minBound .. maxBound], x <- extremes]
              , [Bin op (Lit x) (Lit y) | op <- [minBound .. maxBound], x <- extremes, y <- extremes]
              ]
      mapM_
        (\e -> bits (evalCode (compileExpr e) env0) `shouldBe` bits (evalExpr e env0))
        cases

    it "floors exactly where the AST floors, including past ±2²³" $ do
      let xs = [-16777217, -8388609, -8388608, -8388607.5, -0.5, -0, 0, 0.5, 8388607.5, 8388608, 1 / 0, 0 / 0]
      mapM_
        ( \x ->
            let e = Fun1 FFloor (Lit x)
             in bits (evalCode (compileExpr e) env0) `shouldBe` bits (evalExpr e env0)
        )
        xs

  describe "the Chan instruction is the frozen hash, not a second one" $ do
    prop "Chan n evaluates to hashChan seed pindex n exactly" $
      \env -> forAll (chooseInt (-1000, 1000)) $ \n ->
        bits (evalCode (compileExpr (Chan n)) env)
          === bits (hashChan (envSeed env) (envPIndex env) n)

    it "carries channel indices too wide for the inline operand field" $ do
      -- The operand field is 24 bits; these are not, and the encoding spends
      -- two extra stream words rather than truncating them into a different
      -- random channel.
      let ns = [0, 1, 255, 16777215, 16777216, 2147483647, -1, -16777216, -2147483648]
      mapM_
        ( \n ->
            bits (evalCode (compileExpr (Chan n)) env0)
              `shouldBe` bits (hashChan (envSeed env0) (envPIndex env0) n)
        )
        ns

  describe "the zeroing rule stays at the single consumption entry point" $ do
    prop "evalCodeFinite ≡ evalFinite, bit for bit" $
      \e env -> bits (evalCodeFinite (compiled e) env) === bits (evalFinite e env)

    prop "evalCodeFiniteV3 ≡ evalFiniteV3, componentwise" $
      \x y z env ->
        let v3 = ExprV3 x y z
         in bits3 (evalCodeFiniteV3 (compileExprV3 v3) env) === bits3 (evalFiniteV3 v3 env)

    prop "evalCodeV3 ≡ the three unflushed component values" $
      \x y z env ->
        let v3 = ExprV3 x y z
         in bits3 (evalCodeV3 (compileExprV3 v3) env)
              === (bits (evalExpr x env), bits (evalExpr y env), bits (evalExpr z env))

    it "does not flush an intermediate NaN early — only the final value" $ do
      -- max(+Inf, t) is +Inf inside the program; the flush happens once, at
      -- the end, exactly as it does for the AST.
      let e = Fun2 FMax (Bin Div (Lit 1) (Lit 0)) (Var VarT)
      evalCode (compileExpr e) env0 `shouldSatisfy` isInfinite
      evalExpr e env0 `shouldSatisfy` isInfinite
      evalCodeFinite (compileExpr e) env0 `shouldBe` 0
      evalFinite e env0 `shouldBe` 0
      -- and a NaN that a later operation would have swallowed stays swallowed
      let e2 = Fun3 FClamp (Bin Div (Lit 0) (Lit 0)) (Lit 0) (Lit 1)
      bits (evalCodeFinite (compileExpr e2) env0) `shouldBe` bits (evalFinite e2 env0)

  describe "ecMaxDepth bounds the operand stack" $ do
    prop "it is at least the depth the stream actually reaches" $
      \e -> let c = compiled e in simulatedDepth c <= ecMaxDepth c

    prop "and it is exact, so the evaluator's buffer is not oversized" $
      \e -> let c = compiled e in simulatedDepth c === ecMaxDepth c

    prop "the stream is balanced: it ends with exactly one value" $
      \e -> finalStack (compiled e) === 1

    prop "every slot the stream mentions was assigned by the compiler" $
      \e -> let c = compiled e in maxSlot c < ecSlots c

  describe "evaluation allocates nothing per instruction" $ do
    it "a ~50× longer program costs the same handful of bytes per evaluation" $ do
      enabled <- getRTSStatsEnabled
      if not enabled
        then pendingWith "RTS stats unavailable; the suite needs +RTS -T"
        else do
          let small = compiled (chain 4)
              big = compiled (chain 200)
          -- The two programs differ by ~50× in length and not at all in
          -- stack shape, so any per-instruction allocation would show up as
          -- a difference here and nowhere else.
          codeSize big `shouldSatisfy` (> 40 * codeSize small)
          ecMaxDepth big `shouldBe` ecMaxDepth small
          ecSlots big `shouldBe` ecSlots small
          bSmall <- bytesPerEval small
          bBig <- bytesPerEval big
          -- A boxed Float per node would be ~16 B × 200 = 3.2 kB here.
          bBig `shouldSatisfy` (< 512)
          unless (bBig <= bSmall + 64) $
            expectationFailure
              ( "allocation grew with program length: "
                  ++ show bSmall
                  ++ " B/eval at "
                  ++ show (codeSize small)
                  ++ " instructions vs "
                  ++ show bBig
                  ++ " B/eval at "
                  ++ show (codeSize big)
              )

  describe "the compiled program's own shape" $ do
    prop "compiling the cse DAG directly is the same program" $
      \e -> compileDag (cse e) === compileExpr e

    prop "the constant pool is deduplicated by bit pattern" $
      \e ->
        let c = compiled e
            pool = U.toList (ecConsts c)
         in length pool === length (uniqueBy (map bits pool))

-- | A right-leaning chain @((x + 1) + 1) + …@: many instructions, constant
-- stack depth, one shared literal. The fixture for the allocation test.
chain :: Int -> Expr
chain n = go n (Var VarT)
  where
    go 0 acc = acc
    go k acc = go (k - 1 :: Int) (Bin Add acc (Lit 1))

uniqueBy :: [Word32] -> [Word32]
uniqueBy = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- Independent decoding of the instruction stream -------------------------------

-- The encoding contract, restated here rather than imported: the compiler's
-- own 'ecMaxDepth' is checked against a second reading of the same stream,
-- so an error in the depth computation cannot hide behind the encoder that
-- produced it.

decoded :: ExprCode -> [(Word32, Int)]
decoded code = go 0
  where
    ops = ecOps code
    n = U.length ops
    go pc
      | pc >= n = []
      | otherwise =
          let w = ops U.! pc
              op = w Bits..&. 0xFF
              arg = fromIntegral (w `shiftR` 8) :: Int
              width = if op == 2 then 3 else 1 -- OpChan carries two payload words
           in (op, arg) : go (pc + width)

-- | Net stack effect of each opcode: push, pop-and-push, …
delta :: Word32 -> Int
delta op = case op of
  0 -> 1 -- OpConst
  1 -> 1 -- OpVar
  2 -> 1 -- OpChan
  3 -> 0 -- OpNeg
  4 -> -1 -- OpBin
  5 -> 0 -- OpFun1
  6 -> -1 -- OpFun2
  7 -> -2 -- OpFun3
  8 -> 0 -- OpStore
  _ -> 1 -- OpLoad

simulatedDepth :: ExprCode -> Int
simulatedDepth code = maximum (0 : scanl1 (+) [delta op | (op, _) <- decoded code])

finalStack :: ExprCode -> Int
finalStack code = sum [delta op | (op, _) <- decoded code]

-- | Highest slot number the stream mentions, or @-1@ if it mentions none.
maxSlot :: ExprCode -> Int
maxSlot code = maximum (-1 : [arg | (op, arg) <- decoded code, op == 8 || op == 9])

-- Allocation measurement -------------------------------------------------------

-- | Bytes allocated per 'evalCode' call, averaged over enough iterations
-- that the fixed cost of the measurement itself washes out. The environment
-- varies per iteration so the evaluation cannot be hoisted out of the loop;
-- that per-iteration record is a constant cost shared by both fixtures, and
-- the test compares them against each other.
bytesPerEval :: ExprCode -> IO Int
bytesPerEval code = do
  _ <- evaluate (drive 1000)
  performGC
  s0 <- getRTSStats
  v <- evaluate (drive iterations)
  performGC
  s1 <- getRTSStats
  -- Keep the result alive so nothing above it can be dropped.
  _ <- evaluate (isNaN v)
  pure (fromIntegral (allocated_bytes s1 - allocated_bytes s0) `div` iterations)
  where
    iterations = 20000 :: Int
    drive :: Int -> Float
    drive k = go 0 0
      where
        go !i !acc
          | i >= k = acc
          | otherwise = go (i + 1) (acc + evalCode code (env0 {envT = fromIntegral i}))
