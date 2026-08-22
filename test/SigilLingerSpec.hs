-- | T3 (func-spec 0026): @linger@ — the sigil's end, shifted.
--
-- Three claims, and the third is the one worth the file:
--
--   * positive shifts push the closing landmark out, and 'isFinished'
--     follows it, so a host is never told a spell is over while its
--     sigil is still on screen;
--   * negative shifts pull the sigil in without touching the spell body
--     — the three earlier landmarks do not move, so a sigil that leaves
--     early does not make the cast start early;
--   * however negative the value, the sigil is drawn to completion. That
--     floor lives in the compiler rather than the codec, so it holds for
--     a circle built in Haskell as well as one loaded from a file.
--
-- The sigil's end is read off the formation emitters' envelope rather
-- than asserted about directly: @envDuration = sigilEnd - formLife@ is
-- where the number actually lands, and reading it there means the test
-- would notice if the value were computed correctly and then wired to
-- nothing.
module SigilLingerSpec (spec) where

import qualified Data.Vector as V
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), SigilTiming (..), emptyCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Phase (..)
  , PhasePlan (..)
  , compile
  )
import Magic.Interface
  ( CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , advanceSpell
  , castSpell
  , isFinished
  )
import Magic.Rune (Element (..), EssenceRune (..), NodeRune (..))
import Magic.Types (CastContext (..), Seconds (..), Seed (..), V3 (..))
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

-- | Phases plus a node, so there are ring strokes /and/ node emitters to
-- check, and a short spell body so the landmarks are easy to read.
base :: Circle
base =
  emptyCircle
    { circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))
    , core =
        Core
          (Just (EssenceRune Fire 1.0))
          (Nodes (Just (DirBias 0.2)) Nothing Nothing Nothing)
    }

withLinger :: Double -> Circle -> Circle
withLinger linger c = c {circleSigil = Just (SigilTiming (Seconds linger) False)}

compiled :: Circle -> CompiledSpell
compiled = either (error . show) id . compile

plan :: Circle -> PhasePlan
plan = spellPhases . compiled

-- | The moment the last formation particle dies, recovered from the
-- envelope the compiler handed the sigil's emitters.
sigilEndOf :: CompiledSpell -> Double
sigilEndOf spell = case formationEnvelopes spell of
  [] -> error "no formation emitters"
  envs ->
    let ends = [d + l | Envelope _ (Seconds d) (Seconds l) <- envs]
     in maximum ends

formationEnvelopes :: CompiledSpell -> [Envelope]
formationEnvelopes spell =
  [emSpawn em | em <- V.toList (spellEmitters spell), emPhase em /= Casting]

-- | @formLife@, the compiler's own expression, re-derived here so the
-- expected envelope duration is stated rather than copied out of the
-- implementation.
formLifeOf :: Circle -> Double
formLifeOf c = case circlePhases c of
  Nothing -> 0
  Just (PhaseConfig (Seconds d) (Seconds v)) -> min 0.6 ((d + v) / 2)

secondsOf :: Seconds -> Double
secondsOf (Seconds s) = s

-- | Walk to a wall-clock instant at the demo's step size.
finishedAt :: Circle -> Double -> Bool
finishedAt c t =
  let spell = either (error . show) id (castSpell (CastRequest c ctx))
      steps = round (t / dt) :: Int
      dt = 1 / 60
   in isFinished (foldl (\s _ -> advanceSpell (FrameInput (DeltaTime dt)) s) spell [1 .. steps])

spec :: Spec
spec = describe "linger, the sigil's end (func-spec 0026 T3)" $ do
  describe "zero is the pre-0026 path, by construction" $ do
    it "leaves every landmark exactly where no sigil key leaves them" $
      plan (withLinger 0 base) `shouldBe` plan base

    it "and the whole compiled spell with it" $
      compiled (withLinger 0 base) `shouldBe` compiled base

  describe "a positive linger" $ do
    let lingered = withLinger 2.5 base
        spellEnd = secondsOf (ppEnd (plan base))

    it "pushes the closing landmark out by exactly that much" $
      secondsOf (ppEnd (plan lingered)) `shouldBe` spellEnd + 2.5

    it "and spellLifetime follows it, as the PhasePlan invariant requires" $
      spellLifetime (compiled lingered) `shouldBe` ppEnd (plan lingered)

    it "keeps the three earlier landmarks where they were: the cast is not delayed" $ do
      ppDrawEnd (plan lingered) `shouldBe` ppDrawEnd (plan base)
      ppConvergeEnd (plan lingered) `shouldBe` ppConvergeEnd (plan base)
      ppCastingEnd (plan lingered) `shouldBe` ppCastingEnd (plan base)

    it "and the sigil really does live that long" $
      sigilEndOf (compiled lingered) `shouldBe` spellEnd + 2.5

    it "so isFinished is still false while the sigil is on screen" $ do
      finishedAt lingered (spellEnd + 1.0) `shouldBe` False
      finishedAt base (spellEnd + 1.0) `shouldBe` True

    it "and true once it has gone" $
      finishedAt lingered (spellEnd + 3.0) `shouldBe` True

  describe "a negative linger" $ do
    let early = withLinger (-1.0) base
        spellEnd = secondsOf (ppEnd (plan base))

    it "closes the sigil's spawn window early" $
      sigilEndOf (compiled early) `shouldBe` spellEnd - 1.0

    it "which is the envelope's duration, shifted, and nothing else" $ do
      let expected = spellEnd - 1.0 - formLifeOf base
      [d | Envelope _ (Seconds d) _ <- formationEnvelopes (compiled early)]
        `shouldSatisfy` all (== expected)
      [l | Envelope _ _ (Seconds l) <- formationEnvelopes (compiled early)]
        `shouldSatisfy` all (== formLifeOf base)

    it "leaves the spell body alone: every landmark is where it was" $
      -- ppEnd takes the max of the two ends, so the spell outliving its
      -- sigil is the spell's own end, unchanged.
      plan early `shouldBe` plan base

    it "and leaves the casting emitters bit-for-bit identical" $
      [em | em <- V.toList (spellEmitters (compiled early)), emPhase em == Casting]
        `shouldBe` [em | em <- V.toList (spellEmitters (compiled base)), emPhase em == Casting]

  describe "the floor: the sigil is always drawn to completion" $ do
    it "clamps an absurdly negative linger to the end of the drawing phase" $
      sigilEndOf (compiled (withLinger (-60) base)) `shouldBe` 1.2

    it "at the cap the codec allows, and past anything a file could carry" $
      -- The compiler's floor does not depend on the codec's range check:
      -- a circle built in Haskell gets the same guarantee.
      sigilEndOf (compiled (withLinger (-1e9) base)) `shouldBe` 1.2

    it "so the drawing landmark is never past the sigil's end" $
      secondsOf (ppDrawEnd (plan (withLinger (-60) base)))
        `shouldSatisfy` (<= sigilEndOf (compiled (withLinger (-60) base)))

  describe "no phases, no sigil to time" $ do
    let unphased = emptyCircle {core = core base}

    it "any linger compiles to exactly the spell without one" $ do
      compiled (withLinger 5 unphased) `shouldBe` compiled unphased
      compiled (withLinger (-5) unphased) `shouldBe` compiled unphased

    it "and does not error" $
      compile (withLinger 5 unphased) `shouldSatisfy` isRight

    it "because there are no formation emitters for it to reach" $
      formationEnvelopes (compiled (withLinger 5 unphased)) `shouldBe` []
  where
    isRight = either (const False) (const True)
