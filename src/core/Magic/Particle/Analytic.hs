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
module Magic.Particle.Analytic
  ( sample

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
import Magic.Rune (FaceShape (..), RadiationMode (..), Trajectory (..))
import Magic.Types
  ( CastContext (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V2 (..)
  , V3 (..)
  , basisFromNormal
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
trajectoryOffset :: Trajectory -> Float -> Float -> (Float, V2)
trajectoryOffset trajectory phase age = case trajectory of
  Forward speed -> (realToFrac speed * age, V2 0 0)
  Spiral speed radius freq ->
    (realToFrac speed * age, circleAt radius freq)
  Orbit radius freq -> (0, circleAt radius freq)
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

emitterParticles :: CastContext -> Time -> EmitterSpec -> [(V3, Float, Float, Word32)]
emitterParticles ctx t em =
  [ particle i age
  | i <- [0 .. emCount em - 1]
  , Just age <- [particleAge env (emCount em) i t]
  ]
  where
    env = emSpawn em
    Motion spawnPattern trajectory radiation drift = emMotion em
    Appearance ramp size _blend = emAppearance em
    Seconds lifetime = envLifetime env

    -- Caster frame: +Z = facing, X/Y = the facing's face-plane basis.
    facing = normalize (casterFacing ctx)
    (fu, fw) = basisFromNormal facing
    toWorld (V3 x y z) = vscale x fu + vscale y fw + vscale z facing

    anchorW = casterPos ctx + toWorld (anchorOffset (emAnchor em))
    faceNormal = normalize (toWorld (anchorNormal (emAnchor em)))
    -- Face-plane basis: x = face right, y = face up.
    (u, w) = basisFromNormal faceNormal

    faceToWorld (V3 x y z) = vscale x u + vscale y w + vscale z faceNormal

    particle i ageD =
      let age = realToFrac ageD :: Float

          V2 sx sy = case spawnPattern of
            SpawnAtAnchor _ -> V2 0 0
            SpawnOnShape shape -> sampleShape shape i 0
          spawnW = anchorW + vscale sx u + vscale sy w

          axis = case radiation of
            AlongNormal -> faceNormal
            RadialOutward ->
              let outward = vscale sx u + vscale sy w
               in if norm outward < 1e-6 then faceNormal else normalize outward
          (au, aw) = basisFromNormal axis

          phase = case trajectory of
            Forward _ -> 0
            _ -> 2 * pi * hashChan (seed ctx) i 2
          (travel, V2 lx ly) = trajectoryOffset trajectory phase age

          spreadDrift = case spawnPattern of
            SpawnAtAnchor spread ->
              let c0 = hashChan (seed ctx) i 0 - 0.5
                  c1 = hashChan (seed ctx) i 1 - 0.5
               in vscale (c0 * spread) u + vscale (c1 * spread) w
            SpawnOnShape _ -> V3 0 0 0
          nodeDriftW = faceToWorld drift

          position =
            spawnW
              + vscale travel axis
              + vscale lx au
              + vscale ly aw
              + vscale age (spreadDrift + nodeDriftW)

          lifeFrac = realToFrac (ageD / lifetime) :: Float
       in (position, size, lifeFrac, rampColor ramp lifeFrac)

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
