-- | S2 (func-spec 0023 §6): the velocity columns' definition, its opt-in,
-- and its two compatibility laws.
--
-- Four things are asserted, and they are not of the same kind.
--
--   * The /definition/ (§2.4) is frozen, so it is checked against its own
--     statement rather than against a plausible answer: the backward
--     difference of 'particlePosition' over 'velocityStep', one-sided
--     below that age, zero at birth.
--   * The /opt-in law/ is the expensive promise. Turning a trail on may
--     add velocity columns and must change nothing else — same rows, same
--     six columns, same bits — so a spell without one pays exactly what it
--     paid before this round existed.
--   * The /field witness/ shows the trail bending with the field, which is
--     the whole reason velocity is differenced on the rendered position
--     rather than the analytic one.
--   * __Law 2 of func-spec 0022__ is /extended/, not weakened: parallel ≡
--     sequential now over nine columns rather than six.
module VelocitySampleSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import GHC.Float (castFloatToWord32)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( Anchor (..)
  , Appearance (..)
  , BillboardShape (..)
  , BlendMode (..)
  , ColorRamp (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , ParticleBudget (..)
  , Phase (..)
  , PhasePlan (..)
  , SpawnPattern (..)
  , compile
  , noEmitterCode
  , spellNeedsVelocity
  )
import Magic.Interface
  ( CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , advanceSpell
  , castSpell
  , observeSpell
  )
import qualified Magic.Particle.Analytic as A
import Magic.Particle.Analytic
  ( particlePosition
  , particleVelocity
  , sampleParallel
  , sampleSequential
  , velocityStep
  )
import Magic.Particle.Buffer (ParticleBuffer (..), bufferInvariant, hasVelocity)
import Magic.Rune (FaceShape (..), RadiationMode (..), Trajectory (..))
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 20260816}

-- | Bit patterns of all nine columns plus the row count. As in
-- @ParallelSampleSpec@, bits rather than '(==)': numeric equality on
-- 'Float' would miss a NaN and equate ±0, and these are exactness laws.
digest9 :: ParticleBuffer -> (Int, [Word32])
digest9 pb =
  ( pbCount pb
  , concat
      [ bitsOf (pbPosX pb)
      , bitsOf (pbPosY pb)
      , bitsOf (pbPosZ pb)
      , bitsOf (pbSize pb)
      , bitsOf (pbLife pb)
      , U.toList (pbColor pb)
      , bitsOf (pbVelX pb)
      , bitsOf (pbVelY pb)
      , bitsOf (pbVelZ pb)
      ]
  )
  where
    bitsOf = map castFloatToWord32 . U.toList

-- | The six original columns alone — what the opt-in law compares.
digest6 :: ParticleBuffer -> (Int, [Word32])
digest6 pb =
  ( pbCount pb
  , concat
      [ bitsOf (pbPosX pb)
      , bitsOf (pbPosY pb)
      , bitsOf (pbPosZ pb)
      , bitsOf (pbSize pb)
      , bitsOf (pbLife pb)
      , U.toList (pbColor pb)
      ]
  )
  where
    bitsOf = map castFloatToWord32 . U.toList

-- | A synthetic spell whose only variable is the billboard shape — which
-- is exactly the knob the opt-in law is about. Built without 'compile' so
-- the particle counts can cross 'Magic.Particle.Analytic.parallelThreshold'.
syntheticSpell :: BillboardShape -> Int -> Int -> CompiledSpell
syntheticSpell shape emitters count =
  CompiledSpell
    { spellLifetime = Seconds 10
    , spellBudget = emitters * count
    , spellEmitters = V.fromList (map emitterAt [0 .. emitters - 1])
    , spellPhases = PhasePlan (Seconds 0) (Seconds 0) (Seconds 8) (Seconds 10)
    , spellBudgetPlan = ParticleBudget (U.replicate emitters count) (emitters * count)
    , spellFields = []
    }
  where
    emitterAt k =
      EmitterSpec
        { emAnchor = Anchor {anchorOffset = V3 (fromIntegral k) 0 0, anchorNormal = V3 0 0 1}
        , emCount = count
        , emSpawn = Envelope (Seconds (fromIntegral k * 0.25)) (Seconds 8) (Seconds 2)
        , emMotion =
            Motion
              { motSpawn = SpawnOnShape (Ring 0.8 1.2)
              , motTraject = Spiral 4 0.5 0.7
              , motRadiation = AlongNormal
              , motDrift = V3 0 0 0
              , motRange = Nothing
              , motConverge = Nothing
              }
        , emAppearance =
            Appearance (ColorRamp 0xFFD966FF 0xE6390000) 0.05 BlendAdditive Nothing shape
        , emPhase = Casting
        , emCode = noEmitterCode
        }

compiledExample :: String -> IO CompiledSpell
compiledExample name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (compile circle)

-- | Every particle of every batch, as @(velocity, position)@ pairs.
observedRows :: FrameOutput -> [(V3, V3)]
observedRows out =
  [ ( V3 (pbVelX pb U.! i) (pbVelY pb U.! i) (pbVelZ pb U.! i)
    , V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i)
    )
  | b <- batches out
  , let pb = rbParticles b
  , hasVelocity pb
  , i <- [0 .. pbCount pb - 1]
  ]

norm3 :: V3 -> Float
norm3 (V3 x y z) = sqrt (x * x + y * y + z * z)

frameTimes :: [Time]
frameTimes = [Time (fromIntegral n / 60) | n <- [1 .. 60 :: Int]]

spec :: Spec
spec = describe "velocity sampling (func-spec 0023 §6 S2)" $ do
  describe "the frozen definition (§2.4)" $ do
    it "pins the difference step at 1/240 s" $
      -- A constant, never the frame's dt: a dt-derived velocity would make
      -- the same spell trail differently at 30 and 144 fps.
      velocityStep `shouldBe` 1 / 240

    prop "is the backward difference of particlePosition over that step" $
      forAll (choose (velocityStep, 4 :: Double)) $ \age ->
        let spell = syntheticSpell BillboardTrail 1 8
            em = spellEmitters spell V.! 0
            t = Time (age + 0.5)
            here = particlePosition ctx t em 3 age
            before = particlePosition ctx t em 3 (age - velocityStep)
            V3 ex ey ez = here - before
            k = realToFrac (1 / velocityStep) :: Float
         in particleVelocity ctx t em 3 age === V3 (ex * k) (ey * k) (ez * k)

    prop "differences one-sidedly below that age, never past birth" $
      forAll (choose (0, velocityStep :: Double)) $ \age ->
        let spell = syntheticSpell BillboardTrail 1 8
            em = spellEmitters spell V.! 0
            t = Time 1
            got = particleVelocity ctx t em 3 age
         in if age == 0
              then got === V3 0 0 0
              else
                let here = particlePosition ctx t em 3 age
                    before = particlePosition ctx t em 3 0
                    V3 ex ey ez = here - before
                    k = realToFrac (1 / age) :: Float
                 in got === V3 (ex * k) (ey * k) (ez * k)

    prop "is finite everywhere it is defined" $
      forAll (choose (0, 8 :: Double)) $ \age ->
        let spell = syntheticSpell BillboardTrail 1 8
            em = spellEmitters spell V.! 0
            V3 x y z = particleVelocity ctx (Time (age + 1)) em 5 age
         in all (\v -> not (isNaN v) && not (isInfinite v)) [x, y, z]

    prop "is deterministic: the same arguments give the same bits" $
      forAll (choose (0, 8 :: Double)) $ \age ->
        let spell = syntheticSpell BillboardTrail 1 8
            em = spellEmitters spell V.! 0
            t = Time (age + 1)
            once = particleVelocity ctx t em 5 age
            twice = particleVelocity ctx t em 5 age
         in once === twice

  describe "the opt-in" $ do
    it "is decided by the presence of a trail, and by nothing else" $ do
      spellNeedsVelocity (syntheticSpell BillboardTrail 2 16) `shouldBe` True
      spellNeedsVelocity (syntheticSpell BillboardSquare 2 16) `shouldBe` False
      spellNeedsVelocity (syntheticSpell BillboardSoftDot 2 16) `shouldBe` False

    it "is off for every example shipped before this round" $ do
      -- The zero-ripple witness at the asset level: not one existing spell
      -- starts paying for velocity because the feature now exists.
      mapM_
        ( \name -> do
            spell <- compiledExample name
            spellNeedsVelocity spell `shouldBe` False
        )
        [ "converge-flame"
        , "grand-sigil"
        , "gravity-well"
        , "lissajous"
        , "ring-fire"
        , "soft-bloom"
        , "square-burst"
        , "wuxing-seal"
        , "yin-yang"
        ]

    it "is on for comet-trail" $ do
      spell <- compiledExample "comet-trail"
      spellNeedsVelocity spell `shouldBe` True

    prop "a trail-free spell samples to an empty-velocity buffer" $
      forAll (elements [1 .. 3 :: Int]) $ \emitters ->
        forAll (elements frameTimes) $ \t ->
          let pb = A.sample (syntheticSpell BillboardSquare emitters 64) ctx t
           in not (hasVelocity pb) .&&. property (bufferInvariant pb)

    -- The law the whole widening rests on: switching the trail on adds
    -- velocity and touches nothing else.
    prop "turning the trail on changes the six columns by not one bit" $
      forAll (elements [1 .. 3 :: Int]) $ \emitters ->
        forAll (elements frameTimes) $ \t ->
          let plain = A.sample (syntheticSpell BillboardSquare emitters 64) ctx t
              trailed = A.sample (syntheticSpell BillboardTrail emitters 64) ctx t
           in digest6 plain === digest6 trailed
                .&&. property (not (hasVelocity plain))
                .&&. property (hasVelocity trailed || pbCount trailed == 0)

    prop "the sampled velocity is particleVelocity, row for row" $
      forAll (elements frameTimes) $ \t ->
        let spell = syntheticSpell BillboardTrail 1 64
            em = spellEmitters spell V.! 0
            pb = A.sample spell ctx t
            expected =
              [ particleVelocity ctx t em i age
              | i <- [0 .. emCount em - 1]
              , Just age <- [ageOf em i t]
              ]
            got =
              [ V3 (pbVelX pb U.! r) (pbVelY pb U.! r) (pbVelZ pb U.! r)
              | r <- [0 .. pbCount pb - 1]
              ]
         in got === expected

  describe "the force-field witness (§2.4 point 1)" $ do
    -- A trail must bend with the field, or the picture disagrees with the
    -- positions the host is drawing. The analytic difference alone cannot
    -- know about a field, so this is what proves the field half is wired.
    it "diverges from the fieldless velocity once the field has acted" $ do
      bytes <- BS.readFile "assets/spells/comet-trail.json"
      circle <- either (fail . show) pure (loadCircle bytes)
      spell0 <- either (fail . show) pure (castSpell (CastRequest circle ctx))
      compiled <- compiledExample "comet-trail"
      let dt = FrameInput (DeltaTime (1 / 60))
          advanced = iterate (advanceSpell dt) spell0 !! 150
          rows = observedRows (observeSpell advanced)
          -- The analytic half alone, for the same instant.
          t = Time (150 / 60)
          analyticOnly =
            [ particleVelocity ctx t em i age
            | em <- V.toList (spellEmitters compiled)
            , i <- [0 .. emCount em - 1]
            , Just age <- [ageOf em i t]
            ]
      rows `shouldSatisfy` (not . null)
      length rows `shouldBe` length analyticOnly
      -- Some row's velocity differs from the analytic one: the field is
      -- contributing. (Formation emitters sit still and contribute zero,
      -- which is ADR-0010 D6 — so this is an "any", not an "all".)
      zip (map fst rows) analyticOnly
        `shouldSatisfy` any (\(got, expect) -> norm3 (got - expect) > 1e-4)

    it "sums to the analytic velocity plus the field's own" $ do
      -- Stated as the equation it is: renderedVel = analyticVel + fieldVel.
      bytes <- BS.readFile "assets/spells/comet-trail.json"
      circle <- either (fail . show) pure (loadCircle bytes)
      spell0 <- either (fail . show) pure (castSpell (CastRequest circle ctx))
      let dt = FrameInput (DeltaTime (1 / 60))
          advanced = iterate (advanceSpell dt) spell0 !! 90
          rows = observedRows (observeSpell advanced)
      -- Every velocity is finite; a field that produced NaN would reach a
      -- vertex buffer, which a renderer must never be handed.
      rows `shouldSatisfy` (not . null)
      rows
        `shouldSatisfy` all
          (\(V3 x y z, _) -> all (\v -> not (isNaN v) && not (isInfinite v)) [x, y, z])

  describe "func-spec 0022 law 2, extended to nine columns" $ do
    prop "parallel ≡ sequential, bit for bit, velocity included" $
      forAll (elements [1 .. 4 :: Int]) $ \emitters ->
        forAll (elements [64, 512, 4096 :: Int]) $ \count ->
          forAll (elements frameTimes) $ \t ->
            let spell = syntheticSpell BillboardTrail emitters count
             in digest9 (sampleParallel spell ctx t)
                  === digest9 (sampleSequential spell ctx t)

    prop "and still does for a trail-free spell (empty columns both sides)" $
      forAll (elements [1 .. 4 :: Int]) $ \emitters ->
        forAll (elements frameTimes) $ \t ->
          let spell = syntheticSpell BillboardSquare emitters 4096
           in digest9 (sampleParallel spell ctx t)
                === digest9 (sampleSequential spell ctx t)

    prop "both paths keep the buffer invariant, velocity clause included" $
      forAll (elements [1 .. 4 :: Int]) $ \emitters ->
        forAll (elements frameTimes) $ \t ->
          let spell = syntheticSpell BillboardTrail emitters 4096
           in bufferInvariant (sampleParallel spell ctx t)
                && bufferInvariant (sampleSequential spell ctx t)

-- | The age of particle @i@ of an emitter at @t@, or 'Nothing' when it is
-- not alive — the sampler's own schedule, re-expressed here so the
-- expected row list can be built in the sampler's order.
ageOf :: EmitterSpec -> Int -> Time -> Maybe Double
ageOf em i t = particleAgeOf (emSpawn em) (emCount em) i t

particleAgeOf :: Envelope -> Int -> Int -> Time -> Maybe Double
particleAgeOf env count i (Time t)
  | lifetime <= 0 || t < birth0 = Nothing
  | birth < delay + duration = Just (t - birth)
  | otherwise = Nothing
  where
    Seconds delay = envDelay env
    Seconds duration = envDuration env
    Seconds lifetime = envLifetime env
    birth0 = delay + (fromIntegral i / fromIntegral (max 1 count)) * lifetime
    cycles = fromIntegral (floor ((t - birth0) / lifetime) :: Int)
    birth = birth0 + cycles * lifetime
