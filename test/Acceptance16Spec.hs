-- | S5 (func-spec 0016 §7): end-to-end acceptance of the sigil round.
--
-- The promise being cashed is architecture §1.1's "Circle as Data",
-- visible for the first time: the same circle always draws the same
-- figure, and different circles draw figures you can tell apart. So the
-- three shipped sigils must have three distinct digests, three distinct
-- point sets, and each must be stable across runs.
--
-- Everything else is the usual end-to-end net: the new example loads,
-- compiles and fits the budget; 240 frames are deterministic; and
-- 'isFinished' still flips exactly at @ppEnd@.
module Acceptance16Spec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle)
import Magic.Codec (loadCircle)
import Magic.Compile (CompiledSpell (..), ParticleBudget (..), PhasePlan (..), compile)
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput
  , ParticleBuffer (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , budgetPlanOf
  , castSpell
  , isFinished
  , maxSpellParticles
  , observeSpell
  )
import Magic.Particle.Analytic (sample)
import Magic.Sigil (hashCircle)
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

sigils :: [String]
sigils = ["bare-sigil", "grand-sigil", "lattice-seal"]

sigilCircle :: String -> IO Circle
sigilCircle name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

castFile :: String -> IO ActiveSpell
castFile name = do
  circle <- sigilCircle name
  either (fail . show) pure (castSpell (CastRequest circle ctx))

compiledOf :: String -> IO CompiledSpell
compiledOf name = do
  circle <- sigilCircle name
  either (fail . show) pure (compile circle)

dt :: FrameInput
dt = FrameInput (DeltaTime (1 / 60))

walk :: Int -> ActiveSpell -> [FrameOutput]
walk n spell0 = go n spell0
  where
    go 0 _ = []
    go k s = let s' = advanceSpell dt s in observeSpell s' : go (k - 1 :: Int) s'

-- | The drawn figure: positions of every formation particle at a moment
-- well inside the Drawing window.
figureOf :: CompiledSpell -> [(Float, Float, Float)]
figureOf spell =
  let Seconds drawEnd = ppDrawEnd (spellPhases spell)
      buf = sample spell ctx (Time (drawEnd * 0.5))
   in [ (pbPosX buf U.! j, pbPosY buf U.! j, pbPosZ buf U.! j)
      | j <- [0 .. pbCount buf - 1]
      ]

spec :: Spec
spec = describe "func-spec 0016 acceptance" $ do
  it "lattice-seal loads, compiles and fits the budget" $ do
    spell <- castFile "lattice-seal"
    let plan = budgetPlanOf spell
    budgetTotal plan `shouldSatisfy` (> 0)
    budgetTotal plan `shouldSatisfy` (<= maxSpellParticles)

  it "the three shipped sigils have pairwise distinct digests" $ do
    digests <- mapM (fmap hashCircle . sigilCircle) sigils
    length digests `shouldBe` 3
    sequence_
      [ (a, b) `shouldSatisfy` uncurry (/=)
      | (i, a) <- zip [0 :: Int ..] digests
      , (j, b) <- zip [0 ..] digests
      , i < j
      ]

  it "the three shipped sigils draw three distinguishable figures" $ do
    figures <- mapM (fmap figureOf . compiledOf) sigils
    map length figures `shouldSatisfy` all (> 0)
    sequence_
      [ (a, b) `shouldSatisfy` uncurry (/=)
      | (i, a) <- zip [0 :: Int ..] figures
      , (j, b) <- zip [0 ..] figures
      , i < j
      ]

  it "each sigil's figure is stable across runs" $
    mapM_
      ( \name -> do
          a <- figureOf <$> compiledOf name
          b <- figureOf <$> compiledOf name
          a `shouldBe` b
      )
      sigils

  it "240 frames of each sigil are deterministic" $
    mapM_
      ( \name -> do
          a <- walk 240 <$> castFile name
          b <- walk 240 <$> castFile name
          a `shouldBe` b
      )
      sigils

  it "isFinished still flips exactly at ppEnd" $
    mapM_
      ( \name -> do
          spell <- compiledOf name
          live <- castFile name
          let Seconds end = ppEnd (spellPhases spell)
              stepTo t = advanceSpell (FrameInput (DeltaTime t)) live
          isFinished (stepTo (end - 0.01)) `shouldBe` False
          isFinished (stepTo (end + 0.01)) `shouldBe` True
      )
      sigils

  it "the sigil is drawn, not scattered: particle count grows through the Drawing window" $ do
    spell <- compiledOf "lattice-seal"
    let Seconds drawEnd = ppDrawEnd (spellPhases spell)
        countAt t = pbCount (sample spell ctx (Time t))
    -- Strokes are walked in index order and index order is birth order,
    -- so the drawn figure fills in over the window rather than appearing
    -- at once.
    case [countAt (drawEnd * f) | f <- [0.1, 0.2 .. 0.9]] of
      [] -> expectationFailure "no samples taken"
      samples@(first : _) -> do
        first `shouldSatisfy` (> 0)
        maximum samples `shouldSatisfy` (> first)
