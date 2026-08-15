-- | S2 (func-spec 0017 §7): the three laws the persistence round is
-- actually about, checked end to end through the untouched sampler.
--
--   * /persistence/ — the sigil has live particles at every instant of
--     the cast, not just during the prelude;
--   * /no collapse/ — those particles are still out on their strokes,
--     not piled onto the axis (the failure mode that made "just extend
--     the envelope" wrong on its own);
--   * /the sigil ignores force fields/ — ADR-0010 D6 keyed the field
--     layer on 'emPhase', so a gravity well bends the spell and leaves
--     the drawn circle exactly where it was drawn. That guarantee used
--     to be untestable past @castStart@ because nothing formation-shaped
--     was alive then; this round makes it a real, load-bearing law.
module PersistWiringSpec (spec) where

import qualified Data.ByteString as BS
import Data.Maybe (isJust)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , ParticleBudget (..)
  , Phase (..)
  , PhasePlan (..)
  , compile
  )
import Magic.Interface
  ( ActiveSpell
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , advanceSpell
  , castSpell
  , observeSpell
  )
import Magic.Particle.Analytic (aliveSlots, particleAge, particlePosition, sample)
import Magic.Particle.Buffer (ParticleBuffer (..), bufferInvariant)
import Magic.Rune (Element (..), EssenceRune (..), ForceField (..), NodeRune (..))
import Magic.Sigil (SigilStroke (..), sigilPlan, spStrokes, strokeRadius)
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..), norm)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (sample)

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 4242}

compiled :: Circle -> CompiledSpell
compiled = either (error . show) id . compile

circleFile :: String -> IO Circle
circleFile name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

sigils :: [String]
sigils = ["bare-sigil", "grand-sigil", "lattice-seal", "soft-bloom"]

phased :: PhaseConfig
phased = PhaseConfig (Seconds 1.2) (Seconds 0.6)

-- | Phases + fields: the ADR-0010 D6 fixture, now meaningful for the
-- whole cast rather than only for the prelude.
fieldedCircle :: Circle
fieldedCircle =
  emptyCircle
    { circlePhases = Just phased
    , circleFields = [Gravity (V3 0 (-9) 0), PointAttractor (V3 0 0 3) 8 0.5]
    , core =
        Core
          (Just (EssenceRune Fire 1.0))
          (Nodes (Just (DirBias 0.1)) Nothing Nothing Nothing)
    }

formationIndices :: CompiledSpell -> [Int]
formationIndices spell =
  [e | (e, em) <- zip [0 ..] (V.toList (spellEmitters spell)), emPhase em /= Casting]

-- | The boundary ring: the first formation emitter, present on every
-- phased circle (spec 0006's judgment call, kept by 0016).
boundaryIndex :: CompiledSpell -> Int
boundaryIndex spell = case formationIndices spell of
  (e : _) -> e
  [] -> error "expected a formation emitter"

-- | Live formation slots at @t@.
liveFormation :: CompiledSpell -> Double -> [(Int, Int)]
liveFormation spell t =
  [slot | slot@(e, _) <- aliveSlots spell (Time t), e `elem` formationIndices spell]

-- | Sample times spread across the whole cast, from the first frame to
-- just before the last particle dies.
castTimes :: CompiledSpell -> [Double]
castTimes spell =
  let Seconds end = ppEnd (spellPhases spell)
   in [end * f | f <- [0.02, 0.06 .. 0.98]]

-- | Times strictly inside the Casting window.
castingTimes :: CompiledSpell -> [Double]
castingTimes spell =
  let Seconds start = ppConvergeEnd (spellPhases spell)
      Seconds end = ppCastingEnd (spellPhases spell)
   in [start + (end - start) * f | f <- [0.05, 0.25, 0.5, 0.75, 0.95]]

radiusOf :: CastContext -> V3 -> Float
radiusOf c p = norm (p - casterPos c)

spec :: Spec
spec = describe "the sigil persists through the cast (func-spec 0017 S2)" $ do
  describe "persistence" $ do
    it "every shipped sigil has live formation particles at every instant of its cast" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            sequence_
              [ liveFormation spell t `shouldSatisfy` (not . null)
              | t <- castTimes spell
              ]
        )
        sigils

    it "the sigil is still alive well past castStart (it used to be gone)" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            let Seconds castStart = ppConvergeEnd (spellPhases spell)
            sequence_
              [ liveFormation spell t `shouldSatisfy` (not . null)
              | t <- [castStart + 0.01, castStart + 0.5, castStart + 1.0]
              ]
        )
        sigils

    it "and it is gone once the spell is over" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            let Seconds end = ppEnd (spellPhases spell)
            liveFormation spell (end + 0.01) `shouldBe` []
        )
        sigils

    it "the last formation particle dies at ppEnd, not before" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            let Seconds end = ppEnd (spellPhases spell)
                em = spellEmitters spell V.! boundaryIndex spell
                aliveAt t =
                  any
                    (\i -> isJust (particleAge (emSpawn em) (emCount em) i (Time t)))
                    [0 .. emCount em - 1]
            aliveAt (end - 0.01) `shouldBe` True
            aliveAt (end + 0.01) `shouldBe` False
        )
        sigils

  describe "no collapse" $ do
    it "during Casting the boundary ring is still a ring, not a point on the axis" $
      mapM_
        ( \name -> do
            circle <- circleFile name
            let spell = compiled circle
                em = spellEmitters spell V.! boundaryIndex spell
                stroke = V.head (spStrokes (sigilPlan circle))
            sequence_
              [ let live =
                      [ radiusOf ctx (particlePosition ctx (Time t) em i age)
                      | i <- [0 .. emCount em - 1]
                      , Just age <- [particleAge (emSpawn em) (emCount em) i (Time t)]
                      ]
                 in case live of
                      [] -> expectationFailure (name ++ ": boundary ring dead during Casting")
                      rs -> do
                        -- Still out at the silhouette radius...
                        maximum rs `shouldSatisfy` (> 0.9 * skRadius stroke)
                        -- ...and inside the same conservative bound.
                        maximum rs `shouldSatisfy` (<= strokeRadius stroke + 1e-3)
              | t <- castingTimes spell
              ]
        )
        sigils

    it "a formation particle does not move at all over its life (it holds where it was drawn)" $ do
      spell <- compiled <$> circleFile "lattice-seal"
      let em = spellEmitters spell V.! boundaryIndex spell
          Seconds life = envLifetime (emSpawn em)
          posAt i age = particlePosition ctx (Time 0) em i age
      sequence_
        [ norm (posAt 3 0 - posAt 3 (life * f)) `shouldSatisfy` (< 1e-5)
        | f <- [0.25, 0.5, 0.75, 1.0]
        ]

  describe "the sigil ignores force fields (ADR-0010 D6, now testable past castStart)" $ do
    it "every formation row is exactly undisplaced, all the way through Casting" $ do
      let spell = compiled fieldedCircle
      spell0 <- either (fail . show) pure (castSpell (CastRequest fieldedCircle ctx))
      sequence_
        [ let FrameOutput bs = observeSpell (walk spell0 steps)
              observed = concatMap (positionsOf . rbParticles) bs
              t = timeAfter steps
              analytic = positionsOf (sample spell ctx t)
              formation = formationIndices spell
              rigid =
                [ (o, a)
                | ((e, _), o, a) <- zip3 (aliveSlots spell t) observed analytic
                , e `elem` formation
                ]
           in do
                length observed `shouldBe` length (aliveSlots spell t)
                length rigid `shouldSatisfy` (> 0)
                map fst rigid `shouldBe` map snd rigid
        | steps <- [40, 60, 80, 100 :: Int]
        ]

    it "the casting rows, meanwhile, really are bent by the fields" $ do
      let spell = compiled fieldedCircle
      spell0 <- either (fail . show) pure (castSpell (CastRequest fieldedCircle ctx))
      let FrameOutput bs = observeSpell (walk spell0 80)
          observed = concatMap (positionsOf . rbParticles) bs
          analytic = positionsOf (sample spell ctx (timeAfter 80))
      length observed `shouldBe` length analytic
      observed `shouldNotBe` analytic

  describe "invariants the round must not disturb" $ do
    it "the budget is unchanged: Sigma emCount, index-aligned, same total" $
      mapM_
        ( \name -> do
            spell <- compiled <$> circleFile name
            let counts = map emCount (V.toList (spellEmitters spell))
            spellBudget spell `shouldBe` sum counts
            U.toList (budgetPerEmitter (spellBudgetPlan spell)) `shouldBe` counts
            budgetTotal (spellBudgetPlan spell) `shouldBe` spellBudget spell
        )
        sigils

    prop "the buffer invariant holds across the whole cast, budget included" $
      forAll (choose (-1, 12)) $ \t ->
        let spell = compiled fieldedCircle
            buf = sample spell ctx (Time t)
         in property (bufferInvariant buf && pbCount buf <= spellBudget spell)

    prop "sampling stays bit-for-bit deterministic" $
      forAll (choose (-1, 12)) $ \t ->
        let spell = compiled fieldedCircle
         in sample spell ctx (Time t) === sample spell ctx (Time t)

positionsOf :: ParticleBuffer -> [V3]
positionsOf buf =
  [V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) | j <- [0 .. pbCount buf - 1]]

-- | The host loop's fixed step, @steps@ times.
walk :: ActiveSpell -> Int -> ActiveSpell
walk spell steps = foldl (\s _ -> advanceSpell (FrameInput (DeltaTime dt)) s) spell [1 .. steps]

-- | The step 'walk' uses; the analytic comparison accumulates the same
-- way so the two clocks agree bit for bit.
dt :: Double
dt = 0.05

timeAfter :: Int -> Time
timeAfter steps = Time (foldl (\acc _ -> acc + dt) 0 [1 .. steps])
