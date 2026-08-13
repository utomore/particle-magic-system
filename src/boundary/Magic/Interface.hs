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

import Magic.Circle (Circle, emptyCircle)
import Magic.Compile
  ( BlendMode (..)
  , CompileError (..)
  , CompiledSpell (..)
  , compile
  , spellBlend
  )
import Magic.Particle.Analytic (sample)
import Magic.Particle.Buffer (ParticleBuffer (..))
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

-- | A cast spell. Opaque to the shell: the only skeleton state is the
-- time advanced since casting — 'stepSpell' is a pure state transition
-- returning a new value, never a mutated reference.
data ActiveSpell = ActiveSpell
  { asSpell :: !CompiledSpell
  , asCtx :: !CastContext
  , asElapsed :: !Double
  }

castSpell :: CastRequest -> Either CompileError ActiveSpell
castSpell req = do
  compiled <- compile (circleOf req)
  pure ActiveSpell {asSpell = compiled, asCtx = ctxOf req, asElapsed = 0}

-- | Advance the spell's clock. Pure state transition, no sampling
-- (func-spec 0005 §4.1).
advanceSpell :: FrameInput -> ActiveSpell -> ActiveSpell
advanceSpell (FrameInput (DeltaTime dt)) spell =
  spell {asElapsed = asElapsed spell + dt}

-- | Sample the spell at its current age. Pure observation, no time
-- advance (func-spec 0005 §4.1) — so a host that runs several fixed
-- simulation steps per rendered frame pays for exactly one sampling.
observeSpell :: ActiveSpell -> FrameOutput
observeSpell spell =
  let buffer = sample (asSpell spell) (asCtx spell) (Time (asElapsed spell))
      batch =
        RenderBatch
          { rbParticles = buffer
          , rbBlend = spellBlend (asSpell spell)
          , rbShape = BillboardSquare
          }
   in FrameOutput {batches = [batch]}

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
