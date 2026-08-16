-- | S4 (func-spec 0020 §7): end-to-end acceptance of the motion round.
--
-- Func-spec 0016 gave the sigil a face and 0017 kept it on screen for the
-- whole cast; this round is what turns it from a decal into something
-- that reads as /running machinery/. The promise is three specific
-- things a viewer should be able to see, and all three are asserted here
-- from sampled world positions rather than from the derivation:
--
--   * the figure turns — its point set at @t@ is not its point set at
--     @t'@;
--   * neighbouring rings turn opposite ways;
--   * it winds up while the spell charges and then holds that speed —
--     angular speed strictly increasing before @castStart@, flat after.
--
-- Plus the two invariants the round must not disturb: 240 frames stay
-- bit-for-bit reproducible (nothing here introduces cross-frame state —
-- the angle is a pure function of the cast clock), and 'isFinished' still
-- flips exactly at @ppEnd@.
module Acceptance20Spec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import Magic.Circle (Circle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Motion (..)
  , Phase (..)
  , PhasePlan (..)
  , SpawnPattern (..)
  , compile
  )
import Magic.Interface
  ( ActiveSpell
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput
  , advanceSpell
  , castSpell
  , isFinished
  , observeSpell
  )
import Magic.Particle.Analytic (particlePosition, sample)
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Sigil (SigilSpin (..), SigilStroke (..))
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..), cross, dot, norm)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (sample)

-- | Facing +Y from the origin, so the sigil's face normal is exactly
-- @(0, 1, 0)@ — which is what lets the angular measurements below be
-- signed without reconstructing a basis.
ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

faceNormal :: V3
faceNormal = V3 0 1 0

sigils :: [String]
sigils = ["bare-sigil", "grand-sigil", "lattice-seal", "soft-bloom"]

-- | The sigils that actually have ring layers on top of the silhouette.
layeredSigils :: [String]
layeredSigils = ["grand-sigil", "lattice-seal", "soft-bloom"]

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

frameStep :: FrameInput
frameStep = FrameInput (DeltaTime (1 / 60))

walk :: Int -> ActiveSpell -> [FrameOutput]
walk n spell0 = go n spell0
  where
    go 0 _ = []
    go k s = let s' = advanceSpell frameStep s in observeSpell s' : go (k - 1 :: Int) s'

-- | The stroke emitters of a compiled spell, in draw order.
strokeEmitters :: CompiledSpell -> [(Int, SigilStroke)]
strokeEmitters spell =
  [ (e, sk)
  | (e, em) <- zip [0 ..] (V.toList (spellEmitters spell))
  , SpawnOnStroke sk <- [motSpawn (emMotion em)]
  ]

-- | Where index @i@ of emitter @e@ sits at cast time @t@, taken at age 0.
--
-- Age is irrelevant to a formation particle — it holds where it was drawn
-- (@Forward 0@, no drift, no convergence) — so this reads the /figure/ at
-- @t@ without having to chase which generation happens to be alive.
probe :: CompiledSpell -> Int -> Int -> Double -> V3
probe spell e i t = particlePosition ctx (Time t) (spellEmitters spell V.! e) i 0

-- | Signed angle from @p@ to @q@ about the face normal, radians.
turnedBy :: V3 -> V3 -> Float
turnedBy p q = atan2 (dot faceNormal (cross p q)) (dot p q)

-- | How far emitter @e@'s figure turned between @t0@ and @t1@, measured
-- on a particle far enough out for the angle to be well conditioned.
turnOf :: CompiledSpell -> Int -> Double -> Double -> Float
turnOf spell e t0 t1 = turnedBy (probe spell e i t0) (probe spell e i t1)
  where
    em = spellEmitters spell V.! e
    -- The index whose sample sits furthest from the origin.
    i =
      snd
        ( maximum
            [(norm (probe spell e j 0), j) | j <- [0 .. emCount em - 1]]
        )

pointsAt :: CompiledSpell -> Double -> [V3]
pointsAt spell t =
  [probe spell e i t | (e, _) <- strokeEmitters spell, i <- [0 .. emCount (spellEmitters spell V.! e) - 1]]

spec :: Spec
spec = describe "func-spec 0020 acceptance" $ do
  it "the sigil actually turns: its point set at one instant is not its point set at another" $
    mapM_
      ( \name -> do
          spell <- compiledOf name
          let Seconds end = ppEnd (spellPhases spell)
          sequence_
            [ pointsAt spell (end * a) `shouldNotBe` pointsAt spell (end * b)
            | (a, b) <- [(0.1, 0.3), (0.3, 0.6), (0.6, 0.95)]
            ]
      )
      sigils

  it "and it is still exactly the figure 0016 drew at t = 0" $
    mapM_
      ( \name -> do
          spell <- compiledOf name
          -- spinAngle sp 0 == 0, so the first instant is untouched (§2.4).
          sequence_
            [ turnOf spell e 0 0 `shouldBe` 0
            | (e, _) <- strokeEmitters spell
            ]
      )
      sigils

  it "neighbouring rings turn opposite ways" $
    mapM_
      ( \name -> do
          spell <- compiledOf name
          let Seconds castStart = ppConvergeEnd (spellPhases spell)
              t = castStart * 0.8
              turns = [turnOf spell e 0 t | (e, _) <- strokeEmitters spell]
              -- The two silhouette strokes are one group, so the whole
              -- draw order is: frame, frame, layer 1, layer 2, ...
              groups = case turns of
                (frame : _ : layers) -> frame : layers
                _ -> []
          length groups `shouldSatisfy` (>= 3)
          sequence_
            [ counterexampleOf (name, a, b) (signum a /= signum b && a /= 0)
            | (a, b) <- zip groups (drop 1 groups)
            ]
      )
      layeredSigils

  it "the sigil winds up while the spell charges, then holds that speed" $
    mapM_
      ( \name -> do
          spell <- compiledOf name
          let Seconds castStart = ppConvergeEnd (spellPhases spell)
              Seconds end = ppEnd (spellPhases spell)
              -- A layer with a charge-up worth measuring.
              candidates =
                [e | (e, sk) <- strokeEmitters spell, abs (ssAccel (skSpin sk)) > 0.01]
              window w t0 = abs (turnOf spell w t0 (t0 + 0.2))
          case candidates of
            [] -> expectationFailure (name ++ ": no stroke charges up")
            (e : _) -> do
              let ramp = [window e t | t <- [0.05, 0.05 + gap .. castStart - 0.25]]
                  gap = (castStart - 0.3) / 4
                  held = [window e t | t <- [castStart + 0.1, castStart + 0.1 + hgap .. end - 0.3]]
                  hgap = max 0.2 ((end - castStart - 0.4) / 4)
              length ramp `shouldSatisfy` (>= 3)
              -- Strictly increasing while charging...
              and (zipWith (<) ramp (drop 1 ramp)) `shouldBe` True
              -- ...and flat afterwards.
              length held `shouldSatisfy` (>= 3)
              (maximum held - minimum held) `shouldSatisfy` (< 1e-3)
              -- The held speed is the speed the charge-up reached.
              last ramp `shouldSatisfy` (< head held + 1e-3)
      )
      layeredSigils

  describe "invariants the round must not disturb" $ do
    it "240 frames of each sigil are deterministic" $
      mapM_
        ( \name -> do
            a <- walk 240 <$> castFile name
            b <- walk 240 <$> castFile name
            a `shouldBe` b
        )
        sigils

    prop "sampling the same instant twice gives the same bits" $
      forAll (choose (-1, 12)) $ \t -> ioProperty $ do
        spell <- compiledOf "lattice-seal"
        pure (sample spell ctx (Time t) === sample spell ctx (Time t))

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

    it "the buffer never outgrows the budget with the sigil in motion" $
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

    it "every emitter is still tagged Drawing or Casting, nothing new was added" $
      mapM_
        ( \name -> do
            spell <- compiledOf name
            map emPhase (V.toList (spellEmitters spell))
              `shouldSatisfy` all (`elem` [Drawing, Casting])
        )
        sigils

-- | An assertion that reports the offending values rather than @False@.
counterexampleOf :: (Show a) => a -> Bool -> Expectation
counterexampleOf what ok = if ok then pure () else expectationFailure (show what)
