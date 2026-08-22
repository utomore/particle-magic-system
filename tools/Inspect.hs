{-# LANGUAGE OverloadedStrings #-}

-- | The pure half of @magic-inspect@ (func-spec 0024 S2): what a spell
-- file adds up to, laid out for a person.
--
-- __Zero new analysis.__ Every number below already existed as a query on
-- "Magic.Interface" (func-spec 0010 §9.3 published them for exactly this):
-- 'budgetPlanOf', 'emittersOf', 'emitterBounds', 'maxSpellParticles', and
-- the batch list 'observeSpell' already cuts. This module chooses an
-- order, a column width and a word for each of them and does nothing else
-- — which is why it can be a pure function from 'Circle' to lines, and why
-- a bug in it can only ever be a typo.
--
-- It shares 'defaultContext' and 'lifetimeOf' with "Validate" by import
-- rather than by copy: the two tools describe the same cast, and a second
-- definition of "the context the numbers are measured in" is a drift
-- waiting to happen.
--
-- __Frozen__ (func-spec 0024 §9): the section headers, the column
-- headers, and the rule that every section is a header line at column 0
-- with its body indented by two spaces. Same reason @magic-validate@'s
-- line format is frozen (func-spec 0014 §9.3) — the readers are humans
-- /and/ scripts, so the layout is the contract.
module Inspect
  ( inspectReport
  , renderCompileErrorForInspect
  , sectionHeaders
  ) where

import Data.Aeson (Value (Array, Number, Object), decodeStrict)
import qualified Data.Aeson.KeyMap as KM
import Data.List (intercalate)
import qualified Data.Vector.Unboxed as U
import Magic.Codec (saveCircle)
import Magic.Interface
  ( ActiveSpell
  , BillboardShape (..)
  , BlendMode (..)
  , CastRequest (..)
  , Circle
  , CompileError (..)
  , FrameOutput (batches)
  , ParticleBudget (..)
  , RenderBatch (..)
  , Seconds (..)
  , V3 (..)
  , budgetPlanOf
  , castSpell
  , emitterBounds
  , emittersOf
  , maxSpellParticles
  , observeSpell
  )
import Numeric (showFFloat)
import Validate (defaultContext, lifetimeOf)

-- | The report, one 'String' per line, no trailing newlines.
--
-- 'Left' when the circle does not compile — the whole report or none of
-- it. A half-written report with the failure at the bottom would be worse
-- than the error alone: the numbers above it would be from a spell that
-- does not exist.
inspectReport :: Circle -> Either CompileError [String]
inspectReport circle = do
  spell <- castSpell (CastRequest circle defaultContext)
  pure (summary circle spell ++ [""] ++ timeline circle spell ++ [""] ++ emitterTable spell ++ [""] ++ batchTable spell)

-- | The section headers, in order. Exported so the format contract can be
-- asserted against one list instead of six string literals scattered
-- through a test.
sectionHeaders :: [String]
sectionHeaders = ["spell", "timeline", "emitters", "batches"]

-- | The tool says the same words @magic-validate@ does when a circle is
-- too big; 'CompileError' is a core type and the core does not do prose,
-- so the sentence is written at this layer in both tools.
--
-- Matched exhaustively on purpose (as in "Validate"): a new constructor
-- should break this build rather than fall through to a 'show'.
renderCompileErrorForInspect :: CompileError -> String
renderCompileErrorForInspect err = case err of
  BudgetExceeded wanted cap ->
    "too many particles: this circle needs "
      ++ show wanted
      ++ ", the cap is "
      ++ show cap
      ++ " (the core centre's \"power\" scales the count: 256 x power)"
  ManaExceeded wanted cap ->
    "too much mana: this circle costs "
      ++ show wanted
      ++ ", the cap is "
      ++ show cap

-- Sections -------------------------------------------------------------------

summary :: Circle -> ActiveSpell -> [String]
summary circle spell =
  "spell"
    : map
      (indent . uncurry field)
      [ ("budget", show (budgetTotal budget) ++ " / " ++ show maxSpellParticles ++ " particles")
      , ("emitters", show (length (emittersOf spell)))
      , ("lifetime", secs life)
      , ("extent", extentText (wholeExtent spell))
      , ("phases", phasesText (declPhases decl))
      , ("fields", show (declFields decl))
      , ("anchors", anchorsText (declAnchors decl))
      , ("style", styleText spell)
      ]
  where
    budget = budgetPlanOf spell
    Seconds life = lifetimeOf spell
    decl = declaredOf circle

-- | When the spell's parts happen, as instants rather than durations:
-- a reader who wants to know "is anything on screen at 2 seconds" should
-- not have to add up a column.
timeline :: Circle -> ActiveSpell -> [String]
timeline circle spell =
  "timeline" : map indent (map row stages)
  where
    Seconds life = lifetimeOf spell
    stages = case declPhases (declaredOf circle) of
      Nothing -> [(0, "casting"), (life, "over")]
      Just (Seconds draw, Seconds converge) ->
        [ (0, "draw")
        , (draw, "converge")
        , (draw + converge, "casting")
        , (life, "over")
        ]
    row (at, what) = padTo 10 (secs at) ++ what

-- | One row per compiled emitter: its share of the budget and the box it
-- can reach over the whole lifetime.
--
-- __Not here: the per-emitter envelope.__ func-spec 0024 §6 S2 asked for
-- it, and 'Magic.Interface' does not publish one — 'EmitterSpec' is
-- opaque there (deliberately: a host receives them from 'emittersOf' and
-- hands them back to 'emitterBounds'), and this round's file inventory
-- puts @src\/*@ out of bounds, so widening the interface to reach it is
-- not available. The circle-level declaration is reported in the summary's
-- @phases@ line instead; func-spec 0024 §10 records the deviation.
emitterTable :: ActiveSpell -> [String]
emitterTable spell =
  "emitters"
    : indent (padTo 5 "idx" ++ padTo 11 "particles" ++ "extent")
    : [ indent (padTo 5 (show i) ++ padTo 11 (show n) ++ extentText box)
      | (i, n, box) <- zip3 [0 :: Int ..] counts boxes
      ]
  where
    counts = U.toList (budgetPerEmitter (budgetPlanOf spell))
    boxes = map (emitterBounds defaultContext (lifetimeOf spell)) (emittersOf spell)

-- | One row per render batch: how the spell will be drawn.
--
-- The batch /structure/ is time-independent (func-spec 0015's splitting
-- law groups adjacent emitters by appearance, not by how many of their
-- particles are alive), so reading it off a freshly cast spell describes
-- every later frame too.
batchTable :: ActiveSpell -> [String]
batchTable spell =
  "batches"
    : indent (padTo 5 "idx" ++ padTo 11 "blend" ++ "billboard")
    : [ indent (padTo 5 (show i) ++ padTo 11 (blendName (rbBlend b)) ++ shapeName (rbShape b))
      | (i, b) <- zip [0 :: Int ..] (batches (observeSpell spell))
      ]

-- Wording --------------------------------------------------------------------

blendName :: BlendMode -> String
blendName mode = case mode of
  BlendAlpha -> "alpha"
  BlendAdditive -> "additive"

shapeName :: BillboardShape -> String
shapeName shape = case shape of
  BillboardSquare -> "square"
  BillboardSoftDot -> "soft-dot"
  BillboardRing -> "ring"
  BillboardSpark -> "spark"
  BillboardTrail -> "trail"

-- | The one-line version of the batch table, for the summary block.
styleText :: ActiveSpell -> String
styleText spell = case batches (observeSpell spell) of
  [] -> "none (no batches)"
  bs ->
    intercalate ", " (nubOrd (map (blendName . rbBlend) bs))
      ++ " / "
      ++ intercalate ", " (nubOrd (map (shapeName . rbShape) bs))

phasesText :: Maybe (Seconds, Seconds) -> String
phasesText phases = case phases of
  Nothing -> "none (casting starts at 0.000s)"
  Just (Seconds d, Seconds c) ->
    "draw " ++ secs d ++ " + converge " ++ secs c ++ " -> casting starts at " ++ secs (d + c)

anchorsText :: Maybe Int -> String
anchorsText declared = case declared of
  Nothing -> "1 (the default point, straight ahead)"
  Just n -> show n ++ " (particles are shared out between them, not multiplied)"

-- Reading the circle back ------------------------------------------------------

-- | The circle's three opt-in circle-level keys, read back off
-- 'saveCircle' — the codec's own canonical encoding of the circle that was
-- just loaded, so this reports what the compiler saw rather than what the
-- author's file happened to spell.
--
-- Same route "Validate" takes and for the same reason: none of the three
-- is surfaced by 'Magic.Interface', and this round may not widen it
-- (func-spec 0024 §0.2 puts @src\/*@ out of bounds).
data Declared = Declared
  { declPhases :: Maybe (Seconds, Seconds)
  , declFields :: Int
  , declAnchors :: Maybe Int
  }

declaredOf :: Circle -> Declared
declaredOf circle = case decodeStrict (saveCircle circle) of
  Just (Object top) | Just (Object c) <- KM.lookup "circle" top ->
    Declared {declPhases = phasesOf c, declFields = countOf c "fields", declAnchors = anchorsOf c}
  _ -> Declared {declPhases = Nothing, declFields = 0, declAnchors = Nothing}
  where
    phasesOf c = case KM.lookup "phases" c of
      Just (Object p) -> do
        d <- number =<< KM.lookup "draw" p
        v <- number =<< KM.lookup "converge" p
        pure (Seconds d, Seconds v)
      _ -> Nothing

    countOf c key = case KM.lookup key c of
      Just (Array items) -> length items
      _ -> 0

    -- Null (or absent) is the default single point, which is a different
    -- statement from "a list that happens to have one entry in it".
    anchorsOf c = case KM.lookup "anchors" c of
      Just (Array items) -> Just (length items)
      _ -> Nothing

    number v = case v of
      Number n -> Just (realToFrac n)
      _ -> Nothing

-- | The union of every emitter's box: where this cast can ever put a
-- particle. Identical in meaning to @magic-validate --stats@'s @extent@
-- line, and computed the same way.
wholeExtent :: ActiveSpell -> (V3, V3)
wholeExtent spell =
  case map (emitterBounds defaultContext (lifetimeOf spell)) (emittersOf spell) of
    [] -> (V3 0 0 0, V3 0 0 0)
    (b : bs) -> foldr union b bs
  where
    union (lo1, hi1) (lo2, hi2) = (zipV3 min lo1 lo2, zipV3 max hi1 hi2)
    zipV3 f (V3 a b c) (V3 x y z) = V3 (f a x) (f b y) (f c z)

-- Layout ---------------------------------------------------------------------

indent :: String -> String
indent = ("  " ++)

field :: String -> String -> String
field name body = padTo 12 name ++ body

padTo :: Int -> String -> String
padTo n s = s ++ replicate (max 1 (n - length s)) ' '

secs :: Double -> String
secs s = showFFloat (Just 3) s "s"

extentText :: (V3, V3) -> String
extentText (lo, hi) = point lo ++ " .. " ++ point hi
  where
    coord x = showFFloat (Just 3) (realToFrac x :: Double) ""
    point (V3 x y z) = "(" ++ intercalate ", " (map coord [x, y, z]) ++ ")"

-- | 'Data.List.nub' keeps the first occurrence and this list is never more
-- than a handful long, so the quadratic cost is not worth an import.
nubOrd :: (Eq a) => [a] -> [a]
nubOrd = go []
  where
    go seen [] = reverse seen
    go seen (x : xs)
      | x `elem` seen = go seen xs
      | otherwise = go (x : seen) xs
