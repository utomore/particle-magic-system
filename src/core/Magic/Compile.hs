-- | Circle → CompiledSpell interpreter (spec 0002 §4.4–§4.6,
-- architecture §6). The inside-out fold, for real:
--
-- >   step 1    core        → SpellSeed       (essence: table, budget, drift)
-- >   step 2    inner A→B   → BehaviorProto   (behavior: trajectory, envelope)
-- >   step 3    interlayer  → ModulatedProto  (modulation: envelope shift)
-- >   step 3.5  phases      → ModulatedProto  (casting envelope delayed by castStart)
-- >   step 4    outer A→B   → EmitterSpec     (presentation: shape, radiation)
-- >   step 5    phases      → [EmitterSpec]   (formation geometry emitters)
--
-- An empty core means a Neutral plain discharge ("素放") — the same fold
-- path, no special case (architecture §3.3). Within a ring, layer A (inner)
-- is applied before layer B (outer); same-kind settings from B override A,
-- different kinds never interfere.
--
-- 'CompiledSpell' and its component records are permanent types (frozen
-- once spec 0002 delivers); 'Motion' and 'Appearance' are data, not
-- functions, so a compiled spell is serializable and budget-analyzable
-- (architecture §4.4). Spec 0006 fixes the 'spellEmitters' 'Vector' this
-- round: index 0 is always the casting emitter, the rest (if any) are the
-- formation geometry emitters synthesized from 'Magic.Circle.circlePhases'.
--
-- Spec 0006's compatibility law (its first citizen, func-spec 0006 §1):
-- any 'Circle' with @circlePhases = Nothing@ compiles to exactly one
-- emitter and a degenerate 'PhasePlan' (@ppDrawEnd = ppConvergeEnd = 0@),
-- bit-for-bit identical to the 0004-era fold. The casting envelope shift
-- (step 3.5) branches around the arithmetic entirely when @castStart = 0@
-- rather than adding zero, and step 5 produces no formation emitters —
-- so the law holds by construction, not by a special case.
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

    -- * Lifecycle (permanent, spec 0006)
  , Phase (..)
  , PhasePlan (..)
  , phaseAt

    -- * Compilation
  , compile
  , CompileError (..)
  , budgetCap

    -- * Particle budget and spatial extent (func-spec 0010 S7)
  , ParticleBudget (..)
  , emitterBounds

    -- * Element lookup (closed influence surface, architecture §10)
  , elementAppearance
  , spellBlend
  ) where

import Data.Bits ((.&.))
import Data.Maybe (fromMaybe)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..))
import Magic.Expr
  ( BinOp (..)
  , Expr (..)
  , ExprV3 (..)
  , Fun1 (..)
  , Fun2 (..)
  , Fun3 (..)
  , Var (..)
  , foldConstants
  )
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , ForceField (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types
  ( CastContext (..)
  , Seconds (..)
  , Time (..)
  , V2 (..)
  , V3 (..)
  , basisFromNormal
  , norm
  , normalize
  , vscale
  )

-- | How a batch should be blended by the renderer.
data BlendMode = BlendAlpha | BlendAdditive
  deriving (Eq, Show)

-- | Result of interpreting a circle. Permanent interface; 0001 fields kept
-- as-is, 'spellEmitters' added by 0002, 'spellPhases' added by 0006 (only
-- additions allowed).
data CompiledSpell = CompiledSpell
  { spellLifetime :: !Seconds
  -- ^ Total spell duration (= the moment the last batch of particles
  -- dies, casting's window included); 'Magic.Interface.isFinished'
  -- triggers past it. Always equals 'ppEnd' of 'spellPhases'.
  , spellBudget :: !Int
  -- ^ Particle budget; from spec 0006 on = Σ emCount across every
  -- emitter (casting + formation), computed at compile time.
  , spellEmitters :: !(V.Vector EmitterSpec)
  -- ^ The emitters driving the analytic sampler. Index 0 is always the
  -- casting emitter; spec 0006 first grows this past length 1 with the
  -- formation-geometry emitters.
  , spellPhases :: !PhasePlan
  -- ^ Absolute time landmarks of the four lifecycle stages (spec 0006).
  , spellBudgetPlan :: !ParticleBudget
  -- ^ The same budget, per emitter (func-spec 0010). Invariant:
  -- @spellBudget == budgetTotal spellBudgetPlan@ and
  -- @budgetPerEmitter@ is index-aligned with 'spellEmitters'. A host
  -- sizing GPU buffers or a scene layer handing out a global quota needs
  -- the breakdown, not just the sum; 'spellBudget' stays for every caller
  -- that only ever wanted the sum.
  , spellFields :: ![ForceField]
  -- ^ The circle's force fields (spec 0007), carried through verbatim
  -- from 'Magic.Circle.circleFields'. Deliberately /not/ folded: fields
  -- are neither a slot's meaning nor a modulation of one (ADR-0010 D4),
  -- so no fold step reads or rewrites them — they ride along as compiled
  -- data for 'Magic.Particle.Field' to interpret.
  }
  deriving (Eq, Show)

data EmitterSpec = EmitterSpec
  { emAnchor :: !Anchor
  , emCount :: !Int
  , emSpawn :: !Envelope
  , emMotion :: !Motion
  , emAppearance :: !Appearance
  , emPhase :: !Phase
  -- ^ Pure metadata (spec 0006): which lifecycle stage this emitter
  -- belongs to. The sampler never reads it — time classification always
  -- goes through 'phaseAt'.
  }
  deriving (Eq, Show)

-- | The four lifecycle stages (architecture §3.3). Extensible sum.
-- 'Converging' and 'Dissipating' label time spans, not emitters — no
-- emitter is ever tagged with either.
data Phase = Drawing | Converging | Casting | Dissipating
  deriving (Eq, Show, Enum, Bounded)

-- | Absolute time landmarks (seconds since cast) carving up a cast into
-- its four stages. Invariant:
-- @0 <= ppDrawEnd <= ppConvergeEnd <= ppCastingEnd <= ppEnd@. Permanent
-- type; frozen once spec 0006 delivers.
data PhasePlan = PhasePlan
  { ppDrawEnd :: !Seconds
  -- ^ = phDraw (degenerate circlePhases = Nothing: 0).
  , ppConvergeEnd :: !Seconds
  -- ^ = castStart = phDraw + phConverge (degenerate: 0).
  , ppCastingEnd :: !Seconds
  -- ^ = castStart + envDelay + envDuration of the casting emitter (the
  -- moment casting's own spawn window closes).
  , ppEnd :: !Seconds
  -- ^ = spellLifetime (invariant: the two always agree).
  }
  deriving (Eq, Show)

-- | Total classification function: @t < 0@ classifies as @t = 0@ (so
-- Drawing holds at the very start of a cast, or Casting immediately in
-- the degenerate/skip case — architecture §3.3's "empty circle skips
-- Drawing/Converging" falls out of this for free when
-- @ppDrawEnd = ppConvergeEnd = 0@, no special case needed).
phaseAt :: PhasePlan -> Time -> Phase
phaseAt plan (Time t)
  | t' < drawEnd = Drawing
  | t' < convergeEnd = Converging
  | t' < castingEnd = Casting
  | otherwise = Dissipating
  where
    t' = max 0 t
    Seconds drawEnd = ppDrawEnd plan
    Seconds convergeEnd = ppConvergeEnd plan
    Seconds castingEnd = ppCastingEnd plan

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
  , motRange :: !(Maybe Expr)
  -- ^ Spawn-offset scale curve (spec 0004); 'Nothing' = no modulation.
  , motConverge :: !(Maybe Expr)
  -- ^ Lateral-convergence curve (spec 0004); 'Nothing' = no modulation.
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
  , appAmplify :: !(Maybe Expr)
  -- ^ Size-multiplier curve (spec 0004); 'Nothing' = no modulation.
  }
  deriving (Eq, Show)

-- | Packed 0xRRGGBBAA endpoints, linearly interpolated over a particle's
-- life fraction.
data ColorRamp = ColorRamp
  { rampStart :: !Word32
  , rampEnd :: !Word32
  }
  deriving (Eq, Show)

-- | A compiled spell's particle budget, broken down per emitter
-- (func-spec 0010 S7). Permanent type; frozen once 0010 delivers.
--
-- Invariants (guarded by @test\/BudgetPlanSpec.hs@):
--
-- * @budgetTotal == U.sum budgetPerEmitter@;
-- * @U.length budgetPerEmitter == V.length spellEmitters@, index-aligned;
-- * @budgetTotal == spellBudget@ of the spell it came from.
data ParticleBudget = ParticleBudget
  { budgetPerEmitter :: !(U.Vector Int)
  -- ^ Particle count per emitter, aligned with 'spellEmitters'.
  , budgetTotal :: !Int
  -- ^ Their sum: the whole cast's worst-case particle count.
  }
  deriving (Eq, Show)

-- | Compilation failure. Extensible sum; first real constructor this
-- round (the 0001 placeholder was never constructed and is replaced).
data CompileError
  = -- | Requested particle count, cap.
    BudgetExceeded !Int !Int
  deriving (Eq, Show)

-- | Hard particle cap for this round: 4096 still renders per-particle;
-- a guardrail for the skeleton renderer, not a performance design. Since
-- spec 0006, this bounds Σ emCount across every emitter (casting +
-- formation), not just casting's.
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
  Neutral -> Appearance (ColorRamp 0xFFFFFFFF 0xFFFFFFFF) 0.05 BlendAlpha Nothing
  Fire -> Appearance (ColorRamp 0xFFD966FF 0xE6390000) 0.05 BlendAdditive Nothing
  Water -> Appearance (ColorRamp 0x66CCFFFF 0x1A4DCC33) 0.05 BlendAlpha Nothing
  Lightning -> Appearance (ColorRamp 0xFFFFCCFF 0x8033FF66) 0.05 BlendAdditive Nothing

-- | Blend mode of the spell's render batch (first emitter's — always the
-- casting emitter, spec 0006 keeps index 0 reserved for it; the shell
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

-- | Step 2/3 product: seed + behavior (trajectory, envelope) + the
-- interlayer's motion-side modulation.
data BehaviorProto = BehaviorProto
  { bpSeed :: !SpellSeed
  , bpTraject :: !Trajectory
  , bpEnvelope :: !Envelope
  , bpConverge :: !(Maybe Expr)
  }

-- The fold -------------------------------------------------------------------

compile :: Circle -> Either CompileError CompiledSpell
compile circle = do
  seed0 <- interpretCore (core circle)
  let mPhases = circlePhases circle
      castStart = castStartOf mPhases
      behavior = foldRing applyInner (innerRings circle) (defaultBehavior seed0)
      modulated0 = foldSlot applyBridge (interLayer circle) behavior
      modulated = applyCastShift castStart modulated0
      motion = foldRing applyOuter (outerRings circle) (defaultMotion modulated)
      envelope = bpEnvelope modulated
      Seconds delay = envDelay envelope
      Seconds duration = envDuration envelope
      Seconds lifetime = envLifetime envelope
      count = ssCount (bpSeed modulated)
      castingEmitter =
        EmitterSpec
          { emAnchor = originAnchor
          , emCount = count
          , emSpawn = envelope
          , emMotion = motion
          , emAppearance = ssAppearance (bpSeed modulated)
          , emPhase = Casting
          }
      formationEmitters = case mPhases of
        Nothing -> []
        Just pc -> formationEmittersFor circle pc castStart element
      element = essenceElementOf (core circle)
      allEmitters = map foldEmitterExprs (castingEmitter : formationEmitters)
      totalCount = sum (map emCount allEmitters)
      -- 'delay' is already absolute (step 3.5 baked castStart into it), so
      -- the closing landmarks are delay + duration [+ lifetime] with no
      -- second addition of castStart — degenerate case (castStart = 0)
      -- reduces to exactly the pre-0006 formula either way.
      plan =
        PhasePlan
          { ppDrawEnd = maybe (Seconds 0) phDraw mPhases
          , ppConvergeEnd = castStart
          , ppCastingEnd = Seconds (delay + duration)
          , ppEnd = Seconds (delay + duration + lifetime)
          }
  if totalCount > budgetCap
    then Left (BudgetExceeded totalCount budgetCap)
    else
      Right
        CompiledSpell
          { spellLifetime = ppEnd plan
          , spellBudget = totalCount
          , spellEmitters = V.fromList allEmitters
          , spellPhases = plan
          , spellBudgetPlan =
              ParticleBudget
                { budgetPerEmitter = U.fromList (map emCount allEmitters)
                , budgetTotal = totalCount
                }
          , spellFields = circleFields circle
          }

-- | Fold every variable-free subtree of every formula an emitter carries
-- (func-spec 0010 S6). Compile time is where a player's constant
-- arithmetic should be paid for — once — rather than per particle per
-- frame; 'Magic.Expr.foldConstants' preserves evaluation bit for bit, so
-- this is invisible to every sampled buffer.
foldEmitterExprs :: EmitterSpec -> EmitterSpec
foldEmitterExprs em =
  em
    { emMotion =
        motion
          { motRange = fmap foldConstants (motRange motion)
          , motConverge = fmap foldConstants (motConverge motion)
          , motTraject = case motTraject motion of
              Formula (ExprV3 x y z) ->
                Formula (ExprV3 (foldConstants x) (foldConstants y) (foldConstants z))
              other -> other
          }
    , emAppearance = look {appAmplify = fmap foldConstants (appAmplify look)}
    }
  where
    motion = emMotion em
    look = emAppearance em

-- | The caster-frame origin anchor shared by casting and every
-- ring/center formation emitter (only the four node emitters offset it).
originAnchor :: Anchor
originAnchor = Anchor {anchorOffset = V3 0 0 0, anchorNormal = V3 0 0 1}

-- | castStart = phDraw + phConverge (spec 0006 §4.3); the degenerate
-- 'Nothing' case is 0 — the compatibility law's anchor value.
castStartOf :: Maybe PhaseConfig -> Seconds
castStartOf Nothing = Seconds 0
castStartOf (Just (PhaseConfig (Seconds d) (Seconds c))) = Seconds (d + c)

-- | Fold step 3.5 — casting's envelope delayed by the whole drawing +
-- converging prelude. Compatibility law's implementation guarantee: at
-- @castStart = 0@ the code path branches around the shift entirely
-- (rather than adding zero), so the degenerate case touches no
-- arithmetic spec 0004 didn't already run.
applyCastShift :: Seconds -> BehaviorProto -> BehaviorProto
applyCastShift (Seconds 0) proto = proto
applyCastShift (Seconds shift) proto =
  let env = bpEnvelope proto
      Seconds delay = envDelay env
   in proto {bpEnvelope = env {envDelay = Seconds (delay + shift)}}

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

-- | The essence element a circle casts with (defaulting to Neutral),
-- independent of 'interpretCore' so the formation-appearance lookup
-- (step 5) can share it without threading state through the 'Either'.
essenceElementOf :: Core -> Element
essenceElementOf c =
  let EssenceRune element _ = fromMaybe (EssenceRune Neutral 1.0) (coreCenter c)
   in element

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
    , bpConverge = Nothing
    }

-- | Fold step 2 — inner rings: behavior runes overwrite the defaults;
-- same-kind runes let the outer layer (B) win because it is applied last.
-- 'FormulaRune' is trajectory-kind (spec 0004 §4.3): it lands on the same
-- 'bpTraject' field, so the override rule holds with no extra machinery.
applyInner :: BehaviorProto -> InnerRune -> BehaviorProto
applyInner proto rune = case rune of
  TrajectoryRune t -> proto {bpTraject = t}
  TimingRune e -> proto {bpEnvelope = e}
  FormulaRune v3 -> proto {bpTraject = Formula v3}

-- | Fold step 3 — the interlayer: modulation. 'PhaseRune' shifts the whole
-- envelope later; the Expr runes (spec 0004 §4.3) record their curves for
-- the sampler; everything else about the behavior is untouched.
applyBridge :: BehaviorProto -> BridgeRune -> BehaviorProto
applyBridge proto rune = case rune of
  PhaseRune (Seconds shift) ->
    let env = bpEnvelope proto
        Seconds delay = envDelay env
     in proto {bpEnvelope = env {envDelay = Seconds (delay + shift)}}
  ConvergeRune e -> proto {bpConverge = Just e}
  AmplifyRune e ->
    let sd = bpSeed proto
     in proto {bpSeed = sd {ssAppearance = (ssAppearance sd) {appAmplify = Just e}}}

defaultMotion :: BehaviorProto -> Motion
defaultMotion proto =
  Motion
    { motSpawn = defaultSpawn
    , motTraject = bpTraject proto
    , motRadiation = AlongNormal
    , motDrift = ssDrift (bpSeed proto)
    , motRange = Nothing
    , motConverge = bpConverge proto
    }

-- | Fold step 4 — outer rings: presentation runes overwrite the motion's
-- spawn pattern, radiation reference and spawn-range curve.
applyOuter :: Motion -> OuterRune -> Motion
applyOuter motion rune = case rune of
  ShapeRune shape -> motion {motSpawn = SpawnOnShape shape}
  RadiateRune mode -> motion {motRadiation = mode}
  RangeRune e -> motion {motRange = Just e}

-- | Apply a ring's two layers in order: A (inner) first, then B (outer).
foldRing :: (b -> a -> b) -> TwoOf (Maybe a) -> b -> b
foldRing f (TwoOf a b) z = foldSlot f b (foldSlot f a z)

foldSlot :: (b -> a -> b) -> Maybe a -> b -> b
foldSlot f slot z = maybe z (f z) slot

-- Fold step 5 — formation geometry emitters (spec 0006 §4.4) -----------------

-- | Circle geometry → the formation-drawing emitters (func-spec 0006
-- §4.4's export table). Only called when 'circlePhases' is 'Just'; the
-- boundary ring is unconditional ("陣" always has a silhouette, even the
-- all-empty circle — 'bare-sigil.json's judgment call), every other
-- element only appears when its slot is occupied.
formationEmittersFor :: Circle -> PhaseConfig -> Seconds -> Element -> [EmitterSpec]
formationEmittersFor circle pc castStart element =
  concat
    [ [ringSlotEmitter 96 (SpawnOnShape (Ring 1.45 1.55))]
    , outerRingSlot 64 1.25 1.35 (ringB (outerRings circle))
    , outerRingSlot 64 1.10 1.20 (ringA (outerRings circle))
    , plainSlot 64 0.95 1.05 (interLayer circle)
    , plainSlot 64 0.80 0.90 (ringB (innerRings circle))
    , plainSlot 64 0.65 0.75 (ringA (innerRings circle))
    , nodeSlotEmitter 12 (V3 0 0.35 0) (north (coreNodes (core circle)))
    , nodeSlotEmitter 12 (V3 0 (-0.35) 0) (south (coreNodes (core circle)))
    , nodeSlotEmitter 12 (V3 0.35 0 0) (east (coreNodes (core circle)))
    , nodeSlotEmitter 12 (V3 (-0.35) 0 0) (west (coreNodes (core circle)))
    , centerSlotEmitter 16 (coreCenter (core circle))
    ]
  where
    formEnv = formEnvFor castStart
    mKc = case pc of
      PhaseConfig _ (Seconds c) | c > 0 -> Just (kcExprFor castStart (Seconds c))
      _ -> Nothing
    appearance = formationAppearance element

    ringSlotEmitter cnt spawn =
      EmitterSpec
        { emAnchor = originAnchor
        , emCount = cnt
        , emSpawn = formEnv
        , emMotion = formationMotion spawn mKc
        , emAppearance = appearance
        , emPhase = Drawing
        }

    -- Outer-ring slots: a 'ShapeRune' occupant previews the player's
    -- drawn shape instead of the nominal band (§4.4 exception).
    outerRingSlot :: Int -> Double -> Double -> Maybe OuterRune -> [EmitterSpec]
    outerRingSlot cnt rIn rOut mRune = case mRune of
      Nothing -> []
      Just (ShapeRune shape) -> [ringSlotEmitter cnt (SpawnOnShape shape)]
      Just _ -> [ringSlotEmitter cnt (SpawnOnShape (Ring rIn rOut))]

    -- Bridge/inner-ring slots: occupied ⇒ the nominal band, no exception.
    plainSlot :: Int -> Double -> Double -> Maybe a -> [EmitterSpec]
    plainSlot cnt rIn rOut mRune = case mRune of
      Nothing -> []
      Just _ -> [ringSlotEmitter cnt (SpawnOnShape (Ring rIn rOut))]

    nodeSlotEmitter :: Int -> V3 -> Maybe NodeRune -> [EmitterSpec]
    nodeSlotEmitter cnt offset mRune = case mRune of
      Nothing -> []
      Just _ ->
        [ EmitterSpec
            { emAnchor = Anchor {anchorOffset = offset, anchorNormal = V3 0 0 1}
            , emCount = cnt
            , emSpawn = formEnv
            , emMotion = formationMotion (SpawnAtAnchor 0) mKc
            , emAppearance = appearance
            , emPhase = Drawing
            }
        ]

    centerSlotEmitter :: Int -> Maybe EssenceRune -> [EmitterSpec]
    centerSlotEmitter cnt mRune = case mRune of
      Nothing -> []
      Just _ ->
        [ EmitterSpec
            { emAnchor = originAnchor
            , emCount = cnt
            , emSpawn = formEnv
            , emMotion = formationMotion (SpawnAtAnchor 0) mKc
            , emAppearance = appearance
            , emPhase = Drawing
            }
        ]

formationMotion :: SpawnPattern -> Maybe Expr -> Motion
formationMotion spawn mKc =
  Motion
    { motSpawn = spawn
    , motTraject = Forward 0
    , motRadiation = AlongNormal
    , motDrift = V3 0 0 0
    , motRange = Nothing
    , motConverge = mKc
    }

-- | The formation particles' envelope (spec 0006 §4.3 derivation chain):
-- the whole drawing+converging prelude is the spawn window, capped at a
-- 0.6s lifetime so long preludes still pulse with short-lived particles
-- instead of one long-tailed batch; every index is guaranteed to be born
-- (the stagger span never exceeds the spawn window) and the last batch
-- dies out exactly at 'castStart'.
formEnvFor :: Seconds -> Envelope
formEnvFor (Seconds castStartD) =
  let formLife = min 0.6 (castStartD / 2)
   in Envelope
        { envDelay = Seconds 0
        , envDuration = Seconds (castStartD - formLife)
        , envLifetime = Seconds formLife
        }

-- | The lateral-convergence curve driving formation collapse: 1 while
-- drawing (@t <= castStart - phConverge@, i.e. before Converging starts),
-- ramping linearly to 0 exactly at 'castStart' — the same
-- 'Magic.Rune.ConvergeRune' machinery (spec 0004) the sampler already
-- evaluates, just synthesized by the compiler instead of a player rune.
kcExprFor :: Seconds -> Seconds -> Expr
kcExprFor (Seconds castStartD) (Seconds convergeD) =
  Fun3
    FClamp
    (Bin Div (Bin Sub (Lit (realToFrac castStartD)) (Var VarT)) (Lit (realToFrac convergeD)))
    (Lit 0)
    (Lit 1)

-- Spatial extent (func-spec 0010 S7) ----------------------------------------

-- | A conservative axis-aligned bounding box, in world space, containing
-- every position this emitter can sample over @[0, horizon]@ — returned
-- as @(min corner, max corner)@.
--
-- Conservative means /over/-estimating is allowed and under-estimating is
-- not: the containment law (@test\/BudgetPlanSpec.hs@) says every
-- position 'Magic.Particle.Analytic.particlePosition' produces lies
-- inside the box, and says nothing about how tightly.
--
-- The core stops here on purpose. Frustum culling needs a camera, and the
-- core has no camera concept (ADR-0008: it does not even know which
-- dimension it is rendered in) — so the /decision/ belongs to the host,
-- and what the core owes it is this box. Func-spec 0010 §8 non-goal 3.
--
-- Derivation: the box is the cube of radius @R@ around the emitter's
-- anchor, where @R@ sums the worst case of each term of the position
-- formula — spawn offset (shape extent × the range curve's largest
-- magnitude), trajectory travel and lateral radius, and drift over the
-- longest age a particle can reach — and then multiplies by
-- @1 + max|1 − k_c|@ for the convergence modulation, which can only
-- rescale the transverse part of that same offset. Curve magnitudes come
-- from interval arithmetic over the 'Expr' AST, so a player formula is
-- bounded without being evaluated per particle.
emitterBounds :: CastContext -> Seconds -> EmitterSpec -> (V3, V3)
emitterBounds ctx (Seconds horizon) em = (anchorW - corner, anchorW + corner)
  where
    corner = V3 radius radius radius

    facing = normalize (casterFacing ctx)
    (fu, fw) = basisFromNormal facing
    toWorld (V3 x y z) = vscale x fu + vscale y fw + vscale z facing
    anchorW = casterPos ctx + toWorld (anchorOffset (emAnchor em))

    Motion spawnPattern trajectory _radiation drift mRange mConverge = emMotion em
    Seconds lifetime = envLifetime (emSpawn em)

    -- The oldest a particle of this emitter can be within the horizon.
    maxAge = realToFrac (min lifetime (max 0 horizon)) :: Float

    indexRange = Interval 0 (fromIntegral (max 0 (emCount em - 1)))
    -- Birth-time frame (spec 0004 §4.4): t = the generation's spawn time,
    -- life pinned at 0.
    birthEnv = IntervalEnv (Interval (negate maxAge) (realToFrac (max 0 horizon))) (Interval 0 0) indexRange
    -- Modulation frame: t = seconds since cast, life = the life fraction.
    frameEnv = IntervalEnv (Interval 0 (realToFrac (max 0 horizon))) (Interval 0 1) indexRange
    -- Behavior frame: t = the particle's own age.
    ageEnv = IntervalEnv (Interval 0 maxAge) (Interval 0 1) indexRange

    rangeScale = maybe 1 (\e -> maxMagnitude (evalInterval e birthEnv)) mRange

    spawnRadius = case spawnPattern of
      SpawnAtAnchor _ -> 0
      SpawnOnShape shape -> rangeScale * shapeRadius shape

    trajectoryRadius = case trajectory of
      Forward speed -> abs (realToFrac speed) * maxAge
      Spiral speed radius' _ -> abs (realToFrac speed) * maxAge + abs (realToFrac radius')
      Orbit radius' _ -> abs (realToFrac radius')
      Formula (ExprV3 x y z) ->
        maxMagnitude (evalInterval x ageEnv)
          + maxMagnitude (evalInterval y ageEnv)
          + maxMagnitude (evalInterval z ageEnv)

    -- The per-particle drift spread draws its two coefficients from
    -- 'Magic.Types.hashChan' shifted to [-0.5, 0.5].
    spreadRadius = case spawnPattern of
      SpawnAtAnchor spread -> abs spread
      SpawnOnShape _ -> 0
    driftRadius = maxAge * (spreadRadius + norm drift)

    rawRadius = spawnRadius + trajectoryRadius + driftRadius

    -- pos = raw − (1 − k_c)·transverse, and |transverse| <= |raw − anchor|.
    convergeSlack = case mConverge of
      Nothing -> 0
      Just e -> maxMagnitude (ivSub (Interval 1 1) (evalInterval e frameEnv))

    radius = rawRadius * (1 + convergeSlack)

-- | An upper bound on @|p|@ for any point @p@ the shape samples.
-- Bounds are the componentwise ones summed rather than the exact circum-
-- radius: conservative on purpose, and it keeps the arithmetic obvious.
shapeRadius :: FaceShape -> Float
shapeRadius shape = case shape of
  Ring rInner rOuter -> max (abs (realToFrac rInner)) (abs (realToFrac rOuter))
  Diamond size -> 2 * abs (realToFrac size)
  Rect (V2 w h) -> (abs w + abs h) / 2
  HollowSquare size -> abs (realToFrac size)

-- Interval arithmetic over Expr ----------------------------------------------

-- | A closed range of 'Float' values. Endpoints may be infinite, which is
-- how "unbounded" is spelled.
data Interval = Interval !Float !Float

data IntervalEnv = IntervalEnv
  { ivT :: !Interval
  , ivLife :: !Interval
  , ivPIndex :: !Interval
  }

wholeLine :: Interval
wholeLine = Interval (-1 / 0) (1 / 0)

-- | Any NaN endpoint means the arithmetic left the ordered reals; the
-- honest answer then is "no bound".
settle :: Interval -> Interval
settle iv@(Interval a b)
  | isNaN a || isNaN b || a > b = wholeLine
  | otherwise = iv

-- | The largest @|x|@ the interval admits. Infinite for an unbounded one,
-- which propagates out as an infinite bounding box — a correct "I cannot
-- bound this" rather than a wrong number.
maxMagnitude :: Interval -> Float
maxMagnitude (Interval a b)
  | isNaN a || isNaN b = 1 / 0
  | otherwise = max (abs a) (abs b)

ivAdd, ivSub, ivMul, ivDiv, ivMin, ivMax :: Interval -> Interval -> Interval
ivAdd (Interval a b) (Interval c d) = settle (Interval (a + c) (b + d))
ivSub (Interval a b) (Interval c d) = settle (Interval (a - d) (b - c))
ivMul (Interval a b) (Interval c d) =
  settle (Interval (minimum products) (maximum products))
  where
    products = [a * c, a * d, b * c, b * d]
ivDiv (Interval a b) (Interval c d)
  | c <= 0 && d >= 0 = wholeLine
  | otherwise = settle (Interval (minimum quotients) (maximum quotients))
  where
    quotients = [a / c, a / d, b / c, b / d]
ivMin (Interval a b) (Interval c d) = settle (Interval (min a c) (min b d))
ivMax (Interval a b) (Interval c d) = settle (Interval (max a c) (max b d))

ivNegate :: Interval -> Interval
ivNegate (Interval a b) = settle (Interval (negate b) (negate a))

-- | Bound an 'Expr' over a range of environments, by structural recursion
-- over the same closed first-order AST 'Magic.Expr.evalExpr' walks.
--
-- Every case is an over-approximation: where a function is not monotone
-- and not cheap to bound tightly ('Pow', 'FSqrt' of a possibly-negative
-- range, 'FSign'), it widens rather than guesses.
evalInterval :: Expr -> IntervalEnv -> Interval
evalInterval expr env = go expr
  where
    go e = case e of
      Lit x -> settle (Interval x x)
      Var VarT -> ivT env
      Var VarLife -> ivLife env
      Var VarPIndex -> ivPIndex env
      -- hashChan is documented to land in [0, 1).
      Chan _ -> Interval 0 1
      Neg a -> ivNegate (go a)
      Bin op a b -> binOp op (go a) (go b)
      Fun1 f a -> fun1 f (go a)
      Fun2 f a b -> fun2 f (go a) (go b)
      Fun3 FClamp a lo hi -> ivMin (ivMax (go a) (go lo)) (go hi)

    binOp op = case op of
      Add -> ivAdd
      Sub -> ivSub
      Mul -> ivMul
      Div -> ivDiv
      -- Neither monotone nor sign-stable in general; only a fully
      -- determined exponentiation is worth bounding exactly, and
      -- 'Magic.Expr.foldConstants' has already collapsed those.
      Pow -> \_ _ -> wholeLine

    fun1 f iv@(Interval a b) = case f of
      FSin -> Interval (-1) 1
      FCos -> Interval (-1) 1
      FAbs
        | a >= 0 -> iv
        | b <= 0 -> settle (Interval (negate b) (negate a))
        | otherwise -> settle (Interval 0 (max (negate a) b))
      -- A negative operand yields NaN, which propagates upwards; only a
      -- wholly non-negative range can be bounded.
      FSqrt
        | a >= 0 -> settle (Interval (sqrt a) (sqrt b))
        | otherwise -> wholeLine
      -- floor x ∈ (x − 1, x], monotone.
      FFloor -> settle (Interval (a - 1) b)
      FSign -> Interval (-1) 1

    fun2 f = case f of
      FMin -> ivMin
      FMax -> ivMax

-- | Formation particles' look: the element's own start color, fading to
-- the same RGB with alpha cleared (a natural per-particle fade, no
-- popping); smaller than normal casting particles, same blend mode as
-- the rest of the spell (architecture §10: one blend per spell).
formationAppearance :: Element -> Appearance
formationAppearance element =
  let Appearance (ColorRamp start _) _ blend _ = elementAppearance element
   in Appearance (ColorRamp start (clearAlpha start)) 0.03 blend Nothing
  where
    clearAlpha c = c .&. 0xFFFFFF00
