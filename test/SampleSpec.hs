-- | T-S7 (func-spec 0002 §8): the generalized emitter-driven sampler.
-- Determinism, buffer invariants, envelope windows, the plain-discharge
-- equivalence with the §4.5 constants, and shape-spawn geometry.
module SampleSpec (spec) where

import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , compile
  )
import qualified Data.Vector as V
import Magic.Particle.Analytic (particleAge, sample)
import Magic.Particle.Buffer (ParticleBuffer (..), bufferInvariant)
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , EssenceRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types
  ( CastContext (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , basisFromNormal
  , dot
  , hashChan
  , normalize
  , vscale
  )
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (sample)

ctx :: CastContext
ctx =
  CastContext
    { casterPos = V3 0 0 0
    , casterFacing = V3 0 1 0
    , seed = Seed 42
    }

compiled :: Circle -> CompiledSpell
compiled c = either (error . show) id (compile c)

-- | A circle exercising every fold path: shape spawn, radial radiation,
-- spiral trajectory, shifted timing, fire essence, node bias.
busyCircle :: Circle
busyCircle =
  Circle
    { outerRings =
        TwoOf
          (Just (ShapeRune (Ring 1 1.5)))
          (Just (RadiateRune RadialOutward))
    , interLayer = Just (PhaseRune (Seconds 0.25))
    , innerRings =
        TwoOf
          (Just (TrajectoryRune (Spiral 6 0.4 2)))
          (Just (TimingRune (Envelope (Seconds 0) (Seconds 4) (Seconds 2))))
    , core =
        Core
          { coreCenter = Just (EssenceRune Fire 1.5)
          , coreNodes = Nodes (Just (DirBias 0.4)) Nothing Nothing Nothing
          }
    , circlePhases = Nothing
    , circleFields = []
    , circleAnchors = Nothing
    , circleSigil = Nothing
    , circleVolume = Nothing
    }

spec :: Spec
spec = describe "emitter-driven sampling (spec 0002 S7)" $ do
  prop "bit-for-bit deterministic in (Seed, t)" $
    \(sd :: Word) -> forAll (choose (0 :: Double, 12)) $ \t ->
      let spell = compiled busyCircle
          c = ctx {seed = Seed (fromIntegral sd)}
       in sample spell c (Time t) == sample spell c (Time t)

  prop "buffer invariant holds and count stays within budget" $
    forAll (choose (-1 :: Double, 12)) $ \t ->
      let spell = compiled busyCircle
          buf = sample spell ctx (Time t)
       in bufferInvariant buf && pbCount buf <= spellBudget spell

  it "outside the envelope window the buffer is empty" $ do
    let spell = compiled emptyCircle
    pbCount (sample spell ctx (Time (-0.5))) `shouldBe` 0
    -- spellLifetime 10s: the last batch has died by then.
    pbCount (sample spell ctx (Time 10.001)) `shouldBe` 0
    pbCount (sample spell ctx (Time 9.9)) `shouldSatisfy` (> 0)

  describe "plain-discharge equivalence (empty circle vs §4.5 constants)" $ do
    it "the fountain is at full budget mid-window (256 particles)" $ do
      let spell = compiled emptyCircle
      pbCount (sample spell ctx (Time 3)) `shouldBe` 256

    it "particles are white 0xFFFFFFFF and size 0.05" $ do
      let buf = sample (compiled emptyCircle) ctx (Time 3)
      U.toList (pbColor buf) `shouldSatisfy` all (== 0xFFFFFFFF)
      U.toList (pbSize buf) `shouldSatisfy` all (== 0.05)

    it "positions follow casterPos + facing·4·age + hashChan-1.6-drift·age" $ do
      let spell = compiled emptyCircle
          env = emSpawn (V.head (spellEmitters spell))
          t = Time 1.0
          buf = sample spell ctx t
          facing = normalize (casterFacing ctx)
          (u, w) = basisFromNormal facing
          expected i = do
            age <- particleAge env 256 i t
            let ageF = realToFrac age :: Float
                c0 = hashChan (seed ctx) i 0 - 0.5
                c1 = hashChan (seed ctx) i 1 - 0.5
                drift = vscale (c0 * 1.6) u + vscale (c1 * 1.6) w
            pure (casterPos ctx + vscale (4.0 * ageF) facing + vscale ageF drift)
          alive = [(k, p) | (k, Just p) <- zip [0 ..] (map expected [0 .. 255])]
      -- The sampler packs alive particles in index order.
      length alive `shouldBe` pbCount buf
      sequence_
        [ do
            let got = V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j)
                V3 dx dy dz = got - p
            abs dx + abs dy + abs dz < 1e-4
              `shouldBe` True
        | (j, (_, p)) <- zip [0 ..] alive
        ]

    it "the life field is age / 2s" $ do
      let spell = compiled emptyCircle
          env = emSpawn (V.head (spellEmitters spell))
          t = Time 1.5
          buf = sample spell ctx t
          ages = [a | Just a <- [particleAge env 256 i t | i <- [0 .. 255]]]
      sequence_
        [ abs (realToFrac (pbLife buf U.! j) - age / 2) < 1e-6 `shouldBe` True
        | (j, age) <- zip [0 ..] ages
        ]

  it "SpawnOnShape Ring: birth positions project into the annulus" $ do
    let ringCircle =
          emptyCircle
            { outerRings = TwoOf (Just (ShapeRune (Ring 1 2))) Nothing
            }
        spell = compiled ringCircle
        buf = sample spell ctx (Time 1.0)
        facing = normalize (casterFacing ctx)
        (u, w) = basisFromNormal facing
        radii =
          [ sqrt (sx * sx + sy * sy)
          | j <- [0 .. pbCount buf - 1]
          , let rel = V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) - casterPos ctx
                sx = dot rel u
                sy = dot rel w
          ]
    pbCount buf `shouldSatisfy` (> 0)
    radii `shouldSatisfy` all (\r -> r >= 1 - 1e-3 && r <= 2 + 1e-3)
