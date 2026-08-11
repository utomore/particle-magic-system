-- | Hot reload: pure change-detection decisions + the IO mtime-polling
-- state used by 'App.Effects.runFileWatchIO' (func-spec 0001 §2:
-- polling, not fsnotify — zero extra deps, no cross-platform traps).
--
-- The DECISION is pure and tested (T8): given a sequence of observed
-- stamps, reload exactly when a stamp differs from the previous one; the
-- first observation is the baseline and never triggers.
module App.HotReload
  ( -- * Pure decision (tested by HotReloadSpec)
    stampChanged
  , reloadPoints

    -- * IO polling state (consumed by runFileWatchIO)
  , WatchState
  , newWatchState
  , checkStampIO
  ) where

import qualified Data.Map.Strict as Map
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Time.Clock (UTCTime)
import GHC.Clock (getMonotonicTime)
import System.Directory (getModificationTime)
import System.IO.Error (catchIOError)

-- | @stampChanged lastSeen current@: has the file changed?
stampChanged :: (Eq t) => Maybe t -> t -> Bool
stampChanged Nothing _ = False
stampChanged (Just previous) current = previous /= current

-- | Indices (1-based, into the tail) at which a stamp sequence triggers a
-- reload: exactly where an observation differs from its predecessor.
reloadPoints :: (Eq t) => [t] -> [Int]
reloadPoints stamps =
  [ i
  | (i, previous, current) <- zip3 [1 ..] stamps (drop 1 stamps)
  , stampChanged (Just previous) current
  ]

-- | Per-path polling state: last poll instant (for throttling) and last
-- observed mtime (the baseline for 'stampChanged').
data WatchState = WatchState
  { wsPollInterval :: !Double
  , wsEntries :: !(IORef (Map.Map FilePath (Double, Maybe UTCTime)))
  }

newWatchState :: Double -> IO WatchState
newWatchState pollInterval = WatchState pollInterval <$> newIORef Map.empty

-- | Throttled mtime check. Stats the file at most once per poll interval;
-- in between (and on stat errors, e.g. mid-save on Windows) it reports
-- \"unchanged\".
checkStampIO :: WatchState -> FilePath -> IO Bool
checkStampIO st path = do
  tNow <- getMonotonicTime
  entries <- readIORef (wsEntries st)
  let entry = Map.lookup path entries
  case entry of
    Just (lastPoll, _)
      | tNow - lastPoll < wsPollInterval st -> pure False
    _ -> do
      currentStamp <- fetchStamp
      let lastStamp = snd =<< entry
      atomicModifyIORef' (wsEntries st) $ \es ->
        ( Map.insert path (tNow, currentStamp) es
        , maybe False (stampChanged lastStamp) currentStamp
        )
  where
    fetchStamp =
      fmap Just (getModificationTime path)
        `catchIOError` \_ -> pure Nothing
