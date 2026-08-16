-- | S7 (func-spec 0023 §6): the bloom chain.
--
-- Bloom is three passes with a strict data dependency between them —
-- bright, then blur twice, then composite — and a ping-pong between two
-- targets that must never be read and written at once. Both are
-- properties of the /plan/, which is why the plan is a value
-- ('App.Render.Post.framePlan') rather than a sequence of IO calls: a
-- wrong pass order is a bug you can state, and this states it.
--
-- The switch-off clause carries the same weight as the effect itself.
-- With bloom off there is no chain, no offscreen target and no composite
-- — not a chain configured to do nothing.
module BloomSpec (spec) where

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Render.Post
  ( FramePlan (..)
  , Pass (..)
  , PassSize (..)
  , Target (..)
  , VisualSettings (..)
  , bloomDownscale
  , bloomIntensity
  , bloomThreshold
  , framePlan
  , noEffects
  , passSizeIn
  , scratchTargetsNeeded
  )
import App.Render.Shader (ShaderId (..))

bloomOn :: VisualSettings
bloomOn = noEffects {vsBloom = True}

screenPasses :: VisualSettings -> [(ShaderId, Target, Target, PassSize)]
screenPasses settings =
  [(s, from, to, size) | ScreenPass s from to size <- planPasses (framePlan settings)]

spec :: Spec
spec = describe "bloom (func-spec 0023 §6 S7)" $ do
  describe "the chain" $ do
    it "runs bright, blur, blur, composite — in that order" $
      map (\(s, _, _, _) -> s) (screenPasses bloomOn)
        `shouldBe` [ShaderBright, ShaderBlur, ShaderBlur, ShaderComposite]

    it "draws the frame offscreen first, so the bright pass has an image" $ do
      let passes = planPasses (framePlan bloomOn)
      [t | ParticlePass t _ _ <- passes] `shouldBe` [Scratch 0]

    it "ping-pongs the two blur passes between a pair of targets" $ do
      -- Pass two reads what pass one wrote, and neither reads the target
      -- it is writing. A shader that samples its own render target is
      -- undefined behaviour on every driver.
      let blurs = [(from, to) | (ShaderBlur, from, to, _) <- screenPasses bloomOn]
      blurs `shouldBe` [(Scratch 1, Scratch 2), (Scratch 2, Scratch 1)]

    it "composites the original with the blurred result, onto the screen" $
      [(from, to) | (ShaderComposite, from, to, _) <- screenPasses bloomOn]
        `shouldBe` [(Scratch 0, Screen)]

    it "leaves the scene buffer untouched by the blur chain" $ do
      -- Scratch 0 holds the frame the composite still needs; a blur that
      -- wrote into it would erase what it is being added to.
      let written = [to | (s, _, to, _) <- screenPasses bloomOn, s == ShaderBlur]
      written `shouldNotContain` [Scratch 0]

    it "asks for exactly three offscreen targets" $
      scratchTargetsNeeded (framePlan bloomOn) `shouldBe` 3

  describe "the resolution the chain runs at" $ do
    it "runs the blur chain downscaled and the composite full size" $ do
      let sizes = [(s, size) | (s, _, _, size) <- screenPasses bloomOn]
      lookup ShaderBright sizes `shouldBe` Just (Downscaled bloomDownscale)
      lookup ShaderBlur sizes `shouldBe` Just (Downscaled bloomDownscale)
      lookup ShaderComposite sizes `shouldBe` Just FullSize

    it "downscales by a factor greater than one, or it is not a downscale" $
      bloomDownscale `shouldSatisfy` (> 1)

    prop "the downscaled passes are the window divided, both axes" $
      forAll ((,) <$> choose (16, 4000) <*> choose (16, 4000)) $ \screen ->
        passSizeIn screen (Downscaled bloomDownscale)
          === (fst screen `div` bloomDownscale, snd screen `div` bloomDownscale)

  describe "the switch-off clause (zero ripple)" $ do
    it "plans no screen pass at all when bloom is off" $
      screenPasses noEffects `shouldBe` []

    it "and allocates nothing" $
      -- Not "a chain that multiplies by zero": no chain, no target, no
      -- GPU memory. The composite is where a disabled effect would
      -- otherwise still cost a full-screen read and write per frame.
      scratchTargetsNeeded (framePlan noEffects) `shouldBe` 0

    it "draws straight to the screen instead of through a target" $
      framePlan noEffects `shouldBe` FramePlan [ParticlePass Screen 0 Nothing]

    prop "switching bloom off restores the no-bloom plan exactly" $
      forAll (VisualSettings <$> arbitrary <*> pure True <*> arbitrary <*> arbitrary) $
        \on ->
          let off = on {vsBloom = False}
           in -- Everything else about the frame is unchanged, so a viewer
              -- comparing two screenshots is comparing bloom and nothing
              -- else.
              screenPasses off === []
                .&&. [t | ParticlePass t _ _ <- planPasses (framePlan off)] === [Screen]

  describe "the frozen coefficients" $ do
    it "keeps the threshold inside the range a luminance can reach" $
      -- Above 1 nothing ever blooms; at 0 everything does, which is fog.
      bloomThreshold `shouldSatisfy` (\t -> t > 0 && t < 1)

    it "keeps the intensity short of doubling the image" $
      -- A saturated core plus its own glow clips to white, and the colour
      -- is the magic's semantics (architecture §1.2).
      bloomIntensity `shouldSatisfy` (\i -> i > 0 && i <= 1)
