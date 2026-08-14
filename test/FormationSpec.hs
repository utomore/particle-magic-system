-- | S4 (func-spec 0006 §8): fold step 5 — Circle geometry → formation
-- emitters (§4.4's export table), the formEnv/kcExpr derivation chain,
-- the total-budget Σ check, and index-0/spellBlend invariance.
module FormationSpec (spec) where

import Data.Bits ((.&.))
import qualified Data.Vector as V
import Magic.Circle
  ( Circle (..)
  , Core (..)
  , Nodes (..)
  , PhaseConfig (..)
  , TwoOf (..)
  , emptyCircle
  )
import Magic.Compile
  ( Appearance (..)
  , Anchor (..)
  , BlendMode (..)
  , ColorRamp (..)
  , CompileError (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , Phase (..)
  , SpawnPattern (..)
  , budgetCap
  , compile
  , spellBlend
  )
import Magic.Expr (ExprEnv (..), evalFinite)
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , EssenceRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..), Seed (..), V3 (..))
import Test.Hspec

envAt :: Float -> ExprEnv
envAt t = ExprEnv {envT = t, envLife = 0, envPIndex = 0, envSeed = Seed 0}

compiled :: Circle -> CompiledSpell
compiled c = either (error . show) id (compile c)

-- | A circle occupying every optional slot except the essence element,
-- which is left to the caller; the outer runes are deliberately
-- non-'ShapeRune' so the nominal ring bands are exercised (the shape
-- exception is its own test below).
fullCircle :: Element -> Double -> Circle
fullCircle element power =
  Circle
    { outerRings =
        TwoOf (Just (RadiateRune AlongNormal)) (Just (RadiateRune RadialOutward))
    , interLayer = Just (PhaseRune (Seconds 0))
    , innerRings =
        TwoOf (Just (TrajectoryRune (Forward 1))) (Just (TrajectoryRune (Forward 2)))
    , core =
        Core
          { coreCenter = Just (EssenceRune element power)
          , coreNodes =
              Nodes
                (Just (DirBias 0.1))
                (Just (DirBias 0.1))
                (Just (DirBias 0.1))
                (Just (DirBias 0.1))
          }
    , circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))
    }

bareCircle :: Circle
bareCircle = emptyCircle {circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))}

-- | Only the inner-A ring and the north node are occupied: proves the
-- emitter list tracks occupancy per slot, not all-or-nothing.
mixedCircle :: Circle
mixedCircle =
  emptyCircle
    { innerRings = TwoOf (Just (TrajectoryRune (Forward 1))) Nothing
    , core = Core Nothing (Nodes (Just (DirBias 0.2)) Nothing Nothing Nothing)
    , circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))
    }

spec :: Spec
spec = describe "compile step 5: formation geometry emitters (spec 0006 S4)" $ do
  it "bijection: fully-occupied circle produces the whole export table, in order, boundary always first" $ do
    let spell = compiled (fullCircle Neutral 1.0)
        counts = map emCount (V.toList (spellEmitters spell))
    -- casting, boundary, outerB, outerA, bridge, innerB, innerA, N, S, E, W, center
    counts `shouldBe` [256, 96, 64, 64, 64, 64, 64, 12, 12, 12, 12, 16]
    sum (drop 1 counts) `shouldBe` 480

  it "the all-empty circle with phases still draws the boundary ring (§4.4 judgment call)" $ do
    let spell = compiled bareCircle
        counts = map emCount (V.toList (spellEmitters spell))
    counts `shouldBe` [256, 96]

  it "occupancy tracks individual slots: only inner-A and north appear (plus the boundary)" $ do
    let spell = compiled mixedCircle
        counts = map emCount (V.toList (spellEmitters spell))
    counts `shouldBe` [256, 96, 64, 12]

  it "circlePhases = Nothing produces no formation emitters at all" $
    length (spellEmitters (compiled emptyCircle)) `shouldBe` 1

  it "the outer-ring ShapeRune exception previews the player's shape instead of the nominal band" $ do
    let shape = Diamond 2
        c = emptyCircle {outerRings = TwoOf Nothing (Just (ShapeRune shape)), circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))}
        spell = compiled c
        formation = V.toList (spellEmitters spell) !! 2 -- 0=casting, 1=boundary, 2=outer-B
    motSpawn (emMotion formation) `shouldBe` SpawnOnShape shape

  it "a non-ShapeRune outer occupant uses the nominal band, not the played shape" $ do
    let c = emptyCircle {outerRings = TwoOf Nothing (Just (RadiateRune RadialOutward)), circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))}
        spell = compiled c
        formation = V.toList (spellEmitters spell) !! 2 -- 0=casting, 1=boundary, 2=outer-B
    motSpawn (emMotion formation) `shouldBe` SpawnOnShape (Ring 1.25 1.35)

  it "formEnv derivation chain: castStart 1.5s (draw 1.0 + converge 0.5) caps formLife at 0.6s" $ do
    let spell = compiled mixedCircle
        formation = V.toList (spellEmitters spell) !! 2 -- inner-A ring
        env = emSpawn formation
    envDelay env `shouldBe` Seconds 0
    envDuration env `shouldBe` Seconds 0.9
    envLifetime env `shouldBe` Seconds 0.6
    -- derivation chain step 2: the last batch dies exactly at castStart.
    let Seconds dur = envDuration env
        Seconds life = envLifetime env
    (dur + life) `shouldBe` 1.5

  it "formEnv caps formLife at 0.6s even for a long prelude (castStart 4s)" $ do
    let c = emptyCircle {core = Core Nothing (Nodes (Just (DirBias 0.1)) Nothing Nothing Nothing), circlePhases = Just (PhaseConfig (Seconds 3.0) (Seconds 1.0))}
        spell = compiled c
        formation = V.toList (spellEmitters spell) !! 1
        env = emSpawn formation
    envLifetime env `shouldBe` Seconds 0.6
    envDuration env `shouldBe` Seconds 3.4

  it "kcExpr evaluates to 1 at t=0, 1 at t=phDraw, 0 at t=castStart" $ do
    let spell = compiled mixedCircle -- draw=1.0, converge=0.5, castStart=1.5
        formation = V.toList (spellEmitters spell) !! 2
        kc = case motConverge (emMotion formation) of
          Just e -> e
          Nothing -> error "expected a synthesized convergence curve"
        at t = evalFinite kc (envAt t)
    at 0 `shouldBe` 1
    at 1.0 `shouldBe` 1
    at 1.5 `shouldBe` 0

  it "phConverge = 0 synthesizes no convergence curve (Nothing, no divide-by-zero path)" $ do
    let c = emptyCircle {core = Core Nothing (Nodes (Just (DirBias 0.1)) Nothing Nothing Nothing), circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0))}
        spell = compiled c
        formation = V.toList (spellEmitters spell) !! 1
    motConverge (emMotion formation) `shouldBe` Nothing

  it "node anchorOffset coordinate table (face coordinates, §4.4)" $ do
    let c =
          emptyCircle
            { core =
                Core
                  Nothing
                  (Nodes (Just (DirBias 0.1)) (Just (DirBias 0.1)) (Just (DirBias 0.1)) (Just (DirBias 0.1)))
            , circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))
            }
        spell = compiled c
        nodeEmitters = drop 2 (V.toList (spellEmitters spell))
    map (anchorOffset . emAnchor) nodeEmitters
      `shouldBe` [V3 0 0.35 0, V3 0 (-0.35) 0, V3 0.35 0 0, V3 (-0.35) 0 0]
    map (anchorNormal . emAnchor) nodeEmitters `shouldBe` replicate 4 (V3 0 0 1)

  it "formation particles fade to the same RGB with alpha cleared, smaller and same blend" $ do
    let spell = compiled mixedCircle
        formation = V.toList (spellEmitters spell) !! 2
        Appearance (ColorRamp start end) size blend _ = emAppearance formation
    (start .&. 0x000000FF) `shouldBe` 0xFF -- Neutral start alpha untouched
    (end .&. 0xFFFFFF00) `shouldBe` (start .&. 0xFFFFFF00) -- same RGB
    (end .&. 0x000000FF) `shouldBe` 0 -- alpha cleared
    size `shouldBe` 0.03
    blend `shouldBe` BlendAlpha -- Neutral's own blend mode

  it "spellBudget = Sigma emCount across every emitter" $ do
    let spell = compiled (fullCircle Neutral 1.0)
    spellBudget spell `shouldBe` sum (map emCount (V.toList (spellEmitters spell)))

  it "the Sigma budget check fires BudgetExceeded when casting + formation exceeds the cap" $
    -- power 15 -> casting count 3840 (well under cap alone); + 480 formation = 4320 > 4096.
    compile (fullCircle Neutral 15) `shouldBe` Left (BudgetExceeded 4320 budgetCap)

  it "index 0 is always the casting emitter; spellBlend reads it regardless of formation emitters" $ do
    let spell = compiled (fullCircle Fire 1.0)
        first = V.head (spellEmitters spell)
    emPhase first `shouldBe` Casting
    spellBlend spell `shouldBe` BlendAdditive
