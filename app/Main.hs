{-# LANGUAGE PatternSynonyms #-}

-- S0 smoke test: open a raylib 3D window, draw a cube, auto-close after ~3s
-- (or close via window button / Esc). Validates h-raylib x GHC 9.14.1 x Windows.
module Main (main) where

import Raylib.Core (beginDrawing, beginMode3D, clearBackground, endDrawing, endMode3D, windowShouldClose)
import Raylib.Core.Models (drawCube, drawGrid)
import Raylib.Types (Camera3D (..), CameraProjection (CameraPerspective), pattern Vector3)
import Raylib.Util (withWindow)
import Raylib.Util.Colors (maroon, rayWhite)

main :: IO ()
main = withWindow 800 450 "particle-magic S0 smoke" 60 $ \_ -> do
  let cam = Camera3D (Vector3 4 3 4) (Vector3 0 0 0) (Vector3 0 1 0) 45 CameraPerspective
      loop :: Int -> IO ()
      loop n = do
        close <- windowShouldClose
        if close || n >= 180
          then pure ()
          else do
            beginDrawing
            clearBackground rayWhite
            beginMode3D cam
            drawCube (Vector3 0 0.5 0) 1 1 1 maroon
            drawGrid 10 1
            endMode3D
            endDrawing
            loop (n + 1)
  loop 0
