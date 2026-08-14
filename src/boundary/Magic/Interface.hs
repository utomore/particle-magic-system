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
  , stepSpell
  , advanceSpell
  , observeSpell
  , isFinished
  , spellAge
  ) where

import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle, emptyCircle)
import Magic.Compile
  ( BlendMode (..)
  , CompileError (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Phase (Casting)
  , compile
  , spellBlend
  )
import Magic.Particle.Analytic (aliveSlots, particleAge, particlePosition, sample)
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

-- | Billboard geometry hint for the renderer.
data BillboardShape = BillboardSquare
  deriving (Eq, Show)

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
castSpell req = do
  compiled <- compile (circleOf req)
  pure
    ActiveSpell
      { asSpell = compiled
      , asCtx = ctxOf req
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
            Field.step fields dt (fieldInputs (asSpell spell) (asCtx spell) (Time elapsed')) (asField spell)
        }
  where
    elapsed' = asElapsed spell + dtSeconds
    advanced = spell {asElapsed = elapsed'}

-- | This step's @(age, analytic base position)@ per stable slot, shaped
-- like the 'FieldState' (emitter by emitter, index ascending).
--
-- Only 'Casting' emitters are reported alive: formation particles draw
-- the circle's geometry and must stay legible, so the fields do not touch
-- them (ADR-0010 D6). A circle without phases has a single casting
-- emitter, which makes the rule a no-op there.
fieldInputs :: CompiledSpell -> CastContext -> Time -> V.Vector (V.Vector (Maybe (Double, V3)))
fieldInputs spell ctx t = V.map emitterInputs (spellEmitters spell)
  where
    emitterInputs em
      | emPhase em /= Casting = V.replicate (emCount em) Nothing
      | otherwise = V.generate (emCount em) (slotInput em)

    slotInput em i = case particleAge (emSpawn em) (emCount em) i t of
      Nothing -> Nothing
      Just age -> Just (age, particlePosition ctx t em i age)

-- | Sample the spell at its current age. Pure observation, no time
-- advance (func-spec 0005 §4.1) — so a host that runs several fixed
-- simulation steps per rendered frame pays for exactly one sampling.
--
-- The force-field layer is an additive overlay on that sample (ADR-0010
-- D1): the accumulated displacements are lined up with the buffer's rows
-- through 'aliveSlots', the single enumeration @sample@ itself defines.
-- With no fields the buffer is returned exactly as sampled (D9).
observeSpell :: ActiveSpell -> FrameOutput
observeSpell spell =
  let t = Time (asElapsed spell)
      sampled = sample (asSpell spell) (asCtx spell) t
      buffer = case spellFields (asSpell spell) of
        [] -> sampled
        _ ->
          displaceBuffer
            sampled
            (Field.displacementsInOrder (asField spell) (aliveSlots (asSpell spell) t))
      batch =
        RenderBatch
          { rbParticles = buffer
          , rbBlend = spellBlend (asSpell spell)
          , rbShape = BillboardSquare
          }
   in FrameOutput {batches = [batch]}

-- | Add one displacement per buffer row. Row count, sizes, life fractions
-- and colors are untouched, so the 'Magic.Particle.Buffer.bufferInvariant'
-- carries over; a short displacement list (which the alignment law rules
-- out) pads with zeros rather than truncating the buffer.
displaceBuffer :: ParticleBuffer -> [V3] -> ParticleBuffer
displaceBuffer buffer displacements =
  buffer
    { pbPosX = U.zipWith (+) (pbPosX buffer) (component (\(V3 x _ _) -> x))
    , pbPosY = U.zipWith (+) (pbPosY buffer) (component (\(V3 _ y _) -> y))
    , pbPosZ = U.zipWith (+) (pbPosZ buffer) (component (\(V3 _ _ z) -> z))
    }
  where
    n = pbCount buffer
    component f = U.fromListN n (map f displacements ++ replicate n 0)

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
