-- | T-S7 (func-spec 0006 §8): end-to-end acceptance of the lifecycle
-- phases and formation emitters, headless — @grand-sigil@ (full loadout:
-- phases + shape + fire + nodes) and @bare-sigil@ (phases-only, every
-- slot empty: boundary ring + plain discharge) each run the whole
-- four-phase arc with a non-empty particle set in every window, the two
-- examples are distinguishable, and 'isFinished' flips exactly at
-- 'ppEnd'. The window/hot-reload smoke is manual (spec 0006 §10).
module Acceptance6Spec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle)
import Magic.Codec (loadCircle)
import Magic.Compile (CompiledSpell (..), PhasePlan (..), compile)
import Magic.Interface
  ( CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , castSpell
  , isFinished
  , stepSpell
  )
import Magic.Particle.Analytic (sample)
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Types (Seconds (..))
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 99}

loadExample :: FilePath -> IO Circle
loadExample path = do
  bytes <- BS.readFile path
  either (fail . show) pure (loadCircle bytes)

compiledOf :: FilePath -> IO CompiledSpell
compiledOf path = do
  c <- loadExample path
  either (fail . show) pure (compile c)

positionsAt :: CompiledSpell -> Double -> [V3]
positionsAt spell t =
  let buf = sample spell ctx (Time t)
   in [V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) | j <- [0 .. pbCount buf - 1]]

-- | One representative sample time per phase window (each window's
-- midpoint), from the compiled 'PhasePlan'.
phaseSampleTimes :: CompiledSpell -> (Double, Double, Double, Double)
phaseSampleTimes spell =
  let plan = spellPhases spell
      Seconds drawEnd = ppDrawEnd plan
      Seconds convergeEnd = ppConvergeEnd plan
      Seconds castingEnd = ppCastingEnd plan
      Seconds endV = ppEnd plan
   in (drawEnd / 2, (drawEnd + convergeEnd) / 2, (convergeEnd + castingEnd) / 2, (castingEnd + endV) / 2)

checkFourNonEmptyWindows :: FilePath -> Expectation
checkFourNonEmptyWindows path = do
  spell <- compiledOf path
  let (tDraw, tConverge, tCasting, tDissipate) = phaseSampleTimes spell
  mapM_
    (\t -> length (positionsAt spell t) `shouldSatisfy` (> 0))
    [tDraw, tConverge, tCasting, tDissipate]

checkFinishesAtLifetime :: FilePath -> Expectation
checkFinishesAtLifetime path = do
  spell <- compiledOf path
  circle <- loadExample path
  let Seconds lifetime = spellLifetime spell
      dt = 1 / 60 :: Double
      framesBefore = floor ((lifetime - 0.05) / dt) :: Int
      framesAfter = ceiling ((lifetime + 0.05) / dt) :: Int
      fi = FrameInput (DeltaTime dt)
      runN k s = if k <= (0 :: Int) then s else runN (k - 1) (fst (stepSpell fi s))
  active0 <- either (fail . show) pure (castSpell (CastRequest circle ctx))
  isFinished (runN framesBefore active0) `shouldBe` False
  isFinished (runN framesAfter active0) `shouldBe` True

spec :: Spec
spec = describe "lifecycle acceptance: grand-sigil / bare-sigil (spec 0006 S7)" $ do
  it "grand-sigil: every one of the four phase windows has a non-empty particle set" $
    checkFourNonEmptyWindows "assets/spells/grand-sigil.json"

  it "bare-sigil: every one of the four phase windows has a non-empty particle set" $
    checkFourNonEmptyWindows "assets/spells/bare-sigil.json"

  it "grand-sigil and bare-sigil are distinguishable (particle counts and positions differ)" $ do
    grand <- compiledOf "assets/spells/grand-sigil.json"
    bare <- compiledOf "assets/spells/bare-sigil.json"
    -- Both are drawing at t = 0.4 (grand's draw window is [0, 1.2), bare's is [0, 1.0)).
    let grandPos = positionsAt grand 0.4
        barePos = positionsAt bare 0.4
    length grandPos `shouldNotBe` length barePos
    grandPos `shouldNotBe` barePos

  it "isFinished flips exactly at ppEnd (spellLifetime) for both examples" $ do
    checkFinishesAtLifetime "assets/spells/grand-sigil.json"
    checkFinishesAtLifetime "assets/spells/bare-sigil.json"
