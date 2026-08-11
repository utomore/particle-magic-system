{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeOperators #-}

-- | Test interpreters for the shell effects (func-spec 0001 §4.7):
-- virtual clock, scripted file watch, headless renderer. They compile as
-- part of the executable AND the test suite so they cannot rot.
module App.TestInterp
  ( runClockVirtual
  , runFileWatchScript
  , HeadlessLog (..)
  , runRaylibHeadless
  ) where

import qualified Data.ByteString as BS
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (localSeqUnlift, reinterpret)
import Effectful.State.Static.Local (evalState, get, put, runState, state)

import App.Effects (Clock (..), FileWatch (..), Raylib (..))

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

-- | What the headless renderer observed (assertions for T7/T8).
data HeadlessLog = HeadlessLog
  { hlFrames :: !Int
  -- ^ WithFrame brackets entered.
  , hlDrawCalls :: !Int
  -- ^ DrawBatch commands received.
  }
  deriving (Eq, Show)

-- | Records draw traffic instead of rendering; 'ShouldClose' answers
-- 'False' for the first @frameLimit@ polls, then 'True'.
runRaylibHeadless :: Int -> Eff (Raylib : es) a -> Eff es (a, HeadlessLog)
runRaylibHeadless frameLimit =
  reinterpret (fmap repack . runState initial) $ \env -> \case
    WithWindow _ _ _ inner -> localSeqUnlift env (\unlift -> unlift inner)
    WithFrame inner -> do
      state (\(HeadlessCount fs ds cs) -> ((), HeadlessCount (fs + 1) ds cs))
      localSeqUnlift env (\unlift -> unlift inner)
    DrawBatch _ _ ->
      state (\(HeadlessCount fs ds cs) -> ((), HeadlessCount fs (ds + 1) cs))
    ShouldClose ->
      state
        ( \(HeadlessCount fs ds cs) ->
            (cs >= frameLimit, HeadlessCount fs ds (cs + 1))
        )
  where
    initial = HeadlessCount 0 0 0
    repack (a, HeadlessCount fs ds _) = (a, HeadlessLog fs ds)

data HeadlessCount = HeadlessCount !Int !Int !Int
