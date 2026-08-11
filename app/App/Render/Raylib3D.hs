{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeOperators #-}

-- | The IO interpreter of the 'Raylib' effect (func-spec 0001 §4.7):
-- the ONLY module (besides Main) that touches h-raylib. Skeleton
-- rendering is per-particle 'drawCubeV' (small cubes) — throughput is a
-- later performance spec; the walking skeleton caps at 256 particles.
module App.Render.Raylib3D
  ( runRaylibIO
  ) where

import Control.Exception (bracket_)
import Control.Monad (forM_)
import Data.Bits (shiftR, (.&.))
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word8)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, localSeqUnliftIO)
import qualified Raylib.Core as RL
import qualified Raylib.Core.Models as RL
import Raylib.Types
  ( Camera3D (..)
  , CameraProjection (CameraPerspective)
  , Color (..)
  , Vector3
  , pattern Vector3
  )
import qualified Raylib.Util as RU

import App.Effects (Camera (..), Raylib (..))
import Magic.Interface
  ( ParticleBuffer
  , RenderBatch (..)
  , V3 (..)
  , pbColor
  , pbCount
  , pbPosX
  , pbPosY
  , pbPosZ
  , pbSize
  )

runRaylibIO :: (IOE :> es) => Eff (Raylib : es) a -> Eff es a
runRaylibIO = interpret $ \env -> \case
  WithWindow width height title inner ->
    localSeqUnliftIO env $ \unlift ->
      RU.withWindow width height title 60 (\_res -> unlift inner)
  WithFrame inner ->
    localSeqUnliftIO env $ \unlift ->
      bracket_ RL.beginDrawing RL.endDrawing $ do
        RL.clearBackground (Color 16 16 24 255)
        unlift inner
  DrawBatch cam batch ->
    liftIO $
      bracket_ (RL.beginMode3D (toRaylibCamera cam)) RL.endMode3D $ do
        RL.drawGrid 10 1
        drawParticles (rbParticles batch)
  ShouldClose -> liftIO RL.windowShouldClose

toRaylibCamera :: Camera -> Camera3D
toRaylibCamera cam =
  Camera3D
    { camera3D'position = toVector3 (camPos cam)
    , camera3D'target = toVector3 (camTarget cam)
    , camera3D'up = toVector3 (camUp cam)
    , camera3D'fovy = camFovY cam
    , camera3D'projection = CameraPerspective
    }

toVector3 :: V3 -> Vector3
toVector3 (V3 x y z) = Vector3 x y z

drawParticles :: ParticleBuffer -> IO ()
drawParticles pb =
  forM_ [0 .. pbCount pb - 1] $ \i -> do
    let x = pbPosX pb U.! i
        y = pbPosY pb U.! i
        z = pbPosZ pb U.! i
        s = pbSize pb U.! i
    RL.drawCubeV (Vector3 x y z) (Vector3 s s s) (unpackColor (pbColor pb U.! i))

-- | Packed RGBA (as produced by the core) -> raylib Color.
unpackColor :: Word32 -> Color
unpackColor c =
  Color
    (byteAt 24)
    (byteAt 16)
    (byteAt 8)
    (byteAt 0)
  where
    byteAt :: Int -> Word8
    byteAt bits = fromIntegral ((c `shiftR` bits) .&. 0xFF)
