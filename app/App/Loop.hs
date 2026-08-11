{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeOperators #-}

-- | The main loop (func-spec 0001 §5.2): pure step planning from
-- 'Magic.Step', spell stepping through 'Magic.Interface', all IO behind
-- the 'Clock' / 'FileWatch' / 'Raylib' effects — so the exact same loop
-- runs against the real window and against the headless test
-- interpreters.
module App.Loop
  ( LoopConfig (..)
  , LoopStats (..)
  , defaultCamera
  , runLoop
  ) where

import qualified Data.ByteString as BS
import Effectful (Eff, (:>))
import Magic.Codec (loadCircle)
import Magic.Interface
  ( ActiveSpell
  , CastContext
  , CastRequest (..)
  , Circle
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , Time (..)
  , V3 (..)
  , castSpell
  , isFinished
  , spellAge
  , stepSpell
  )
import Magic.Step (StepPlan (..), plan)

import App.Effects
  ( Camera (..)
  , Clock
  , FileWatch
  , Raylib
  , checkChanged
  , drawBatch
  , now
  , readBytes
  , shouldClose
  , withFrame
  , withWindow
  )

data LoopConfig = LoopConfig
  { lcSimDt :: !Double
  -- ^ Fixed simulation timestep (1/60).
  , lcMaxStepsPerFrame :: !Int
  -- ^ Spiral-of-death clamp (8).
  , lcSpellPath :: !FilePath
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

data LoopState = LoopState
  { stCircle :: !(Maybe Circle)
  -- ^ Latest successfully loaded circle (kept for finish restarts).
  , stSpell :: !(Maybe ActiveSpell)
  , stOutput :: !FrameOutput
  , stAcc :: !Double
  , stLastTime :: !Double
  , stFrames :: !Int
  , stSimSteps :: !Int
  , stCasts :: !Int
  }

runLoop
  :: (Clock :> es, FileWatch :> es, Raylib :> es)
  => LoopConfig
  -> Eff es LoopStats
runLoop cfg =
  withWindow (fst (lcWindowSize cfg)) (snd (lcWindowSize cfg)) (lcWindowTitle cfg) $ do
    (circle0, spell0, casts0) <- loadAndCast cfg
    t0 <- now
    frameLoop
      cfg
      LoopState
        { stCircle = circle0
        , stSpell = spell0
        , stOutput = FrameOutput []
        , stAcc = 0
        , stLastTime = t0
        , stFrames = 0
        , stSimSteps = 0
        , stCasts = casts0
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

      -- Hot reload: mtime change => reload + re-cast (state reset,
      -- architecture §8.3 POC strategy).
      changed <- checkChanged (lcSpellPath cfg)
      st1 <-
        if changed
          then do
            (c, s, casts) <- loadAndCast cfg
            pure $ case s of
              -- Load/compile errors keep the old spell running.
              Nothing -> st
              Just _ -> st {stCircle = c, stSpell = s, stCasts = stCasts st + casts}
          else pure st

      -- A finished spell restarts from the kept circle (walking-skeleton
      -- demo keeps the fountain alive).
      st2 <- case (stSpell st1, stCircle st1) of
        (Just spell, Just circle)
          | isFinished spell ->
              case castSpell (CastRequest circle (lcCastCtx cfg)) of
                Right fresh ->
                  pure st1 {stSpell = Just fresh, stCasts = stCasts st1 + 1}
                Left _ -> pure st1 {stSpell = Nothing}
        _ -> pure st1

      -- Fixed-step planning (pure), then n pure spell steps.
      let StepPlan n acc' = plan (lcSimDt cfg) (lcMaxStepsPerFrame cfg) elapsed (stAcc st2)
          (spell', output', stepsRun) = case stSpell st2 of
            Nothing -> (Nothing, stOutput st2, 0)
            Just spell -> stepTimes n spell (stOutput st2)

      -- Render the newest output every frame (even when n == 0).
      withFrame $ mapM_ (drawBatch (lcCamera cfg)) (batches output')

      frameLoop
        cfg
        st2
          { stSpell = spell'
          , stOutput = output'
          , stAcc = acc'
          , stLastTime = tNow
          , stFrames = stFrames st2 + 1
          , stSimSteps = stSimSteps st2 + stepsRun
          }
  where
    stepTimes n spell out
      | n <= 0 = (Just spell, out, 0)
      | otherwise =
          let go 0 s o k = (Just s, o, k)
              go m s _ k =
                let (s', o') = stepSpell (FrameInput (DeltaTime (lcSimDt cfg))) s
                 in go (m - 1) s' o' (k + 1)
           in go n spell out (0 :: Int)

-- | Read + decode + cast. Returns (circle, spell, casts-performed).
loadAndCast
  :: (FileWatch :> es)
  => LoopConfig
  -> Eff es (Maybe Circle, Maybe ActiveSpell, Int)
loadAndCast cfg = do
  bytesOrErr <- readBytes (lcSpellPath cfg)
  pure $ case bytesOrErr >>= decodeAndCast of
    Left _ -> (Nothing, Nothing, 0)
    Right (circle, spell) -> (Just circle, Just spell, 1)
  where
    decodeAndCast :: BS.ByteString -> Either String (Circle, ActiveSpell)
    decodeAndCast bytes = do
      circle <- either (Left . show) Right (loadCircle bytes)
      spell <-
        either
          (Left . show)
          Right
          (castSpell (CastRequest circle (lcCastCtx cfg)))
      pure (circle, spell)
