-- | Circle → CompiledSpell interpreter (spec 0002 §4.4–§4.6,
-- architecture §6). The inside-out fold, for real:
--
-- >   step 1  core        → SpellSeed       (essence: table, budget, drift)
-- >   step 2  inner A→B   → BehaviorProto   (behavior: trajectory, envelope)
-- >   step 3  interlayer  → ModulatedProto  (modulation: envelope shift)
-- >   step 4  outer A→B   → EmitterSpec     (presentation: shape, radiation)
--
-- An empty core means a Neutral plain discharge ("素放") — the same fold
-- path, no special case (architecture §3.3). Within a ring, layer A (inner)
-- is applied before layer B (outer); same-kind settings from B override A,
-- different kinds never interfere.
--
-- 'CompiledSpell' and its component records are permanent types (frozen
-- once spec 0002 delivers); 'Motion' and 'Appearance' are data, not
-- functions, so a compiled spell is serializable and budget-analyzable
-- (architecture §4.4). This round the fold always produces exactly one
-- emitter; the 'Vector' interface is reserved for the lifecycle spec's
-- formation-geometry emitters.
module Magic.Compile
  ( -- * Compiled products (permanent)
    CompiledSpell (..)
  , EmitterSpec (..)
  , Anchor (..)
  , Envelope (..)
  , Motion (..)
  , SpawnPattern (..)
  , Appearance (..)
  , ColorRamp (..)
  , BlendMode (..)

    -- * Compilation
  , compile
  , CompileError (..)
  , budgetCap

    -- * Element lookup (closed influence surface, architecture §10)
  , elementAppearance
  , spellBlend
  ) where

import Data.Maybe (fromMaybe)
import qualified Data.Vector as V
import Data.Word (Word32)
import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..))
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..), V3 (..))

-- | How a batch should be blended by the renderer.
data BlendMode = BlendAlpha | BlendAdditive
  deriving (Eq, Show)

-- | Result of interpreting a circle. Permanent interface; 0001 fields kept
-- as-is, 'spellEmitters' added this round (only additions allowed).
data CompiledSpell = CompiledSpell
  { spellLifetime :: !Seconds
  -- ^ Total spell duration (= envDelay + envDuration + envLifetime, the
  -- moment the last batch of particles dies);
  -- 'Magic.Interface.isFinished' triggers past it.
  , spellBudget :: !Int
  -- ^ Particle budget; from this round on = Σ emCount, computed at
  -- compile time.
  , spellEmitters :: !(V.Vector EmitterSpec)
  -- ^ The emitters driving the analytic sampler (this round: exactly 1).
  }
  deriving (Eq, Show)

data EmitterSpec = EmitterSpec
  { emAnchor :: !Anchor
  , emCount :: !Int
  , emSpawn :: !Envelope
  , emMotion :: !Motion
  , emAppearance :: !Appearance
  }
  deriving (Eq, Show)

-- | The activation point, in the caster's coordinate frame (resolved at
-- sample time with 'Magic.Types.CastContext': local +Z is 'casterFacing',
-- local X/Y are the 'Magic.Types.basisFromNormal' pair of the facing).
data Anchor = Anchor
  { anchorOffset :: !V3
  -- ^ Offset from the caster position (caster frame; skeleton = origin).
  , anchorNormal :: !V3
  -- ^ Initial face normal (caster frame; skeleton = +Z = casterFacing).
  }
  deriving (Eq, Show)

data Motion = Motion
  { motSpawn :: !SpawnPattern
  -- ^ Where particles are born.
  , motTraject :: !Trajectory
  -- ^ Path relative to the spawn point, as a function of age.
  , motRadiation :: !RadiationMode
  -- ^ Reference for the trajectory's travel direction.
  , motDrift :: !V3
  -- ^ Constant drift velocity from node biases, in face coordinates
  -- (x = face right, y = face up, z = along the normal).
  }
  deriving (Eq, Show)

data SpawnPattern
  = -- | Plain discharge: all particles born at the anchor; the parameter
    -- is the per-particle lateral drift-velocity spread (derived from
    -- 'Magic.Types.hashChan' channels 0/1 — the generalization of the
    -- 0001 fountain; plain discharge = 1.6).
    SpawnAtAnchor !Float
  | -- | Born on the initial face shape (no drift spread).
    SpawnOnShape !FaceShape
  deriving (Eq, Show)

data Appearance = Appearance
  { appColor :: !ColorRamp
  -- ^ Particle life fraction 0..1 → RGBA (linear interpolation).
  , appSize :: !Float
  , appBlend :: !BlendMode
  }
  deriving (Eq, Show)

-- | Packed 0xRRGGBBAA endpoints, linearly interpolated over a particle's
-- life fraction.
data ColorRamp = ColorRamp
  { rampStart :: !Word32
  , rampEnd :: !Word32
  }
  deriving (Eq, Show)

-- | Compilation failure. Extensible sum; first real constructor this
-- round (the 0001 placeholder was never constructed and is replaced).
data CompileError
  = -- | Requested particle count, cap.
    BudgetExceeded !Int !Int
  deriving (Eq, Show)

-- | Hard particle cap for this round: 4096 still renders per-particle;
-- a guardrail for the skeleton renderer, not a performance design.
budgetCap :: Int
budgetCap = 4096

-- Plain-discharge defaults (spec 0002 §4.5, constants from the delivered
-- 0001 stub) ----------------------------------------------------------------

baseCount :: Int
baseCount = 256

defaultEnvelope :: Envelope
defaultEnvelope =
  Envelope
    { envDelay = Seconds 0
    , envDuration = Seconds 8
    , envLifetime = Seconds 2
    }

defaultTrajectory :: Trajectory
defaultTrajectory = Forward 4.0

defaultSpawn :: SpawnPattern
defaultSpawn = SpawnAtAnchor 1.6

-- | Element → appearance lookup (the only place essence influences looks;
-- closed influence surface, architecture §10). Neutral must reproduce the
-- 0001 plain discharge: solid white, alpha blend, size 0.05.
elementAppearance :: Element -> Appearance
elementAppearance element = case element of
  Neutral -> Appearance (ColorRamp 0xFFFFFFFF 0xFFFFFFFF) 0.05 BlendAlpha
  Fire -> Appearance (ColorRamp 0xFFD966FF 0xE6390000) 0.05 BlendAdditive
  Water -> Appearance (ColorRamp 0x66CCFFFF 0x1A4DCC33) 0.05 BlendAlpha
  Lightning -> Appearance (ColorRamp 0xFFFFCCFF 0x8033FF66) 0.05 BlendAdditive

-- | Blend mode of the spell's render batch (first emitter's; the shell
-- reads this through 'Magic.Interface').
spellBlend :: CompiledSpell -> BlendMode
spellBlend spell = case V.toList (spellEmitters spell) of
  (em : _) -> appBlend (emAppearance em)
  [] -> BlendAlpha

-- Interpreter intermediate representations (internal, free to evolve) --------

-- | Step 1 product: essence interpreted.
data SpellSeed = SpellSeed
  { ssAppearance :: !Appearance
  , ssCount :: !Int
  , ssDrift :: !V3
  }

-- | Step 2/3 product: seed + behavior (trajectory, envelope).
data BehaviorProto = BehaviorProto
  { bpSeed :: !SpellSeed
  , bpTraject :: !Trajectory
  , bpEnvelope :: !Envelope
  }

-- The fold -------------------------------------------------------------------

compile :: Circle -> Either CompileError CompiledSpell
compile circle = do
  seed0 <- interpretCore (core circle)
  let behavior = foldRing applyInner (innerRings circle) (defaultBehavior seed0)
      modulated = foldSlot applyBridge (interLayer circle) behavior
      motion = foldRing applyOuter (outerRings circle) (defaultMotion modulated)
      envelope = bpEnvelope modulated
      Seconds delay = envDelay envelope
      Seconds duration = envDuration envelope
      Seconds lifetime = envLifetime envelope
      count = ssCount (bpSeed modulated)
      emitter =
        EmitterSpec
          { emAnchor = Anchor {anchorOffset = V3 0 0 0, anchorNormal = V3 0 0 1}
          , emCount = count
          , emSpawn = envelope
          , emMotion = motion
          , emAppearance = ssAppearance (bpSeed modulated)
          }
  pure
    CompiledSpell
      { spellLifetime = Seconds (delay + duration + lifetime)
      , spellBudget = count
      , spellEmitters = V.singleton emitter
      }

-- | Fold step 1 — the core: essence to appearance, power to particle
-- count (clamped below at 1; above the cap is a compile error), node
-- biases to a summed drift velocity in face coordinates.
interpretCore :: Core -> Either CompileError SpellSeed
interpretCore c = do
  let EssenceRune element power = fromMaybe (EssenceRune Neutral 1.0) (coreCenter c)
      requested = round (power * fromIntegral baseCount) :: Int
  count <-
    if requested > budgetCap
      then Left (BudgetExceeded requested budgetCap)
      else Right (max 1 requested)
  pure
    SpellSeed
      { ssAppearance = elementAppearance element
      , ssCount = count
      , ssDrift = nodeDrift (coreNodes c)
      }

-- | Σ directionᵢ × biasᵢ in face coordinates: north = +y (face up),
-- east = +x (face right), south/west their negations.
nodeDrift :: Nodes (Maybe NodeRune) -> V3
nodeDrift nodes =
  contribution (north nodes) (V3 0 1 0)
    + contribution (south nodes) (V3 0 (-1) 0)
    + contribution (east nodes) (V3 1 0 0)
    + contribution (west nodes) (V3 (-1) 0 0)
  where
    contribution slot dir = case slot of
      Nothing -> V3 0 0 0
      Just (DirBias bias) -> realToFrac bias `scale` dir
    scale s (V3 x y z) = V3 (s * x) (s * y) (s * z)

defaultBehavior :: SpellSeed -> BehaviorProto
defaultBehavior seed =
  BehaviorProto
    { bpSeed = seed
    , bpTraject = defaultTrajectory
    , bpEnvelope = defaultEnvelope
    }

-- | Fold step 2 — inner rings: behavior runes overwrite the defaults;
-- same-kind runes let the outer layer (B) win because it is applied last.
applyInner :: BehaviorProto -> InnerRune -> BehaviorProto
applyInner proto rune = case rune of
  TrajectoryRune t -> proto {bpTraject = t}
  TimingRune e -> proto {bpEnvelope = e}

-- | Fold step 3 — the interlayer: modulation. 'PhaseRune' shifts the whole
-- envelope later; everything else about the behavior is untouched.
applyBridge :: BehaviorProto -> BridgeRune -> BehaviorProto
applyBridge proto (PhaseRune (Seconds shift)) =
  let env = bpEnvelope proto
      Seconds delay = envDelay env
   in proto {bpEnvelope = env {envDelay = Seconds (delay + shift)}}

defaultMotion :: BehaviorProto -> Motion
defaultMotion proto =
  Motion
    { motSpawn = defaultSpawn
    , motTraject = bpTraject proto
    , motRadiation = AlongNormal
    , motDrift = ssDrift (bpSeed proto)
    }

-- | Fold step 4 — outer rings: presentation runes overwrite the motion's
-- spawn pattern and radiation reference.
applyOuter :: Motion -> OuterRune -> Motion
applyOuter motion rune = case rune of
  ShapeRune shape -> motion {motSpawn = SpawnOnShape shape}
  RadiateRune mode -> motion {motRadiation = mode}

-- | Apply a ring's two layers in order: A (inner) first, then B (outer).
foldRing :: (b -> a -> b) -> TwoOf (Maybe a) -> b -> b
foldRing f (TwoOf a b) z = foldSlot f b (foldSlot f a z)

foldSlot :: (b -> a -> b) -> Maybe a -> b -> b
foldSlot f slot z = maybe z (f z) slot
