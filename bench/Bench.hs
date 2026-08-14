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

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.List (sortOn)
import Data.Ord (Down (..))
import qualified Data.Vector as V
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Magic.Codec (loadCircle)
import Magic.Compile
  ( Anchor (..)
  , Appearance (..)
  , BlendMode (..)
  , ColorRamp (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , ParticleBudget (..)
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
import Magic.Particle.Analytic (sample)
import Magic.Particle.Buffer (pbPosX, pbPosY, pbPosZ)
import Magic.Projection (ViewPlane (..), depthOrder, orthographic)
import Magic.Rune (FaceShape (..), RadiationMode (..), Trajectory (..))
import Magic.Types (Seconds (..))
import Test.Tasty.Bench (bench, bgroup, defaultMain, nf, whnf)

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
        , emAppearance = Appearance (ColorRamp 0xFFD966FF 0xE6390000) 0.05 BlendAdditive Nothing
        , emPhase = Casting
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
    ]
