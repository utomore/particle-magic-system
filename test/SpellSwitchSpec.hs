-- | S6 (func-spec 0005 §8): cycling through the example spells from the
-- keyboard.
--
-- Until this round the demo could only show whichever file @Main.hs@ was
-- edited to point at. The arrow keys now walk the scanned list, and each
-- move is a real load + re-cast whose watcher follows the new path.
module SpellSwitchSpec (spec) where

import qualified Data.ByteString as BS
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
import Magic.Interface (CastContext (..), Seed (..), V3 (..))
import Test.Hspec

paths :: [FilePath]
paths = ["a.json", "b.json", "c.json"]

sources :: [FilePath]
sources =
  [ "assets/spells/ring-fire.json"
  , "assets/spells/square-burst.json"
  , "assets/spells/spiral-spark.json"
  ]

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = paths
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

-- | Each virtual path serves the bytes of a real example file.
loadFiles :: IO (M.Map FilePath (BS.ByteString, [Bool]))
loadFiles = do
  bytes <- mapM BS.readFile sources
  pure (M.fromList (zip paths (map (\b -> (b, [])) bytes)))

runDemo
  :: M.Map FilePath (BS.ByteString, [Bool])
  -> LoopConfig
  -> [DemoInput]
  -> Int
  -> (LoopStats, HeadlessLog)
runDemo files cfg inputs frames =
  runPureEff
    . runRaylibHeadlessWith inputs frames
    . runFileWatchScriptMap files
    . runClockVirtual (1 / 60)
    $ runLoop cfg

-- | Build an input script: @(frame, key)@ pairs, idle everywhere else.
script :: Int -> [(Int, DemoInput -> DemoInput)] -> [DemoInput]
script frames presses =
  [ foldr ($) noInput [f | (j, f) <- presses, j == k]
  | k <- [1 .. frames]
  ]

next, prev, recast :: DemoInput -> DemoInput
next i = i {diNextSpell = True}
prev i = i {diPrevSpell = True}
recast i = i {diRecast = True}

spec :: Spec
spec = describe "keyboard spell switching (func-spec 0005 §4.4)" $ do
  it "-> walks the list forward, re-casting on each move" $ do
    files <- loadFiles
    let frames = 30
        (stats, logR) = runDemo files testConfig (script frames [(10, next), (20, next)]) frames
        seen = map hvSpellPath (hlHuds logR)
    take 9 seen `shouldSatisfy` all (== "a.json")
    take 10 (drop 9 seen) `shouldSatisfy` all (== "b.json")
    drop 19 seen `shouldSatisfy` all (== "c.json")
    -- Initial cast plus one per move.
    lsCasts stats `shouldBe` 3

  it "a switch restarts the spell's age from zero" $ do
    files <- loadFiles
    let frames = 30
        k = 10
        (_, logR) = runDemo files testConfig (script frames [(k, next)]) frames
        huds = hlHuds logR
    -- Frame k-1 is deep into the first spell...
    hvSpellAge (huds !! (k - 2)) `shouldSatisfy` (> 8 * (1 / 60))
    -- ...and frame k is one step into the new one.
    abs (hvSpellAge (huds !! (k - 1)) - (1 / 60)) `shouldSatisfy` (< 1e-9)

  it "-> wraps around the end of the list" $ do
    files <- loadFiles
    let frames = 20
        (stats, logR) =
          runDemo files testConfig (script frames [(4, next), (8, next), (12, next)]) frames
    map hvSpellPath (drop 11 (hlHuds logR)) `shouldSatisfy` all (== "a.json")
    lsCasts stats `shouldBe` 4

  it "<- walks the list backward and wraps" $ do
    files <- loadFiles
    let frames = 20
        (_, logR) = runDemo files testConfig (script frames [(5, prev)]) frames
    map hvSpellPath (drop 4 (hlHuds logR)) `shouldSatisfy` all (== "c.json")

  it "pressing both arrows on one frame is a no-op" $ do
    files <- loadFiles
    let frames = 20
        (stats, logR) = runDemo files testConfig (script frames [(5, next . prev)]) frames
    map hvSpellPath (hlHuds logR) `shouldSatisfy` all (== "a.json")
    lsCasts stats `shouldBe` 1

  it "a single-file list makes -> and <- no-ops" $ do
    files <- loadFiles
    let frames = 20
        cfg = testConfig {lcSpellPaths = ["a.json"]}
        (stats, logR) = runDemo files cfg (script frames [(5, next), (10, prev)]) frames
    map hvSpellPath (hlHuds logR) `shouldSatisfy` all (== "a.json")
    lsCasts stats `shouldBe` 1

  it "the watcher follows the new path: a change to the old file is ignored" $ do
    base <- loadFiles
    -- Announce a change on a.json at frame 15, i.e. after we left it.
    let files = M.adjust (\(b, _) -> (b, replicate 14 False ++ [True])) "a.json" base
        frames = 30
        (stats, logR) = runDemo files testConfig (script frames [(5, next)]) frames
    map hvSpellPath (drop 4 (hlHuds logR)) `shouldSatisfy` all (== "b.json")
    -- Initial cast + the switch. The stale a.json change never fires.
    lsCasts stats `shouldBe` 2

  it "the watcher fires on the new path once we are on it" $ do
    base <- loadFiles
    let files = M.adjust (\(b, _) -> (b, replicate 14 False ++ [True])) "b.json" base
        frames = 30
        (stats, logR) = runDemo files testConfig (script frames [(5, next)]) frames
        huds = hlHuds logR
    -- Initial cast + switch + hot reload of b.json.
    lsCasts stats `shouldBe` 3
    map hvReload (drop 20 huds) `shouldSatisfy` all isOk

  it "R re-casts the current spell without changing file" $ do
    files <- loadFiles
    let frames = 30
        k = 12
        (stats, logR) = runDemo files testConfig (script frames [(k, recast)]) frames
        huds = hlHuds logR
    map hvSpellPath huds `shouldSatisfy` all (== "a.json")
    lsCasts stats `shouldBe` 2
    abs (hvSpellAge (huds !! (k - 1)) - (1 / 60)) `shouldSatisfy` (< 1e-9)

  it "switching to a missing file reports the error and can be switched away from" $ do
    base <- loadFiles
    -- ring-fire's first particles are born around t = 0.8s, so the failed
    -- switch happens while the old spell is visibly emitting.
    let files = M.delete "b.json" base
        frames = 180
        toMissing = 70
        toSpark = 120
        (stats, logR) =
          runDemo files testConfig (script frames [(toMissing, next), (toSpark, next)]) frames
        huds = hlHuds logR
        broken = take (toSpark - toMissing) (drop (toMissing - 1) huds)
    -- The failed switch keeps the old spell alive and drawing.
    map hvParticles broken `shouldSatisfy` all (> 0)
    map hvReload broken `shouldSatisfy` all isFailed
    -- Moving on to c.json recovers.
    map hvSpellPath (drop (toSpark - 1) huds) `shouldSatisfy` all (== "c.json")
    map hvReload (drop (toSpark - 1) huds) `shouldSatisfy` all isOk
    lsCasts stats `shouldBe` 2

isOk :: ReloadStatus -> Bool
isOk s = case s of
  ReloadOk _ -> True
  _ -> False

isFailed :: ReloadStatus -> Bool
isFailed s = case s of
  ReloadFailed _ _ -> True
  _ -> False
