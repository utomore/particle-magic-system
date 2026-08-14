-- | Analytic particle layer (spec 0002 §5.2, architecture §4.6).
--
-- @sample@ keeps its frozen 0001 signature — a stateless pure function of
-- time — but is now driven by the compiled 'EmitterSpec's instead of a
-- hard-coded fountain. For every emitter, every particle index is
-- scheduled by the spawn 'Envelope', born on the 'SpawnPattern', moved by
-- its 'Trajectory' along the 'RadiationMode' axis plus constant drifts,
-- and colored by the 'ColorRamp' over its life fraction.
--
-- All randomness is 'hashChan' (channels 0/1: anchor-spawn lateral drift,
-- exactly the 0001 fountain channels; channel 2: trajectory phase
-- stagger), so the same @(spell, ctx, t)@ always yields a bit-for-bit
-- identical buffer.
--
-- Spec 0004 wires the Expr runes in at three insertion points (§4.5) with
-- the layered time frame of §4.4: the range curve scales the spawn offset
-- (t = birth time, frozen at birth), the trajectory term may come from a
-- formula (t = particle age), the converge curve multiplies the lateral
-- component of the total displacement and the amplify curve multiplies
-- the size (both t = seconds since cast). All evaluation goes through
-- 'evalFinite' / 'evalFiniteV3' — any player formula yields finite values.
--
-- Spec 0007 refactors this module additively: the per-particle position
-- formula ('particlePosition') and the alive-slot enumeration
-- ('aliveSlots') are lifted out of @sample@ and exported, so the
-- force-field layer can compute base positions and align its
-- displacements to buffer rows without ever copying either. @sample@
-- itself is bit-for-bit unchanged (spec 0007 §4.4 proof obligation).
module Magic.Particle.Analytic
  ( sample

    -- * Single source of truth for the force-field layer (spec 0007 §4.4)
  , particlePosition
  , aliveSlots

    -- * Shape sampling (spec 0002 S3; extension point of architecture §10)
  , sampleShape

    -- * Envelope scheduling and trajectory evaluation (spec 0002 S4)
  , firstBirth
  , particleAge
  , trajectoryOffset
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.Vector as V
import Data.Word (Word32)
import Magic.Compile
  ( Anchor (..)
  , Appearance (..)
  , ColorRamp (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , SpawnPattern (..)
  )
import Magic.Expr (ExprEnv (..), evalFinite, evalFiniteV3)
import Magic.Rune (FaceShape (..), RadiationMode (..), Trajectory (..))
import Magic.Types
  ( CastContext (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V2 (..)
  , V3 (..)
  , basisFromNormal
  , dot
  , hashChan
  , norm
  , normalize
  , vscale
  )
import Magic.Particle.Buffer (ParticleBuffer, emptyBuffer, fromParticles)

-- Envelope scheduling ---------------------------------------------------------

-- | When particle @i@ of @count@ is first born (seconds after the cast):
-- @envDelay + (i/count)·envLifetime@ — the generalization of the 0001
-- fountain's spawn stagger.
firstBirth :: Envelope -> Int -> Int -> Double
firstBirth env count i =
  let Seconds delay = envDelay env
      Seconds lifetime = envLifetime env
   in delay + (fromIntegral i / fromIntegral (max 1 count)) * lifetime

-- | Age of particle @i@ of @count@ at time @t@, or 'Nothing' when the
-- particle is not alive (not yet born, or its last respawn fell outside
-- the spawn window @envDelay + envDuration@). Respawns are cyclic every
-- 'envLifetime'; the last batch dies out by
-- @envDelay + envDuration + envLifetime@.
particleAge :: Envelope -> Int -> Int -> Time -> Maybe Double
particleAge env count i (Time t)
  | lifetime <= 0 || t < birth0 = Nothing
  | birth < delay + duration = Just (t - birth)
  | otherwise = Nothing
  where
    Seconds delay = envDelay env
    Seconds duration = envDuration env
    Seconds lifetime = envLifetime env
    birth0 = firstBirth env count i
    cycles = fromIntegral (floor ((t - birth0) / lifetime) :: Int)
    birth = birth0 + cycles * lifetime

-- Trajectory evaluation -------------------------------------------------------

-- | Evaluate a trajectory at a particle age: @(travel along the axis,
-- lateral offset in the axis' 'basisFromNormal' plane)@. @phase@ (radians)
-- staggers the angular start of 'Spiral'/'Orbit'; 'Forward' ignores it.
-- 'Formula' needs the particle's 'ExprEnv' and is evaluated by the sampler
-- itself (spec 0004 §4.5); this env-free helper reports it as zero offset.
trajectoryOffset :: Trajectory -> Float -> Float -> (Float, V2)
trajectoryOffset trajectory phase age = case trajectory of
  Forward speed -> (realToFrac speed * age, V2 0 0)
  Spiral speed radius freq ->
    (realToFrac speed * age, circleAt radius freq)
  Orbit radius freq -> (0, circleAt radius freq)
  Formula _ -> (0, V2 0 0)
  where
    circleAt radius freq =
      let theta = phase + 2 * pi * realToFrac freq * age
          r = realToFrac radius
       in V2 (r * cos theta) (r * sin theta)

-- Shape sampling --------------------------------------------------------------

-- | Fixed internal seed for shape sampling: spawn positions are a property
-- of the drawn face, not of the cast (per-cast variation rides on the
-- drift/phase channels of the cast seed instead).
shapeSeed :: Seed
shapeSeed = Seed 0x53686170

-- | @sampleShape shape i c@: a deterministic point on the face for
-- particle index @i@, drawing uniformity from hash channels
-- @c@, @c+1@, @c+2@ of the internal shape seed.
sampleShape :: FaceShape -> Int -> Int -> V2
sampleShape shape i c = case shape of
  Ring rInner rOuter ->
    -- Area-uniform annulus: radius = sqrt(lerp(rIn², rOut², u1)).
    let theta = 2 * pi * u0
        rIn = realToFrac rInner :: Float
        rOut = realToFrac rOuter
        r = sqrt (rIn * rIn + u1 * (rOut * rOut - rIn * rIn))
     in V2 (r * cos theta) (r * sin theta)
  Diamond size ->
    -- Uniform on |x| + |y| <= size: a rotated unit square.
    let s = realToFrac size
     in V2 ((u0 - u1) * s) ((u0 + u1 - 1) * s)
  Rect (V2 w h) ->
    V2 ((u0 - 0.5) * w) ((u1 - 0.5) * h)
  HollowSquare size ->
    -- Nine-grid band: pick one of the 8 non-center cells, then a uniform
    -- point inside it — the center cavity gets no points.
    let cell = realToFrac size / 3 :: Float
        idx = min 7 (floor (u0 * 8)) :: Int
        (gx, gy) = bandCells !! idx
        x = (fromIntegral gx - 1) * cell + (u1 - 0.5) * cell
        y = (fromIntegral gy - 1) * cell + (u2 - 0.5) * cell
     in V2 x y
  where
    u0 = hashChan shapeSeed i c
    u1 = hashChan shapeSeed i (c + 1)
    u2 = hashChan shapeSeed i (c + 2)

-- | The 3×3 grid cells minus the center.
bandCells :: [(Int, Int)]
bandCells = [(gx, gy) | gx <- [0 .. 2 :: Int], gy <- [0 .. 2 :: Int], (gx, gy) /= (1, 1)]

-- The sampler -----------------------------------------------------------------

sample :: CompiledSpell -> CastContext -> Time -> ParticleBuffer
sample spell ctx t@(Time seconds)
  | seconds < 0 = emptyBuffer
  | otherwise =
      fromParticles (concatMap (emitterParticles ctx t) (V.toList (spellEmitters spell)))

-- | The stable slots alive at @t@, in exactly the row order 'sample'
-- lays down (emitter by emitter as stored in 'spellEmitters', particle
-- index ascending).
--
-- Spec 0007 §4.4: the force-field layer keys its state by the stable
-- @(emitterIndex, particleIndex)@ pair (ADR-0010 D2) and has to line its
-- per-slot displacements up with buffer rows. That enumeration therefore
-- lives here, next to the sampler that defines it — a second copy is the
-- drift bug ADR-0010 D2 forbids.
aliveSlots :: CompiledSpell -> Time -> [(Int, Int)]
aliveSlots spell t@(Time seconds)
  | seconds < 0 = []
  | otherwise =
      [ (e, i)
      | (e, em) <- zip [0 ..] (V.toList (spellEmitters spell))
      , i <- [0 .. emCount em - 1]
      , Just _ <- [particleAge (emSpawn em) (emCount em) i t]
      ]

emitterParticles :: CastContext -> Time -> EmitterSpec -> [(V3, Float, Float, Word32)]
emitterParticles ctx t em =
  [ particle i age
  | i <- [0 .. emCount em - 1]
  , Just age <- [particleAge env (emCount em) i t]
  ]
  where
    env = emSpawn em
    Appearance ramp size _blend mAmplify = emAppearance em
    Seconds lifetime = envLifetime env

    particle i ageD =
      let lifeFrac = realToFrac (ageD / lifetime) :: Float
          -- §4.5 (3) Amplify: negative curve values clamp to size 0.
          finalSize = case mAmplify of
            Nothing -> size
            Just amp -> size * max 0 (evalFinite amp (frameEnvFor ctx t em i ageD))
       in (particlePosition ctx t em i ageD, finalSize, lifeFrac, rampColor ramp lifeFrac)

-- | Position of particle @i@ of an emitter at age @ageD@ — the analytic
-- layer's position formula, extracted verbatim from 'sample' (spec 0007
-- §4.4, additive refactor: @sample@ is bit-for-bit unchanged and now
-- calls this).
--
-- The force-field layer feeds this as the base position of its
-- integration (ADR-0010 D1: @renderedPos = analyticPos + displacement@),
-- so there is exactly one copy of the formula.
particlePosition :: CastContext -> Time -> EmitterSpec -> Int -> Double -> V3
particlePosition ctx t em i ageD = position
  where
    Motion spawnPattern trajectory radiation drift mRange mConverge = emMotion em
    age = realToFrac ageD :: Float

    -- Caster frame: +Z = facing, X/Y = the facing's face-plane basis.
    facing = normalize (casterFacing ctx)
    (fu, fw) = basisFromNormal facing
    toWorld (V3 x y z) = vscale x fu + vscale y fw + vscale z facing

    anchorW = casterPos ctx + toWorld (anchorOffset (emAnchor em))
    faceNormal = normalize (toWorld (anchorNormal (emAnchor em)))
    -- Face-plane basis: x = face right, y = face up.
    (u, w) = basisFromNormal faceNormal

    faceToWorld (V3 x y z) = vscale x u + vscale y w + vscale z faceNormal

    -- Layered time frame (spec 0004 §4.4).
    birthEnv = birthEnvFor ctx t i ageD
    frameEnv = frameEnvFor ctx t em i ageD
    -- Behavior-layer env for the formula trajectory: t = age.
    ageEnv = frameEnv {envT = age}

    -- §4.5 (1) Range: scale the shape sample point. Not clamped
    -- (negative = mirrored); a no-op for SpawnAtAnchor (offset 0).
    rangeScale = maybe 1 (`evalFinite` birthEnv) mRange
    V2 sx sy = case spawnPattern of
      SpawnAtAnchor _ -> V2 0 0
      SpawnOnShape shape -> vscale2 rangeScale (sampleShape shape i 0)
    spawnW = anchorW + vscale sx u + vscale sy w

    axis = case radiation of
      AlongNormal -> faceNormal
      RadialOutward ->
        let outward = vscale sx u + vscale sy w
         in if norm outward < 1e-6 then faceNormal else normalize outward
    (au, aw) = basisFromNormal axis

    -- §4.5 (4) Formula replaces only the trajectory term; built-ins
    -- keep the 0002 phase-stagger path bit-for-bit.
    trajTerm = case trajectory of
      Formula v3 ->
        let V3 fx fy fz = evalFiniteV3 v3 ageEnv
         in vscale fx au + vscale fy aw + vscale fz axis
      _ ->
        let phase = case trajectory of
              Forward _ -> 0
              _ -> 2 * pi * hashChan (seed ctx) i 2
            (travel, V2 lx ly) = trajectoryOffset trajectory phase age
         in vscale travel axis + vscale lx au + vscale ly aw

    spreadDrift = case spawnPattern of
      SpawnAtAnchor spread ->
        let c0 = hashChan (seed ctx) i 0 - 0.5
            c1 = hashChan (seed ctx) i 1 - 0.5
         in vscale (c0 * spread) u + vscale (c1 * spread) w
      SpawnOnShape _ -> V3 0 0 0
    nodeDriftW = faceToWorld drift

    rawPosition = spawnW + trajTerm + vscale age (spreadDrift + nodeDriftW)

    -- §4.5 (2) Converge: pos' = anchor + axial + k_c·trans, written
    -- as pos − (1−k_c)·trans so k_c = 1 reproduces the unmodulated
    -- position exactly.
    position = case mConverge of
      Nothing -> rawPosition
      Just conv ->
        let kc = evalFinite conv frameEnv
            r = rawPosition - anchorW
            axial = vscale (dot r axis) axis
            trans = r - axial
         in rawPosition - vscale (1 - kc) trans

-- | Birth env (spec 0004 §4.4): t = this generation's spawn time,
-- life = 0 (the value at the instant of birth) — recomputed every frame
-- but constant per birth.
birthEnvFor :: CastContext -> Time -> Int -> Double -> ExprEnv
birthEnvFor ctx (Time seconds) i ageD =
  ExprEnv
    { envT = realToFrac (seconds - ageD)
    , envLife = 0
    , envPIndex = i
    , envSeed = seed ctx
    }

-- | Modulation-layer env (spec 0004 §4.4): t = seconds since cast,
-- life = this particle's life fraction.
frameEnvFor :: CastContext -> Time -> EmitterSpec -> Int -> Double -> ExprEnv
frameEnvFor ctx (Time seconds) em i ageD =
  let Seconds lifetime = envLifetime (emSpawn em)
   in ExprEnv
        { envT = realToFrac seconds
        , envLife = realToFrac (ageD / lifetime)
        , envPIndex = i
        , envSeed = seed ctx
        }

vscale2 :: Float -> V2 -> V2
vscale2 s (V2 x y) = V2 (s * x) (s * y)

-- | Linear interpolation of a packed 0xRRGGBBAA ramp over life ∈ [0, 1].
rampColor :: ColorRamp -> Float -> Word32
rampColor (ColorRamp start end) life
  | start == end = start
  | otherwise = foldr (.|.) 0 [lerpByte sh `shiftL` sh | sh <- [24, 16, 8, 0]]
  where
    l = max 0 (min 1 life)
    byteAt v sh = fromIntegral ((v `shiftR` sh) .&. 0xFF) :: Float
    lerpByte sh =
      let a = byteAt start sh
          b = byteAt end sh
       in round (a + (b - a) * l) :: Word32
