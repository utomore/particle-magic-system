-- | S1 (func-spec 0015 §7): 'observeSpell' cuts the sampled buffer into
-- batches by run-length grouping adjacent emitters on
-- @(appBlend, appShape)@ — and the cut is only ever allowed to /slice/:
--
--   * splitting law — the batches' buffers, concatenated in batch order,
--     are the un-split buffer bit for bit (all six columns, row order
--     included);
--   * a spell whose emitters all share one key is exactly one batch;
--   * a spell with no emitters at all is zero batches;
--   * batch order is emitter order (the run-length of the emitters'
--     keys), which makes the output deterministic by construction;
--   * the row counts of the batches sum to the un-split row count.
--
-- The expected buffer comes from the core's own 'sample' (the test suite
-- may reach magic-core), so the law is checked against the sampler, not
-- against a second copy of the splitter. Field-free circles only: with
-- fields the un-split buffer is internal to "Magic.Interface", and the
-- displacement overlay is 0007/0010's business, not this spec's.
module BatchSplitSpec (spec) where

import qualified Data.List as List
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( Appearance (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , compile
  )
import Magic.Interface
  ( ActiveSpell
  , BillboardShape (..)
  , BlendMode
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , castSpells
  , observeSpell
  )
import qualified Magic.Particle.Analytic as Analytic
import Magic.Rune
  ( Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , OuterRune (..)
  )
import Magic.Types (Seconds (..), Time (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

castOf :: Circle -> ActiveSpell
castOf c = either (error . show) id (castSpell (CastRequest c ctx))

-- | Observe a circle @t@ seconds after its cast (one advance step — these
-- circles are field-free, so step count cannot matter).
observeAt :: Circle -> Double -> FrameOutput
observeAt c t = observeSpell (advanceSpell (FrameInput (DeltaTime t)) (castOf c))

-- | The un-split buffer straight from the core's sampler.
sampledAt :: Circle -> Double -> ParticleBuffer
sampledAt c t =
  let compiled = either (error . show) id (compile c)
   in Analytic.sample compiled ctx (Time t)

-- | The batch keys the run-length rule predicts from the compiled
-- emitters: adjacent equals collapse, non-adjacent equals stay apart.
expectedKeys :: Circle -> [(BlendMode, BillboardShape)]
expectedKeys c =
  let compiled = either (error . show) id (compile c)
   in collapse
        [ (appBlend look, appShape look)
        | em <- V.toList (spellEmitters compiled)
        , let look = emAppearance em
        ]
  where
    collapse = map fst . List.foldr merge []
    merge k ((k', n) : rest) | k == k' = (k', n + 1 :: Int) : rest
    merge k rest = (k, 1) : rest

sixColumns :: ParticleBuffer -> ([Float], [Float], [Float], [Float], [Float], [Word32])
sixColumns pb =
  ( U.toList (pbPosX pb)
  , U.toList (pbPosY pb)
  , U.toList (pbPosZ pb)
  , U.toList (pbSize pb)
  , U.toList (pbLife pb)
  , U.toList (pbColor pb)
  )

concatColumns :: [ParticleBuffer] -> ([Float], [Float], [Float], [Float], [Float], [Word32])
concatColumns pbs =
  let cols = map sixColumns pbs
   in ( concatMap (\(a, _, _, _, _, _) -> a) cols
      , concatMap (\(_, b, _, _, _, _) -> b) cols
      , concatMap (\(_, _, c, _, _, _) -> c) cols
      , concatMap (\(_, _, _, d, _, _) -> d) cols
      , concatMap (\(_, _, _, _, e, _) -> e) cols
      , concatMap (\(_, _, _, _, _, f) -> f) cols
      )

-- Random circles: enough variety to move every splitting input (element →
-- blend, style → shape, phases → formation emitters, timing → live rows),
-- small enough that no draw ever trips the budget.
genCircle :: Gen Circle
genCircle = do
  element <- elements [Neutral, Fire, Water, Lightning]
  power <- choose (0.2, 3.0)
  style <-
    frequency
      [ (1, pure Nothing)
      , (2, Just . StyleRune <$> elements [minBound .. maxBound])
      ]
  shapeRune <-
    elements [Nothing, Just (ShapeRune (Ring 0.8 1.2)), Just (ShapeRune (Diamond 0.9))]
  phases <- elements [Nothing, Just (PhaseConfig (Seconds 0.8) (Seconds 0.4))]
  timing <-
    elements
      [Nothing, Just (TimingRune (Envelope (Seconds 0) (Seconds 3) (Seconds 1.5)))]
  pure
    emptyCircle
      { outerRings = TwoOf shapeRune style
      , innerRings = TwoOf timing Nothing
      , core = Core (Just (EssenceRune element power)) (Nodes Nothing Nothing Nothing Nothing)
      , circlePhases = phases
      }

genT :: Gen Double
genT = choose (0, 6)

-- A phased circle with no 'StyleRune': casting and formation emitters all
-- share @(blend, BillboardSquare)@ — the single-key shape of every
-- pre-0015 example.
singleKeyCircle :: Circle
singleKeyCircle =
  emptyCircle
    { outerRings = TwoOf (Just (ShapeRune (Ring 0.8 1.2))) Nothing
    , circlePhases = Just (PhaseConfig (Seconds 0.8) (Seconds 0.4))
    }

styledCircle :: Circle
styledCircle =
  emptyCircle
    { outerRings = TwoOf Nothing (Just (StyleRune BillboardSoftDot))
    , circlePhases = Just (PhaseConfig (Seconds 0.8) (Seconds 0.4))
    }

spec :: Spec
spec = describe "observeSpell batch splitting (func-spec 0015 S1)" $ do
  prop "splitting law: batches concatenate to the sampled buffer, bit for bit" $
    forAll genCircle $ \c -> forAll genT $ \t ->
      let FrameOutput bs = observeAt c t
       in concatColumns (map rbParticles bs) === sixColumns (sampledAt c t)

  prop "row counts are conserved across the split" $
    forAll genCircle $ \c -> forAll genT $ \t ->
      let FrameOutput bs = observeAt c t
       in sum (map (pbCount . rbParticles) bs) === pbCount (sampledAt c t)

  prop "batch order is the run-length of the emitters' keys, in emitter order" $
    forAll genCircle $ \c -> forAll genT $ \t ->
      let FrameOutput bs = observeAt c t
       in map (\b -> (rbBlend b, rbShape b)) bs === expectedKeys c

  it "a single-key spell is exactly one batch, live rows or not" $ do
    let counts t = length (batches (observeAt singleKeyCircle t))
    map counts [0, 0.5, 1.5, 3, 20] `shouldBe` [1, 1, 1, 1, 1]

  it "a styled, phased spell splits into casting and formation batches" $ do
    let FrameOutput bs = observeAt styledCircle 0.5
    map rbShape bs `shouldBe` [BillboardSoftDot, BillboardSquare]

  it "the empty composed spell has zero batches" $ do
    let s = either (error . show) id (castSpells [] ctx)
    batches (observeSpell s) `shouldBe` []
