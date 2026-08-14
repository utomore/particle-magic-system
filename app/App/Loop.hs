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
  , ViewState (..)
  , defaultCamera
  , defaultViewState
  , applyViewInput
  , flatViewFor
  , orbitDegreesPerPixel
  , depthTintStrength
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

import Magic.Projection (ViewPlane (..))

import App.Camera (dolly, orbit)
import App.Effects
  ( Camera (..)
  , Clock
  , DemoInput (..)
  , FileWatch
  , FlatView (..)
  , HudView (..)
  , Raylib
  , ReloadStatus (..)
  , ViewMode (..)
  , checkChanged
  , drawFlat
  , drawHud
  , drawScene
  , now
  , pollInput
  , readBytes
  , shouldClose
  , windowSize
  , withFrame
  , withWindow
  )
import App.Hud (fpsEma)
import App.Render.Flat (panBy, resizeTo, zoomAt)

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

-- | Screen scale of the 2D backend, in pixels per world unit. Together
-- with 'flatViewFor' this is the whole presentation policy of the flat
-- path — deliberately shell-side constants (func-spec 0008 §4.6), not
-- part of the frozen projection surface.
flatPixelsPerUnit :: Float
flatPixelsPerUnit = 60

-- | The flat view for a window size and plane. The side view puts the
-- caster near the bottom (spells fire upwards, so the headroom goes
-- above); the top view centres the world origin, since a formation
-- spreads out around it.
flatViewFor :: (Int, Int) -> ViewPlane -> FlatView
flatViewFor (w, h) plane =
  FlatView
    { fvPlane = plane
    , fvScreenSize = (w, h)
    , fvOrigin = case plane of
        SideXY -> (fw * 0.5, fh * 0.8)
        TopXZ -> (fw * 0.5, fh * 0.5)
    , fvPixelsPerUnit = flatPixelsPerUnit
    , fvDepthTint = 0
    }
  where
    fw = fromIntegral w
    fh = fromIntegral h

-- | How far one pixel of mouse drag turns the 3D camera.
orbitDegreesPerPixel :: Float
orbitDegreesPerPixel = 0.3

-- | How dark the far end of the batch goes when the 2D depth tint is
-- switched on. Strong enough to read as depth, short of black — a
-- particle that vanishes entirely is worse than one that reads flat.
depthTintStrength :: Float
depthTintStrength = 0.55

-- | Everything about how the frame is observed, and nothing about what
-- is being observed (func-spec 0013 §4). Keeping the four pieces in one
-- record is what lets the whole scheme be one pure function of the
-- frame's input, asserted headless.
data ViewState = ViewState
  { vsMode :: !ViewMode
  , vsPlane :: !ViewPlane
  -- ^ Remembered across backends, so the plane can be chosen in 3D.
  , vsCamera :: !Camera
  , vsFlat :: !FlatView
  }
  deriving (Eq, Show)

-- | The state a demo starts in: 'defaultCamera', side view, no pan, no
-- zoom, no tint.
defaultViewState :: (Int, Int) -> Camera -> ViewState
defaultViewState size cam =
  ViewState
    { vsMode = View3D
    , vsPlane = SideXY
    , vsCamera = cam
    , vsFlat = flatViewFor size SideXY
    }

-- | The view state machine: the discrete switches (Tab, V, T) first,
-- then the continuous steering (drag, wheel) of whichever view is live.
--
-- Pressing several keys on one frame is defined rather than forbidden:
-- the backend switches first, then the plane, then the tint. The plane
-- is remembered across backends, so it can be chosen while still in 3D
-- — and choosing it re-derives the 2D view, since a pan and a zoom made
-- for one pair of axes mean nothing for the other.
--
-- Steering is dispatched by the live backend, so the mouse drives what
-- is on screen and only that: the 2D pan cannot secretly move the 3D
-- camera, and vice versa. Idle input is the identity on the nose (each
-- of 'orbit', 'dolly', 'panBy', 'zoomAt' is), which is what makes a demo
-- nobody touches render exactly what func-spec 0008 delivered.
applyViewInput :: DemoInput -> ViewState -> ViewState
applyViewInput input = steer . toggleTint . togglePlane . toggleBackend
  where
    toggleBackend vs
      | not (diToggleBackend input) = vs
      | otherwise = case vsMode vs of
          View3D -> vs {vsMode = View2D (vsPlane vs)}
          View2D _ -> vs {vsMode = View3D}

    togglePlane vs
      | not (diTogglePlane input) = vs
      | otherwise =
          let plane' = flipPlane (vsPlane vs)
           in vs
                { vsPlane = plane'
                , vsMode = case vsMode vs of
                    View3D -> View3D
                    View2D _ -> View2D plane'
                , vsFlat = rebasedFlat plane' (vsFlat vs)
                }

    toggleTint vs
      | not (diToggleTint input) = vs
      | otherwise =
          vs
            { vsFlat =
                (vsFlat vs)
                  { fvDepthTint =
                      if fvDepthTint (vsFlat vs) > 0 then 0 else depthTintStrength
                  }
            }

    steer vs = case vsMode vs of
      View3D -> vs {vsCamera = dolly (diWheel input) (orbit dragDegrees (vsCamera vs))}
      View2D _ -> vs {vsFlat = zoomAt (diCursor input) (diWheel input) (panBy panPixels (vsFlat vs))}

    dragDegrees = case diOrbitDrag input of
      Nothing -> (0, 0)
      -- Dragging right turns the camera left around the target (the
      -- world follows the hand), and dragging down raises it.
      Just (dx, dy) -> (negate dx * orbitDegreesPerPixel, dy * orbitDegreesPerPixel)

    panPixels = case diPanDrag input of
      Nothing -> (0, 0)
      Just d -> d

    -- A fresh 2D view for a new plane, keeping the one setting that is
    -- about the tint rather than about the axes.
    rebasedFlat plane fv =
      (flatViewFor (fvScreenSize fv) plane) {fvDepthTint = fvDepthTint fv}

    flipPlane SideXY = TopXZ
    flipPlane TopXZ = SideXY

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
  , stView :: !ViewMode
  -- ^ Which backend draws (func-spec 0008). Observation-side state: it
  -- is orthogonal to the simulation and survives reloads and re-casts.
  , stPlane :: !ViewPlane
  -- ^ The remembered orthographic plane, also while in 3D.
  , stCamera :: !Camera
  -- ^ Where the 3D camera has been orbited to (func-spec 0013). Same
  -- observation-side status as 'stView': moving it cannot disturb a
  -- running spell.
  , stFlat :: !FlatView
  -- ^ The live 2D view — pan, zoom, screen size, depth tint.
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
        , stView = vsMode view0
        , stPlane = vsPlane view0
        , stCamera = vsCamera view0
        , stFlat = vsFlat view0
        }
  where
    view0 = defaultViewState (lcWindowSize cfg) (lcCamera cfg)

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
      -- Polled every frame rather than taken from the config: the window
      -- is resizable, so the 2D screen mapping is state, not a constant.
      size <- windowSize
      let index' = shiftIndex cfg input (stIndex st)
          -- Purely observational: the view never feeds back into the
          -- simulation, so switching it cannot disturb a running spell.
          view' =
            applyViewInput
              input
              ViewState
                { vsMode = stView st
                , vsPlane = stPlane st
                , vsCamera = stCamera st
                , vsFlat = resizeTo size (stFlat st)
                }

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
              , hvView = vsMode view'
              , hvCamera = vsCamera view'
              , hvFlat = vsFlat view'
              }

      withFrame $ do
        -- One 'FrameOutput', two consumers (ADR-0008): the 3D backend
        -- takes it through a perspective camera, the 2D one through an
        -- orthographic projection. Neither the sampling above nor the
        -- output itself knows which.
        case vsMode view' of
          View3D -> drawScene (vsCamera view') (batches output')
          View2D _ -> drawFlat (vsFlat view') (batches output')
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
          , stView = vsMode view'
          , stPlane = vsPlane view'
          , stCamera = vsCamera view'
          , stFlat = vsFlat view'
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
