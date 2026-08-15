-- | T-S6 (func-spec 0002 §8): fold steps 3–4 — interlayer modulation,
-- outer-ring presentation, budget arithmetic and the compile error.
module CompileFoldSpec (spec) where

import qualified Data.Vector as V
import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( CompileError (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , SpawnPattern (..)
  , budgetCap
  , compile
  )
import Magic.Rune
  ( BridgeRune (..)
  , EssenceRune (..)
  , Element (..)
  , FaceShape (..)
  , InnerRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  )
import Magic.Types (Seconds (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

theEmitter :: Circle -> EmitterSpec
theEmitter c = case compile c of
  Right spell | V.length (spellEmitters spell) == 1 -> V.head (spellEmitters spell)
  other -> error ("expected exactly one emitter, got: " ++ show other)

spec :: Spec
spec = describe "compile fold steps 3-4 (spec 0002 S6)" $ do
  it "PhaseRune shifts envDelay by exactly its amount, all else untouched" $ do
    let base = theEmitter emptyCircle
        shifted = theEmitter emptyCircle {interLayer = Just (PhaseRune (Seconds 0.5))}
    envDelay (emSpawn shifted) `shouldBe` Seconds 0.5
    envDuration (emSpawn shifted) `shouldBe` envDuration (emSpawn base)
    envLifetime (emSpawn shifted) `shouldBe` envLifetime (emSpawn base)
    emMotion shifted `shouldBe` emMotion base
    emAppearance shifted `shouldBe` emAppearance base
    emCount shifted `shouldBe` emCount base

  it "PhaseRune shifts an inner-ring timing, not just the default" $ do
    let timing = Envelope (Seconds 1) (Seconds 4) (Seconds 2)
        c =
          emptyCircle
            { innerRings = TwoOf (Just (TimingRune timing)) Nothing
            , interLayer = Just (PhaseRune (Seconds 0.25))
            }
    envDelay (emSpawn (theEmitter c)) `shouldBe` Seconds 1.25

  it "ShapeRune switches the spawn pattern to SpawnOnShape" $ do
    let c =
          emptyCircle
            { outerRings = TwoOf (Just (ShapeRune (Ring 1 2))) Nothing
            }
    motSpawn (emMotion (theEmitter c)) `shouldBe` SpawnOnShape (Ring 1 2)

  it "RadiateRune overrides the default radiation mode" $ do
    let c =
          emptyCircle
            { outerRings = TwoOf Nothing (Just (RadiateRune RadialOutward))
            }
    motRadiation (emMotion (theEmitter c)) `shouldBe` RadialOutward

  it "same-kind outer runes: ringB wins; different kinds compose" $ do
    let c =
          emptyCircle
            { outerRings =
                TwoOf
                  (Just (ShapeRune (Diamond 1)))
                  (Just (ShapeRune (Ring 1 2)))
            }
    motSpawn (emMotion (theEmitter c)) `shouldBe` SpawnOnShape (Ring 1 2)
    let c2 =
          emptyCircle
            { outerRings =
                TwoOf
                  (Just (ShapeRune (Diamond 1)))
                  (Just (RadiateRune RadialOutward))
            }
        m = emMotion (theEmitter c2)
    motSpawn m `shouldBe` SpawnOnShape (Diamond 1)
    motRadiation m `shouldBe` RadialOutward

  prop "spellBudget == emCount of the single emitter" $
    forAll (choose (0.01, 15)) $ \power ->
      let c = essenceCircle power
       in case compile c of
            Right spell ->
              spellBudget spell === emCount (V.head (spellEmitters spell))
            Left err -> counterexample (show err) False

  it "power beyond the cap compiles to Left (BudgetExceeded requested cap)" $ do
    -- power 80 → 20480, past the 16384 cap func-spec 0012 S1 set.
    compile (essenceCircle 80) `shouldBe` Left (BudgetExceeded 20480 budgetCap)

  it "spellLifetime == envDelay + envDuration + envLifetime" $ do
    let timing = Envelope (Seconds 0.5) (Seconds 3) (Seconds 1.5)
        c =
          emptyCircle
            { innerRings = TwoOf (Just (TimingRune timing)) Nothing
            , interLayer = Just (PhaseRune (Seconds 0.5))
            }
    case compile c of
      Right spell -> spellLifetime spell `shouldBe` Seconds (1 + 3 + 1.5)
      Left err -> expectationFailure (show err)

  it "the empty circle's lifetime is the 0001 formula: 0 + 8 + 2 = 10s" $
    case compile emptyCircle of
      Right spell -> spellLifetime spell `shouldBe` Seconds 10
      Left err -> expectationFailure (show err)

essenceCircle :: Double -> Circle
essenceCircle power =
  emptyCircle
    { core =
        Core
          (Just (EssenceRune Neutral power))
          (Nodes Nothing Nothing Nothing Nothing)
    }
