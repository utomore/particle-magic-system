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
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Vector.Storable as S
import Data.Word (Word16)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, localSeqUnliftIO)
import Foreign (Ptr, Storable (peek, poke, sizeOf), castPtr, free, malloc, plusPtr, with)
import Foreign.C.String (withCString)
import Foreign.C.Types (CFloat (..), CInt)
import Foreign.Marshal.Array (withArray)
import qualified Raylib.Core as RL
import qualified Raylib.Core.Models as RLM
import qualified Raylib.Core.Shapes as RLS
import qualified Raylib.Core.Text as RLT
import qualified Raylib.Core.Textures as RLTex
import Raylib.Types
  ( Camera3D (..)
  , CameraProjection (CameraPerspective)
  , Color (..)
  , ConfigFlag (WindowResizable)
  , Image (..)
  , KeyboardKey
      ( KeyFour
      , KeyG
      , KeyLeft
      , KeyOne
      , KeyR
      , KeyRight
      , KeyT
      , KeyTab
      , KeyThree
      , KeyTwo
      , KeyV
      )
  , Material
  , Matrix
  , Mesh (..)
  , MouseButton (MouseButtonLeft)
  , PixelFormat (PixelFormatUncompressedR8G8B8A8)
  , RenderTexture (..)
  , Shader
  , Texture
  , Vector3
  , p'material'maps
  , p'material'shader
  , p'materialMap'texture
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
import App.Render.Chunk (chunkBatch)
import App.Render.Flat (buildFlatQuadsIn)
import App.Render.Order (DrawGroup (..), frameDraws, orderedQuads)
import App.Render.Post
  ( FramePlan (..)
  , Pass (..)
  , PassSize (..)
  , Target (..)
  , VisualSettings
  , bloomIntensity
  , bloomThreshold
  , framePlan
  , passSizeIn
  , scratchTargetsNeeded
  )
import App.Render.Quads (QuadBatch (..), quadIndices, quadTexcoords)
import App.Render.Shader
  ( ShaderId (..)
  , allShaders
  , fragmentPath
  , vertexPath
  )
import App.Render.Sprite (atlasRect, atlasSize, atlasTexels, spriteSize, spriteTexels)
import App.Scene (Block (..), testScene)
import Magic.Interface
  ( BillboardShape (..)
  , BlendMode (..)
  , RenderBatch (..)
  , V3 (..)
  )

-- | Vertex capacity of the shared mesh, in particles — an upload
-- granularity, not a particle limit.
--
-- It used to mirror the core's @Magic.Compile.budgetCap@; func-spec 0012
-- raised that cap past what a 'Word16' index buffer can address
-- (4096*4 = 16384 vertices is already half of 65536), so the two numbers
-- part ways here. The mesh stays this size and a larger batch is drawn as
-- several consecutive chunks ('App.Render.Chunk.chunkBatch') instead of
-- being clamped or reallocated mid-frame.
gpuCapacity :: Int
gpuCapacity = 4096

-- | @sizeof(MaterialMap)@, so @maps[1]@ can be reached from @maps[0]@.
-- Mirrors h-raylib's own 'Foreign.Storable.sizeOf' for the type; written
-- out because the array is reached through a raw pointer rather than a
-- 'Foreign.Marshal.Array' read.
materialMapSize :: Int
materialMapSize = 28

-- | GPU-side resources, created inside the window bracket and reused for
-- every frame and every batch.
data QuadGpu = QuadGpu
  { gpuMesh :: !(Ptr Mesh)
  , gpuMaterial :: !(Ptr Material)
  , gpuTransform :: !(Ptr Matrix)
  , gpuDiffuseSlot :: !(Ptr Texture)
  -- ^ The diffuse-map texture slot /inside/ 'gpuMaterial' (maps[0]);
  -- binding a batch's sprite is one 'poke' here (func-spec 0015 S4).
  , gpuDepthSlot :: !(Ptr Texture)
  -- ^ The material's /second/ map slot (@maps[1]@, raylib's specular
  -- map), which is how the soft-particle depth texture reaches the shader
  -- (func-spec 0023 S8).
  --
  -- Not @SetShaderValueTexture@, which is the obvious call and does not
  -- work here: it registers a sampler for rlgl's immediate-mode batch,
  -- and @DrawMesh@ binds material map slots instead. The uniform was
  -- therefore set to a texture unit nothing was ever bound to, the fade
  -- read zero, and every particle came out fully transparent — found by
  -- the §9 smoke, not by any test (§10).
  , gpuDefaultTex :: !Texture
  -- ^ The default material's own 1×1 white texture: what
  -- 'BillboardSquare' draws with — i.e. exactly the pre-0015 pipeline.
  , gpuBlankTex :: !Texture
  -- ^ A zeroed 'Texture', i.e. id 0. Written back into 'gpuDepthSlot'
  -- after a soft-particle pass: @DrawMesh@ skips a map whose texture id
  -- is 0, so this is how the slot is /unbound/ rather than left pointing
  -- at a render texture that may be about to be resized.
  , gpuShapeTex :: ![(BillboardShape, Texture)]
  -- ^ One procedurally generated sprite per non-square shape, uploaded
  -- once at startup ('App.Render.Sprite'). 'BillboardSquare' is absent
  -- on purpose (it uses 'gpuDefaultTex' and costs no texture).
  --
  -- Kept for 'DrawScene' and the 2D path, which still bind per batch.
  -- The 3D frame path uses 'gpuAtlasTex' instead.
  , gpuAtlasTex :: !Texture
  -- ^ Every shape's sprite in one texture (func-spec 0023 S9). Bound
  -- once per frame rather than once per batch, which is what removes the
  -- last per-batch draw-call boundary and lets particles of different
  -- shapes share a depth sort.
  , gpuShaders :: ![(ShaderId, Shader)]
  -- ^ The func-spec 0023 programs, compiled once at startup. Every entry
  -- of 'App.Render.Shader.allShaders' appears here, and 'freeQuadGpu'
  -- unloads every entry — the bracket law, kept as a walk over one list
  -- rather than as a matched pair of hand-written call sequences.
  , gpuDefaultShader :: !Shader
  -- ^ The material's own shader as raylib built it. Restored before the
  -- material is torn down, and bound for every draw that does not want a
  -- custom program — so "effects off" really is the default pipeline and
  -- not a custom shader imitating it.
  , gpuTargets :: !(IORef [RenderTexture])
  -- ^ The offscreen targets, sized to the window. Empty until a frame
  -- actually needs one (which, with every effect off, is never), and
  -- rebuilt when the window is resized.
  , gpuTargetSize :: !(IORef (Int, Int))
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
            RU.withWindow width height title 60 $ \_res -> do
              -- A fixed window would make the 2D screen mapping a
              -- constant again; the loop follows the size every frame
              -- through 'WindowSize' (func-spec 0013 §4).
              RL.setWindowState [WindowResizable]
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
        DrawFrame cam settings batches ->
          liftIO (withGpu gpuRef $ \gpu -> drawFrameIO gpu cam settings batches)
        DrawFlat fv batches -> liftIO (withGpu gpuRef $ \gpu -> drawFlatIO gpu fv batches)
        DrawHud view -> liftIO (drawHudIO view)
        ShouldClose -> liftIO RL.windowShouldClose
        PollInput -> liftIO pollInputIO
        WindowSize -> liftIO ((,) <$> RL.getScreenWidth <*> RL.getScreenHeight)
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
  -- The material's diffuse map slot, kept as a pointer so a batch's
  -- sprite bind is a single poke; its startup content is the default 1×1
  -- white texture, remembered for the square (= textureless) batches.
  mapsPtr <- peek (p'material'maps matPtr)
  let diffuseSlot = p'materialMap'texture mapsPtr
      -- maps[1] is raylib's specular slot; @DrawMesh@ binds it to texture
      -- unit 1 and points the shader's @texture1@ sampler at it.
      depthSlot = p'materialMap'texture (plusPtr mapsPtr materialMapSize)
  defaultTex <- peek diffuseSlot
  blankTex <- peek depthSlot
  shapeTex <-
    mapM
      (\shape -> (,) shape <$> RLTex.loadTextureFromImage (spriteImage shape))
      [BillboardSoftDot, BillboardRing, BillboardSpark, BillboardTrail]
  -- Func-spec 0023 S5. Compiled once, here, inside the window bracket
  -- that already owns the mesh and the material: a shader is a GL object
  -- and has exactly the same lifetime rules.
  atlasTex <- RLTex.loadTextureFromImage atlasImage
  defaultShader <- peek (p'material'shader matPtr)
  shaders <-
    mapM
      (\s -> (,) s <$> RL.loadShader (vertexPath s) (Just (fragmentPath s)))
      allShaders
  targets <- newIORef []
  targetSize <- newIORef (0, 0)
  pure
    QuadGpu
      { gpuMesh = meshPtr
      , gpuMaterial = matPtr
      , gpuTransform = xformPtr
      , gpuDiffuseSlot = diffuseSlot
      , gpuDepthSlot = depthSlot
      , gpuDefaultTex = defaultTex
      , gpuBlankTex = blankTex
      , gpuShapeTex = shapeTex
      , gpuAtlasTex = atlasTex
      , gpuShaders = shaders
      , gpuDefaultShader = defaultShader
      , gpuTargets = targets
      , gpuTargetSize = targetSize
      }

-- | A sprite's pixels as a raylib CPU-side image, ready for upload.
spriteImage :: BillboardShape -> Image
spriteImage shape =
  Image
    { image'data = S.toList (spriteTexels shape spriteSize)
    , image'width = spriteSize
    , image'height = spriteSize
    , image'mipmaps = 1
    , image'format = PixelFormatUncompressedR8G8B8A8
    }

-- | Every shape's sprite side by side, as one image (func-spec 0023 S9).
atlasImage :: Image
atlasImage =
  Image
    { image'data = S.toList atlasTexels
    , image'width = fst atlasSize
    , image'height = snd atlasSize
    , image'mipmaps = 1
    , image'format = PixelFormatUncompressedR8G8B8A8
    }

freeQuadGpu :: QuadGpu -> IO ()
freeQuadGpu gpu = do
  -- Put the default texture and shader back before the material is torn
  -- down: both the sprites and the custom programs are unloaded here and
  -- must not dangle from it.
  poke (gpuDiffuseSlot gpu) (gpuDefaultTex gpu)
  poke (p'material'shader (gpuMaterial gpu)) (gpuDefaultShader gpu)
  forM_ (gpuShapeTex gpu) $ \(_, tex) -> with tex RLTex.c'unloadTexture
  with (gpuAtlasTex gpu) RLTex.c'unloadTexture
  -- The other half of the bracket law (func-spec 0023 S5): one unload per
  -- load, driven by the same list, so the two cannot fall out of step as
  -- programs are added.
  forM_ (gpuShaders gpu) $ \(_, shader) -> with shader RL.c'unloadShader
  freeTargets gpu
  RLM.c'unloadMesh (gpuMesh gpu)
  free (gpuMesh gpu)
  free (gpuMaterial gpu)
  free (gpuTransform gpu)

-- | Release every offscreen target and forget their size.
freeTargets :: QuadGpu -> IO ()
freeTargets gpu = do
  existing <- readIORef (gpuTargets gpu)
  forM_ existing $ \rt -> with rt RLTex.c'unloadRenderTexture
  writeIORef (gpuTargets gpu) []
  writeIORef (gpuTargetSize gpu) (0, 0)

-- | The offscreen targets a plan needs, at the current window size,
-- creating or resizing them if necessary.
--
-- Allocation is demand-driven and size-driven, both for the same reason:
-- a frame with no effects on needs none and must allocate none (that is
-- half of what "zero ripple" costs), and a resized window needs them at
-- the new size or the composite samples a stale, wrongly-scaled image.
ensureTargets :: QuadGpu -> Int -> IO [RenderTexture]
ensureTargets gpu wanted = do
  size <- (,) <$> RL.getScreenWidth <*> RL.getScreenHeight
  existing <- readIORef (gpuTargets gpu)
  cached <- readIORef (gpuTargetSize gpu)
  if length existing >= wanted && cached == size
    then pure existing
    else do
      freeTargets gpu
      if wanted <= 0
        then pure []
        else do
          -- Every target is full resolution. The bloom chain runs at half
          -- size by drawing into a viewport-sized corner of a full-size
          -- texture instead of by owning smaller ones, which keeps a
          -- resize to one reallocation path rather than two.
          created <- mapM (\_ -> uncurry RLTex.loadRenderTexture size) [1 .. wanted]
          writeIORef (gpuTargets gpu) created
          writeIORef (gpuTargetSize gpu) size
          pure created

-- | A zeroed mesh of @cap@ quads with the static triangle index pattern
-- already in place. Normals and texcoords exist because raylib uploads a
-- VBO per non-null attribute and the default shader expects both; their
-- values never change. Since func-spec 0015 the texcoords carry the
-- per-quad sprite mapping ('quadTexcoords') instead of zeros — still
-- written once here, never updated.
emptyQuadMesh :: Int -> Mesh
emptyQuadMesh cap =
  Mesh
    { mesh'vertexCount = verts
    , mesh'triangleCount = cap * 2
    , mesh'vertices = replicate verts (Vector3 0 0 0)
    , mesh'texcoords = Just (uvPairs (quadTexcoords cap))
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

-- | The flat (u, v, u, v, …) stream as the vector-of-pairs shape the
-- h-raylib 'Mesh' record wants.
uvPairs :: S.Vector Float -> [RT.Vector2]
uvPairs uv =
  [ Vector2 (uv S.! (2 * i)) (uv S.! (2 * i + 1))
  | i <- [0 .. S.length uv `div` 2 - 1]
  ]

-- | Draw every batch of one frame: 3D mode once, grid once, then per
-- batch a blend-mode bracket around a single mesh update + draw.
--
-- 'orderedQuads' is where func-spec 0013 lands on this path: an alpha
-- batch arrives already sorted back to front, so overlapping particles
-- composite in the order the blend equation assumes. The IO budget is
-- unchanged — the sort happens on the staging side, and the GPU still
-- sees one mesh update and one draw call per batch.
drawSceneIO :: QuadGpu -> Camera -> [RenderBatch] -> IO ()
drawSceneIO gpu cam batches =
  bracket_ (RL.beginMode3D (toRaylibCamera cam)) RL.endMode3D $ do
    RLM.drawGrid 10 1
    forM_ batches $ \batch -> do
      let quads = orderedQuads cam batch
          additive = rbBlend batch == BlendAdditive
      when (qbCount quads > 0) $
        bracket_
          ( do
              bindShapeTexture gpu (rbShape batch)
              RL.beginBlendMode (toRaylibBlend (rbBlend batch))
              -- Additive particles must not write depth or they occlude
              -- each other and the accumulation shows draw-order seams.
              when additive RLGL.rlDisableDepthMask
          )
          ( do
              when additive RLGL.rlEnableDepthMask
              RL.endBlendMode
          )
          (uploadAndDrawChunked gpu quads)

-- Func-spec 0023: the planned frame ---------------------------------------
--
-- 'App.Render.Post.framePlan' decides what happens; this executes it and
-- decides nothing. Same division of labour ADR-0009 set up one level
-- down, where 'App.Render.Quads' decides the vertices and this module
-- only uploads them — and the reason the pass order, the ping-pong and
-- the zero-ripple laws are all asserted headless.

-- | Draw one frame through its plan.
drawFrameIO :: QuadGpu -> Camera -> VisualSettings -> [RenderBatch] -> IO ()
drawFrameIO gpu cam settings batches = do
  targets <- ensureTargets gpu (scratchTargetsNeeded plan)
  size <- (,) <$> RL.getScreenWidth <*> RL.getScreenHeight
  mapM_ (runPass gpu cam settings size targets batches) (planPasses plan)
  where
    plan = framePlan settings

-- | Execute one pass.
runPass
  :: QuadGpu
  -> Camera
  -> VisualSettings
  -> (Int, Int)
  -> [RenderTexture]
  -> [RenderBatch]
  -> Pass
  -> IO ()
runPass gpu cam settings size targets batches pass = case pass of
  ScenePass target ->
    intoTarget target $ \firstUse -> do
      when firstUse clear
      bracket_ (RL.beginMode3D (toRaylibCamera cam)) RL.endMode3D drawTestScene
  ParticlePass target fade depthSource ->
    intoTarget target $ \firstUse -> do
      when firstUse clear
      withParticleShader gpu (depthTextureOf depthSource) fade $
        bracket_ (RL.beginMode3D (toRaylibCamera cam)) RL.endMode3D $ do
          RLM.drawGrid 10 1
          drawBatchesIO gpu cam settings batches
  ScreenPass shader from to passSize ->
    intoTarget to $ \_ ->
      screenPass gpu shader from to passSize size targets
  where
    -- A target is cleared by whichever pass touches it first in this
    -- frame; the scene pass runs before the particle pass, so clearing in
    -- both would erase the geometry the fade needs.
    firstUseOf target = case takeWhile (/= pass) (planPasses (framePlan settings)) of
      earlier -> not (any (writesTo target) earlier)

    writesTo target p = case p of
      ScenePass t -> t == target
      ParticlePass t _ _ -> t == target
      ScreenPass _ _ t _ -> t == target

    -- The depth attachment of the pre-pass's target, if there is one.
    depthTextureOf source = case source of
      Just (Scratch i) -> case drop i targets of
        (rt : _) -> Just (renderTexture'depth rt)
        [] -> Nothing
      _ -> Nothing

    clear = RL.clearBackground (Color 16 16 24 255)

    intoTarget target k = case target of
      Screen -> k (firstUseOf Screen && False)
      -- The window's framebuffer was already cleared by 'WithFrame', so a
      -- screen-targeted pass never clears again; an offscreen target has
      -- no such prior clear and needs one.
      Scratch i -> case drop i targets of
        (rt : _) -> bracket_ (RL.beginTextureMode rt) RL.endTextureMode (k (firstUseOf target))
        [] -> pure () -- unreachable: ensureTargets sized the list

-- | The test scene's blocks (func-spec 0023 §2.6). Solid geometry, so it
-- writes depth — which is the entire reason it exists.
drawTestScene :: IO ()
drawTestScene =
  forM_ testScene $ \block ->
    RLM.drawCubeV
      (toVector3 (blCenter block))
      (toVector3 (scaleV3 2 (blHalf block)))
      (unpackColor (blColor block))

scaleV3 :: Float -> V3 -> V3
scaleV3 k (V3 x y z) = V3 (k * x) (k * y) (k * z)

-- | 0xRRGGBBAA, the same packing 'Magic.Interface.pbColor' uses.
unpackColor :: Word -> Color
unpackColor c =
  Color
    (fromIntegral ((c `div` 0x1000000) `mod` 256))
    (fromIntegral ((c `div` 0x10000) `mod` 256))
    (fromIntegral ((c `div` 0x100) `mod` 256))
    (fromIntegral (c `mod` 256))

-- | Bind the particle program for the duration of an action, with the
-- soft-particle uniforms set — or bind nothing at all when the fade is
-- off.
--
-- The @fade <= 0@ branch is the zero-ripple law's IO half (func-spec 0023
-- S8): with soft particles off the material keeps raylib's own default
-- shader, so the draw is not "the custom shader configured to behave like
-- the default one" but literally the pre-0023 draw.
withParticleShader :: QuadGpu -> Maybe Texture -> Float -> IO a -> IO a
withParticleShader gpu depthTex fade action
  | fade <= 0 = action
  | otherwise = case (lookup ShaderParticle (gpuShaders gpu), depthTex) of
      (Just shader, Just depth) ->
        bracket_
          ( do
              setFloat shader "softDistance" fade
              setFloat shader "nearPlane" nearPlane
              setFloat shader "farPlane" farPlane
              -- Through the material's second map slot, not through
              -- SetShaderValueTexture: see 'gpuDepthSlot'.
              poke (gpuDepthSlot gpu) depth
              poke (p'material'shader (gpuMaterial gpu)) shader
          )
          ( do
              poke (p'material'shader (gpuMaterial gpu)) (gpuDefaultShader gpu)
              poke (gpuDepthSlot gpu) (gpuBlankTex gpu)
          )
          action
      -- No program or no depth to read: draw hard-edged rather than not at
      -- all. "Degrade to the old picture, never to a black screen" (S8).
      _ -> action

-- | raylib's default 3D clipping planes, which the depth linearization in
-- @particle.fs@ has to agree with or the fade distance means nothing.
nearPlane, farPlane :: Float
nearPlane = 0.01
farPlane = 1000

-- | One screen-filling shader pass: read one target, write another.
screenPass
  :: QuadGpu
  -> ShaderId
  -> Target
  -> Target
  -> PassSize
  -> (Int, Int)
  -> [RenderTexture]
  -> IO ()
screenPass gpu shaderId from to passSize screen targets =
  case (lookup shaderId (gpuShaders gpu), sourceTexture) of
    (Just shader, Just source) -> do
      setUniforms shader
      bracket_ (RL.beginShaderMode shader) RL.endShaderMode $
        -- The source is drawn flipped vertically: a render texture's
        -- origin is bottom-left and the screen's is top-left, and raylib's
        -- own examples handle it exactly this way (a negative source
        -- height) rather than by flipping in every shader.
        RLTex.drawTexturePro
          source
          (RT.Rectangle 0 0 (fromIntegral (fst srcSize)) (negate (fromIntegral (snd srcSize))))
          (RT.Rectangle 0 0 (fromIntegral (fst dstSize)) (fromIntegral (snd dstSize)))
          (Vector2 0 0)
          0
          (Color 255 255 255 255)
    _ -> pure ()
  where
    textureAt target = case target of
      Screen -> Nothing
      Scratch i -> case drop i targets of
        (rt : _) -> Just (renderTexture'texture rt)
        [] -> Nothing

    sourceTexture = textureAt from
    srcSize = passSizeIn screen FullSize
    dstSize = passSizeIn screen passSize

    setUniforms shader = case shaderId of
      ShaderBright -> setFloat shader "threshold" bloomThreshold
      ShaderBlur -> do
        -- Horizontal when the pass writes the higher-numbered target of
        -- the ping-pong pair, vertical on the way back: the plan runs
        -- 1→2 then 2→1, so the direction follows from the pass itself and
        -- needs no extra field in the plan.
        let horizontal = case (from, to) of
              (Scratch a, Scratch b) -> b > a
              _ -> True
        setVec2 shader "direction" (if horizontal then (1, 0) else (0, 1))
        setVec2
          shader
          "texelSize"
          (1 / fromIntegral (max 1 (fst dstSize)), 1 / fromIntegral (max 1 (snd dstSize)))
      ShaderComposite -> do
        setFloat shader "intensity" bloomIntensity
        forM_ (textureAt (Scratch 1)) (setTexture shader "bloomTexture")
      ShaderParticle -> pure ()

-- | Set a @float@ uniform by name. A name the program does not declare
-- resolves to @-1@ and raylib ignores the write, which is why
-- @test\/ShaderPipelineSpec.hs@ holds the GLSL to
-- 'App.Render.Shader.shaderUniforms': the failure is silent on the GPU.
setFloat :: Shader -> String -> Float -> IO ()
setFloat shader name value = do
  loc <- shaderLoc shader name
  with (CFloat value) $ \p ->
    with shader $ \s -> RL.c'setShaderValue s loc (castPtr p) uniformFloat

setVec2 :: Shader -> String -> (Float, Float) -> IO ()
setVec2 shader name (x, y) = do
  loc <- shaderLoc shader name
  withArray [CFloat x, CFloat y] $ \p ->
    with shader $ \s -> RL.c'setShaderValue s loc (castPtr p) uniformVec2

setTexture :: Shader -> String -> Texture -> IO ()
setTexture shader name tex = do
  loc <- shaderLoc shader name
  with shader $ \s -> with tex $ \t -> RL.c'setShaderValueTexture s loc t

shaderLoc :: Shader -> String -> IO CInt
shaderLoc shader name = with shader $ \s -> withCString name (RL.c'getShaderLocation s)

-- | @SHADER_UNIFORM_FLOAT@ and @SHADER_UNIFORM_VEC2@, raylib's own enum
-- values.
uniformFloat, uniformVec2 :: CInt
uniformFloat = 0
uniformVec2 = 1

-- | The frame's particles, as at most two draws (func-spec 0023 S9): the
-- alpha ones depth-sorted across every batch, then the additive ones.
--
-- The atlas is bound once for both. Which shape a particle is now lives
-- in its texture coordinates, so there is no per-batch texture bind left
-- to force a draw-call boundary — which is exactly what lets the alpha
-- particles of /different/ batches be sorted against each other at all.
drawBatchesIO :: QuadGpu -> Camera -> VisualSettings -> [RenderBatch] -> IO ()
drawBatchesIO gpu cam settings batches = do
  poke (gpuDiffuseSlot gpu) (gpuAtlasTex gpu)
  forM_ (frameDraws settings cam batches) $ \group -> do
    let quads = dgQuads group
        additive = dgBlend group == BlendAdditive
    when (qbCount quads > 0) $
      bracket_
        ( do
            RL.beginBlendMode (toRaylibBlend (dgBlend group))
            -- Additive particles must not write depth or they occlude
            -- each other and the accumulation shows draw-order seams.
            when additive RLGL.rlDisableDepthMask
        )
        ( do
            when additive RLGL.rlEnableDepthMask
            RL.endBlendMode
        )
        (uploadAndDrawChunked gpu quads)

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
  -- The atlas serves this path too (func-spec 0023 S9): one bind for the
  -- whole frame, and the shape carried in each quad's UVs.
  poke (gpuDiffuseSlot gpu) (gpuAtlasTex gpu)
  forM_ batches $ \batch -> do
    let quads = buildFlatQuadsIn fv (atlasRect (rbShape batch)) (rbParticles batch)
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
        (uploadAndDrawChunked gpu quads)

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

-- | Draw a whole batch, in as many mesh-sized pieces as it takes
-- (func-spec 0012 S1). A batch within 'gpuCapacity' — every spell the
-- demo shipped with before the cap rose — is one piece, so this is the
-- old single upload plus a list of length one.
uploadAndDrawChunked :: QuadGpu -> QuadBatch -> IO ()
uploadAndDrawChunked gpu = mapM_ (uploadAndDraw gpu) . chunkBatch gpuCapacity

-- | The per-frame hot path: two zero-copy buffer updates, one poke to set
-- the draw length, one draw call.
uploadAndDraw :: QuadGpu -> QuadBatch -> IO ()
uploadAndDraw gpu quads = do
  let n = min gpuCapacity (qbCount quads)
      meshPtr = gpuMesh gpu
      posBytes = n * 4 * 3 * sizeOf (0 :: Float)
      colBytes = n * 4 * 4
      uvBytes = n * 4 * 2 * sizeOf (0 :: Float)
  S.unsafeWith (qbPositions quads) $ \p ->
    RLM.c'updateMeshBuffer meshPtr vboPositions (castPtr p) (fromIntegral posBytes) 0
  S.unsafeWith (qbColors quads) $ \p ->
    RLM.c'updateMeshBuffer meshPtr vboColors (castPtr p) (fromIntegral colBytes) 0
  -- Func-spec 0023 S9: the third per-frame stream. It used to be written
  -- once at mesh upload, because every quad sampled the whole of whatever
  -- texture was bound; with the atlas a quad's UVs say which shape it is,
  -- and that is per particle and per frame.
  S.unsafeWith (qbTexcoords quads) $ \p ->
    RLM.c'updateMeshBuffer meshPtr vboTexcoords (castPtr p) (fromIntegral uvBytes) 0
  -- Variable-length draw: raylib draws triangleCount*3 indices, and the
  -- index buffer's quad pattern is contiguous, so shrinking the triangle
  -- count is exactly "draw the first n quads".
  poke (p'mesh'triangleCount meshPtr) (fromIntegral (n * 2))
  RLM.c'drawMesh meshPtr (gpuMaterial gpu) (gpuTransform gpu)

-- | Point the shared material's diffuse map at the batch's sprite
-- (func-spec 0015 S4): one 20-byte poke, no FFI call, no shader change —
-- the default shader was sampling this slot all along.
-- 'BillboardSquare' restores the default white texture, i.e. the exact
-- pre-0015 draw state.
bindShapeTexture :: QuadGpu -> BillboardShape -> IO ()
bindShapeTexture gpu shape =
  poke (gpuDiffuseSlot gpu) (fromMaybe (gpuDefaultTex gpu) (lookup shape (gpuShapeTex gpu)))

-- | VBO slots, in raylib's @UpdateMeshBuffer@ index order (which is the
-- 'RT.DefaultShaderAttributeLocation' order): 0 position, 1 texcoord,
-- 2 normal, 3 color.
vboPositions, vboTexcoords, vboColors :: (Num a) => a
vboPositions = 0
vboTexcoords = 1
vboColors = 3

toRaylibBlend :: BlendMode -> RT.BlendMode
toRaylibBlend = \case
  BlendAlpha -> RT.BlendAlpha
  BlendAdditive -> RT.BlendAdditive

drawHudIO :: HudView -> IO ()
drawHudIO view =
  forM_ (zip [0 ..] (formatHud view)) $ \(i, line) ->
    RLT.drawText line 12 (12 + i * 22) 18 (Color 220 230 255 255)

-- | This frame's keyboard and mouse, translated out of raylib's
-- vocabulary into ours.
--
-- The left-button drag is offered to both view controls at once
-- ('diOrbitDrag' and 'diPanDrag'): one gesture, and the loop decides
-- which view it steers. A held button that did not move reports
-- 'Nothing' rather than a zero delta, so an idle frame is idle input by
-- construction.
pollInputIO :: IO DemoInput
pollInputIO = do
  nxt <- RL.isKeyPressed KeyRight
  prv <- RL.isKeyPressed KeyLeft
  rec' <- RL.isKeyPressed KeyR
  backend <- RL.isKeyPressed KeyTab
  plane <- RL.isKeyPressed KeyV
  tint <- RL.isKeyPressed KeyT
  readability <- RL.isKeyPressed KeyG
  trails <- RL.isKeyPressed KeyOne
  bloom <- RL.isKeyPressed KeyTwo
  soft <- RL.isKeyPressed KeyThree
  scene <- RL.isKeyPressed KeyFour
  dragging <- RL.isMouseButtonDown MouseButtonLeft
  Vector2 dx dy <- RL.getMouseDelta
  wheel <- RL.getMouseWheelMove
  Vector2 mx my <- RL.getMousePosition
  let drag
        | dragging && (dx /= 0 || dy /= 0) = Just (dx, dy)
        | otherwise = Nothing
  pure
    DemoInput
      { diNextSpell = nxt
      , diPrevSpell = prv
      , diRecast = rec'
      , diToggleBackend = backend
      , diTogglePlane = plane
      , diToggleTint = tint
      , diToggleReadability = readability
      , diToggleTrails = trails
      , diToggleBloom = bloom
      , diToggleSoft = soft
      , diToggleScene = scene
      , diOrbitDrag = drag
      , diPanDrag = drag
      , diWheel = wheel
      , diCursor = (mx, my)
      }
