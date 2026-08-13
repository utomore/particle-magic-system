-- | T-S4 (func-spec 0004 §8): end-to-end acceptance of the Expr rune
-- wiring, headless — each new example spell file runs
-- bytes → loadCircle → castSpell → N frames of stepSpell → isFinished,
-- the three examples are pairwise distinguishable, and together they
-- cover all four Expr runes. The window/hot-reload part is the manual
-- smoke recorded in spec 0004 §10.
module Acceptance4Spec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), TwoOf (..))
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
import Magic.Rune (BridgeRune (..), InnerRune (..), OuterRune (..))
import Test.Hspec

examples :: [FilePath]
examples =
  [ "assets/spells/lissajous.json"
  , "assets/spells/converge-flame.json"
  , "assets/spells/pulse-ring.json"
  ]

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

loadExample :: FilePath -> IO Circle
loadExample path = do
  bytes <- BS.readFile path
  either (fail . show) pure (loadCircle bytes)

-- | Drive a spell file for @frames@ frames at 60Hz; return the outputs
-- and the final spell state.
runSpell :: FilePath -> Int -> IO ([FrameOutput], I.ActiveSpell)
runSpell path frames = do
  circle <- loadExample path
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
spec = describe "Expr rune wiring acceptance (spec 0004 S4, headless)" $ do
  it "each example runs end to end: particles appear, spell finishes" $
    mapM_
      ( \path -> do
          (outs, finalSpell) <- runSpell path 620
          length outs `shouldBe` 620
          -- Output is non-empty while the spell runs (check t = 1s).
          pbCount (bufferAt outs 59) `shouldSatisfy` (> 0)
          -- 620 frames = 10.33s exceeds every example's lifetime
          -- (6s / 5.5s / 5s).
          let Time age = spellAge finalSpell
          age `shouldSatisfy` (> 10)
          isFinished finalSpell `shouldBe` True
      )
      examples

  it "the three examples are pairwise distinguishable (positions)" $ do
    -- Compare at t = 1s (frame 59), when all three spells are emitting.
    buffers <-
      mapM
        ( \path -> do
            (outs, _) <- runSpell path 620
            pure (path, bufferAt outs 59)
        )
        examples
    sequence_
      [ (pa, pb, U.toList (pbPosX a), U.toList (pbPosY a), U.toList (pbPosZ a))
          `shouldNotBe` (pa, pb, U.toList (pbPosX b), U.toList (pbPosY b), U.toList (pbPosZ b))
      | (i, (pa, a)) <- zip [0 :: Int ..] buffers
      , (j, (pb, b)) <- zip [0 ..] buffers
      , i < j
      ]

  it "the four Expr runes are all covered by the examples" $ do
    circles <- mapM loadExample examples
    let outers = concatMap (\c -> let TwoOf a b = outerRings c in [a, b]) circles
        inners = concatMap (\c -> let TwoOf a b = innerRings c in [a, b]) circles
        bridges = map interLayer circles
        hasRange = or [True | Just (RangeRune _) <- outers]
        hasFormula = or [True | Just (FormulaRune _) <- inners]
        hasConverge = or [True | Just (ConvergeRune _) <- bridges]
        hasAmplify = or [True | Just (AmplifyRune _) <- bridges]
    (hasRange, hasConverge, hasAmplify, hasFormula)
      `shouldBe` (True, True, True, True)
