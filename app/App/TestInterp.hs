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
  , HeadlessLog (..)
  , runRaylibHeadless
  , runRaylibHeadlessWith
  ) where

import qualified Data.ByteString as BS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (localSeqUnlift, reinterpret)
import Effectful.State.Static.Local (evalState, get, put, runState, state)
import Magic.Interface (BlendMode, RenderBatch (..), pbCount)

import App.Effects
  ( Clock (..)
  , DemoInput (..)
  , FileWatch (..)
  , HudView
  , Raylib (..)
  , noInput
  )

-- | A monotonic clock that advances by a fixed amount per 'Now' call
-- (one call per frame in the loop => one virtual frame per call).
runClockVirtual :: Double -> Eff (Clock : es) a -> Eff es a
runClockVirtual perCall =
  reinterpret (evalState (0 :: Double)) $ \_ -> \case
    Now -> state (\t -> (t, t + perCall))

-- | Scripted file watch: the n-th 'CheckChanged' call answers the n-th
-- list element (exhausted script => no more changes); 'ReadBytes' always
-- serves the given bytes.
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

-- | Multi-file scripted watch (func-spec 0005 §4.3): each path serves its
-- own bytes and its own per-path change script, so spell switching can be
-- driven headless. An unknown path reads as a missing file, which is
-- exactly the error path the loop must survive.
runFileWatchScriptMap
  :: Map FilePath (BS.ByteString, [Bool])
  -> Eff (FileWatch : es) a
  -> Eff es a
runFileWatchScriptMap table0 =
  reinterpret (evalState scripts0) $ \_ -> \case
    CheckChanged path ->
      get >>= \scripts -> case M.lookup path scripts of
        Just (c : cs) -> put (M.insert path cs scripts) >> pure c
        _ -> pure False
    ReadBytes path -> pure $ case M.lookup path table0 of
      Just (bytes, _) -> Right bytes
      Nothing -> Left ("no such file (test script): " ++ path)
  where
    scripts0 = M.map snd table0

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
    WithWindow _ _ _ inner -> localSeqUnlift env (\unlift -> unlift inner)
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
    DrawHud view ->
      state (\h -> ((), h {hcHuds = view : hcHuds h}))
    PollInput ->
      state $ \h -> case hcInputs h of
        [] -> (noInput, h)
        (i : is) -> (i, h {hcInputs = is})
  where
    summarize b = (rbBlend b, pbCount (rbParticles b))
    initial =
      HeadlessCount
        { hcFrames = 0
        , hcDraws = 0
        , hcPolls = 0
        , hcScenes = []
        , hcHuds = []
        , hcInputs = inputs
        }
    repack (a, h) =
      ( a
      , HeadlessLog
          { hlFrames = hcFrames h
          , hlDrawCalls = hcDraws h
          , hlScenes = reverse (hcScenes h)
          , hlHuds = reverse (hcHuds h)
          }
      )

-- | Accumulator (lists held reversed; 'repack' restores order).
data HeadlessCount = HeadlessCount
  { hcFrames :: !Int
  , hcDraws :: !Int
  , hcPolls :: !Int
  , hcScenes :: ![(BlendMode, Int)]
  , hcHuds :: ![HudView]
  , hcInputs :: ![DemoInput]
  }
