-- | S5 (func-spec 0023 §6): the custom shader pipeline.
--
-- ADR-0009 said "no custom shaders" and ADR-0018 replaces that premise.
-- What the old decision was really protecting — that rendering detail
-- does not enter the library, and that a demo nobody has touched renders
-- what it always did — is what this spec holds the new code to.
--
-- Four kinds of assertion, none of which needs a window:
--
--   * the __asset set__ exists and is readable, and every uniform a pass
--     sets is one its GLSL actually declares. A uniform name that does
--     not resolve is silently ignored by the driver, so this is the one
--     shader bug that never announces itself;
--   * the __bracket law__ (func-spec 0005's discipline, applied to a new
--     kind of GPU object): every program the demo loads is a program it
--     unloads. Asserted by reading @App.Render.Raylib3D@'s source, the
--     same trick @FFIContractSpec@ uses for the C header — the compiler
--     cannot check a pairing that spans two functions;
--   * the __zero-ripple law__: with every effect off, the frame plan is a
--     single pass straight to the screen and allocates no render texture
--     at all. That is the func-spec 0015 draw, so the whole apparatus
--     costs a comparison;
--   * the __resize rule__: pass sizes follow the window, and never
--     degenerate to zero.
module ShaderPipelineSpec (spec) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import System.Directory (doesFileExist)
import System.IO (IOMode (ReadMode), hClose, hGetContents, hSetEncoding, openFile, utf8)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Render.Post
  ( FramePlan (..)
  , Pass (..)
  , PassSize (..)
  , Target (..)
  , VisualSettings (..)
  , allEffects
  , framePlan
  , noEffects
  , passSizeIn
  , scratchTargetsNeeded
  )
import App.Render.Shader
  ( ShaderId (..)
  , allShaders
  , fragmentPath
  , shaderAssets
  , shaderUniforms
  , vertexPath
  )

backendSource :: FilePath
backendSource = "app/App/Render/Raylib3D.hs"

readUtf8 :: FilePath -> IO String
readUtf8 path = do
  h <- openFile path ReadMode
  hSetEncoding h utf8
  contents <- hGetContents h
  _ <- length contents `seq` pure ()
  hClose h
  pure contents

spec :: Spec
spec = describe "custom shader pipeline (func-spec 0023 §6 S5)" $ do
  describe "the GLSL assets" $ do
    it "declares at least one program, and a fragment stage for each" $ do
      allShaders `shouldSatisfy` (not . null)
      map fragmentPath allShaders `shouldSatisfy` all (not . null)

    it "ships every file it declares, and they are readable" $
      forM_ shaderAssets $ \path -> do
        exists <- doesFileExist path
        (path, exists) `shouldBe` (path, True)
        source <- readUtf8 path
        (path, length source > 0) `shouldBe` (path, True)

    it "gives only the particle program a vertex stage" $ do
      -- The three post-processing passes draw a screen-filling quad, for
      -- which raylib's built-in pass-through vertex shader is exactly
      -- right; three more copies of it would be three more files to keep
      -- in step for no behaviour.
      vertexPath ShaderParticle `shouldSatisfy` (/= Nothing)
      map vertexPath [ShaderBright, ShaderBlur, ShaderComposite]
        `shouldBe` [Nothing, Nothing, Nothing]

    it "declares in GLSL every uniform the Haskell side names" $
      -- The silent failure: a uniform the shader does not declare
      -- resolves to -1 and the write is dropped. Nothing crashes; the
      -- picture is just wrong.
      forM_ allShaders $ \shader -> do
        source <- readUtf8 (fragmentPath shader)
        forM_ (shaderUniforms shader) $ \name ->
          (fragmentPath shader, name, ("uniform" `isInfixOf` source) && (name `isInfixOf` source))
            `shouldBe` (fragmentPath shader, name, True)

    it "keeps the soft-particle fade switchable inside the shader itself" $ do
      -- Not "scaled down to nothing": an early return, so that with the
      -- fade off the program is the default one (func-spec 0023 S8).
      source <- readUtf8 (fragmentPath ShaderParticle)
      source `shouldSatisfy` ("softDistance <= 0.0" `isInfixOf`)

    it "keeps the bloom composite switchable the same way" $ do
      source <- readUtf8 (fragmentPath ShaderComposite)
      source `shouldSatisfy` ("intensity <= 0.0" `isInfixOf`)

  describe "the bracket law: every shader loaded is a shader freed" $ do
    it "loads the declared set at startup and unloads it at teardown" $ do
      source <- readUtf8 backendSource
      -- Both halves walk 'allShaders', so a fifth program joins the load
      -- and the unload at once and cannot join only one.
      source `shouldSatisfy` ("allShaders" `isInfixOf`)
      source `shouldSatisfy` ("loadShader" `isInfixOf`)
      source `shouldSatisfy` ("c'unloadShader" `isInfixOf`)
      source `shouldSatisfy` ("gpuShaders" `isInfixOf`)

    it "restores the material's default shader before tearing it down" $ do
      -- Otherwise the material is left pointing at a program that has
      -- been unloaded — the same dangling-reference bug func-spec 0015
      -- avoided for the sprite textures, one object kind along.
      source <- readUtf8 backendSource
      source `shouldSatisfy` ("gpuDefaultShader" `isInfixOf`)

    it "releases every render texture it created" $ do
      source <- readUtf8 backendSource
      source `shouldSatisfy` ("c'unloadRenderTexture" `isInfixOf`)
      source `shouldSatisfy` ("freeTargets" `isInfixOf`)

  describe "the zero-ripple law" $ do
    it "plans a single pass straight to the screen when nothing is on" $
      framePlan noEffects `shouldBe` FramePlan [ParticlePass Screen 0 Nothing]

    it "allocates no render texture at all in that case" $
      -- The cost of the whole apparatus, for a demo nobody has touched:
      -- one comparison, and no GPU memory.
      scratchTargetsNeeded (framePlan noEffects) `shouldBe` 0

    it "still draws the particles exactly once when everything is on" $
      -- The effects add passes, not particle draws. A frame that drew the
      -- batches twice would double every additive spell's brightness.
      length [() | ParticlePass _ _ _ <- planPasses (framePlan allEffects)] `shouldBe` 1

    prop "plans exactly one particle pass whatever the settings" $
      forAll settingsGen $ \settings ->
        length [() | ParticlePass _ _ _ <- planPasses (framePlan settings)] === 1

    prop "never writes a target it is reading in the same pass" $
      forAll settingsGen $ \settings ->
        conjoin
          [ counterexample (show p) (from /= to)
          | p@(ScreenPass _ from to _) <- planPasses (framePlan settings)
          ]

    prop "asks for exactly as many scratch targets as it names" $
      forAll settingsGen $ \settings ->
        let plan = framePlan settings
            named = [i | p <- planPasses plan, Scratch i <- targetsOf p]
         in scratchTargetsNeeded plan
              === (if null named then 0 else maximum named + 1)

  describe "the resize rule" $ do
    prop "a full-size pass is the window" $
      forAll sizeGen $ \(w, h) ->
        passSizeIn (w, h) FullSize === (max 1 w, max 1 h)

    prop "a downscaled pass divides both axes" $
      forAll sizeGen $ \(w, h) ->
        forAll (choose (1, 4 :: Int)) $ \n ->
          passSizeIn (w, h) (Downscaled n) === (max 1 (w `div` n), max 1 (h `div` n))

    prop "never degenerates to zero, however small the window" $
      forAll (choose (-4, 8 :: Int)) $ \w ->
        forAll (choose (-4, 8 :: Int)) $ \h ->
          forAll (choose (1, 8 :: Int)) $ \n ->
            let (pw, ph) = passSizeIn (w, h) (Downscaled n)
             in -- raylib will happily fail to create a 0×0 render texture,
                -- and a window dragged to nothing is a thing users do.
                pw >= 1 .&&. ph >= 1

targetsOf :: Pass -> [Target]
targetsOf p = case p of
  ScenePass t -> [t]
  ParticlePass t _ _ -> [t]
  ScreenPass _ from to _ -> [from, to]

settingsGen :: Gen VisualSettings
settingsGen =
  VisualSettings <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

sizeGen :: Gen (Int, Int)
sizeGen = (,) <$> choose (1, 4000) <*> choose (1, 4000)
