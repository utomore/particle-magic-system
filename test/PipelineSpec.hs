-- | T5 (func-spec 0001 §8): the core pipeline stub, end to end and pure —
-- empty circle → castSpell → stepSpell frames → isFinished.
module PipelineSpec (spec) where

import Data.Either (isRight)
import Magic.Compile (CompiledSpell (..), compile)
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
  , emptyCircle
  , isFinished
  , spellAge
  , stepSpell
  )
import qualified Magic.Interface as I
import qualified Magic.Particle.Analytic as Analytic
import Magic.Particle.Buffer (bufferInvariant, pbCount)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

ctx :: CastContext
ctx =
  CastContext
    { casterPos = V3 0 0 0
    , casterFacing = V3 0 1 0
    , seed = Seed 42
    }

request :: CastRequest
request = CastRequest {circleOf = emptyCircle, ctxOf = ctx}

stepN :: Int -> Double -> I.ActiveSpell -> (I.ActiveSpell, [FrameOutput])
stepN n dt spell0 = go n spell0 []
  where
    go 0 s acc = (s, reverse acc)
    go k s acc =
      let (s', out) = stepSpell (FrameInput (DeltaTime dt)) s
       in go (k - 1) s' (out : acc)

spec :: Spec
spec = describe "core pipeline stub (empty circle => plain discharge)" $ do
  it "castSpell succeeds on the empty circle" $
    isRight (castSpell request) `shouldBe` True

  it "a fresh spell starts at age 0 and is not finished" $ do
    let Right spell = castSpell request
    spellAge spell `shouldBe` Time 0
    isFinished spell `shouldBe` False

  it "stepping keeps particle count within budget and the buffer invariant true" $ do
    let Right spell = castSpell request
        Right compiled = compile emptyCircle
        (_, outs) = stepN 400 (1 / 60) spell
        buffers = [rbParticles b | FrameOutput bs <- outs, b <- bs]
    length buffers `shouldBe` 400
    buffers `shouldSatisfy` all bufferInvariant
    buffers `shouldSatisfy` all ((<= spellBudget compiled) . pbCount)

  it "particles actually appear (non-empty output while the spell runs)" $ do
    let Right spell = castSpell request
        (_, outs) = stepN 60 (1 / 60) spell
        lastCounts = [pbCount (rbParticles b) | FrameOutput bs <- drop 30 outs, b <- bs]
    lastCounts `shouldSatisfy` all (> 0)

  prop "sampling is bit-for-bit deterministic in (Seed, t)" $
    \(sd :: Word) -> forAll (choose (0 :: Double, 20)) $ \t ->
      let Right compiled = compile emptyCircle
          c = ctx {seed = Seed (fromIntegral sd)}
       in Analytic.sample compiled c (Time t) == Analytic.sample compiled c (Time t)

  it "advancing past the spell lifetime flips isFinished" $ do
    let Right spell = castSpell request
        Right compiled = compile emptyCircle
        I.Seconds lifetime = spellLifetime compiled
        frames = ceiling (lifetime * 60) + 1
        (spellEnd, _) = stepN frames (1 / 60) spell
    isFinished spellEnd `shouldBe` True

  it "stepSpell is a pure state transition (same input, same output)" $ do
    let Right spell = castSpell request
        r1 = stepSpell (FrameInput (DeltaTime (1 / 60))) spell
        r2 = stepSpell (FrameInput (DeltaTime (1 / 60))) spell
    snd r1 `shouldBe` snd r2
