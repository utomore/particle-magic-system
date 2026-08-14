-- | Rune vocabulary (spec 0002 §4.2; ADR-0002 layer 2, ADR-0003).
--
-- Slot responsibility is enforced by the types: each ring stores its own
-- rune sum, so "a behavior rune in the outer ring" is unrepresentable and
-- the interpreter needs zero defensive checks.
--
-- Every sum type here is an /extensible sum/ (spec 0002 §2): the meaning
-- and JSON tag of each existing constructor are frozen, but later specs
-- add constructors (plus an interpreter case and a codec tag) without
-- that counting as breaking the freeze. Spec 0004 fills the reserved
-- slots with the Expr-payload runes (RangeRune / ConvergeRune /
-- AmplifyRune / FormulaRune); their meaning is frozen by 0004 §4.7.
module Magic.Rune
  ( -- * Outer ring: presentation
    OuterRune (..)
  , FaceShape (..)
  , RadiationMode (..)

    -- * Interlayer: modulation
  , BridgeRune (..)

    -- * Inner ring: behavior
  , InnerRune (..)
  , Trajectory (..)
  , Envelope (..)

    -- * Core: essence
  , EssenceRune (..)
  , Element (..)
  , NodeRune (..)

    -- * Force fields (spec 0007; a circle-level property, not a rune)
  , ForceField (..)
  ) where

import Magic.Expr (Expr, ExprV3)
import Magic.Types (Seconds, V2, V3)

-- | Outer-ring runes: how the magic presents itself.
data OuterRune
  = -- | Initial face shape — the source of particle spawn positions.
    ShapeRune FaceShape
  | -- | Reference direction for trajectory travel.
    RadiateRune RadiationMode
  | -- | Spawn-offset scale curve (spec 0004; t = this particle's birth
    -- time, frozen at birth). A no-op without a 'ShapeRune'.
    RangeRune Expr
  deriving (Eq, Show)

-- | The drawn 2D face the spell is born on (face coordinates).
data FaceShape
  = -- | Square band (edge length; the nine-grid center cell is empty).
    HollowSquare !Double
  | -- | Filled rectangle (width × height).
    Rect !V2
  | -- | Annulus (inner radius, outer radius).
    Ring !Double !Double
  | -- | Filled diamond (diagonal half-extent): |x| + |y| ≤ size.
    Diamond !Double
  deriving (Eq, Show)

data RadiationMode
  = -- | Travel along the initial face normal.
    AlongNormal
  | -- | Radiate outward from the face center (degenerates to the normal
    -- direction when the spawn point is at the center).
    RadialOutward
  deriving (Eq, Show)

-- | Interlayer runes: modulate the behavior before presentation.
data BridgeRune
  = -- | Timing shift: delays the whole spawn envelope.
    PhaseRune !Seconds
  | -- | Lateral-convergence multiplier curve (spec 0004; t = seconds
    -- since cast, whole-spell time): 0 = beam, 1 = untouched.
    ConvergeRune Expr
  | -- | Size-multiplier curve (spec 0004; t = seconds since cast;
    -- negative values clamp to 0 at the sampler).
    AmplifyRune Expr
  deriving (Eq, Show)

-- | Inner-ring runes: how particles behave over their lifetime.
data InnerRune
  = TrajectoryRune Trajectory
  | TimingRune Envelope
  | -- | Custom trajectory formula (spec 0004; t = particle age). Same
    -- rune kind as 'TrajectoryRune' for the override rule.
    FormulaRune ExprV3
  deriving (Eq, Show)

-- | Built-in trajectories, functions of particle age relative to the
-- spawn point; the travel axis comes from 'RadiationMode'.
data Trajectory
  = -- | Straight travel: speed (units/second).
    Forward !Double
  | -- | Helix: travel speed, radius, angular frequency (Hz).
    Spiral !Double !Double !Double
  | -- | Circle around the travel axis (radius, angular frequency);
    -- no travel along the axis.
    Orbit !Double !Double
  | -- | Formula-driven offset (spec 0004 §4.5): displacement =
    -- x·b_x + y·b_y + z·d in the travel frame, components evaluated
    -- with t = particle age.
    Formula ExprV3
  deriving (Eq, Show)

-- | Spawn/lifetime envelope. Scheduling (the generalization of the 0001
-- fountain): particle @i@ of @count@ is first born at
-- @envDelay + (i/count)·envLifetime@, then respawns every 'envLifetime'
-- until the window @envDelay + envDuration@ closes; the last batch dies
-- out by @envDelay + envDuration + envLifetime@.
data Envelope = Envelope
  { envDelay :: !Seconds
  -- ^ How long after the cast spawning starts.
  , envDuration :: !Seconds
  -- ^ Length of the spawn window; particles respawn cyclically inside it.
  , envLifetime :: !Seconds
  -- ^ Lifetime of a single particle.
  }
  deriving (Eq, Show)

-- | The core center rune: the spell's essence.
data EssenceRune = EssenceRune
  { essElement :: !Element
  -- ^ Element → color ramp / blend mode (table lookup in Magic.Compile).
  , essPower :: !Double
  -- ^ Intensity → particle-count scaling.
  }
  deriving (Eq, Show)

-- | Spell element. Extensible sum; plain discharge ("素放") = 'Neutral'.
data Element = Neutral | Fire | Water | Lightning
  deriving (Eq, Show, Enum, Bounded)

-- | Core node runes (north/south/east/west slots).
newtype NodeRune
  = -- | Constant drift-velocity bias along that node's face direction.
    DirBias Double
  deriving (Eq, Show)

-- | Force fields acting on the casting-phase particles (spec 0007,
-- ADR-0010). Not a rune and not in any slot: a field is a property of
-- the circle as a whole (its physical environment), so it hangs off
-- 'Magic.Circle.circleFields' — ADR-0010 D4 spells out the four reasons.
-- Lives here because this is the parameter vocabulary's home, next to
-- 'Envelope' and 'Trajectory'.
--
-- Parameters are static world-space values (ADR-0010 D5); field-to-particle
-- only (architecture §7). Extensible sum: existing constructors' meaning
-- and JSON tags are frozen once spec 0007 delivers.
data ForceField
  = -- | Constant world-space acceleration (units/s²).
    Gravity !V3
  | -- | Center, strength (> 0 attracts, < 0 repels; the magnitude at
    -- distance 1 with zero softening) and softening (> 0, keeps the
    -- singularity at the center out):
    -- @accel = strength · normalize(center − pos) / (dist² + softening²)@.
    PointAttractor !V3 !Float !Float
  | -- | Center, axis (normalized when evaluated), tangential strength and
    -- radial falloff (>= 0; 0 = the swirl does not weaken with off-axis
    -- distance): @accel = strength · tangent / (1 + falloff · offAxisDist)@
    -- with @tangent = normalize(axis × offAxisVector)@.
    Vortex !V3 !V3 !Float !Float
  deriving (Eq, Show)
