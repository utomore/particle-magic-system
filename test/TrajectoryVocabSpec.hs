-- | S3 (func-spec 0021 §7): the trajectory vocabulary, four to eight.
--
-- The invariant the whole analytic layer rests on is that a built-in
-- trajectory is a __closed-form function of the particle's age__ and
-- nothing else (architecture §4.6): no state, no history, no integration.
-- That is what makes @sample@ a pure function of @t@ and what makes a
-- cast replayable. So the first two properties here are stated over all
-- eight trajectories at once — same age, same output; every output
-- finite, including at absurd ages — and the rest pin down the specific
-- shape each new one promises, from its sampled values rather than from
-- its derivation.
module TrajectoryVocabSpec (spec) where

import Magic.Expr (Expr (..), ExprV3 (..))
import Magic.Particle.Analytic (trajectoryOffset)
import Magic.Rune (Trajectory (..))
import Magic.Types (V2 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

newtype ValidTrajectory = ValidTrajectory Trajectory
  deriving (Show)

-- | As 'Magic.Codec' admits them: frequencies non-negative, radii
-- positive, speeds and amplitudes free (a negative one is a mirror).
instance Arbitrary ValidTrajectory where
  arbitrary =
    ValidTrajectory
      <$> oneof
        [ Forward <$> speed
        , Spiral <$> speed <*> choose (0.05, 3) <*> freq
        , Orbit <$> choose (0.05, 3) <*> freq
        , Wave <$> speed <*> choose (-3, 3) <*> freq
        , Ballistic <$> speed <*> choose (-20, 20)
        , Pulse <$> speed <*> freq
        , Zigzag <$> speed <*> choose (-3, 3) <*> freq
        ]
    where
      speed = choose (-10, 10)
      freq = choose (0, 8)

travelOf :: Trajectory -> Float -> Float -> Float
travelOf t phase age = fst (trajectoryOffset t phase age)

lateralOf :: Trajectory -> Float -> Float -> V2
lateralOf t phase age = snd (trajectoryOffset t phase age)

finiteOffset :: (Float, V2) -> Bool
finiteOffset (travel, V2 lx ly) = all ok [travel, lx, ly]
  where
    ok v = not (isNaN v) && not (isInfinite v)

epsilon :: Float
epsilon = 1e-3

spec :: Spec
spec = describe "trajectory vocabulary, 4 -> 8 (func-spec 0021 S3)" $ do
  describe "every built-in stays a closed-form function of age" $ do
    prop "the same age yields the same offset, bit for bit" $
      \(ValidTrajectory t) ->
        forAll (choose (0, 20)) $ \age ->
          forAll (choose (0, 2 * pi)) $ \phase ->
            trajectoryOffset t phase age === trajectoryOffset t phase age

    prop "every component is finite, at ordinary and at absurd ages" $
      \(ValidTrajectory t) ->
        forAll (oneof [choose (0, 20), choose (0, 100000)]) $ \age ->
          forAll (choose (0, 2 * pi)) $ \phase ->
            finiteOffset (trajectoryOffset t phase age)

    -- Only the axial term: 'Orbit' and the weaves start out on their
    -- circle rather than at its centre, so their lateral term at age 0
    -- is deliberately non-zero.
    prop "an age of zero leaves the travel term at the origin" $
      \(ValidTrajectory t) ->
        forAll (choose (0, 2 * pi)) $ \phase ->
          travelOf t phase 0 === 0

  describe "the existing four are untouched" $ do
    it "Forward is still speed x age with no lateral term" $
      trajectoryOffset (Forward 4) 0.7 2 `shouldBe` (8, V2 0 0)

    it "Spiral still travels axially and circles laterally" $ do
      let (travel, V2 lx ly) = trajectoryOffset (Spiral 3 0.5 1) 0 1
      travel `shouldBe` 3
      abs (sqrt (lx * lx + ly * ly) - 0.5) `shouldSatisfy` (< epsilon)

    it "Orbit still has no axial travel" $
      travelOf (Orbit 0.6 0.5) 1.1 3 `shouldBe` 0

    -- The sampler evaluates a formula trajectory itself, with the
    -- particle's Expr environment; this env-free helper reports zero.
    it "Formula is still reported as a zero offset by this helper" $
      trajectoryOffset (Formula (ExprV3 (Lit 1) (Lit 2) (Lit 3))) 0 1
        `shouldBe` (0, V2 0 0)

  describe "Wave: a sine weave in one plane" $ do
    it "travels along the axis at its speed" $
      travelOf (Wave 3 0.5 1.5) 0 2 `shouldBe` 6

    prop "repeats its lateral offset every 1/freq seconds" $
      forAll (choose (0.2, 4) :: Gen Double) $ \freq ->
        forAll (choose (0, 6) :: Gen Float) $ \age ->
          let t = Wave 3 0.5 freq
              period = realToFrac (1 / freq) :: Float
              a = lateralOf t 0.3 age
              b = lateralOf t 0.3 (age + period)
              V2 ax ay = a
              V2 bx by = b
           in counterexample (show (a, b)) $
                abs (ax - bx) < epsilon && abs (ay - by) < epsilon

    it "keeps the weave inside its amplitude" $
      mapM_
        ( \age ->
            let V2 lx _ = lateralOf (Wave 3 0.5 1.5) 0.9 age
             in (age, lx) `shouldSatisfy` ((<= 0.5 + epsilon) . abs . snd)
        )
        [0, 0.05 .. 4 :: Float]

  describe "Ballistic: the analytic parabola" $ do
    it "puts the apex at v0/g, the closed-form answer" $ do
      let v0 = 8 :: Double
          g = 4 :: Double
          apex = realToFrac (v0 / g) :: Float
          at age = travelOf (Ballistic v0 g) 0 age
      mapM_
        (\age -> (age, at age) `shouldSatisfy` ((<= at apex) . snd))
        [0, 0.05 .. 2 * apex]

    it "returns to the launch height after 2·v0/g" $ do
      let v0 = 8 :: Double
          g = 4 :: Double
          apex = realToFrac (v0 / g) :: Float
      abs (travelOf (Ballistic v0 g) 0 (2 * apex)) `shouldSatisfy` (< epsilon)

    it "degenerates to Forward at zero gravity" $
      travelOf (Ballistic 5 0) 0 3 `shouldBe` travelOf (Forward 5) 0 3

  describe "Pulse: surge and coast, never backwards" $ do
    prop "displacement is monotone non-decreasing in age" $
      forAll (choose (0.1, 6)) $ \meanSpeed ->
        forAll (choose (0, 4)) $ \freq ->
          forAll (choose (0, 2 * pi)) $ \phase ->
            let at age = travelOf (Pulse meanSpeed freq) phase age
                ages = [0, 0.02 .. 4 :: Float]
                xs = map at ages
             in counterexample (show (meanSpeed, freq, phase)) $
                  and (zipWith (\a b -> b >= a - epsilon) xs (drop 1 xs))

    it "averages out to the mean speed over whole periods" $ do
      let meanSpeed = 2 :: Double
          freq = 1 :: Double
          -- Four whole periods; the oscillating term cancels.
          age = 4 :: Float
      abs (travelOf (Pulse meanSpeed freq) 0 age - realToFrac meanSpeed * age)
        `shouldSatisfy` (< epsilon)

    it "stands still at zero frequency and zero phase — the degenerate case" $
      travelOf (Pulse 3 0) 0 5 `shouldBe` 0

  describe "Zigzag: hard corners, not a weave" $ do
    prop "reverses direction freq times per second" $
      forAll (elements [1, 2, 4 :: Double]) $ \freq ->
        let seconds = 4 :: Float
            t = Zigzag 3 0.5 freq
            samples =
              [ let V2 lx _ = lateralOf t 0 age in lx
              | age <- [0, 0.001 .. seconds]
              ]
            deltas = zipWith (-) (drop 1 samples) samples
            reversals =
              length
                [ ()
                | (a, b) <- zip deltas (drop 1 deltas)
                , a /= 0 && b /= 0 && signum a /= signum b
                ]
            expected = round (realToFrac freq * seconds) :: Int
         in counterexample (show (freq, reversals, expected)) $
              abs (reversals - expected) <= 1

    it "keeps the swing inside its amplitude" $
      mapM_
        ( \age ->
            let V2 lx _ = lateralOf (Zigzag 3 0.5 2) 0.4 age
             in (age, lx) `shouldSatisfy` ((<= 0.5 + epsilon) . abs . snd)
        )
        [0, 0.01 .. 4 :: Float]

    it "travels along the axis at its speed, like Wave" $
      travelOf (Zigzag 3 0.5 2) 1.3 2 `shouldBe` 6
