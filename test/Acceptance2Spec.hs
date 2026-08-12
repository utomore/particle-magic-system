-- | T-S8 (func-spec 0002 §8): end-to-end acceptance of the circle
-- interpreter, headless — each example spell file runs
-- bytes → loadCircle → castSpell → N frames of stepSpell → isFinished,
-- and the three examples are pairwise distinguishable in the output
-- (positions and colors). The window/hot-reload part is the manual smoke
-- recorded in spec 0002 §10.
module Acceptance2Spec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import Magic.Codec (loadCircle)
import Magic.Interface
  ( CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , castSpell
  , isFinished
  , spellAge
  , stepSpell
  )
import qualified Magic.Interface as I
import Magic.Particle.Buffer (ParticleBuffer (..))
import Test.Hspec

examples :: [FilePath]
examples =
  [ "assets/spells/ring-fire.json"
  , "assets/spells/square-burst.json"
  , "assets/spells/spiral-spark.json"
  ]

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

-- | Drive a spell file for @frames@ frames at 60Hz; return the outputs
-- and the final spell state.
runSpell :: FilePath -> Int -> IO ([FrameOutput], I.ActiveSpell)
runSpell path frames = do
  bytes <- BS.readFile path
  circle <- either (fail . show) pure (loadCircle bytes)
  spell0 <- either (fail . show) pure (castSpell (CastRequest circle ctx))
  let dt = FrameInput (DeltaTime (1 / 60))
      go 0 s acc = (reverse acc, s)
      go k s acc =
        let (s', out) = stepSpell dt s
         in go (k - 1 :: Int) s' (out : acc)
      (outs, finalSpell) = go frames spell0 []
  pure (outs, finalSpell)

-- | The particle buffer of the single batch at a given frame index.
bufferAt :: [FrameOutput] -> Int -> ParticleBuffer
bufferAt outs i = case batches (outs !! i) of
  [batch] -> rbParticles batch
  bs -> error ("expected exactly one batch, got " ++ show (length bs))

spec :: Spec
spec = describe "circle interpreter acceptance (spec 0002 S8, headless)" $ do
  it "each example runs end to end: particles appear, spell finishes" $
    mapM_
      ( \path -> do
          (outs, finalSpell) <- runSpell path 620
          length outs `shouldBe` 620
          -- Output is non-empty while the spell runs (check t = 1s).
          let midCount = pbCount (bufferAt outs 59)
          midCount `shouldSatisfy` (> 0)
          -- 620 frames = 10.33s exceeds every example's lifetime.
          let Time age = spellAge finalSpell
          age `shouldSatisfy` (> 10)
          isFinished finalSpell `shouldBe` True
      )
      examples

  it "the three examples are pairwise distinguishable (positions and colors)" $ do
    -- Compare at t = 1s (frame 59), when all three spells are emitting.
    buffers <-
      mapM
        ( \path -> do
            (outs, _) <- runSpell path 620
            pure (path, bufferAt outs 59)
        )
        examples
    sequence_
      [ do
          -- Colors differ: each element's ramp is distinct.
          (pa, pb, U.toList (pbColor a)) `shouldNotBe` (pa, pb, U.toList (pbColor b))
          -- Position distributions differ.
          (pa, pb, U.toList (pbPosX a), U.toList (pbPosY a), U.toList (pbPosZ a))
            `shouldNotBe` (pa, pb, U.toList (pbPosX b), U.toList (pbPosY b), U.toList (pbPosZ b))
      | (i, (pa, a)) <- zip [0 :: Int ..] buffers
      , (j, (pb, b)) <- zip [0 ..] buffers
      , i < j
      ]
