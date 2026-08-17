{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | The shell's three named effects (func-spec 0001 §4.7): 'Clock',
-- 'FileWatch', 'Raylib'. Each has an IO interpreter and a test
-- interpreter ('App.TestInterp'); the pair-call raylib operations are
-- higher-order (bracket pattern) so begin/end can never be unpaired.
--
-- This module is renderer-agnostic on purpose: 'Camera' is our own type,
-- not raylib's, so the loop and the test interpreters never touch
-- h-raylib. Only 'App.Render.Raylib3D' (the IO interpreter of 'Raylib')
-- does.
module App.Effects
  ( -- * Camera (renderer-agnostic)
    Camera (..)

    -- * View selection (func-spec 0008)
  , ViewMode (..)
  , FlatView (..)

    -- * Clock
  , Clock (..)
  , now
  , runClockIO

    -- * File watching
  , FileWatch (..)
  , checkChanged
  , readBytes
  , writeBytes
  , scanDir
  , runFileWatchIO

    -- * Observation / input vocabulary (renderer-agnostic)
  , HudView (..)
  , ReloadStatus (..)
  , PanelView (..)
  , panelViewClosed
  , DemoInput (..)
  , noInput

    -- * Raylib (definition only; IO interpreter in App.Render.Raylib3D)
  , Raylib (..)
  , withWindow
  , withFrame
  , drawBatch
  , drawScene
  , drawFrame
  , drawFlat
  , drawHud
  , pollInput
  , shouldClose
  , windowSize
  ) where

import qualified Data.ByteString as BS
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import GHC.Clock (getMonotonicTime)
import Magic.Interface (RenderBatch, V3)
import Magic.Projection (ViewPlane)
import System.IO.Error (catchIOError)

import App.HotReload (checkStampIO, newWatchState, scanDirIO, writeBytesIO)
import App.Render.Post (VisualSettings)

-- | Renderer-agnostic camera description; the raylib backend converts it.
data Camera = Camera
  { camPos :: !V3
  , camTarget :: !V3
  , camUp :: !V3
  , camFovY :: !Float
  }
  deriving (Eq, Show)

-- | Which backend the frame is drawn through (func-spec 0008 §4.3). The
-- simulation is unaffected by it: 'FrameOutput' carries no dimension
-- assumption (ADR-0008), so this only selects the consumer.
data ViewMode
  = View3D
  -- ^ Perspective camera, quads billboarded towards it.
  | View2D !ViewPlane
  -- ^ Orthographic projection onto the given plane, painter-sorted and
  -- drawn in screen pixels — how a real 2D host would consume us.
  deriving (Eq, Show)

-- | Everything the flat backend needs to place a projected particle on
-- screen. Renderer-agnostic (pixels, not raylib), and not frozen: origin
-- and scale are shell-side presentation choices.
data FlatView = FlatView
  { fvPlane :: !ViewPlane
  , fvScreenSize :: !(Int, Int)
  , fvOrigin :: !(Float, Float)
  -- ^ Where the world origin sits, in screen pixels.
  , fvPixelsPerUnit :: !Float
  , fvDepthTint :: !Float
  -- ^ How much the dropped axis darkens a particle, in @[0, 1]@ (0 =
  -- off, the default). The top view stacks the whole spell onto one
  -- plane, and without a depth cue the result reads as a flat blob;
  -- shading by depth is the cheapest cue that needs no new geometry
  -- (func-spec 0013 §2). Presentation state, so it lives here with the
  -- origin and the scale.
  , fvDepthScale :: !Float
  -- ^ How strongly depth is allowed to change a particle's on-screen
  -- size (func-spec 0021 S6, the second cue after the tint). 1 = off and
  -- the default; at @k@ the nearest particle of the batch is drawn @k@
  -- times its size and the furthest @1/k@ times, restoring the size
  -- gradient an orthographic projection deletes by definition.
  , fvOutlineFloor :: !Float
  -- ^ Smallest on-screen quad edge, in pixels (0 = off, the default).
  -- Shrinking the far end is only readable if the near end keeps an edge
  -- to read; this is the floor that guarantees one.
  }
  deriving (Eq, Show)

-- | Monotonic clock, in seconds.
data Clock :: Effect where
  Now :: Clock m Double

type instance DispatchOf Clock = Dynamic

now :: (Clock :> es) => Eff es Double
now = send Now

runClockIO :: (IOE :> es) => Eff (Clock : es) a -> Eff es a
runClockIO = interpret $ \_ -> \case
  Now -> liftIO getMonotonicTime

-- | Watching + reading the watched file. 'CheckChanged' reports whether
-- the file's mtime changed since the previous call (the first observation
-- is the baseline, not a change).
data FileWatch :: Effect where
  CheckChanged :: FilePath -> FileWatch m Bool
  ReadBytes :: FilePath -> FileWatch m (Either String BS.ByteString)
  -- | Every @*.json@ under a directory, sorted (func-spec 0014 S3).
  -- 'CheckChanged' asks whether one file moved; this asks which files
  -- there are, so the demo's spell list can grow and shrink while it
  -- runs. Added the additive way every effect operation has been added
  -- since 0005: a new constructor, no existing signature touched.
  ScanDir :: FilePath -> FileWatch m [FilePath]
  -- | Write a file (func-spec 0024 S5): the parameter panel's save.
  --
  -- The first /write/ in a vocabulary that was read-only for twenty-three
  -- specs, and added the same additive way 'ScanDir' was — a new
  -- constructor, no existing signature touched. It lives on 'FileWatch'
  -- rather than on a new effect because the file being written is the
  -- file being watched, and a save that the watcher then reports as a
  -- change is the single most important interaction either of them has
  -- (func-spec 0024 §2.5).
  WriteBytes :: FilePath -> BS.ByteString -> FileWatch m (Either String ())

type instance DispatchOf FileWatch = Dynamic

checkChanged :: (FileWatch :> es) => FilePath -> Eff es Bool
checkChanged = send . CheckChanged

readBytes :: (FileWatch :> es) => FilePath -> Eff es (Either String BS.ByteString)
readBytes = send . ReadBytes

writeBytes :: (FileWatch :> es) => FilePath -> BS.ByteString -> Eff es (Either String ())
writeBytes path = send . WriteBytes path

scanDir :: (FileWatch :> es) => FilePath -> Eff es [FilePath]
scanDir = send . ScanDir

-- | mtime polling interpreter (ADR-0005 hot reload; fsnotify deliberately
-- avoided for the skeleton). @pollInterval@ throttles filesystem stats —
-- calls arriving earlier than that since the last stat report 'False' —
-- and @scanInterval@ does the same for directory listings, on its own
-- (slower) clock.
runFileWatchIO :: (IOE :> es) => Double -> Double -> Eff (FileWatch : es) a -> Eff es a
runFileWatchIO pollInterval scanInterval action = do
  st <- liftIO (newWatchState pollInterval scanInterval)
  interpret
    ( \_ -> \case
        CheckChanged path -> liftIO (checkStampIO st path)
        ReadBytes path -> liftIO (readBytesIO path)
        ScanDir dir -> liftIO (scanDirIO st dir)
        WriteBytes path bytes -> liftIO (writeBytesIO path bytes)
    )
    action
  where
    readBytesIO :: FilePath -> IO (Either String BS.ByteString)
    readBytesIO path =
      fmap Right (BS.readFile path)
        `catchIOError` \e -> pure (Left (show e))

-- | Everything the HUD overlay shows (func-spec 0005 §4.2). Computed by
-- the loop as a plain value, so what the player would read off the screen
-- is exactly what the headless tests assert on.
data HudView = HudView
  { hvFps :: !Double
  -- ^ EMA-smoothed frames per second (the shell computes it; raylib's own
  -- @getFPS@ would have no meaning under the test interpreters).
  , hvParticles :: !Int
  -- ^ Total particles across this frame's batches.
  , hvSpellPath :: !FilePath
  , hvSpellAge :: !Double
  , hvReload :: !ReloadStatus
  , hvView :: !ViewMode
  -- ^ The backend this frame was drawn through (func-spec 0008): the HUD
  -- is where a headless test reads the view state off.
  , hvCamera :: !Camera
  -- ^ Where the 3D camera is, live (func-spec 0013). Shown as its orbit
  -- summary, and — like 'hvView' — this is how a headless test reads the
  -- camera state off without a window.
  , hvFlat :: !FlatView
  -- ^ The live 2D view: scale, pan and depth tint. Only meaningful while
  -- 'hvView' is 'View2D', but always carried, for the same reason
  -- 'hvView' carries the plane in 3D — the state exists either way.
  , hvVisual :: !VisualSettings
  -- ^ Which of func-spec 0023's effects are on. Carried here for the
  -- reason 'hvView' and 'hvCamera' are: the HUD is where a headless test
  -- reads observation-side state off without a window.
  , hvPanel :: !PanelView
  -- ^ The parameter panel (func-spec 0024 S4). Same reason again — and
  -- one more: the panel is the first piece of this demo that can change
  -- what is /simulated/, so being able to read its whole state off a
  -- headless frame is what makes S5's laws assertable at all.
  }
  deriving (Eq, Show)

-- | What the HUD shows of the parameter panel.
--
-- Plain pairs rather than the panel's own 'App.Panel.ParamSpec': this
-- record is part of the observation vocabulary, which "App.Panel" imports
-- — so it must not know about "App.Panel" in return.
data PanelView = PanelView
  { pvOpen :: !Bool
  , pvDirty :: !Bool
  -- ^ Edited since the last save. Shown, because an author who quits with
  -- this set loses work, and nothing else on screen would say so.
  , pvIndex :: !Int
  , pvParams :: ![(String, Double)]
  -- ^ Empty while the panel is closed: the list costs a save\/load round
  -- trip of the circle to build, and a closed panel is not showing it.
  , pvNote :: !(Maybe String)
  }
  deriving (Eq, Show)

-- | The panel as it starts, and as it stays for a demo nobody opens it in.
panelViewClosed :: PanelView
panelViewClosed =
  PanelView {pvOpen = False, pvDirty = False, pvIndex = 0, pvParams = [], pvNote = Nothing}

-- | Outcome of the most recent load attempt. A failure keeps the previous
-- spell running and puts the full error text on screen (ADR-0005's
-- "error message quality needs investment" clause).
data ReloadStatus
  = ReloadIdle
  -- ^ No reload since startup.
  | ReloadOk !Double
  -- ^ Succeeded, at that cast-clock time.
  | ReloadFailed !Double !String
  -- ^ Failed, at that time, with the full rendered error.
  deriving (Eq, Show)

-- | This frame's input snapshot. Our own type, so the loop and the test
-- interpreters stay free of raylib key codes.
data DemoInput = DemoInput
  { diNextSpell :: !Bool
  , diPrevSpell :: !Bool
  , diRecast :: !Bool
  , diToggleBackend :: !Bool
  -- ^ Tab: switch between the 3D and the 2D backend.
  , diTogglePlane :: !Bool
  -- ^ V: switch the orthographic plane (side ↔ top).
  , diToggleTint :: !Bool
  -- ^ T: switch the 2D depth tint on and off (func-spec 0013 §4).
  , diToggleReadability :: !Bool
  -- ^ G: switch the 2D depth flattening and outline floor on and off
  -- (func-spec 0021 S6) — the second-tier top-view cues, kept on their
  -- own key so the first-tier tint can still be judged alone.
  , diToggleTrails :: !Bool
  -- ^ 1: velocity-stretched trails (func-spec 0023 S6).
  , diToggleBloom :: !Bool
  -- ^ 2: the bloom chain (S7).
  , diToggleSoft :: !Bool
  -- ^ 3: soft particles (S8).
  , diToggleScene :: !Bool
  -- ^ 4: the test scene geometry (§2.6).
  --
  -- Four keys rather than one, because the completion definition asks for
  -- each effect to be switchable /independently/: judging whether bloom
  -- helps means seeing the same frame with and without it and nothing
  -- else changed.
  , diOrbitDrag :: !(Maybe (Float, Float))
  -- ^ Mouse drag while the left button is held, in pixels, or 'Nothing'
  -- when nothing is being dragged. Drives the 3D orbit; the pixels are
  -- turned into degrees by the loop, not by the backend.
  , diPanDrag :: !(Maybe (Float, Float))
  -- ^ The same drag, offered to the 2D path as a screen-pixel pan. Two
  -- fields rather than one because the two views read the same gesture
  -- differently, and a backend that only supports one of them can say so
  -- by leaving the other 'Nothing'.
  , diWheel :: !Float
  -- ^ Wheel notches this frame, positive away from the user. Zooms
  -- whichever view is live.
  , diCursor :: !(Float, Float)
  -- ^ Cursor position in screen pixels — the fixed point of the 2D zoom.
  , diTogglePanel :: !Bool
  -- ^ P: open and close the parameter panel (func-spec 0024 S4).
  , diPanelPrev :: !Bool
  -- ^ @[@: select the previous parameter.
  , diPanelNext :: !Bool
  -- ^ @]@: select the next one.
  --
  -- Its own pair of keys rather than the arrows, which already switch
  -- spell: a modal meaning for a key that has a meaning is how a demo
  -- becomes unpredictable, and the panel is supposed to be the part that
  -- makes the demo /easier/ to steer.
  , diPanelDec :: !Bool
  -- ^ @-@: nudge the selected parameter down one step.
  , diPanelInc :: !Bool
  -- ^ @=@: nudge it up one step.
  , diPanelSave :: !Bool
  -- ^ S: write the edited circle back to its file.
  }
  deriving (Eq, Show)

noInput :: DemoInput
noInput =
  DemoInput
    { diNextSpell = False
    , diPrevSpell = False
    , diRecast = False
    , diToggleBackend = False
    , diTogglePlane = False
    , diToggleTint = False
    , diToggleReadability = False
    , diToggleTrails = False
    , diToggleBloom = False
    , diToggleSoft = False
    , diToggleScene = False
    , diOrbitDrag = Nothing
    , diPanDrag = Nothing
    , diWheel = 0
    , diCursor = (0, 0)
    , diTogglePanel = False
    , diPanelPrev = False
    , diPanelNext = False
    , diPanelDec = False
    , diPanelInc = False
    , diPanelSave = False
    }

-- | Paired-call raylib operations (bracket pattern, higher-order effect)
-- plus the draw and input commands. No raylib types appear here.
--
-- 'DrawScene' supersedes 'DrawBatch' in the loop: blend grouping, the
-- ground grid and the shared mesh update are whole-scene decisions that a
-- per-batch operation cannot express. 'DrawBatch' is kept because the
-- 0001 effect interface is frozen and frozen interfaces do not shrink.
data Raylib :: Effect where
  WithWindow :: Int -> Int -> String -> m a -> Raylib m a
  WithFrame :: m a -> Raylib m a
  DrawBatch :: Camera -> RenderBatch -> Raylib m ()
  ShouldClose :: Raylib m Bool
  DrawScene :: Camera -> [RenderBatch] -> Raylib m ()
  DrawHud :: HudView -> Raylib m ()
  PollInput :: Raylib m DemoInput
  -- | The 2D path (func-spec 0008), added the same additive way
  -- 'DrawScene' was: the same batches, consumed through an orthographic
  -- projection instead of a camera.
  DrawFlat :: FlatView -> [RenderBatch] -> Raylib m ()
  -- | The window's current size in pixels (func-spec 0013): a resizable
  -- window means the 2D view's screen mapping is no longer a constant,
  -- and the loop is where that mapping is decided.
  WindowSize :: Raylib m (Int, Int)
  -- | The 3D path with func-spec 0023's effects (S5–S9), added the same
  -- additive way 'DrawScene' and 'DrawFlat' were.
  --
  -- It supersedes 'DrawScene' in the loop and carries one thing more: the
  -- 'VisualSettings' that decide the frame's render plan
  -- ('App.Render.Post.framePlan') — scene geometry, offscreen targets,
  -- the bloom chain, the soft-particle fade distance and whether trail
  -- batches are stretched. With every effect off the plan is a single
  -- pass straight to the screen, so this draws exactly what 'DrawScene'
  -- draws and the zero-ripple law is the default rather than a special
  -- case.
  DrawFrame :: Camera -> VisualSettings -> [RenderBatch] -> Raylib m ()

type instance DispatchOf Raylib = Dynamic

withWindow :: (Raylib :> es) => Int -> Int -> String -> Eff es a -> Eff es a
withWindow w h title = send . WithWindow w h title

withFrame :: (Raylib :> es) => Eff es a -> Eff es a
withFrame = send . WithFrame

drawBatch :: (Raylib :> es) => Camera -> RenderBatch -> Eff es ()
drawBatch cam = send . DrawBatch cam

drawScene :: (Raylib :> es) => Camera -> [RenderBatch] -> Eff es ()
drawScene cam = send . DrawScene cam

drawFrame :: (Raylib :> es) => Camera -> VisualSettings -> [RenderBatch] -> Eff es ()
drawFrame cam settings = send . DrawFrame cam settings

drawFlat :: (Raylib :> es) => FlatView -> [RenderBatch] -> Eff es ()
drawFlat fv = send . DrawFlat fv

drawHud :: (Raylib :> es) => HudView -> Eff es ()
drawHud = send . DrawHud

pollInput :: (Raylib :> es) => Eff es DemoInput
pollInput = send PollInput

shouldClose :: (Raylib :> es) => Eff es Bool
shouldClose = send ShouldClose

windowSize :: (Raylib :> es) => Eff es (Int, Int)
windowSize = send WindowSize
