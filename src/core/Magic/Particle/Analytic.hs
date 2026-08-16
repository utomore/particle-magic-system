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
--
-- Func-spec 0022 adds two things, and neither of them moves a bit. The
-- formula curves are evaluated from compiled bytecode
-- ("Magic.Expr.Code") when 'Magic.Compile.compile' left some, and from the
-- AST otherwise — law 1 says those are the same answer. And @sample@ grows
-- a parallel path above 'parallelThreshold': the work is cut into 'Shard's
-- and evaluated with "Control.Parallel.Strategies", a /pure/ API, so the
-- module's signatures are untouched and ADR-0007 holds. Law 2 — the two
-- paths agree bit for bit on any number of cores — follows from how
-- 'shardsOf' cuts, not from luck; the argument is written out there.
module Magic.Particle.Analytic
  ( sample

    -- * Parallel sampling (func-spec 0022 S4, ADR-0017)
  , sampleSequential
  , sampleParallel
  , parallelThreshold
  , parallelChunk
  , Shard (..)
  , shardsOf
  , spellShards
  , sampleWindows

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
import Control.Parallel.Strategies (parMap, rdeepseq)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Compile
  ( Anchor (..)
  , Appearance (..)
  , ColorRamp (..)
  , CompiledSpell (..)
  , EmitterCode (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , SpawnPattern (..)
  )
import Magic.Expr (Expr, ExprEnv (..), ExprV3, evalFinite, evalFiniteV3)
import Magic.Expr.Code
  ( ExprCode
  , ExprCodeV3
  , evalCodeFinite
  , evalCodeFiniteV3
  )
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
  , cross
  , dot
  , hashChan
  , norm
  , normalize
  , vscale
  )
import Magic.Particle.Buffer (ParticleBuffer (..), WriteRow, buildBuffer, emptyBuffer)

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
  -- Func-spec 0021. All four stay what every built-in trajectory has
  -- always been: a closed-form function of the particle's age alone, with
  -- no state to carry and nothing to integrate — which is what keeps
  -- 'sample' a pure function of @t@ (architecture §4.6).
  Wave speed amplitude freq ->
    ( realToFrac speed * age
    , V2 (realToFrac amplitude * sin (phase + 2 * pi * realToFrac freq * age)) 0
    )
  -- The analytic parabola. A force field could produce this too, but only
  -- by paying for cross-frame state; as a trajectory it costs nothing.
  Ballistic speed gravity ->
    (realToFrac speed * age - 0.5 * realToFrac gravity * age * age, V2 0 0)
  Pulse meanSpeed freq ->
    -- ∫₀ᵃ mean·(1 − cos(φ + ωs)) ds in closed form. The integrand is
    -- never negative, so the displacement is monotone: a pulsing spell
    -- surges and coasts, it never reverses.
    let m = realToFrac meanSpeed :: Float
        w = 2 * pi * realToFrac freq
     in ( if w == 0
            then m * (1 - cos phase) * age
            else m * (age - (sin (phase + w * age) - sin phase) / w)
        , V2 0 0
        )
  Zigzag speed amplitude freq ->
    -- 'Wave' with a triangle wave: the corners are what make it read as a
    -- zigzag rather than as a weave. @freq@ counts direction reversals per
    -- second, and the triangle has two per period, hence the halving.
    ( realToFrac speed * age
    , V2 (realToFrac amplitude * triangleWave (phase / (2 * pi) + realToFrac freq * age / 2)) 0
    )
  where
    circleAt radius freq =
      let theta = phase + 2 * pi * realToFrac freq * age
          r = realToFrac radius
       in V2 (r * cos theta) (r * sin theta)

-- | Unit triangle wave of period 1: @0 ↦ 1@, @0.5 ↦ −1@, linear between,
-- range @[−1, 1]@.
triangleWave :: Float -> Float
triangleWave s = 4 * abs (u - 0.5) - 1
  where
    u = s - fromIntegral (floor s :: Int)

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
  -- Func-spec 0021's four. Polygon and Star share one construction: pick
  -- a wedge of the triangle fan, then a uniform point inside it. Every
  -- sample is therefore a convex combination of the origin and two
  -- vertices, which is exactly why @|p| <= shapeRadius@ holds by
  -- construction rather than by inspection (§2.2).
  Polygon sides radius ->
    let n = max 3 sides
        k = min (n - 1) (floor (u0 * fromIntegral n)) :: Int
        r = realToFrac radius :: Float
        vertexAt j = polar r (2 * pi * fromIntegral j / fromIntegral n)
     in inWedge (vertexAt k) (vertexAt (k + 1))
  Star points rOuter rInner ->
    -- 2n vertices alternating outer/inner; index parity picks which, and
    -- 2n being even keeps index n consistent with index 0.
    let n = 2 * max 2 points
        k = min (n - 1) (floor (u0 * fromIntegral n)) :: Int
        radiusAt j = if even j then realToFrac rOuter else realToFrac rInner :: Float
        vertexAt j = polar (radiusAt j) (2 * pi * fromIntegral j / fromIntegral n)
     in inWedge (vertexAt k) (vertexAt (k + 1))
  Cross len width ->
    -- Two crossed bars; the overlap at the center is sampled by both,
    -- which reads as a brighter hub and is what a cross wants anyway.
    let l = realToFrac len :: Float
        halfW = realToFrac width / 2 :: Float
        along = (u1 - 0.5) * 2 * l
        across = (u2 - 0.5) * 2 * halfW
     in if u0 < 0.5 then V2 along across else V2 across along
  Sector rInner rOuter sweep ->
    -- Area-uniform annular sector (same radius trick as 'Ring'), centered
    -- on the face's +x axis so the sweep is symmetric about it.
    let rIn = realToFrac rInner :: Float
        rOut = realToFrac rOuter
        theta = (u0 - 0.5) * realToFrac sweep
        r = sqrt (rIn * rIn + u1 * (rOut * rOut - rIn * rIn))
     in polar r theta
  where
    u0 = hashChan shapeSeed i c
    u1 = hashChan shapeSeed i (c + 1)
    u2 = hashChan shapeSeed i (c + 2)

    polar r theta = V2 (r * cos theta) (r * sin theta)

    -- Uniform point in the triangle (origin, a, b), by folding the unit
    -- square onto its lower half. The two barycentric weights are
    -- non-negative and sum to at most 1, so the result is inside the
    -- triangle — and inside the disc through a and b.
    inWedge (V2 ax ay) (V2 bx by) =
      let (s, u) = if u1 + u2 > 1 then (1 - u1, 1 - u2) else (u1, u2)
       in V2 (s * ax + u * bx) (s * ay + u * by)

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
--
-- Func-spec 0022 S4 adds a second path above 'parallelThreshold': the same
-- work, cut into 'shardsOf' pieces and evaluated with
-- "Control.Parallel.Strategies", then concatenated. __Law 2__ — the two
-- paths agree bit for bit, on any number of cores — is not a hope but a
-- consequence of how the cut is made; see 'shardsOf'.
sample :: CompiledSpell -> CastContext -> Time -> ParticleBuffer
sample spell ctx t@(Time seconds)
  | seconds < 0 = emptyBuffer
  | windowRows windows < parallelThreshold = fillSequential spell ctx t windows
  | otherwise = fillParallel spell ctx t windows
  where
    windows = sampleWindows spell t

-- | The single-threaded path, forced. Exported so __law 2__ can be stated
-- as an equation between the two paths at /any/ particle count, instead of
-- only above 'parallelThreshold' where 'sample' would pick for itself.
sampleSequential :: CompiledSpell -> CastContext -> Time -> ParticleBuffer
sampleSequential spell ctx t@(Time seconds)
  | seconds < 0 = emptyBuffer
  | otherwise = fillSequential spell ctx t (sampleWindows spell t)

-- | The sharded path, forced. See 'sampleSequential'.
sampleParallel :: CompiledSpell -> CastContext -> Time -> ParticleBuffer
sampleParallel spell ctx t@(Time seconds)
  | seconds < 0 = emptyBuffer
  | otherwise = fillParallel spell ctx t (sampleWindows spell t)

-- | Each emitter's live index windows at @t@ (func-spec 0010 S3), computed
-- once and shared by both paths — so "the two paths walk the same
-- particles" is one computation rather than two agreeing ones.
sampleWindows :: CompiledSpell -> Time -> V.Vector [(Int, Int)]
sampleWindows spell t =
  V.map (\em -> aliveRanges (emSpawn em) (emCount em) t) (spellEmitters spell)

windowRows :: V.Vector [(Int, Int)] -> Int
windowRows windows = sum [hi - lo | ws <- V.toList windows, (lo, hi) <- ws]

fillSequential
  :: CompiledSpell -> CastContext -> Time -> V.Vector [(Int, Int)] -> ParticleBuffer
fillSequential spell ctx t windows = buildBuffer (windowRows windows) fill
  where
    ems = spellEmitters spell

    fill :: WriteRow s -> ST s ()
    fill write = goEmitter 0 0
      where
        goEmitter !row !e
          | e >= V.length ems = pure ()
          | otherwise = do
              row' <- fillEmitter write ctx t (ems V.! e) (windows V.! e) row
              goEmitter row' (e + 1)

fillParallel
  :: CompiledSpell -> CastContext -> Time -> V.Vector [(Int, Int)] -> ParticleBuffer
fillParallel spell ctx t windows =
  concatBuffers (parMap rdeepseq shardBuffer (shardsFrom windows))
  where
    ems = spellEmitters spell
    shardBuffer (Shard e ranges rows) =
      buildBuffer rows $ \write -> () <$ fillEmitter write ctx t (ems V.! e) ranges 0

-- | Every shard of a set of windows, in output order: emitter by emitter,
-- and inside an emitter by ascending particle index.
shardsFrom :: V.Vector [(Int, Int)] -> [Shard]
shardsFrom windows = concat [shardsOf e (windows V.! e) | e <- [0 .. V.length windows - 1]]

-- | The shards 'sample' would spread over cores for this spell at @t@.
spellShards :: CompiledSpell -> Time -> [Shard]
spellShards spell t = shardsFrom (sampleWindows spell t)

-- | The minimum live-particle count that makes the parallel path worth its
-- own overhead: below it 'sample' runs the func-spec 0010 single-pass fill,
-- above it the sharded one.
--
-- This does /not/ affect law 2. Both paths produce the same bits; the
-- threshold only chooses which one runs, and a spell that crosses it from
-- one frame to the next does not flicker. Chosen by measurement, not by
-- taste (func-spec 0022 §2.5, ADR-0017): the smallest power of two at which
-- the sharded path is measurably faster on every core count measured, once
-- it has paid for its concatenation pass and its sparks.
--
-- 8192 sits under 'Magic.Compile.budgetCap' (16384, func-spec 0012), so a
-- spell at the cap does take this path and does get faster — measured at
-- 1.4–1.5× on 2 to 16 cores, rising to 3.9× at the 100k the cap does not
-- yet allow. Below 8192 the parallel path measured /slower/ on every core
-- count, which is what the threshold is for.
parallelThreshold :: Int
parallelThreshold = 8192

-- | Rows per shard. Small enough that a spell just past the threshold still
-- has several shards to spread over cores, large enough that the per-shard
-- buffer allocation and the final concatenation stay noise. Measured
-- against 512 and 4096 at 8 cores; 4096 was clearly worse (too few shards
-- to balance), 512 within noise.
parallelChunk :: Int
parallelChunk = 1024

-- | One unit of parallel work: a contiguous run of output rows, all of them
-- from a single emitter.
data Shard = Shard
  { shEmitter :: !Int
  -- ^ Index into 'Magic.Compile.spellEmitters'.
  , shRanges :: ![(Int, Int)]
  -- ^ Half-open particle-index ranges, a sub-list of that emitter's
  -- 'aliveRanges' with at most the first and last one split.
  , shRows :: !Int
  -- ^ Rows this shard writes; always @Σ (hi − lo)@ over 'shRanges'.
  }
  deriving (Eq, Show)

-- | Cut one emitter's alive windows into shards of at most 'parallelChunk'
-- rows. __This function is law 2's proof__, so it is worth saying exactly
-- why (func-spec 0022 §2.4):
--
-- 1. /The boundaries are pure data./ The emitter order is
--    'Magic.Compile.spellEmitters'; the windows are 'aliveRanges', decided
--    in @O(log n)@ from the envelope; the chunking is a fixed arithmetic
--    walk over them. Nothing here can see a thread, a core count or a
--    schedule.
-- 2. /The shards are independent./ A particle's position is a function of
--    @(CastContext, Time, EmitterSpec, index)@ and of nothing else — the
--    root property of an analytic model (architecture §1.3) — so no shard
--    reads another shard's output.
-- 3. /There is no cross-thread reduction./ Shard results are concatenated,
--    never summed, averaged or merge-sorted. Floating-point addition is not
--    associative, and this is the door that would have let that matter; the
--    door is not there.
-- 4. /The concatenation order is fixed./ It is the shard list's order,
--    which is emitter order then ascending index — not completion order.
--
-- Together: any number of threads, any schedule, identical bits.
shardsOf :: Int -> [(Int, Int)] -> [Shard]
shardsOf e = go
  where
    go [] = []
    go ranges =
      let (taken, rows, rest) = takeRows parallelChunk ranges
       in if rows <= 0 then [] else Shard e taken rows : go rest

    -- Peel at most @budget@ rows off the front of the window list, splitting
    -- a window if it straddles the boundary.
    takeRows _ [] = ([], 0, [])
    takeRows budget ((lo, hi) : rest)
      | budget <= 0 = ([], 0, (lo, hi) : rest)
      | hi - lo <= budget =
          let (taken, rows, leftover) = takeRows (budget - (hi - lo)) rest
           in ((lo, hi) : taken, (hi - lo) + rows, leftover)
      | otherwise = ([(lo, lo + budget)], budget, (lo + budget, hi) : rest)

-- | Lay the shard buffers end to end. The extra pass func-spec 0022 §2.4
-- knowingly pays for: the 0010 sampler wrote its six columns exactly once,
-- and this writes them twice. The trade is a bandwidth-bound copy against
-- arithmetic that is now spread over every core — and it is the reason the
-- threshold exists, since at small counts the copy is all there is.
concatBuffers :: [ParticleBuffer] -> ParticleBuffer
concatBuffers parts =
  ParticleBuffer
    { pbPosX = U.concat (map pbPosX parts)
    , pbPosY = U.concat (map pbPosY parts)
    , pbPosZ = U.concat (map pbPosZ parts)
    , pbSize = U.concat (map pbSize parts)
    , pbLife = U.concat (map pbLife parts)
    , pbColor = U.concat (map pbColor parts)
    , pbCount = sum (map pbCount parts)
    }

-- | Write one emitter's live particles, starting at buffer row @row0@;
-- returns the next free row.
fillEmitter
  :: WriteRow s -> CastContext -> Time -> EmitterSpec -> [(Int, Int)] -> Int -> ST s Int
fillEmitter write ctx t em ranges row0 = goRange row0 ranges
  where
    env = emSpawn em
    count = emCount em
    Appearance ramp size _blend mAmplify _shape = emAppearance em
    amplifyCode = emcAmplify (emCode em)
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
                  Just amp ->
                    size * max 0 (curveAt amplifyCode amp (frameEnvFor ctx t em i ageD))
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
    -- The compiled form of the four formulas above (func-spec 0022 S3).
    -- Every use goes through 'curveAt' / 'curveAtV3', so an emitter that
    -- never went through 'Magic.Compile.compile' still samples — by the
    -- reference evaluator, at the reference answer.
    code = emCode em
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
    rangeScale = maybe 1 (\e -> curveAt (emcRange code) e birthEnv) mRange
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
      -- Func-spec 0021's two, written out rather than folded together
      -- with the branch above: 'RadialOutward' is a pre-0021 code path
      -- and the bit-for-bit compatibility law (§1-1) is worth more than
      -- the three lines the three branches could have shared.
      RadialInward ->
        let inward = vscale (negate sx) u + vscale (negate sy) w
            ax = if norm inward < 1e-6 then faceNormal else normalize inward
            (bu, bw) = basisFromNormal ax
         in (ax, bu, bw)
      TangentialSwirl ->
        let tangent = cross faceNormal (vscale sx u + vscale sy w)
            ax = if norm tangent < 1e-6 then faceNormal else normalize tangent
            (bu, bw) = basisFromNormal ax
         in (ax, bu, bw)

    -- §4.5 (4) Formula replaces only the trajectory term; built-ins
    -- keep the 0002 phase-stagger path bit-for-bit.
    trajTerm = case trajectory of
      Formula v3 ->
        let V3 fx fy fz = curveAtV3 (emcTraject code) v3 ageEnv
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
        let kc = curveAt (emcConverge code) conv frameEnv
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

-- | Evaluate a modulation curve (func-spec 0022 S3): the compiled bytecode
-- when 'Magic.Compile.compile' left one, the AST otherwise.
--
-- The fallback is not a hedge against the bytecode being wrong — law 1 says
-- the two answers are the same bits — it is what keeps a hand-built
-- 'EmitterSpec' (a benchmark fixture, a test) samplable without every such
-- caller having to compile its own formulas first. The only difference
-- between the branches is speed.
curveAt :: Maybe ExprCode -> Expr -> ExprEnv -> Float
curveAt (Just c) _ env = evalCodeFinite c env
curveAt Nothing e env = evalFinite e env
{-# INLINE curveAt #-}

curveAtV3 :: Maybe ExprCodeV3 -> ExprV3 -> ExprEnv -> V3
curveAtV3 (Just c) _ env = evalCodeFiniteV3 c env
curveAtV3 Nothing e env = evalFiniteV3 e env
{-# INLINE curveAtV3 #-}

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
