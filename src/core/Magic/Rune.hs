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
  , BillboardShape (..)

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

    -- * Activation points (spec 0025; a circle-level property, not a rune)
  , Anchor (..)
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
  | -- | Billboard form of the main-effect particles (spec 0015; the
    -- outer ring is presentation, ADR-0003). Formation emitters ignore
    -- it — a drawn circle stays crisp squares.
    StyleRune BillboardShape
  deriving (Eq, Show)

-- | Billboard geometry hint the renderer receives per batch (spec 0015).
-- Moved here from the boundary's @Magic.Interface@ (which still
-- re-exports it) the moment it became player vocabulary.
--
-- Declaration order IS the C wire code: @shapeCode = fromEnum@, and each
-- constructor's @PM_SHAPE_*@ define pins its index forever — new shapes
-- append at the end, never in the middle (ADR-0013). Always
-- parameterless: @batch_info@'s frozen stride gives a shape one int of
-- room and nothing more (ADR-0013 records the rejected alternatives).
data BillboardShape
  = -- | Hard-edged square (wire code 0, the original and default look).
    BillboardSquare
  | -- | Soft dot: radial alpha falloff, full at the center.
    BillboardSoftDot
  | -- | Hollow ring: alpha peaks on the r ≈ 0.5 band.
    BillboardRing
  | -- | Four-pointed cross flare.
    BillboardSpark
  deriving (Eq, Show, Enum, Bounded)

-- | The drawn 2D face the spell is born on (face coordinates).
--
-- Func-spec 0021 appends four shapes. Every constructor here owes a
-- /conservative upper bound/ to 'Magic.Compile.shapeRadius' as well as a
-- sampler case: GHC's exhaustiveness check catches a missing case, but a
-- bound that is merely too small compiles fine and silently breaks the
-- host's frustum culling (func-spec 0021 §2.2), which is why the bound is
-- a property test rather than a review item.
data FaceShape
  = -- | Square band (edge length; the nine-grid center cell is empty).
    HollowSquare !Double
  | -- | Filled rectangle (width × height).
    Rect !V2
  | -- | Annulus (inner radius, outer radius).
    Ring !Double !Double
  | -- | Filled diamond (diagonal half-extent): |x| + |y| ≤ size.
    Diamond !Double
  | -- | Filled regular polygon: vertex count (>= 3), circumradius.
    Polygon !Int !Double
  | -- | Filled star: point count (>= 2), outer radius, inner radius.
    Star !Int !Double !Double
  | -- | Filled cross: arm length (from the center), arm width.
    Cross !Double !Double
  | -- | Filled annular sector: inner radius, outer radius, sweep angle
    -- (radians), centered on the face's +x axis.
    Sector !Double !Double !Double
  deriving (Eq, Show)

-- | Reference direction the trajectory's travel term is applied along.
-- Func-spec 0021 appends the two that need the spawn offset's /tangent/
-- rather than its ray.
data RadiationMode
  = -- | Travel along the initial face normal.
    AlongNormal
  | -- | Radiate outward from the face center (degenerates to the normal
    -- direction when the spawn point is at the center).
    RadialOutward
  | -- | Converge on the face center — 'RadialOutward' reversed, with the
    -- same degenerate fallback.
    RadialInward
  | -- | Travel along the face tangent at the spawn point, i.e. around the
    -- face center; degenerates to the normal direction at the center.
    TangentialSwirl
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
  | -- | Sine weave: travel speed, lateral amplitude, frequency (Hz). The
    -- lateral term stays in one plane, unlike 'Spiral'.
    Wave !Double !Double !Double
  | -- | Analytic parabola: initial speed along the axis, gravity
    -- (units/s²) opposing it. A closed-form arc that needs no force field
    -- — and so no cross-frame state (func-spec 0021 §2.5).
    Ballistic !Double !Double
  | -- | Surge/coast/surge along the axis: mean speed, pulse frequency
    -- (Hz). Speed is @mean·(1 − cos)@, so it never runs backwards and the
    -- displacement is monotone.
    Pulse !Double !Double
  | -- | Hard zigzag: travel speed, lateral amplitude, reversal frequency
    -- (direction changes per second). 'Wave' with a triangle wave in
    -- place of the sine.
    Zigzag !Double !Double !Double
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
--
-- Func-spec 0021 appends the three missing 五行 members plus the 陰陽
-- pair. __The declaration order is wire code from that round on__ (its
-- §2.4): 'Magic.Sigil.hashCircle' feeds the element's ordinal into the
-- digest that decides what a spell's sigil looks like, so inserting a
-- constructor between the existing ones would silently redraw every
-- already-written spell. New elements append at the end, always.
data Element
  = Neutral
  | Fire
  | Water
  | Lightning
  | Metal
  | Wood
  | Earth
  | Yin
  | Yang
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
  | -- | Direction (normalized when evaluated), strength and turbulence
    -- (>= 0): a steady push plus a divergence-free positional wobble,
    -- @accel = strength · normalize(dir) + turbulence · curlNoise(pos)@.
    Wind !V3 !Float !Float
  | -- | Strength and spatial scale (> 0): that wobble on its own,
    -- @accel = strength · curlNoise(pos / scale)@.
    Turbulence !Float !Float
  | -- | Center and stiffness (> 0): a linear restoring force,
    -- @accel = −k · (pos − center)@. Unlike 'PointAttractor' it neither
    -- falls off with distance nor has a singularity, so it produces a
    -- steady oscillation about the center instead of a collapse onto it.
    Spring !V3 !Float
  deriving (Eq, Show)

-- | The activation point a spell (or one of its emitters) fires from, in
-- the caster's coordinate frame (resolved at sample time with
-- 'Magic.Types.CastContext': local +Z is @casterFacing@, local X\/Y are
-- the 'Magic.Types.basisFromNormal' pair of the facing).
--
-- Permanent type, frozen since spec 0002 — where it was declared in
-- "Magic.Compile", which still re-exports it, so every existing import
-- keeps working. Func-spec 0025 moves the declaration down here for the
-- same reason spec 0015 moved 'BillboardShape': it became circle-level
-- player vocabulary ('Magic.Circle.circleAnchors'), and "Magic.Circle"
-- cannot import "Magic.Compile" — the interpreter reads the circle, not
-- the other way round.
--
-- Not a rune, and deliberately so (func-spec 0025 §2.5): an activation
-- point says /where this spell comes out/, which is not one of ADR-0003's
-- four slot responsibilities (essence, behavior, modulation,
-- presentation). It hangs off the circle as a whole, exactly as
-- 'ForceField' and @circlePhases@ do.
data Anchor = Anchor
  { anchorOffset :: !V3
  -- ^ Offset from the caster position (caster frame; skeleton = origin).
  , anchorNormal :: !V3
  -- ^ Initial face normal (caster frame; skeleton = +Z = casterFacing).
  }
  deriving (Eq, Show)
