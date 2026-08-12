-- | T-S4 (func-spec 0002 §8): envelope scheduling boundaries and
-- trajectory evaluation.
module EnvelopeSpec (spec) where

import Data.Maybe (isJust, isNothing)
import Magic.Compile (Envelope (..))
import Magic.Particle.Analytic (firstBirth, particleAge, trajectoryOffset)
import Magic.Rune (Trajectory (..))
import Magic.Types (Seconds (..), Time (..), V2 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | The plain-discharge envelope of §4.5.
env0 :: Envelope
env0 = Envelope {envDelay = Seconds 0, envDuration = Seconds 8, envLifetime = Seconds 2}

genEnvelope :: Gen Envelope
genEnvelope = do
  delay <- choose (0, 4)
  duration <- choose (0.5, 10)
  lifetime <- choose (0.1, 5)
  pure (Envelope (Seconds delay) (Seconds duration) (Seconds lifetime))

genCountIndex :: Gen (Int, Int)
genCountIndex = do
  count <- chooseInt (1, 512)
  i <- chooseInt (0, count - 1)
  pure (count, i)

spec :: Spec
spec = describe "envelope scheduling and trajectory evaluation (spec 0002 S4)" $ do
  prop "particle i is first born at envDelay + (i/count)·envLifetime" $
    forAll ((,) <$> genEnvelope <*> genCountIndex) $
      \(env, (count, i)) ->
        let Seconds delay = envDelay env
            Seconds lifetime = envLifetime env
            expected = delay + (fromIntegral i / fromIntegral count) * lifetime
         in abs (firstBirth env count i - expected) < 1e-9

  prop "before envDelay no particle is alive" $
    forAll ((,) <$> genEnvelope <*> genCountIndex) $
      \(env, (count, i)) ->
        let Seconds delay = envDelay env
         in forAll (choose (-1, delay - 1e-6)) $ \t ->
              isNothing (particleAge env count i (Time t))

  prop "at its first birth instant a particle is alive with age 0" $
    forAll ((,) <$> genEnvelope <*> genCountIndex) $
      \(env, (count, i)) ->
        let birth = firstBirth env count i
         in case particleAge env count i (Time birth) of
              Just age -> abs age < 1e-9
              Nothing ->
                -- Only legitimate when the birth already falls outside the
                -- spawn window (tiny durations).
                let Seconds delay = envDelay env
                    Seconds duration = envDuration env
                 in birth >= delay + duration

  prop "after envDelay+envDuration+envLifetime everything is dead" $
    forAll ((,) <$> genEnvelope <*> genCountIndex) $
      \(env, (count, i)) ->
        let Seconds delay = envDelay env
            Seconds duration = envDuration env
            Seconds lifetime = envLifetime env
            end = delay + duration + lifetime
         in forAll (choose (end + 1e-6, end + 20)) $ \t ->
              isNothing (particleAge env count i (Time t))

  it "the plain-discharge envelope: alive mid-window, dead at 10s, age cycles" $ do
    -- Particle 0 of 256: born at 0, lifetime 2, window [0, 8).
    particleAge env0 256 0 (Time 0) `shouldBe` Just 0
    particleAge env0 256 0 (Time 3) `shouldBe` Just 1 -- second cycle, age 1
    particleAge env0 256 0 (Time 7.5) `shouldBe` Just 1.5
    -- Its last respawn is at 6 (8 would fall outside the window).
    particleAge env0 256 0 (Time 8.5) `shouldSatisfy` isNothing
    particleAge env0 256 0 (Time 10) `shouldSatisfy` isNothing
    -- A late particle: i = 255 first born at ~1.992, alive shortly before 10.
    particleAge env0 256 255 (Time 9.9) `shouldSatisfy` isJust

  prop "Forward: travel == speed × age, zero lateral offset" $
    forAll ((,) <$> choose (-20, 20) <*> choose (0, 10 :: Double)) $
      \(speed, ageD) ->
        let age = realToFrac ageD :: Float
            (travel, lateral) = trajectoryOffset (Forward speed) 0 age
         in abs (travel - realToFrac speed * age) < 1e-3 && lateral == V2 0 0

  prop "Spiral: lateral radius is constantly the configured radius" $
    forAll ((,,,) <$> choose (0.1, 10) <*> choose (0.1, 5) <*> choose (0, 2 * pi :: Double) <*> choose (0, 10 :: Double)) $
      \(radius, freq, phase, ageD) ->
        let age = realToFrac ageD :: Float
            (_, V2 lx ly) = trajectoryOffset (Spiral 3 radius freq) (realToFrac phase) age
            r = sqrt (lx * lx + ly * ly)
         in abs (r - realToFrac radius) < 1e-2

  prop "Orbit: never travels along the axis" $
    forAll ((,,) <$> choose (0.1, 10) <*> choose (0.1, 5) <*> choose (0, 10 :: Double)) $
      \(radius, freq, ageD) ->
        let (travel, _) = trajectoryOffset (Orbit radius freq) 0 (realToFrac ageD)
         in travel == 0
