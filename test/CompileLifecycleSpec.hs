-- | S3 (func-spec 0006 §8): fold step 3.5 (casting envelope delayed by
-- castStart) and 'PhasePlan' assembly — the compatibility law's
-- implementation core, plus the L1/L2 shift laws (§4.3) and the
-- @spellLifetime == ppEnd@ invariant.
module CompileLifecycleSpec (spec) where

import qualified Data.Vector as V
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Phase (..)
  , PhasePlan (..)
  , compile
  )
import Magic.Rune (BridgeRune (..), Element (..), EssenceRune (..), InnerRune (..))
import Magic.Types (Seconds (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- Circle construction ----------------------------------------------------

data Setup = Setup
  { stTiming :: Maybe Envelope
  , stShift :: Maybe Seconds
  , stPhases :: Maybe PhaseConfig
  , stPower :: Double
  }
  deriving (Show)

genEnvelope :: Gen Envelope
genEnvelope = do
  delay <- choose (0, 5)
  duration <- choose (0, 10)
  lifetime <- choose (0.1, 5)
  pure (Envelope (Seconds delay) (Seconds duration) (Seconds lifetime))

genPhaseConfig :: Gen PhaseConfig
genPhaseConfig =
  PhaseConfig
    <$> (Seconds <$> choose (0.05, 5))
    <*> (Seconds <$> choose (0, 5))

genMaybe :: Gen a -> Gen (Maybe a)
genMaybe g = oneof [pure Nothing, Just <$> g]

genSetup :: Gen Setup
genSetup =
  Setup
    <$> genMaybe genEnvelope
    <*> genMaybe (Seconds <$> choose (0, 5))
    <*> genMaybe genPhaseConfig
    <*> choose (0.05, 5)

instance Arbitrary Setup where
  arbitrary = genSetup

buildCircle :: Setup -> Circle
buildCircle st =
  emptyCircle
    { innerRings = TwoOf (TimingRune <$> stTiming st) Nothing
    , interLayer = PhaseRune <$> stShift st
    , core = Core (Just (EssenceRune Neutral (stPower st))) (Nodes Nothing Nothing Nothing Nothing)
    , circlePhases = stPhases st
    }

compiled :: Circle -> CompiledSpell
compiled c = either (error . show) id (compile c)

castingOf :: CompiledSpell -> EmitterSpec
castingOf spell = V.head (spellEmitters spell)

spec :: Spec
spec = describe "compile step 3.5 / PhasePlan assembly (spec 0006 S3)" $ do
  prop "circlePhases = Nothing compiles to exactly one emitter with a degenerate PhasePlan" $
    \st ->
      let c = buildCircle st {stPhases = Nothing}
          spell = compiled c
          plan = spellPhases spell
          em = castingOf spell
          Seconds delay = envDelay (emSpawn em)
          Seconds duration = envDuration (emSpawn em)
          Seconds lifetime = envLifetime (emSpawn em)
       in V.length (spellEmitters spell) === 1
            .&&. ppDrawEnd plan === Seconds 0
            .&&. ppConvergeEnd plan === Seconds 0
            .&&. ppCastingEnd plan === Seconds (delay + duration)
            .&&. ppEnd plan === Seconds (delay + duration + lifetime)

  prop "spellLifetime == ppEnd of spellPhases, always" $
    \st ->
      let spell = compiled (buildCircle st)
       in spellLifetime spell === ppEnd (spellPhases spell)

  prop "L1: with phases, the casting emitter differs from the phases-less bake only in envDelay" $
    \st -> forAll genPhaseConfig $ \pc ->
      let base = castingOf (compiled (buildCircle st {stPhases = Nothing}))
          shifted = castingOf (compiled (buildCircle st {stPhases = Just pc}))
          Seconds d0 = envDelay (emSpawn base)
          Seconds castStart = phasesCastStart pc
       in envDelay (emSpawn shifted) === Seconds (d0 + castStart)
            .&&. envDuration (emSpawn shifted) === envDuration (emSpawn base)
            .&&. envLifetime (emSpawn shifted) === envLifetime (emSpawn base)
            .&&. emMotion shifted === emMotion base
            .&&. emAppearance shifted === emAppearance base
            .&&. emCount shifted === emCount base

  prop "L2: PhaseRune shift and phases compose additively (order-independent)" $
    \st -> forAll (choose (0, 5)) $ \shiftD -> forAll genPhaseConfig $ \pc ->
      let withBoth =
            castingOf . compiled $
              (buildCircle st {stShift = Nothing, stPhases = Nothing})
                { interLayer = Just (PhaseRune (Seconds shiftD))
                , circlePhases = Just pc
                }
          baseline = castingOf (compiled (buildCircle st {stShift = Nothing, stPhases = Nothing}))
          Seconds d0 = envDelay (emSpawn baseline)
          Seconds castStart = phasesCastStart pc
       in envDelay (emSpawn withBoth) === Seconds (d0 + shiftD + castStart)

  prop "emPhase: index 0 is always Casting; every other emitter (formation) is Drawing" $
    \st ->
      let spell = compiled (buildCircle st)
          ems = V.toList (spellEmitters spell)
       in case ems of
            (first : rest) -> emPhase first === Casting .&&. property (all ((== Drawing) . emPhase) rest)
            [] -> counterexample "spellEmitters must never be empty" False

phasesCastStart :: PhaseConfig -> Seconds
phasesCastStart pc =
  let Seconds d = phDraw pc
      Seconds c = phConverge pc
   in Seconds (d + c)
