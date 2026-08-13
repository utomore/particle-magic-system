-- | S9 (func-spec 0005 §8): end-to-end acceptance of the render and
-- observability round, headless.
--
-- One uninterrupted run over real example bytes: the demo starts on a
-- fire spell, gets hot-reloaded, is switched forward into a broken file,
-- survives it, is switched on to a good one, and recovers — while every
-- frame produces exactly one scene and one HUD, and the 0001 'LoopStats'
-- contract keeps holding. The window half is the manual smoke recorded in
-- the spec §10.
module Acceptance5Spec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Map.Strict as M
import App.Effects (DemoInput (..), HudView (..), ReloadStatus (..), noInput)
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScriptMap
  , runRaylibHeadlessWith
  )
import Effectful (runPureEff)
import Magic.Interface
  ( BlendMode (..)
  , CastContext (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  )
import Test.Hspec

firePath, brokenPath, sparkPath :: FilePath
firePath = "fire.json"
brokenPath = "broken.json"
sparkPath = "spark.json"

demoPaths :: [FilePath]
demoPaths = [firePath, brokenPath, sparkPath]

brokenBytes :: BS.ByteString
brokenBytes = BS8.pack "{ \"version\": 1, \"circle\": { \"bridge\": { \"rune\": \"bogus\" } } }"

-- | Five virtual seconds at 60Hz. The waypoints are spaced so the live
-- spell is past its first births at every interesting moment: ring-fire
-- starts emitting around t = 0.8s.
frames :: Int
frames = 300

-- | Hot reload of the fire spell at frame 60, then forward into the
-- broken file at 150, then on to the spark at 220.
reloadFrame, toBrokenFrame, toSparkFrame :: Int
reloadFrame = 60
toBrokenFrame = 150
toSparkFrame = 220

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = demoPaths
    , lcSpellIndex = 0
    , lcCamera = defaultCamera
    , lcCastCtx =
        CastContext
          { casterPos = V3 0 0 0
          , casterFacing = V3 0 1 0
          , seed = Seed 2026
          }
    , lcWindowSize = (1280, 720)
    , lcWindowTitle = "acceptance"
    }

inputs :: [DemoInput]
inputs =
  [ if k == toBrokenFrame || k == toSparkFrame
      then noInput {diNextSpell = True}
      else noInput
  | k <- [1 .. frames]
  ]

runDemo :: IO (LoopStats, HeadlessLog)
runDemo = do
  fireBytes <- BS.readFile "assets/spells/ring-fire.json"
  sparkBytes <- BS.readFile "assets/spells/spiral-spark.json"
  let files =
        M.fromList
          [ (firePath, (fireBytes, replicate (reloadFrame - 1) False ++ [True]))
          , (brokenPath, (brokenBytes, []))
          , (sparkPath, (sparkBytes, []))
          ]
  pure
    . runPureEff
    . runRaylibHeadlessWith inputs frames
    . runFileWatchScriptMap files
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

-- | Frames are 1-based in the scripts; the logs are 0-based.
at :: [a] -> Int -> a
at xs k = xs !! (k - 1)

spec :: Spec
spec = describe "render + observability acceptance (func-spec 0005 S9)" $ do
  it "runs the whole script in one take without ever losing a frame" $ do
    (stats, logR) <- runDemo
    lsFrames stats `shouldBe` frames
    hlFrames logR `shouldBe` frames
    length (hlScenes logR) `shouldBe` frames
    length (hlHuds logR) `shouldBe` frames
    -- The 0001 stats contract: one fixed step per virtual frame.
    lsSimSteps stats `shouldBe` frames
    case lsFinalAge stats of
      Just (Time age) -> age `shouldSatisfy` (> 0)
      Nothing -> expectationFailure "the run must end with a live spell"

  it "casts once at startup, once per successful reload or switch" $ do
    (stats, _) <- runDemo
    -- initial + hot reload + (failed switch: none) + switch to spark
    lsCasts stats `shouldBe` 3

  it "keeps drawing particles across the failed switch" $ do
    (_, logR) <- runDemo
    let counts = map snd (hlScenes logR)
        -- From the moment the broken file is switched in until the next
        -- switch, the fire spell must still be emitting.
        acrossFailure = take (toSparkFrame - toBrokenFrame) (drop (toBrokenFrame - 1) counts)
    acrossFailure `shouldSatisfy` all (> 0)
    -- And the run ends on a spell that is emitting again.
    last counts `shouldSatisfy` (> 0)

  it "the HUD path and reload state track the script frame by frame" $ do
    (_, logR) <- runDemo
    let huds = hlHuds logR
    hvReload (huds `at` (reloadFrame - 1)) `shouldBe` ReloadIdle
    hvReload (huds `at` reloadFrame) `shouldSatisfy` isOk
    hvSpellPath (huds `at` (toBrokenFrame - 1)) `shouldBe` firePath
    -- Switching into the broken file: path follows, spell does not.
    hvSpellPath (huds `at` toBrokenFrame) `shouldBe` brokenPath
    hvReload (huds `at` toBrokenFrame) `shouldSatisfy` isFailed
    -- The fire spell keeps ageing across the failed switch.
    hvSpellAge (huds `at` (toSparkFrame - 1))
      `shouldSatisfy` (> hvSpellAge (huds `at` toBrokenFrame))
    -- And the next switch recovers onto a fresh spell.
    hvSpellPath (huds `at` toSparkFrame) `shouldBe` sparkPath
    hvReload (huds `at` toSparkFrame) `shouldSatisfy` isOk
    abs (hvSpellAge (huds `at` toSparkFrame) - (1 / 60)) `shouldSatisfy` (< 1e-9)

  it "the blend mode reaching the renderer follows the live spell" $ do
    (_, logR) <- runDemo
    let scenes = hlScenes logR
    -- ring-fire is additive and stays so across the failed switch.
    map fst (take (toSparkFrame - 1) scenes) `shouldSatisfy` all (== BlendAdditive)
    -- spiral-spark is lightning: additive too, but it is a distinct spell
    -- and the particle counts change at the switch.
    snd (scenes `at` toSparkFrame) `shouldNotBe` snd (scenes `at` (toSparkFrame - 1))

  it "the HUD's particle count is exactly what the scene was handed" $ do
    (_, logR) <- runDemo
    map hvParticles (hlHuds logR) `shouldBe` map snd (hlScenes logR)

  it "the frame-rate readout settles at the virtual frame rate" $ do
    (_, logR) <- runDemo
    let fps = hvFps (last (hlHuds logR))
    abs (fps - 60) `shouldSatisfy` (< 1)

isOk :: ReloadStatus -> Bool
isOk s = case s of
  ReloadOk _ -> True
  _ -> False

isFailed :: ReloadStatus -> Bool
isFailed s = case s of
  ReloadFailed _ _ -> True
  _ -> False
