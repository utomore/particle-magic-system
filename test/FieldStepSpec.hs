-- | S3 (func-spec 0007 §8): the integration state machine in isolation —
-- 'stepSlot' as a pure per-slot transition and 'step' as its lifting to a
-- whole cast, with no sampler or compiler in sight. The four laws of
-- ADR-0010 D1/D3 are asserted here; §8's S6/S8 then check they survive
-- being wired to real data.
module FieldStepSpec (spec) where

import qualified Data.Vector as V
import Magic.Particle.Field
  ( FieldState (..)
  , SlotState (..)
  , displacementsInOrder
  , emptyFieldState
  , quiescent
  , step
  , stepSlot
  )
import Magic.Rune (ForceField (..))
import Magic.Types (DeltaTime (..), V3 (..), norm, vscale)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (choose, forAll)

gravity :: ForceField
gravity = Gravity (V3 0 (-9.8) 0)

-- | Run one slot for @n@ steps of @dt@, the particle alive throughout
-- with ages @dt, 2·dt, …@ (born on step 1) and a fixed base position.
runSteps :: [ForceField] -> Double -> Int -> Maybe (Double, SlotState)
runSteps fields dt n = foldl one Nothing [1 .. n]
  where
    one prev k = stepSlot fields (DeltaTime dt) (Just (fromIntegral k * dt, V3 0 0 0)) prev

dispOf :: Maybe (Double, SlotState) -> V3
dispOf = maybe (V3 0 0 0) (ssDisp . snd)

velOf :: Maybe (Double, SlotState) -> V3
velOf = maybe (V3 0 0 0) (ssVel . snd)

-- | Free-fall displacement after simulating a fixed total time with the
-- given step size.
fallAfter :: Double -> Double -> V3
fallAfter total dt = dispOf (runSteps [gravity] dt (round (total / dt)))

-- | The exact analytic free-fall displacement: ½·a·t².
exactFall :: Float -> V3
exactFall t = vscale (0.5 * t * t) (V3 0 (-9.8) 0)

spec :: Spec
spec = describe "force-field integration state machine (spec 0007 S3)" $ do
  describe "the zero-field law (ADR-0010 D9)" $ do
    prop "with no fields the displacement is exactly zero, however many steps run" $
      forAll ((,) <$> choose (1, 200 :: Int) <*> choose (0.001, 0.2)) $ \(n, dt) ->
        dispOf (runSteps [] dt n) == V3 0 0 0 && velOf (runSteps [] dt n) == V3 0 0 0

  describe "semi-implicit Euler under constant gravity (ADR-0010 D1)" $ do
    it "starts at rest, coincident with the analytic position" $ do
      dispOf (runSteps [gravity] 0.01 1) `shouldBe` V3 0 0 0
      velOf (runSteps [gravity] 0.01 1) `shouldBe` V3 0 0 0

    it "falls, and falls only along the acceleration" $ do
      let V3 x y z = dispOf (runSteps [gravity] 0.01 100)
      y `shouldSatisfy` (< 0)
      (x, z) `shouldBe` (0, 0)

    it "converges to the analytic parabola as dt goes to 0 (first order)" $ do
      let target = exactFall 1.0
          err dt = norm (fallAfter 1.0 dt - target)
          (e1, e2, e3) = (err 0.1, err 0.01, err 0.001)
      e1 `shouldSatisfy` (> e2)
      e2 `shouldSatisfy` (> e3)
      -- 1% of the exact 4.9 m drop at the finest step.
      e3 `shouldSatisfy` (< 0.01 * norm target)

    it "halving dt roughly halves the error (first-order rate)" $ do
      let target = exactFall 1.0
          err dt = norm (fallAfter 1.0 dt - target)
          ratio = err 0.004 / err 0.002
      ratio `shouldSatisfy` (\r -> r > 1.7 && r < 2.3)

  describe "death and birth (ADR-0010 D3)" $ do
    prop "a dead or unborn slot has no state at all" $
      forAll (choose (1, 50 :: Int)) $ \n ->
        stepSlot [gravity] (DeltaTime 0.02) Nothing (runSteps [gravity] 0.02 n) == Nothing

    it "a slot that comes back after dying restarts from rest" $ do
      let alive = runSteps [gravity] 0.02 20
          dead = stepSlot [gravity] (DeltaTime 0.02) Nothing alive
          reborn = stepSlot [gravity] (DeltaTime 0.02) (Just (0.02, V3 1 2 3)) dead
      dispOf alive `shouldNotBe` V3 0 0 0
      dead `shouldBe` Nothing
      reborn `shouldBe` Just (0.02, quiescent)

    prop "an age that goes backwards wipes the history (respawn)" $
      forAll ((,) <$> choose (2, 60 :: Int) <*> choose (0.0, 0.9)) $ \(n, backTo) ->
        let alive = runSteps [gravity] 0.02 n
            lastAge = fromIntegral n * 0.02
            respawned =
              stepSlot [gravity] (DeltaTime 0.02) (Just (backTo * lastAge, V3 0 0 0)) alive
         in backTo * lastAge >= lastAge -- generator can't produce this, but stay total
              || respawned == Just (backTo * lastAge, quiescent)

    it "a non-decreasing age keeps integrating (same generation)" $ do
      let alive = runSteps [gravity] 0.02 10
          continued = stepSlot [gravity] (DeltaTime 0.02) (Just (0.22, V3 0 0 0)) alive
      norm (dispOf continued) `shouldSatisfy` (> norm (dispOf alive))

  describe "the field sampling point (ADR-0010 D1)" $
    it "reads the fields at the rendered position (base + displacement), not the base" $ do
      -- A strong attractor sitting exactly where the particle has been
      -- displaced to: sampling at the base position would still pull, but
      -- sampling at the rendered position sits at the singular center.
      let fields = [Gravity (V3 0 (-10) 0)]
          afterOne = stepSlot fields (DeltaTime 0.1) (Just (0.1, V3 0 0 0)) Nothing
          afterTwo = stepSlot fields (DeltaTime 0.1) (Just (0.2, V3 0 0 0)) afterOne
          probe = [PointAttractor (V3 0 (-0.1) 0) 100 0.01]
          fromBase = stepSlot probe (DeltaTime 0.1) (Just (0.2, V3 0 0 0)) afterTwo
      -- afterTwo has displacement (0, -0.1, 0); the probe's center is
      -- exactly there, so the acceleration it feels is zero.
      dispOf afterTwo `shouldBe` V3 0 (-0.1) 0
      velOf fromBase `shouldBe` velOf afterTwo

  describe "FieldState: shape and slot independence" $ do
    it "emptyFieldState gives one row per emitter, one slot per particle, all empty" $ do
      let FieldState st = emptyFieldState [2, 3, 0]
      V.length st `shouldBe` 3
      map V.length (V.toList st) `shouldBe` [2, 3, 0]
      concatMap V.toList (V.toList st) `shouldBe` replicate 5 Nothing

    it "step advances only the slots the caller reports alive" $ do
      let st0 = emptyFieldState [2, 1]
          inputs =
            V.fromList
              [ V.fromList [Just (0.1, V3 0 0 0), Nothing]
              , V.fromList [Just (0.1, V3 0 0 0)]
              ]
          st1 = step [gravity] (DeltaTime 0.1) inputs st0
          st2 = step [gravity] (DeltaTime 0.1) (bump inputs) st1
          bump = V.map (V.map (fmap (\(a, p) -> (a + 0.1, p))))
      displacementsInOrder st1 [(0, 0), (0, 1), (1, 0)]
        `shouldBe` [V3 0 0 0, V3 0 0 0, V3 0 0 0]
      let ds = displacementsInOrder st2 [(0, 0), (0, 1), (1, 0)]
      (ds !! 0) `shouldSatisfy` (\v -> norm v > 0)
      (ds !! 1) `shouldBe` V3 0 0 0
      (ds !! 2) `shouldBe` (ds !! 0)

    it "displacementsInOrder follows the requested order and zeroes unknown slots" $ do
      let st0 = emptyFieldState [1, 1]
          alive a =
            V.fromList [V.fromList [Just (a, V3 0 0 0)], V.fromList [Just (a, V3 0 5 0)]]
          st1 = step [gravity] (DeltaTime 0.1) (alive 0.1) st0
          st2 = step [PointAttractor (V3 0 0 0) 5 0.5] (DeltaTime 0.1) (alive 0.2) st1
          forward = displacementsInOrder st2 [(0, 0), (1, 0)]
          reversed' = displacementsInOrder st2 [(1, 0), (0, 0)]
      reverse reversed' `shouldBe` forward
      displacementsInOrder st2 [(9, 9), (0, 42)] `shouldBe` [V3 0 0 0, V3 0 0 0]

  describe "no fields, real shape" $
    it "step with an empty field list leaves every displacement at zero" $ do
      let st0 = emptyFieldState [3]
          inputs a = V.fromList [V.fromList [Just (a, V3 1 2 3) | _ <- [1 :: Int .. 3]]]
          stN = foldl (\s k -> step [] (DeltaTime 0.05) (inputs (0.05 * fromIntegral k)) s) st0 [1 .. 40 :: Int]
      displacementsInOrder stN [(0, 0), (0, 1), (0, 2)] `shouldBe` replicate 3 (V3 0 0 0)
