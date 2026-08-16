-- | The scene layer (func-spec 0012 S4, ADR-0012): several casts alive at
-- once under one global particle quota.
--
-- Everything above 'Magic.Interface' and nothing below it — this module
-- imports the public interface only, exactly as a host would, and adds no
-- new spell semantics. A 'Scene' is a pure value: 'advanceScene' is
-- @map advanceSpell@ plus @filter (not . isFinished)@, 'observeScene' is
-- @concatMap@ over the batches. No IO, no mutable state, no locks; how a
-- host threads several scenes (or several frames) is the host's decision,
-- unchanged from func-spec 0009 §9-2.
--
-- The quota is first-come-first-served (ADR-0012): a cast is admitted
-- when the spells already in the scene plus its own compiled budget fit
-- under 'scGlobalCap', and refused otherwise, leaving the scene exactly as
-- it was. Nothing is preempted, nothing is scaled down. The accounting is
-- recomputed from the spell list rather than kept in a counter, so a
-- finished spell releases its share the moment 'advanceScene' drops it —
-- there is no second ledger that can drift from the first.
module Magic.Scene
  ( -- * Identity and configuration
    SpellId (..)
  , SceneConfig (..)

    -- * The scene
  , Scene
  , newScene
  , sceneSpells
  , sceneBudget
  , lookupSpell

    -- * Admission
  , CastRefusal (..)
  , castInto
  , castManyInto
  , dismiss

    -- * Frame cycle
  , advanceScene
  , observeScene
  ) where

import Magic.Interface
  ( ActiveSpell
  , CastContext
  , CastRequest (..)
  , Circle
  , CompileError
  , FrameInput
  , FrameOutput (..)
  , advanceSpell
  , budgetPlanOf
  , budgetTotal
  , castSpell
  , castSpells
  , isFinished
  , observeSpell
  )

-- | A scene-unique handle for one cast. Ascending in admission order;
-- ids are never reused, so a stale handle is inert rather than
-- ambiguous.
newtype SpellId = SpellId Int
  deriving (Eq, Ord, Show)

-- | What a scene is allowed to cost.
newtype SceneConfig = SceneConfig
  { scGlobalCap :: Int
  -- ^ Total particles the scene may hold across every live spell. Sized
  -- by the host from what its renderer can draw; unrelated to
  -- 'Magic.Interface.maxSpellParticles', which bounds one cast.
  }
  deriving (Eq, Show)

-- | Live casts under a quota. Opaque: the association list is kept
-- ascending by 'SpellId', which is what makes 'observeScene' a function
-- of the scene's /contents/ rather than of the order operations happened
-- to be applied in.
data Scene = Scene
  { sceneConfig :: !SceneConfig
  , sceneList :: ![(SpellId, ActiveSpell)]
  -- ^ Ascending by 'SpellId'. A list, not a @Map@: the boundary layer's
  -- dependency whitelist has no @containers@, and a scene holds the
  -- spells a game has in flight — single to low double digits — so the
  -- linear walk is cheaper than the dependency.
  , sceneNextId :: !Int
  }

-- | Why a cast was not admitted.
data CastRefusal
  = -- | The spell compiled, but its budget does not fit: requested,
    -- remaining.
    QuotaExceeded !Int !Int
  | -- | The circle(s) did not compile. Wrapped, not merged: the scene's
    -- own refusal reason stays separate from the compiler's error type.
    CompileFailed !CompileError
  deriving (Eq, Show)

newScene :: SceneConfig -> Scene
newScene cfg = Scene {sceneConfig = cfg, sceneList = [], sceneNextId = 0}

-- | The live spells, in admission order.
sceneSpells :: Scene -> [SpellId]
sceneSpells = map fst . sceneList

-- | @(particles committed, the global cap)@. The first component is
-- summed from the live spells' compiled budgets on demand.
sceneBudget :: Scene -> (Int, Int)
sceneBudget scene = (usedBudget scene, scGlobalCap (sceneConfig scene))

-- | One live spell by id, or 'Nothing' for an id that is stale, already
-- finished or never issued (func-spec 0025 S6).
--
-- Read-only, and the smallest opening that lets a per-spell query — the
-- spatial summary is the first — be asked of a scene at all. It hands
-- back an 'ActiveSpell', which is opaque, so it grants a caller nothing
-- the single-cast path does not already grant.
lookupSpell :: SpellId -> Scene -> Maybe ActiveSpell
lookupSpell sid = lookup sid . sceneList

usedBudget :: Scene -> Int
usedBudget = sum . map (budgetOf . snd) . sceneList

budgetOf :: ActiveSpell -> Int
budgetOf = budgetTotal . budgetPlanOf

-- | Cast one circle into the scene.
castInto :: CastRequest -> Scene -> Either CastRefusal (SpellId, Scene)
castInto req = admit (castSpell req)

-- | Cast a composition of circles into the scene as a single spell
-- (func-spec 0012 §5) — the scene layer and the composition layer meeting
-- at the one point they need to.
castManyInto :: [Circle] -> CastContext -> Scene -> Either CastRefusal (SpellId, Scene)
castManyInto circles ctx = admit (castSpells circles ctx)

-- | The admission decision, shared by both entry points: compile errors
-- surface as 'CompileFailed', an over-budget cast as 'QuotaExceeded', and
-- in both cases the scene handed back on the 'Left' path is the caller's
-- own — refusal changes nothing.
admit
  :: Either CompileError ActiveSpell -> Scene -> Either CastRefusal (SpellId, Scene)
admit compiled scene = case compiled of
  Left err -> Left (CompileFailed err)
  Right spell
    | need > remaining -> Left (QuotaExceeded need remaining)
    | otherwise -> Right (sid, scene')
    where
      need = budgetOf spell
      remaining = scGlobalCap (sceneConfig scene) - usedBudget scene
      sid = SpellId (sceneNextId scene)
      scene' =
        scene
          { sceneList = sceneList scene ++ [(sid, spell)]
          , sceneNextId = sceneNextId scene + 1
          }

-- | Remove a spell (a host interrupting a cast). Unknown or already
-- finished ids are a no-op, so a host may dismiss without first checking
-- whether the spell outlived itself.
dismiss :: SpellId -> Scene -> Scene
dismiss sid scene = scene {sceneList = filter ((/= sid) . fst) (sceneList scene)}

-- | Advance every live spell by one frame and drop the ones that finished
-- — which is also how their share of the quota is released.
advanceScene :: FrameInput -> Scene -> Scene
advanceScene fi scene =
  scene {sceneList = filter (not . isFinished . snd) (map advance (sceneList scene))}
  where
    advance (sid, spell) = (sid, advanceSpell fi spell)

-- | Observe every live spell, batches concatenated in 'SpellId' order.
--
-- Pure observation, like 'Magic.Interface.observeSpell': no time passes,
-- so a host running several fixed steps per rendered frame pays for one
-- sampling of each spell. The batch list is what the host draws; batches
-- are not merged across spells, since each carries its own blend mode.
observeScene :: Scene -> FrameOutput
observeScene scene =
  FrameOutput {batches = concatMap (batches . observeSpell . snd) (sceneList scene)}
