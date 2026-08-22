-- | magic-semantics E001: the stack carries a full layer's worth of
-- particles, and the decorations stack with it.
--
-- F002 shipped the stack by /sharing/ one layer's particle count across
-- the layers, and left the four node points and the center point on a
-- single plane. E001 reverses both: 'Magic.Sigil.sigilBudget' is now read
-- as the budget of /one layer/, so each layer carries the plan's own
-- count untouched, and the decorations get the same depth and the same
-- layer offsets the strokes get.
--
-- The internal helpers (@stackDepth@, @layerAnchor@, @layerGap@) stay
-- unexported — Level 2 promises only the external effect — so every claim
-- here is stated about 'spellEmitters', the way "SigilVolumeStackSpec"
-- states its own.
--
-- Sections, in Todo order:
--
--   * T1 — the zero-ripple regression: with @circleVolume = Nothing@ the
--     decorations and the strokes are exactly what they were before this
--     round. Written first and green before any of the code below it
--     moved.
--   * T2 — every layer carries the plan's full count.
--   * T4 — each filled node slot stacks, 12 particles per layer.
--   * T5 — the center point stacks into a column on the axis, 16 per layer.
--   * T6 — the cross-layer upper bound, and the over-budget path.
module SigilVolumeAmplifySpec (spec) where

import qualified Data.Vector as V
import Magic.Circle
  ( Circle (..)
  , Core (..)
  , Nodes (..)
  , PhaseConfig (..)
  , SigilVolume (..)
  , TwoOf (..)
  , emptyCircle
  )
import Magic.Compile
  ( Anchor (..)
  , CompileError (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Motion (..)
  , Phase (..)
  , SpawnPattern (..)
  , budgetCap
  , compile
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
import Magic.Sigil (SigilPlan (..), SigilStroke (..), sigilBudget, sigilPlan)
import Magic.Types (Seconds (..), V3 (..))
import SigilGen (genAnyCircle)
import Test.Hspec
import Test.QuickCheck

-- | Every ring/interlayer slot filled (occCount = 5, the deepest stack),
-- all four node slots filled and the center filled — the circle that
-- exercises every one of the five emitter sources at once. Outer ring B
-- carries a 'ShapeRune' so @spShapes@ is non-empty too (spec 0006 §4.4's
-- exception), which still counts as an occupied slot.
richCircle :: Circle
richCircle =
  emptyCircle
    { circlePhases = Just (PhaseConfig (Seconds 1.4) (Seconds 0.7))
    , outerRings = TwoOf (Just (ShapeRune (Ring 0.4 0.6))) (Just (RadiateRune AlongNormal))
    , interLayer = Just (PhaseRune (Seconds 0.2))
    , innerRings = TwoOf (Just (TrajectoryRune (Forward 3))) (Just (TrajectoryRune (Forward 3)))
    , core =
        Core
          (Just (EssenceRune Earth 1.0))
          (Nodes (Just (DirBias 0.1)) (Just (DirBias 0.1)) (Just (DirBias 0.1)) (Just (DirBias 0.1)))
    }

flatOf :: Circle -> Circle
flatOf c = c {circleVolume = Nothing}

stackedOf :: Circle -> Circle
stackedOf c = c {circleVolume = Just SigilVolume}

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

formationEmitters :: CompiledSpell -> [EmitterSpec]
formationEmitters spell = [em | em <- V.toList (spellEmitters spell), emPhase em /= Casting]

strokeGroup :: CompiledSpell -> SigilStroke -> [EmitterSpec]
strokeGroup spell sk =
  [em | em <- formationEmitters spell, motSpawn (emMotion em) == SpawnOnStroke sk]

shapeGroup :: CompiledSpell -> FaceShape -> [EmitterSpec]
shapeGroup spell shape =
  [em | em <- formationEmitters spell, motSpawn (emMotion em) == SpawnOnShape shape]

-- | The node and center emitters: spec 0006 §4.4's decorations, the only
-- formation emitters born at a plain anchor rather than along a stroke or
-- over a shape.
decorEmitters :: CompiledSpell -> [EmitterSpec]
decorEmitters spell =
  [em | em <- formationEmitters spell, motSpawn (emMotion em) == SpawnAtAnchor 0]

-- | Split the decorations by whether they sit on the face axis: the
-- center point does, the four node points do not (they are parked at
-- ±0.35 on one of the face axes). The layer offset is purely along the
-- normal, so this split survives stacking.
onAxis :: EmitterSpec -> Bool
onAxis em = let V3 x y _ = anchorOffset (emAnchor em) in x == 0 && y == 0

nodeEmitters :: CompiledSpell -> [EmitterSpec]
nodeEmitters = Prelude.filter (not . onAxis) . decorEmitters

centerEmitters :: CompiledSpell -> [EmitterSpec]
centerEmitters = Prelude.filter onAxis . decorEmitters

zOf :: EmitterSpec -> Float
zOf em = let V3 _ _ z = anchorOffset (emAnchor em) in z

xyOf :: EmitterSpec -> (Float, Float)
xyOf em = let V3 x y _ = anchorOffset (emAnchor em) in (x, y)

-- | The depth this circle stacks at, read off its first stroke — every
-- plan has at least the boundary group, so there is always one.
depthOf :: Circle -> Int
depthOf c = length (strokeGroup (compiledOf c) (V.head (spStrokes (sigilPlan c))))

nearZero :: Float -> Bool
nearZero x = abs x < 1e-5

spec :: Spec
spec = describe "a full layer's worth of particles (magic-semantics E001)" $ do
  -- T1 ----------------------------------------------------------------
  describe "T1 zero ripple: circleVolume = Nothing keeps the pre-E001 shape" $ do
    let spell = compiledOf (flatOf richCircle)
        plan = sigilPlan (flatOf richCircle)

    it "each filled node slot gets exactly one emitter, off the axis, 12 particles" $ do
      let nodes = nodeEmitters spell
      length nodes `shouldBe` 4
      mapM_ (\em -> emCount em `shouldBe` 12) nodes
      mapM_ (\em -> zOf em `shouldSatisfy` nearZero) nodes

    it "the four node offsets are the four face directions at 0.35" $
      map xyOf (nodeEmitters spell)
        `shouldMatchList` [(0, 0.35), (0, -0.35), (0.35, 0), (-0.35, 0)]

    it "the center gets exactly one emitter, on the axis, 16 particles" $
      case centerEmitters spell of
        [em] -> do
          emCount em `shouldBe` 16
          anchorOffset (emAnchor em) `shouldBe` V3 0 0 0
          anchorNormal (emAnchor em) `shouldBe` V3 0 0 1
        other -> expectationFailure ("expected one center emitter, got " ++ show (length other))

    it "every stroke and every shape still gets one emitter carrying the plan's own count" $ do
      mapM_
        ( \sk -> case strokeGroup spell sk of
            [em] -> emCount em `shouldBe` skCount sk
            other -> expectationFailure ("stroke: expected 1 emitter, got " ++ show (length other))
        )
        (V.toList (spStrokes plan))
      mapM_
        ( \(shape, cnt) -> case shapeGroup spell shape of
            [em] -> emCount em `shouldBe` cnt
            other -> expectationFailure ("shape: expected 1 emitter, got " ++ show (length other))
        )
        (V.toList (spShapes plan))

    it "so the formation emitter count is strokes + shapes + 4 nodes + 1 center" $
      length (formationEmitters spell)
        `shouldBe` V.length (spStrokes plan) + V.length (spShapes plan) + 5

  -- T2 ----------------------------------------------------------------
  describe "T2 every layer carries the plan's full count" $ do
    let stacked = stackedOf richCircle
        spell = compiledOf stacked
        plan = sigilPlan stacked

    it "every layer of every stroke gets exactly the stroke's own skCount" $
      mapM_
        (\sk -> map emCount (strokeGroup spell sk) `shouldBe` replicate (depthOf stacked) (skCount sk))
        (V.toList (spStrokes plan))

    it "every layer of every shape preview gets exactly the plan's count" $
      mapM_
        (\(shape, cnt) -> map emCount (shapeGroup spell shape) `shouldBe` replicate (depthOf stacked) cnt)
        (V.toList (spShapes plan))

    it "so the stacked spell carries strictly more particles than the flat one" $
      spellBudget spell `shouldSatisfy` (> spellBudget (compiledOf (flatOf richCircle)))

  -- T4 ----------------------------------------------------------------
  describe "T4 the node points stack with the strokes" $ do
    let stacked = stackedOf richCircle
        spell = compiledOf stacked
        depth = depthOf stacked
        strokeZs = map zOf (strokeGroup spell (V.head (spStrokes (sigilPlan stacked))))

    it "each of the four slots produces one emitter per layer" $
      length (nodeEmitters spell) `shouldBe` 4 * depth

    it "each layer keeps the full structural constant of 12" $
      mapM_ (\em -> emCount em `shouldBe` 12) (nodeEmitters spell)

    it "the four in-face offsets are untouched, one column per node" $
      mapM_
        ( \xy ->
            length (Prelude.filter ((== xy) . xyOf) (nodeEmitters spell)) `shouldBe` depth
        )
        [(0, 0.35), (0, -0.35), (0.35, 0), (-0.35, 0)]

    it "and they ride the same layer offsets the strokes do" $
      mapM_
        ( \xy ->
            map zOf (Prelude.filter ((== xy) . xyOf) (nodeEmitters spell)) `shouldBe` strokeZs
        )
        [(0, 0.35), (0, -0.35), (0.35, 0), (-0.35, 0)]

  -- T5 ----------------------------------------------------------------
  describe "T5 the center point stacks into a column on the axis" $ do
    let stacked = stackedOf richCircle
        spell = compiledOf stacked
        depth = depthOf stacked
        centers = centerEmitters spell
        strokeZs = map zOf (strokeGroup spell (V.head (spStrokes (sigilPlan stacked))))

    it "one emitter per layer" $
      length centers `shouldBe` depth

    it "each keeping the full structural constant of 16" $
      mapM_ (\em -> emCount em `shouldBe` 16) centers

    it "all of them on the axis, at the same layer offsets as the strokes" $ do
      mapM_ (\em -> xyOf em `shouldBe` (0, 0)) centers
      map zOf centers `shouldBe` strokeZs

    it "symmetric about the face origin, so the column is centered" $
      sum (map zOf centers) `shouldSatisfy` nearZero

  -- T6 ----------------------------------------------------------------
  describe "T6 the cross-layer bound, and what happens above it" $ do
    it "any circle's formation total fits (sigilBudget + 64) * 5, or is refused" $
      property $
        forAll (stackedOf <$> genAnyCircle) $ \c ->
          case compile c of
            Right spell ->
              counterexample
                (show (sum (map emCount (formationEmitters spell))))
                (sum (map emCount (formationEmitters spell)) <= (sigilBudget + 64) * 5)
            Left (BudgetExceeded _ cap) -> counterexample "cap moved" (cap == budgetCap)
            Left other -> counterexample (show other) False

    it "an over-budget stacked circle still reports BudgetExceeded, unchanged" $
      case compile (stackedOf richCircle {core = Core (Just (EssenceRune Fire 64)) (coreNodes (core richCircle))}) of
        Left (BudgetExceeded asked cap) -> do
          cap `shouldBe` budgetCap
          asked `shouldSatisfy` (> budgetCap)
        other -> expectationFailure ("expected BudgetExceeded, got " ++ show (fmap spellBudget other))
