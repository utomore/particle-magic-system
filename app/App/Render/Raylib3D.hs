{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeOperators #-}

-- | The IO interpreter of the 'Raylib' effect (func-spec 0001 §4.7,
-- realized by 0005 §7): the ONLY module (besides Main) that touches
-- h-raylib.
--
-- Render path (0005 §0.2): one dynamic quad mesh, uploaded once and
-- refilled per frame through the @c'@ pointer API, then drawn with a
-- single @DrawMesh@ per batch. Every h-raylib FFI import is @ccall safe@,
-- so anything per-particle (the skeleton's @drawCubeV@, @drawBillboard@,
-- rlgl immediate mode) cannot scale; the design budget is O(1) FFI calls
-- per frame. Instancing was rejected because raylib's per-instance data
-- is a transform only — 'Magic.Compile.ColorRamp''s per-particle color
-- would be lost — and because it would require a custom shader.
--
-- The default raylib shader already multiplies in the mesh's vertex color
-- attribute and samples the default material's 1x1 white texture, so
-- per-particle color needs no shader of our own.
module App.Render.Raylib3D
  ( runRaylibIO
  ) where

import Control.Exception (bracket, bracket_)
import Control.Monad (forM_, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Vector.Storable as S
import Data.Word (Word16)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, localSeqUnliftIO)
import Foreign (Ptr, Storable (poke, sizeOf), castPtr, free, malloc)
import qualified Raylib.Core as RL
import qualified Raylib.Core.Models as RLM
import qualified Raylib.Core.Shapes as RLS
import qualified Raylib.Core.Text as RLT
import Raylib.Types
  ( Camera3D (..)
  , CameraProjection (CameraPerspective)
  , Color (..)
  , KeyboardKey (KeyLeft, KeyR, KeyRight, KeyTab, KeyV)
  , Material
  , Matrix
  , Mesh (..)
  , Vector2
  , Vector3
  , p'mesh'triangleCount
  , pattern Vector2
  , pattern Vector3
  )
import qualified Raylib.Types as RT
import qualified Raylib.Util as RU
import qualified Raylib.Util.Math as RM
import qualified Raylib.Util.RLGL as RLGL

import App.Effects
  ( Camera (..)
  , DemoInput (..)
  , FlatView (..)
  , HudView
  , Raylib (..)
  )
import App.Hud (formatHud)
import App.Render.Flat (buildFlatQuads)
import App.Render.Quads (QuadBatch (..), buildQuads, quadIndices)
import Magic.Interface
  ( BlendMode (..)
  , RenderBatch (..)
  , V3 (..)
  )

-- | Vertex capacity of the shared mesh, in particles. Mirrors the core's
-- @Magic.Compile.budgetCap@ (4096), which the shell cannot import across
-- the package boundary; batches larger than this are clamped rather than
-- reallocating mid-frame. 4096*4 = 16384 vertices keeps the index buffer
-- inside 'Word16'.
gpuCapacity :: Int
gpuCapacity = 4096

-- | GPU-side resources, created inside the window bracket and reused for
-- every frame and every batch.
data QuadGpu = QuadGpu
  { gpuMesh :: !(Ptr Mesh)
  , gpuMaterial :: !(Ptr Material)
  , gpuTransform :: !(Ptr Matrix)
  }

runRaylibIO :: (IOE :> es) => Eff (Raylib : es) a -> Eff es a
runRaylibIO action = do
  -- The mesh outlives individual operations but not the window, so it is
  -- owned by the 'WithWindow' bracket and reached through a ref.
  gpuRef <- liftIO (newIORef Nothing)
  interpret
    ( \env -> \case
        WithWindow width height title inner ->
          localSeqUnliftIO env $ \unlift ->
            RU.withWindow width height title 60 $ \_res ->
              bracket initQuadGpu freeQuadGpu $ \gpu ->
                bracket_
                  (writeIORef gpuRef (Just gpu))
                  (writeIORef gpuRef Nothing)
                  (unlift inner)
        WithFrame inner ->
          localSeqUnliftIO env $ \unlift ->
            bracket_ RL.beginDrawing RL.endDrawing $ do
              RL.clearBackground (Color 16 16 24 255)
              unlift inner
        DrawBatch cam batch -> liftIO (withGpu gpuRef $ \gpu -> drawSceneIO gpu cam [batch])
        DrawScene cam batches -> liftIO (withGpu gpuRef $ \gpu -> drawSceneIO gpu cam batches)
        DrawFlat fv batches -> liftIO (withGpu gpuRef $ \gpu -> drawFlatIO gpu fv batches)
        DrawHud view -> liftIO (drawHudIO view)
        ShouldClose -> liftIO RL.windowShouldClose
        PollInput -> liftIO pollInputIO
    )
    action
  where
    -- Drawing outside the window bracket cannot happen through 'runLoop';
    -- if a host ever does it, there is no surface to draw on, so skip.
    withGpu ref k =
      readIORef ref >>= \case
        Just gpu -> k gpu
        Nothing -> pure ()

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

-- | Allocate the dynamic mesh (positions + colors refilled every frame,
-- indices written once), the default material and a reusable identity
-- transform.
initQuadGpu :: IO QuadGpu
initQuadGpu = do
  meshPtr <- malloc
  poke meshPtr (emptyQuadMesh gpuCapacity)
  -- dynamic = True: the position and color VBOs get GL_DYNAMIC_DRAW, which
  -- is what makes the per-frame UpdateMeshBuffer cheap.
  RLM.c'uploadMesh meshPtr 1
  matPtr <- RLM.c'loadMaterialDefault
  xformPtr <- malloc
  poke xformPtr RM.matrixIdentity
  pure QuadGpu {gpuMesh = meshPtr, gpuMaterial = matPtr, gpuTransform = xformPtr}

freeQuadGpu :: QuadGpu -> IO ()
freeQuadGpu gpu = do
  RLM.c'unloadMesh (gpuMesh gpu)
  free (gpuMesh gpu)
  free (gpuMaterial gpu)
  free (gpuTransform gpu)

-- | A zeroed mesh of @cap@ quads with the static triangle index pattern
-- already in place. Normals and texcoords exist because raylib uploads a
-- VBO per non-null attribute and the default shader expects both; their
-- values never change.
emptyQuadMesh :: Int -> Mesh
emptyQuadMesh cap =
  Mesh
    { mesh'vertexCount = verts
    , mesh'triangleCount = cap * 2
    , mesh'vertices = replicate verts (Vector3 0 0 0)
    , mesh'texcoords = Just (replicate verts (Vector2 0 0))
    , mesh'texcoords2 = Nothing
    , mesh'normals = replicate verts (Vector3 0 0 1)
    , mesh'tangents = Nothing
    , mesh'colors = Just (replicate verts (Color 255 255 255 255))
    , mesh'indices = Just (S.toList (quadIndices cap) :: [Word16])
    , mesh'animVertices = Nothing
    , mesh'animNormals = Nothing
    , mesh'boneIds = Nothing
    , mesh'boneWeights = Nothing
    , mesh'boneMatrices = Nothing
    , mesh'boneCount = 0
    , mesh'vaoId = 0
    , mesh'vboId = Nothing
    }
  where
    verts = cap * 4

-- | Draw every batch of one frame: 3D mode once, grid once, then per
-- batch a blend-mode bracket around a single mesh update + draw.
drawSceneIO :: QuadGpu -> Camera -> [RenderBatch] -> IO ()
drawSceneIO gpu cam batches =
  bracket_ (RL.beginMode3D (toRaylibCamera cam)) RL.endMode3D $ do
    RLM.drawGrid 10 1
    forM_ batches $ \batch -> do
      let quads = buildQuads (camPos cam) (camTarget cam) (camUp cam) (rbParticles batch)
          additive = rbBlend batch == BlendAdditive
      when (qbCount quads > 0) $
        bracket_
          ( do
              RL.beginBlendMode (toRaylibBlend (rbBlend batch))
              -- Additive particles must not write depth or they occlude
              -- each other and the accumulation shows draw-order seams.
              when additive RLGL.rlDisableDepthMask
          )
          ( do
              when additive RLGL.rlEnableDepthMask
              RL.endBlendMode
          )
          (uploadAndDraw gpu quads)

-- | The 2D path (func-spec 0008 §4.5). No @BeginMode3D@: raylib's default
-- state is already a screen-pixel orthographic projection with depth
-- testing off, so the same dynamic mesh draws the flat, painter-sorted
-- quads that 'buildFlatQuads' staged — and drawing them in order IS the
-- depth resolution.
--
-- The y-flip in the screen mapping reverses the quads' winding, so
-- backface culling is disabled around the draw; everything else (blend
-- bracket, one mesh update + one draw per batch) is the 3D path's budget,
-- unchanged.
drawFlatIO :: QuadGpu -> FlatView -> [RenderBatch] -> IO ()
drawFlatIO gpu fv batches = do
  drawFlatAxes fv
  forM_ batches $ \batch -> do
    let quads = buildFlatQuads fv (rbParticles batch)
    when (qbCount quads > 0) $
      bracket_
        ( do
            RL.beginBlendMode (toRaylibBlend (rbBlend batch))
            RLGL.rlDisableBackfaceCulling
        )
        ( do
            RLGL.rlEnableBackfaceCulling
            RL.endBlendMode
        )
        (uploadAndDraw gpu quads)

-- | A faint cross through the world origin: the 2D views have no ground
-- grid, and without it the caster's position is guesswork.
drawFlatAxes :: FlatView -> IO ()
drawFlatAxes fv = do
  RLS.drawLine 0 oy w oy axisColor
  RLS.drawLine ox 0 ox h axisColor
  where
    (w, h) = fvScreenSize fv
    (fx, fy) = fvOrigin fv
    (ox, oy) = (round fx, round fy)
    axisColor = Color 60 70 90 255

-- | The per-frame hot path: two zero-copy buffer updates, one poke to set
-- the draw length, one draw call.
uploadAndDraw :: QuadGpu -> QuadBatch -> IO ()
uploadAndDraw gpu quads = do
  let n = min gpuCapacity (qbCount quads)
      meshPtr = gpuMesh gpu
      posBytes = n * 4 * 3 * sizeOf (0 :: Float)
      colBytes = n * 4 * 4
  S.unsafeWith (qbPositions quads) $ \p ->
    RLM.c'updateMeshBuffer meshPtr vboPositions (castPtr p) (fromIntegral posBytes) 0
  S.unsafeWith (qbColors quads) $ \p ->
    RLM.c'updateMeshBuffer meshPtr vboColors (castPtr p) (fromIntegral colBytes) 0
  -- Variable-length draw: raylib draws triangleCount*3 indices, and the
  -- index buffer's quad pattern is contiguous, so shrinking the triangle
  -- count is exactly "draw the first n quads".
  poke (p'mesh'triangleCount meshPtr) (fromIntegral (n * 2))
  RLM.c'drawMesh meshPtr (gpuMaterial gpu) (gpuTransform gpu)

-- | VBO slots, in raylib's @UpdateMeshBuffer@ index order (which is the
-- 'RT.DefaultShaderAttributeLocation' order): 0 position, 1 texcoord,
-- 2 normal, 3 color.
vboPositions, vboColors :: (Num a) => a
vboPositions = 0
vboColors = 3

toRaylibBlend :: BlendMode -> RT.BlendMode
toRaylibBlend = \case
  BlendAlpha -> RT.BlendAlpha
  BlendAdditive -> RT.BlendAdditive

drawHudIO :: HudView -> IO ()
drawHudIO view =
  forM_ (zip [0 ..] (formatHud view)) $ \(i, line) ->
    RLT.drawText line 12 (12 + i * 22) 18 (Color 220 230 255 255)

pollInputIO :: IO DemoInput
pollInputIO = do
  nxt <- RL.isKeyPressed KeyRight
  prv <- RL.isKeyPressed KeyLeft
  rec' <- RL.isKeyPressed KeyR
  backend <- RL.isKeyPressed KeyTab
  plane <- RL.isKeyPressed KeyV
  pure
    DemoInput
      { diNextSpell = nxt
      , diPrevSpell = prv
      , diRecast = rec'
      , diToggleBackend = backend
      , diTogglePlane = plane
      }
