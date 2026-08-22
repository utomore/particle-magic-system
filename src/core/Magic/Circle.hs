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
  , SigilTiming (..)
  , emptyCircle
  ) where

import Magic.Rune (Anchor, BridgeRune, EssenceRune, ForceField, InnerRune, NodeRune, OuterRune)
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
  , circleAnchors :: !(Maybe [Anchor])
  -- ^ Where the main effect comes out (func-spec 0025). The third
  -- circle-level property after 'circlePhases' and 'circleFields', and
  -- it follows their convention exactly: not a rune, in no slot, opt-in,
  -- and 'Nothing' (the 'emptyCircle' value) means the single origin
  -- anchor the interpreter has always used — the pre-0025 path, branched
  -- around rather than reconstructed.
  --
  -- @Just []@ is unrepresentable in a loaded circle: the codec rejects an
  -- empty array rather than letting it collide with "no key" (func-spec
  -- 0025 §3.1). Handed one anyway, 'Magic.Compile.compile' produces a
  -- spell with no casting emitter — the honest reading of "fires from
  -- nowhere", not a special case.
  , circleSigil :: !(Maybe SigilTiming)
  -- ^ The sigil's own time axis (func-spec 0026). The fourth
  -- circle-level property, and it follows the convention the three above
  -- it set exactly: not a rune, in no slot, opt-in, and 'Nothing' (the
  -- 'emptyCircle' value) takes the func-spec 0017 path — the sigil ends
  -- with the spell and keeps redrawing itself every @formLife@ while it
  -- waits.
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

-- | The sigil's own time axis (func-spec 0026). Two knobs, each opt-in,
-- each defaulting to what func-spec 0017 delivered.
--
-- Deliberately /not/ folded into 'Magic.Sigil.hashCircle': this type
-- changes how long the sigil exists and how it ends, not what it looks
-- like (ADR-0014 D3). It rides alongside the fold exactly as
-- 'circleFields' and 'circleAnchors' do — carried, never folded.
--
-- It is a circle-level property rather than two more 'PhaseConfig'
-- fields for the same reason: 'PhaseConfig' /is/ digested, so a field
-- added there would silently redraw every shipped sigil unless hand-
-- excluded from the hash.
data SigilTiming = SigilTiming
  { stLinger :: !Seconds
  -- ^ The sigil's end, relative to the spell's. @0@ = they end together
  -- (the func-spec 0017 behaviour). Positive = the sigil outlives the
  -- spell, and the lifecycle's closing landmark stretches with it.
  -- Negative = the sigil goes first, with a floor at 'phDraw': however
  -- negative this is, the sigil is drawn to completion.
  , stHold :: !Bool
  -- ^ 'True' = freeze once drawn. The first @formLife@ still lays the
  -- sigil down one index at a time (spec 0016's "index order is drawing
  -- order" is untouched); after it, the look no longer changes. The
  -- sigil still spins — that runs off the cast clock, not particle age
  -- (ADR-0020).
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
    , circleAnchors = Nothing
    , circleSigil = Nothing
    }
