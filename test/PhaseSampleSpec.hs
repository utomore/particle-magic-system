-- | S5 (func-spec 0006 §8): end-to-end phase sampling behavior through
-- the untouched 'sample' function — Drawing-period geometry, Converging
-- collapse, formation death at castStart, casting's delayed first birth,
-- determinism and the buffer invariant.
module PhaseSampleSpec (spec) where

import Data.Maybe (isJust, isNothing)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , PhasePlan (..)
  , compile
  )
import Magic.Particle.Analytic (particleAge, sample)
import Magic.Particle.Buffer (ParticleBuffer (..), bufferInvariant)
import Magic.Rune (InnerRune (..), NodeRune (..))
import Magic.Types
  ( CastContext (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , basisFromNormal
  , normalize
  , norm
  , vscale
  )
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (sample)

ctx :: CastContext
ctx =
  CastContext
    { casterPos = V3 0 0 0
    , casterFacing = V3 0 0 1
    , seed = Seed 7
    }

compiled :: Circle -> CompiledSpell
compiled c = either (error . show) id (compile c)

genPhaseConfig :: Gen PhaseConfig
genPhaseConfig =
  PhaseConfig
    <$> (Seconds <$> choose (0.3, 3))
    <*> (Seconds <$> choose (0.1, 2))

-- | Only the boundary ring (always present when phases are active) plus
-- the default casting discharge: buffer contents are unambiguous — every
-- particle at t < castStart is a formation particle, every particle at
-- t = castStart + delay is the first casting one.
boundaryCircle :: PhaseConfig -> Circle
boundaryCircle pc = emptyCircle {circlePhases = Just pc}

boundaryEmitter :: CompiledSpell -> EmitterSpec
boundaryEmitter spell = V.toList (spellEmitters spell) !! 1

radial :: V3 -> Float
radial p = norm (p - casterPos ctx)

positionsOf :: ParticleBuffer -> [V3]
positionsOf buf =
  [ V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j)
  | j <- [0 .. pbCount buf - 1]
  ]

phDrawEndOf :: CompiledSpell -> Seconds
phDrawEndOf spell = ppDrawEnd (spellPhases spell)

phConvergeEndOf :: CompiledSpell -> Seconds
phConvergeEndOf spell = ppConvergeEnd (spellPhases spell)

aliveIndices :: EmitterSpec -> Time -> [Int]
aliveIndices em t =
  [i | i <- [0 .. emCount em - 1], isJust (particleAge (emSpawn em) (emCount em) i t)]

spec :: Spec
spec = describe "end-to-end phase sampling (spec 0006 S5)" $ do
  it "Drawing: boundary-ring particles exist and lie in the [1.45, 1.55] band" $ do
    let pc = PhaseConfig (Seconds 1.2) (Seconds 0.6)
        spell = compiled (boundaryCircle pc)
        buf = sample spell ctx (Time 0.5) -- within [0, 1.2) = Drawing
        radii = map radial (positionsOf buf)
    length radii `shouldSatisfy` (> 0)
    radii `shouldSatisfy` all (\r -> r >= 1.45 - 1e-3 && r <= 1.55 + 1e-3)

  it "Drawing: a node emitter's particles sit exactly at its fixed anchor (mapped through the caster frame)" $ do
    let pc = PhaseConfig (Seconds 1.2) (Seconds 0.6)
        c =
          emptyCircle
            { core = Core Nothing (Nodes (Just (DirBias 0.0)) Nothing Nothing Nothing)
            , circlePhases = Just pc
            }
        spell = compiled c
        t = Time 0.5
        buf = sample spell ctx t
        [castingEm, boundaryEm, node] = V.toList (spellEmitters spell) -- 0=casting, 1=boundary, 2=north
        facing = normalize (casterFacing ctx)
        (fu, fw) = basisFromNormal facing
        -- Node offset in face coords is (0, 0.35, 0); the caster frame
        -- transform is the same one 'Magic.Particle.Analytic.sample' uses.
        expectedAnchor = casterPos ctx + vscale 0.35 fw + vscale 0 fu
        -- Skip exactly as many buffer entries as the emitters before the
        -- node one actually contributed (not their nominal counts — a
        -- ring's alive count varies with t within its spawn window).
        skipCount = length (aliveIndices castingEm t) + length (aliveIndices boundaryEm t)
        nodePos = drop skipCount (positionsOf buf)
    length nodePos `shouldSatisfy` (> 0)
    emCount node `shouldBe` 12
    nodePos `shouldSatisfy` all (\p -> norm (p - expectedAnchor) < 1e-3)

  prop "Converging: paired-index lateral distance from the axis is non-increasing as t grows toward castStart" $
    forAll genPhaseConfig $ \pc ->
      let spell = compiled (boundaryCircle pc)
          em = boundaryEmitter spell
          Seconds drawEnd = phDrawEndOf spell
          Seconds castStart = phConvergeEndOf spell
       in (castStart - drawEnd > 0.05) ==> forAll (choose (drawEnd, castStart - 0.01)) $ \t1 ->
            forAll (choose (t1, castStart - 0.001)) $ \t2 ->
              let alive1 = zip (aliveIndices em (Time t1)) (positionsOf (sample spell ctx (Time t1)))
                  alive2 = zip (aliveIndices em (Time t2)) (positionsOf (sample spell ctx (Time t2)))
                  paired = [(radial p1, radial p2) | (i1, p1) <- alive1, (i2, p2) <- alive2, i1 == i2]
               in not (null paired) ==> property (all (\(r1, r2) -> r2 <= r1 + 1e-3) paired)

  prop "formation particles never survive at or after castStart" $
    forAll genPhaseConfig $ \pc ->
      let spell = compiled (boundaryCircle pc)
          em = boundaryEmitter spell
          Seconds castStart = phConvergeEndOf spell
       in forAll (choose (castStart, castStart + 20)) $ \t ->
            property (all (\i -> isNothing (particleAge (emSpawn em) (emCount em) i (Time t))) [0 .. emCount em - 1])

  prop "at t = castStart the buffer holds exactly the casting emitter's first particle (formation is fully dead)" $
    forAll genPhaseConfig $ \pc ->
      let spell = compiled (boundaryCircle pc)
          Seconds castStart = phConvergeEndOf spell
          buf = sample spell ctx (Time castStart)
       in pbCount buf === 1

  prop "casting's own first particle is never born earlier than castStart + its own delay" $
    forAll genPhaseConfig $ \pc -> forAll (choose (0, 5)) $ \da ->
      let c =
            emptyCircle
              { innerRings = TwoOf (Just (TimingRune (Envelope (Seconds da) (Seconds 5) (Seconds 1)))) Nothing
              , circlePhases = Just pc
              }
          spell = compiled c
          casting = V.head (spellEmitters spell)
          Seconds castStart = phConvergeEndOf spell
          justBefore = particleAge (emSpawn casting) (emCount casting) 0 (Time (castStart + da - 1e-3))
          atBirth = particleAge (emSpawn casting) (emCount casting) 0 (Time (castStart + da))
       in isNothing justBefore .&&. isJust atBirth

  prop "bit-for-bit deterministic in (Seed, t) with phases active" $
    forAll genPhaseConfig $ \pc -> \(sd :: Word) -> forAll (choose (-1, 10)) $ \t ->
      let spell = compiled (boundaryCircle pc)
          c = ctx {seed = Seed (fromIntegral sd)}
       in sample spell c (Time t) === sample spell c (Time t)

  prop "buffer invariant holds and count stays within budget for phased spells" $
    forAll genPhaseConfig $ \pc -> forAll (choose (-1, 10)) $ \t ->
      let spell = compiled (boundaryCircle pc)
          buf = sample spell ctx (Time t)
       in property (bufferInvariant buf && pbCount buf <= spellBudget spell)
