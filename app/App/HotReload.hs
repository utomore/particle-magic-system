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
  , scanDirIO
  ) where

import qualified Data.Map.Strict as Map
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isSuffixOf, sort)
import Data.Time.Clock (UTCTime)
import GHC.Clock (getMonotonicTime)
import System.Directory (getModificationTime, listDirectory)
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
-- observed mtime (the baseline for 'stampChanged'). Func-spec 0014 adds
-- the directory half next to it: same idea, coarser subject and a slower
-- clock, because a spell file is saved far more often than one is created
-- or deleted.
data WatchState = WatchState
  { wsPollInterval :: !Double
  , wsScanInterval :: !Double
  , wsEntries :: !(IORef (Map.Map FilePath (Double, Maybe UTCTime)))
  , wsDirs :: !(IORef (Map.Map FilePath (Double, [FilePath])))
  }

-- | @newWatchState pollInterval scanInterval@ — how often a watched file
-- may be stat'ed, and how often a watched directory may be listed.
newWatchState :: Double -> Double -> IO WatchState
newWatchState pollInterval scanInterval =
  WatchState pollInterval scanInterval <$> newIORef Map.empty <*> newIORef Map.empty

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

-- | Throttled directory listing: every @*.json@ under @dir@, sorted, at
-- most once per scan interval. Between scans — and when the listing
-- fails, e.g. the directory is being moved under us — the previous answer
-- is repeated, which is the same "a failed observation is not a change"
-- rule 'checkStampIO' follows.
--
-- The entries are joined back onto @dir@ exactly the way @Main@ built the
-- startup list — a forward slash, and nothing at all when the directory
-- is @\".\"@ (which is 'System.FilePath.takeDirectory'\'s answer for a
-- bare file name). Not @System.FilePath.\<\/\>@: on Windows that joins
-- with a backslash, and a listing that differs from the list already in
-- hand by one character is a /different/ list — the loop would swap it
-- in and re-cast on the very first frame. That the two spellings mean the
-- same file to the OS is exactly why the bug is invisible until you read
-- the HUD.
--
-- So: a listing of an unchanged directory is EQUAL to the list in hand,
-- and the loop skips the whole merge on equality (the zero-ripple law).
scanDirIO :: WatchState -> FilePath -> IO [FilePath]
scanDirIO st dir = do
  tNow <- getMonotonicTime
  dirs <- readIORef (wsDirs st)
  let entry = Map.lookup dir dirs
  case entry of
    Just (lastScan, listed)
      | tNow - lastScan < wsScanInterval st -> pure listed
    _ -> do
      listed <- fetchListing (maybe [] snd entry)
      atomicModifyIORef' (wsDirs st) $ \ds ->
        (Map.insert dir (tNow, listed) ds, listed)
  where
    fetchListing fallback =
      fmap (sort . map under . filter isSpellFile) (listDirectory dir)
        `catchIOError` \_ -> pure fallback

    isSpellFile = isSuffixOf ".json"
    under name = if dir == "." then name else dir ++ "/" ++ name
