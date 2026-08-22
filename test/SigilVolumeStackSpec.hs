-- | T3 (magic-semantics F002): the stack itself, observed through
-- 'Magic.Compile.compile' — @stackDepth@, @layerAnchor@ and
-- @perLayerCount@ are deliberately unexported (Level 2 promises only the
-- external effect), so every claim here is stated about
-- 'spellEmitters' rather than about the internal helpers.
--
-- Two claims, matching the feature doc's derivation exactly:
--
--   * at @circleVolume = Nothing@ the only reachable depth is 1, and at
--     depth 1 the layered formula degenerates to a single emitter whose
--     anchor and count are exactly what a pre-F002 stroke/shape emitter
--     always had — the plain origin anchor and the plan's own count,
--     untouched;
--   * at @circleVolume = Just SigilVolume@ every stroke produces more
--     than one emitter, symmetric about the face origin along the
--     normal, sharing one spawn envelope and one appearance across the
--     whole group.
module SigilVolumeStackSpec (spec) where

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
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Motion (..)
  , Phase (..)
  , SpawnPattern (..)
  , compile
  )
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , EssenceRune (..)
  , InnerRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Sigil (SigilPlan (..), SigilStroke (..), sigilPlan)
import Magic.Types (Seconds (..), V3 (..))
import Test.Hspec

-- | Five ring/interlayer slots filled, exactly the occupancy
-- @assets/spells/stacked-sigil.json@ ships (occCount = 5, the deepest
-- stack this round's formula reaches). The rune content does not matter
-- to occupancy — any rune, any parameter — only presence does.
fullCircle :: Circle
fullCircle =
  emptyCircle
    { circlePhases = Just (PhaseConfig (Seconds 1.4) (Seconds 0.7))
    , outerRings = TwoOf (Just (RadiateRune AlongNormal)) (Just (RadiateRune AlongNormal))
    , interLayer = Just (PhaseRune (Seconds 0.2))
    , innerRings = TwoOf (Just (TrajectoryRune (Forward 3))) (Just (TrajectoryRune (Forward 3)))
    , core = Core (Just (EssenceRune Earth 1.0)) (Nodes Nothing Nothing Nothing Nothing)
    }

flatOf :: Circle -> Circle
flatOf c = c {circleVolume = Nothing}

stackedOf :: Circle -> Circle
stackedOf c = c {circleVolume = Just SigilVolume}

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

formationEmitters :: CompiledSpell -> [EmitterSpec]
formationEmitters spell = [em | em <- V.toList (spellEmitters spell), emPhase em /= Casting]

-- | Every formation emitter whose spawn pattern is exactly this stroke.
strokeGroup :: CompiledSpell -> SigilStroke -> [EmitterSpec]
strokeGroup spell sk =
  [em | em <- formationEmitters spell, motSpawn (emMotion em) == SpawnOnStroke sk]

zOf :: EmitterSpec -> Float
zOf em = let V3 _ _ z = anchorOffset (emAnchor em) in z

dedupFloats :: [Float] -> [Float]
dedupFloats = go []
  where
    go seen [] = seen
    go seen (x : xs)
      | any (\y -> abs (x - y) < 1e-6) seen = go seen xs
      | otherwise = go (x : seen) xs

dedupBy :: (Eq b) => (a -> b) -> [a] -> [b]
dedupBy f = go [] . map f
  where
    go seen [] = seen
    go seen (x : xs)
      | x `elem` seen = go seen xs
      | otherwise = go (x : seen) xs

spec :: Spec
spec = describe "the stack, through compile (magic-semantics F002 T3)" $ do
  describe "circleVolume = Nothing: the only reachable depth is 1" $ do
    let flat = flatOf fullCircle
        plan = sigilPlan flat
        spell = compiledOf flat

    it "every stroke gets exactly one formation emitter" $
      mapM_
        (\sk -> length (strokeGroup spell sk) `shouldBe` 1)
        (V.toList (spStrokes plan))

    it "and that emitter sits at the plain origin anchor" $
      mapM_
        ( \sk -> case strokeGroup spell sk of
            [em] -> do
              anchorOffset (emAnchor em) `shouldBe` V3 0 0 0
              anchorNormal (emAnchor em) `shouldBe` V3 0 0 1
            other -> expectationFailure ("expected exactly one emitter, got " ++ show (length other))
        )
        (V.toList (spStrokes plan))

    it "with its count exactly the plan's own, untouched" $
      mapM_
        ( \sk -> case strokeGroup spell sk of
            [em] -> emCount em `shouldBe` skCount sk
            _ -> expectationFailure "expected exactly one emitter"
        )
        (V.toList (spStrokes plan))

  describe "circleVolume = Just SigilVolume: every stroke stacks" $ do
    let stacked = stackedOf fullCircle
        plan = sigilPlan stacked
        spell = compiledOf stacked
        depths = [length (strokeGroup spell sk) | sk <- V.toList (spStrokes plan)]

    it "produces more than one emitter per stroke" $
      depths `shouldSatisfy` all (> 1)

    it "the same depth for every stroke in one compile" $
      length (Prelude.filter (/= head depths) depths) `shouldBe` 0

    it "spread symmetrically about the face origin along the normal" $
      mapM_
        ( \sk -> do
            let zs = map zOf (strokeGroup spell sk)
            sum zs `shouldSatisfy` (\s -> abs s < 1e-5)
        )
        (V.toList (spStrokes plan))

    it "each layer at a distinct anchor" $
      mapM_
        ( \sk -> do
            let zs = map zOf (strokeGroup spell sk)
            length zs `shouldBe` length (dedupFloats zs)
        )
        (V.toList (spStrokes plan))

    it "sharing one spawn envelope and one appearance across the group" $
      mapM_
        ( \sk -> do
            let ems = strokeGroup spell sk
            length (dedupBy emSpawn ems) `shouldBe` 1
            length (dedupBy emAppearance ems) `shouldBe` 1
        )
        (V.toList (spStrokes plan))
