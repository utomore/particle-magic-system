-- | S3 (func-spec 0014 §7): the demo's spell list follows the directory.
--
-- Two halves, and the split is the point. 'mergeSpellList' and
-- 'spellDirOf' are pure decisions about a list of paths, so they are
-- tested as arithmetic; the wiring — that a new listing actually reaches
-- the loop, and that the selection survives it — is driven headless
-- through the scripted 'ScanDir', with no filesystem anywhere in sight.
module RescanSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as M
import Effectful (runPureEff)
import System.Directory (listDirectory)
import Test.Hspec

import App.Effects (DemoInput (..), HudView (..), ReloadStatus (..), noInput)
import App.HotReload (newWatchState, scanDirIO)
import App.Loop
  ( LoopConfig (..)
  , LoopStats (..)
  , defaultCamera
  , mergeSpellList
  , runLoop
  , spellDirOf
  )
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScriptDirs
  , runRaylibHeadlessWith
  )
import Magic.Interface (CastContext (..), Seed (..), V3 (..))

dir :: FilePath
dir = "assets/spells"

-- | Three virtual paths in one directory, each served real bytes.
pathA, pathB, pathC, pathD :: FilePath
pathA = dir ++ "/a.json"
pathB = dir ++ "/b.json"
pathC = dir ++ "/c.json"
pathD = dir ++ "/d.json"

paths :: [FilePath]
paths = [pathA, pathB, pathC]

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

-- | Every path in 'paths' plus a fourth one, all served real bytes, so a
-- listing can introduce @d.json@ without the loop hitting a missing file.
loadFiles :: IO (M.Map FilePath (BS.ByteString, [Bool]))
loadFiles = do
  ringFire <- BS.readFile "assets/spells/ring-fire.json"
  burst <- BS.readFile "assets/spells/square-burst.json"
  spark <- BS.readFile "assets/spells/spiral-spark.json"
  pure $
    M.fromList
      [ (pathA, (ringFire, []))
      , (pathB, (burst, []))
      , (pathC, (spark, []))
      , (pathD, (ringFire, []))
      ]

runDemo
  :: M.Map FilePath (BS.ByteString, [Bool])
  -> [[FilePath]]
  -> [DemoInput]
  -> Int
  -> (LoopStats, HeadlessLog)
runDemo files listings inputs frames =
  runPureEff
    . runRaylibHeadlessWith inputs frames
    . runFileWatchScriptDirs files listings
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

idle :: Int -> [DemoInput]
idle frames = replicate frames noInput

-- | @(frame, key)@ pairs, idle everywhere else.
script :: Int -> [(Int, DemoInput -> DemoInput)] -> [DemoInput]
script frames presses =
  [ foldr ($) noInput [f | (j, f) <- presses, j == k]
  | k <- [1 .. frames]
  ]

next :: DemoInput -> DemoInput
next i = i {diNextSpell = True}

-- | The spell list exactly as @app\/Main.hs@ builds it at startup.
startupListing :: IO [FilePath]
startupListing = do
  entries <- listDirectory dir
  pure [dir ++ "/" ++ e | e <- sort entries, ".json" `isSuffixOf` e]

spec :: Spec
spec = do
  describe "spellDirOf: where to rescan (func-spec 0014 §4)" $ do
    it "is the common directory of the list" $
      spellDirOf paths `shouldBe` Just dir

    it "is nothing for an empty list" $
      spellDirOf [] `shouldBe` Nothing

    it "is nothing when the paths come from different places" $
      spellDirOf ["a/x.json", "b/y.json"] `shouldBe` Nothing

    it "handles bare file names (the directory is \".\")" $
      spellDirOf ["x.json", "y.json"] `shouldBe` Just "."

  describe "mergeSpellList: the pure decision (func-spec 0014 §4)" $ do
    it "does nothing when there is no listing" $
      mergeSpellList [] paths pathA 0 `shouldBe` Nothing

    it "does nothing when the listing is the list we already have" $
      mergeSpellList paths paths pathB 1 `shouldBe` Nothing

    it "keeps the selection on its path when a file is inserted before it" $ do
      let grown = ["assets/spells/0.json"] ++ paths
      mergeSpellList grown paths pathB 1 `shouldBe` Just (grown, 2)

    it "keeps the selection on its path when a file is appended" $ do
      let grown = paths ++ ["assets/spells/z.json"]
      mergeSpellList grown paths pathB 1 `shouldBe` Just (grown, 1)

    it "falls onto the neighbour that took the slot when the selection is deleted" $ do
      let shrunk = [pathA, pathC]
      -- b.json was index 1; c.json now is.
      mergeSpellList shrunk paths pathB 1 `shouldBe` Just (shrunk, 1)

    it "clamps onto the new last entry when the deleted file was last" $ do
      let shrunk = take 2 paths
      mergeSpellList shrunk paths pathC 2 `shouldBe` Just (shrunk, 1)

    it "never produces an index outside the new list" $ do
      let one = [pathA]
      mergeSpellList one paths pathC 2 `shouldBe` Just (one, 0)

  -- The three headless laws above all rest on one assumption: that a
  -- listing of an unchanged directory comes back EQUAL to the list Main
  -- built at startup. A scripted interpreter cannot check that -- it is a
  -- property of the real one, and getting it wrong costs a spurious
  -- re-cast on the first frame of every session (a Windows path
  -- separator was enough to do it, and the demo still ran, because both
  -- spellings name the same file).
  describe "scanDirIO: the listing really is the startup list (func-spec 0014 §4)" $ do
    it "reproduces what Main scanned, separator for separator" $ do
      expected <- startupListing
      st <- newWatchState 0.5 2.0
      listed <- scanDirIO st dir
      listed `shouldBe` expected
      -- Which is the whole point: it merges to the identity.
      case expected of
        (firstSpell : _) ->
          mergeSpellList listed expected firstSpell 0 `shouldBe` Nothing
        [] -> expectationFailure "assets/spells has no spell files"
      spellDirOf listed `shouldBe` Just dir

    it "repeats its previous answer while throttled" $ do
      st <- newWatchState 0.5 3600
      first' <- scanDirIO st dir
      second' <- scanDirIO st dir
      second' `shouldBe` first'

    it "reports nothing for a directory that is not there, rather than throwing" $ do
      st <- newWatchState 0.5 2.0
      listed <- scanDirIO st (dir ++ "/no-such-directory")
      listed `shouldBe` []

  describe "the loop follows the directory (func-spec 0014 §1.4)" $ do
    it "picks up a file created while it runs" $ do
      files <- loadFiles
      let frames = 30
          grown = paths ++ [pathD]
          -- Frame 1 sees the list it started with, every later scan sees
          -- the grown one (the script's last listing repeats).
          (stats, logR) = runDemo files [paths, grown] (script frames [(10, next), (20, next), (25, next)]) frames
          seen = map hvSpellPath (hlHuds logR)
      -- Three -> presses walk onto the file that did not exist at start.
      drop 24 seen `shouldSatisfy` all (== pathD)
      -- Initial cast plus one per move: the rescan itself never re-casts.
      lsCasts stats `shouldBe` 4

    it "a rescan that adds a file does not disturb the running spell" $ do
      files <- loadFiles
      let frames = 30
          grown = [dir ++ "/0.json"] ++ paths
          (grownStats, grownLog) = runDemo files [paths, grown] (idle frames) frames
          (stillStats, stillLog) = runDemo files [] (idle frames) frames
      -- The list grew (and the selection's index moved with it), but not
      -- one particle differs.
      map hvSpellPath (hlHuds grownLog) `shouldSatisfy` all (== pathA)
      hlScenes grownLog `shouldBe` hlScenes stillLog
      lsCasts grownStats `shouldBe` lsCasts stillStats
      lsFinalAge grownStats `shouldBe` lsFinalAge stillStats

    it "deleting the selected file falls onto its neighbour and casts it" $ do
      files <- loadFiles
      let frames = 40
          shrunk = [pathA, pathC]
          -- Start on b.json, then it disappears.
          cfg = testConfig {lcSpellIndex = 1}
          (stats, logR) =
            runPureEff
              . runRaylibHeadlessWith (idle frames) frames
              . runFileWatchScriptDirs files [paths, paths, shrunk]
              . runClockVirtual (1 / 60)
              $ runLoop cfg
          seen = map hvSpellPath (hlHuds logR)
      take 2 seen `shouldSatisfy` all (== pathB)
      drop 2 seen `shouldSatisfy` all (== pathC)
      -- Initial cast of b.json, then one cast of the neighbour.
      lsCasts stats `shouldBe` 2
      map hvReload (drop 2 (hlHuds logR)) `shouldSatisfy` all isOk

    it "deleting a file we are NOT on leaves the spell alone" $ do
      files <- loadFiles
      let frames = 30
          shrunk = take 2 paths
          (stats, logR) = runDemo files [paths, shrunk] (idle frames) frames
          (stillStats, stillLog) = runDemo files [] (idle frames) frames
      map hvSpellPath (hlHuds logR) `shouldSatisfy` all (== pathA)
      hlScenes logR `shouldBe` hlScenes stillLog
      lsCasts stats `shouldBe` lsCasts stillStats

    it "an unavailable listing is not an empty directory" $ do
      -- The throttle answers "nothing to report" far more often than it
      -- answers a listing; that must never be read as "every spell was
      -- deleted".
      files <- loadFiles
      let frames = 20
          (stats, logR) = runDemo files [] (idle frames) frames
      map hvSpellPath (hlHuds logR) `shouldSatisfy` all (== pathA)
      lsCasts stats `shouldBe` 1

    it "a listing equal to the one in hand changes nothing at all" $ do
      files <- loadFiles
      let frames = 20
          (repeated, repeatedLog) = runDemo files [paths] (idle frames) frames
          (still, stillLog) = runDemo files [] (idle frames) frames
      hlScenes repeatedLog `shouldBe` hlScenes stillLog
      hlHuds repeatedLog `shouldBe` hlHuds stillLog
      lsCasts repeated `shouldBe` lsCasts still

isOk :: ReloadStatus -> Bool
isOk s = case s of
  ReloadOk _ -> True
  _ -> False
