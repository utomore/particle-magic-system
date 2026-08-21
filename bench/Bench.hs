-- | Throughput measurements: the func-spec 0005 §8 S8 baselines, plus the
-- groups func-spec 0010 S8 adds.
--
-- 0005 measured casting each example circle, sampling a full particle
-- buffer at a range of ages ('observeSpell'), and expanding that buffer
-- into camera-facing quads ('buildQuads'). 0010 rewrote the hot path, so
-- it adds what that rewrite touched and 0005 could not see:
--
--   * 'advanceSpell' with and without a force field — the per-step cost of
--     the SoA integration state against the zero-field fast path;
--   * 'depthOrder' at the 4096 cap — the in-place introsort against the
--     boxed 'Data.List.sortOn' it replaced;
--   * synthetic 10k / 50k / 100k sampling, the range ADR-0006 names as the
--     target and 'budgetCap' still forbids a compiled spell from reaching.
--     Those fixtures are 'CompiledSpell' values built here rather than
--     compiled circles: @sample@ never consults the cap, so this is the
--     real code path at a size @compile@ would refuse.
--
-- Everything here is compiled with @-O2@; numbers taken without it mean
-- nothing.
module Main (main) where

import Control.Exception (evaluate)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import GHC.Clock (getMonotonicTime)
import GHC.Conc (getNumCapabilities)
import Data.Ord (Down (..))
import qualified Data.Vector as V
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Magic.Codec (loadCircle)
import Magic.Compile
  ( Anchor (..)
  , Appearance (..)
  , BillboardShape (..)
  , BlendMode (..)
  , ColorRamp (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , ParticleBudget (..)
  , compile
  , noEmitterCode
  , Phase (..)
  , PhasePlan (..)
  , SpawnPattern (..)
  )
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , Circle
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer
  , RenderBatch (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , isFinished
  , observeSpell
  , pbCount
  , spellAge
  )
import Magic.Expr
  ( BinOp (..)
  , Expr (..)
  , ExprEnv (..)
  , Fun1 (..)
  , Var (..)
  , evalFinite
  , exprSize
  , foldConstants
  )
import Magic.Expr.Code
  ( codeSize
  , compileExpr
  , cse
  , dagNodeCount
  , evalCodeFinite
  )
import Magic.Particle.Analytic
  ( parallelChunk
  , parallelThreshold
  , sample
  , sampleParallel
  , sampleSequential
  , spellShards
  )
import Magic.Particle.Buffer (pbPosX, pbPosY, pbPosZ)
import Magic.Projection (ViewPlane (..), depthOrder, orthographic)
import Magic.Rune (FaceShape (..), RadiationMode (..), Trajectory (..))
import Magic.Types (Seconds (..))
import Test.Tasty.Bench (bench, bgroup, defaultMain, nf, nfIO, whnf)

import App.Render.Quads (QuadBatch (..), buildQuads)

examples :: [FilePath]
examples =
  [ "assets/spells/ring-fire.json"
  , "assets/spells/square-burst.json"
  , "assets/spells/spiral-spark.json"
  , "assets/spells/converge-flame.json"
  ]

-- | A circle whose essence power drives the particle count to the core's
-- 4096 budget cap (count = round (power * 256)). Inline rather than an
-- asset file: it is a measuring instrument, not an example spell.
denseBytes :: BS.ByteString
denseBytes =
  BS8.pack
    "{ \"version\": 1, \"name\": \"bench-dense\", \"circle\": \
    \{ \"core\": { \"center\": { \"element\": \"fire\", \"power\": 16.0 }, \
    \\"nodes\": { \"north\": null, \"south\": null, \"east\": null, \"west\": null } } } }"

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

camPos, camTarget, camUp :: V3
camPos = V3 6 4 6
camTarget = V3 0 2 0
camUp = V3 0 1 0

loadOrDie :: FilePath -> IO Circle
loadOrDie path = do
  bytes <- BS.readFile path
  either (fail . show) pure (loadCircle bytes)

castOrDie :: Circle -> IO ActiveSpell
castOrDie circle = either (fail . show) pure (castSpell (CastRequest circle ctx))

-- | Age a spell by @n@ frames of 1/60s without sampling.
ageBy :: Int -> ActiveSpell -> ActiveSpell
ageBy n s0 = go n s0
  where
    dt = FrameInput (DeltaTime (1 / 60))
    go k s
      | k <= 0 = s
      | otherwise = go (k - 1) (advanceSpell dt s)

-- | Total particles observed — forces every SoA column of the buffer.
countOf :: FrameOutput -> Int
countOf out = sum (map (pbCount . rbParticles) (batches out))

bufferOf :: ActiveSpell -> ParticleBuffer
bufferOf s = case batches (observeSpell s) of
  (b : _) -> rbParticles b
  [] -> error "benchmark fixture produced no batch"

-- | Forcing the summed positions and the color vector's length
-- materializes both staging vectors in full.
forceQuads :: ParticleBuffer -> Float
forceQuads pb =
  let q = buildQuads camPos camTarget camUp pb
   in S.sum (qbPositions q) + fromIntegral (S.length (qbColors q))

-- func-spec 0010 S8 fixtures ---------------------------------------------------

-- | A single-emitter spell of @n@ particles, built without going through
-- 'Magic.Compile.compile' so it can be far past 'budgetCap'. Envelope and
-- motion are the shipped @ring-fire@ shape, so the per-particle work is
-- what a real spell does, only more of it.
syntheticSpell :: Int -> CompiledSpell
syntheticSpell n =
  CompiledSpell
    { spellLifetime = Seconds 10
    , spellBudget = n
    , spellEmitters = V.singleton emitter
    , spellPhases = PhasePlan (Seconds 0) (Seconds 0) (Seconds 8) (Seconds 10)
    , spellBudgetPlan = ParticleBudget (U.singleton n) n
    , spellFields = []
    }
  where
    emitter =
      EmitterSpec
        { emAnchor = Anchor {anchorOffset = V3 0 0 0, anchorNormal = V3 0 0 1}
        , emCount = n
        , emSpawn = Envelope (Seconds 0) (Seconds 8) (Seconds 2)
        , emMotion =
            Motion
              { motSpawn = SpawnOnShape (Ring 0.8 1.2)
              , motTraject = Forward 4
              , motRadiation = AlongNormal
              , motDrift = V3 0 0 0
              , motRange = Nothing
              , motConverge = Nothing
              }
        , emAppearance = Appearance (ColorRamp 0xFFD966FF 0xE6390000) 0.05 BlendAdditive Nothing BillboardSquare
        , emPhase = Casting
        -- func-spec 0022 S3: this fixture carries no formulas at all, so "no
        -- bytecode compiled" is the accurate value rather than a shortcut --
        -- there is nothing here for the sampler to run either way.
        , emCode = noEmitterCode
        }

-- | Sample the synthetic spell and force every column by summing one of
-- them and counting the rows.
sampleCost :: CompiledSpell -> Time -> Float
sampleCost spell t =
  let pb = sample spell ctx t
   in U.sum (pbPosX pb) + fromIntegral (pbCount pb)

-- | Advance @n@ fixed steps and read the clock — forcing the whole chain,
-- including (for a spell with fields) every integration step.
advanceCost :: Int -> ActiveSpell -> Double
advanceCost n s0 = let Time age = spellAge (ageBy n s0) in age

-- | host-runtime F004's wall-clock control. What @pm_advance@ does to a
-- handle's cell, both ways: the pre-F004 read-modify-write and the atomic
-- step that replaced it, over the same real spell and the same @dt@.
--
-- The shapes are spelled out here rather than imported because @Magic.FFI@
-- lives in the foreign library, which this stanza does not (and should
-- not) depend on. @stepCell@ is a one-line shell over 'atomicModifyIORef''
-- precisely so that this control measures the same instruction sequence
-- the shipped shell executes.
--
-- The number to read off is the DIFFERENCE per call. The absolute figures
-- include one 'advanceSpell', which for a field-carrying spell dwarfs both
-- primitives; the fieldless row is where the synchronisation shows up.
cellStepLegacy :: IORef ActiveSpell -> Int -> IO Double
cellStepLegacy ref n = go n
  where
    fi = FrameInput (DeltaTime (1 / 60))
    go k
      | k <= 0 = do
          s <- readIORef ref
          let Time age = spellAge s
          pure age
      | otherwise = do
          s <- readIORef ref
          writeIORef ref $! advanceSpell fi s
          go (k - 1)

cellStepAtomic :: IORef ActiveSpell -> Int -> IO Double
cellStepAtomic ref n = go n
  where
    fi = FrameInput (DeltaTime (1 / 60))
    go k
      | k <= 0 = do
          s <- readIORef ref
          let Time age = spellAge s
          pure age
      | otherwise = do
          atomicModifyIORef' ref (\s -> (advanceSpell fi s, ()))
          go (k - 1)

depthCost :: ViewPlane -> ParticleBuffer -> Int
depthCost plane pb = U.sum (depthOrder plane pb)

-- | The pre-0010 'depthOrder': 'Data.List.sortOn' over a boxed list of
-- the whole batch. Kept here, and nowhere else, so the introsort that
-- replaced it is measured against something rather than asserted about.
legacyDepthCost :: ViewPlane -> ParticleBuffer -> Int
legacyDepthCost plane pb = sum (map fst (sortOn (Down . snd) keyed))
  where
    keyed = [(i, depthAt i) | i <- [0 .. pbCount pb - 1]]
    depthAt i =
      snd (orthographic plane (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i)))

-- | The range ADR-0006 targets.
syntheticSizes :: [Int]
syntheticSizes = [10000, 50000, 100000]

-- | The whole per-frame CPU cost at one particle count: sample the buffer
-- and expand it into quads, the two terms func-spec 0005 §10 and 0010
-- §9.2 measured separately.
--
-- Func-spec 0012 S1 picks the particle cap by this number: the largest
-- power of two whose frame cost stays under 2 ms. Measuring it directly
-- at the candidate values beats extrapolating from the 100k figure, which
-- is what the 0010 acceptance record could only offer.
frameCost :: CompiledSpell -> Time -> Float
frameCost spell t =
  let pb = sample spell ctx t
   in forceQuads pb + fromIntegral (pbCount pb)

-- | The powers of two either side of the cap func-spec 0012 chose.
capCandidates :: [Int]
capCandidates = [4096, 8192, 16384, 32768]

-- func-spec 0022 S6 fixtures ---------------------------------------------------

-- | Formulas of the shape a player actually writes, and the shape this
-- round is meant to help. @wave@ is a plain trajectory term; @shared@
-- repeats @sin(3t)@ three times, which is what CSE is for; @deep@ is a long
-- chain, where the flat instruction stream should beat the pointer chase by
-- the widest margin it ever will.
benchExprs :: [(String, Expr)]
benchExprs =
  [ ("wave", wave)
  , ("shared", Bin Add (Bin Mul s s) (Bin Sub s (Var VarLife)))
  , ("deep", chain 64)
  ]
  where
    s = Fun1 FSin (Bin Mul (Lit 3) (Var VarT))
    wave =
      Bin
        Add
        (Bin Mul (Lit 2) (Fun1 FSin (Bin Mul (Lit 3) (Var VarT))))
        (Fun1 FCos (Bin Mul (Lit 2) (Var VarT)))
    chain n = go (n :: Int) (Var VarT)
      where
        go 0 acc = acc
        go k acc = go (k - 1) (Bin Add (Fun1 FSin acc) (Lit 1))

-- | The production pipeline: fold, share, flatten (func-spec 0022 §2.6).
prepared :: Expr -> Expr
prepared = foldConstants

-- | @n@ evaluations of a formula over varying particle indices — the shape
-- the sampler runs it in, one per particle per frame.
astExprCost :: Expr -> Int -> Float
astExprCost e n = go 0 0
  where
    go !i !acc
      | i >= n = acc
      | otherwise = go (i + 1) (acc + evalFinite e (exprEnvAt i))

codeExprCost :: Expr -> Int -> Float
codeExprCost e n = go 0 0
  where
    code = compileExpr e
    go !i !acc
      | i >= n = acc
      | otherwise = go (i + 1) (acc + evalCodeFinite code (exprEnvAt i))

exprEnvAt :: Int -> ExprEnv
exprEnvAt i =
  ExprEnv
    { envT = fromIntegral i * 0.001
    , envLife = fromIntegral (i `mod` 100) * 0.01
    , envPIndex = i
    , envSeed = Seed 2026
    }

-- | How much of a formula CSE removes: nodes before, nodes after,
-- instructions emitted. Reported rather than benchmarked — a hit rate is a
-- number, not a duration.
cseReport :: (String, Expr) -> String
cseReport (name, e0) =
  name
    ++ ": "
    ++ show (exprSize e0)
    ++ " AST nodes -> "
    ++ show (exprSize e)
    ++ " folded -> "
    ++ show (dagNodeCount (cse e))
    ++ " shared -> "
    ++ show (codeSize (compileExpr e))
    ++ " instructions"
  where
    e = prepared e0

-- | The same spell with every compiled program removed, so the sampler
-- falls back to 'Magic.Expr.evalFinite' over the AST.
stripCode :: CompiledSpell -> CompiledSpell
stripCode spell =
  spell {spellEmitters = V.map (\em -> em {emCode = noEmitterCode}) (spellEmitters spell)}

-- | Shipped examples that actually carry formulas — the only ones for which
-- "bytecode vs AST" is a question rather than a tautology.
formulaExamples :: [FilePath]
formulaExamples =
  [ "assets/spells/lissajous.json"
  , "assets/spells/converge-flame.json"
  , "assets/spells/pulse-ring.json"
  ]

-- The parallel measurement, on a wall clock -------------------------------------

-- | Sizes either side of 'parallelThreshold', so the acceptance record can
-- say where the parallel path starts paying for itself rather than assert
-- it. Powers of two around the threshold plus the ADR-0006 target range.
parallelSizes :: [Int]
parallelSizes = [1024, 2048, 4096, 8192, 16384, 32768, 100000]

-- | Force every column of a buffer, so the measurement is of the whole
-- sample and not of a thunk.
forceBuffer :: ParticleBuffer -> Float
forceBuffer pb = U.sum (pbPosX pb) + U.sum (pbPosZ pb) + fromIntegral (pbCount pb)

-- | Milliseconds per call, on the /wall/ clock, averaged over @reps@.
--
-- This section deliberately does not go through 'Test.Tasty.Bench':
-- tasty-bench measures __CPU__ time, which for a parallel computation goes
-- /up/ as the work is spread over more cores. It is the right instrument
-- for every other group in this file and exactly the wrong one for this
-- one — an early draft of func-spec 0022's acceptance run read "parallel is
-- 15% slower at 100k" off it, when the same work on a wall clock was 3.7×
-- faster. The numbers below are the ones §9 records.
--
-- The time argument varies by an unobservably small amount per repetition,
-- which changes nothing about the work and everything about whether GHC may
-- float the sample out of the loop and measure a memoized thunk.
timeMs :: Int -> (Int -> Float) -> IO Double
timeMs reps f = do
  _ <- evaluate (f 0)
  t0 <- getMonotonicTime
  let go !i !acc
        | i >= reps = acc
        | otherwise = go (i + 1) (acc + f i)
  _ <- evaluate (go 0 0)
  t1 <- getMonotonicTime
  pure ((t1 - t0) / fromIntegral reps * 1000)

-- | The sequential\/parallel table at the current capability count. Run the
-- binary at @+RTS -N1@, @-N2@, @-N4@, @-N8@ to get the speed-up curve; the
-- two columns are the same buffer computed two ways (law 2), so the ratio
-- is a pure statement about time.
parallelReport :: IO ()
parallelReport = do
  caps <- getNumCapabilities
  putStrLn ("-- sample: sequential vs parallel, wall clock, -N" ++ show caps)
  mapM_ row parallelSizes
  where
    row n = do
      let spell = syntheticSpell n
          at i = Time (2.5 + fromIntegral i * 1e-9)
          reps = max 20 (2000000 `div` max 1 n)
      s <- timeMs reps (\i -> forceBuffer (sampleSequential spell ctx (at i)))
      p <- timeMs reps (\i -> forceBuffer (sampleParallel spell ctx (at i)))
      putStrLn
        ( "   "
            ++ pad 8 (show n)
            ++ " particles  seq "
            ++ pad 9 (micro s)
            ++ "  par "
            ++ pad 9 (micro p)
            ++ "  speedup "
            ++ show (fromIntegral (round (s / p * 100) :: Int) / 100 :: Double)
            ++ (if n < parallelThreshold then "   (below threshold: sample takes the sequential path)" else "")
        )
    micro x = show (round (x * 1000) :: Int) ++ " us"
    pad w s = s ++ replicate (w - length s) ' '

-- | Cast and force the compiled spell to its constructor. 'isFinished'
-- reads @spellLifetime@, so the strict 'CompiledSpell' record exists —
-- but its emitter vector's elements stay lazy, so this is the floor of
-- what casting costs, not the whole of it.
castCost :: Circle -> Bool
castCost c = either (const True) isFinished (castSpell (CastRequest c ctx))

-- | What a hot reload actually costs: cast, then sample the first frame,
-- which forces every emitter the interpretation produced.
castAndObserveCost :: Circle -> Int
castAndObserveCost c =
  either (const (-1)) (countOf . observeSpell) (castSpell (CastRequest c ctx))

main :: IO ()
main = do
  circles <- mapM loadOrDie examples
  denseCircle <- either (fail . show) pure (loadCircle denseBytes)
  denseSpell <- castOrDie denseCircle
  -- The two ends of the ADR-0010 D9 fast path: a fieldless spell carries
  -- its integration state through untouched, a spell with fields pays for
  -- every live slot, every step.
  fieldlessSpell <- castOrDie =<< loadOrDie "assets/spells/ring-fire.json"
  fieldSpell <- castOrDie =<< loadOrDie "assets/spells/gravity-well.json"
  -- Births are spread over the envelope lifetime, so by ~2s the whole
  -- budget is alive; the ages below straddle that ramp.
  let ages = [30, 60, 120, 240, 480 :: Int]
      agedSpells = map (`ageBy` denseSpell) ages
      buffer = bufferOf (ageBy 240 denseSpell)

  putStrLn ("benchmark buffer particle count: " ++ show (pbCount buffer))
  putStrLn
    ( "synthetic live particle counts at t=2.5: "
        ++ show [(n, pbCount (sample (syntheticSpell n) ctx (Time 2.5))) | n <- syntheticSizes]
    )
  putStrLn
    ( "particle counts by age: "
        ++ show [(a, pbCount (bufferOf s)) | (a, s) <- zip ages agedSpells]
    )
  -- func-spec 0022 S6. The CSE hit rate and the shard layout are counts,
  -- not durations, so they are reported here rather than benchmarked.
  caps <- getNumCapabilities
  putStrLn ("capabilities: " ++ show caps)
  putStrLn
    ( "parallel threshold / chunk: "
        ++ show parallelThreshold
        ++ " / "
        ++ show parallelChunk
    )
  putStrLn
    ( "shards at t=2.5: "
        ++ show [(n, length (spellShards (syntheticSpell n) (Time 2.5))) | n <- parallelSizes]
    )
  mapM_ (putStrLn . ("CSE " ++) . cseReport) benchExprs
  formulaSpells <-
    mapM
      ( \path -> do
          circle <- loadOrDie path
          spell <- either (fail . show) pure (compile circle)
          pure (takeWhile (/= '.') (drop (length ("assets/spells/" :: String)) path), spell)
      )
      formulaExamples
  parallelReport
  defaultMain
    [ bgroup
        "castSpell (compile only)"
        [ bench name (nf castCost circle)
        | (name, circle) <- zip examples circles
        ]
    , bgroup
        "castSpell + first observe"
        [ bench name (nf castAndObserveCost circle)
        | (name, circle) <- zip examples circles
        ]
    , bgroup
        "observeSpell"
        [ bench ("age " ++ show a ++ " frames") (nf (countOf . observeSpell) s)
        | (a, s) <- zip ages agedSpells
        ]
    , bgroup
        "buildQuads"
        [ bench ("count " ++ show (pbCount buffer)) (whnf forceQuads buffer)
        ]
    , -- func-spec 0010 S8 -----------------------------------------------
      bgroup
        "advanceSpell (60 fixed steps)"
        [ bench "ring-fire (no fields)" (nf (advanceCost 60) fieldlessSpell)
        , bench "gravity-well (2 fields)" (nf (advanceCost 60) fieldSpell)
        ]
    , -- host-runtime F004 T7: the cost of "no lost updates", measured
      -- rather than argued. 1000 steps per iteration so the per-call
      -- difference is readable above the timer's own noise.
      bgroup
        "handle cell advance (1000 steps)"
        [ bench "ring-fire (no fields) / pre-F004 read-modify-write" $
            nfIO (newIORef fieldlessSpell >>= \r -> cellStepLegacy r 1000)
        , bench "ring-fire (no fields) / F004 atomic step" $
            nfIO (newIORef fieldlessSpell >>= \r -> cellStepAtomic r 1000)
        , bench "gravity-well (2 fields) / pre-F004 read-modify-write" $
            nfIO (newIORef fieldSpell >>= \r -> cellStepLegacy r 1000)
        , bench "gravity-well (2 fields) / F004 atomic step" $
            nfIO (newIORef fieldSpell >>= \r -> cellStepAtomic r 1000)
        ]
    , bgroup
        "depthOrder"
        ( [ bench (show plane ++ " @ " ++ show (pbCount buffer)) (whnf (depthCost plane) buffer)
          | plane <- [SideXY, TopXZ]
          ]
            ++ [ bench
                  (show plane ++ " @ " ++ show (pbCount buffer) ++ " (pre-0010 sortOn)")
                  (whnf (legacyDepthCost plane) buffer)
               | plane <- [SideXY, TopXZ]
               ]
        )
    , bgroup
        "sample (synthetic, past the cap)"
        [ bench (show n ++ " particles") (whnf (\s -> sampleCost s (Time 2.5)) spell)
        | n <- syntheticSizes
        , let spell = syntheticSpell n
        ]
    , -- func-spec 0012 S1: the cap selection measurement ----------------
      bgroup
        "frame CPU (sample + buildQuads)"
        [ bench (show n ++ " particles") (whnf (\s -> frameCost s (Time 2.5)) spell)
        | n <- capCandidates
        , let spell = syntheticSpell n
        ]
    , -- func-spec 0022 S6 ----------------------------------------------
      -- The Expr acceleration ladder's second and third rungs, against the
      -- reference AST walk they replace. Func-spec 0022 §2.2 predicts a
      -- modest win here (0010 measured the sampling hot spot to be
      -- sin/cos/hashChan, not Expr dispatch); this is where that prediction
      -- is either confirmed or corrected.
      bgroup
        "Expr evaluation (10k evaluations)"
        ( concat
            [ [ bench (name ++ " / AST (evalExpr)") (whnf (astExprCost (prepared e)) 10000)
              , bench (name ++ " / bytecode (evalCode)") (whnf (codeExprCost (prepared e)) 10000)
              ]
            | (name, e) <- benchExprs
            ]
        )
    , bgroup
        "compile a formula (once per cast, not per particle)"
        [ bench name (nf (codeSize . compileExpr . prepared) e)
        | (name, e) <- benchExprs
        ]
    , -- The measurement the round exists for. Run the binary at -N1, -N2,
      -- -N4, -N8 and read the speed-up off the same rows; the sequential
      -- row is the invariant baseline the parallel one is divided by, and
      -- the two produce identical buffers (law 2), so this is a pure
      -- time comparison of one answer computed two ways.
      bgroup
        "sample: which path sample picks (CPU time, single-threaded)"
        [ bench (show n ++ " particles") (whnf (\s -> sampleCost s (Time 2.5)) spell)
        | n <- [parallelThreshold - 1, parallelThreshold]
        , let spell = syntheticSpell n
        ]
    , -- The question the two groups above cannot answer between them: does
      -- routing a /real/ spell's formulas through the bytecode make its
      -- frame cheaper? 'stripCode' is the same spell with the compiled
      -- programs removed, so the sampler falls back to walking the AST —
      -- the same buffer, bit for bit (law 1), by the evaluator this round
      -- replaced.
      bgroup
        "sample a formula-carrying spell: bytecode vs AST"
        ( concat
            [ [ bench (name ++ " / bytecode") (whnf (\s -> sampleCost s (Time 2.5)) spell)
              , bench (name ++ " / AST") (whnf (\s -> sampleCost s (Time 2.5)) (stripCode spell))
              ]
            | (name, spell) <- formulaSpells
            ]
        )
    ]
