{-# LANGUAGE OverloadedStrings #-}

-- | The pure half of @magic-validate@ (func-spec 0014 S1): bytes in,
-- report out.
--
-- The tool is the boundary layer's third consumer, next to the demo shell
-- and the C ABI (func-spec 0014 §2). It imports 'Magic.Codec' and
-- 'Magic.Interface' and nothing else from this repo — no core internals,
-- no renderer — so an executable that opens no window and draws nothing
-- is, by construction, a second proof that the library is complete and
-- the drawing is outside it.
--
-- Everything that decides an outcome lives here, as pure functions over
-- 'Data.ByteString.ByteString'; @tools\/Main.hs@ only reads files, prints
-- and exits. That is what makes the delivered contract testable: the
-- report format is frozen (§9), and the frozen thing is a 'String'.
--
-- __Frozen__ (func-spec 0014 §9): the command line accepted by
-- 'parseArgs', and the line format produced by 'renderReport' — one
-- @OK \<path\>@ or @FAIL \<path\>@ line per file, every detail line
-- indented by two spaces. Scripts grep the first word; humans read the
-- rest.
module Validate
  ( -- * Command line
    Options (..)
  , parseArgs
  , usage

    -- * Reports
  , Report (..)
  , Stats (..)
  , validateBytes
  , renderReport
  , failureCount
  , exitCodeFor

    -- * The context reports are measured in
  , defaultContext
  ) where

import Data.Aeson (Value (Array, Number, Object), decodeStrict)
import qualified Data.Aeson.KeyMap as KM
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import Data.List (intercalate)
import qualified Data.Vector.Unboxed as U
import Magic.Codec (loadCircle, renderLoadError, saveCircle)
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , Circle
  , CompileError (..)
  , DeltaTime (..)
  , EmitterSpec
  , FrameInput (..)
  , ParticleBudget (..)
  , Seconds (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , budgetPlanOf
  , castSpell
  , emitterBounds
  , emittersOf
  , isFinished
  , maxSpellParticles
  )
import Numeric (showFFloat)

-- Command line ---------------------------------------------------------------

data Options = Options
  { optStats :: !Bool
  -- ^ @--stats@: print the compiled numbers under every passing file.
  , optPaths :: ![FilePath]
  -- ^ Files and\/or directories to validate, in the order given.
  }
  deriving (Eq, Show)

-- | Parse the command line. 'Left' is the message to print on stderr
-- before the usage text; there are no silent defaults, because a
-- validator that guesses what to validate is a validator you cannot put
-- in a CI script.
parseArgs :: [String] -> Either String Options
parseArgs args = do
  (stats, paths) <- go False [] args
  if null paths
    then Left "magic-validate: no files or directories given"
    else Right (Options {optStats = stats, optPaths = reverse paths})
  where
    go stats paths [] = Right (stats, paths)
    go stats paths (a : rest) = case a of
      "--stats" -> go True paths rest
      "--help" -> Left "magic-validate: help requested"
      "-h" -> Left "magic-validate: help requested"
      ('-' : _) -> Left ("magic-validate: unknown option " ++ show a)
      _ -> go stats (a : paths) rest

usage :: String
usage =
  unlines
    [ "usage: magic-validate [--stats] PATH..."
    , ""
    , "  PATH      a spell file, or a directory whose *.json files are all checked"
    , "  --stats   print the compiled budget, lifetime, phases, fields and extent"
    , ""
    , "Exit code is the number of files that failed (0 = all good, 64 = bad usage)."
    ]

-- Reports --------------------------------------------------------------------

-- | One file's verdict: the rendered error text, or the numbers behind a
-- successful cast.
data Report = Report
  { repPath :: FilePath
  , repResult :: Either String Stats
  }
  deriving (Eq, Show)

-- | What @--stats@ prints. Everything here is known before a single
-- frame is sampled — the point of the report is that an author can size
-- and time a spell without running it.
data Stats = Stats
  { stBudget :: !Int
  -- ^ Total particles this cast will ever hold (= 'budgetTotal').
  , stPerEmitter :: ![Int]
  -- ^ The same budget, emitter by emitter; index 0 is casting.
  , stCap :: !Int
  -- ^ 'maxSpellParticles', so the headroom is readable without a second
  -- lookup.
  , stEmitters :: !Int
  , stLifetime :: !Seconds
  , stPhases :: !(Maybe (Seconds, Seconds))
  -- ^ The circle's declared @draw@ and @converge@ durations, or 'Nothing'
  -- for a spell with no @"phases"@ key (casting starts immediately).
  , stFields :: !Int
  , stExtent :: !(V3, V3)
  -- ^ Conservative world-space box containing every particle this cast
  -- can produce, over its whole lifetime, in 'defaultContext'.
  }
  deriving (Eq, Show)

-- | The cast the tool reports on: caster at the origin, facing +Y,
-- seed 42 — the demo's own context (@app\/Main.hs@), so the numbers a
-- author reads here are the numbers that demo shows.
--
-- Only 'stExtent' depends on it; the budget, the lifetime, the phases and
-- the field count are properties of the circle alone.
defaultContext :: CastContext
defaultContext =
  CastContext
    { casterPos = V3 0 0 0
    , casterFacing = V3 0 1 0
    , seed = Seed 42
    }

-- | The whole verdict for one file: load it, then cast it. Both gates
-- matter and they fail differently — a circle can be perfectly
-- well-formed JSON and still be uncastable (the budget is checked at
-- compile time), which is exactly the mistake an author cannot see by
-- reading their file.
validateBytes :: FilePath -> BS.ByteString -> Report
validateBytes path bytes =
  Report path $ do
    circle <- first renderLoadError (loadCircle bytes)
    spell <- first renderCompileError (castSpell (CastRequest circle defaultContext))
    pure (statsOf circle spell)

-- | 'Magic.Codec' renders its own errors for the HUD ('renderLoadError'),
-- and the tool says the same words. 'CompileError' has no such renderer —
-- it is a core type, and the core does not do prose — so the sentence is
-- written here, in the vocabulary of the file the author is editing:
-- @power@ is the key that scales the count, and 256 is what a power of 1
-- buys.
--
-- Matched exhaustively on purpose: 'CompileError' is an extensible sum,
-- and a new constructor should break this build rather than fall through
-- to a 'show' an author cannot read.
renderCompileError :: CompileError -> String
renderCompileError err = case err of
  BudgetExceeded wanted cap ->
    "too many particles: this circle needs "
      ++ show wanted
      ++ ", the cap is "
      ++ show cap
      ++ " (the core centre's \"power\" scales the count: 256 x power)"

statsOf :: Circle -> ActiveSpell -> Stats
statsOf circle spell =
  Stats
    { stBudget = budgetTotal budget
    , stPerEmitter = perEmitter
    , stCap = maxSpellParticles
    , stEmitters = length emitters
    , stLifetime = lifetime
    , stPhases = phases
    , stFields = fields
    , stExtent = extentOf lifetime emitters
    }
  where
    budget = budgetPlanOf spell
    perEmitter = U.toList (budgetPerEmitter budget)
    emitters = emittersOf spell
    lifetime = lifetimeOf spell
    (phases, fields) = declaredOf circle

-- | Union of every emitter's conservative bounding box (func-spec 0010's
-- 'emitterBounds'), over the whole lifetime. An emitterless spell cannot
-- happen — index 0 is always the casting emitter — but a degenerate
-- answer beats a partial function.
extentOf :: Seconds -> [EmitterSpec] -> (V3, V3)
extentOf horizon emitters = case map (emitterBounds defaultContext horizon) emitters of
  [] -> (V3 0 0 0, V3 0 0 0)
  (b : bs) -> foldr union b bs
  where
    union (lo1, hi1) (lo2, hi2) = (zipV3 min lo1 lo2, zipV3 max hi1 hi2)
    zipV3 f (V3 a b c) (V3 x y z) = V3 (f a x) (f b y) (f c z)

-- | The spell's total duration, in seconds.
--
-- 'Magic.Interface' publishes the duration only as the predicate
-- 'isFinished' (@age >= lifetime@) — and func-spec 0014 §0.1 imports that
-- module read-only, because func-spec 0012 owns the file while the two
-- rounds run in parallel (SKILL.md, multi-collaborator rule 4). So the
-- number is recovered rather than asked for, and recovered exactly: the
-- predicate is monotone in the age, 'advanceSpell' sets a freshly cast
-- spell's age to precisely its argument, and bisection on a monotone
-- predicate over 'Double' converges on the very bits the compiler
-- computed. Roughly sixty probes per file, once, at load time.
lifetimeOf :: ActiveSpell -> Seconds
lifetimeOf spell0 = Seconds (bisect 0 (grow 1 (0 :: Int)))
  where
    -- A fresh spell has age 0, so one advance of dt lands its age on
    -- exactly dt (0 + dt) — no accumulated rounding to reason about.
    finishedAt x = isFinished (advanceSpell (FrameInput (DeltaTime x)) spell0)

    -- Bracket first: double until the spell is over. The counter is a
    -- backstop for a non-finite lifetime, which the codec's validation
    -- rules out but this loop should not depend on.
    grow hi n
      | n >= 64 = hi
      | finishedAt hi = hi
      | otherwise = grow (hi * 2) (n + 1)

    -- Invariant: not (finishedAt lo), finishedAt hi. Stops when the two
    -- are adjacent Doubles, at which point hi IS the lifetime.
    bisect lo hi
      | mid <= lo || mid >= hi = hi
      | finishedAt mid = bisect lo mid
      | otherwise = bisect mid hi
      where
        mid = lo + (hi - lo) / 2

-- | The circle's declared staging and force fields, read back off
-- 'saveCircle' — the codec's own canonical encoding of the circle that
-- was just loaded, so this reports what the compiler saw rather than what
-- the file happened to spell. (Both are circle-level opt-in keys that
-- 'Magic.Interface' does not surface; see 'lifetimeOf' for why the tool
-- does not widen that module this round.)
declaredOf :: Circle -> (Maybe (Seconds, Seconds), Int)
declaredOf circle = case decodeStrict (saveCircle circle) of
  Just (Object top) | Just (Object c) <- KM.lookup "circle" top -> (phasesOf c, fieldsOf c)
  _ -> (Nothing, 0)
  where
    phasesOf c = case KM.lookup "phases" c of
      Just (Object p) -> do
        d <- number =<< KM.lookup "draw" p
        v <- number =<< KM.lookup "converge" p
        pure (Seconds d, Seconds v)
      _ -> Nothing

    fieldsOf c = case KM.lookup "fields" c of
      Just (Array items) -> length items
      _ -> 0

    -- aeson's Number carries a Scientific; the two durations are plain
    -- seconds, so Double is the honest type to report them in.
    number v = case v of
      Number n -> Just (realToFrac n)
      _ -> Nothing

-- Rendering ------------------------------------------------------------------

-- | The frozen line format. @renderReport stats r@ ends with a newline,
-- so a run's whole stdout is @concatMap (renderReport stats) reports@.
renderReport :: Bool -> Report -> String
renderReport withStats (Report path result) = unlines $ case result of
  Left err -> ("FAIL " ++ path) : map indent (lines err)
  Right st
    | withStats -> ("OK " ++ path) : map indent (statLines st)
    | otherwise -> ["OK " ++ path]
  where
    indent = ("  " ++)

statLines :: Stats -> [String]
statLines st =
  [ field "budget" $
      show (stBudget st)
        ++ " / "
        ++ show (stCap st)
        ++ " particles"
  , field "emitters" $
      show (stEmitters st)
        ++ " ["
        ++ intercalate ", " (map show (stPerEmitter st))
        ++ "]"
  , field "lifetime" (seconds (stLifetime st))
  , field "phases" phasesLine
  , field "fields" (show (stFields st))
  , field "extent" (point lo ++ " .. " ++ point hi)
  ]
  where
    (lo, hi) = stExtent st

    field name body = pad name ++ body
    pad name = name ++ replicate (max 1 (10 - length name)) ' '

    phasesLine = case stPhases st of
      Nothing -> "none (casting starts at 0.000s)"
      Just (Seconds d, Seconds c) ->
        "draw "
          ++ secs d
          ++ " + converge "
          ++ secs c
          ++ " -> casting starts at "
          ++ secs (d + c)

    seconds (Seconds s) = secs s
    secs s = showFFloat (Just 3) s "s"
    coord x = showFFloat (Just 3) (realToFrac x :: Double) ""
    point (V3 x y z) = "(" ++ intercalate ", " (map coord [x, y, z]) ++ ")"

-- | How many files did not pass.
failureCount :: [Report] -> Int
failureCount = length . filter (either (const True) (const False) . repResult)

-- | The process exit code: the number of failing files, clamped so it
-- stays a legal exit status (a run with more than 125 broken spells has
-- bigger problems than the exact count).
exitCodeFor :: [Report] -> Int
exitCodeFor = min 125 . failureCount
