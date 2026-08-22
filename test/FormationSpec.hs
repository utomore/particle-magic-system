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
  , PhasePlan (..)
  , SpawnPattern (..)
  , budgetCap
  , compile
  , spellBlend
  )
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
import Magic.Sigil (SigilStroke (..), sigilPlan, spShapes, spStrokes)
import Magic.Types (Seconds (..), V3 (..))
import Test.Hspec

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
    , circleFields = []
    , circleAnchors = Nothing
    , circleSigil = Nothing
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
  it "slot-to-stroke-group correspondence: every occupied slot is represented, boundary first" $ do
    let circle = fullCircle Neutral 1.0
        spell = compiled circle
        plan = sigilPlan circle
        counts = map emCount (V.toList (spellEmitters spell))
        -- casting, then the plan's strokes, then N/S/E/W and the center.
        strokeCount = V.length (spStrokes plan)
    -- Five ring slots occupied -> boundary group (2) + one stroke each.
    strokeCount `shouldBe` 7
    take 1 counts `shouldBe` [256]
    take strokeCount (drop 1 counts)
      `shouldBe` map skCount (V.toList (spStrokes plan))
    drop (1 + strokeCount) counts `shouldBe` [12, 12, 12, 12, 16]

  it "the all-empty circle with phases still draws the boundary group (§4.4 judgment call)" $ do
    let spell = compiled bareCircle
        plan = sigilPlan bareCircle
    V.length (spStrokes plan) `shouldBe` 2
    map emCount (V.toList (spellEmitters spell))
      `shouldBe` 256 : map skCount (V.toList (spStrokes plan))

  it "occupancy tracks individual slots: only inner-A and north appear (plus the boundary)" $ do
    let spell = compiled mixedCircle
        plan = sigilPlan mixedCircle
    -- boundary group (2) + the one occupied ring slot.
    V.length (spStrokes plan) `shouldBe` 3
    map emCount (V.toList (spellEmitters spell))
      `shouldBe` 256 : map skCount (V.toList (spStrokes plan)) ++ [12]

  it "circlePhases = Nothing produces no formation emitters at all" $
    length (spellEmitters (compiled emptyCircle)) `shouldBe` 1

  it "the outer-ring ShapeRune exception previews the player's shape instead of a stroke" $ do
    let shape = Diamond 2
        c = emptyCircle {outerRings = TwoOf Nothing (Just (ShapeRune shape)), circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))}
        spell = compiled c
        -- 0 = casting, 1..2 = the boundary group, 3 = the preview.
        formation = V.toList (spellEmitters spell) !! 3
    motSpawn (emMotion formation) `shouldBe` SpawnOnShape shape
    emCount formation `shouldBe` 64

  it "a non-ShapeRune outer occupant is drawn with a stroke, not a shape" $ do
    let c = emptyCircle {outerRings = TwoOf Nothing (Just (RadiateRune RadialOutward)), circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))}
        spell = compiled c
        plan = sigilPlan c
        formation = V.toList (spellEmitters spell) !! 3
    motSpawn (emMotion formation) `shouldBe` SpawnOnStroke (spStrokes plan V.! 2)

  it "formEnv derivation chain: castStart 1.5s (draw 1.0 + converge 0.5) caps formLife at 0.6s" $ do
    let spell = compiled mixedCircle
        formation = V.toList (spellEmitters spell) !! 1 -- the boundary ring
        env = emSpawn formation
    -- The pace is spec 0006's, unchanged: delay 0, lifetime capped at 0.6.
    envDelay env `shouldBe` Seconds 0
    envLifetime env `shouldBe` Seconds 0.6
    -- Func-spec 0017 moved the chain's endpoint: the last batch now dies
    -- at ppEnd (the sigil outlives the prelude) rather than at castStart.
    let Seconds dur = envDuration env
        Seconds life = envLifetime env
        Seconds end = ppEnd (spellPhases spell)
    abs (dur + life - end) `shouldSatisfy` (< 1e-9)

  it "formEnv caps formLife at 0.6s even for a long prelude (castStart 4s)" $ do
    let c = emptyCircle {core = Core Nothing (Nodes (Just (DirBias 0.1)) Nothing Nothing Nothing), circlePhases = Just (PhaseConfig (Seconds 3.0) (Seconds 1.0))}
        spell = compiled c
        formation = V.toList (spellEmitters spell) !! 1
        env = emSpawn formation
        Seconds end = ppEnd (spellPhases spell)
        Seconds dur = envDuration env
    envLifetime env `shouldBe` Seconds 0.6
    abs (dur + 0.6 - end) `shouldSatisfy` (< 1e-9)

  it "formation carries no convergence curve at all (func-spec 0017: it holds where it was drawn)" $ do
    let spell = compiled mixedCircle -- draw=1.0, converge=0.5, castStart=1.5
        formation = drop 1 (V.toList (spellEmitters spell))
    map (motConverge . emMotion) formation `shouldSatisfy` all (== Nothing)

  it "phConverge = 0 is still a legal configuration, with no curve either" $ do
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
        -- casting + the boundary group; the four nodes follow.
        nodeEmitters = drop (1 + V.length (spStrokes (sigilPlan c))) (V.toList (spellEmitters spell))
    map (anchorOffset . emAnchor) nodeEmitters
      `shouldBe` [V3 0 0.35 0, V3 0 (-0.35) 0, V3 0.35 0 0, V3 (-0.35) 0 0]
    map (anchorNormal . emAnchor) nodeEmitters `shouldBe` replicate 4 (V3 0 0 1)

  it "formation particles fade to the same RGB with alpha cleared, smaller and same blend" $ do
    let spell = compiled mixedCircle
        formation = V.toList (spellEmitters spell) !! 1
        Appearance (ColorRamp start end) size blend _ _ = emAppearance formation
    (start .&. 0x000000FF) `shouldBe` 0xFF -- Neutral start alpha untouched
    (end .&. 0xFFFFFF00) `shouldBe` (start .&. 0xFFFFFF00) -- same RGB
    (end .&. 0x000000FF) `shouldBe` 0 -- alpha cleared
    size `shouldBe` 0.03
    blend `shouldBe` BlendAlpha -- Neutral's own blend mode

  it "spellBudget = Sigma emCount across every emitter" $ do
    let spell = compiled (fullCircle Neutral 1.0)
    spellBudget spell `shouldBe` sum (map emCount (V.toList (spellEmitters spell)))

  it "the Sigma budget check fires BudgetExceeded when casting + formation exceeds the cap" $
    -- power 63 -> casting count 16128, under the 16384 cap on its own;
    -- the sigil's own emitters push the sum over it. The point of the
    -- case is the /sum/, so the expected demand is read off the same
    -- formation the compiler builds rather than hard-coded.
    let c = fullCircle Neutral 63
        plan = sigilPlan c
        formation =
          sum (map skCount (V.toList (spStrokes plan)))
            + sum (map snd (V.toList (spShapes plan)))
            + 4 * 12 -- the four node emitters
            + 16 -- the center emitter
     in compile c `shouldBe` Left (BudgetExceeded (16128 + formation) budgetCap)

  it "index 0 is always the casting emitter; spellBlend reads it regardless of formation emitters" $ do
    let spell = compiled (fullCircle Fire 1.0)
        first = V.head (spellEmitters spell)
    emPhase first `shouldBe` Casting
    spellBlend spell `shouldBe` BlendAdditive
