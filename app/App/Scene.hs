-- | The demo's test scene geometry (func-spec 0023 §2.6).
--
-- __Why this exists at all.__ Soft particles work by fading a billboard
-- out as it approaches solid geometry, which removes the hard line a quad
-- cuts where it intersects a surface. But the demo has never drawn any
-- solid geometry — only particles — so there was nothing to intersect,
-- nothing to fade against, and no way to tell a working implementation
-- from a broken one. That gap was found while designing func-spec 0023
-- and is recorded there; this module closes it.
--
-- __What it is not.__ Not art, and not a game scene. It is a /test
-- bench/: a ground plane and three blocks at different distances, chosen
-- so that a spell cast at the origin passes through some of them and near
-- others. The lineage is func-spec 0008's top-down view, which existed to
-- /expose/ the depth-overlap problem rather than to look good.
--
-- Renderer-agnostic, like 'App.Effects.Camera': plain boxes in our own
-- 'V3', so the loop and the headless interpreters never touch h-raylib
-- and the geometry can be asserted about without a window.
module App.Scene
  ( Block (..)
  , testScene
  , groundSize
  , groundLevel
  ) where

import Magic.Interface (V3 (..))

-- | One axis-aligned box: centre and half-extents, plus the packed RGBA
-- colour to draw it in.
--
-- A box rather than a mesh because every question soft particles ask is
-- about depth, and a box answers it at every distance a particle can
-- reach. Anything with more triangles would test the renderer's
-- patience, not the effect.
data Block = Block
  { blCenter :: !V3
  , blHalf :: !V3
  , blColor :: !Word
  -- ^ Packed 0xRRGGBBAA, the same convention
  -- 'Magic.Interface.pbColor' uses — so the shell has one colour
  -- encoding rather than two.
  }
  deriving (Eq, Show)

-- | Edge length of the ground plane, in world units. Comfortably larger
-- than the spells' reach, so a particle leaving the plane is leaving the
-- scene rather than falling off a visible edge.
groundSize :: Float
groundSize = 24

-- | Height of the ground. Slightly below zero, not at it: a spell cast at
-- the origin would otherwise spawn its formation particles exactly
-- coplanar with the floor, and coplanar geometry z-fights — which looks
-- like a soft-particle bug and is not one.
groundLevel :: Float
groundLevel = -0.05

-- | The scene: a ground slab and three blocks.
--
-- Placed deliberately rather than prettily. One block sits where a spell
-- cast at the origin will fly straight into it (the intersection case,
-- which is what the fade is for); one stands off to the side at a
-- distance (the near-miss case, where the fade must /not/ fire, or every
-- particle in the scene dims); one is short and close, so the ground,
-- the block and the particles all overlap in a small screen area — the
-- crowded case where a depth mistake is visible.
testScene :: [Block]
testScene =
  [ -- The ground, as a very flat block: one geometry kind rather than
    -- two, so the interpreter has one thing to draw and the depth pass
    -- one thing to write.
    Block
      { blCenter = V3 0 (groundLevel - 0.1) 0
      , blHalf = V3 (groundSize / 2) 0.1 (groundSize / 2)
      , blColor = 0x28303CFF
      }
  , -- Straight ahead, at the height spells travel: the one particles run
    -- into.
    Block
      { blCenter = V3 0 1.6 (-4.5)
      , blHalf = V3 1.6 1.6 0.4
      , blColor = 0x3C4655FF
      }
  , -- Off to the side, deliberately clear of the spell: the control.
    Block
      { blCenter = V3 4.5 1.2 1.0
      , blHalf = V3 0.8 1.2 0.8
      , blColor = 0x46506080
      }
  , -- Low and close, under the cast point.
    Block
      { blCenter = V3 (-2.2) 0.35 1.8
      , blHalf = V3 1.0 0.35 1.0
      , blColor = 0x323C4AFF
      }
  ]
