-- | The system's single public entry point (architecture §5.3, func-spec
-- 0001 §4.6). Permanent contract — frozen once spec 0001 is delivered.
--
-- The shell (and any future host game) imports ONLY this module,
-- 'Magic.Codec' and 'Magic.Step'. It re-exports every type the shell
-- needs; 'ParticleBuffer' is exported as a read-only view (fields, no
-- constructor), and 'ActiveSpell' is fully opaque.
module Magic.Interface
  ( -- * Core vocabulary re-exports
    V3 (..)
  , Time (..)
  , DeltaTime (..)
  , Seconds (..)
  , Seed (..)
  , CastContext (..)
  , Circle
  , emptyCircle
  , CompileError (..)

    -- * Particle buffer (read-only view)
  , ParticleBuffer (pbPosX, pbPosY, pbPosZ, pbSize, pbLife, pbColor, pbCount)

    -- * System input
  , CastRequest (..)
  , FrameInput (..)

    -- * System output (dimension-agnostic)
  , FrameOutput (..)
  , RenderBatch (..)
  , BlendMode (..)
  , BillboardShape (..)

    -- * Spell lifecycle
  , ActiveSpell
  , castSpell
  , castSpells
  , stepSpell
  , advanceSpell
  , observeSpell
  , isFinished
  , spellAge

    -- * Particle budget and spatial extent (func-spec 0010 S7)
  , ParticleBudget (..)
  , budgetPlanOf
  , maxSpellParticles
  , EmitterSpec
  -- ^ Opaque here: a host receives these from 'emittersOf' and hands
  -- them back to 'emitterBounds'; building one is the compiler's job.
  , emittersOf
  , emitterBounds
  ) where

import Control.Monad.ST (runST)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MU
import Magic.Circle (Circle, emptyCircle)
import Magic.Compile
  ( Appearance (appBlend, appShape)
  , BillboardShape (..)
  , BlendMode (..)
  , CompileError (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , ParticleBudget (..)
  , Phase (Casting)
  , budgetCap
  , compile
  , compileMany
  , emitterBounds
  )
import Magic.Particle.Analytic
  ( aliveRanges
  , aliveSlotIndices
  , emitterOffsets
  , particleAge
  , particlePosition
  , sample
  )
import Magic.Particle.Buffer (ParticleBuffer (..))
import qualified Magic.Particle.Field as Field
import Magic.Particle.Field (FieldState)
import Magic.Types
  ( CastContext (..)
  , DeltaTime (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  )

-- 'BillboardShape' is defined in the core's "Magic.Rune" since spec 0015
-- (it became player vocabulary) and re-exported here unchanged — the
-- host-visible surface is the same text it has been since 0005.

data CastRequest = CastRequest
  { circleOf :: Circle
  , ctxOf :: CastContext
  }
  deriving (Eq, Show)

newtype FrameInput = FrameInput
  { frameDt :: DeltaTime
  }
  deriving (Eq, Show)

newtype FrameOutput = FrameOutput
  { batches :: [RenderBatch]
  }
  deriving (Eq, Show)

-- | Dimension-agnostic render payload: abstract 3D coordinates, no
-- renderer types (architecture §5.2).
data RenderBatch = RenderBatch
  { rbParticles :: ParticleBuffer
  , rbBlend :: BlendMode
  , rbShape :: BillboardShape
  }
  deriving (Eq, Show)

-- | A cast spell. Opaque to the shell: the skeleton state is the time
-- advanced since casting plus (spec 0007) the force-field layer's
-- integration state — 'stepSpell' is a pure state transition returning a
-- new value, never a mutated reference.
data ActiveSpell = ActiveSpell
  { asSpell :: !CompiledSpell
  , asCtx :: !CastContext
  , asElapsed :: !Double
  , asField :: !FieldState
  -- ^ The system's only cross-frame state (spec 0007). Never leaves this
  -- module: a fresh cast starts it at rest, and since a hot reload is a
  -- re-cast (architecture §8.3, ADR-0010 D8) it is never migrated.
  }

castSpell :: CastRequest -> Either CompileError ActiveSpell
castSpell req = activate (ctxOf req) <$> compile (circleOf req)

-- | Cast several circles as one composed spell (func-spec 0012 S3): the
-- multi-circle entry point, and the only form in which composition
-- reaches a host — 'Magic.Compile.compileMany' composes
-- @CompiledSpell@s, which this layer deliberately keeps out of its
-- vocabulary.
--
-- The composed cast behaves as the superposition of its components
-- (func-spec 0012 §1-5): the sampled buffer is each component's rows,
-- concatenated in list order. Two deliberate exceptions, both of them
-- ADR-0012 decisions rather than accidents: force fields fuse (every
-- component's fields act on every component's casting particles), and the
-- batch's blend mode is the first component's, since a spell renders as
-- one batch (architecture §10).
--
-- > castSpells [c] ctx == castSpell (CastRequest c ctx)
-- > castSpells []  ctx  -- a spell with no particles that is finished at once
castSpells :: [Circle] -> CastContext -> Either CompileError ActiveSpell
castSpells circles ctx = activate ctx <$> compileMany circles

-- | A compiled spell plus the cast it belongs to, clock at zero and the
-- force-field layer at rest (ADR-0010 D8).
activate :: CastContext -> CompiledSpell -> ActiveSpell
activate ctx compiled =
  ActiveSpell
    { asSpell = compiled
    , asCtx = ctx
    , asElapsed = 0
    , asField = Field.emptyFieldState (map emCount (V.toList (spellEmitters compiled)))
    }

-- | Advance the spell's clock, and with it the force-field integration
-- (one fixed step per call — func-spec 0005's @advanceSpell ×n@ loop is
-- exactly the fixed-timestep carrier ADR-0010 D1 needs). Pure state
-- transition, no sampling (func-spec 0005 §4.1).
--
-- A fieldless spell takes the ADR-0010 D9 fast path: the state is carried
-- through untouched, and not one field computation runs.
advanceSpell :: FrameInput -> ActiveSpell -> ActiveSpell
advanceSpell (FrameInput dt@(DeltaTime dtSeconds)) spell =
  case spellFields (asSpell spell) of
    [] -> advanced
    fields ->
      advanced
        { asField =
            Field.stepColumns
              fields
              dt
              (fieldInputs (asSpell spell) (asCtx spell) (Time elapsed'))
              (asField spell)
        }
  where
    elapsed' = asElapsed spell + dtSeconds
    advanced = spell {asElapsed = elapsed'}

-- | This step's @(age, analytic base position)@ per stable slot, in the
-- 'FieldState' flattening (emitter by emitter, index ascending), written
-- straight into unboxed columns (func-spec 0010 S4 — the pre-0010 version
-- rebuilt a nested boxed vector of @Maybe@ every step).
--
-- Only 'Casting' emitters are reported alive: formation particles draw
-- the circle's geometry and must stay legible, so the fields do not touch
-- them (ADR-0010 D6). A circle without phases has a single casting
-- emitter, which makes the rule a no-op there. Dead slots keep the
-- negative-age sentinel the columns are initialized with, so the walk
-- only visits the live index windows.
fieldInputs :: CompiledSpell -> CastContext -> Time -> Field.FieldInputs
fieldInputs spell ctx t = runST $ do
  age <- MU.replicate n (-1)
  px <- MU.replicate n 0
  py <- MU.replicate n 0
  pz <- MU.replicate n 0
  let goEmitter e
        | e >= V.length ems = pure ()
        | otherwise = do
            let em = ems V.! e
                base = offsets U.! e
            if emPhase em /= Casting
              then pure ()
              else
                mapM_
                  (\(lo, hi) -> goIndex em base lo hi)
                  (aliveRanges (emSpawn em) (emCount em) t)
            goEmitter (e + 1)
      goIndex em base i hi
        | i >= hi = pure ()
        | otherwise = do
            case particleAge (emSpawn em) (emCount em) i t of
              Nothing -> pure ()
              Just a -> do
                let V3 x y z = particlePosition ctx t em i a
                    j = base + i
                MU.write age j a
                MU.write px j x
                MU.write py j y
                MU.write pz j z
            goIndex em base (i + 1) hi
  goEmitter 0
  Field.FieldInputs offsets
    <$> U.unsafeFreeze age
    <*> U.unsafeFreeze px
    <*> U.unsafeFreeze py
    <*> U.unsafeFreeze pz
  where
    ems = spellEmitters spell
    offsets = emitterOffsets spell
    n = if U.null offsets then 0 else U.last offsets

-- | Sample the spell at its current age. Pure observation, no time
-- advance (func-spec 0005 §4.1) — so a host that runs several fixed
-- simulation steps per rendered frame pays for exactly one sampling.
--
-- The force-field layer is an additive overlay on that sample (ADR-0010
-- D1): the accumulated displacements are lined up with the buffer's rows
-- through 'aliveSlots', the single enumeration @sample@ itself defines.
-- With no fields the buffer is returned exactly as sampled (D9).
--
-- Since func-spec 0015 the output is one batch per run of adjacent
-- same-looking emitters, not always one batch — see 'splitBatches' for
-- the splitting law. The signature and 'FrameOutput' are unchanged;
-- @batches@ was always a list.
observeSpell :: ActiveSpell -> FrameOutput
observeSpell spell =
  let t = Time (asElapsed spell)
      sampled = sample (asSpell spell) (asCtx spell) t
      buffer = case spellFields (asSpell spell) of
        [] -> sampled
        _ ->
          let slots = aliveSlotIndices (asSpell spell) t
              (dx, dy, dz) = Field.displacementColumns (asField spell) slots
           in displaceBuffer sampled dx dy dz
   in FrameOutput {batches = splitBatches (asSpell spell) t buffer}

-- | Cut the sampled buffer into render batches: adjacent emitters with
-- the same @(appBlend, appShape)@ merge into one batch, in emitter order
-- (func-spec 0015 S1).
--
-- Splitting law: @concat (map rbParticles batches)@ is the input buffer,
-- bit for bit, six columns, rows in order — structural, because the
-- buffer's rows are the emitters' rows concatenated in emitter order
-- (0010's @sample@), so a run of adjacent emitters IS a contiguous slice.
-- Equal keys that are /not/ adjacent deliberately stay separate batches:
-- merging them would reorder rows and break both the law and the
-- 'aliveSlotIndices' alignment. Slices are 'U.slice' — zero copies.
--
-- A spell with no emitters (@mempty@, e.g. @castSpells []@) has zero
-- batches; every compiled circle has at least the casting emitter and so
-- at least one batch, even when no particle is currently alive.
splitBatches :: CompiledSpell -> Time -> ParticleBuffer -> [RenderBatch]
splitBatches compiled t buffer =
  [ RenderBatch
      { rbParticles = sliceBuffer offset len buffer
      , rbBlend = blend
      , rbShape = shape
      }
  | ((blend, shape), offset, len) <- placed
  ]
  where
    keyed =
      [ ((appBlend look, appShape look), rows)
      | em <- V.toList (spellEmitters compiled)
      , let look = emAppearance em
            rows = sum [hi - lo | (lo, hi) <- aliveRanges (emSpawn em) (emCount em) t]
      ]
    grouped = foldr mergeRun [] keyed
    mergeRun (key, n) ((key', n') : rest) | key == key' = (key, n + n') : rest
    mergeRun kn rest = kn : rest
    placed =
      zipWith
        (\(key, n) offset -> (key, offset, n))
        grouped
        (scanl (+) 0 (map snd grouped))

-- | One contiguous row window of the buffer, as a buffer: each of the six
-- columns sliced in place (no copy), the count the window's length.
sliceBuffer :: Int -> Int -> ParticleBuffer -> ParticleBuffer
sliceBuffer offset len pb =
  ParticleBuffer
    { pbPosX = cut (pbPosX pb)
    , pbPosY = cut (pbPosY pb)
    , pbPosZ = cut (pbPosZ pb)
    , pbSize = cut (pbSize pb)
    , pbLife = cut (pbLife pb)
    , pbColor = cut (pbColor pb)
    , pbCount = len
    }
  where
    cut :: (U.Unbox a) => U.Vector a -> U.Vector a
    cut = U.slice offset len

-- | Add one displacement column per position column. Row count, sizes,
-- life fractions and colors are untouched, so the
-- 'Magic.Particle.Buffer.bufferInvariant' carries over; a short
-- displacement column (which the alignment law rules out) contributes
-- zeros past its end rather than truncating the buffer.
--
-- Zero is still /added/ in that tail rather than skipped: @-0.0 + 0.0@ is
-- @0.0@, so skipping would change a bit the pre-0010 padded @zipWith@
-- did not.
displaceBuffer
  :: ParticleBuffer -> U.Vector Float -> U.Vector Float -> U.Vector Float -> ParticleBuffer
displaceBuffer buffer dx dy dz =
  buffer
    { pbPosX = add (pbPosX buffer) dx
    , pbPosY = add (pbPosY buffer) dy
    , pbPosZ = add (pbPosZ buffer) dz
    }
  where
    add col d =
      U.imap (\i v -> v + (if i < U.length d then U.unsafeIndex d i else 0)) col

-- | Advance then observe. Decomposition law (func-spec 0005 §4.1, guarded
-- by @test\/StepObserveSpec.hs@):
--
-- > stepSpell fi s == let s' = advanceSpell fi s in (s', observeSpell s')
stepSpell :: FrameInput -> ActiveSpell -> (ActiveSpell, FrameOutput)
stepSpell fi spell =
  let spell' = advanceSpell fi spell
   in (spell', observeSpell spell')

isFinished :: ActiveSpell -> Bool
isFinished spell =
  let Seconds lifetime = spellLifetime (asSpell spell)
   in asElapsed spell >= lifetime

-- | Seconds since this spell was cast. Read-only observer (useful to
-- hosts and to the hot-reload tests: a re-cast spell starts at age 0).
spellAge :: ActiveSpell -> Time
spellAge = Time . asElapsed

-- Budget and extent (func-spec 0010 S7) ---------------------------------------

-- | This cast's particle budget, per emitter and in total — known at
-- compile time, so a host can size its buffers before the first frame is
-- ever sampled.
budgetPlanOf :: ActiveSpell -> ParticleBudget
budgetPlanOf = spellBudgetPlan . asSpell

-- | The most particles any single spell can be compiled to (a compile
-- that would exceed it fails with 'BudgetExceeded') — a composed cast
-- ('castSpells') included: composition is checked against the same cap as
-- a single circle, not a multiple of it.
--
-- Func-spec 0012 raised this constant (4096 → 16384) rather than adding a
-- second one, exactly as func-spec 0010 promised. A host that /asks/ —
-- here or through the C ABI's @pm_max_particles@ — sizes its buffers
-- correctly across the change; one that hard-codes 4096 keeps working for
-- every spell that fitted before.
maxSpellParticles :: Int
maxSpellParticles = budgetCap

-- | The compiled emitters of a cast, in 'ParticleBudget' order — the
-- arguments 'emitterBounds' takes.
emittersOf :: ActiveSpell -> [EmitterSpec]
emittersOf = V.toList . spellEmitters . asSpell
