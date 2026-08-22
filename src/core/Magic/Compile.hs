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
  , BillboardShape (..)

    -- * Compiled formula programs (func-spec 0022 S3)
  , EmitterCode (..)
  , noEmitterCode
  , emitterCodeOf

    -- * Lifecycle (permanent, spec 0006)
  , Phase (..)
  , PhasePlan (..)
  , phaseAt

    -- * Compilation
  , compile
  , compileMany
  , CompileError (..)
  , budgetCap

    -- * Particle budget and spatial extent (func-spec 0010 S7)
  , ParticleBudget (..)
  , emitterBounds
  , shapeRadius

    -- * Element lookup (closed influence surface, architecture §10)
  , elementAppearance
  , spellBlend

    -- * Trail opt-in (func-spec 0023 S2/S3)
  , spellNeedsVelocity

    -- * Interval arithmetic over 'Expr' (internal; NOT part of the frozen
    -- surface). Exposed for "Magic.Space" alone, so the per-axis box of
    -- func-spec 0025 bounds a player formula with the /same/ code
    -- 'emitterBounds' does rather than a second copy of it — which is
    -- what lets the frozen function stay bit-for-bit while the new one
    -- gets tighter (func-spec 0025 §2.3).
  , Interval (..)
  , IntervalEnv (..)
  , evalInterval
  , maxMagnitude
  , ivSub
  , shapeRadius
  ) where

import Data.Bits ((.&.))
import Data.Maybe (fromMaybe)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), SigilTiming (..), TwoOf (..))
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
import Magic.Expr.Code (ExprCode, ExprCodeV3, compileExpr, compileExprV3)
import Magic.Rune
  ( Anchor (..)
  , BillboardShape (..)
  , BridgeRune (..)
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
import Magic.Sigil
  ( SigilPlan (..)
  , SigilStroke (..)
  , sigilPlan
  , strokeRadius
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
  -- ^ The emitters driving the analytic sampler. A prefix of casting
  -- emitters comes first, the formation-geometry emitters (spec 0006)
  -- after; index 0 is always a casting emitter. The prefix has length 1
  -- unless the circle names several activation points (func-spec 0025),
  -- in which case it has one entry per 'Magic.Rune.Anchor', in the order
  -- the circle lists them.
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

-- | Composition of two circles' compiled products into one spell
-- (func-spec 0012 §2, ADR-0012). Every field composes the only way its
-- own meaning allows:
--
-- * 'spellEmitters' and 'spellFields' concatenate, left spell first —
--   the sampler walks emitters independently, so concatenating them is
--   exactly "run both", and the row order of the sampled buffer is the
--   concatenation order (the superposition law, @test\/Acceptance12Spec@);
-- * 'spellBudget' and 'budgetTotal' add, 'budgetPerEmitter' concatenates,
--   which keeps 'ParticleBudget' index-aligned with the concatenated
--   emitters and its sum invariant intact;
-- * 'spellPhases' takes the per-landmark maximum, and 'spellLifetime'
--   (always @ppEnd@) follows it.
--
-- Per-landmark @max@ is the only merge that preserves the 'PhasePlan'
-- invariant without truncating either component: @max@ is monotone in
-- each argument, so @a₁≤a₂≤a₃≤a₄@ and @b₁≤b₂≤b₃≤b₄@ give
-- @max a₁ b₁ ≤ max a₂ b₂ ≤ …@. Semantically each stage of the composed
-- circle lasts until the slowest component's does; a faster component
-- fades inside its own envelope with nothing to truncate it.
--
-- Associativity is inherited term by term (@max@, @+@, and both
-- concatenations are associative), so this is a lawful 'Semigroup' —
-- guarded bit for bit by @test\/ComposeSpec.hs@.
instance Semigroup CompiledSpell where
  a <> b =
    CompiledSpell
      { spellLifetime = ppEnd mergedPlan
      , spellBudget = spellBudget a + spellBudget b
      , spellEmitters = spellEmitters a <> spellEmitters b
      , spellPhases = mergedPlan
      , spellBudgetPlan = mergeBudget (spellBudgetPlan a) (spellBudgetPlan b)
      , spellFields = spellFields a <> spellFields b
      }
    where
      mergedPlan = mergePhases (spellPhases a) (spellPhases b)

-- | The empty spell: no emitters, no fields, no budget, and a fully
-- degenerate 'PhasePlan' (every landmark 0, so 'phaseAt' classifies every
-- instant as 'Dissipating' and 'Magic.Interface.isFinished' holds
-- immediately).
--
-- It is an identity for '<>' on every value satisfying the 'PhasePlan'
-- invariant — which is every value 'compile' can produce, since
-- @max 0 x = x@ needs @x >= 0@ and @0 <= ppDrawEnd@ is the invariant's
-- first clause. Note that @compile emptyCircle@ is /not/ 'mempty': an
-- empty circle still casts a plain discharge (architecture §3.3). The
-- unit laws are asserted about 'mempty' itself, not about that spell.
instance Monoid CompiledSpell where
  mempty =
    CompiledSpell
      { spellLifetime = Seconds 0
      , spellBudget = 0
      , spellEmitters = V.empty
      , spellPhases =
          PhasePlan
            { ppDrawEnd = Seconds 0
            , ppConvergeEnd = Seconds 0
            , ppCastingEnd = Seconds 0
            , ppEnd = Seconds 0
            }
      , spellBudgetPlan = ParticleBudget {budgetPerEmitter = U.empty, budgetTotal = 0}
      , spellFields = []
      }

-- | Per-landmark maximum (func-spec 0012 §2). Invariant-preserving, see
-- the 'Semigroup' instance's note.
mergePhases :: PhasePlan -> PhasePlan -> PhasePlan
mergePhases x y =
  PhasePlan
    { ppDrawEnd = ppDrawEnd x `max` ppDrawEnd y
    , ppConvergeEnd = ppConvergeEnd x `max` ppConvergeEnd y
    , ppCastingEnd = ppCastingEnd x `max` ppCastingEnd y
    , ppEnd = ppEnd x `max` ppEnd y
    }

-- | Concatenate the per-emitter breakdown and add the totals — the
-- 'ParticleBudget' counterpart of concatenating 'spellEmitters'.
mergeBudget :: ParticleBudget -> ParticleBudget -> ParticleBudget
mergeBudget x y =
  ParticleBudget
    { budgetPerEmitter = budgetPerEmitter x <> budgetPerEmitter y
    , budgetTotal = budgetTotal x + budgetTotal y
    }

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
  , emCode :: !EmitterCode
  -- ^ The emitter's formulas, compiled to bytecode (func-spec 0022 S3).
  -- A /cache/ of what 'emMotion' and 'emAppearance' already say, not a
  -- second source of truth: 'compile' fills it from the emitter's own AST
  -- and nothing else ever writes it.
  }
  deriving (Eq, Show)

-- | The bytecode form of every formula an emitter can carry (func-spec
-- 0022 S3). Each slot is 'Nothing' when the emitter has no formula there —
-- and also, for a hand-built 'EmitterSpec' that never went through
-- 'compile', when nobody has compiled one yet: the sampler then falls back
-- to 'Magic.Expr.evalFinite' over the AST, which law 1 makes an identical
-- answer at a slower speed.
--
-- Why the AST fields stay where they are, rather than being /replaced/ by
-- these (a deviation from func-spec 0022 §3, recorded in its §10): the
-- 'Magic.Rune.Trajectory' sum carries its own 'Magic.Expr.ExprV3' and
-- "Magic.Rune" is untouched this round; and 'emitterBounds' bounds a player
-- formula by interval arithmetic over the AST, which a flattened program
-- cannot answer. Bytecode is what the /sampler/ needs; the AST is what the
-- /compiler/ needs. Keeping both is the honest shape.
data EmitterCode = EmitterCode
  { emcRange :: !(Maybe ExprCode)
  -- ^ 'motRange' compiled.
  , emcConverge :: !(Maybe ExprCode)
  -- ^ 'motConverge' compiled.
  , emcAmplify :: !(Maybe ExprCode)
  -- ^ 'appAmplify' compiled.
  , emcTraject :: !(Maybe ExprCodeV3)
  -- ^ 'motTraject'\'s 'Magic.Rune.Formula' payload compiled.
  }
  deriving (Eq, Show)

-- | No formula compiled — the value a fixture that bypasses 'compile'
-- carries, and the correct one for an emitter with no formulas at all.
noEmitterCode :: EmitterCode
noEmitterCode = EmitterCode Nothing Nothing Nothing Nothing

-- | Compile every formula an emitter carries. Reads the emitter's own
-- 'Motion' and 'Appearance', so the cache cannot drift from the AST it was
-- derived from unless somebody rewrites one without re-running this — which
-- @test\/ExprCodeWiringSpec.hs@ checks for across every shipped example.
emitterCodeOf :: EmitterSpec -> EmitterCode
emitterCodeOf em =
  EmitterCode
    { emcRange = fmap compileExpr (motRange motion)
    , emcConverge = fmap compileExpr (motConverge motion)
    , emcAmplify = fmap compileExpr (appAmplify (emAppearance em))
    , emcTraject = case motTraject motion of
        Formula v3 -> Just (compileExprV3 v3)
        _ -> Nothing
    }
  where
    motion = emMotion em

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
  | -- | Born /along/ a sigil stroke (func-spec 0016): index order is
    -- position along the curve, so the emitter draws its stroke instead
    -- of scattering over an area. No drift spread, same as
    -- 'SpawnOnShape'.
    SpawnOnStroke !SigilStroke
  deriving (Eq, Show)

data Appearance = Appearance
  { appColor :: !ColorRamp
  -- ^ Particle life fraction 0..1 → RGBA (linear interpolation).
  , appSize :: !Float
  , appBlend :: !BlendMode
  , appAmplify :: !(Maybe Expr)
  -- ^ Size-multiplier curve (spec 0004); 'Nothing' = no modulation.
  , appShape :: !BillboardShape
  -- ^ Billboard form (spec 0015). Opt-in: 'elementAppearance' and
  -- 'formationAppearance' always answer 'BillboardSquare', so only a
  -- 'StyleRune' ever moves it.
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

-- | Hard particle cap: the most particles one compiled spell — a single
-- circle or a composition of several ('compileMany') — may add up to,
-- summed over every emitter (casting + formation) since spec 0006.
--
-- Func-spec 0012 S1 raises it from the skeleton renderer's 4096 guardrail
-- to a measurement-backed value. Selection rule: the largest power of two
-- whose whole per-frame CPU cost (sampling + quad expansion, the two
-- terms func-spec 0010 §9.2 measured) stays under 2 ms — an eighth of the
-- 60 fps frame, leaving the host the rest. At 0010's measured constants
-- that is 16384; see func-spec 0012 §9 for the numbers taken at this
-- value itself.
--
-- Raising it again is an interface event, not an edit: the C ABI mirrors
-- it through @pm_max_particles@ (func-spec 0011's query mirror law) and
-- the demo's GPU mesh capacity is sized independently and chunked, so a
-- host that asks rather than assumes keeps working.
budgetCap :: Int
budgetCap = 16384

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
--
-- Func-spec 0021 adds five rows and nothing else — which is the whole
-- point of the closed influence surface: an element's blast radius is one
-- table, so growing the vocabulary from four to nine costs five lines
-- here and zero elsewhere in the fold.
--
-- The blend column is deliberately split 5 alpha / 4 additive, so any
-- composition mixing the two groups produces a 'Magic.Interface'
-- 'RenderBatch' run with more than one blend — the material func-spec
-- 0015 §8-5 booked for the batch-splitting machinery it had already
-- delivered. 陰 wants a subtractive blend and gets a dark low-alpha ramp
-- instead: a third 'BlendMode' is a C-ABI change and belongs to a spec
-- that knows it is making one (func-spec 0021 §2.3).
elementAppearance :: Element -> Appearance
elementAppearance element = case element of
  Neutral -> Appearance (ColorRamp 0xFFFFFFFF 0xFFFFFFFF) 0.05 BlendAlpha Nothing BillboardSquare
  Fire -> Appearance (ColorRamp 0xFFD966FF 0xE6390000) 0.05 BlendAdditive Nothing BillboardSquare
  Water -> Appearance (ColorRamp 0x66CCFFFF 0x1A4DCC33) 0.05 BlendAlpha Nothing BillboardSquare
  Lightning -> Appearance (ColorRamp 0xFFFFCCFF 0x8033FF66) 0.05 BlendAdditive Nothing BillboardSquare
  -- 金: sharp specular highlight; additive blows the overlaps out to white.
  Metal -> Appearance (ColorRamp 0xFFF2CCFF 0xB38F1A66) 0.05 BlendAdditive Nothing BillboardSquare
  -- 木: growth and occlusion — additive would make green glow, not grow.
  Wood -> Appearance (ColorRamp 0x99E680FF 0x2E661A33) 0.05 BlendAlpha Nothing BillboardSquare
  -- 土: heavy and opaque; alpha is its meaning here, not a concession.
  Earth -> Appearance (ColorRamp 0xD9B380FF 0x59401A00) 0.05 BlendAlpha Nothing BillboardSquare
  -- 陰: swallows light — a dark ramp fading to nothing.
  Yin -> Appearance (ColorRamp 0x6633AAFF 0x0D0A1A00) 0.05 BlendAlpha Nothing BillboardSquare
  -- 陽: emits light, 陰's opposite number.
  Yang -> Appearance (ColorRamp 0xFFFFE0FF 0xFFCC4D00) 0.05 BlendAdditive Nothing BillboardSquare

-- | Blend mode of the spell's render batch (first emitter's — always the
-- casting emitter, spec 0006 keeps index 0 reserved for it; the shell
-- reads this through 'Magic.Interface').
spellBlend :: CompiledSpell -> BlendMode
spellBlend spell = case V.toList (spellEmitters spell) of
  (em : _) -> appBlend (emAppearance em)
  [] -> BlendAlpha

-- | Whether this spell's sampling has to produce velocity columns
-- (func-spec 0023 S2): it does exactly when some emitter draws as a
-- 'BillboardTrail', because that is the only shape whose geometry reads
-- them.
--
-- Derived from 'spellEmitters' rather than stored as a field of
-- 'CompiledSpell'. Two reasons, and both are about not adding a second
-- source of truth: a stored flag could disagree with the emitters after
-- 'compileMany' concatenates two spells, and the derivation is a walk
-- over a handful of emitters once per frame, next to nothing beside the
-- per-particle work it decides. The @Semigroup@ instance therefore needs
-- no clause for it — @any@ over a concatenation is the disjunction of the
-- parts, for free.
spellNeedsVelocity :: CompiledSpell -> Bool
spellNeedsVelocity =
  V.any ((== BillboardTrail) . appShape . emAppearance) . spellEmitters

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
      (motion, styleShape) =
        foldRing applyOuter (outerRings circle) (defaultMotion modulated, BillboardSquare)
      envelope = bpEnvelope modulated
      Seconds delay = envDelay envelope
      Seconds duration = envDuration envelope
      Seconds lifetime = envLifetime envelope
      count = ssCount (bpSeed modulated)
      -- The whole cast's end (= 'ppEnd'): the moment the last casting
      -- particle dies. Func-spec 0017 hands it to step 5 so the sigil
      -- lives exactly as long as the spell does.
      spellEnd = Seconds (delay + duration + lifetime)
      Seconds spellEndD = spellEnd
      -- The sigil's own end (func-spec 0026 §4). Without a @sigil@ key,
      -- and with @phases@ absent, this is @spellEnd@ to the bit — which
      -- is what makes the zero-ripple law hold by construction rather
      -- than by a test that happens to pass: the whole expression below
      -- degenerates to the pre-0026 one.
      --
      -- @max drawEnd@ is the floor: however negative the shift, the
      -- sigil is drawn to completion. The codec caps the magnitude; this
      -- is the other end of the same gate.
      sigilEnd = case (mPhases, circleSigil circle) of
        (Just pc, Just st) ->
          let Seconds lingerD = stLinger st
              Seconds drawEndD = phDraw pc
           in Seconds (max drawEndD (spellEndD + lingerD))
        _ -> spellEnd
      Seconds sigilEndD = sigilEnd
      castingEmitterAt anchor n =
        EmitterSpec
          { emAnchor = anchor
          , emCount = n
          , emSpawn = envelope
          , emMotion = motion
          , emAppearance = (ssAppearance (bpSeed modulated)) {appShape = styleShape}
          , emPhase = Casting
          , emCode = noEmitterCode
          }
      -- Func-spec 0025 S4. @Nothing@ branches around the split entirely
      -- (rather than splitting into one part), which is what makes the
      -- opt-in law hold by construction: every pre-0025 circle produces
      -- the very expression it always did.
      castingEmitters = case circleAnchors circle of
        Nothing -> [castingEmitterAt originAnchor count]
        Just anchors -> zipWith castingEmitterAt anchors (shareCount count (length anchors))
      formationEmitters = case mPhases of
        Nothing -> []
        Just _ -> formationEmittersFor circle castStart sigilEnd element
      element = essenceElementOf (core circle)
      allEmitters = map compileEmitterExprs (castingEmitters ++ formationEmitters)
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
          , -- Whichever outlives the other. The three landmarks above
            -- belong to the spell body and do not move: a lingering
            -- sigil does not delay the cast, it only outstays it.
            ppEnd = Seconds (max spellEndD sigilEndD)
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

-- | Compile several circles and compose them into one spell (func-spec
-- 0012 S3): every circle compiles on its own, the results are merged with
-- the 'Monoid' instance in list order, and the /composed/ total is
-- checked against 'budgetCap' — so two circles that each fit may still be
-- refused together, with the same 'BudgetExceeded' constructor carrying
-- the combined demand.
--
-- Laws (@test\/ComposeBudgetSpec.hs@):
--
-- > compileMany []  == Right mempty
-- > compileMany [c] == compile c
--
-- The second holds because a single circle's own budget check is the
-- composed check, and @mconcat [x] == x@.
compileMany :: [Circle] -> Either CompileError CompiledSpell
compileMany circles = do
  spells <- traverse compile circles
  let composed = mconcat spells
      total = spellBudget composed
  if total > budgetCap
    then Left (BudgetExceeded total budgetCap)
    else Right composed

-- | Run architecture §8.2's whole acceleration ladder over every formula an
-- emitter carries: fold the constants (func-spec 0010 S6), then share and
-- flatten into bytecode (func-spec 0022 S3, @foldConstants → cse →
-- compileExpr@).
--
-- Compile time is where a player's arithmetic should be paid for — once —
-- rather than once per particle per frame. Every rung of the ladder
-- preserves evaluation bit for bit, so all of this is invisible to every
-- sampled buffer; that is the whole claim, and @test\/ExprCodeWiringSpec.hs@
-- is where it is cashed.
compileEmitterExprs :: EmitterSpec -> EmitterSpec
compileEmitterExprs em = folded {emCode = emitterCodeOf folded}
  where
    folded = foldEmitterExprs em

-- | The constant-folding half, kept separate so the ordering
-- @fold → compile@ is visible rather than implied.
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
-- Also the value a circle without 'Magic.Circle.circleAnchors' casts
-- from, which is what makes the opt-in case the pre-0025 one exactly.
originAnchor :: Anchor
originAnchor = Anchor {anchorOffset = V3 0 0 0, anchorNormal = V3 0 0 1}

-- | Split a particle count over @n@ activation points — the energy
-- equipartition law of func-spec 0025 §2.6.
--
-- The same energy leaves from @n@ places, so the parts sum to @count@
-- /exactly/: @spellBudget@ of an @n@-anchor circle equals that of the
-- same circle with one anchor, and @budgetCap@ therefore stays the only
-- gate on how much a spell may cost. Adding an activation point is a
-- choice of shape, never of strength — 'Magic.Rune.essPower' remains the
-- one parameter that buys power, and it still runs into the cap.
--
-- The remainder goes to the leading parts, so every part is @count \`div\`
-- n@ or one more, and the split is a deterministic function of
-- @(count, n)@ alone. When @count < n@ the trailing anchors get 0
-- particles: a legal emitter that samples nothing, rather than a
-- compile error — the codec's 16-anchor ceiling is what keeps that from
-- being anyone's normal case.
shareCount :: Int -> Int -> [Int]
shareCount count n
  | n <= 0 = []
  | otherwise = [base + (if i < remainder then 1 else 0) | i <- [0 .. n - 1]]
  where
    (base, remainder) = count `divMod` n

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
-- spawn pattern, radiation reference and spawn-range curve, and (spec
-- 0015) the billboard form the casting appearance ends up with. Same
-- override rule as every ring: layer B is applied after A, so a second
-- 'StyleRune' wins.
applyOuter :: (Motion, BillboardShape) -> OuterRune -> (Motion, BillboardShape)
applyOuter (motion, style) rune = case rune of
  ShapeRune shape -> (motion {motSpawn = SpawnOnShape shape}, style)
  RadiateRune mode -> (motion {motRadiation = mode}, style)
  RangeRune e -> (motion {motRange = Just e}, style)
  StyleRune shape -> (motion, shape)

-- | Apply a ring's two layers in order: A (inner) first, then B (outer).
foldRing :: (b -> a -> b) -> TwoOf (Maybe a) -> b -> b
foldRing f (TwoOf a b) z = foldSlot f b (foldSlot f a z)

foldSlot :: (b -> a -> b) -> Maybe a -> b -> b
foldSlot f slot z = maybe z (f z) slot

-- Fold step 5 — formation geometry emitters (spec 0006 §4.4) -----------------

-- | Circle geometry → the formation-drawing emitters. Only called when
-- 'circlePhases' is 'Just'.
--
-- Func-spec 0016 replaces 0006's fixed table of concentric bands with
-- 'Magic.Sigil.sigilPlan': the geometry is now derived from the circle
-- itself (structure picks the skeleton, the circle's digest picks the
-- ornament), and each stroke of the plan becomes one emitter. Settling
-- the budget, culling dead time windows and grouping render batches all
-- stay per-emitter, so a stroke pays exactly what a ring band used to —
-- and 'Magic.Sigil.sampleStroke' stays O(1) with no prefix sums.
--
-- What 0006 keeps: the boundary group is unconditional ("陣" always has
-- a silhouette, even the all-empty circle), the four node emitters and
-- the center emitter keep their coordinate table and particle counts, and
-- an outer slot holding a 'ShapeRune' still previews the player's own
-- shape (§4.4's exception, now carried by 'spShapes').
--
-- Func-spec 0017 gives every one of these emitters the whole cast to live
-- in (@spellEnd@ = 'ppEnd') instead of dying at @castStart@, and drops the
-- synthesized convergence curve: the spell is now fired /out of/ a sigil
-- that is still there, rather than consuming it.
-- Func-spec 0026 makes that third argument the /sigil's/ end rather than
-- the spell's: they are the same value unless the circle names a
-- @linger@, and the signature does not move.
formationEmittersFor :: Circle -> Seconds -> Seconds -> Element -> [EmitterSpec]
formationEmittersFor circle castStart sigilEnd element =
  concat
    [ [ringSlotEmitter (skCount sk) (SpawnOnStroke sk) | sk <- V.toList (spStrokes plan)]
    , [ringSlotEmitter cnt (SpawnOnShape shape) | (shape, cnt) <- V.toList (spShapes plan)]
    , nodeSlotEmitter 12 (V3 0 0.35 0) (north (coreNodes (core circle)))
    , nodeSlotEmitter 12 (V3 0 (-0.35) 0) (south (coreNodes (core circle)))
    , nodeSlotEmitter 12 (V3 0.35 0 0) (east (coreNodes (core circle)))
    , nodeSlotEmitter 12 (V3 (-0.35) 0 0) (west (coreNodes (core circle)))
    , centerSlotEmitter 16 (coreCenter (core circle))
    ]
  where
    plan = sigilPlan circle
    formEnv = formEnvFor castStart sigilEnd
    appearance = formationAppearance (maybe False stHold (circleSigil circle)) element

    ringSlotEmitter cnt spawn =
      EmitterSpec
        { emAnchor = originAnchor
        , emCount = cnt
        , emSpawn = formEnv
        , emMotion = formationMotion spawn
        , emAppearance = appearance
        , emPhase = Drawing
        , emCode = noEmitterCode
        }

    nodeSlotEmitter :: Int -> V3 -> Maybe NodeRune -> [EmitterSpec]
    nodeSlotEmitter cnt offset mRune = case mRune of
      Nothing -> []
      Just _ ->
        [ EmitterSpec
            { emAnchor = Anchor {anchorOffset = offset, anchorNormal = V3 0 0 1}
            , emCount = cnt
            , emSpawn = formEnv
            , emMotion = formationMotion (SpawnAtAnchor 0)
            , emAppearance = appearance
            , emPhase = Drawing
            , emCode = noEmitterCode
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
            , emMotion = formationMotion (SpawnAtAnchor 0)
            , emAppearance = appearance
            , emPhase = Drawing
            , emCode = noEmitterCode
            }
        ]

-- | Formation particles hold the position they were drawn at.
--
-- @motConverge = Nothing@ is the func-spec 0017 decision: the sigil no
-- longer collapses onto the axis at @castStart@. The spell is fired out
-- of a circle that is still there, so there is nothing to converge —
-- and the sampler's existing "no modulation" branch is all it takes.
-- (A player's own 'Magic.Rune.ConvergeRune' is untouched by this: spec
-- 0004 froze it as a casting-emitter curve, and it still is one.)
formationMotion :: SpawnPattern -> Motion
formationMotion spawn =
  Motion
    { motSpawn = spawn
    , motTraject = Forward 0
    , motRadiation = AlongNormal
    , motDrift = V3 0 0 0
    , motRange = Nothing
    , motConverge = Nothing
    }

-- | The formation particles' envelope. @castStart@ sets the /pace/ the
-- sigil is drawn at, the second argument sets how long it stays.
--
-- Derivation (func-spec 0017 §2, re-proving spec 0006 §4.3's chain with
-- the new endpoint):
--
-- 1. the birth stagger spans 'envLifetime' = @formLife@, and
--    @formLife <= castStart - formLife <= spellEnd - formLife@ =
--    'envDuration', so /every index is born/ — unchanged from 0006;
-- 2. the last batch is born before @spellEnd - formLife@ and so dies by
--    @spellEnd@ exactly: the sigil and the spell end together;
-- 3. @formLife@ is capped at 0.6s and derived from @castStart@ alone, so
--    the drawing pace is bit-for-bit what it was — 'firstBirth' reads
--    'envDelay' and 'envLifetime' and never 'envDuration', which is why
--    holding the sigil for the whole cast costs nothing in the Drawing
--    window and why it keeps pulsing (redrawing itself every @formLife@)
--    rather than freezing.
--
-- Func-spec 0026 hands it the /sigil's/ end instead, which is the same
-- number unless the circle names a @linger@; step 2 above then reads
-- "the sigil ends where it was told to". Nothing in the body changes,
-- for the reason step 3 gives: only 'envDuration' depends on this
-- argument, and only the far end of the sigil's life depends on
-- 'envDuration'.
formEnvFor :: Seconds -> Seconds -> Envelope
formEnvFor (Seconds castStartD) (Seconds sigilEndD) =
  let formLife = min 0.6 (castStartD / 2)
   in Envelope
        { envDelay = Seconds 0
        , envDuration = Seconds (max 0 (sigilEndD - formLife))
        , envLifetime = Seconds formLife
        }

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
      SpawnOnStroke stroke -> rangeScale * strokeRadius stroke

    trajectoryRadius = case trajectory of
      Forward speed -> abs (realToFrac speed) * maxAge
      Spiral speed radius' _ -> abs (realToFrac speed) * maxAge + abs (realToFrac radius')
      Orbit radius' _ -> abs (realToFrac radius')
      Formula (ExprV3 x y z) ->
        maxMagnitude (evalInterval x ageEnv)
          + maxMagnitude (evalInterval y ageEnv)
          + maxMagnitude (evalInterval z ageEnv)
      -- Func-spec 0021: same rule as the shapes — over-estimating is
      -- allowed, under-estimating is the bug the culling cannot survive.
      Wave speed amplitude _ ->
        abs (realToFrac speed) * maxAge + abs (realToFrac amplitude)
      -- |v₀t − gt²/2| <= |v₀|t + |g|t²/2 over the whole horizon.
      Ballistic speed gravity ->
        abs (realToFrac speed) * maxAge
          + abs (realToFrac gravity) * maxAge * maxAge / 2
      -- Speed is mean·(1 − cos) ∈ [0, 2·mean], so the displacement can
      -- never outrun twice the mean over the age.
      Pulse meanSpeed _ -> 2 * abs (realToFrac meanSpeed) * maxAge
      Zigzag speed amplitude _ ->
        abs (realToFrac speed) * maxAge + abs (realToFrac amplitude)

    -- The per-particle drift spread draws its two coefficients from
    -- 'Magic.Types.hashChan' shifted to [-0.5, 0.5].
    spreadRadius = case spawnPattern of
      SpawnAtAnchor spread -> abs spread
      SpawnOnShape _ -> 0
      SpawnOnStroke _ -> 0
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
--
-- Under-estimating here is the one failure mode the compiler cannot
-- catch (func-spec 0021 §2.2): a missing case is an exhaustiveness error,
-- but a bound that is too small type-checks and then makes a host's
-- frustum culling drop emitters that are still on screen. Each 0021
-- radius takes the /max/ of the radii it was given rather than assuming
-- the codec's ordering validation, so the bound holds for any value of
-- the constructor, not just the ones that survive 'Magic.Codec'.
shapeRadius :: FaceShape -> Float
shapeRadius shape = case shape of
  Ring rInner rOuter -> max (abs (realToFrac rInner)) (abs (realToFrac rOuter))
  Diamond size -> 2 * abs (realToFrac size)
  Rect (V2 w h) -> (abs w + abs h) / 2
  HollowSquare size -> abs (realToFrac size)
  -- Every sample is a convex combination of the origin and two vertices,
  -- all of which sit at the circumradius.
  Polygon _ radius' -> abs (realToFrac radius')
  Star _ rOuter rInner -> max (abs (realToFrac rOuter)) (abs (realToFrac rInner))
  -- The far corner of an arm: half a width off the axis, a whole length
  -- along it.
  Cross len width -> sqrt (l * l + (halfW * halfW))
    where
      l = abs (realToFrac len) :: Float
      halfW = abs (realToFrac width) / 2
  Sector rInner rOuter _ -> max (abs (realToFrac rInner)) (abs (realToFrac rOuter))

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
-- Always 'BillboardSquare', 'StyleRune' or not: a drawn line wants hard
-- dots to stay sharp (spec 0015 §2), and this is what keeps the shape
-- vocabulary opt-in for every pre-0015 circle.
--
-- Func-spec 0026 adds the @hold@ branch, and it is the whole of "freeze
-- once drawn". Every other term of a formation particle's position is
-- age-free — the spin runs off the cast clock (ADR-0020), the trajectory
-- is @Forward 0@, spread and drift are zero, and there is neither a
-- range curve nor a convergence one — so the only observable the
-- @formLife@ rebirth cycle drives is this ramp. Flatten it and the cycle
-- becomes unobservable: the particles still die and are reborn, they
-- just look the same on both sides of the boundary.
--
-- 'Magic.Particle.Analytic.firstBirth' is untouched, so the first
-- @formLife@ still lays the sigil down one index at a time — spec 0016's
-- "index order is drawing order" survives verbatim, which is what makes
-- this the literal reading of /draw, then freeze/. At the far end the
-- spawn window closes and each particle vanishes on its own cycle
-- boundary, in index order: with the fade gone that reads as the sigil
-- being erased in the order it was drawn, which is the symmetric ending
-- and costs no code.
formationAppearance :: Bool -> Element -> Appearance
formationAppearance hold element =
  let Appearance (ColorRamp start _) _ blend _ _ = elementAppearance element
      end = if hold then start else clearAlpha start
   in Appearance (ColorRamp start end) 0.03 blend Nothing BillboardSquare
  where
    clearAlpha c = c .&. 0xFFFFFF00
