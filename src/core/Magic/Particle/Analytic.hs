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
  , aliveSlotIndices

    -- * Emitter time-window culling (func-spec 0010 S3)
  , aliveRanges
  , emitterOffsets

    -- * Shape sampling (spec 0002 S3; extension point of architecture §10)
  , sampleShape

    -- * Envelope scheduling and trajectory evaluation (spec 0002 S4)
  , firstBirth
  , particleAge
  , trajectoryOffset
  ) where

import Control.Monad.ST (ST)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
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
import Magic.Sigil (SigilStroke (..), sampleStroke, spinAngle)
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
import Magic.Particle.Buffer (ParticleBuffer, WriteRow, buildBuffer, emptyBuffer)

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

-- Time-window culling (func-spec 0010 §2, S3) ---------------------------------

-- | The index ranges of one emitter that hold a live particle at @t@ —
-- ascending, disjoint, half-open @[lo, hi)@.
--
-- 'firstBirth' is non-decreasing in the index and the respawn cycle count
-- @floor ((t − birth₀) \/ lifetime)@ is therefore non-increasing, so
-- aliveness is a /prefix/ predicate inside each block of equal cycle
-- count — and the index span of one emitter covers less than one lifetime,
-- so there are at most two such blocks. Each boundary is found by binary
-- search over the very same 'firstBirth' \/ 'particleAge' arithmetic the
-- sampler uses, never by a second closed-form solution of the schedule:
-- that is what makes the culled walk bit-for-bit identical to the full
-- scan (guarded as a property by @test\/CullSpec.hs@) instead of merely
-- close to it.
--
-- A dead window returns @[]@, so an emitter outside its spawn window
-- costs @O(log count)@ instead of @O(count)@.
aliveRanges :: Envelope -> Int -> Time -> [(Int, Int)]
aliveRanges env count t@(Time seconds)
  | count <= 0 = []
  | lifetime <= 0 = []
  | otherwise = blocks 0 born
  where
    Seconds lifetime = envLifetime env
    n = count

    -- Condition 1 of 'particleAge': the particle has been born at all.
    born = countPrefix n (\i -> firstBirth env n i <= seconds)

    -- Same expression as 'particleAge' — not a re-derivation of it.
    cyclesAt i = floor ((seconds - firstBirth env n i) / lifetime) :: Int

    isAlive i = case particleAge env n i t of
      Just _ -> True
      Nothing -> False

    -- Split [lo, hi) into blocks of equal cycle count; inside one block
    -- aliveness is a prefix.
    blocks lo hi
      | lo >= hi = []
      | otherwise =
          let c = cyclesAt lo
              k = lo + countPrefix (hi - lo) (\j -> cyclesAt (lo + j) >= c)
              p = lo + countPrefix (k - lo) (\j -> isAlive (lo + j))
              rest = blocks k hi
           in if p > lo then (lo, p) : rest else rest

-- | Number of leading indices of @[0, m)@ satisfying a prefix predicate
-- (true up to some point, false after it). @O(log m)@.
countPrefix :: Int -> (Int -> Bool) -> Int
countPrefix m p = go 0 m
  where
    go lo hi
      | lo >= hi = lo
      | p mid = go (mid + 1) hi
      | otherwise = go lo mid
      where
        mid = lo + (hi - lo) `div` 2

-- | Prefix sums of the emitters' particle counts: @emitterOffsets spell@
-- has one more element than there are emitters, the last being the total
-- slot count. This is the flattening the force-field layer's SoA state
-- shares with the sampler (ADR-0010 D2's stable slot identity, laid out
-- linearly).
emitterOffsets :: CompiledSpell -> U.Vector Int
emitterOffsets spell =
  U.scanl' (+) 0 (U.generate (V.length ems) (\e -> emCount (ems V.! e)))
  where
    ems = spellEmitters spell

-- The sampler -----------------------------------------------------------------

-- | Sample every emitter at @t@ into one SoA buffer.
--
-- Func-spec 0010 S2: count first (the culling windows give the exact row
-- count without touching a particle), then fill six exact-size columns in
-- place. The emitter order and, inside an emitter, the ascending index
-- order are exactly what the pre-0010 @concatMap@ produced, and every
-- floating-point operation per particle is the same one in the same
-- order — the buffer is bit-for-bit what it always was.
sample :: CompiledSpell -> CastContext -> Time -> ParticleBuffer
sample spell ctx t@(Time seconds)
  | seconds < 0 = emptyBuffer
  | otherwise = buildBuffer total fill
  where
    ems = spellEmitters spell
    windows = V.map (\em -> aliveRanges (emSpawn em) (emCount em) t) ems
    total = sum [hi - lo | ws <- V.toList windows, (lo, hi) <- ws]

    fill :: WriteRow s -> ST s ()
    fill write = goEmitter 0 0
      where
        goEmitter !row !e
          | e >= V.length ems = pure ()
          | otherwise = do
              row' <- fillEmitter write ctx t (ems V.! e) (windows V.! e) row
              goEmitter row' (e + 1)

-- | Write one emitter's live particles, starting at buffer row @row0@;
-- returns the next free row.
fillEmitter
  :: WriteRow s -> CastContext -> Time -> EmitterSpec -> [(Int, Int)] -> Int -> ST s Int
fillEmitter write ctx t em ranges row0 = goRange row0 ranges
  where
    env = emSpawn em
    count = emCount em
    Appearance ramp size _blend mAmplify _shape = emAppearance em
    Seconds lifetime = envLifetime env
    -- Hoisted out of the per-particle loop (func-spec 0010 S2): the
    -- caster and face frames depend on the emitter, not on the particle,
    -- and cost four 'normalize's and two 'basisFromNormal's each.
    frame = emitterFrame ctx em

    goRange !row [] = pure row
    goRange !row ((lo, hi) : rest) = do
      row' <- goIndex row lo hi
      goRange row' rest

    goIndex !row !i !hi
      | i >= hi = pure row
      | otherwise = case particleAge env count i t of
          -- Unreachable: 'aliveRanges' enumerates exactly the live
          -- indices. Skipping (rather than writing) keeps the walk total
          -- if that ever stopped being true.
          Nothing -> goIndex row (i + 1) hi
          Just ageD -> do
            let lifeFrac = realToFrac (ageD / lifetime) :: Float
                -- §4.5 (3) Amplify: negative curve values clamp to size 0.
                finalSize = case mAmplify of
                  Nothing -> size
                  Just amp -> size * max 0 (evalFinite amp (frameEnvFor ctx t em i ageD))
            write
              row
              (positionIn frame ctx t em i ageD)
              finalSize
              lifeFrac
              (rampColor ramp lifeFrac)
            goIndex (row + 1) (i + 1) hi

-- | The stable slots alive at @t@, in exactly the row order 'sample'
-- lays down (emitter by emitter as stored in 'spellEmitters', particle
-- index ascending).
--
-- Spec 0007 §4.4: the force-field layer keys its state by the stable
-- @(emitterIndex, particleIndex)@ pair (ADR-0010 D2) and has to line its
-- per-slot displacements up with buffer rows. That enumeration therefore
-- lives here, next to the sampler that defines it — a second copy is the
-- drift bug ADR-0010 D2 forbids. Since func-spec 0010 both this and
-- 'sample' read the same 'aliveRanges' windows, so "the same enumeration"
-- is now literally one computation instead of two agreeing ones.
aliveSlots :: CompiledSpell -> Time -> [(Int, Int)]
aliveSlots spell t@(Time seconds)
  | seconds < 0 = []
  | otherwise =
      [ (e, i)
      | (e, em) <- zip [0 ..] (V.toList (spellEmitters spell))
      , (lo, hi) <- aliveRanges (emSpawn em) (emCount em) t
      , i <- [lo .. hi - 1]
      ]

-- | 'aliveSlots' flattened through 'emitterOffsets': the same enumeration,
-- same order, as one unboxed column of slot ids. The hot path's form —
-- the force-field overlay indexes its SoA state with it directly.
aliveSlotIndices :: CompiledSpell -> Time -> U.Vector Int
aliveSlotIndices spell t@(Time seconds)
  | seconds < 0 = U.empty
  | otherwise = U.concat (map ofEmitter [0 .. V.length ems - 1])
  where
    ems = spellEmitters spell
    offsets = emitterOffsets spell
    ofEmitter e =
      let em = ems V.! e
          base = offsets U.! e
       in U.concat
            [ U.enumFromN (base + lo) (hi - lo)
            | (lo, hi) <- aliveRanges (emSpawn em) (emCount em) t
            ]

-- | Position of particle @i@ of an emitter at age @ageD@ — the analytic
-- layer's position formula, extracted verbatim from 'sample' (spec 0007
-- §4.4, additive refactor: @sample@ is bit-for-bit unchanged and now
-- calls this).
--
-- The force-field layer feeds this as the base position of its
-- integration (ADR-0010 D1: @renderedPos = analyticPos + displacement@),
-- so there is exactly one copy of the formula.
particlePosition :: CastContext -> Time -> EmitterSpec -> Int -> Double -> V3
particlePosition ctx t em = positionIn (emitterFrame ctx em) ctx t em

-- | The parts of the position formula that depend on the emitter and the
-- cast context but not on the particle: the caster frame, the anchor in
-- world space, the face normal and its plane basis, and the node drift
-- rotated into world space (func-spec 0010 S2).
--
-- Six 'normalize'\/'basisFromNormal' calls used to run per particle per
-- frame; they run once per emitter per frame now. The expressions are
-- moved verbatim, so every particle still sees the same bits.
data EmitterFrame = EmitterFrame
  { efAnchorW :: !V3
  , efNormal :: !V3
  , efU :: !V3
  -- ^ Face right.
  , efW :: !V3
  -- ^ Face up.
  , efDriftW :: !V3
  }

emitterFrame :: CastContext -> EmitterSpec -> EmitterFrame
emitterFrame ctx em =
  EmitterFrame
    { efAnchorW = anchorW
    , efNormal = faceNormal
    , efU = u
    , efW = w
    , efDriftW = faceToWorld (motDrift (emMotion em))
    }
  where
    -- Caster frame: +Z = facing, X/Y = the facing's face-plane basis.
    facing = normalize (casterFacing ctx)
    (fu, fw) = basisFromNormal facing
    toWorld (V3 x y z) = vscale x fu + vscale y fw + vscale z facing

    anchorW = casterPos ctx + toWorld (anchorOffset (emAnchor em))
    faceNormal = normalize (toWorld (anchorNormal (emAnchor em)))
    -- Face-plane basis: x = face right, y = face up.
    (u, w) = basisFromNormal faceNormal

    faceToWorld (V3 x y z) = vscale x u + vscale y w + vscale z faceNormal

-- | 'particlePosition' with the per-emitter frame supplied.
positionIn :: EmitterFrame -> CastContext -> Time -> EmitterSpec -> Int -> Double -> V3
positionIn frame ctx t em i ageD = position
  where
    Motion spawnPattern trajectory radiation _drift mRange mConverge = emMotion em
    age = realToFrac ageD :: Float
    -- The modulation layer's clock: seconds since the cast started.
    Time tCast = t

    anchorW = efAnchorW frame
    faceNormal = efNormal frame
    u = efU frame
    w = efW frame
    nodeDriftW = efDriftW frame

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
      -- Func-spec 0016: the index is a position along the curve, not a
      -- hash channel — which is the whole difference between a sigil
      -- being drawn and a sigil fading in.
      --
      -- Func-spec 0020 turns the sampled point about the face origin. The
      -- angle is a function of the /cast/ clock, never of the particle's
      -- age: a rigid rotation is "every point at the same angle at the
      -- same instant", and the sigil respawns cyclically, so ages differ
      -- across the figure at every moment. Driving it by age would smear
      -- the sigil into a spiral instead of turning it (§2.1). That makes
      -- this a modulation-layer term, and the modulation layer's clock is
      -- seconds since the cast (spec 0004 §4.7).
      SpawnOnStroke stroke ->
        vscale2 rangeScale (rotate2 (spinAngle (skSpin stroke) tCast) (sampleStroke stroke i))
    spawnW = anchorW + vscale sx u + vscale sy w

    -- 'AlongNormal' takes the face normal, whose plane basis is the
    -- frame's own @(u, w)@ — @basisFromNormal@ of the same vector, so the
    -- reuse is an equality, not an approximation, and it saves the two
    -- cross products per particle.
    (axis, au, aw) = case radiation of
      AlongNormal -> (faceNormal, u, w)
      RadialOutward ->
        let outward = vscale sx u + vscale sy w
            ax = if norm outward < 1e-6 then faceNormal else normalize outward
            (bu, bw) = basisFromNormal ax
         in (ax, bu, bw)

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
      SpawnOnStroke _ -> V3 0 0 0

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

-- | Rotate a face-plane point about the face origin (func-spec 0020).
--
-- About the /origin/ specifically: that is what makes it an isometry of
-- the face plane, so @|rotate2 th p| == |p|@ and every bound the compiler
-- derived from 'Magic.Sigil.strokeRadius' survives untouched. Spinning a
-- stroke about its own center instead would have broken that and dragged
-- 'Magic.Compile.emitterBounds' along with it (§2.2).
rotate2 :: Float -> V2 -> V2
rotate2 th (V2 x y) = V2 (x * c - y * s) (x * s + y * c)
  where
    c = cos th
    s = sin th
{-# INLINE rotate2 #-}

-- | Linear interpolation of a packed 0xRRGGBBAA ramp over life ∈ [0, 1].
--
-- The four shifts are written out rather than folded over a list: this
-- runs once per particle per frame, and the list the fold walked was
-- allocated there too. Same four terms, same @(.|.)@, same result.
rampColor :: ColorRamp -> Float -> Word32
rampColor (ColorRamp start end) life
  | start == end = start
  | otherwise =
      (lerpByte 24 `shiftL` 24)
        .|. (lerpByte 16 `shiftL` 16)
        .|. (lerpByte 8 `shiftL` 8)
        .|. lerpByte 0
  where
    l = max 0 (min 1 life)
    byteAt v sh = fromIntegral ((v `shiftR` sh) .&. 0xFF) :: Float
    lerpByte sh =
      let a = byteAt start sh
          b = byteAt end sh
       in round (a + (b - a) * l) :: Word32
