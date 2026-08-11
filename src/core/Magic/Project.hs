-- | Projection abstraction (ADR-0008). Skeleton: identity — the raylib 3D
-- backend consumes abstract-space coordinates directly. A future 2D
-- backend supplies a real projection here without touching the core.
module Magic.Project
  ( project
  ) where

import Magic.Types (V3)

project :: V3 -> V3
project = id
