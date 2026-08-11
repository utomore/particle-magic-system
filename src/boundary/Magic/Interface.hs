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
  , isFinished
  , spellAge
  ) where

import Magic.Circle (Circle, emptyCircle)
import Magic.Compile (CompileError (..), CompiledSpell (..), compile)
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

-- | How a batch should be blended by the renderer.
data BlendMode = BlendAlpha | BlendAdditive
  deriving (Eq, Show)

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

stepSpell :: FrameInput -> ActiveSpell -> (ActiveSpell, FrameOutput)
stepSpell (FrameInput (DeltaTime dt)) spell =
  let elapsed' = asElapsed spell + dt
      spell' = spell {asElapsed = elapsed'}
      buffer = sample (asSpell spell) (asCtx spell) (Time elapsed')
      batch =
        RenderBatch
          { rbParticles = buffer
          , rbBlend = BlendAlpha
          , rbShape = BillboardSquare
          }
   in (spell', FrameOutput {batches = [batch]})

isFinished :: ActiveSpell -> Bool
isFinished spell =
  let Seconds lifetime = spellLifetime (asSpell spell)
   in asElapsed spell >= lifetime

-- | Seconds since this spell was cast. Read-only observer (useful to
-- hosts and to the hot-reload tests: a re-cast spell starts at age 0).
spellAge :: ActiveSpell -> Time
spellAge = Time . asElapsed
