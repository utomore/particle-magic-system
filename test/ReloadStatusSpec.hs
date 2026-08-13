-- | S4 (func-spec 0005 §8): load failures are observable.
--
-- Before this round a broken spell file was swallowed silently — the
-- window either kept the old picture with no explanation or, if the very
-- first load failed, stayed black. ADR-0005 called that out as the price
-- of the JSON interface; this spec is the payment: the previous spell
-- keeps running, the full 'Magic.Codec.renderLoadError' text reaches the
-- HUD, and moving to a good file recovers.
module ReloadStatusSpec (spec) where

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
import Magic.Codec (loadCircle, renderLoadError, saveCircle)
import Magic.Interface (CastContext (..), Seed (..), V3 (..), emptyCircle)
import Test.Hspec

goodPath, badPath :: FilePath
goodPath = "good-spell.json"
badPath = "broken-spell.json"

goodBytes :: BS.ByteString
goodBytes = saveCircle emptyCircle

-- | Valid JSON, invalid circle: an unknown rune tag. The decoder's error
-- carries the JSON path and the list of legal tags, which is exactly the
-- text the HUD has to show.
badBytes :: BS.ByteString
badBytes =
  BS8.pack
    "{ \"version\": 1, \"name\": \"broken\", \"circle\": \
    \{ \"outer\": [ { \"rune\": \"nonsense\" } ] } }"

-- | What 'renderLoadError' says about 'badBytes' — the HUD must show
-- this string, not a paraphrase of it.
expectedError :: String
expectedError = case loadCircle badBytes of
  Left err -> renderLoadError err
  Right _ -> error "fixture must not decode"

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = [goodPath, badPath]
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

files :: M.Map FilePath (BS.ByteString, [Bool])
files =
  M.fromList
    [ (goodPath, (goodBytes, []))
    , (badPath, (badBytes, []))
    ]

runDemo :: LoopConfig -> [DemoInput] -> Int -> (LoopStats, HeadlessLog)
runDemo cfg inputs frames =
  runPureEff
    . runRaylibHeadlessWith inputs frames
    . runFileWatchScriptMap files
    . runClockVirtual (1 / 60)
    $ runLoop cfg

-- | Press "next spell" on frame @k@ (1-based), idle otherwise.
nextOn :: [Int] -> Int -> [DemoInput]
nextOn ks frames =
  [ if k `elem` ks then noInput {diNextSpell = True} else noInput
  | k <- [1 .. frames]
  ]

failureOf :: HudView -> Maybe String
failureOf v = case hvReload v of
  ReloadFailed _ err -> Just err
  _ -> Nothing

isOk :: ReloadStatus -> Bool
isOk status = case status of
  ReloadOk _ -> True
  _ -> False

spec :: Spec
spec = describe "load failures stay visible (func-spec 0005 §4.2)" $ do
  it "a good file that never changes reports no reload at all" $ do
    let (stats, logR) = runDemo testConfig [] 30
    lsCasts stats `shouldBe` 1
    map hvReload (hlHuds logR) `shouldSatisfy` all (== ReloadIdle)

  it "switching to a broken file keeps the old spell running and shows the error" $ do
    let frames = 30
        k = 10
        (stats, logR) = runDemo testConfig (nextOn [k] frames) frames
        huds = hlHuds logR
    -- Only the initial cast happened: the failed load cast nothing.
    lsCasts stats `shouldBe` 1
    -- The old spell is still being sampled and drawn.
    map hvParticles (drop k huds) `shouldSatisfy` all (> 0)
    -- Its age keeps climbing across the failure instead of resetting.
    hvSpellAge (last huds) `shouldSatisfy` (> hvSpellAge (huds !! (k - 1)))
    -- And every frame from the failure on says exactly why.
    map hvReload (take (k - 1) huds) `shouldSatisfy` all (== ReloadIdle)
    map failureOf (drop (k - 1) huds) `shouldSatisfy` all (== Just expectedError)
    -- The HUD follows the switch even though the load failed.
    map hvSpellPath (drop (k - 1) huds) `shouldSatisfy` all (== badPath)

  it "a broken file at startup does not blank the screen, and recovers on switch" $ do
    let frames = 30
        k = 10
        cfg = testConfig {lcSpellIndex = 1}
        (stats, logR) = runDemo cfg (nextOn [k] frames) frames
        huds = hlHuds logR
    length huds `shouldBe` frames
    -- Before the switch: no spell, but a full explanation on screen.
    map hvParticles (take (k - 1) huds) `shouldSatisfy` all (== 0)
    map failureOf (take (k - 1) huds) `shouldSatisfy` all (== Just expectedError)
    -- After the switch to the good file: cast, particles, ReloadOk.
    lsCasts stats `shouldBe` 1
    map hvReload (drop (k - 1) huds) `shouldSatisfy` all isOk
    map hvSpellPath (drop (k - 1) huds) `shouldSatisfy` all (== goodPath)
    -- A freshly cast spell restarts at one step of age.
    abs (hvSpellAge (huds !! (k - 1)) - (1 / 60)) `shouldSatisfy` (< 1e-9)

  it "a hot-reload change on the live file is reported as ReloadOk" $ do
    let frames = 30
        k = 10
        withScript = M.insert goodPath (goodBytes, replicate (k - 1) False ++ [True]) files
        (stats, logR) =
          runPureEff
            . runRaylibHeadlessWith [] frames
            . runFileWatchScriptMap withScript
            . runClockVirtual (1 / 60)
            $ runLoop testConfig
        huds = hlHuds logR
    lsCasts stats `shouldBe` 2
    map hvReload (take (k - 1) huds) `shouldSatisfy` all (== ReloadIdle)
    map hvReload (drop (k - 1) huds) `shouldSatisfy` all isOk
    abs (hvSpellAge (huds !! (k - 1)) - (1 / 60)) `shouldSatisfy` (< 1e-9)

  it "a missing file is a load error like any other, not a crash" $ do
    let cfg = testConfig {lcSpellPaths = ["no-such-file.json"], lcSpellIndex = 0}
        (stats, logR) = runDemo cfg [] 10
    lsCasts stats `shouldBe` 0
    length (hlHuds logR) `shouldBe` 10
    map failureOf (hlHuds logR) `shouldSatisfy` all (/= Nothing)
