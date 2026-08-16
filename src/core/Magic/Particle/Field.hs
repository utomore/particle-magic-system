-- | The force-field layer (func-spec 0007, ADR-0010) — the system's first
-- cross-frame state.
--
-- The analytic layer stays what it always was: a stateless pure function
-- of @t@. This module carries an /additive displacement/ on top of it
-- (ADR-0010 D1):
--
-- > renderedPos = analyticPos(t) + displacement
--
-- Displacement is integrated per stable slot with semi-implicit (symplectic)
-- Euler at the fixed simulation step:
--
-- > accel = Σ fieldAccel(fields, analyticPos + disp)
-- > vel'  = vel  + accel·dt
-- > disp' = disp + vel'·dt
--
-- Known limitation, recorded rather than fixed (ADR-0010 D1): with large
-- steps and strong vortex/attractor parameters the energy drifts. This is
-- a game-feel integrator, not orbital mechanics.
--
-- Identity model (ADR-0010 D2): state is keyed by the stable
-- @(emitterIndex, particleIndex)@ slot — a compile-time constant space —
-- never by a 'Magic.Particle.Buffer.ParticleBuffer' row, whose ordering
-- shifts every frame as particles die and respawn.
--
-- Rebirth (ADR-0010 D3): particles respawn cyclically on their 'Envelope'
-- schedule, so a slot's age sequence is monotone /within/ a generation and
-- jumps backwards at a respawn. A slot whose age went backwards — or that
-- had no state at all — is a new particle: it starts from rest, coincident
-- with its analytic position ('quiescent'), and only integrates from the
-- following step. Teleporting at a rebirth is therefore structurally
-- impossible, and no generation counter has to be bolted onto the frozen
-- 'Envelope' scheduling.
--
-- The module depends on 'Magic.Types' and the 'ForceField' vocabulary
-- only: it knows nothing of @CompiledSpell@, @Envelope@ or the sampler
-- (architecture §2 dependency direction). Ages and base positions are
-- computed by the caller ('Magic.Interface') with the frozen analytic
-- functions and handed in.
-- Func-spec 0010 S4 turns the state's /representation/ into flat unboxed
-- columns (spec 0007 §4.7 left it explicitly unfrozen for exactly this).
-- The laws did not move: 'stepSlot' still spells out the per-slot
-- transition, it is still the definition the columnar 'stepColumns'
-- implements, and @test\/FieldSoASpec.hs@ holds the two against each
-- other bit for bit. Absence — the old @Nothing@ — is a negative age
-- sentinel in the age column; ages are @>= 0@ by construction, so the two
-- can never be confused, and unlike a NaN sentinel it leaves 'Eq' and
-- 'Show' meaning what they say.
module Magic.Particle.Field
  ( -- * Field evaluation
    fieldAccel

    -- * Per-slot integration state (the reference semantics)
  , SlotState (..)
  , quiescent
  , stepSlot

    -- * Whole-spell state (SoA, func-spec 0010 S4)
  , FieldState (..)
  , emptyFieldState
  , slotAt
  , FieldInputs (..)
  , fieldInputsOf
  , stepColumns
  , displacementColumns
  , velocityColumns

    -- * Boxed entry points (compatibility; not the hot path)
  , step
  , displacementsInOrder
  ) where

import Control.Monad.ST (runST)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MU
import Magic.Rune (ForceField (..))
import Magic.Types
  ( DeltaTime (..)
  , V3 (..)
  , cross
  , dot
  , norm
  , normalize
  , vscale
  )

-- Field evaluation ------------------------------------------------------------

-- | Total acceleration the fields exert at a world-space point. Fields
-- superpose: the sum is taken in list order, and the empty list is the
-- zero vector (the compatibility law's degenerate case, ADR-0010 D9).
fieldAccel :: [ForceField] -> V3 -> V3
fieldAccel fields pos = foldl' (\acc f -> acc + accelOf f pos) (V3 0 0 0) fields

-- | A single field's contribution (spec 0007 §4.1).
accelOf :: ForceField -> V3 -> V3
accelOf field pos = case field of
  Gravity accel -> accel
  PointAttractor center strength softening ->
    let toCenter = center - pos
        dist2 = dot toCenter toCenter
        soft2 = softening * softening
     in vscale (strength / (dist2 + soft2)) (normalize toCenter)
  Vortex center axis0 strength falloff ->
    let axis = normalize axis0
        offset = pos - center
        offAxis = offset - vscale (dot offset axis) axis
        tangent = normalize (cross axis offAxis)
     in vscale (strength / (1 + falloff * norm offAxis)) tangent
  -- Func-spec 0021's three. The hard selection criterion was the frozen
  -- signature: 'fieldAccel' sees a position and nothing else, so a field
  -- that needs the particle's velocity (drag, magnetism) cannot be added
  -- here at any price — that is a signature change plus a hot-path
  -- rewrite, and it belongs to a spec that says so (§2.5, §7-2).
  Wind dir strength turbulence ->
    vscale strength (normalize dir) + vscale turbulence (curlNoise 1 pos)
  Turbulence strength scale -> vscale strength (curlNoise scale pos)
  -- Linear restoring force. No distance falloff and no singularity, so
  -- unlike 'PointAttractor' this oscillates about the center rather than
  -- collapsing onto it.
  Spring center k -> vscale (negate k) (pos - center)

-- | A bounded, divergence-free vector field of position alone
-- (func-spec 0021 §2.5): the analytic curl of a potential built from
-- three sinusoids.
--
-- Divergence-free /exactly/, not approximately — @div (curl ψ) = 0@ is an
-- identity, and taking the curl in closed form rather than by finite
-- differences is what keeps it one. That matters because a field with
-- divergence pumps particles into sources and sinks, which reads as
-- clumping rather than as turbulence.
--
-- Pure in the position, so it holds no state and cannot break the replay
-- contract (ADR-0010 D7); bounded by construction, since every term is a
-- cosine, which is what keeps 'stepColumns' from integrating an infinity.
curlNoise :: Float -> V3 -> V3
curlNoise scale (V3 px py pz) =
  V3
    (cy * cosC - bz * cosB)
    (az * cosA - cx * cosC)
    (bx * cosB - ay * cosA)
  where
    -- A zero (or negative) scale would fold the whole field onto a single
    -- value; the core takes the same "clamp rather than crash" line it
    -- takes for particle counts, and 'Magic.Codec' rejects it upstream.
    s = if scale > 0 then 1 / scale else 1

    -- Mutually incommensurate frequency vectors, so the three components
    -- of the potential do not line up into a visible lattice.
    avec@(V3 _ ay az) = V3 1.0 1.7 2.3
    bvec@(V3 bx _ bz) = V3 2.1 1.3 0.7
    cvec@(V3 cx cy _) = V3 1.9 0.9 1.5

    -- The potential is ψ = (sin(a·q), sin(b·q), sin(c·q)) at q = pos/scale;
    -- what follows is its curl, differentiated by hand. Scaling q by a
    -- constant keeps the divergence zero, so the scale is free to be here.
    at (V3 kx ky kz) = cos ((kx * px + ky * py + kz * pz) * s)
    cosA = at avec
    cosB = at bvec
    cosC = at cvec

-- Per-slot integration --------------------------------------------------------

-- | One stable slot's integration state: the velocity the fields have
-- built up, and the displacement it has accumulated.
data SlotState = SlotState
  { ssVel :: !V3
  , ssDisp :: !V3
  }
  deriving (Eq, Show)

-- | At rest, undisplaced — the state a particle is (re)born in.
quiescent :: SlotState
quiescent = SlotState {ssVel = V3 0 0 0, ssDisp = V3 0 0 0}

-- | Advance one stable slot by one fixed step.
--
-- @stepSlot fields dt now previous@ where @now@ is this step's
-- @(age, analytic base position)@ for that slot ('Nothing' = dead or not
-- yet born) and @previous@ is the slot's @(lastAge, state)@ from the
-- previous step. The three cases are exactly ADR-0010 D1/D3:
--
-- * dead or unborn ⇒ 'Nothing' — the state is dropped, so a slot that
--   comes back later starts clean;
-- * a new generation (no previous state, or the age went backwards) ⇒
--   'quiescent': zero displacement at the instant of birth, i.e. the
--   rendered position /is/ the analytic position;
-- * otherwise ⇒ one semi-implicit Euler step, sampling the fields at the
--   particle's current rendered position.
stepSlot
  :: [ForceField]
  -> DeltaTime
  -> Maybe (Double, V3)
  -> Maybe (Double, SlotState)
  -> Maybe (Double, SlotState)
stepSlot fields (DeltaTime dt) now previous = case now of
  Nothing -> Nothing
  Just (age, basePos) -> case previous of
    Just (lastAge, state) | age >= lastAge -> Just (age, integrate state basePos)
    _ -> Just (age, quiescent)
  where
    dtF = realToFrac dt :: Float
    integrate state basePos =
      let accel = fieldAccel fields (basePos + ssDisp state)
          vel' = ssVel state + vscale dtF accel
          disp' = ssDisp state + vscale dtF vel'
       in SlotState {ssVel = vel', ssDisp = disp'}

-- Whole-spell state (SoA) -----------------------------------------------------

-- | The age stored for a slot that holds no live particle. Real ages are
-- @t − birth@ with @birth <= t@, hence never negative, so any negative
-- value is unambiguous; @-1@ is the one written.
noAge :: Double
noAge = -1

-- | Field state of a whole cast, flattened: 'fsOffsets' is the prefix sum
-- of the emitters' particle counts (one entry more than there are
-- emitters, the last being the total slot count — the same flattening
-- 'Magic.Particle.Analytic.emitterOffsets' produces), and every other
-- column is one value per slot in that layout.
--
-- @fsAge < 0@ marks a slot with no state; its velocity and displacement
-- are zero, so a stale read degrades to "no displacement" rather than to
-- somebody else's.
--
-- Not a 'Magic.Particle.Buffer.ParticleBuffer' and so not governed by
-- ADR-0006 — but the same SoA reasoning applies, which is why func-spec
-- 0010 moved it here.
data FieldState = FieldState
  { fsOffsets :: !(U.Vector Int)
  , fsAge :: !(U.Vector Double)
  , fsVelX :: !(U.Vector Float)
  , fsVelY :: !(U.Vector Float)
  , fsVelZ :: !(U.Vector Float)
  , fsDispX :: !(U.Vector Float)
  , fsDispY :: !(U.Vector Float)
  , fsDispZ :: !(U.Vector Float)
  }
  deriving (Eq, Show)

-- | This step's @(age, analytic base position)@ per slot, in the same
-- flattening as 'FieldState'. @fiAge < 0@ means "not alive": the caller
-- uses it both for dead slots and for whole emitters the fields must not
-- touch (ADR-0010 D6 keeps formation particles rigid).
data FieldInputs = FieldInputs
  { fiOffsets :: !(U.Vector Int)
  , fiAge :: !(U.Vector Double)
  , fiPosX :: !(U.Vector Float)
  , fiPosY :: !(U.Vector Float)
  , fiPosZ :: !(U.Vector Float)
  }
  deriving (Eq, Show)

-- | All slots at rest, from each emitter's particle count. This is the
-- state a fresh cast starts in, and the state a hot reload returns to
-- (ADR-0010 D8: a reload is a re-cast, field state is never migrated).
emptyFieldState :: [Int] -> FieldState
emptyFieldState counts =
  FieldState
    { fsOffsets = offsets
    , fsAge = U.replicate n noAge
    , fsVelX = zeros
    , fsVelY = zeros
    , fsVelZ = zeros
    , fsDispX = zeros
    , fsDispY = zeros
    , fsDispZ = zeros
    }
  where
    offsets = U.scanl' (+) 0 (U.fromList counts)
    n = if U.null offsets then 0 else U.last offsets
    zeros = U.replicate n 0

-- | The flat slot id of @(emitter, particleIndex)@, or 'Nothing' when the
-- pair names no slot of this state.
flatSlot :: U.Vector Int -> Int -> Int -> Maybe Int
flatSlot offsets e i
  | e < 0 || i < 0 || e + 1 >= U.length offsets = Nothing
  | i >= offsets U.! (e + 1) - base = Nothing
  | otherwise = Just (base + i)
  where
    base = offsets U.! e

-- | One slot's state in the boxed vocabulary 'stepSlot' is written in —
-- the bridge between the columns and the reference semantics.
slotAt :: FieldState -> Int -> Int -> Maybe (Double, SlotState)
slotAt st e i = do
  j <- flatSlot (fsOffsets st) e i
  let age = fsAge st U.! j
  if age < 0
    then Nothing
    else
      Just
        ( age
        , SlotState
            { ssVel = V3 (fsVelX st U.! j) (fsVelY st U.! j) (fsVelZ st U.! j)
            , ssDisp = V3 (fsDispX st U.! j) (fsDispY st U.! j) (fsDispZ st U.! j)
            }
        )

-- | Advance every slot by one fixed step — the hot path.
--
-- Each slot takes exactly the branch 'stepSlot' specifies: not alive ⇒ no
-- state; no previous state or an age that went backwards ⇒ 'quiescent';
-- otherwise one semi-implicit Euler step sampling the fields at the
-- rendered position. The arithmetic is the same expression in the same
-- order, so the columns hold bit for bit what the boxed transition held.
--
-- Pure in @(fields, dt, ages, base positions, previous state)@ — no wall
-- clock, no randomness of its own — which is what keeps the replay
-- contract (ADR-0010 D7) intact. A previous state of a different shape
-- (a re-cast that changed the emitter layout) is treated as absent, so
-- every live slot restarts from rest rather than inheriting a stranger's
-- momentum.
stepColumns :: [ForceField] -> DeltaTime -> FieldInputs -> FieldState -> FieldState
stepColumns fields (DeltaTime dt) inputs previous = runST $ do
  age <- MU.replicate n noAge
  vx <- MU.replicate n 0
  vy <- MU.replicate n 0
  vz <- MU.replicate n 0
  dx <- MU.replicate n 0
  dy <- MU.replicate n 0
  dz <- MU.replicate n 0
  let go !j
        | j >= n = pure ()
        | otherwise = do
            let a = fiAge inputs `U.unsafeIndex` j
            if a < 0
              then pure ()
              else do
                MU.write age j a
                let la = if compatible then fsAge previous `U.unsafeIndex` j else noAge
                if la >= 0 && a >= la
                  then do
                    let basePos =
                          V3
                            (fiPosX inputs `U.unsafeIndex` j)
                            (fiPosY inputs `U.unsafeIndex` j)
                            (fiPosZ inputs `U.unsafeIndex` j)
                        disp =
                          V3
                            (fsDispX previous `U.unsafeIndex` j)
                            (fsDispY previous `U.unsafeIndex` j)
                            (fsDispZ previous `U.unsafeIndex` j)
                        vel =
                          V3
                            (fsVelX previous `U.unsafeIndex` j)
                            (fsVelY previous `U.unsafeIndex` j)
                            (fsVelZ previous `U.unsafeIndex` j)
                        accel = fieldAccel fields (basePos + disp)
                        vel'@(V3 vx' vy' vz') = vel + vscale dtF accel
                        V3 dx' dy' dz' = disp + vscale dtF vel'
                    MU.write vx j vx'
                    MU.write vy j vy'
                    MU.write vz j vz'
                    MU.write dx j dx'
                    MU.write dy j dy'
                    MU.write dz j dz'
                  else pure ()
            go (j + 1)
  go 0
  FieldState (fiOffsets inputs)
    <$> U.unsafeFreeze age
    <*> U.unsafeFreeze vx
    <*> U.unsafeFreeze vy
    <*> U.unsafeFreeze vz
    <*> U.unsafeFreeze dx
    <*> U.unsafeFreeze dy
    <*> U.unsafeFreeze dz
  where
    n = U.length (fiAge inputs)
    dtF = realToFrac dt :: Float
    compatible =
      fsOffsets previous == fiOffsets inputs && U.length (fsAge previous) == n

-- | The accumulated displacements of the given flat slot ids, in the
-- given order — which is 'Magic.Particle.Analytic.aliveSlotIndices'
-- order, i.e. buffer row order (ADR-0010 D2's single source of truth).
-- A slot id outside the state contributes zero, so a mismatch degrades to
-- "no displacement" instead of shifting the wrong particle.
displacementColumns
  :: FieldState -> U.Vector Int -> (U.Vector Float, U.Vector Float, U.Vector Float)
displacementColumns st slots = (col (fsDispX st), col (fsDispY st), col (fsDispZ st))
  where
    n = U.length (fsDispX st)
    col c = U.map (\j -> if j >= 0 && j < n then c `U.unsafeIndex` j else 0) slots

-- | The integrated velocities of the given flat slot ids, in the same
-- order and with the same out-of-range rule as 'displacementColumns'
-- (func-spec 0023 S2).
--
-- This is the field layer's half of a trailing particle's velocity, and
-- it is the /exact/ finite difference of 'displacementColumns' rather
-- than an approximation of it: 'stepSlot' integrates
-- @disp' = disp + dt·vel'@, so @(disp' − disp) \/ dt == vel'@ identically,
-- for every field and every step size. The analytic half is differenced
-- over 'Magic.Particle.Analytic.velocityStep' and this half over the
-- simulation's own @dt@ — the only interval at which a displacement that
-- exists solely as an integration history is defined at all (func-spec
-- 0023 §10).
--
-- Add-only: nothing above reads it unless the spell has a trail, so a
-- fieldless or trail-free spell never calls it.
velocityColumns
  :: FieldState -> U.Vector Int -> (U.Vector Float, U.Vector Float, U.Vector Float)
velocityColumns st slots = (col (fsVelX st), col (fsVelY st), col (fsVelZ st))
  where
    n = U.length (fsVelX st)
    col c = U.map (\j -> if j >= 0 && j < n then c `U.unsafeIndex` j else 0) slots

-- Boxed entry points ----------------------------------------------------------

-- | Build 'FieldInputs' from the boxed per-emitter shape. The convenience
-- constructor for callers that already hold that shape (tests, tools);
-- 'Magic.Interface' fills the columns directly.
fieldInputsOf :: V.Vector (V.Vector (Maybe (Double, V3))) -> FieldInputs
fieldInputsOf rows =
  FieldInputs
    { fiOffsets = U.scanl' (+) 0 (U.generate (V.length rows) (V.length . (rows V.!)))
    , fiAge = U.fromList [maybe noAge fst slot | slot <- flat]
    , fiPosX = U.fromList [component (\(V3 x _ _) -> x) slot | slot <- flat]
    , fiPosY = U.fromList [component (\(V3 _ y _) -> y) slot | slot <- flat]
    , fiPosZ = U.fromList [component (\(V3 _ _ z) -> z) slot | slot <- flat]
    }
  where
    flat = concatMap V.toList (V.toList rows)
    component f = maybe 0 (f . snd)

-- | 'stepColumns' in the boxed vocabulary of spec 0007.
step
  :: [ForceField]
  -> DeltaTime
  -> V.Vector (V.Vector (Maybe (Double, V3)))
  -> FieldState
  -> FieldState
step fields dt inputs = stepColumns fields dt (fieldInputsOf inputs)

-- | 'displacementColumns' keyed by @(emitter, particleIndex)@ pairs.
displacementsInOrder :: FieldState -> [(Int, Int)] -> [V3]
displacementsInOrder st = map look
  where
    look (e, i) = case flatSlot (fsOffsets st) e i of
      Just j -> V3 (fsDispX st U.! j) (fsDispY st U.! j) (fsDispZ st U.! j)
      Nothing -> V3 0 0 0
