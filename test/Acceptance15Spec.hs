-- | S5 (func-spec 0015 §7): end-to-end acceptance of the visual
-- vocabulary round.
--
--   * the styled, phased example splits into exactly two batches during
--     Drawing — casting (soft-dot, not yet live) first, formation
--     (square, drawing the circle) second — which is the first time the
--     0013 per-batch machinery and @pm_observe@'s @max_batches@ see a
--     genuinely plural frame;
--   * 240 frames of the new example are deterministic (two identical
--     walks, 'Eq' on the whole 'FrameOutput');
--   * every pre-0015 example keeps observing as a single square batch
--     across its whole life (the byte-level six-column guarantee is
--     @test\/PerfGoldenSpec.hs@'s golden net, running in this same
--     suite);
--   * @assets\/spells\/soft-bloom.json@ loads, compiles and fits the
--     budget.
module Acceptance15Spec (spec) where

import qualified Data.ByteString as BS
import Magic.Codec (loadCircle)
import Magic.Interface
  ( ActiveSpell
  , BillboardShape (..)
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , budgetPlanOf
  , castSpell
  , maxSpellParticles
  , observeSpell
  )
import Magic.Compile (ParticleBudget (..))
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

castFile :: String -> IO ActiveSpell
castFile name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (castSpell (CastRequest circle ctx))

dt :: FrameInput
dt = FrameInput (DeltaTime (1 / 60))

-- | Advance-then-observe for @n@ frames — the host loop, verbatim.
walk :: Int -> ActiveSpell -> [FrameOutput]
walk n spell0 = go n spell0
  where
    go 0 _ = []
    go k s =
      let s' = advanceSpell dt s
       in observeSpell s' : go (k - 1 :: Int) s'

observeAt :: ActiveSpell -> Double -> FrameOutput
observeAt spell t = observeSpell (advanceSpell (FrameInput (DeltaTime t)) spell)

legacyExamples :: [String]
legacyExamples =
  [ "bare-sigil"
  , "converge-flame"
  , "empty"
  , "grand-sigil"
  , "gravity-well"
  , "lissajous"
  , "pulse-ring"
  , "ring-fire"
  , "spiral-spark"
  , "square-burst"
  ]

spec :: Spec
spec = describe "func-spec 0015 acceptance" $ do
  it "soft-bloom loads, compiles and fits the budget" $ do
    spell <- castFile "soft-bloom"
    let plan = budgetPlanOf spell
    budgetTotal plan `shouldSatisfy` (> 0)
    budgetTotal plan `shouldSatisfy` (<= maxSpellParticles)

  it "soft-bloom is two batches while Drawing: soft-dot casting, square formation" $ do
    spell <- castFile "soft-bloom"
    let FrameOutput bs = observeAt spell 0.5 -- inside draw 1.2s
    map rbShape bs `shouldBe` [BillboardSoftDot, BillboardSquare]
    -- Casting has not started: the drawn circle is all the live rows.
    map (pbCount . rbParticles) bs `shouldSatisfy` \counts -> case counts of
      [castingRows, formationRows] -> castingRows == 0 && formationRows > 0
      _ -> False

  it "soft-bloom's casting batch comes alive after the prelude, still soft-dot" $ do
    spell <- castFile "soft-bloom"
    let FrameOutput bs = observeAt spell 2.5 -- past draw + converge = 2.0s
    map rbShape bs `shouldBe` [BillboardSoftDot, BillboardSquare]
    case bs of
      (casting : _) -> pbCount (rbParticles casting) `shouldSatisfy` (> 0)
      [] -> expectationFailure "no batches"

  it "240 frames of soft-bloom are deterministic, batches and all" $ do
    a <- walk 240 <$> castFile "soft-bloom"
    b <- walk 240 <$> castFile "soft-bloom"
    a `shouldBe` b

  it "every pre-0015 example stays a single square batch over 240 frames" $
    mapM_
      ( \name -> do
          frames <- walk 240 <$> castFile name
          length frames `shouldBe` 240
          [b | FrameOutput bs <- frames, b <- bs, rbShape b /= BillboardSquare]
            `shouldBe` []
          map (\(FrameOutput bs) -> length bs) frames
            `shouldSatisfy` all (== 1)
      )
      legacyExamples
