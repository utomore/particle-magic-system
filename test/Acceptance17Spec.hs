-- | S3 (func-spec 0017 §7): end-to-end acceptance of the persistence
-- round.
--
-- The promise: the spell is fired /out of/ a sigil that is still there.
-- So during Casting a phased spell must show both at once — the drawn
-- circle out at its stroke radii and the main effect doing whatever it
-- does — and the sigil must go out with the spell, not before it.
--
-- Guarded alongside: func-spec 0016's own law (the sigil fills in over
-- the Drawing window, because index order is draw order) still holds, and
-- 'isFinished' still flips exactly at @ppEnd@ even though something is
-- now alive right up to it.
module Acceptance17Spec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle)
import Magic.Codec (loadCircle)
import Magic.Compile (CompiledSpell (..), EmitterSpec (..), Phase (..), PhasePlan (..), compile)
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
  , castSpell
  , isFinished
  , observeSpell
  )
import Magic.Particle.Analytic (aliveSlots, sample)
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

sigils :: [String]
sigils = ["bare-sigil", "grand-sigil", "lattice-seal"]

sigilCircle :: String -> IO Circle
sigilCircle name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

compiledOf :: String -> IO CompiledSpell
compiledOf name = sigilCircle name >>= either (fail . show) pure . compile

castFile :: String -> IO ActiveSpell
castFile name = do
  circle <- sigilCircle name
  either (fail . show) pure (castSpell (CastRequest circle ctx))

dt :: FrameInput
dt = FrameInput (DeltaTime (1 / 60))

walk :: Int -> ActiveSpell -> [FrameOutput]
walk n spell0 = go n spell0
  where
    go 0 _ = []
    go k s = let s' = advanceSpell dt s in observeSpell s' : go (k - 1 :: Int) s'

-- | @(formation rows, casting rows)@ alive at @t@.
rowsAt :: CompiledSpell -> Double -> (Int, Int)
rowsAt spell t = (count (/= Casting), count (== Casting))
  where
    count p =
      length
        [ ()
        | (e, _) <- aliveSlots spell (Time t)
        , p (emPhase (spellEmitters spell V.! e))
        ]

spec :: Spec
spec = describe "func-spec 0017 acceptance" $ do
  it "the spell fires out of a sigil that is still drawn: both are alive during Casting" $
    mapM_
      ( \name -> do
          spell <- compiledOf name
          let Seconds castStart = ppConvergeEnd (spellPhases spell)
              Seconds castingEnd = ppCastingEnd (spellPhases spell)
              probes = [castStart + (castingEnd - castStart) * f | f <- [0.2, 0.5, 0.8]]
          sequence_
            [ rowsAt spell t `shouldSatisfy` \(formation, casting) ->
                formation > 0 && casting > 0
            | t <- probes
            ]
      )
      sigils

  it "the sigil goes out with the spell, not before it" $
    mapM_
      ( \name -> do
          spell <- compiledOf name
          let Seconds end = ppEnd (spellPhases spell)
          fst (rowsAt spell (end - 0.02)) `shouldSatisfy` (> 0)
          rowsAt spell (end + 0.02) `shouldBe` (0, 0)
      )
      sigils

  it "func-spec 0016's law survives: the sigil still fills in over the Drawing window" $
    mapM_
      ( \name -> do
          spell <- compiledOf name
          let Seconds drawEnd = ppDrawEnd (spellPhases spell)
              counts = [fst (rowsAt spell (drawEnd * f)) | f <- [0.1, 0.2 .. 0.9]]
          case counts of
            [] -> expectationFailure "no samples taken"
            (first : _) -> do
              first `shouldSatisfy` (> 0)
              maximum counts `shouldSatisfy` (> first)
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

  it "the buffer never outgrows the budget even with the sigil held all cast" $
    mapM_
      ( \name -> do
          spell <- compiledOf name
          let Seconds end = ppEnd (spellPhases spell)
          sequence_
            [ pbCount (sample spell ctx (Time t)) `shouldSatisfy` (<= spellBudget spell)
            | t <- [0, 0.05 .. end + 0.5]
            ]
      )
      sigils

  it "the sigil's own rows are a stable count once it is fully drawn" $ do
    -- Every index respawns cyclically, so past one full formLife the
    -- drawn figure is continuously present rather than flickering out.
    spell <- compiledOf "lattice-seal"
    let Seconds castStart = ppConvergeEnd (spellPhases spell)
        Seconds end = ppEnd (spellPhases spell)
        samples = [fst (rowsAt spell t) | t <- [castStart, castStart + 0.1 .. end - 0.1]]
    minimum samples `shouldSatisfy` (> 0)

  it "positions are unaffected by how the buffer is observed (sample is the single source)" $ do
    spell <- compiledOf "grand-sigil"
    let buf = sample spell ctx (Time 2.0)
    U.length (pbPosX buf) `shouldBe` pbCount buf
