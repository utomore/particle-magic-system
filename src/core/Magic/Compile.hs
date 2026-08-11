-- | Circle → CompiledSpell interpreter (func-spec 0001 §4.3).
--
-- ⚠ Stub behavior, permanent interface: @compile@'s 'Either' signature is
-- frozen; the skeleton compiler never fails and maps ANY circle to the
-- plain-discharge fountain ("空陣即素放", architecture §3.3). Spec 0002+
-- replaces the body with the real inside-out fold.
module Magic.Compile
  ( CompiledSpell (..)
  , CompileError (..)
  , compile
  , particleLifetime
  ) where

import Magic.Circle (Circle)
import Magic.Types (Seconds (..))

-- | Result of interpreting a circle. Interface permanent; fields are the
-- skeleton minimum and will grow (emitters, fields, phase plan).
data CompiledSpell = CompiledSpell
  { spellLifetime :: !Seconds
  -- ^ Total spell duration; 'Magic.Interface.isFinished' triggers past it.
  , spellBudget :: !Int
  -- ^ Particle budget (skeleton: fixed 256).
  }
  deriving (Eq, Show)

-- | Compilation failure. The skeleton compiler cannot fail, but the error
-- channel is part of the frozen interface.
newtype CompileError = CompileError String
  deriving (Eq, Show)

-- | Lifetime of an individual fountain particle (seconds). Skeleton
-- constant used by the analytic sampler stub.
particleLifetime :: Double
particleLifetime = 2.0

compile :: Circle -> Either CompileError CompiledSpell
compile _ =
  Right
    CompiledSpell
      { spellLifetime = Seconds 10
      , spellBudget = 256
      }
