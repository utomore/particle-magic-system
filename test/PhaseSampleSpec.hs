-- | S5 (func-spec 0006 §8): end-to-end phase sampling behavior through
-- the untouched 'sample' function — Drawing-period geometry, casting's
-- delayed first birth, determinism and the buffer invariant.
--
-- Func-spec 0016 replaced the geometry (bands of fog became strokes) and
-- func-spec 0017 replaced the time axis (the sigil holds where it was
-- drawn and lives until 'ppEnd' instead of collapsing and dying at
-- castStart); the properties below track those two changes at the same
-- strength rather than being deleted.
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
import Magic.Sigil (sigilPlan, spStrokes, strokeRadius)
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
  it "Drawing: sigil particles exist and every one lies inside its stroke's radius bound" $ do
    let pc = PhaseConfig (Seconds 1.2) (Seconds 0.6)
        circle = boundaryCircle pc
        spell = compiled circle
        t = Time 0.5 -- within [0, 1.2) = Drawing
        buf = sample spell ctx t
        radii = map radial (positionsOf buf)
        -- The plan's own conservative bound replaces spec 0006's fixed
        -- [1.45, 1.55] band: the geometry is derived now, the bound is
        -- what stays checkable (func-spec 0016 §2).
        bound = maximum (map strokeRadius (V.toList (spStrokes (sigilPlan circle))))
    length radii `shouldSatisfy` (> 0)
    radii `shouldSatisfy` all (\r -> r <= bound + 1e-3)

  it "Drawing: the boundary ring is drawn, not scattered — its points sit on the silhouette" $ do
    let pc = PhaseConfig (Seconds 1.2) (Seconds 0.6)
        circle = boundaryCircle pc
        spell = compiled circle
        em = boundaryEmitter spell
        t = Time 0.5
        alive = aliveIndices em t
        buf = sample spell ctx t
        -- The casting emitter has not started, so the buffer's leading
        -- rows are this emitter's, in index order.
        ringPos = take (length alive) (positionsOf buf)
        radii = map radial ringPos
    length alive `shouldSatisfy` (> 0)
    -- The boundary stroke is a closed ring of radius 1.5 plus jitter.
    radii `shouldSatisfy` all (\r -> abs (r - 1.5) < 0.05)

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
        emitters = V.toList (spellEmitters spell)
        node = last emitters
        facing = normalize (casterFacing ctx)
        (fu, fw) = basisFromNormal facing
        -- Node offset in face coords is (0, 0.35, 0); the caster frame
        -- transform is the same one 'Magic.Particle.Analytic.sample' uses.
        expectedAnchor = casterPos ctx + vscale 0.35 fw + vscale 0 fu
        -- Skip exactly as many buffer entries as the emitters before the
        -- node one actually contributed (not their nominal counts — a
        -- stroke's alive count varies with t within its spawn window).
        skipCount = sum [length (aliveIndices em t) | em <- init emitters]
        nodePos = drop skipCount (positionsOf buf)
    length nodePos `shouldSatisfy` (> 0)
    emCount node `shouldBe` 12
    nodePos `shouldSatisfy` all (\p -> norm (p - expectedAnchor) < 1e-3)

  -- Func-spec 0017 replaces spec 0006's convergence semantics: the sigil
  -- no longer collapses onto the axis at castStart, it holds the position
  -- it was drawn at for as long as the spell lasts. The three properties
  -- that asserted the collapse and the death at castStart are replaced by
  -- their successors here, at the same strength.
  prop "Converging: a paired index stays exactly where it was drawn (no collapse)" $
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
               in not (null paired) ==> property (all (\(r1, r2) -> abs (r2 - r1) < 1e-3) paired)

  prop "formation particles are alive throughout the cast, right up to ppEnd" $
    forAll genPhaseConfig $ \pc ->
      let spell = compiled (boundaryCircle pc)
          em = boundaryEmitter spell
          Seconds end = ppEnd (spellPhases spell)
       in forAll (choose (0.01, end - 0.01)) $ \t ->
            property (any (\i -> isJust (particleAge (emSpawn em) (emCount em) i (Time t))) [0 .. emCount em - 1])

  prop "formation particles never survive past ppEnd" $
    forAll genPhaseConfig $ \pc ->
      let spell = compiled (boundaryCircle pc)
          em = boundaryEmitter spell
          Seconds end = ppEnd (spellPhases spell)
       in forAll (choose (end, end + 20)) $ \t ->
            property (all (\i -> isNothing (particleAge (emSpawn em) (emCount em) i (Time t))) [0 .. emCount em - 1])

  prop "at t = castStart the sigil is still drawn, and the casting emitter has just started" $
    forAll genPhaseConfig $ \pc ->
      let spell = compiled (boundaryCircle pc)
          Seconds castStart = phConvergeEndOf spell
          buf = sample spell ctx (Time castStart)
          casting = V.head (spellEmitters spell)
          castingAlive =
            length
              [ i
              | i <- [0 .. emCount casting - 1]
              , isJust (particleAge (emSpawn casting) (emCount casting) i (Time castStart))
              ]
       in castingAlive === 1 .&&. pbCount buf > 1

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
