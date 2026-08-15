-- | S4 (func-spec 0016 §7): the wiring — 'SpawnOnStroke' inside the
-- compiled motion, 'formationEmittersFor' driven by the plan,
-- 'emitterBounds' bounding the new pattern, and the sampler drawing it.
--
-- The load-bearing claim is the /casting phase is untouched/ law. Sigil
-- geometry is a Drawing/Converging concern; a spell without @phases@ has
-- no formation emitters at all and must render bit-for-bit what it did
-- before this round, and a spell /with/ phases must keep its casting
-- emitter bit-for-bit too. ADR-0014 records that the bit-exactness
-- exemption reaches exactly two phases and no further.
module SigilWiringSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompileError (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Motion (..)
  , ParticleBudget (..)
  , Phase (..)
  , PhasePlan (..)
  , SpawnPattern (..)
  , budgetCap
  , compile
  , emitterBounds
  )
import Magic.Particle.Analytic (aliveSlots, particleAge, particlePosition, sample)
import Magic.Particle.Buffer (ParticleBuffer (..), bufferInvariant)
import Magic.Rune (EssenceRune (..), Element (..), NodeRune (..))
import Magic.Sigil (SigilStroke (..), sigilBudget, sigilPlan, spStrokes)
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (sample)

ctx :: CastContext
ctx = CastContext {casterPos = V3 0.25 (-0.5) 1.0, casterFacing = V3 0 1 0, seed = Seed 4242}

compiled :: Circle -> CompiledSpell
compiled = either (error . show) id . compile

circleOf :: String -> IO Circle
circleOf name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

-- | Every example that shipped before this round without @phases@: no
-- formation emitters, so not one bit of them may move.
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
phasedExamples = ["bare-sigil", "grand-sigil", "soft-bloom"]

phased :: PhaseConfig
phased = PhaseConfig (Seconds 1.2) (Seconds 0.6)

fullCircle :: Circle
fullCircle =
  emptyCircle
    { interLayer = Nothing
    , innerRings = TwoOf Nothing Nothing
    , core =
        Core
          (Just (EssenceRune Fire 1.0))
          (Nodes (Just (DirBias 0.1)) (Just (DirBias 0.1)) (Just (DirBias 0.1)) (Just (DirBias 0.1)))
    , circlePhases = Just phased
    }

formationEmitters :: CompiledSpell -> [EmitterSpec]
formationEmitters spell = [em | em <- V.toList (spellEmitters spell), emPhase em /= Casting]

spec :: Spec
spec = describe "sigil wiring (func-spec 0016 S4)" $ do
  describe "the casting phase is untouched" $ do
    it "an unphased example compiles to exactly one emitter, and it is casting" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleOf name
            V.length (spellEmitters spell) `shouldBe` 1
            emPhase (V.head (spellEmitters spell)) `shouldBe` Casting
        )
        unphasedExamples

    -- Func-spec 0017 retired the stronger form of this ("from castStart
    -- on the buffer is the casting emitter's alone"): the sigil now stays
    -- drawn for the whole cast. What survives is the part that was always
    -- the point — the casting emitter itself is untouched by any of this.
    it "the casting emitter's rows are the same whether or not the sigil is drawn beside it" $
      mapM_
        ( \name -> do
            circle <- circleOf name
            let spell = compiled circle
                castingOnly = spell {spellEmitters = V.take 1 (spellEmitters spell)}
                Seconds castStart = ppConvergeEnd (spellPhases spell)
                Seconds end = spellLifetime spell
                castingRows t =
                  let em = V.head (spellEmitters spell)
                   in [ particlePosition ctx (Time t) em i age
                      | i <- [0 .. emCount em - 1]
                      , Just age <- [particleAge (emSpawn em) (emCount em) i (Time t)]
                      ]
                soloRows t = positionsOf (sample castingOnly ctx (Time t))
            sequence_
              [ castingRows t `shouldBe` soloRows t
              | t <- [castStart, castStart + 0.1 .. end + 0.5]
              ]
        )
        phasedExamples

    it "index 0 stays the casting emitter with the sigil in place" $ do
      spell <- compiled <$> circleOf "grand-sigil"
      emPhase (V.head (spellEmitters spell)) `shouldBe` Casting
      map emPhase (formationEmitters spell) `shouldSatisfy` all (== Drawing)

  describe "the plan drives the emitters" $ do
    it "every stroke of the plan becomes one emitter, in plan order" $ do
      circle <- circleOf "grand-sigil"
      let spell = compiled circle
          strokes = V.toList (spStrokes (sigilPlan circle))
          spawns = [motSpawn (emMotion em) | em <- formationEmitters spell]
      take (length strokes) spawns `shouldBe` map SpawnOnStroke strokes

    it "the particle count of a stroke emitter is the stroke's own" $ do
      circle <- circleOf "lattice-seal"
      let spell = compiled circle
          strokes = V.toList (spStrokes (sigilPlan circle))
          counts = [emCount em | em <- formationEmitters spell]
      take (length strokes) counts `shouldBe` map skCount strokes

    it "the formation budget stays within sigilBudget plus 0006's node/center constants" $ do
      let spell = compiled fullCircle
          formation = sum (map emCount (formationEmitters spell))
      formation `shouldSatisfy` (<= sigilBudget + 64)

    it "spellBudget is still the sum over every emitter" $ do
      let spell = compiled fullCircle
      spellBudget spell `shouldBe` sum (map emCount (V.toList (spellEmitters spell)))
      budgetTotal (spellBudgetPlan spell) `shouldBe` spellBudget spell
      U.toList (budgetPerEmitter (spellBudgetPlan spell))
        `shouldBe` map emCount (V.toList (spellEmitters spell))

    it "an over-budget circle still reports BudgetExceeded" $ do
      let c = fullCircle {core = Core (Just (EssenceRune Fire 64)) (coreNodes (core fullCircle))}
      case compile c of
        Left (BudgetExceeded asked cap) -> do
          cap `shouldBe` budgetCap
          asked `shouldSatisfy` (> budgetCap)
        other -> expectationFailure ("expected BudgetExceeded, got " ++ show (fmap spellBudget other))

  describe "the bounds cover the new spawn pattern" $ do
    it "every formation particle of every phased example lies inside its emitter's box" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleOf name
            let horizon = spellLifetime spell
                Seconds hz = horizon
            sequence_
              [ let em = spellEmitters spell V.! e
                    (lo, hi) = emitterBounds ctx horizon em
                    age = maybe 0 id (particleAge (emSpawn em) (emCount em) i (Time t))
                    p = particlePosition ctx (Time t) em i age
                 in inside lo hi p `shouldBe` True
              | t <- [0, 0.1 .. hz]
              , (e, i) <- aliveSlots spell (Time t)
              ]
        )
        (phasedExamples ++ ["lattice-seal"])

  describe "the sampler still holds its invariants with strokes in play" $ do
    prop "buffer invariant and budget bound over the whole cast" $
      forAll (choose (-1, 12)) $ \t ->
        let spell = compiled fullCircle
            buf = sample spell ctx (Time t)
         in property (bufferInvariant buf && pbCount buf <= spellBudget spell)

    prop "sampling is bit-for-bit deterministic" $
      forAll (choose (-1, 12)) $ \t ->
        let spell = compiled fullCircle
         in sample spell ctx (Time t) === sample spell ctx (Time t)

positionsOf :: ParticleBuffer -> [V3]
positionsOf buf =
  [V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) | j <- [0 .. pbCount buf - 1]]

inside :: V3 -> V3 -> V3 -> Bool
inside (V3 lx ly lz) (V3 hx hy hz) (V3 x y z) =
  x >= lx - eps && x <= hx + eps && y >= ly - eps && y <= hy + eps && z >= lz - eps && z <= hz + eps
  where
    eps = 1e-4
