-- | T-S5 (func-spec 0002 §8): fold steps 1–2 — core essence to seed
-- (element table, power scaling, node drift) and inner-ring behavior with
-- the same-kind override rule.
module CompileCoreSpec (spec) where

import qualified Data.Vector as V
import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( Appearance (..)
  , BillboardShape (..)
  , BlendMode (..)
  , ColorRamp (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , SpawnPattern (..)
  , budgetCap
  , compile
  , elementAppearance
  )
import Magic.Rune
  ( Element (..)
  , EssenceRune (..)
  , InnerRune (..)
  , NodeRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..), V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Compile and pull out the single emitter this round's fold produces.
theEmitter :: Circle -> EmitterSpec
theEmitter c = case compile c of
  Right spell | V.length (spellEmitters spell) == 1 -> V.head (spellEmitters spell)
  other -> error ("expected exactly one emitter, got: " ++ show other)

withCore :: Core -> Circle
withCore c = emptyCircle {core = c}

noNodes :: Nodes (Maybe NodeRune)
noNodes = Nodes Nothing Nothing Nothing Nothing

spec :: Spec
spec = describe "compile fold steps 1-2 (spec 0002 S5)" $ do
  it "an empty core yields the Neutral plain-discharge defaults (§4.5 table)" $ do
    let em = theEmitter emptyCircle
    emCount em `shouldBe` 256
    emSpawn em
      `shouldBe` Envelope
        { envDelay = Seconds 0
        , envDuration = Seconds 8
        , envLifetime = Seconds 2
        }
    motTraject (emMotion em) `shouldBe` Forward 4.0
    motSpawn (emMotion em) `shouldBe` SpawnAtAnchor 1.6
    motRadiation (emMotion em) `shouldBe` AlongNormal
    motDrift (emMotion em) `shouldBe` V3 0 0 0
    emAppearance em
      `shouldBe` Appearance
        { appColor = ColorRamp 0xFFFFFFFF 0xFFFFFFFF
        , appSize = 0.05
        , appBlend = BlendAlpha
        , appAmplify = Nothing
        , appShape = BillboardSquare
        }

  it "each element looks up its own appearance; Neutral is 0001's white" $ do
    elementAppearance Neutral
      `shouldBe` Appearance (ColorRamp 0xFFFFFFFF 0xFFFFFFFF) 0.05 BlendAlpha Nothing BillboardSquare
    let looks = map elementAppearance [Neutral, Fire, Water, Lightning]
    -- All four table rows are distinct, and the essence reaches the emitter.
    length looks `shouldBe` 4
    [appColor a | a <- looks] `shouldSatisfy` allDistinct
    let fireCircle = withCore (Core (Just (EssenceRune Fire 1.0)) noNodes)
    emAppearance (theEmitter fireCircle) `shouldBe` elementAppearance Fire

  prop "emCount == round (power × 256), clamped below at 1" $
    forAll (choose (0.001, 16)) $ \power ->
      let c = withCore (Core (Just (EssenceRune Neutral power)) noNodes)
          expected = max 1 (round (power * 256)) :: Int
       in expected <= budgetCap ==> emCount (theEmitter c) === expected

  it "the four node biases sum into motDrift (north=+y, east=+x)" $ do
    let nodes =
          Nodes
            { north = Just (DirBias 1.0)
            , south = Just (DirBias 0.25)
            , east = Just (DirBias 0.5)
            , west = Nothing
            }
        c = withCore (Core Nothing nodes)
    -- north 1.0 - south 0.25 = +0.75 face-up; east 0.5 face-right.
    motDrift (emMotion (theEmitter c)) `shouldBe` V3 0.5 0.75 0

  it "same-kind inner runes: the outer layer (ringB) overrides the inner" $ do
    let c =
          emptyCircle
            { innerRings =
                TwoOf
                  (Just (TrajectoryRune (Forward 1)))
                  (Just (TrajectoryRune (Orbit 2 3)))
            }
    motTraject (emMotion (theEmitter c)) `shouldBe` Orbit 2 3

  it "different-kind inner runes do not interfere" $ do
    let timing = Envelope (Seconds 1) (Seconds 2) (Seconds 3)
        c =
          emptyCircle
            { innerRings =
                TwoOf
                  (Just (TrajectoryRune (Spiral 1 2 3)))
                  (Just (TimingRune timing))
            }
        em = theEmitter c
    motTraject (emMotion em) `shouldBe` Spiral 1 2 3
    emSpawn em `shouldBe` timing

allDistinct :: (Eq a) => [a] -> Bool
allDistinct xs = and [x /= y | (i, x) <- zip [0 :: Int ..] xs, (j, y) <- zip [0 ..] xs, i < j]
