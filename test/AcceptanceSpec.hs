-- | T9 (func-spec 0001 §8): end-to-end walking-skeleton acceptance,
-- headless: real spell-file bytes -> loadCircle -> castSpell -> N frames
-- of stepSpell -> non-empty FrameOutput -> isFinished. The whole spell
-- lifecycle runs as pure functions; the window part is the manual smoke
-- recorded in the spec §10.
module AcceptanceSpec (spec) where

import qualified Data.ByteString as BS
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
  , pbCount
  , spellAge
  , stepSpell
  )
import Magic.Codec (loadCircle)
import Test.Hspec

spec :: Spec
spec = describe "walking skeleton acceptance (headless full pipeline)" $
  it "spell file bytes -> cast -> frames -> particles appear -> spell finishes" $ do
    bytes <- BS.readFile "assets/spells/empty.json"

    -- Load + cast through the public entry points only.
    circle <- either (fail . show) pure (loadCircle bytes)
    let ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}
    spell0 <- either (fail . show) pure (castSpell (CastRequest circle ctx))

    -- Drive 620 frames at 60Hz (spell lifetime is 10s).
    let dt = FrameInput (DeltaTime (1 / 60))
        frames = scanl (\(s, _) _ -> stepSpell dt s) (spell0, FrameOutput []) [1 .. 620 :: Int]
        outputs = map snd (drop 1 frames)
        particleCounts =
          [ sum (map (pbCount . rbParticles) (batches out))
          | out <- outputs
          ]
        finalSpell = fst (last frames)

    -- Every frame produced output; particles appear and stay in budget.
    length outputs `shouldBe` 620
    maximum particleCounts `shouldSatisfy` (> 0)
    maximum particleCounts `shouldSatisfy` (<= 256)
    -- Steady state: past the first particle lifetime the fountain is full.
    particleCounts !! 200 `shouldBe` 256

    -- The spell ran past its lifetime and reports finished.
    let Time age = spellAge finalSpell
    age `shouldSatisfy` (> 10)
    isFinished finalSpell `shouldBe` True
