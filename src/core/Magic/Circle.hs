-- | The real magic-circle slot structure (spec 0002 §4.1, architecture
-- §4.1). Permanent type — frozen once spec 0002 is delivered.
--
-- The ring-layer layout (outer 2 / interlayer 1 / inner 2 / core) is the
-- hard contract of architecture §11. Every slot is optional and freely
-- combinable; the all-empty circle compiles to a plain magic discharge
-- ("空陣即素放", architecture §3.3) through the same interpreter fold —
-- no special case.
module Magic.Circle
  ( Circle (..)
  , TwoOf (..)
  , Core (..)
  , Nodes (..)
  , PhaseConfig (..)
  , emptyCircle
  ) where

import Magic.Rune (BridgeRune, EssenceRune, ForceField, InnerRune, NodeRune, OuterRune)
import Magic.Types (Seconds)

-- | A fixed pair of ring layers. Convention: 'ringA' is the inner layer,
-- 'ringB' the outer layer — the interpreter folds A before B, and
-- same-kind settings from B override A.
data TwoOf a = TwoOf
  { ringA :: a
  , ringB :: a
  }
  deriving (Eq, Show, Functor)

data Circle = Circle
  { outerRings :: TwoOf (Maybe OuterRune)
  -- ^ Outer ring, 2 layers: presentation.
  , interLayer :: Maybe BridgeRune
  -- ^ Interlayer, 1 layer: modulation.
  , innerRings :: TwoOf (Maybe InnerRune)
  -- ^ Inner ring, 2 layers: behavior.
  , core :: Core
  -- ^ Core: essence.
  , circlePhases :: !(Maybe PhaseConfig)
  -- ^ Lifecycle staging (spec 0006 §3.3). 'Nothing' = instant cast, the
  -- compatibility law's degenerate case; 'emptyCircle' uses it.
  , circleFields :: ![ForceField]
  -- ^ The circle's physical environment (spec 0007, ADR-0010 D4): force
  -- fields acting on the casting particles. Not runes and not in any
  -- slot — a property of the circle as a whole, like 'circlePhases'.
  -- @[]@ (the 'emptyCircle' value) is the zero-field compatibility case:
  -- the whole field layer is branched around, not computed to zero.
  }
  deriving (Eq, Show)

-- | Lifecycle staging of the drawn circle (architecture §3.3). Not a
-- rune: it is a property of the circle as a whole, not of any slot's
-- meaning (ADR-0003 slot responsibility would be broken by parking it on
-- a ring instead).
data PhaseConfig = PhaseConfig
  { phDraw :: !Seconds
  -- ^ Drawing-phase length; the codec validates @> 0@.
  , phConverge :: !Seconds
  -- ^ Converging-phase length; the codec validates @>= 0@ (0 = instant
  -- snap).
  }
  deriving (Eq, Show)

data Core = Core
  { coreCenter :: Maybe EssenceRune
  -- ^ The very center; empty = Neutral plain discharge.
  , coreNodes :: Nodes (Maybe NodeRune)
  -- ^ The four directional nodes around the center.
  }
  deriving (Eq, Show)

-- | The four core node slots (face directions: north = face up,
-- east = face right).
data Nodes a = Nodes
  { north :: a
  , south :: a
  , east :: a
  , west :: a
  }
  deriving (Eq, Show, Functor)

-- | The circle with every slot empty.
emptyCircle :: Circle
emptyCircle =
  Circle
    { outerRings = TwoOf Nothing Nothing
    , interLayer = Nothing
    , innerRings = TwoOf Nothing Nothing
    , core = Core {coreCenter = Nothing, coreNodes = Nodes Nothing Nothing Nothing Nothing}
    , circlePhases = Nothing
    , circleFields = []
    }
