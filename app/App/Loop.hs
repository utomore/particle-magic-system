{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeOperators #-}

-- | The main loop (func-spec 0001 §5.2, extended by 0005): pure step
-- planning from 'Magic.Step', spell stepping through 'Magic.Interface',
-- all IO behind the 'Clock' / 'FileWatch' / 'Raylib' effects — so the
-- exact same loop runs against the real window and against the headless
-- test interpreters.
--
-- Spec 0005 adds three things to it: time advance and sampling are
-- separated ('advanceSpell' n times, 'observeSpell' exactly once per
-- rendered frame), load failures become observable instead of silent
-- (they keep the previous spell alive and put their full text on the
-- HUD), and the demo can cycle through the example spells from the
-- keyboard.
module App.Loop
  ( LoopConfig (..)
  , LoopStats (..)
  , defaultCamera
  , runLoop
  ) where

import qualified Data.ByteString as BS
import Effectful (Eff, (:>))
import Magic.Codec (loadCircle, renderLoadError)
import Magic.Interface
  ( ActiveSpell
  , CastContext
  , CastRequest (..)
  , Circle
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , isFinished
  , observeSpell
  , pbCount
  , spellAge
  )
import Magic.Step (StepPlan (..), plan)

import App.Effects
  ( Camera (..)
  , Clock
  , DemoInput (..)
  , FileWatch
  , HudView (..)
  , Raylib
  , ReloadStatus (..)
  , checkChanged
  , drawHud
  , drawScene
  , now
  , pollInput
  , readBytes
  , shouldClose
  , withFrame
  , withWindow
  )
import App.Hud (fpsEma)

data LoopConfig = LoopConfig
  { lcSimDt :: !Double
  -- ^ Fixed simulation timestep (1/60).
  , lcMaxStepsPerFrame :: !Int
  -- ^ Spiral-of-death clamp (8).
  , lcSpellPaths :: ![FilePath]
  -- ^ Spell files the demo cycles through; scanned once at startup and
  -- non-empty (Main's job). Rescanning the directory is out of scope.
  , lcSpellIndex :: !Int
  -- ^ Index into 'lcSpellPaths' to start from.
  , lcCamera :: !Camera
  , lcCastCtx :: !CastContext
  , lcWindowSize :: !(Int, Int)
  , lcWindowTitle :: !String
  }

-- | Observable outcome of a loop run — the test interpreters assert on
-- these (T7/T8).
data LoopStats = LoopStats
  { lsFrames :: !Int
  -- ^ Render frames processed.
  , lsSimSteps :: !Int
  -- ^ Fixed simulation steps executed.
  , lsCasts :: !Int
  -- ^ castSpell invocations (initial load, hot reloads, finish restarts).
  , lsFinalAge :: !(Maybe Time)
  -- ^ Age of the live spell when the loop ended.
  }
  deriving (Eq, Show)

defaultCamera :: Camera
defaultCamera =
  Camera
    { camPos = V3 6 4 6
    , camTarget = V3 0 2 0
    , camUp = V3 0 1 0
    , camFovY = 45
    }

-- | Smoothing factor of the HUD frame-rate readout.
fpsAlpha :: Double
fpsAlpha = 0.1

data LoopState = LoopState
  { stCircle :: !(Maybe Circle)
  -- ^ Latest successfully loaded circle (kept for finish restarts).
  , stSpell :: !(Maybe ActiveSpell)
  , stAcc :: !Double
  , stLastTime :: !Double
  , stFrames :: !Int
  , stSimSteps :: !Int
  , stCasts :: !Int
  , stIndex :: !Int
  -- ^ Position in 'lcSpellPaths'.
  , stPath :: !FilePath
  -- ^ The file currently loaded and watched.
  , stReload :: !ReloadStatus
  , stFpsEma :: !Double
  }

runLoop
  :: (Clock :> es, FileWatch :> es, Raylib :> es)
  => LoopConfig
  -> Eff es LoopStats
runLoop cfg =
  withWindow (fst (lcWindowSize cfg)) (snd (lcWindowSize cfg)) (lcWindowTitle cfg) $ do
    t0 <- now
    let index0 = normalizeIndex cfg (lcSpellIndex cfg)
        path0 = pathAt cfg index0
    loaded <- loadAndCast cfg path0
    frameLoop
      cfg
      LoopState
        { stCircle = either (const Nothing) (Just . fst) loaded
        , stSpell = either (const Nothing) (Just . snd) loaded
        , stAcc = 0
        , stLastTime = t0
        , stFrames = 0
        , stSimSteps = 0
        , stCasts = either (const 0) (const 1) loaded
        , stIndex = index0
        , stPath = path0
        , -- A failing initial load is reported like any other failure, so
          -- the demo shows the reason instead of a black window.
          stReload = either (ReloadFailed t0) (const ReloadIdle) loaded
        , stFpsEma = 0
        }

frameLoop
  :: (Clock :> es, FileWatch :> es, Raylib :> es)
  => LoopConfig
  -> LoopState
  -> Eff es LoopStats
frameLoop cfg st = do
  closing <- shouldClose
  if closing
    then
      pure
        LoopStats
          { lsFrames = stFrames st
          , lsSimSteps = stSimSteps st
          , lsCasts = stCasts st
          , lsFinalAge = spellAge <$> stSpell st
          }
    else do
      tNow <- now
      let elapsed = tNow - stLastTime st

      input <- pollInput
      let index' = shiftIndex cfg input (stIndex st)

      st1 <-
        if index' /= stIndex st
          then do
            -- Switching spell: load the new file, re-cast, and let the
            -- watcher follow the new path from here on.
            let path' = pathAt cfg index'
            loaded <- loadAndCast cfg path'
            pure (applyLoad tNow (st {stIndex = index', stPath = path'}) loaded)
          else do
            -- Hot reload: mtime change => reload + re-cast (state reset,
            -- architecture §8.3 POC strategy).
            changed <- checkChanged (stPath st)
            if changed
              then applyLoad tNow st <$> loadAndCast cfg (stPath st)
              else pure (recastOnRequest cfg input st)

      -- A finished spell restarts from the kept circle (walking-skeleton
      -- demo keeps the fountain alive).
      let st2 = case (stSpell st1, stCircle st1) of
            (Just spell, Just circle)
              | isFinished spell -> recastFrom cfg circle st1
            _ -> st1

      -- Fixed-step planning (pure), then n pure time advances and exactly
      -- one sampling — the frame's whole render cost, by construction.
      let StepPlan n acc' = plan (lcSimDt cfg) (lcMaxStepsPerFrame cfg) elapsed (stAcc st2)
          (spell', stepsRun) = case stSpell st2 of
            Nothing -> (Nothing, 0)
            Just spell -> (Just (advanceTimes cfg n spell), max 0 n)
          output' = maybe (FrameOutput []) observeSpell spell'
          fps' = fpsEma fpsAlpha elapsed (stFpsEma st2)
          hud =
            HudView
              { hvFps = fps'
              , hvParticles = sum (map (pbCount . rbParticles) (batches output'))
              , hvSpellPath = stPath st2
              , hvSpellAge = maybe 0 (\s -> let Time a = spellAge s in a) spell'
              , hvReload = stReload st2
              }

      withFrame $ do
        drawScene (lcCamera cfg) (batches output')
        drawHud hud

      frameLoop
        cfg
        st2
          { stSpell = spell'
          , stAcc = acc'
          , stLastTime = tNow
          , stFrames = stFrames st2 + 1
          , stSimSteps = stSimSteps st2 + stepsRun
          , stFpsEma = fps'
          }

-- | @n@ pure time advances, no sampling.
advanceTimes :: LoopConfig -> Int -> ActiveSpell -> ActiveSpell
advanceTimes cfg n spell0 = go n spell0
  where
    dt = FrameInput (DeltaTime (lcSimDt cfg))
    go k s
      | k <= 0 = s
      | otherwise = go (k - 1) (advanceSpell dt s)

-- | Where the arrow keys move us. Pressing both, or having nothing to
-- switch to, leaves the index alone — and an unchanged index means no
-- re-cast at all.
shiftIndex :: LoopConfig -> DemoInput -> Int -> Int
shiftIndex cfg input i = case lcSpellPaths cfg of
  [] -> i
  ps ->
    let delta = (if diNextSpell input then 1 else 0) - (if diPrevSpell input then 1 else 0)
     in (i + delta) `mod` length ps

normalizeIndex :: LoopConfig -> Int -> Int
normalizeIndex cfg i = case lcSpellPaths cfg of
  [] -> 0
  ps -> i `mod` length ps

pathAt :: LoopConfig -> Int -> FilePath
pathAt cfg i = case lcSpellPaths cfg of
  [] -> ""
  ps -> ps !! (i `mod` length ps)

-- | @R@: re-cast the spell that is already loaded (age back to zero). It
-- deliberately does not re-read the file — that is what hot reload is for.
recastOnRequest :: LoopConfig -> DemoInput -> LoopState -> LoopState
recastOnRequest cfg input st
  | not (diRecast input) = st
  | otherwise = case stCircle st of
      Nothing -> st
      Just circle -> recastFrom cfg circle st

-- | Re-cast from a known-good circle, counting the cast.
recastFrom :: LoopConfig -> Circle -> LoopState -> LoopState
recastFrom cfg circle st =
  case castSpell (CastRequest circle (lcCastCtx cfg)) of
    Right fresh -> st {stSpell = Just fresh, stCasts = stCasts st + 1}
    Left _ -> st {stSpell = Nothing}

-- | Fold a load result into the state: success swaps in the new spell and
-- counts the cast, failure keeps the old spell running and records the
-- full error for the HUD.
applyLoad :: Double -> LoopState -> Either String (Circle, ActiveSpell) -> LoopState
applyLoad t st = \case
  Left err -> st {stReload = ReloadFailed t err}
  Right (circle, spell) ->
    st
      { stCircle = Just circle
      , stSpell = Just spell
      , stCasts = stCasts st + 1
      , stReload = ReloadOk t
      }

-- | Read + decode + cast. The error side carries the rendered text the
-- HUD shows — 'renderLoadError' finally has a call site (ADR-0005).
loadAndCast
  :: (FileWatch :> es)
  => LoopConfig
  -> FilePath
  -> Eff es (Either String (Circle, ActiveSpell))
loadAndCast cfg path = do
  bytesOrErr <- readBytes path
  pure (bytesOrErr >>= decodeAndCast)
  where
    decodeAndCast :: BS.ByteString -> Either String (Circle, ActiveSpell)
    decodeAndCast bytes = do
      circle <- either (Left . renderLoadError) Right (loadCircle bytes)
      spell <-
        either
          (Left . show)
          Right
          (castSpell (CastRequest circle (lcCastCtx cfg)))
      pure (circle, spell)
