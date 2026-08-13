-- | T8 (func-spec 0001 §8): hot reload — the pure decision function over
-- mtime sequences, and the loop re-casting when the scripted FileWatch
-- reports a change at frame k.
module HotReloadSpec (spec) where

import App.HotReload (reloadPoints, stampChanged)
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.TestInterp
  ( runClockVirtual
  , runFileWatchScript
  , runRaylibHeadless
  )
import Effectful (runPureEff)
import Magic.Codec (saveCircle)
import Magic.Interface (CastContext (..), Seed (..), Time (..), V3 (..), emptyCircle)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , -- func-spec 0005 §4.4 turned the single path into the demo's spell
      -- list; a one-element list is the 0001 behaviour exactly.
      lcSpellPaths = ["virtual-spell.json"]
    , lcSpellIndex = 0
    , lcCamera = defaultCamera
    , lcCastCtx =
        CastContext
          { casterPos = V3 0 0 0
          , casterFacing = V3 0 1 0
          , seed = Seed 7
          }
    , lcWindowSize = (640, 360)
    , lcWindowTitle = "headless"
    }

runWithScript :: Int -> [Bool] -> LoopStats
runWithScript frames script =
  fst
    . runPureEff
    . runRaylibHeadless frames
    . runFileWatchScript (saveCircle emptyCircle) script
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

ageSeconds :: LoopStats -> Double
ageSeconds stats = case lsFinalAge stats of
  Just (Time t) -> t
  Nothing -> -1

spec :: Spec
spec = describe "hot reload" $ do
  describe "pure decision (mtime sequence -> reload points)" $ do
    it "an unchanged sequence never reloads" $
      reloadPoints (replicate 10 (0 :: Int)) `shouldBe` []

    it "the first observation is a baseline, not a change" $ do
      stampChanged (Nothing :: Maybe Int) 5 `shouldBe` False
      reloadPoints [5 :: Int] `shouldBe` []

    it "reloads exactly at the observations that differ from their predecessor" $
      reloadPoints [1, 1, 2, 2, 2, 3, 1 :: Int] `shouldBe` [2, 5, 6]

    prop "number of reloads == number of adjacent unequal pairs" $
      \(stamps :: [Int]) ->
        length (reloadPoints stamps)
          === length (filter id (zipWith (/=) stamps (drop 1 stamps)))

    prop "a constant prefix before a change delays the reload point past it" $
      forAll (choose (1, 20)) $ \k ->
        reloadPoints (replicate k (0 :: Int) ++ [1]) === [k]

  describe "scripted loop (change injected at frame k)" $ do
    it "no change => a single cast for the whole run" $ do
      let stats = runWithScript 60 []
      lsCasts stats `shouldBe` 1
      abs (ageSeconds stats - 60 * (1 / 60)) `shouldSatisfy` (< 1e-6)

    it "a change at frame 10 re-casts: cast count 2, spell age restarts" $ do
      let frames = 60
          k = 10
          stats = runWithScript frames (replicate (k - 1) False ++ [True])
      lsCasts stats `shouldBe` 2
      -- Re-cast at frame k steps once that same frame, then the
      -- remaining frames once each: age = (frames - k + 1) * dt.
      abs (ageSeconds stats - fromIntegral (frames - k + 1) * (1 / 60))
        `shouldSatisfy` (< 1e-6)

    it "two separate changes re-cast twice" $ do
      let script = [False, True, False, False, True]
          stats = runWithScript 30 script
      lsCasts stats `shouldBe` 3
