-- | The demo's custom shader set (func-spec 0023 S5): which programs
-- exist, where their GLSL lives, and what uniforms each one takes.
--
-- __Why this module is pure.__ ADR-0009 said "no custom shaders" and
-- ADR-0018 replaces that premise — but what the old decision was really
-- protecting is that /rendering detail does not enter the library/, and
-- that is untouched. The GLSL sits under @assets\/shaders\/@, it is loaded
-- by the one module that already owns every h-raylib call
-- ('App.Render.Raylib3D'), and 'Magic.Interface.FrameOutput' still knows
-- nothing about any of it (architecture §5.2).
--
-- Keeping the /declaration/ here, separate from the loading, buys two
-- things. The headless test suite can check the asset set — that every
-- declared file exists, that every uniform a pass sets is one the shader
-- declares — without a window or a GPU. And the lifecycle law ("every
-- shader loaded is a shader freed") becomes an assertion over a fixed
-- list rather than over a reviewer's memory.
module App.Render.Shader
  ( ShaderId (..)
  , allShaders
  , shaderAssets
  , vertexPath
  , fragmentPath
  , shaderUniforms
  , shaderDir
  ) where

-- | The four programs the demo compiles.
--
-- Deliberately a closed enumeration rather than a path-keyed map: a pass
-- names a shader by constructor, so a pass that names a program nobody
-- loads cannot be written, and GHC's exhaustiveness check lists every
-- place a fifth program would have to be handled.
data ShaderId
  = -- | The particle program: the default pipeline's vertex-colour ×
    -- diffuse-texture behaviour, plus the soft-particle depth fade
    -- (func-spec 0023 S8). With the fade distance at zero it reproduces
    -- the default shader's output, which is what makes soft particles
    -- switchable rather than a one-way door.
    ShaderParticle
  | -- | Bright pass: keep what is brighter than a threshold, drop the
    -- rest. The first of bloom's three (S7).
    ShaderBright
  | -- | Separable Gaussian blur; run twice, once per axis.
    ShaderBlur
  | -- | Composite: the blurred bright pass added back over the original.
    ShaderComposite
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Where the GLSL lives, relative to the working directory — beside
-- @assets\/spells@, so a checkout has everything the demo needs and
-- nothing is fetched or generated.
shaderDir :: FilePath
shaderDir = "assets/shaders"

allShaders :: [ShaderId]
allShaders = [minBound .. maxBound]

-- | Vertex source of a program.
--
-- Only the particle program has one of its own: the three post-processing
-- passes draw a screen-filling quad, for which raylib's built-in
-- pass-through vertex shader is exactly right, and writing a fourth copy
-- of it would be three more files to keep in step for no behaviour.
vertexPath :: ShaderId -> Maybe FilePath
vertexPath shader = case shader of
  ShaderParticle -> Just (shaderDir ++ "/particle.vs")
  ShaderBright -> Nothing
  ShaderBlur -> Nothing
  ShaderComposite -> Nothing

fragmentPath :: ShaderId -> FilePath
fragmentPath shader = case shader of
  ShaderParticle -> shaderDir ++ "/particle.fs"
  ShaderBright -> shaderDir ++ "/bright.fs"
  ShaderBlur -> shaderDir ++ "/blur.fs"
  ShaderComposite -> shaderDir ++ "/composite.fs"

-- | Every GLSL file the demo loads, in a fixed order — the list the
-- startup bracket walks and the teardown bracket walks back.
shaderAssets :: [FilePath]
shaderAssets =
  concat [maybe [] pure (vertexPath s) ++ [fragmentPath s] | s <- allShaders]

-- | The uniforms a program takes, beyond the ones raylib binds itself
-- (@mvp@, @texture0@, @colDiffuse@).
--
-- This is the list @test\/ShaderPipelineSpec.hs@ holds the GLSL to: a
-- uniform a pass sets but the shader does not declare is a silent no-op
-- on the GPU, which is the failure mode a shader bug takes in practice —
-- nothing crashes, the picture is just wrong.
shaderUniforms :: ShaderId -> [String]
shaderUniforms shader = case shader of
  ShaderParticle ->
    [ "texture1"
    -- ^ The scene depth the fade reads (S8). Named for raylib's second
    -- material map slot, because that is the only way a texture reaches
    -- a @DrawMesh@ shader — see 'App.Render.Raylib3D.gpuDepthSlot'.
    , "softDistance"
    -- ^ World-space fade distance; 0 disables the fade entirely.
    , "nearPlane"
    , "farPlane"
    -- ^ Needed to linearize the depth sample back to world units.
    ]
  ShaderBright -> ["threshold"]
  ShaderBlur ->
    [ "direction"
    -- ^ (1,0) or (0,1): which axis this invocation blurs along.
    , "texelSize"
    ]
  ShaderComposite ->
    [ "bloomTexture"
    , "intensity"
    -- ^ 0 makes the composite the identity on its input (S7's zero-ripple
    -- clause).
    ]
