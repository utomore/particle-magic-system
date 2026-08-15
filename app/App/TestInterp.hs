{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeOperators #-}

-- | Test interpreters for the shell effects (func-spec 0001 §4.7,
-- extended by 0005 §4.3): virtual clock, scripted file watch, headless
-- renderer. They compile as part of the executable AND the test suite so
-- they cannot rot.
module App.TestInterp
  ( runClockVirtual
  , runFileWatchScript
  , runFileWatchScriptMap
  , runFileWatchScriptDirs
  , HeadlessLog (..)
  , runRaylibHeadless
  , runRaylibHeadlessWith
  ) where

import qualified Data.ByteString as BS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (localSeqUnlift, reinterpret)
import Effectful.State.Static.Local (evalState, get, put, runState, state)
import Magic.Interface (BlendMode, RenderBatch (..), pbCount)

import App.Effects
  ( Clock (..)
  , DemoInput (..)
  , FileWatch (..)
  , FlatView (..)
  , HudView
  , Raylib (..)
  , noInput
  )
import Magic.Projection (ViewPlane)

-- | A monotonic clock that advances by a fixed amount per 'Now' call
-- (one call per frame in the loop => one virtual frame per call).
runClockVirtual :: Double -> Eff (Clock : es) a -> Eff es a
runClockVirtual perCall =
  reinterpret (evalState (0 :: Double)) $ \_ -> \case
    Now -> state (\t -> (t, t + perCall))

-- | Scripted file watch: the n-th 'CheckChanged' call answers the n-th
-- list element (exhausted script => no more changes); 'ReadBytes' always
-- serves the given bytes. 'ScanDir' answers "no listing", so a run driven
-- by this interpreter behaves exactly as it did before func-spec 0014
-- existed.
runFileWatchScript
  :: BS.ByteString
  -> [Bool]
  -> Eff (FileWatch : es) a
  -> Eff es a
runFileWatchScript bytes script =
  reinterpret (evalState script) $ \_ -> \case
    CheckChanged _ ->
      get >>= \case
        [] -> pure False
        (c : cs) -> put cs >> pure c
    ReadBytes _ -> pure (Right bytes)
    ScanDir _ -> pure []

-- | Multi-file scripted watch (func-spec 0005 §4.3): each path serves its
-- own bytes and its own per-path change script, so spell switching can be
-- driven headless. An unknown path reads as a missing file, which is
-- exactly the error path the loop must survive.
runFileWatchScriptMap
  :: Map FilePath (BS.ByteString, [Bool])
  -> Eff (FileWatch : es) a
  -> Eff es a
runFileWatchScriptMap table0 = runFileWatchScriptDirs table0 []

-- | As 'runFileWatchScriptMap', plus a script for 'ScanDir' (func-spec
-- 0014 S3): the n-th scan answers the n-th listing, and once the script
-- runs out the last listing is repeated forever.
--
-- Repeating rather than emptying is what models the real interpreter: a
-- throttled 'App.HotReload.scanDirIO' between scans repeats its cached
-- answer, it does not report an empty directory. An /empty/ script (what
-- 'runFileWatchScriptMap' passes) means "no listing at all", which is the
-- one answer the loop is required to ignore — that is the zero-ripple
-- law every pre-0014 test rides on.
runFileWatchScriptDirs
  :: Map FilePath (BS.ByteString, [Bool])
  -> [[FilePath]]
  -> Eff (FileWatch : es) a
  -> Eff es a
runFileWatchScriptDirs table0 dirScript0 =
  reinterpret (evalState (scripts0, dirScript0)) $ \_ -> \case
    CheckChanged path ->
      get @ScriptState >>= \(scripts, dirs) -> case M.lookup path scripts of
        Just (c : cs) -> put (M.insert path cs scripts, dirs) >> pure c
        _ -> pure False
    ReadBytes path -> pure $ case M.lookup path table0 of
      Just (bytes, _) -> Right bytes
      Nothing -> Left ("no such file (test script): " ++ path)
    ScanDir _ ->
      get @ScriptState >>= \(scripts, dirs) -> case dirs of
        [] -> pure []
        [listing] -> pure listing
        (listing : rest) -> put (scripts, rest) >> pure listing
  where
    scripts0 = M.map snd table0

-- | The scripted watch's carried state: the per-path change scripts, and
-- the remaining directory listings.
type ScriptState = (Map FilePath [Bool], [[FilePath]])

-- | What the headless renderer observed (assertions for T7/T8 and for
-- func-spec 0005 §8).
data HeadlessLog = HeadlessLog
  { hlFrames :: !Int
  -- ^ WithFrame brackets entered.
  , hlDrawCalls :: !Int
  -- ^ Batches received: @DrawBatch@ counts 1, @DrawScene@ counts one per
  -- batch it carries. With today's one-batch-per-frame output this is the
  -- same number the 0001 assertions were written against.
  , hlScenes :: ![(BlendMode, Int)]
  -- ^ @(blend, particle count)@ summary of every batch handed to
  -- 'DrawScene', in order.
  , hlHuds :: ![HudView]
  -- ^ Every 'DrawHud' payload, in order.
  , hlFlats :: ![(ViewPlane, BlendMode, Int)]
  -- ^ @(plane, blend, particle count)@ summary of every batch handed to
  -- 'DrawFlat', in order. A run that never toggles the backend leaves
  -- this empty — a free regression sentinel for the 3D path.
  }
  deriving (Eq, Show)

-- | Records draw traffic instead of rendering; 'ShouldClose' answers
-- 'False' for the first @frameLimit@ polls, then 'True'. Input is always
-- idle — see 'runRaylibHeadlessWith' to script it.
runRaylibHeadless :: Int -> Eff (Raylib : es) a -> Eff es (a, HeadlessLog)
runRaylibHeadless = runRaylibHeadlessWith []

-- | As 'runRaylibHeadless', with a scripted input sequence: the n-th
-- 'PollInput' answers the n-th element, and an exhausted script answers
-- 'noInput'.
runRaylibHeadlessWith
  :: [DemoInput]
  -> Int
  -> Eff (Raylib : es) a
  -> Eff es (a, HeadlessLog)
runRaylibHeadlessWith inputs frameLimit =
  reinterpret (fmap repack . runState initial) $ \env -> \case
    WithWindow w h _ inner -> do
      -- The headless "window" is whatever size the loop asked for, so
      -- 'WindowSize' answers without any interpreter configuration and a
      -- run that never resizes sees exactly the configured size.
      state (\hc -> ((), hc {hcWindow = (w, h)}))
      localSeqUnlift env (\unlift -> unlift inner)
    WindowSize -> state (\hc -> (hcWindow hc, hc))
    WithFrame inner -> do
      state (\h -> ((), h {hcFrames = hcFrames h + 1}))
      localSeqUnlift env (\unlift -> unlift inner)
    DrawBatch _ _ ->
      state (\h -> ((), h {hcDraws = hcDraws h + 1}))
    ShouldClose ->
      state (\h -> (hcPolls h >= frameLimit, h {hcPolls = hcPolls h + 1}))
    DrawScene _ batches ->
      state $ \h ->
        ( ()
        , h
            { hcDraws = hcDraws h + length batches
            , hcScenes = reverse (map summarize batches) ++ hcScenes h
            }
        )
    DrawFlat fv batches ->
      state $ \h ->
        ( ()
        , h
            { hcDraws = hcDraws h + length batches
            , hcFlats = reverse (map (summarizeFlat (fvPlane fv)) batches) ++ hcFlats h
            }
        )
    DrawHud view ->
      state (\h -> ((), h {hcHuds = view : hcHuds h}))
    PollInput ->
      state $ \h -> case hcInputs h of
        [] -> (noInput, h)
        (i : is) -> (i, h {hcInputs = is})
  where
    summarize b = (rbBlend b, pbCount (rbParticles b))
    summarizeFlat plane b = (plane, rbBlend b, pbCount (rbParticles b))
    initial =
      HeadlessCount
        { hcFrames = 0
        , hcDraws = 0
        , hcPolls = 0
        , hcScenes = []
        , hcHuds = []
        , hcFlats = []
        , hcInputs = inputs
        , hcWindow = (1280, 720)
        }
    repack (a, h) =
      ( a
      , HeadlessLog
          { hlFrames = hcFrames h
          , hlDrawCalls = hcDraws h
          , hlScenes = reverse (hcScenes h)
          , hlHuds = reverse (hcHuds h)
          , hlFlats = reverse (hcFlats h)
          }
      )

-- | Accumulator (lists held reversed; 'repack' restores order).
data HeadlessCount = HeadlessCount
  { hcFrames :: !Int
  , hcDraws :: !Int
  , hcPolls :: !Int
  , hcScenes :: ![(BlendMode, Int)]
  , hcHuds :: ![HudView]
  , hcFlats :: ![(ViewPlane, BlendMode, Int)]
  , hcInputs :: ![DemoInput]
  , hcWindow :: !(Int, Int)
  -- ^ Size the loop opened its window at; what 'WindowSize' answers,
  -- until a test grows a way to script a resize.
  }
