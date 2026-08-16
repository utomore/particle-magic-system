-- | The frame's render plan (func-spec 0023 S5/S7/S8): which passes run,
-- into which target, at which size, with which uniforms.
--
-- __Pure, and that is the point.__ ADR-0009's division of labour was
-- "decide on the staging side, execute in O(1) FFI calls", and this is
-- that rule applied one level up: 'framePlan' decides the whole frame as
-- a value, and 'App.Render.Raylib3D' does nothing but execute it. So the
-- pass order, the ping-pong between scratch targets, the resolution of
-- each pass and the zero-ripple laws are all checkable headless
-- (@test\/ShaderPipelineSpec.hs@, @test\/BloomSpec.hs@,
-- @test\/SoftParticleSpec.hs@) rather than by looking at a window.
--
-- __The zero-ripple law__ is the load-bearing one. With every effect off,
-- 'framePlan' is a single 'ParticlePass' straight to the screen with no
-- soft fade — which is exactly the draw func-spec 0015 delivered, so a
-- demo nobody has touched renders what it always did, and the whole
-- post-processing apparatus costs a comparison.
module App.Render.Post
  ( -- * Settings
    VisualSettings (..)
  , noEffects
  , allEffects
  , bloomThreshold
  , bloomIntensity
  , bloomDownscale
  , softDistance
  , depthScratch

    -- * The plan
  , Target (..)
  , PassSize (..)
  , Pass (..)
  , FramePlan (..)
  , framePlan
  , scratchTargetsNeeded
  , passSizeIn
  ) where

import App.Render.Shader (ShaderId (..))

-- | Which of this round's effects are on. Presentation state, like
-- 'App.Effects.FlatView''s tint and scale: it never feeds back into the
-- simulation, so toggling any of it cannot disturb a running spell.
data VisualSettings = VisualSettings
  { vsTrails :: !Bool
  -- ^ Stretch 'Magic.Interface.BillboardTrail' batches along their
  -- particles' velocity (func-spec 0023 S6). Off means such a batch draws
  -- as the square quad it drew before this round, which is why a host
  -- that predates trails is never shown something it cannot explain.
  , vsBloom :: !Bool
  , vsSoftParticles :: !Bool
  , vsScene :: !Bool
  -- ^ Draw the test scene geometry (func-spec 0023 §2.6). Its own switch
  -- rather than being implied by 'vsSoftParticles', because the two
  -- questions a viewer asks are different: "is there anything to
  -- intersect" and "does intersecting it look right".
  }
  deriving (Eq, Show)

-- | Everything off — the func-spec 0015 picture, and the demo's start
-- state.
noEffects :: VisualSettings
noEffects =
  VisualSettings
    { vsTrails = False
    , vsBloom = False
    , vsSoftParticles = False
    , vsScene = False
    }

allEffects :: VisualSettings
allEffects =
  VisualSettings
    { vsTrails = True
    , vsBloom = True
    , vsSoftParticles = True
    , vsScene = True
    }

-- | Luminance above which a pixel contributes to the glow.
--
-- High enough that the additive fire spells bloom and the dim formation
-- particles do not: bloom on everything is fog, and the point of the
-- effect is that the bright things are picked out.
bloomThreshold :: Float
bloomThreshold = 0.65

-- | How much of the blurred bright pass is added back. Short of 1, or a
-- saturated core plus its own glow clips to white and the colour — which
-- is the magic's semantics (architecture §1.2) — is lost exactly where
-- the spell is most intense.
bloomIntensity :: Float
bloomIntensity = 0.8

-- | The bloom chain runs at @1\/n@ of the screen's resolution.
--
-- Halving is not a compromise here, it is part of the effect: the
-- downsample is itself a blur, so the same visual radius costs a quarter
-- of the samples, and a glow has no high-frequency detail to lose.
bloomDownscale :: Int
bloomDownscale = 2

-- | World-space distance over which a particle fades out as it approaches
-- solid geometry. Zero switches the fade off in the shader itself, not
-- merely down (see @assets\/shaders\/particle.fs@).
softDistance :: Float
softDistance = 0.6

-- | Where a pass draws.
data Target
  = -- | The window's own framebuffer.
    Screen
  | -- | An offscreen render texture, by index. 0 is the full-resolution
    -- scene buffer; 1 and 2 are the half-resolution ping-pong pair the
    -- blur bounces between.
    Scratch !Int
  deriving (Eq, Show)

-- | The resolution a pass runs at.
data PassSize
  = FullSize
  | -- | @1\/n@ of the screen on each axis.
    Downscaled !Int
  deriving (Eq, Show)

-- | One step of the frame.
data Pass
  = -- | The test scene's geometry (func-spec 0023 §2.6). Runs before any
    -- particle pass, because the soft fade reads the depth this writes —
    -- an ordering the plan makes structural instead of leaving it to the
    -- interpreter to remember.
    ScenePass !Target
  | -- | The particle batches, through 'ShaderParticle': the target to
    -- draw into, the soft-particle fade distance (0 = no fade) and the
    -- target whose /depth/ the fade samples.
    --
    -- The depth source is a separate target on purpose. A pass may not
    -- sample the depth attachment it is currently writing — the result is
    -- undefined, and in practice the fade reads garbage and every
    -- particle disappears (found by the func-spec 0023 §9 smoke, §10).
    ParticlePass !Target !Float !(Maybe Target)
  | -- | A screen-filling shader pass reading one target and writing
    -- another.
    ScreenPass !ShaderId !Target !Target !PassSize
  deriving (Eq, Show)

-- | Everything the interpreter needs for one frame.
newtype FramePlan = FramePlan
  { planPasses :: [Pass]
  }
  deriving (Eq, Show)

-- | Index of the scratch target the soft-particle depth pre-pass writes,
-- for a given bloom setting.
--
-- Past the bloom chain's three when bloom is on, and index 0 when it is
-- off. Numbering it from what the frame actually uses — rather than
-- pinning it at 3 — is what keeps "allocate exactly what the plan names"
-- true: soft particles without bloom then cost /one/ render texture, not
-- four with three of them idle.
depthScratch :: Bool -> Int
depthScratch bloomOn = if bloomOn then 3 else 0

-- | The frame's passes, from the settings.
--
-- Read the cases in order of what they cost:
--
--   * nothing on — one pass, straight to the screen. Bit for bit the
--     func-spec 0015 draw;
--   * scene on — the geometry first, so there is something for particles
--     to sit behind;
--   * soft particles on — a /depth pre-pass/ draws the same geometry into
--     a scratch target of its own, and the particle pass fades against
--     that. Two reasons it is a separate target rather than the frame's:
--     a pass may not sample the depth attachment it is writing (the
--     result is undefined, and in practice every particle vanishes), and
--     the window's own depth buffer cannot be sampled at all — which is
--     why the effect silently did nothing without bloom before this was
--     found (§10). Drawing four boxes twice is cheaper than either
--     alternative (a colour copy, or a separate particle layer that would
--     break additive blending against the scene);
--   * soft particles are gated on 'vsScene' as well: with no geometry the
--     depth buffer is empty, every fragment would compare against the far
--     plane, and the effect would be a uniform dimming that looks exactly
--     like a bug. "Degrade to hard-edged, never to a black screen" (S8);
--   * bloom on — the whole frame is drawn into 'Scratch' 0 instead, and
--     the three-pass chain runs from there to the screen.
framePlan :: VisualSettings -> FramePlan
framePlan settings = FramePlan (depthPrepass ++ scene ++ [particles] ++ bloom)
  where
    -- With bloom on, everything is drawn offscreen so the bright pass has
    -- an image to read; without it, straight to the window.
    sceneTarget
      | vsBloom settings = Scratch 0
      | otherwise = Screen

    softened = vsSoftParticles settings && vsScene settings

    depthSource
      | softened = Just (Scratch (depthScratch (vsBloom settings)))
      | otherwise = Nothing

    depthPrepass = [ScenePass t | Just t <- [depthSource]]

    scene
      | vsScene settings = [ScenePass sceneTarget]
      | otherwise = []

    fade
      | softened = softDistance
      | otherwise = 0

    particles = ParticlePass sceneTarget fade depthSource

    bloom
      | not (vsBloom settings) = []
      | otherwise =
          [ ScreenPass ShaderBright (Scratch 0) (Scratch 1) half
          , -- Horizontal then vertical, bouncing between the pair: pass
            -- two reads what pass one wrote, and neither reads the target
            -- it is writing.
            ScreenPass ShaderBlur (Scratch 1) (Scratch 2) half
          , ScreenPass ShaderBlur (Scratch 2) (Scratch 1) half
          , ScreenPass ShaderComposite (Scratch 0) Screen FullSize
          ]

    half = Downscaled bloomDownscale

-- | How many scratch render textures a plan needs — the count the
-- interpreter allocates at startup and reallocates on a resize.
--
-- Derived from the plan rather than fixed at 3, so "everything off
-- allocates nothing" is a consequence of the plan and not a second fact
-- that could drift away from it.
scratchTargetsNeeded :: FramePlan -> Int
scratchTargetsNeeded (FramePlan passes) =
  case [i | p <- passes, Scratch i <- targetsOf p] of
    [] -> 0
    indices -> maximum indices + 1
  where
    targetsOf p = case p of
      ScenePass t -> [t]
      ParticlePass t _ depth -> t : maybe [] pure depth
      ScreenPass _ from to _ -> [from, to]

-- | A pass's pixel dimensions at a given screen size. Never smaller than
-- 1×1: a window dragged to nothing would otherwise ask for a zero-sized
-- render texture, which raylib will happily fail to create.
passSizeIn :: (Int, Int) -> PassSize -> (Int, Int)
passSizeIn (w, h) size = case size of
  FullSize -> (max 1 w, max 1 h)
  Downscaled n -> (max 1 (w `div` max 1 n), max 1 (h `div` max 1 n))
