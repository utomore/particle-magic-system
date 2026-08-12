-- | The Expr math-formula language core (func-spec 0003 §4).
--
-- DSL layer three (ADR-0002): a closed, first-order, fixed-arity AST.
-- There is no recursion, no binding and no user-defined functions in the
-- language, so every 'Expr' is a finite tree and evaluation is plain
-- structural recursion — termination is guaranteed by construction, not
-- checked.
--
-- 'evalExpr' is IEEE-total: any input yields a value, possibly NaN or
-- ±Infinity. 'evalFinite' is the single consumption-side entry point that
-- flushes those to 0. Randomness is the frozen 'hashChan' mechanism via
-- 'Chan' — stateless and bit-for-bit deterministic.
--
-- Frozen contract once spec 0003 is delivered (§4.5): the semantics of
-- the existing constructors (§4.3), the 'ExprEnv' fields and the
-- 'evalFinite' zeroing rule. The sums are open for extension by adding
-- constructors — never by changing existing meaning.
module Magic.Expr
  ( -- * AST (extensible sums; existing members frozen)
    Expr (..)
  , Var (..)
  , BinOp (..)
  , Fun1 (..)
  , Fun2 (..)
  , Fun3 (..)

    -- * Variable environment
  , ExprEnv (..)

    -- * Evaluation
  , evalExpr
  , evalFinite
  , exprSize
  ) where

import Magic.Types (Seed, hashChan)

-- | A math formula. Fixed arity is encoded in the constructors ('Fun3'
-- carries exactly three children), so an ill-formed application is
-- unrepresentable.
data Expr
  = -- | Literal value.
    Lit !Float
  | -- | Environment variable lookup.
    Var !Var
  | -- | Random channel @n@: @'hashChan' seed pindex n@ ∈ [0, 1).
    Chan !Int
  | -- | Unary negation.
    Neg Expr
  | Bin !BinOp Expr Expr
  | Fun1 !Fun1 Expr
  | Fun2 !Fun2 Expr Expr
  | Fun3 !Fun3 Expr Expr Expr
  deriving (Eq, Show)

data Var = VarT | VarLife | VarPIndex
  deriving (Eq, Show, Enum, Bounded)

data BinOp = Add | Sub | Mul | Div | Pow
  deriving (Eq, Show, Enum, Bounded)

data Fun1 = FSin | FCos | FAbs | FSqrt | FFloor | FSign
  deriving (Eq, Show, Enum, Bounded)

data Fun2 = FMin | FMax
  deriving (Eq, Show, Enum, Bounded)

data Fun3 = FClamp
  deriving (Eq, Show, Enum, Bounded)

-- | Everything a formula can read. Built per particle per frame by the
-- sampling side (spec 0004); this module only defines the shape.
data ExprEnv = ExprEnv
  { envT :: !Float
  -- ^ Seconds since cast (narrowed from 'Magic.Types.Time' by the caller).
  , envLife :: !Float
  -- ^ Normalized particle life, 0..1.
  , envPIndex :: !Int
  -- ^ Particle index.
  , envSeed :: !Seed
  -- ^ Cast seed ('Magic.Types.CastContext' seed).
  }
  deriving (Eq, Show)

-- | IEEE-total evaluation: always returns a value, possibly NaN or
-- ±Infinity (division by zero, negative sqrt, …). Semantics per §4.3 of
-- func-spec 0003; deterministic — the same @(Expr, ExprEnv)@ always
-- yields the same bits.
evalExpr :: Expr -> ExprEnv -> Float
evalExpr expr env = go expr
  where
    go :: Expr -> Float
    go e = case e of
      Lit x -> x
      Var VarT -> envT env
      Var VarLife -> envLife env
      Var VarPIndex -> fromIntegral (envPIndex env)
      Chan n -> hashChan (envSeed env) (envPIndex env) n
      Neg a -> negate (go a)
      Bin op a b -> binOp op (go a) (go b)
      Fun1 f a -> fun1 f (go a)
      Fun2 f a b -> fun2 f (go a) (go b)
      Fun3 f a b c -> fun3 f (go a) (go b) (go c)

    binOp :: BinOp -> Float -> Float -> Float
    binOp op = case op of
      Add -> (+)
      Sub -> (-)
      Mul -> (*)
      Div -> (/) -- IEEE: x/0 = ±Inf, 0/0 = NaN (zeroed by 'evalFinite')
      Pow -> (**) -- negative base × non-integral exponent = NaN (idem)

    fun1 :: Fun1 -> Float -> Float
    fun1 f = case f of
      FSin -> sin
      FCos -> cos
      FAbs -> abs
      FSqrt -> sqrt -- negative → NaN (zeroed by 'evalFinite')
      FFloor -> floorF
      FSign -> signum -- NaN → NaN (idem)

    fun2 :: Fun2 -> Float -> Float -> Float
    fun2 f = case f of
      FMin -> min
      FMax -> max

    fun3 :: Fun3 -> Float -> Float -> Float -> Float
    fun3 FClamp x lo hi = min (max x lo) hi

-- | Total floor. Outside ±2²³ a Float has no fractional part anyway (and
-- NaN/±Inf have none either), so those come back unchanged instead of
-- overflowing an integer conversion.
floorF :: Float -> Float
floorF x
  | isNaN x || isInfinite x || abs x >= 8388608 = x
  | otherwise = fromIntegral (floor x :: Int)

-- | The consumption-side contract (the sampling pipeline's only entry
-- point): NaN and ±Infinity are flushed to 0, so the result is always a
-- finite Float.
evalFinite :: Expr -> ExprEnv -> Float
evalFinite e env =
  let v = evalExpr e env
   in if isNaN v || isInfinite v then 0 else v

-- | AST node count (every constructor counts as one node). Used by the
-- parse-layer size gate and by tests.
exprSize :: Expr -> Int
exprSize e = case e of
  Lit _ -> 1
  Var _ -> 1
  Chan _ -> 1
  Neg a -> 1 + exprSize a
  Bin _ a b -> 1 + exprSize a + exprSize b
  Fun1 _ a -> 1 + exprSize a
  Fun2 _ a b -> 1 + exprSize a + exprSize b
  Fun3 _ a b c -> 1 + exprSize a + exprSize b + exprSize c
