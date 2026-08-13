-- | T7 (func-spec 0001 §8): the real main loop runs headless under the
-- test interpreters — virtual clock at one frame per 'now' call, scripted
-- file watch, recording renderer.
module EffectsSpec (spec) where

import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScript
  , runRaylibHeadless
  )
import Effectful (runPureEff)
import Magic.Codec (saveCircle)
import Magic.Interface (CastContext (..), Seed (..), V3 (..), emptyCircle)
import Test.Hspec

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

-- | Run the loop for a number of headless frames with a change script.
runHeadless :: Int -> [Bool] -> (LoopStats, HeadlessLog)
runHeadless frames script =
  runPureEff
    . runRaylibHeadless frames
    . runFileWatchScript (saveCircle emptyCircle) script
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

spec :: Spec
spec = describe "shell effects under test interpreters (headless main loop)" $ do
  it "N virtual seconds at 60fps yields exactly N*60 simulation steps" $ do
    let n = 2
        (stats, _) = runHeadless (n * 60) []
    lsSimSteps stats `shouldBe` n * 60

  it "the headless renderer receives one DrawBatch per rendered frame" $ do
    let frames = 90
        (stats, logR) = runHeadless frames []
    lsFrames stats `shouldBe` frames
    hlFrames logR `shouldBe` frames
    hlDrawCalls logR `shouldBe` frames

  it "the initial cast happens exactly once when the file never changes" $ do
    let (stats, _) = runHeadless 30 []
    lsCasts stats `shouldBe` 1

  it "a slower render clock still simulates at the fixed rate (2 steps per frame at 30fps)" $ do
    let frames = 30
        (stats, _) =
          runPureEff
            . runRaylibHeadless frames
            . runFileWatchScript (saveCircle emptyCircle) []
            . runClockVirtual (1 / 30)
            $ runLoop testConfig
    lsSimSteps stats `shouldBe` frames * 2
