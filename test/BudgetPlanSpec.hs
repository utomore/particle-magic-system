-- | S7 (func-spec 0010 §7): the structured particle budget and the
-- conservative spatial extent.
--
-- Two additions, two different kinds of claim:
--
--   * 'ParticleBudget' is bookkeeping — a breakdown of a number the
--     compiler already had. Its invariants are exact equalities, and they
--     have to hold for every circle shape (phased, fieldless, dense, the
--     empty one).
--
--   * 'emitterBounds' is an /over/-approximation, and the only thing an
--     over-approximation may never do is under-approximate. So the law is
--     containment: every position the sampler can produce, at any age in
--     the horizon, for any particle index, lies inside the box. It is
--     checked against 'Magic.Particle.Analytic.particlePosition' itself,
--     not against a re-derivation of it.
--
-- Both are also exercised through 'Magic.Interface', since the point of
-- the round is that a host can reach them.
module BudgetPlanSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , ParticleBudget (..)
  , budgetCap
  , compile
  , emitterBounds
  )
import Magic.Expr (Expr, ExprV3 (..))
import Magic.Expr.Parse (parseExpr)
import qualified Magic.Interface as I
import Magic.Particle.Analytic (aliveRanges, particleAge, particlePosition)
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , EssenceRune (..)
  , FaceShape (..)
  , ForceField (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V2 (..), V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

ctx :: CastContext
ctx = CastContext {casterPos = V3 1 (-2) 0.5, casterFacing = V3 0 1 0, seed = Seed 31337}

examples :: [String]
examples =
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

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

loadCompiled :: String -> IO CompiledSpell
loadCompiled name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (compile circle)

-- | Parse a formula the way the codec does, so the fixtures read like the
-- JSON a player writes.
exprOf :: String -> Expr
exprOf s = either (error . show) id (parseExpr (T.pack s))

-- | Synthetic circles covering what the shipped examples do not: every
-- face shape, every trajectory kind, radial radiation, node drift, a
-- range curve, a convergence curve, phases, fields and the budget cap.
synthetic :: [(String, Circle)]
synthetic =
  [ ("empty core", emptyCircle)
  ,
    ( "diamond + spiral + drift"
    , emptyCircle
        { outerRings = TwoOf (Just (ShapeRune (Diamond 0.9))) (Just (RadiateRune RadialOutward))
        , innerRings = TwoOf (Just (TrajectoryRune (Spiral 2 0.4 3))) Nothing
        , core =
            Core
              (Just (EssenceRune Fire 1))
              (Nodes (Just (DirBias 0.7)) Nothing (Just (DirBias (-0.4))) Nothing)
        }
    )
  ,
    ( "rect + orbit"
    , emptyCircle
        { outerRings = TwoOf (Just (ShapeRune (Rect (V2 1.5 0.4)))) Nothing
        , innerRings = TwoOf (Just (TrajectoryRune (Orbit 0.8 2))) Nothing
        }
    )
  ,
    ( "hollow square + range curve"
    , emptyCircle
        { outerRings =
            TwoOf
              (Just (ShapeRune (HollowSquare 1.2)))
              (Just (RangeRune (exprOf "1 + sin(t)*0.5")))
        }
    )
  ,
    ( "ring + converge curve"
    , emptyCircle
        { outerRings = TwoOf (Just (ShapeRune (Ring 0.4 1.1))) Nothing
        , interLayer = Just (ConvergeRune (exprOf "1 - life*2"))
        }
    )
  ,
    ( "formula trajectory"
    , emptyCircle
        { innerRings =
            TwoOf
              (Just (FormulaRune (formulaOf "sin(t*3)*0.6" "cos(t*2)*0.6" "t*2")))
              Nothing
        }
    )
  ,
    ( "phased with fields"
    , emptyCircle
        { circlePhases = Just (PhaseConfig (Seconds 0.8) (Seconds 0.4))
        , circleFields = [Gravity (V3 0 (-9) 0)]
        , core =
            Core
              (Just (EssenceRune Water 2))
              (Nodes (Just (DirBias 0.3)) (Just (DirBias 0.3)) Nothing Nothing)
        }
    )
  ,
    ( "a dense core"
    , emptyCircle
        { core = Core (Just (EssenceRune Lightning 16)) (Nodes Nothing Nothing Nothing Nothing)
        }
    )
  ]

-- | A circle whose casting emitter is exactly 'budgetCap' particles —
-- derived from the cap rather than written out, so raising the cap
-- (func-spec 0012 S1) moves this fixture with it instead of stranding it.
atCapCircle :: Circle
atCapCircle =
  emptyCircle
    { core =
        Core
          (Just (EssenceRune Lightning (fromIntegral budgetCap / 256)))
          (Nodes Nothing Nothing Nothing Nothing)
    }

formulaOf :: String -> String -> String -> ExprV3
formulaOf x y z = ExprV3 (exprOf x) (exprOf y) (exprOf z)

syntheticNamed :: String -> Circle
syntheticNamed name = case lookup name synthetic of
  Just circle -> circle
  Nothing -> error ("BudgetPlanSpec: no synthetic fixture named " ++ show name)

-- Containment ------------------------------------------------------------------

inBox :: (V3, V3) -> V3 -> Bool
inBox (V3 lx ly lz, V3 hx hy hz) (V3 x y z) =
  x >= lx && x <= hx && y >= ly && y <= hy && z >= lz && z <= hz

finiteBox :: (V3, V3) -> Bool
finiteBox (lo, hi) = all ok [lo, hi]
  where
    ok (V3 x y z) = all (\v -> not (isNaN v) && not (isInfinite v)) [x, y, z]

-- | Every position the sampler can produce for this spell, paired with
-- the emitter whose box has to contain it. 33 sample times across the
-- whole lifetime, every live index at each of them — the same
-- 'aliveRanges' windows the sampler walks.
sampledPositions :: CompiledSpell -> [(Int, V3)]
sampledPositions spell =
  [ (e, particlePosition ctx t em i age)
  | (e, em) <- zip [0 ..] (V.toList (spellEmitters spell))
  , k <- [0 .. 32 :: Int]
  , let t = Time (horizon * fromIntegral k / 32)
  , (lo, hi) <- aliveRanges (emSpawn em) (emCount em) t
  , i <- [lo .. hi - 1]
  , Just age <- [particleAge (emSpawn em) (emCount em) i t]
  ]
  where
    Seconds horizon = spellLifetime spell

boxesOf :: CompiledSpell -> [(V3, V3)]
boxesOf spell =
  [emitterBounds ctx (spellLifetime spell) em | em <- V.toList (spellEmitters spell)]

containment :: CompiledSpell -> Expectation
containment spell = do
  let boxes = boxesOf spell
      positions = sampledPositions spell
      escapes = [(e, p) | (e, p) <- positions, not (inBox (boxes !! e) p)]
  length boxes `shouldBe` V.length (spellEmitters spell)
  case escapes of
    [] -> pure ()
    ((e, p) : _) ->
      expectationFailure
        ( "emitter "
            ++ show e
            ++ " sampled "
            ++ show p
            ++ " outside its bounds "
            ++ show (boxes !! e)
            ++ " ("
            ++ show (length escapes)
            ++ " of "
            ++ show (length positions)
            ++ " positions escaped)"
        )

budgetInvariants :: CompiledSpell -> Expectation
budgetInvariants spell = do
  let plan = spellBudgetPlan spell
      counts = map emCount (V.toList (spellEmitters spell))
  U.toList (budgetPerEmitter plan) `shouldBe` counts
  U.length (budgetPerEmitter plan) `shouldBe` V.length (spellEmitters spell)
  U.sum (budgetPerEmitter plan) `shouldBe` budgetTotal plan
  budgetTotal plan `shouldBe` spellBudget spell
  budgetTotal plan `shouldSatisfy` (<= I.maxSpellParticles)

castOf :: Circle -> I.ActiveSpell
castOf circle =
  either (error . show) id (I.castSpell I.CastRequest {I.circleOf = circle, I.ctxOf = ctx})

spec :: Spec
spec = describe "ParticleBudget and emitterBounds (func-spec 0010 §7 S7)" $ do
  describe "ParticleBudget invariants" $ do
    it "hold for every shipped example" $
      mapM_ (\name -> loadCompiled name >>= budgetInvariants) examples

    mapM_
      (\(title, circle) -> it ("hold for " ++ title) (budgetInvariants (compiledOf circle)))
      synthetic

    it "a phased circle really does have more than one emitter (not vacuous)" $ do
      let spell = compiledOf (syntheticNamed "phased with fields")
      V.length (spellEmitters spell) `shouldSatisfy` (> 1)
      U.length (budgetPerEmitter (spellBudgetPlan spell)) `shouldSatisfy` (> 1)

  describe "the containment law: every sampled position is inside its emitter's box" $ do
    it "for every shipped example" $
      mapM_ (\name -> loadCompiled name >>= containment) examples

    mapM_
      (\(title, circle) -> it ("for " ++ title) (containment (compiledOf circle)))
      synthetic

    it "and the check is not vacuous (thousands of positions, real boxes)" $ do
      spell <- loadCompiled "ring-fire"
      length (sampledPositions spell) `shouldSatisfy` (> 1000)
      all finiteBox (boxesOf spell) `shouldBe` True

    it "the boxes stay finite for every shipped example" $
      mapM_
        (\name -> do spell <- loadCompiled name; all finiteBox (boxesOf spell) `shouldBe` True)
        examples

    prop "and for any horizon, not just the spell's own lifetime" $
      forAll (choose (0, 30)) $ \h -> do
        let spell = compiledOf (syntheticNamed "diamond + spiral + drift")
            boxes = [emitterBounds ctx (Seconds h) em | em <- V.toList (spellEmitters spell)]
            positions =
              [ (e, particlePosition ctx t em i age)
              | (e, em) <- zip [0 ..] (V.toList (spellEmitters spell))
              , k <- [0 .. 16 :: Int]
              , let t = Time (h * fromIntegral k / 16)
              , (lo, hi) <- aliveRanges (emSpawn em) (emCount em) t
              , i <- [lo .. hi - 1]
              , Just age <- [particleAge (emSpawn em) (emCount em) i t]
              ]
        property (all (\(e, p) -> inBox (boxes !! e) p) positions)

  describe "reachable through Magic.Interface (the additive exports)" $ do
    it "budgetPlanOf agrees with the compiled plan" $ do
      let circle = syntheticNamed "empty core"
          spell = castOf circle
      I.budgetPlanOf spell `shouldBe` spellBudgetPlan (compiledOf circle)

    it "maxSpellParticles is the compile-time cap" $ do
      -- Stated as the law rather than as the number: func-spec 0010 left
      -- the value at 4096 and func-spec 0012 S1 raised it to 16384, and
      -- neither move should have needed an edit here. The sentinel for
      -- the value itself lives in @CapacitySpec@, in one place.
      I.maxSpellParticles `shouldBe` budgetCap
      budgetTotal (I.budgetPlanOf (castOf atCapCircle)) `shouldBe` I.maxSpellParticles

    it "emittersOf feeds emitterBounds, and the boxes contain the sample" $ do
      let circle = syntheticNamed "diamond + spiral + drift"
          spell = castOf circle
          compiled = compiledOf circle
          boxes = [I.emitterBounds ctx (spellLifetime compiled) em | em <- I.emittersOf spell]
      boxes `shouldBe` boxesOf compiled
      all (\(e, p) -> inBox (boxes !! e) p) (sampledPositions compiled) `shouldBe` True

    it "the emitter list lines up with the budget breakdown" $ do
      let spell = castOf (syntheticNamed "phased with fields")
      length (I.emittersOf spell)
        `shouldBe` U.length (budgetPerEmitter (I.budgetPlanOf spell))
