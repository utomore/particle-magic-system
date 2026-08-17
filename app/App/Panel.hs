-- | The in-demo parameter panel (func-spec 0024 S4): change a number, see
-- it immediately.
--
-- __Why this works through JSON rather than through the ADT.__ The panel
-- has to read and write individual numbers inside a 'Circle', and the
-- shell layer cannot see one: @app@ depends on @magic-boundary@ only
-- (func-spec 0001 §3, guarded by @test\/BoundarySpec.hs@), and
-- 'Magic.Interface' re-exports 'Circle' as an opaque type — the rune
-- constructors live in @magic-core@, which this layer physically cannot
-- import. Widening the interface was not available either: func-spec 0024
-- §0.2 puts @src\/*@ out of bounds for this round.
--
-- So the panel edits the circle's /canonical encoding/: 'saveCircle'
-- produces it, a number is replaced at a path, and 'loadCircle' reads it
-- back. That is not a workaround, it is the better design of the two:
--
--   * ADR-0005 already says JSON is the input interface, so a tool that
--     edits spells is working in the right vocabulary;
--   * a 'ParamPath' becomes literally what func-spec 0024 §2.6 asks the
--     panel's state model to be — a path and a 'Double';
--   * and every validation rule stays in exactly one place. @rInner <
--     rOuter@, @inner < outer@, the non-zero @normal@, the positive
--     @lifetime@: this module knows none of them. It proposes a number,
--     and a circle the codec refuses is simply not adopted — the panel
--     visibly sticks instead of building a spell that cannot be saved.
--
-- The cost is a save/load round trip per adjustment. A circle is a few
-- kilobytes of JSON and an adjustment happens when a person presses a key,
-- so that cost is not worth avoiding.
--
-- __What the panel may change__ (func-spec 0024 §2.6): numbers, in slots
-- that already exist. It cannot add or remove a slot, change a rune kind
-- or edit a formula string — those are the editor of §8-1, not this.
module App.Panel
  ( -- * Adjustable parameters
    ParamPath
  , paramPathLabel
  , ParamSpec (..)
  , paramsOf
  , applyParam

    -- * The panel's state machine (pure)
  , PanelState (..)
  , panelClosed
  , PanelAction (..)
  , stepPanel
  , panelViewOf
  , discardedNote
  , savedNote
  , saveFailedNote
  ) where

import Data.Aeson (Value (Array, Number, Object), decodeStrict, encode)
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (toList)
import Data.List (intercalate, sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Vector as V
import Magic.Codec (loadCircle, saveCircle)
import Magic.Interface (Circle)
import Numeric (showFFloat)

import App.Effects (DemoInput (..), PanelView (..))

-- Paths ----------------------------------------------------------------------

-- | One step of a path into the circle's canonical JSON.
data Step
  = Key !String
  | Ix !Int
  deriving (Eq, Ord, Show)

-- | Where a number lives inside a circle. Opaque: a caller gets these
-- from 'paramsOf' and hands them back to 'applyParam', exactly as a host
-- does with 'Magic.Interface.EmitterSpec'.
newtype ParamPath = ParamPath [Step]
  deriving (Eq, Ord, Show)

-- | The path as an author would write it: @outer[0].shape.rOuter@,
-- @core.nodes.north.strength@, @fields[1].falloff@.
paramPathLabel :: ParamPath -> String
paramPathLabel (ParamPath steps) = go True steps
  where
    go _ [] = ""
    go first (Key k : rest) = (if first then k else '.' : k) ++ go False rest
    go first (Ix i : rest) = "[" ++ show i ++ "]" ++ go first rest

-- | One adjustable number.
--
-- 'psStep' is this module's addition to the sketch in func-spec 0024 §3:
-- a nudge needs a stride, and deriving it from the range at the call site
-- would put half of a presentation decision in the loop. It also has to
-- know about counts — a fortieth of the @sides@ range is a change that
-- rounds straight back to where it started.
data ParamSpec = ParamSpec
  { psPath :: !ParamPath
  , psLabel :: !String
  , psMin :: !Double
  , psMax :: !Double
  , psStep :: !Double
  , psValue :: !Double
  }
  deriving (Eq, Show)

-- Enumeration -----------------------------------------------------------------

-- | Every number in the circle, in a stable order: object keys
-- alphabetically, array elements by index.
--
-- Alphabetical rather than declaration order because there is no
-- declaration order to have: 'saveCircle' writes its keys in a chosen
-- sequence, but aeson's 'Object' is a hash map and decoding forgets it.
-- Sorting is the only ordering that is stable across aeson versions, and
-- an author reading @freq / radius / speed@ down a panel is no worse off
-- than one reading them in any other fixed order.
paramsOf :: Circle -> [ParamSpec]
paramsOf circle =
  [ ParamSpec
      { psPath = ParamPath steps
      , psLabel = paramPathLabel (ParamPath steps)
      , psMin = lo
      , psMax = hi
      , psStep = stepFor steps lo hi
      , psValue = value
      }
  | (steps, value) <- numbersIn circle
  , let (lo, hi) = rangeFor steps
  ]

-- | The numbers under @$.circle@ — the top-level @version@ and @name@ are
-- not parameters of the spell, they are what identifies the file.
numbersIn :: Circle -> [([Step], Double)]
numbersIn circle = case decodeStrict (saveCircle circle) of
  Just (Object top)
    | Just body <- KM.lookup (AK.fromString "circle") top ->
        numbersUnder [] body
  _ -> []

numbersUnder :: [Step] -> Value -> [([Step], Double)]
numbersUnder prefix value = case value of
  Object o ->
    concat
      [ numbersUnder (prefix ++ [Key k]) v
      | (k, v) <- sortOn fst [(AK.toString key, sub) | (key, sub) <- KM.toList o]
      ]
  Array items ->
    concat [numbersUnder (prefix ++ [Ix i]) v | (i, v) <- zip [0 ..] (toList items)]
  Number n -> [(prefix, realToFrac n)]
  _ -> []

-- Applying --------------------------------------------------------------------

-- | Put a new value at a path. Total, and conservative: a circle the
-- codec will not read back is not adopted, so the caller always holds a
-- circle that compiles and saves.
--
-- Two candidates are tried, in order: the clamped value itself, and its
-- nearest integer. The second exists because a few fields are /counts/
-- (@sides@, @points@) and the codec reads them as integers — and finding
-- that out by asking the codec, rather than by keeping a list of which
-- fields are counts, means a count added by a later spec needs no change
-- here.
applyParam :: ParamPath -> Double -> Circle -> Circle
applyParam path v circle = fromMaybe circle (listToMaybe (candidates >>= adopt))
  where
    candidates = case [spec | spec <- paramsOf circle, psPath spec == path] of
      (spec : _) ->
        let clamped = min (psMax spec) (max (psMin spec) v)
            rounded = fromIntegral (round clamped :: Integer)
         in if clamped == rounded then [clamped] else [clamped, rounded]
      [] -> []

    adopt x =
      [ circle'
      | Just number <- [jsonNumber x]
      , Just root <- [decodeStrict (saveCircle circle)]
      , Just root' <- [setAt (Key "circle" : stepsOf path) number root]
      , Right circle' <- [loadCircle (BL.toStrict (encode root'))]
      ]

    stepsOf (ParamPath steps) = steps

-- | A JSON number for a 'Double', by way of its own decimal text.
--
-- Going through the text rather than @realToFrac@ is deliberate: the
-- latter converts exactly, so @0.1@ would be written into the file as its
-- full binary expansion. Six decimals is far finer than a keyboard nudge
-- and leaves a file a person can read.
jsonNumber :: Double -> Maybe Value
jsonNumber x
  | isNaN x || isInfinite x = Nothing
  | x == fromIntegral (round x :: Integer) = decodeStrict (BSC.pack (show (round x :: Integer)))
  | otherwise = decodeStrict (BSC.pack (showFFloat (Just 6) x ""))

setAt :: [Step] -> Value -> Value -> Maybe Value
setAt steps new value = case (steps, value) of
  ([], _) -> Just new
  (Key k : rest, Object o) -> do
    sub <- KM.lookup (AK.fromString k) o
    sub' <- setAt rest new sub
    Just (Object (KM.insert (AK.fromString k) sub' o))
  (Ix i : rest, Array items)
    | i >= 0 && i < V.length items -> do
        sub' <- setAt rest new (items V.! i)
        Just (Array (items V.// [(i, sub')]))
  _ -> Nothing

-- Ranges ----------------------------------------------------------------------

-- | What a slider for this field should span.
--
-- Presentation only. Every /semantic/ bound (positive lifetime, ordered
-- radii, non-zero normal) is the codec's, and 'applyParam' finds out about
-- it by being refused. So a range that is slightly too generous costs a
-- nudge that does not move, not a broken spell.
--
-- __A function of the path and nothing else.__ Deriving the range from
-- the current value instead — "four times what it is now", say — reads as
-- an accommodating idea and breaks the overwrite law on the spot: the
-- clamp would then depend on how the circle got here, so setting @2.0@
-- after @0.3@ would land somewhere setting @2.0@ directly does not.
-- A caught-by-property mistake, recorded in func-spec 0024 §10.
rangeFor :: [Step] -> (Double, Double)
rangeFor steps = case fieldKey steps of
  Just "power" -> (0.05, 8)
  Just "shift" -> (0, 10)
  Just "delay" -> (0, 10)
  Just "duration" -> (0, 20)
  Just "lifetime" -> (0.05, 20)
  Just "draw" -> (0.05, 5)
  Just "converge" -> (0, 5)
  Just "speed" -> (-20, 20)
  Just "amplitude" -> (-5, 5)
  Just "freq" -> (-10, 10)
  Just "gravity" -> (-30, 30)
  Just "sweep" -> (0, 2 * pi)
  Just "sides" -> (3, 16)
  Just "points" -> (2, 16)
  Just "softening" -> (0.01, 5)
  Just "falloff" -> (0, 5)
  Just "turbulence" -> (0, 10)
  Just "scale" -> (0.05, 10)
  Just "k" -> (0.01, 50)
  -- The one key two different things are called: a node's drift bias and
  -- a force field's magnitude live in different orders of magnitude, and
  -- the slot they sit in is what says which is which.
  Just "strength"
    | inFields steps -> (-50, 50)
    | otherwise -> (-5, 5)
  Just key
    | key `elem` ["radius", "rInner", "rOuter", "size", "w", "h", "length", "width", "outer", "inner"] ->
        (0, 5)
  -- The vectors, reached one component at a time: 'fieldKey' looks past
  -- the index, so @fields[0].accel[1]@ answers to @accel@.
  Just "accel" -> (-30, 30)
  Just "center" -> (-10, 10)
  Just "offset" -> (-10, 10)
  Just key
    | key `elem` ["axis", "dir", "normal"] -> (-1, 1)
  _ -> (-10, 10)
  where
    inFields path = case path of
      (Key "fields" : _) -> True
      _ -> False

-- | How far one keypress moves a value: a fortieth of the range, except
-- for counts, where the only useful stride is one.
stepFor :: [Step] -> Double -> Double -> Double
stepFor steps lo hi
  | fieldKey steps `elem` [Just "sides", Just "points"] = 1
  | otherwise = (hi - lo) / 40

-- | The last named field on the path, looking past any array indices —
-- a vector's component belongs to the vector.
fieldKey :: [Step] -> Maybe String
fieldKey steps = case [k | Key k <- reverse steps] of
  (k : _) -> Just k
  [] -> Nothing

-- The panel's state machine ----------------------------------------------------

-- | Everything the panel remembers between frames. Small on purpose: the
-- circle itself is the loop's, and this only says which of its numbers is
-- selected and whether the file is behind.
data PanelState = PanelState
  { pnOpen :: !Bool
  , pnIndex :: !Int
  -- ^ Which parameter is selected, as an index into 'paramsOf'. An index
  -- rather than a path because the list is rebuilt from the circle every
  -- frame and a path that stopped existing would have to mean something.
  , pnDirty :: !Bool
  -- ^ Edited since the last save (or since the file was loaded).
  , pnNote :: !(Maybe String)
  -- ^ The last thing worth telling the author, for the HUD.
  }
  deriving (Eq, Show)

panelClosed :: PanelState
panelClosed = PanelState {pnOpen = False, pnIndex = 0, pnDirty = False, pnNote = Nothing}

-- | What the loop has to do in IO after a pure panel step.
data PanelAction
  = PanelIdle
  | -- | The circle changed: re-cast it.
    PanelRecast
  | -- | Write the circle to the file it came from.
    PanelSave
  deriving (Eq, Show)

-- | One frame of panel input.
--
-- __The zero-input law__: with no panel key pressed this is the identity
-- on the state, on the circle and on the action — so a demo nobody touches
-- runs exactly as it did before this module existed. With the panel
-- /closed/ the adjustment keys do nothing at all, which is what keeps
-- @[-]@ and @[=]@ from being a hidden way to edit a file.
stepPanel :: DemoInput -> Circle -> PanelState -> (PanelState, Circle, PanelAction)
stepPanel input circle st0
  | not (pnOpen opened) = (opened, circle, PanelIdle)
  | diPanelSave input = (opened, circle, PanelSave)
  | otherwise = case selected of
      Nothing -> (moved, circle, PanelIdle)
      Just spec
        | nudge == 0 -> (moved, circle, PanelIdle)
        | otherwise ->
            ( moved {pnDirty = True, pnNote = Nothing}
            , applyParam (psPath spec) (psValue spec + nudge * psStep spec) circle
            , PanelRecast
            )
  where
    opened
      | diTogglePanel input = st0 {pnOpen = not (pnOpen st0), pnNote = Nothing}
      | otherwise = st0

    specs = paramsOf circle
    count = length specs

    moved
      | count == 0 = opened {pnIndex = 0}
      | otherwise = opened {pnIndex = (pnIndex opened + delta) `mod` count}

    delta =
      (if diPanelNext input then 1 else 0) - (if diPanelPrev input then 1 else 0)

    selected = case drop (pnIndex moved) specs of
      (spec : _) -> Just spec
      [] -> Nothing

    nudge =
      (if diPanelInc input then 1 else 0) - (if diPanelDec input then 1 else 0) :: Double

-- | What the HUD is told. Built here so the loop does not have to know
-- what a parameter is, and so a headless test reads exactly what a player
-- would see.
panelViewOf :: Circle -> PanelState -> PanelView
panelViewOf circle st =
  PanelView
    { pvOpen = pnOpen st
    , pvDirty = pnDirty st
    , pvIndex = pnIndex st
    , pvParams =
        [ (psLabel spec, psValue spec)
        | pnOpen st
        , spec <- paramsOf circle
        ]
    , pvNote = pnNote st
    }

-- | The three sentences the loop needs, in one place so the HUD text and
-- the tests that assert on it cannot drift.
discardedNote :: String -> String
discardedNote why = "unsaved panel edits discarded (" ++ why ++ ")"

savedNote :: FilePath -> String
savedNote path = "saved to " ++ path ++ " (rewritten in canonical form)"

saveFailedNote :: FilePath -> String -> String
saveFailedNote path err = "could not save " ++ path ++ ": " ++ oneLine err
  where
    oneLine = intercalate "; " . lines
