-- | S8 (func-spec 0023 §6): soft particles and the test scene they need.
--
-- The effect fades a billboard out as it approaches solid geometry,
-- removing the hard line a quad cuts where it intersects a surface. Three
-- things have to hold, and the third is the one func-spec 0023 §2.6 found
-- was missing a prerequisite:
--
--   * the depth the fade reads has to be /written first/, so the scene
--     pass must precede the particle pass. An ordering, hence a property
--     of the plan;
--   * with the fade distance at zero the shader returns early
--     (@assets\/shaders\/particle.fs@) and the draw is the pre-0023 one —
--     hard edges, bit for bit;
--   * with no scene there is nothing to intersect. Every fragment would
--     then compare against the far plane, and the effect would be a
--     uniform dimming that looks exactly like a bug. So soft particles
--     without a scene degrade to hard edges — "never to a black screen".
module SoftParticleSpec (spec) where

import Data.List (isInfixOf)
import System.IO (IOMode (ReadMode), hClose, hGetContents, hSetEncoding, openFile, utf8)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Render.Post
  ( FramePlan (..)
  , Pass (..)
  , Target (..)
  , VisualSettings (..)
  , framePlan
  , noEffects
  , softDistance
  )
import App.Render.Shader (ShaderId (ShaderParticle), fragmentPath)
import App.Scene (Block (..), groundLevel, groundSize, testScene)
import Magic.Interface (V3 (..))

softOnly, sceneOnly, both :: VisualSettings
softOnly = noEffects {vsSoftParticles = True}
sceneOnly = noEffects {vsScene = True}
both = noEffects {vsSoftParticles = True, vsScene = True}

fadeOf :: VisualSettings -> Float
fadeOf settings = case [d | ParticlePass _ d _ <- planPasses (framePlan settings)] of
  (d : _) -> d
  [] -> 0

readUtf8 :: FilePath -> IO String
readUtf8 path = do
  h <- openFile path ReadMode
  hSetEncoding h utf8
  contents <- hGetContents h
  _ <- length contents `seq` pure ()
  hClose h
  pure contents

spec :: Spec
spec = describe "soft particles (func-spec 0023 §6 S8)" $ do
  describe "the fade is on exactly when it can mean something" $ do
    it "is on with both the scene and soft particles" $
      fadeOf both `shouldBe` softDistance

    it "is off with neither" $
      fadeOf noEffects `shouldBe` 0

    it "is off with a scene but no soft particles" $
      fadeOf sceneOnly `shouldBe` 0

    it "is off with soft particles but no scene" $ do
      -- The clause that keeps the failure benign. With an empty depth
      -- buffer every fragment compares against the far plane, so the
      -- "fade" would dim the entire frame uniformly — a global change
      -- wearing a local change's name, and indistinguishable from a bug.
      fadeOf softOnly `shouldBe` 0
      framePlan softOnly `shouldBe` FramePlan [ParticlePass Screen 0 Nothing]

    prop "needs both switches, never just one" $
      forAll (VisualSettings <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary) $
        \settings ->
          (fadeOf settings > 0) === (vsSoftParticles settings && vsScene settings)

    it "uses a fade distance a particle can actually cross" $
      -- Zero would be no effect; a distance larger than the spells' own
      -- scale would fade particles that are nowhere near anything.
      softDistance `shouldSatisfy` (\d -> d > 0 && d < 3)

  describe "the depth the fade reads is written first, and elsewhere" $ do
    it "runs a depth pre-pass, then the visible scene, then the particles" $
      -- Two scene passes: one into the depth source, one into the frame.
      case planPasses (framePlan both) of
        (ScenePass a : ScenePass b : ParticlePass t _ (Just d) : _) -> do
          a `shouldBe` d
          b `shouldBe` t
        other -> expectationFailure ("unexpected plan: " ++ show other)

    it "never samples the depth of the target it is drawing into" $ do
      -- The bug the func-spec 0023 §9 smoke found: sampling a render
      -- texture's depth attachment while writing it is undefined, and in
      -- practice every particle vanished. Structural now, not a habit.
      let plans = [framePlan s | s <- allSettings]
      [ (t, d)
        | p <- concatMap planPasses plans
        , ParticlePass t _ (Just d) <- [p]
        , t == d
        ]
        `shouldBe` []

    it "draws the visible scene into the frame's own target" $ do
      let passes = planPasses (framePlan both)
          frameTargets = [t | ParticlePass t _ _ <- passes]
          sceneTargets = [t | ScenePass t <- passes]
      sceneTargets `shouldContain` frameTargets

    prop "and does so whichever other effects are on" $
      forAll (VisualSettings <$> arbitrary <*> arbitrary <*> pure True <*> pure True) $
        \settings ->
          let passes = planPasses (framePlan settings)
              sceneAt = length (takeWhile (not . isScene) passes)
              particleAt = length (takeWhile (not . isParticle) passes)
           in counterexample (show passes) (sceneAt < particleAt)

    it "plans no depth pre-pass when soft particles are off" $
      -- One scene pass, not two: the pre-pass exists only for the fade.
      length [() | ScenePass _ <- planPasses (framePlan sceneOnly)] `shouldBe` 1

    it "plans no scene pass at all when the scene is off" $
      [() | ScenePass _ <- planPasses (framePlan softOnly)] `shouldBe` []

  describe "the shader's own switch" $ do
    it "returns early rather than scaling the fade to nothing" $ do
      -- What makes "hard edges, bit for bit" a fact about the code and
      -- not a hope about floating point.
      source <- readUtf8 (fragmentPath ShaderParticle)
      source `shouldSatisfy` ("softDistance <= 0.0" `isInfixOf`)

    it "linearizes the depth sample before comparing" $ do
      -- The depth buffer stores a hyperbolic encoding, so a raw
      -- difference is not a distance; fading on it would make the
      -- softness depend on where the camera happens to be.
      source <- readUtf8 (fragmentPath ShaderParticle)
      source `shouldSatisfy` ("linearize" `isInfixOf`)

    it "fades alpha only, leaving the particle's colour alone" $ do
      -- Colour is semantics here (architecture §1.2): a fade that
      -- darkened the RGB would change what element the particle looks
      -- like as it nears a wall.
      source <- readUtf8 (fragmentPath ShaderParticle)
      source `shouldSatisfy` ("base.a * fade" `isInfixOf`)

  describe "the test scene (§2.6)" $ do
    it "exists at all — which was the gap this round found" $
      -- Soft particles fade against solid geometry, and the demo drew
      -- none. Without a bench the effect could be claimed but not
      -- verified.
      testScene `shouldSatisfy` ((>= 2) . length)

    it "has a ground large enough to cover the spells' reach" $
      groundSize `shouldSatisfy` (> 16)

    it "keeps the ground off the exact cast plane" $
      -- Coplanar geometry z-fights, which looks like a soft-particle bug
      -- and is not one.
      groundLevel `shouldSatisfy` (/= 0)

    it "gives every block a positive extent on all three axes" $
      testScene
        `shouldSatisfy` all (\b -> let V3 x y z = blHalf b in x > 0 && y > 0 && z > 0)

    it "puts something in a spell's way and something clear of it" $ do
      -- The two cases the fade has to get right: intersection (fade) and
      -- near miss (do not fade). A bench with only the first cannot tell
      -- a working fade from one that dims everything.
      let nearAxis b = let V3 x _ _ = blCenter b in abs x < 2
          blocks = drop 1 testScene -- skip the ground slab
      blocks `shouldSatisfy` any nearAxis
      blocks `shouldSatisfy` any (not . nearAxis)
  where
    isScene p = case p of ScenePass _ -> True; _ -> False
    isParticle p = case p of ParticlePass _ _ _ -> True; _ -> False
    allSettings =
      [ VisualSettings a b c d
      | a <- [False, True]
      , b <- [False, True]
      , c <- [False, True]
      , d <- [False, True]
      ]
