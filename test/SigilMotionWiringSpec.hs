-- | S3 (func-spec 0020 §7): the wiring — one rotation, applied in one
-- case of 'Magic.Particle.Analytic.positionIn', and the laws that keep it
-- from reaching anything else.
--
-- Func-spec 0020 replaces spec 0016 §1-5's "the Casting phase is
-- untouched" law, which ADR-0015 D4 had already knocked out from under
-- it (the sigil no longer dies at @castStart@, so a law phrased about
-- phases has nothing left to stand on). The two that replace it are
-- phrased about /emitters/ instead, and both are stronger for it:
--
--   * /the main effect is untouched/ — a casting emitter never carries a
--     'SpawnOnStroke' pattern, so the rotation is unreachable from it at
--     every instant of every phase. Witnessed both structurally and by
--     differential comparison against the same spell with every spin
--     zeroed;
--   * /a spell without phases is untouched/ — no @phases@ means no
--     formation emitters at all, so nothing this round added is even
--     constructed. @test\/PerfGoldenSpec.hs@ carries the bit-exact half
--     of that claim for the eight shipped examples: their golden files
--     were not re-recorded this round, and they still pass.
--
-- Alongside them, ADR-0015 D3's law is re-checked with the sigil now
-- moving: a spinning sigil is still not something a gravity well can
-- drag, and the conservative bounds 'Magic.Compile.emitterBounds' derived
-- before the rotation existed still contain it (§2.2, the reason
-- @Magic.Compile@ needed no change).
module SigilMotionWiringSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Motion (..)
  , Phase (..)
  , PhasePlan (..)
  , SpawnPattern (..)
  , compile
  , emitterBounds
  )
import Magic.Interface
  ( ActiveSpell
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , advanceSpell
  , castSpell
  , observeSpell
  )
import Magic.Particle.Analytic (aliveSlots, particleAge, particlePosition, sample)
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Rune (Element (..), EssenceRune (..), ForceField (..), NodeRune (..))
import Magic.Sigil (SigilStroke (..), staticSpin)
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..))
import SigilGen (genAnyCircle)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (sample)

ctx :: CastContext
ctx = CastContext {casterPos = V3 0.25 (-0.5) 1.0, casterFacing = V3 0 1 0, seed = Seed 4242}

compiled :: Circle -> CompiledSpell
compiled = either (error . show) id . compile

circleFile :: String -> IO Circle
circleFile name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

-- | Every shipped example that has no @phases@ key, and therefore no
-- formation emitters and nothing for this round to touch.
unphasedExamples :: [String]
unphasedExamples =
  [ "converge-flame"
  , "empty"
  , "gravity-well"
  , "lissajous"
  , "pulse-ring"
  , "ring-fire"
  , "spiral-spark"
  , "square-burst"
  ]

phasedExamples :: [String]
phasedExamples = ["bare-sigil", "grand-sigil", "lattice-seal", "soft-bloom"]

-- | The same compiled spell with every stroke standing still — the
-- counterfactual "func-spec 0020 was never implemented" build, expressed
-- as data rather than as a second code path.
deSpin :: CompiledSpell -> CompiledSpell
deSpin spell = spell {spellEmitters = V.map stopEmitter (spellEmitters spell)}
  where
    stopEmitter em = em {emMotion = stopMotion (emMotion em)}
    stopMotion m = case motSpawn m of
      SpawnOnStroke sk -> m {motSpawn = SpawnOnStroke sk {skSpin = staticSpin}}
      _ -> m

castingIndices :: CompiledSpell -> [Int]
castingIndices spell =
  [e | (e, em) <- zip [0 ..] (V.toList (spellEmitters spell)), emPhase em == Casting]

formationIndices :: CompiledSpell -> [Int]
formationIndices spell =
  [e | (e, em) <- zip [0 ..] (V.toList (spellEmitters spell)), emPhase em /= Casting]

-- | @(emitter, index, position)@ of every live particle at @t@.
livePositions :: CompiledSpell -> Double -> [(Int, Int, V3)]
livePositions spell t =
  [ (e, i, particlePosition ctx (Time t) em i age)
  | (e, i) <- aliveSlots spell (Time t)
  , let em = spellEmitters spell V.! e
  , Just age <- [particleAge (emSpawn em) (emCount em) i (Time t)]
  ]

-- | Instants spread over the whole cast, so no phase escapes the net.
castTimes :: CompiledSpell -> [Double]
castTimes spell =
  let Seconds end = ppEnd (spellPhases spell)
   in [end * f | f <- [0.02, 0.1 .. 0.98]]

positionsOf :: ParticleBuffer -> [V3]
positionsOf buf =
  [V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) | j <- [0 .. pbCount buf - 1]]

-- | Phases + strong fields: ADR-0015 D3's fixture, now with the sigil in
-- motion.
fieldedCircle :: Circle
fieldedCircle =
  emptyCircle
    { circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))
    , circleFields = [Gravity (V3 0 (-9) 0), PointAttractor (V3 0 0 3) 8 0.5]
    , core =
        Core
          (Just (EssenceRune Fire 1.0))
          (Nodes (Just (DirBias 0.1)) Nothing Nothing Nothing)
    }

walk :: ActiveSpell -> Int -> ActiveSpell
walk spell steps = foldl (\s _ -> advanceSpell (FrameInput (DeltaTime dt)) s) spell [1 .. steps]

dt :: Double
dt = 0.05

timeAfter :: Int -> Time
timeAfter steps = Time (foldl (\acc _ -> acc + dt) 0 [1 .. steps])

spec :: Spec
spec = describe "sigil spin wiring (func-spec 0020 S3)" $ do
  describe "the main effect is untouched" $ do
    it "no casting emitter carries a stroke pattern, on any shipped example" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            sequence_
              [ case motSpawn (emMotion (spellEmitters spell V.! e)) of
                  SpawnOnStroke sk -> expectationFailure (name ++ ": casting on " ++ show (skKind sk))
                  _ -> pure ()
              | e <- castingIndices spell
              ]
        )
        (unphasedExamples ++ phasedExamples)

    prop "...nor on any circle at all" $
      forAll genAnyCircle $ \c ->
        let spell = compiled c
         in conjoin
              [ case motSpawn (emMotion (spellEmitters spell V.! e)) of
                  SpawnOnStroke _ -> counterexample "casting emitter on a stroke" False
                  _ -> property True
              | e <- castingIndices spell
              ]

    it "so casting rows are bit-for-bit what a spin-free build produces, at every instant" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            let casting = castingIndices spell
                rowsAt s t = [(e, i, p) | (e, i, p) <- livePositions s t, e `elem` casting]
            sequence_
              [ rowsAt spell t `shouldBe` rowsAt (deSpin spell) t
              | t <- castTimes spell
              ]
        )
        phasedExamples

    it "and the sigil's own rows are the ones that moved (the change is real)" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            let formation = formationIndices spell
                rowsAt s t = [p | (e, _, p) <- livePositions s t, e `elem` formation]
                Seconds end = ppEnd (spellPhases spell)
                t = end * 0.5
            rowsAt spell t `shouldNotBe` rowsAt (deSpin spell) t
        )
        phasedExamples

  describe "a spell without phases is untouched" $ do
    it "compiles to no formation emitter at all" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            formationIndices spell `shouldBe` []
        )
        unphasedExamples

    it "and samples bit-for-bit identically with and without the spin term" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            let Seconds end = ppEnd (spellPhases spell)
            sequence_
              [ sample spell ctx (Time t) `shouldBe` sample (deSpin spell) ctx (Time t)
              | t <- [0, 0.05 .. end + 0.2]
              ]
        )
        unphasedExamples

  describe "the sigil still ignores force fields (ADR-0015 D3, now in motion)" $ do
    it "every formation row is exactly undisplaced, all the way through the cast" $ do
      let spell = compiled fieldedCircle
      spell0 <- either (fail . show) pure (castSpell (CastRequest fieldedCircle ctx))
      sequence_
        [ let FrameOutput bs = observeSpell (walk spell0 steps)
              observed = concatMap (positionsOf . rbParticles) bs
              t = timeAfter steps
              analytic = positionsOf (sample spell ctx t)
              formation = formationIndices spell
              rigid =
                [ (o, a)
                | ((e, _), o, a) <- zip3 (aliveSlots spell t) observed analytic
                , e `elem` formation
                ]
           in do
                length observed `shouldBe` length (aliveSlots spell t)
                length rigid `shouldSatisfy` (> 0)
                map fst rigid `shouldBe` map snd rigid
        | steps <- [40, 60, 80, 100 :: Int]
        ]

    it "while the casting rows next to them really are bent" $ do
      let spell = compiled fieldedCircle
      spell0 <- either (fail . show) pure (castSpell (CastRequest fieldedCircle ctx))
      let FrameOutput bs = observeSpell (walk spell0 80)
          observed = concatMap (positionsOf . rbParticles) bs
          analytic = positionsOf (sample spell ctx (timeAfter 80))
      length observed `shouldBe` length analytic
      observed `shouldNotBe` analytic

  describe "emitterBounds needed no change (the rotation preserves length)" $ do
    it "every formation particle of every shipped sigil stays inside its box" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            let boxes =
                  [ emitterBounds ctx (spellLifetime spell) em
                  | em <- V.toList (spellEmitters spell)
                  ]
                formation = formationIndices spell
                escapes =
                  [ (e, i, p)
                  | t <- castTimes spell
                  , (e, i, p) <- livePositions spell t
                  , e `elem` formation
                  , not (inBox (boxes !! e) p)
                  ]
            case escapes of
              [] -> pure ()
              (bad : _) -> expectationFailure (name ++ ": escaped its box: " ++ show bad)
        )
        phasedExamples

    it "the center of the sigil does not move (陣心不動)" $ do
      -- The center and node emitters are anchored points, not strokes, so
      -- the rotation cannot reach them: they hold exactly where they were
      -- drawn, giving the turning figure a fixed visual anchor.
      let circle = emptyCircle {circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6)), core = Core (Just (EssenceRune Fire 1.0)) (Nodes Nothing Nothing Nothing Nothing)}
          spell = compiled circle
          anchored =
            [ e
            | e <- formationIndices spell
            , case motSpawn (emMotion (spellEmitters spell V.! e)) of
                SpawnAtAnchor _ -> True
                _ -> False
            ]
          posAt e t =
            let em = spellEmitters spell V.! e
             in [particlePosition ctx (Time t) em i 0 | i <- [0 .. emCount em - 1]]
      anchored `shouldNotBe` []
      sequence_
        [posAt e t `shouldBe` posAt e 0 | e <- anchored, t <- [0.5, 1.5, 2.5, 3.5]]

inBox :: (V3, V3) -> V3 -> Bool
inBox (V3 lx ly lz, V3 hx hy hz) (V3 x y z) =
  x >= lx - eps && x <= hx + eps && y >= ly - eps && y <= hy + eps && z >= lz - eps && z <= hz + eps
  where
    eps = 1e-4
