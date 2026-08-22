-- | T5 (magic-semantics F002): the structure-derives-the-depth law
-- (ADR-0014 D2, "structure sets the skeleton").
--
-- @stackDepth@ itself is unexported (Level 2 promises only the external
-- effect), so "the depth" here means "how many formation emitters one
-- stroke produces once @circleVolume@ is on" — observed the same way
-- "SigilVolumeStackSpec" observes it, through 'compile'.
--
-- Three claims:
--
--   * three circles at three different slot-occupancy counts (0, some,
--     all five) produce depths of 2, something in between, and 5 —
--     monotone non-decreasing in how many slots are filled;
--   * whatever the depth, every stroke's particle count summed across its
--     layers is exactly what 'Magic.Sigil.sigilPlan' handed that stroke
--     times the depth — magic-semantics E001 reads @sigilBudget@ as one
--     layer's budget, so each layer carries a full count and stacking
--     makes the sigil denser rather than spreading the same particles
--     thinner (this reverses F002's own reading, assumption A4);
--   * the depth is always in @[1, 5]@ — 1 only when @circleVolume@ is
--     off, never above the feature's own ceiling.
module SigilVolumeStructureSpec (spec) where

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
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Motion (..)
  , Phase (..)
  , SpawnPattern (..)
  , compile
  )
import Magic.Rune (BridgeRune (..), Element (..), EssenceRune (..), InnerRune (..), OuterRune (..), RadiationMode (..), Trajectory (..))
import Magic.Sigil (SigilPlan (..), SigilStroke (..), sigilPlan)
import Magic.Types (Seconds (..))
import Test.Hspec

phased :: Seconds -> Seconds -> Circle
phased draw converge = emptyCircle {circlePhases = Just (PhaseConfig draw converge)}

-- | occCount = 0: only @phases@, no ring or interlayer slot filled.
occ0 :: Circle
occ0 = phased (Seconds 1.0) (Seconds 0.4)

-- | occCount = 2: one outer ring layer and one inner ring layer filled,
-- the interlayer and the other two ring layers left empty.
occ2 :: Circle
occ2 =
  (phased (Seconds 1.2) (Seconds 0.5))
    { outerRings = TwoOf Nothing (Just (RadiateRune AlongNormal))
    , innerRings = TwoOf (Just (TrajectoryRune (Forward 2))) Nothing
    }

-- | occCount = 5: every ring/interlayer slot filled — the same occupancy
-- @assets/spells/stacked-sigil.json@ ships.
occ5 :: Circle
occ5 =
  (phased (Seconds 1.4) (Seconds 0.7))
    { outerRings = TwoOf (Just (RadiateRune AlongNormal)) (Just (RadiateRune AlongNormal))
    , interLayer = Just (PhaseRune (Seconds 0.2))
    , innerRings = TwoOf (Just (TrajectoryRune (Forward 3))) (Just (TrajectoryRune (Forward 3)))
    , core = Core (Just (EssenceRune Earth 1.0)) (Nodes Nothing Nothing Nothing Nothing)
    }

withVolume :: Circle -> Circle
withVolume c = c {circleVolume = Just SigilVolume}

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

formationEmitters :: CompiledSpell -> [EmitterSpec]
formationEmitters spell = [em | em <- V.toList (spellEmitters spell), emPhase em /= Casting]

strokeGroup :: CompiledSpell -> SigilStroke -> [EmitterSpec]
strokeGroup spell sk =
  [em | em <- formationEmitters spell, motSpawn (emMotion em) == SpawnOnStroke sk]

-- | The depth this circle stacks at, read off its first stroke — every
-- circle 'sigilPlan' ever produces has at least the boundary group
-- (spec 0006's "a sigil always has a silhouette"), so there is always a
-- first stroke to measure.
depthOf :: Circle -> Int
depthOf c = length (strokeGroup (compiledOf c) (V.head (spStrokes (sigilPlan c))))

spec :: Spec
spec = describe "structure derives the depth (magic-semantics F002 T5)" $ do
  describe "three occupancies, three depths, monotone" $ do
    it "occCount = 0 stacks at the floor, 2" $
      depthOf (withVolume occ0) `shouldBe` 2

    it "occCount = 2 stacks in between" $ do
      let d = depthOf (withVolume occ2)
      d `shouldSatisfy` (\x -> x > depthOf (withVolume occ0) && x < 5)

    it "occCount = 5 stacks at the ceiling, 5" $
      depthOf (withVolume occ5) `shouldBe` 5

    it "monotone: more filled slots never means a shallower stack" $ do
      let d0 = depthOf (withVolume occ0)
          d2 = depthOf (withVolume occ2)
          d5 = depthOf (withVolume occ5)
      d0 `shouldSatisfy` (<= d2)
      d2 `shouldSatisfy` (<= d5)

  describe "the depth is always in [1, 5]" $ do
    it "1 only when circleVolume is off" $ do
      depthOf occ0 `shouldBe` 1
      depthOf occ2 `shouldBe` 1
      depthOf occ5 `shouldBe` 1

    it "never above 5, at the ceiling occupancy" $
      depthOf (withVolume occ5) `shouldSatisfy` (<= 5)

    it "never below 2 once circleVolume is on" $ do
      depthOf (withVolume occ0) `shouldSatisfy` (>= 2)
      depthOf (withVolume occ2) `shouldSatisfy` (>= 2)
      depthOf (withVolume occ5) `shouldSatisfy` (>= 2)

  describe "stacking multiplies a stroke's particle count by the depth" $
    it "every stroke's cross-layer sum is exactly the plan's count times the depth" $
      mapM_
        ( \c -> do
            let stacked = withVolume c
                plan = sigilPlan stacked
                spell = compiledOf stacked
                depth = depthOf stacked
            mapM_
              ( \sk -> do
                  let total = sum (map emCount (strokeGroup spell sk))
                  total `shouldBe` skCount sk * depth
              )
              (V.toList (spStrokes plan))
        )
        [occ0, occ2, occ5]
