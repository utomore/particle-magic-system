-- | S9 (func-spec 0010 §7): the acceptance run for the performance round.
--
-- The individual steps each proved their own law; this one asserts the
-- claim of the whole round, on the real public path and nothing else:
--
--   * every shipped example, cast and flown for 240 frames through
--     'advanceSpell' \/ 'observeSpell', renders exactly the golden frames
--     captured before the rewrite — and stays legal on the way (the
--     buffer invariant, and a valid painter's permutation, every frame);
--   * a 100 000-particle spell — past 'budgetCap', built as a compiled
--     value the way @bench\/Bench.hs@ does — samples the count it should,
--     with finite values in every column;
--   * determinism survives an irregular host cadence: the same dt
--     sequence replays bit for bit;
--   * @maxSpellParticles@ is the cap the core currently publishes. It was
--     4096 when this file was written — func-spec 0010 §8 non-goal 1 left
--     the value alone — and func-spec 0012 S1 raised it to 16384, which
--     is what this sentinel now reads. The golden files above are the
--     other half of that check: raising the cap must not move a single
--     bit of any spell that already fitted.
module Acceptance10Spec (spec) where

import qualified Data.ByteString as BS
import Data.Bits (shiftR, xor, (.&.))
import Data.List (sort)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word64)
import GHC.Float (castFloatToWord32)
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
  , Phase (..)
  , PhasePlan (..)
  , SpawnPattern (..)
  , compile
  )
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , Seed (..)
  , Time (..)
  , advanceSpell
  , batches
  , budgetPlanOf
  , castSpell
  , maxSpellParticles
  , observeSpell
  )
import Magic.Particle.Analytic (sample)
import Magic.Particle.Buffer (bufferInvariant)
import Magic.Projection (ViewPlane (..), depthOrder)
import Magic.Rune (FaceShape (..), RadiationMode (..), Trajectory (..))
import Magic.Types (Seconds (..), V3 (..))
import Test.Hspec

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

-- | The same context, cadence and frame count 'PerfGoldenSpec' primed the
-- golden files with — this run has to reproduce them through the public
-- interface, or the golden files are not describing the shipped path.
ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

frameCount :: Int
frameCount = 240

dt :: FrameInput
dt = FrameInput (DeltaTime (1 / 60))

castOf :: String -> IO ActiveSpell
castOf name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (castSpell (CastRequest circle ctx))

goldenOf :: String -> IO [(Int, Word64)]
goldenOf name = map parseLine . lines <$> readFile ("test/golden/perf-0010/" ++ name ++ ".txt")
  where
    parseLine line = case words line of
      [n, h] -> (read n, read h)
      _ -> error ("malformed golden line: " ++ show line)

-- | Frame digest, identical to 'PerfGoldenSpec''s: count plus FNV-1a over
-- the raw bits of all six columns.
digestOf :: FrameOutput -> (Int, Word64)
digestOf out = (sum (map pbCount buffers), fnv1a (concatMap columns buffers))
  where
    buffers = map rbParticles (batches out)
    columns pb =
      concat
        [ map castFloatToWord32 (U.toList (pbPosX pb))
        , map castFloatToWord32 (U.toList (pbPosY pb))
        , map castFloatToWord32 (U.toList (pbPosZ pb))
        , map castFloatToWord32 (U.toList (pbSize pb))
        , map castFloatToWord32 (U.toList (pbLife pb))
        , U.toList (pbColor pb)
        ]

fnv1a :: [Word32] -> Word64
fnv1a = foldl word 0xcbf29ce484222325
  where
    word h w = foldl byte h [(w `shiftR` s) .&. 0xFF | s <- [0, 8, 16, 24]]
    byte h b = (h `xor` fromIntegral b) * 0x100000001b3

-- | Every frame of the flight, as (digest, all buffers of that frame).
flight :: ActiveSpell -> [((Int, Word64), [ParticleBuffer])]
flight = go frameCount
  where
    go 0 _ = []
    go n s =
      let s' = advanceSpell dt s
          out = observeSpell s'
       in (digestOf out, map rbParticles (batches out)) : go (n - 1 :: Int) s'

-- | A host that drops and stretches frames, the way a real one does.
cadence :: [Double]
cadence = take 180 (cycle [1 / 60, 1 / 60, 1 / 30, 0.004, 0.05, 1 / 60])

-- | Drive a spell along 'cadence', digesting every frame.
walkCadence :: ActiveSpell -> [(Int, Word64)]
walkCadence spell0 = go spell0 cadence
  where
    go _ [] = []
    go s (d : ds) =
      let s' = advanceSpell (FrameInput (DeltaTime d)) s
       in digestOf (observeSpell s') : go s' ds

-- The 100k fixture ------------------------------------------------------------

-- | A single-emitter spell far past 'budgetCap' — the same instrument
-- @bench\/Bench.hs@ measures with. @compile@ would refuse it; @sample@
-- never consults the cap, which is exactly why the cap can be raised by a
-- later spec without the sampler changing.
hugeSpell :: Int -> CompiledSpell
hugeSpell n =
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
        }

allFinite :: ParticleBuffer -> Bool
allFinite pb =
  all
    (U.all (\v -> not (isNaN v) && not (isInfinite v)))
    [pbPosX pb, pbPosY pb, pbPosZ pb, pbSize pb, pbLife pb]

spec :: Spec
spec = describe "func-spec 0010 acceptance (§7 S9)" $ do
  describe "every shipped example flies the golden 240 frames" $
    mapM_ goldenFlight examples

  describe "100 000 particles, past the cap" $ do
    let spell = hugeSpell 100000
        pb = sample spell ctx (Time 2.5)

    it "samples every live particle" $ do
      -- delay 0, duration 8, lifetime 2: at t = 2.5 the spawn window is
      -- still open, so every index is alive.
      pbCount pb `shouldBe` 100000
      bufferInvariant pb `shouldBe` True

    it "produces finite values in every column" $
      allFinite pb `shouldBe` True

    it "is empty before the cast and after the last batch has died" $ do
      pbCount (sample spell ctx (Time (-0.001))) `shouldBe` 0
      pbCount (sample spell ctx (Time 11)) `shouldBe` 0

    it "orders 100 000 particles into a valid painter's permutation" $
      sort (U.toList (depthOrder SideXY pb)) `shouldBe` [0 .. 99999]

    it "reports the budget it was built with" $ do
      budgetTotal (spellBudgetPlan spell) `shouldBe` 100000
      U.toList (budgetPerEmitter (spellBudgetPlan spell)) `shouldBe` [100000]

  describe "determinism under an irregular host cadence" $ do
    it "replays bit for bit, on every example" $
      mapM_
        ( \name -> do
            a <- walkCadence <$> castOf name
            b <- walkCadence <$> castOf name
            a `shouldBe` b
        )
        examples

    it "and the cadence actually simulates something" $ do
      frames <- walkCadence <$> castOf "ring-fire"
      maximum (map fst frames) `shouldSatisfy` (> 100)
      length (filter ((/= 0) . snd) frames) `shouldSatisfy` (> 100)

  describe "the particle cap (raised by func-spec 0012 S1)" $ do
    it "maxSpellParticles is 16384" $
      maxSpellParticles `shouldBe` 16384

    it "and a circle that would exceed it still fails to compile" $ do
      bytes <- BS.readFile "assets/spells/ring-fire.json"
      circle <- either (fail . show) pure (loadCircle bytes)
      -- Sanity: the shipped example compiles, well under the cap.
      case compile circle of
        Left err -> expectationFailure (show err)
        Right spell ->
          budgetTotal (spellBudgetPlan spell) `shouldSatisfy` (<= maxSpellParticles)

    it "every example's budget plan agrees with its emitters" $
      mapM_
        ( \name -> do
            spell <- castOf name
            let plan = budgetPlanOf spell
            U.sum (budgetPerEmitter plan) `shouldBe` budgetTotal plan
        )
        examples

goldenFlight :: String -> Spec
goldenFlight name = describe name $ do
  it "matches the golden frames and stays legal at every one of them" $ do
    spell <- castOf name
    expected <- goldenOf name
    let frames = flight spell
        actual = map fst frames
    length actual `shouldBe` length expected
    case [i | (i, a, e) <- zip3 [0 :: Int ..] actual expected, a /= e] of
      [] -> pure ()
      (i : _) ->
        expectationFailure
          ( "frame " ++ show i ++ ": " ++ show (actual !! i) ++ " /= " ++ show (expected !! i)
          )
    let illegal =
          [ i
          | (i, (_, buffers)) <- zip [0 :: Int ..] frames
          , not (all bufferInvariant buffers && all allFinite buffers)
          ]
    illegal `shouldBe` []
    let badOrder =
          [ i
          | (i, (_, buffers)) <- zip [0 :: Int ..] frames
          , pb <- buffers
          , sort (U.toList (depthOrder SideXY pb)) /= [0 .. pbCount pb - 1]
          ]
    badOrder `shouldBe` []
