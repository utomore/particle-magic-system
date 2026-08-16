{-# LANGUAGE PatternSynonyms #-}

-- | Flat bytecode for the formula language (func-spec 0022, architecture
-- §8.2 stages two and three).
--
-- Stage one — 'Magic.Expr.foldConstants' — landed in func-spec 0010. This
-- module adds the other two: common-subexpression elimination ('cse', a
-- hash-consed DAG) and flattening into a contiguous instruction array
-- ('compileExpr'), run by a tight loop over unboxed memory ('evalCode').
--
-- __"AST interface unchanged, only the evaluator swapped"__ (architecture
-- §8.2) is taken literally: "Magic.Expr" is not touched by this round at
-- all. 'Magic.Expr.evalExpr' stays on as the /reference implementation/ —
-- slow, plain, and in one-to-one correspondence with the semantics func-spec
-- 0003 §4.3 froze. That is exactly what makes it the right answer to check
-- against, and why it survives even though the production path no longer
-- calls it.
--
-- The two laws this module is delivered under (guarded by
-- @test\/ExprCodeSpec.hs@ and @test\/ExprCseSpec.hs@), bit for bit —
-- including NaN, ±Infinity and negative zero, which are ordinary values here
-- and are flushed only by the @…Finite@ entry points:
--
-- > evalCode (compileExpr e) env  ≡  evalExpr e env
-- > evalDag  (cse e)         env  ≡  evalExpr e env
--
-- Why a flat array beats the tree: an AST walk is a pointer chase plus a
-- case dispatch per node over heap-scattered cells, while the instruction
-- stream is a linear scan of contiguous memory, which the branch predictor
-- and the cache both like. The honest caveat (func-spec 0022 §2.2) is that
-- func-spec 0010 §9.2 measured the sampling hot spot to be
-- @sin@\/@cos@\/'Magic.Types.hashChan' rather than 'Expr' dispatch, so the
-- expected win here is modest; the order-of-magnitude one is meant to come
-- from parallel sampling.
module Magic.Expr.Code
  ( -- * Compiled programs
    ExprCode (..)
  , ExprCodeV3 (..)
  , compileExpr
  , compileExprV3
  , codeSize

    -- * Evaluation (IEEE-total, mirroring 'Magic.Expr.evalExpr')
  , evalCode
  , evalCodeV3

    -- * Consumption-side entry points (mirroring 'Magic.Expr.evalFinite')
  , evalCodeFinite
  , evalCodeFiniteV3

    -- * Common-subexpression elimination
  , ExprDag (..)
  , DagNode (..)
  , cse
  , cseBuckets
  , dagNodeCount
  , evalDag
  , compileDag
  ) where

import Control.DeepSeq (NFData (..))
import Control.Monad (forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MU
import Data.Word (Word32, Word64)
import GHC.Float (castFloatToWord32, castWord32ToFloat)
import Magic.Expr
  ( BinOp (..)
  , Expr (..)
  , ExprEnv (..)
  , ExprV3 (..)
  , Fun1 (..)
  , Fun2 (..)
  , Fun3 (..)
  , Var (..)
  , exprSize
  )
import Magic.Types (V3 (..), hashChan)

-- Instruction encoding ---------------------------------------------------------

-- | The instruction stream is a @U.Vector Word32@: low 8 bits opcode, high
-- 24 bits an inline operand (constant-pool index, slot number, or a small
-- enum tag). 'Chan' is the one node whose operand is an arbitrary 'Int' and
-- so does not fit; it spends two extra stream words on the payload rather
-- than forcing a second operand pool into 'ExprCode'.
--
-- Pattern synonyms rather than plain constants so the evaluator's dispatch
-- is a @case@ over literals — one jump table — instead of a chain of
-- equality tests, which would have given back exactly the dispatch cost
-- bytecode is here to remove.
pattern OpConst, OpVar, OpChan, OpNeg, OpBin, OpFun1, OpFun2, OpFun3, OpStore, OpLoad :: Word32
pattern OpConst = 0
pattern OpVar = 1
pattern OpChan = 2
pattern OpNeg = 3
pattern OpBin = 4
pattern OpFun1 = 5
pattern OpFun2 = 6
pattern OpFun3 = 7
pattern OpStore = 8
pattern OpLoad = 9

instr :: Word32 -> Int -> Word32
instr op arg = op .|. (fromIntegral arg `shiftL` 8)
{-# INLINE instr #-}

-- | A flattened evaluation program: no pointers, exact-size, made entirely
-- of unboxed vectors and 'Int's — so a 'Magic.Compile.CompiledSpell' holding
-- one is as serializable as it was before (architecture §4.4).
data ExprCode = ExprCode
  { ecOps :: !(U.Vector Word32)
  -- ^ Instruction stream (opcode + inline operand).
  , ecConsts :: !(U.Vector Float)
  -- ^ Constant pool, deduplicated by bit pattern.
  , ecSlots :: !Int
  -- ^ Number of CSE reuse slots (fixed at compile time).
  , ecMaxDepth :: !Int
  -- ^ Exact upper bound on the operand stack (fixed at compile time), so
  -- the evaluator allocates once and then never grows and never checks.
  }
  deriving (Eq, Show)

instance NFData ExprCode where
  rnf (ExprCode o c s d) = o `seq` c `seq` s `seq` d `seq` ()

-- | One program per spatial component — the 'ExprV3' counterpart.
data ExprCodeV3 = ExprCodeV3 !ExprCode !ExprCode !ExprCode
  deriving (Eq, Show)

instance NFData ExprCodeV3 where
  rnf (ExprCodeV3 x y z) = rnf x `seq` rnf y `seq` rnf z

-- | Instruction-stream length: the observable that makes CSE's saving
-- visible. A formula with repeated subterms compiles to fewer instructions
-- than the same formula without sharing.
codeSize :: ExprCode -> Int
codeSize = U.length . ecOps

-- Hash-consed DAG (CSE) --------------------------------------------------------

-- | A node of the shared DAG. Children are indices into 'dagNodes' and are
-- always /smaller/ than the node's own index, so the vector is in
-- topological order by construction and one forward pass evaluates it.
data DagNode
  = DLit !Float
  | DVar !Var
  | DChan !Int
  | DNeg !Int
  | DBin !BinOp !Int !Int
  | DFun1 !Fun1 !Int
  | DFun2 !Fun2 !Int !Int
  | DFun3 !Fun3 !Int !Int !Int
  deriving (Eq, Show)

-- | The result of common-subexpression elimination: every structurally
-- distinct subterm of the source 'Expr' appears exactly once.
--
-- Func-spec 0022 §3 sketched @cse :: Expr -> Expr@, with "or an internal DAG
-- representation" as the alternative; this is that alternative, and it is
-- the one that can be /observed/. Sharing inside an 'Expr' is physical, not
-- structural, so an @Expr -> Expr@ signature cannot express "this subterm is
-- now evaluated once" in any way a test could witness —
-- 'Magic.Expr.exprSize' would go on counting it twice.
data ExprDag = ExprDag
  { dagNodes :: !(V.Vector DagNode)
  , dagRoot :: !Int
  }
  deriving (Eq, Show)

-- | Number of distinct nodes — the thing CSE is supposed to reduce.
dagNodeCount :: ExprDag -> Int
dagNodeCount = V.length . dagNodes

-- | Hash-cons an 'Expr' into a DAG, merging structurally identical subterms.
--
-- Law: @'evalDag' ('cse' e) env ≡ 'Magic.Expr.evalExpr' e env@, bit for bit.
--
-- The hash is only ever a /bucket hint/: a hit is followed by a structural
-- comparison, and only an actual structural match reuses a node. Trusting
-- the hash alone would merge two different formulas whenever they collided,
-- which is not a slow answer but a wrong one (func-spec 0022 §2.6).
cse :: Expr -> ExprDag
cse = cseBuckets 0

-- | 'cse' with the bucket count forced. @0@ auto-sizes to the tree; any
-- positive value is used verbatim, which is how @test\/ExprCseSpec.hs@
-- witnesses collision handling — at one bucket /every/ pair of nodes
-- collides, so only the structural comparison can keep the answer right.
cseBuckets :: Int -> Expr -> ExprDag
cseBuckets bucketHint e = runST $ do
  table <- MV.replicate buckets []
  nodesRef <- newSTRef []
  countRef <- newSTRef (0 :: Int)
  root <- internExpr table nodesRef countRef buckets e
  count <- readSTRef countRef
  nodes <- readSTRef nodesRef
  pure (ExprDag (V.fromListN count (reverse nodes)) root)
  where
    buckets
      | bucketHint > 0 = bucketHint
      | otherwise = max 8 (exprSize e)

-- | Post-order walk that interns every subterm and returns the DAG index of
-- the whole tree.
internExpr
  :: MV.MVector s [(DagNode, Int)]
  -> STRef s [DagNode]
  -> STRef s Int
  -> Int
  -> Expr
  -> ST s Int
internExpr table nodesRef countRef buckets = goE
  where
    add = intern table nodesRef countRef buckets
    goE expr = case expr of
      Lit x -> add (DLit x)
      Var v -> add (DVar v)
      Chan n -> add (DChan n)
      Neg a -> do
        ia <- goE a
        add (DNeg ia)
      Bin op a b -> do
        ia <- goE a
        ib <- goE b
        add (DBin op ia ib)
      Fun1 f a -> do
        ia <- goE a
        add (DFun1 f ia)
      Fun2 f a b -> do
        ia <- goE a
        ib <- goE b
        add (DFun2 f ia ib)
      Fun3 f a b c -> do
        ia <- goE a
        ib <- goE b
        ic <- goE c
        add (DFun3 f ia ib ic)

-- | Look a node up in the bucket table, inserting it if structurally absent.
intern
  :: MV.MVector s [(DagNode, Int)]
  -> STRef s [DagNode]
  -> STRef s Int
  -> Int
  -> DagNode
  -> ST s Int
intern table nodesRef countRef buckets node = do
  bucket <- MV.read table b
  case findIn bucket of
    Just i -> pure i
    Nothing -> do
      i <- readSTRef countRef
      writeSTRef countRef (i + 1)
      modifySTRef' nodesRef (node :)
      MV.write table b ((node, i) : bucket)
      pure i
  where
    b = fromIntegral (nodeHash node `mod` fromIntegral (max 1 buckets))
    findIn [] = Nothing
    findIn ((n, i) : rest)
      | sameNode n node = Just i
      | otherwise = findIn rest

-- | Structural equality, with literals compared by /bit pattern/ rather than
-- by @(==)@: @0.0@ and @-0.0@ are the same number but different values, and
-- a NaN equals nothing at all — the derived 'Eq' would merge the first pair
-- (wrongly) and refuse the second (harmless, but a missed share).
sameNode :: DagNode -> DagNode -> Bool
sameNode a b = case (a, b) of
  (DLit x, DLit y) -> castFloatToWord32 x == castFloatToWord32 y
  (DVar x, DVar y) -> x == y
  (DChan x, DChan y) -> x == y
  (DNeg x, DNeg y) -> x == y
  (DBin o x y, DBin o' x' y') -> o == o' && x == x' && y == y'
  (DFun1 f x, DFun1 f' x') -> f == f' && x == x'
  (DFun2 f x y, DFun2 f' x' y') -> f == f' && x == x' && y == y'
  (DFun3 f x y z, DFun3 f' x' y' z') -> f == f' && x == x' && y == y' && z == z'
  _ -> False

-- | Structural hash of a node. The mixer is 'Magic.Types.hashChan'\'s own
-- splitmix64 finalizer — func-spec 0022 §2.6: one hash function in this
-- project, not two.
nodeHash :: DagNode -> Word64
nodeHash node = case node of
  DLit x -> mixAll [0, fromIntegral (castFloatToWord32 x)]
  DVar v -> mixAll [1, fromIntegral (fromEnum v)]
  DChan n -> mixAll [2, fromIntegral n]
  DNeg a -> mixAll [3, fromIntegral a]
  DBin o a b -> mixAll [4, fromIntegral (fromEnum o), fromIntegral a, fromIntegral b]
  DFun1 f a -> mixAll [5, fromIntegral (fromEnum f), fromIntegral a]
  DFun2 f a b -> mixAll [6, fromIntegral (fromEnum f), fromIntegral a, fromIntegral b]
  DFun3 f a b c ->
    mixAll [7, fromIntegral (fromEnum f), fromIntegral a, fromIntegral b, fromIntegral c]
  where
    mixAll :: [Word64] -> Word64
    mixAll = foldl' (\acc w -> mix64 (acc + w * 0x9E3779B97F4A7C15)) 0

mix64 :: Word64 -> Word64
mix64 z0 =
  let z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
   in z2 `xor` (z2 `shiftR` 31)

-- | Evaluate a DAG directly, one memoized pass in topological order. Not the
-- production path — this is the middle rung's reference evaluator, the thing
-- the CSE law is stated against.
evalDag :: ExprDag -> ExprEnv -> Float
evalDag (ExprDag nodes root) env
  | V.null nodes = 0
  | otherwise = runST $ do
      vals <- MU.unsafeNew (V.length nodes)
      forM_ [0 .. V.length nodes - 1] $ \i -> do
        let at = MU.unsafeRead vals
        v <- case V.unsafeIndex nodes i of
          DLit x -> pure x
          DVar v -> pure (varValue env v)
          DChan n -> pure (hashChan (envSeed env) (envPIndex env) n)
          DNeg a -> negate <$> at a
          DBin o a b -> binOp o <$> at a <*> at b
          DFun1 f a -> fun1 f <$> at a
          DFun2 f a b -> fun2 f <$> at a <*> at b
          DFun3 f a b c -> fun3 f <$> at a <*> at b <*> at c
        MU.unsafeWrite vals i v
      MU.unsafeRead vals root

-- Compilation ------------------------------------------------------------------

-- | The full pipeline of architecture §8.2's remaining two stages: share,
-- then flatten.
--
-- Law: @'evalCode' ('compileExpr' e) env ≡ 'Magic.Expr.evalExpr' e env@, bit
-- for bit. Callers put 'Magic.Expr.foldConstants' in front of it
-- (@foldConstants → cse → compileExpr@, func-spec 0022 §2.6): folding first
-- turns more subterms into identical literals and so raises the CSE hit rate.
compileExpr :: Expr -> ExprCode
compileExpr = compileDag . cse

compileExprV3 :: ExprV3 -> ExprCodeV3
compileExprV3 (ExprV3 x y z) = ExprCodeV3 (compileExpr x) (compileExpr y) (compileExpr z)

-- | Flatten a shared DAG into a stack program.
--
-- A node referenced more than once is evaluated at its first occurrence,
-- kept in a slot, and loaded from there afterwards — which is where sharing
-- actually turns into saved work. Everything else is a plain post-order
-- flattening: @Bin op a b@ becomes @code a; code b; BIN op@.
compileDag :: ExprDag -> ExprCode
compileDag (ExprDag nodes root)
  | V.null nodes = ExprCode (U.singleton (instr OpConst 0)) (U.singleton 0) 0 1
  | otherwise = runST $ do
      -- -2: used once, no slot. -1: shared, slot not yet assigned.
      -- >=0: the slot the value now lives in.
      slotOf <- MU.replicate n (-2 :: Int)
      forM_ [0 .. n - 1] $ \i ->
        when (refCount U.! i >= 2) (MU.unsafeWrite slotOf i (-1))
      opsRef <- newSTRef []
      constsRef <- newSTRef ([], 0 :: Int)
      nextSlot <- newSTRef (0 :: Int)
      let push w = modifySTRef' opsRef (w :)
          constIndex x = do
            (pool, k) <- readSTRef constsRef
            let bits = castFloatToWord32 x
            case lookup bits pool of
              Just j -> pure j
              Nothing -> do
                writeSTRef constsRef ((bits, k) : pool, k + 1)
                pure k
          emit i = do
            s <- MU.unsafeRead slotOf i
            if s >= 0
              then push (instr OpLoad s)
              else do
                case V.unsafeIndex nodes i of
                  DLit x -> constIndex x >>= push . instr OpConst
                  DVar v -> push (instr OpVar (fromEnum v))
                  DChan c -> do
                    let w = fromIntegral c :: Word64
                    push (instr OpChan 0)
                    push (fromIntegral (w .&. 0xFFFFFFFF))
                    push (fromIntegral (w `shiftR` 32))
                  DNeg a -> emit a >> push (instr OpNeg 0)
                  DBin o a b -> emit a >> emit b >> push (instr OpBin (fromEnum o))
                  DFun1 f a -> emit a >> push (instr OpFun1 (fromEnum f))
                  DFun2 f a b -> emit a >> emit b >> push (instr OpFun2 (fromEnum f))
                  DFun3 f a b c ->
                    emit a >> emit b >> emit c >> push (instr OpFun3 (fromEnum f))
                when (s == -1) $ do
                  k <- readSTRef nextSlot
                  writeSTRef nextSlot (k + 1)
                  MU.unsafeWrite slotOf i k
                  push (instr OpStore k)
      emit root
      ops <- (U.fromList . reverse) <$> readSTRef opsRef
      (pool, poolSize) <- readSTRef constsRef
      slots <- readSTRef nextSlot
      let consts = U.replicate poolSize 0 U.// [(j, castWord32ToFloat w) | (w, j) <- pool]
      pure (ExprCode ops consts slots (stackDepth ops))
  where
    n = V.length nodes

    -- How many times each node is referenced (the root counts as one use),
    -- so "referenced at least twice" is exactly "worth a slot".
    refCount :: U.Vector Int
    refCount = U.accumulate (+) (U.replicate n 0) (U.fromList ((root, 1) : concatMap kids (V.toList nodes)))

    kids nd = case nd of
      DLit _ -> []
      DVar _ -> []
      DChan _ -> []
      DNeg a -> [(a, 1 :: Int)]
      DBin _ a b -> [(a, 1), (b, 1)]
      DFun1 _ a -> [(a, 1)]
      DFun2 _ a b -> [(a, 1), (b, 1)]
      DFun3 _ a b c -> [(a, 1), (b, 1), (c, 1)]

-- | Exact maximum operand-stack depth of a finished instruction stream,
-- obtained by simulating the net push\/pop of every instruction. Exact rather
-- than estimated: the evaluator allocates this many cells once and then
-- never checks a bound again.
stackDepth :: U.Vector Word32 -> Int
stackDepth ops = go 0 0 0
  where
    len = U.length ops
    go !pc !sp !best
      | pc >= len = max sp best
      | otherwise =
          let w = U.unsafeIndex ops pc
              op = w .&. 0xFF
              (sp', pc') = case op of
                OpConst -> (sp + 1, pc + 1)
                OpVar -> (sp + 1, pc + 1)
                OpLoad -> (sp + 1, pc + 1)
                OpChan -> (sp + 1, pc + 3)
                OpNeg -> (sp, pc + 1)
                OpFun1 -> (sp, pc + 1)
                OpStore -> (sp, pc + 1)
                OpBin -> (sp - 1, pc + 1)
                OpFun2 -> (sp - 1, pc + 1)
                _ -> (sp - 2, pc + 1) -- OpFun3
           in go pc' sp' (max best sp')

-- Evaluation -------------------------------------------------------------------

-- | Tight-loop evaluation. One allocation per call — a single unboxed buffer
-- holding the operand stack and the CSE slots back to back — and nothing per
-- instruction: no boxed intermediate ever exists, so the cost is flat in the
-- program length instead of showing up on the heap.
--
-- IEEE-total, exactly like 'Magic.Expr.evalExpr': NaN and ±Infinity come back
-- as values, and are flushed only by 'evalCodeFinite'.
evalCode :: ExprCode -> ExprEnv -> Float
evalCode code env = runST (runCode code env)
{-# INLINE evalCode #-}

runCode :: ExprCode -> ExprEnv -> ST s Float
runCode code env = do
  buf <- MU.unsafeNew (frameSize code)
  runCodeIn buf code env
{-# INLINE runCode #-}

-- | Cells one program needs: its operand stack and its CSE slots.
frameSize :: ExprCode -> Int
frameSize (ExprCode _ _ slots depth) = depth + slots
{-# INLINE frameSize #-}

-- | 'runCode' with the buffer supplied, so a caller running several
-- programs for one particle allocates once instead of once each. The buffer
-- must have at least 'frameSize' cells; its contents on entry are
-- irrelevant, since every cell is written before it is read.
runCodeIn :: MU.MVector s Float -> ExprCode -> ExprEnv -> ST s Float
runCodeIn buf (ExprCode ops consts _slots depth) env = do
  let len = U.length ops
      sd = envSeed env
      pidx = envPIndex env
      go !pc !sp
        | pc >= len = if sp <= 0 then pure 0 else MU.unsafeRead buf (sp - 1)
        | otherwise =
            let w = U.unsafeIndex ops pc
                arg = fromIntegral (w `shiftR` 8) :: Int
                push v = MU.unsafeWrite buf sp v >> go (pc + 1) (sp + 1)
                unary f = do
                  a <- MU.unsafeRead buf (sp - 1)
                  MU.unsafeWrite buf (sp - 1) (f a)
                  go (pc + 1) sp
                binary f = do
                  a <- MU.unsafeRead buf (sp - 2)
                  b <- MU.unsafeRead buf (sp - 1)
                  MU.unsafeWrite buf (sp - 2) (f a b)
                  go (pc + 1) (sp - 1)
             in case w .&. 0xFF of
                  OpConst -> push (U.unsafeIndex consts arg)
                  OpVar -> push (varValue env (toEnum arg))
                  OpChan ->
                    let lo = fromIntegral (U.unsafeIndex ops (pc + 1)) :: Word64
                        hi = fromIntegral (U.unsafeIndex ops (pc + 2)) :: Word64
                        c = fromIntegral (lo .|. (hi `shiftL` 32)) :: Int
                     in do
                          MU.unsafeWrite buf sp (hashChan sd pidx c)
                          go (pc + 3) (sp + 1)
                  OpNeg -> unary negate
                  OpBin -> binary (binOp (toEnum arg))
                  OpFun1 -> unary (fun1 (toEnum arg))
                  OpFun2 -> binary (fun2 (toEnum arg))
                  OpFun3 -> do
                    a <- MU.unsafeRead buf (sp - 3)
                    b <- MU.unsafeRead buf (sp - 2)
                    c <- MU.unsafeRead buf (sp - 1)
                    MU.unsafeWrite buf (sp - 3) (fun3 (toEnum arg) a b c)
                    go (pc + 1) (sp - 2)
                  OpStore -> do
                    v <- MU.unsafeRead buf (sp - 1)
                    MU.unsafeWrite buf (depth + arg) v
                    go (pc + 1) sp
                  _ -> do
                    -- OpLoad
                    v <- MU.unsafeRead buf (depth + arg)
                    MU.unsafeWrite buf sp v
                    go (pc + 1) (sp + 1)
  go 0 0
{-# INLINE runCodeIn #-}

-- | Componentwise 'evalCode' — three programs, one 'ST' region, and one
-- buffer big enough for whichever of them needs the most. A formula
-- trajectory runs this once per particle per frame, so three allocations
-- where one will do is three times the garbage for no reason.
evalCodeV3 :: ExprCodeV3 -> ExprEnv -> V3
evalCodeV3 (ExprCodeV3 cx cy cz) env = runST $ do
  buf <- MU.unsafeNew (max (frameSize cx) (max (frameSize cy) (frameSize cz)))
  V3 <$> runCodeIn buf cx env <*> runCodeIn buf cy env <*> runCodeIn buf cz env
{-# INLINE evalCodeV3 #-}

-- | The consumption-side contract, unchanged from 'Magic.Expr.evalFinite':
-- NaN and ±Infinity flush to 0, and they flush /here/ — at the single entry
-- point — rather than anywhere inside the instruction stream. That is what
-- makes a NaN appear at exactly the place it appeared under AST evaluation,
-- which the equivalence law needs (func-spec 0022 §2.2).
evalCodeFinite :: ExprCode -> ExprEnv -> Float
evalCodeFinite code env =
  let v = evalCode code env
   in if isNaN v || isInfinite v then 0 else v
{-# INLINE evalCodeFinite #-}

evalCodeFiniteV3 :: ExprCodeV3 -> ExprEnv -> V3
evalCodeFiniteV3 code env =
  let V3 x y z = evalCodeV3 code env
   in V3 (flush x) (flush y) (flush z)
  where
    flush v = if isNaN v || isInfinite v then 0 else v
{-# INLINE evalCodeFiniteV3 #-}

-- Shared primitives -------------------------------------------------------------

-- These mirror 'Magic.Expr.evalExpr''s own local helpers operation for
-- operation. They are duplicated rather than imported because §2.1 of this
-- round forbids touching "Magic.Expr" at all — including to widen its export
-- list. The equivalence property in @test\/ExprCodeSpec.hs@ is what keeps the
-- two copies honest, and it quantifies over every constructor.

varValue :: ExprEnv -> Var -> Float
varValue env v = case v of
  VarT -> envT env
  VarLife -> envLife env
  VarPIndex -> fromIntegral (envPIndex env)
{-# INLINE varValue #-}

binOp :: BinOp -> Float -> Float -> Float
binOp op = case op of
  Add -> (+)
  Sub -> (-)
  Mul -> (*)
  Div -> (/)
  Pow -> (**)
{-# INLINE binOp #-}

fun1 :: Fun1 -> Float -> Float
fun1 f = case f of
  FSin -> sin
  FCos -> cos
  FAbs -> abs
  FSqrt -> sqrt
  FFloor -> floorF
  FSign -> signum
{-# INLINE fun1 #-}

fun2 :: Fun2 -> Float -> Float -> Float
fun2 f = case f of
  FMin -> min
  FMax -> max
{-# INLINE fun2 #-}

fun3 :: Fun3 -> Float -> Float -> Float -> Float
fun3 FClamp x lo hi = min (max x lo) hi
{-# INLINE fun3 #-}

-- | Byte-for-byte the total floor of "Magic.Expr" (its own @floorF@).
floorF :: Float -> Float
floorF x
  | isNaN x || isInfinite x || abs x >= 8388608 = x
  | otherwise = fromIntegral (floor x :: Int)
{-# INLINE floorF #-}
