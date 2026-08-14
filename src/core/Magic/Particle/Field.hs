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
module Magic.Particle.Field
  ( -- * Field evaluation
    fieldAccel

    -- * Per-slot integration state
  , SlotState (..)
  , quiescent
  , stepSlot

    -- * Whole-spell state
  , FieldState (..)
  , emptyFieldState
  , step
  , displacementsInOrder
  ) where

import Control.Monad (join)
import qualified Data.Vector as V
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

-- Whole-spell state -----------------------------------------------------------

-- | Field state of a whole cast: the outer vector follows emitter order
-- (as in @spellEmitters@), each inner vector is that emitter's @emCount@
-- slots. 'Nothing' = the slot holds no live particle.
--
-- The boxed representation is deliberately /not/ frozen (spec 0007 §4.7):
-- a later performance spec may turn it into SoA unboxed vectors as long as
-- the D1–D3 laws still hold. It is not a 'Magic.Particle.Buffer' and so
-- not governed by ADR-0006.
newtype FieldState = FieldState (V.Vector (V.Vector (Maybe (Double, SlotState))))
  deriving (Eq, Show)

-- | All slots at rest, from each emitter's particle count. This is the
-- state a fresh cast starts in, and the state a hot reload returns to
-- (ADR-0010 D8: a reload is a re-cast, field state is never migrated).
emptyFieldState :: [Int] -> FieldState
emptyFieldState counts = FieldState (V.fromList [V.replicate n Nothing | n <- counts])

-- | Advance every slot by one fixed step. The input has the same shape as
-- the state — emitter by emitter, slot by slot — and carries this step's
-- @(age, analytic base position)@ per slot; the caller passes 'Nothing'
-- both for dead slots and for whole emitters the fields must not touch
-- (ADR-0010 D6 keeps formation particles rigid).
--
-- Pure in @(fields, dt, ages, base positions, previous state)@ — no wall
-- clock, no randomness of its own — which is what keeps the replay
-- contract (ADR-0010 D7) intact.
step
  :: [ForceField]
  -> DeltaTime
  -> V.Vector (V.Vector (Maybe (Double, V3)))
  -> FieldState
  -> FieldState
step fields dt inputs (FieldState previous) =
  FieldState (V.imap emitter inputs)
  where
    emitter e row = V.imap (\i now -> stepSlot fields dt now (priorOf e i)) row
    priorOf e i = join (fmap (join . (V.!? i)) (previous V.!? e))

-- | The accumulated displacements of the given slots, in the given order —
-- which is 'Magic.Particle.Analytic.aliveSlots' order, i.e. buffer row
-- order (ADR-0010 D2's single source of truth). A slot with no state
-- contributes the zero vector, so a mismatch degrades to "no displacement"
-- instead of shifting the wrong particle.
displacementsInOrder :: FieldState -> [(Int, Int)] -> [V3]
displacementsInOrder (FieldState state) = map look
  where
    look (e, i) = case join (fmap (join . (V.!? i)) (state V.!? e)) of
      Just (_, slot) -> ssDisp slot
      Nothing -> V3 0 0 0
