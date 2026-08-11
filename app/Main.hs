-- | The effectful shell: assemble the IO interpreters and run the loop
-- (func-spec 0001 §5). All spell semantics live behind Magic.Interface;
-- this file is glue.
module Main (main) where

import Effectful (runEff)

import App.Effects (runClockIO, runFileWatchIO)
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.Render.Raylib3D (runRaylibIO)
import Magic.Interface (CastContext (..), Seed (..), V3 (..))

config :: LoopConfig
config =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPath = "assets/spells/empty.json"
    , lcCamera = defaultCamera
    , lcCastCtx =
        CastContext
          { casterPos = V3 0 0 0
          , casterFacing = V3 0 1 0
          , seed = Seed 42
          }
    , lcWindowSize = (1280, 720)
    , lcWindowTitle = "particle-magic — walking skeleton"
    }

main :: IO ()
main = do
  stats <-
    runEff
      . runRaylibIO
      . runFileWatchIO 0.5
      . runClockIO
      $ runLoop config
  putStrLn $
    "frames="
      ++ show (lsFrames stats)
      ++ " simSteps="
      ++ show (lsSimSteps stats)
      ++ " casts="
      ++ show (lsCasts stats)
