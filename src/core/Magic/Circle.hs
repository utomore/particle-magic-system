-- | ⚠ Skeleton stub (func-spec 0001 §4.2). Spec 0002+ fills in the real
-- slot structure (TwoOf rings, bridge, core nodes — architecture §4.1).
-- For the skeleton, only the all-empty circle needs to be representable
-- and serializable: an empty circle compiles to a plain magic discharge
-- ("素放", architecture §3.3).
module Magic.Circle
  ( Circle (..)
  , emptyCircle
  ) where

-- | The magic circle. Skeleton placeholder: only the all-empty circle
-- exists. The constructor set will grow fields in spec 0002+; downstream
-- code must treat this as opaque data flowing to 'Magic.Compile.compile'.
data Circle = Circle
  deriving (Eq, Show)

emptyCircle :: Circle
emptyCircle = Circle
