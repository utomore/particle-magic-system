-- | S1 (func-spec 0017 §7): the formation envelope, re-derived.
--
-- The whole round is two numbers and one @Maybe@, so this module is where
-- the semantics actually lives:
--
--   * the sigil's /pace/ is untouched — @envDelay@ and @envLifetime@ keep
--     spec 0006's formulas exactly, which is what makes the Drawing
--     window bit-for-bit what it was ('firstBirth' reads those two and
--     never @envDuration@);
--   * the sigil's /span/ now reaches @ppEnd@: the last batch dies exactly
--     when the spell does;
--   * formation carries no convergence curve any more, so it holds the
--     position it was drawn at instead of collapsing onto the axis.
--
-- Also pinned: the four 'PhasePlan' landmarks do not move. This round
-- changes how long the sigil lives, not when any phase begins or ends.
module PersistEnvelopeSpec (spec) where

import qualified Data.Vector as V
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , Phase (..)
  , PhasePlan (..)
  , compile
  )
import Magic.Rune (Element (..), EssenceRune (..), InnerRune (..), NodeRune (..), Trajectory (..))
import Magic.Types (Seconds (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

compiled :: Circle -> CompiledSpell
compiled = either (error . show) id . compile

phasedCircle :: PhaseConfig -> Circle
phasedCircle pc = emptyCircle {circlePhases = Just pc}

-- | Occupied slots on both sides of the plan, so the emitter list holds
-- strokes, node emitters and the centre emitter at once.
loadedCircle :: PhaseConfig -> Circle
loadedCircle pc =
  (phasedCircle pc)
    { innerRings = TwoOf (Just (TrajectoryRune (Forward 1))) Nothing
    , core =
        Core
          (Just (EssenceRune Fire 1.0))
          (Nodes (Just (DirBias 0.1)) Nothing (Just (DirBias 0.1)) Nothing)
    }

formationOf :: CompiledSpell -> [EmitterSpec]
formationOf spell = [em | em <- V.toList (spellEmitters spell), emPhase em /= Casting]

-- | The first formation emitter (the boundary ring) — every formation
-- emitter shares one envelope, asserted separately below.
boundaryOf :: CompiledSpell -> EmitterSpec
boundaryOf spell = case formationOf spell of
  (em : _) -> em
  [] -> error "expected formation emitters"

genPhaseConfig :: Gen PhaseConfig
genPhaseConfig =
  PhaseConfig
    <$> (Seconds <$> choose (0.3, 3))
    <*> (Seconds <$> choose (0, 2))

-- | Spec 0006's formula, restated here so a change to it has to be
-- deliberate: the drawing pace is what this round promises not to touch.
expectedFormLife :: Double -> Double
expectedFormLife castStart = min 0.6 (castStart / 2)

spec :: Spec
spec = describe "formation envelope: pace kept, span extended (func-spec 0017 S1)" $ do
  describe "the drawing pace is spec 0006's, unchanged" $ do
    prop "envDelay is 0 and envLifetime is min 0.6 (castStart/2)" $
      forAll genPhaseConfig $ \pc@(PhaseConfig (Seconds d) (Seconds c)) ->
        let env = emSpawn (boundaryOf (compiled (phasedCircle pc)))
         in envDelay env === Seconds 0
              .&&. envLifetime env === Seconds (expectedFormLife (d + c))

    it "a long prelude still caps the lifetime at 0.6s" $ do
      let env = emSpawn (boundaryOf (compiled (phasedCircle (PhaseConfig (Seconds 3) (Seconds 1)))))
      envLifetime env `shouldBe` Seconds 0.6

  describe "the span now reaches the end of the spell" $ do
    prop "the last batch dies exactly at ppEnd" $
      forAll genPhaseConfig $ \pc ->
        let spell = compiled (phasedCircle pc)
            env = emSpawn (boundaryOf spell)
            Seconds dur = envDuration env
            Seconds life = envLifetime env
            Seconds end = ppEnd (spellPhases spell)
         in counterexample (show (dur, life, end)) (abs (dur + life - end) < 1e-9)

    prop "every index is still born: the stagger span fits inside the window" $
      forAll genPhaseConfig $ \pc ->
        let env = emSpawn (boundaryOf (compiled (phasedCircle pc)))
         in envLifetime env <= envDuration env

    it "the window really is longer than the prelude (this is the change)" $ do
      let pc = PhaseConfig (Seconds 1.2) (Seconds 0.6) -- castStart 1.8
          spell = compiled (phasedCircle pc)
          env = emSpawn (boundaryOf spell)
          Seconds dur = envDuration env
      -- Pre-0017 this was castStart - formLife = 1.2; now it runs to ppEnd.
      dur `shouldSatisfy` (> 1.8)

    prop "every formation emitter shares the one envelope (strokes, nodes and centre alike)" $
      forAll genPhaseConfig $ \pc ->
        let envs = map emSpawn (formationOf (compiled (loadedCircle pc)))
         in case envs of
              [] -> property False
              (e : rest) -> length envs > 3 .&&. property (all (== e) rest)

  describe "formation no longer converges" $ do
    prop "no formation emitter carries a convergence curve" $
      forAll genPhaseConfig $ \pc ->
        let spell = compiled (phasedCircle pc)
         in property (all (\em -> motConverge (emMotion em) == Nothing) (formationOf spell))

    it "holds even when phConverge > 0 (where the curve used to be synthesized)" $ do
      let spell = compiled (phasedCircle (PhaseConfig (Seconds 1.0) (Seconds 0.5)))
      map (motConverge . emMotion) (formationOf spell)
        `shouldSatisfy` all (== Nothing)

    it "the casting emitter's own modulation is untouched" $ do
      let spell = compiled (phasedCircle (PhaseConfig (Seconds 1.0) (Seconds 0.5)))
      motConverge (emMotion (V.head (spellEmitters spell))) `shouldBe` Nothing

  describe "the phase landmarks do not move" $ do
    prop "ppDrawEnd = phDraw and ppConvergeEnd = phDraw + phConverge" $
      forAll genPhaseConfig $ \pc@(PhaseConfig (Seconds d) (Seconds c)) ->
        let plan = spellPhases (compiled (phasedCircle pc))
         in ppDrawEnd plan === Seconds d .&&. ppConvergeEnd plan === Seconds (d + c)

    prop "ppEnd is still spellLifetime" $
      forAll genPhaseConfig $ \pc ->
        let spell = compiled (phasedCircle pc)
         in ppEnd (spellPhases spell) === spellLifetime spell

    it "phConverge = 0 remains a legal, curve-free configuration" $ do
      let spell = compiled (phasedCircle (PhaseConfig (Seconds 1.0) (Seconds 0)))
          plan = spellPhases spell
      ppConvergeEnd plan `shouldBe` Seconds 1.0
      map (motConverge . emMotion) (formationOf spell) `shouldSatisfy` all (== Nothing)

  describe "the budget is untouched by this round" $
    prop "spellBudget is the same sum it always was" $
      forAll genPhaseConfig $ \pc ->
        let spell = compiled (phasedCircle pc)
         in spellBudget spell === sum (map emCount (V.toList (spellEmitters spell)))
