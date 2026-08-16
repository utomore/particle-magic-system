-- | S4 (func-spec 0025 §6): the fold produces one casting emitter per
-- activation point.
--
-- Two laws, and the round is only safe because both hold:
--
--   * __opt-in, bit for bit__ — a circle with no @anchors@ compiles to
--     exactly the emitter it always did, and 240 frames of its output are
--     bit-identical. This is the fourth time the repo states that law
--     (after @phases@, @fields@ and @style@) and the first time it covers
--     a change to the fold's /shape/ rather than to a value inside it.
--   * __energy equipartition__ — @n@ activation points spend the same
--     particle budget one does. Otherwise adding an anchor would be a way
--     to buy strength without going through @power@, and @budgetCap@
--     would stop bounding anything (func-spec 0025 §2.6).
module MultiAnchorSpec (spec) where

import Control.Monad (forM_)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Circle (Circle (..), Core (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( Anchor (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , ParticleBudget (..)
  , Phase (..)
  , compile
  , compileMany
  )
import Magic.Interface
  ( CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , advanceSpell
  , castSpell
  , observeSpell
  )
import Magic.Rune (EssenceRune (..), Element (..), InnerRune (..), Trajectory (..))
import Magic.Types (Seconds (..), V3 (..))
import SpaceExamples (exampleCircles, testCtx)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

-- | A circle with a definite, non-default particle count, so the split is
-- observable rather than accidentally symmetric.
baseCircle :: Circle
baseCircle =
  emptyCircle
    { core = (core emptyCircle) {coreCenter = Just (EssenceRune Fire 1.0)}
    , innerRings = TwoOf (Just (TrajectoryRune (Forward 5))) Nothing
    }

withAnchors :: [Anchor] -> Circle -> Circle
withAnchors as circle = circle {circleAnchors = Just as}

anchorsN :: Int -> [Anchor]
anchorsN n = [Anchor (V3 (fromIntegral i) 0 0) (V3 0 0 1) | i <- [1 .. n]]

castingEmitters :: CompiledSpell -> [EmitterSpec]
castingEmitters = filter ((== Casting) . emPhase) . V.toList . spellEmitters

-- | 240 frames of a cast, as the bits a host would receive.
framesOf :: Circle -> [[(Int, [Float], [Float], [Float], [Float], [Float], [Word32])]]
framesOf circle =
  [ [ ( pbCount pb
      , U.toList (pbPosX pb)
      , U.toList (pbPosY pb)
      , U.toList (pbPosZ pb)
      , U.toList (pbSize pb)
      , U.toList (pbLife pb)
      , U.toList (pbColor pb)
      )
    | batch <- batches (observeSpell cast)
    , let pb = rbParticles batch
    ]
  | cast <- take 240 (drop 1 (iterate step cast0))
  ]
  where
    cast0 = either (error . show) id (castSpell (CastRequest circle testCtx))
    step = advanceSpell (FrameInput (DeltaTime (1 / 60)))

spec :: Spec
spec = describe "several activation points (func-spec 0025 S4)" $ do
  describe "the opt-in law" $ do
    it "no anchors means exactly one casting emitter, at the origin anchor" $ do
      let spell = compiledOf baseCircle
      length (castingEmitters spell) `shouldBe` 1
      emAnchor (head (castingEmitters spell))
        `shouldBe` Anchor (V3 0 0 0) (V3 0 0 1)

    it "every pre-0025 example still fires from the origin, and only there" $ do
      -- The structural half. The bit-for-bit half over 240 frames is
      -- test/golden/perf-0010/*, recorded before this round and NOT
      -- re-recorded — the whole reason this law is worth stating is that
      -- those files did not have to move.
      circles <- exampleCircles
      forM_ [c | c@(name, _) <- circles, name /= "twin-lance.json"] $ \(name, circle) -> do
        let spell = compiledOf circle
        (name, length (castingEmitters spell)) `shouldBe` (name, 1)
        (name, emAnchor (head (castingEmitters spell)))
          `shouldBe` (name, Anchor (V3 0 0 0) (V3 0 0 1))

    it "naming the origin explicitly reproduces the implicit path, bit for bit" $ do
      -- Non-vacuous version of the law: the n = 1 split must be the
      -- identity, or every existing spell would drift the moment its
      -- author wrote down the anchor it already had.
      circles <- exampleCircles
      forM_ [c | c@(name, _) <- circles, name /= "twin-lance.json"] $ \(name, circle) -> do
        let explicit = withAnchors [Anchor (V3 0 0 0) (V3 0 0 1)] circle
        (name, compiledOf explicit) `shouldBe` (name, compiledOf circle)
        (name, framesOf explicit) `shouldBe` (name, framesOf circle)

  describe "the energy equipartition law" $ do
    prop "the budget of n activation points equals the budget of one" $
      forAll (choose (1, 16)) $ \n ->
        spellBudget (compiledOf (withAnchors (anchorsN n) baseCircle))
          === spellBudget (compiledOf baseCircle)

    prop "and the per-emitter breakdown still sums to it" $
      forAll (choose (1, 16)) $ \n ->
        let spell = compiledOf (withAnchors (anchorsN n) baseCircle)
            plan = spellBudgetPlan spell
         in conjoin
              [ U.sum (budgetPerEmitter plan) === budgetTotal plan
              , budgetTotal plan === spellBudget spell
              , U.length (budgetPerEmitter plan) === V.length (spellEmitters spell)
              ]

    prop "the shares differ by at most one particle" $
      forAll (choose (1, 16)) $ \n ->
        let counts = map emCount (castingEmitters (compiledOf (withAnchors (anchorsN n) baseCircle)))
         in maximum counts - minimum counts <= 1

    it "holds with a phased circle too (formation emitters are not split)" $ do
      let phased = baseCircle {circlePhases = Just (PhaseConfig (Seconds 1) (Seconds 0.5))}
          one = compiledOf phased
          four = compiledOf (withAnchors (anchorsN 4) phased)
      spellBudget four `shouldBe` spellBudget one
      -- The sigil is drawn once, however many points the spell fires from.
      length (formationOf four) `shouldBe` length (formationOf one)
      map emCount (formationOf four) `shouldBe` map emCount (formationOf one)
      map emAnchor (formationOf four) `shouldBe` map emAnchor (formationOf one)

  describe "the emitters themselves" $ do
    prop "one casting emitter per activation point, in the circle's order" $
      forAll (choose (1, 16)) $ \n ->
        let as = anchorsN n
            spell = compiledOf (withAnchors as baseCircle)
         in map emAnchor (castingEmitters spell) === as

    it "index 0 is still a casting emitter (spec 0006's reservation)" $ do
      let spell = compiledOf (withAnchors (anchorsN 3) baseCircle {circlePhases = Just (PhaseConfig (Seconds 1) (Seconds 0))})
      emPhase (spellEmitters spell V.! 0) `shouldBe` Casting

    it "the casting emitters differ only in their anchor" $ do
      let spell = compiledOf (withAnchors (anchorsN 3) baseCircle)
          ems = castingEmitters spell
          stripped em = (emSpawn em, emMotion em, emAppearance em, emPhase em)
      map stripped ems `shouldBe` replicate 3 (stripped (head ems))

    it "a very small count leaves the trailing points with nothing to fire" $ do
      -- power 0.004 → 1 particle, shared between 4 points.
      let tiny = baseCircle {core = (core baseCircle) {coreCenter = Just (EssenceRune Fire 0.001)}}
          spell = compiledOf (withAnchors (anchorsN 4) tiny)
      map emCount (castingEmitters spell) `shouldBe` [1, 0, 0, 0]
      spellBudget spell `shouldBe` spellBudget (compiledOf tiny)

  describe "composition" $
    it "each component circle's activation points act on its own emitters" $ do
      let left = withAnchors [Anchor (V3 (-1) 0 0) (V3 0 0 1)] baseCircle
          right = withAnchors (anchorsN 2) baseCircle
          composed = either (error . show) id (compileMany [left, right])
      map emAnchor (castingEmitters composed)
        `shouldBe` (Anchor (V3 (-1) 0 0) (V3 0 0 1) : anchorsN 2)
      spellBudget composed
        `shouldBe` spellBudget (compiledOf left) + spellBudget (compiledOf right)

formationOf :: CompiledSpell -> [EmitterSpec]
formationOf = filter ((/= Casting) . emPhase) . V.toList . spellEmitters
