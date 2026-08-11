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

    -- * Clock
  , Clock (..)
  , now
  , runClockIO

    -- * File watching
  , FileWatch (..)
  , checkChanged
  , readBytes
  , runFileWatchIO

    -- * Raylib (definition only; IO interpreter in App.Render.Raylib3D)
  , Raylib (..)
  , withWindow
  , withFrame
  , drawBatch
  , shouldClose
  ) where

import qualified Data.ByteString as BS
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import GHC.Clock (getMonotonicTime)
import Magic.Interface (RenderBatch, V3)
import System.IO.Error (catchIOError)

import App.HotReload (WatchState, checkStampIO, newWatchState)

-- | Renderer-agnostic camera description; the raylib backend converts it.
data Camera = Camera
  { camPos :: !V3
  , camTarget :: !V3
  , camUp :: !V3
  , camFovY :: !Float
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

type instance DispatchOf FileWatch = Dynamic

checkChanged :: (FileWatch :> es) => FilePath -> Eff es Bool
checkChanged = send . CheckChanged

readBytes :: (FileWatch :> es) => FilePath -> Eff es (Either String BS.ByteString)
readBytes = send . ReadBytes

-- | mtime polling interpreter (ADR-0005 hot reload; fsnotify deliberately
-- avoided for the skeleton). @pollInterval@ throttles filesystem stats —
-- calls arriving earlier than that since the last stat report 'False'.
runFileWatchIO :: (IOE :> es) => Double -> Eff (FileWatch : es) a -> Eff es a
runFileWatchIO pollInterval action = do
  st <- liftIO (newWatchState pollInterval)
  interpret
    ( \_ -> \case
        CheckChanged path -> liftIO (checkStampIO st path)
        ReadBytes path -> liftIO (readBytesIO path)
    )
    action
  where
    readBytesIO :: FilePath -> IO (Either String BS.ByteString)
    readBytesIO path =
      fmap Right (BS.readFile path)
        `catchIOError` \e -> pure (Left (show e))

-- | Paired-call raylib operations (bracket pattern, higher-order effect)
-- plus the draw command. No raylib types appear here.
data Raylib :: Effect where
  WithWindow :: Int -> Int -> String -> m a -> Raylib m a
  WithFrame :: m a -> Raylib m a
  DrawBatch :: Camera -> RenderBatch -> Raylib m ()
  ShouldClose :: Raylib m Bool

type instance DispatchOf Raylib = Dynamic

withWindow :: (Raylib :> es) => Int -> Int -> String -> Eff es a -> Eff es a
withWindow w h title = send . WithWindow w h title

withFrame :: (Raylib :> es) => Eff es a -> Eff es a
withFrame = send . WithFrame

drawBatch :: (Raylib :> es) => Camera -> RenderBatch -> Eff es ()
drawBatch cam = send . DrawBatch cam

shouldClose :: (Raylib :> es) => Eff es Bool
shouldClose = send ShouldClose
