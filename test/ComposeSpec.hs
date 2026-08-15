-- | S2 (func-spec 0012 §7): 'CompiledSpell' as a lawful 'Semigroup' and
-- 'Monoid'.
--
-- The instance is what makes "several circles, one spell" a fold instead
-- of a special case, so the algebra has to hold rather than merely look
-- plausible: associativity and the unit laws are properties over the
-- shipped example spells, and each structural invariant a compiled spell
-- carries — the 'PhasePlan' landmark order, @spellLifetime == ppEnd@, the
-- 'ParticleBudget' sum and alignment — is asserted to survive a merge.
--
-- Also here: the index-0 question. Func-spec 0006 made "emitter 0 is the
-- casting emitter" a /construction/ convention, and composition is the
-- first thing that breaks it as a /reading/ assumption (the second
-- circle's casting emitter lands in the middle of the vector). The
-- witness at the bottom shows the force-field layer keys off 'emPhase',
-- not off the index, so a composed spell's second casting emitter is
-- driven exactly like its first.
module ComposeSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , ParticleBudget (..)
  , Phase (..)
  , PhasePlan (..)
  , compile
  )
import Magic.Interface
  ( CastContext (..)
  , CastRequest (..)
  , Circle
  , DeltaTime (..)
  , FrameInput (..)
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , batches
  , castSpell
  , castSpells
  , observeSpell
  , pbCount
  , pbPosX
  , pbPosY
  , pbPosZ
  )
import Magic.Types (Seconds (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

exampleNames :: [String]
exampleNames =
  [ "bare-sigil"
  , "converge-flame"
  , "empty"
  , "grand-sigil"
  , "gravity-well"
  , "lissajous"
  , "pulse-ring"
  , "ring-fire"
  , "spiral-spark"
  , "square-burst"
  ]

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

loadCircleOf :: String -> IO Circle
loadCircleOf name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

compileOf :: String -> IO CompiledSpell
compileOf name = do
  circle <- loadCircleOf name
  either (fail . show) pure (compile circle)

-- | The 'PhasePlan' invariant, as a predicate rather than as prose.
planOrdered :: PhasePlan -> Bool
planOrdered p =
  Seconds 0 <= ppDrawEnd p
    && ppDrawEnd p <= ppConvergeEnd p
    && ppConvergeEnd p <= ppCastingEnd p
    && ppCastingEnd p <= ppEnd p

-- | Everything a compiled spell promises about itself in one place, so a
-- merged value can be held to the same promises as a compiled one.
wellFormed :: CompiledSpell -> Property
wellFormed s =
  conjoin
    [ counterexample "PhasePlan landmarks ordered" (property (planOrdered (spellPhases s)))
    , counterexample "lifetime agrees with ppEnd" (spellLifetime s === ppEnd (spellPhases s))
    , counterexample
        "budget plan aligned with emitters"
        (U.length (budgetPerEmitter (spellBudgetPlan s)) === V.length (spellEmitters s))
    , counterexample
        "budget plan sums to its total"
        (U.sum (budgetPerEmitter (spellBudgetPlan s)) === budgetTotal (spellBudgetPlan s))
    , counterexample
        "spellBudget agrees with the plan"
        (spellBudget s === budgetTotal (spellBudgetPlan s))
    , counterexample
        "per-emitter counts are the emitters' own"
        (U.toList (budgetPerEmitter (spellBudgetPlan s)) === map emCount (V.toList (spellEmitters s)))
    ]

spec :: Spec
spec = do
  pool <- runIO (mapM compileOf exampleNames)
  let anySpell = elements pool

  describe "Semigroup CompiledSpell (func-spec 0012 S2)" $ do
    prop "is associative, bit for bit" $
      forAll anySpell $ \a -> forAll anySpell $ \b -> forAll anySpell $ \c ->
        let l = (a <> b) <> c
            r = a <> (b <> c)
         in conjoin
              [ counterexample "structural equality" (l === r)
              , counterexample "rendered equality (separates -0.0 from 0.0)" (show l === show r)
              ]

    prop "mempty is a left and a right identity" $
      forAll anySpell $ \a ->
        conjoin
          [ counterexample "left" (mempty <> a === a)
          , counterexample "right" (a <> mempty === a)
          ]

    prop "mconcat of a singleton is that spell (compileMany [c] == compile c)" $
      forAll anySpell $ \a -> mconcat [a] === a

    prop "a merge is as well-formed as the spells it merged" $
      forAll anySpell $ \a -> forAll anySpell $ \b -> wellFormed (a <> b)

    prop "emitters and fields concatenate, left spell first" $
      forAll anySpell $ \a -> forAll anySpell $ \b ->
        conjoin
          [ spellEmitters (a <> b) === spellEmitters a <> spellEmitters b
          , spellFields (a <> b) === spellFields a ++ spellFields b
          , spellBudget (a <> b) === spellBudget a + spellBudget b
          ]

    prop "every landmark is the maximum of the two" $
      forAll anySpell $ \a -> forAll anySpell $ \b ->
        let p = spellPhases (a <> b)
            (pa, pb) = (spellPhases a, spellPhases b)
         in conjoin
              [ ppDrawEnd p === max (ppDrawEnd pa) (ppDrawEnd pb)
              , ppConvergeEnd p === max (ppConvergeEnd pa) (ppConvergeEnd pb)
              , ppCastingEnd p === max (ppCastingEnd pa) (ppCastingEnd pb)
              , ppEnd p === max (ppEnd pa) (ppEnd pb)
              ]

  describe "the landmark max, concretely" $ do
    it "a drawn circle composed with a plain one keeps the drawing prelude" $ do
      drawn <- compileOf "grand-sigil"
      plain <- compileOf "ring-fire"
      -- The plain circle has no phases at all: its prelude landmarks are 0.
      ppDrawEnd (spellPhases plain) `shouldBe` Seconds 0
      ppConvergeEnd (spellPhases plain) `shouldBe` Seconds 0
      let merged = spellPhases (drawn <> plain)
      ppDrawEnd merged `shouldBe` ppDrawEnd (spellPhases drawn)
      ppConvergeEnd merged `shouldBe` ppConvergeEnd (spellPhases drawn)
      -- ...and runs until the later of the two ends, truncating neither.
      ppEnd merged
        `shouldBe` max (ppEnd (spellPhases drawn)) (ppEnd (spellPhases plain))
      planOrdered merged `shouldBe` True

    it "composition is commutative on the plan even where it is not on the emitters" $ do
      a <- compileOf "grand-sigil"
      b <- compileOf "spiral-spark"
      spellPhases (a <> b) `shouldBe` spellPhases (b <> a)
      spellEmitters (a <> b) `shouldNotBe` spellEmitters (b <> a)

  describe "index 0 is a construction convention, not a reading assumption" $ do
    it "a composed spell has a casting emitter that is not emitter 0" $ do
      a <- compileOf "ring-fire"
      b <- compileOf "spiral-spark"
      let castingAt =
            [ i
            | (i, em) <- zip [0 :: Int ..] (V.toList (spellEmitters (a <> b)))
            , emPhase em == Casting
            ]
      case castingAt of
        [first', second'] -> do
          first' `shouldBe` 0
          second' `shouldSatisfy` (> 0)
        other -> expectationFailure ("expected two casting emitters, got " ++ show other)

    it "and the force fields of one circle move the other's casting particles" $ do
      -- 'gravity-well' carries the fields; 'ring-fire' carries none. Under
      -- ADR-0012's fused composition, ring-fire's particles must move
      -- differently inside the composition than they do alone — with the
      -- first spell's own rows left as the control.
      wellCircle <- loadCircleOf "gravity-well"
      fireCircle <- loadCircleOf "ring-fire"
      composed <- either (fail . show) pure (castSpells [wellCircle, fireCircle] ctx)
      alone <- either (fail . show) pure (castSpell (CastRequest fireCircle ctx))
      let dt = FrameInput (DeltaTime (1 / 60))
          fly n = (!! n) . iterate (advanceSpell dt)
          rowsOf s = concatMap (positions . rbParticles) (batches (observeSpell s))
          positions pb =
            [ (pbPosX pb U.! i, pbPosY pb U.! i, pbPosZ pb U.! i)
            | i <- [0 .. pbCount pb - 1]
            ]
          composedRows = rowsOf (fly 120 composed)
          aloneRows = rowsOf (fly 120 alone)
      aloneRows `shouldSatisfy` (not . null)
      -- The composition's tail rows are ring-fire's, and the field has
      -- displaced them: same count, different values.
      let tailRows = drop (length composedRows - length aloneRows) composedRows
      length tailRows `shouldBe` length aloneRows
      tailRows `shouldNotBe` aloneRows
