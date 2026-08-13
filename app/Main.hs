-- | The effectful shell: assemble the IO interpreters and run the loop
-- (func-spec 0001 §5). All spell semantics live behind Magic.Interface;
-- this file is glue.
--
-- Spec 0005: the demo no longer hardcodes one spell file. It scans
-- @assets\/spells@ once at startup and the arrow keys cycle through what
-- it found, so every example is reachable without editing this file.
module Main (main) where

import Data.List (isSuffixOf, sort)
import Effectful (runEff)
import System.Directory (doesDirectoryExist, listDirectory)

import App.Effects (runClockIO, runFileWatchIO)
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.Render.Raylib3D (runRaylibIO)
import Magic.Interface (CastContext (..), Seed (..), V3 (..))

spellDir :: FilePath
spellDir = "assets/spells"

-- | Every @*.json@ under 'spellDir', sorted. Falls back to the empty
-- circle's path so the loop always has something to report on — a missing
-- directory then shows up as a load error on the HUD rather than as a
-- silent black window.
scanSpells :: IO [FilePath]
scanSpells = do
  there <- doesDirectoryExist spellDir
  entries <-
    if there
      then sort . filter (".json" `isSuffixOf`) <$> listDirectory spellDir
      else pure []
  pure $ case entries of
    [] -> [under "empty.json"]
    es -> map under es
  where
    under name = spellDir ++ "/" ++ name

config :: [FilePath] -> LoopConfig
config paths =
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
          , seed = Seed 42
          }
    , lcWindowSize = (1280, 720)
    , lcWindowTitle = "particle-magic"
    }

main :: IO ()
main = do
  paths <- scanSpells
  stats <-
    runEff
      . runRaylibIO
      . runFileWatchIO 0.5
      . runClockIO
      $ runLoop (config paths)
  putStrLn $
    "frames="
      ++ show (lsFrames stats)
      ++ " simSteps="
      ++ show (lsSimSteps stats)
      ++ " casts="
      ++ show (lsCasts stats)
