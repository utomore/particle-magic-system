{-# LANGUAGE OverloadedStrings #-}

-- | JSON codec for the spell-file contract (spec 0002 §4.7, ADR-0005).
--
-- Schema v1, full slot form. Backward compatible with the 0001 skeleton
-- subset: a missing key, @null@ and an absent array element all mean "empty
-- slot", so @"circle": {}@ still decodes to 'emptyCircle' and the shipped
-- @empty.json@ loads byte-for-byte unchanged.
--
-- Runes are tagged by a @"rune"@ field. Valid tags: outer @shape@ |
-- @radiate@ | @range@ | @style@ (spec 0015),
-- bridge @phase@ | @converge@ | @amplify@, inner
-- @trajectory@ | @timing@ | @formula@, nodes @dir-bias@ (the Expr-payload
-- tags added by spec 0004 §4.6). Unknown tags are load errors listing the
-- valid tags for that slot. All new errors go through the frozen
-- 'LoadError' machinery as 'JsonError' with an aeson JSON path
-- (e.g. @$.circle.inner[0]@) — no new constructors.
--
-- Formula fields are strings parsed here with 'parseExpr' (spec 0003's
-- gatekeeper: syntax, unknown names, the node budget and non-literal
-- @chan@ arguments are all rejected at load time); a failure becomes an
-- aeson 'Parser' failure whose message is 'renderExprParseError' (with
-- line/column), wrapped in 'JsonError' with the JSON path.
--
-- Parameter validation happens here, at the boundary (the core does no
-- defensive checks): geometry must be positive (@rInner < rOuter@),
-- @power > 0@, envelope fields non-negative with @lifetime > 0@,
-- @shift >= 0@, trajectory radii positive.
module Magic.Codec
  ( loadCircle
  , saveCircle
  , LoadError (..)
  , renderLoadError
  ) where

import Data.Aeson
  ( Object
  , Value (Array, Null, Object)
  , eitherDecodeStrict
  , encode
  , object
  , parseJSON
  , toJSON
  , withObject
  , withText
  , (.=)
  )
import qualified Data.Aeson.Key as AK
import Data.Aeson.Types
  ( JSONPathElement (Index, Key)
  , Pair
  , Parser
  , parseEither
  , (.:)
  , (.:?)
  , (<?>)
  )
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Text (Text)
import qualified Data.Text as T
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Expr (Expr, ExprV3 (..))
import Magic.Expr.Parse (parseExpr, renderExpr, renderExprParseError)
import Magic.Rune
  ( BillboardShape (..)
  , BridgeRune (..)
  , Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , ForceField (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..), V2 (..), V3 (..))

data LoadError
  = -- | Malformed JSON or wrong shape; message includes aeson's
    -- position path.
    JsonError String
  | -- | @version@ field present but not a version this codec accepts.
    UnsupportedVersion Int
  deriving (Eq, Show)

renderLoadError :: LoadError -> String
renderLoadError err = case err of
  JsonError msg -> "spell JSON error: " ++ msg
  UnsupportedVersion v ->
    "unsupported spell schema version " ++ show v ++ " (this build reads version 1)"

-- | Decode a spell file (strict bytes — the file handle is released before
-- hot reload re-reads it).
loadCircle :: BS.ByteString -> Either LoadError Circle
loadCircle bytes = do
  value <- first (JsonError . addPosition bytes) (eitherDecodeStrict bytes)
  version <- first JsonError (parseEither parseVersion value)
  if version /= 1
    then Left (UnsupportedVersion version)
    else first JsonError (parseEither parseCircleV1 value)

-- | aeson's syntax errors quote the unconsumed input at the failure point
-- (@Unexpected "…"@) but give no coordinates. Locate that fragment in the
-- source and append @line L, column C@ so spell authors can find the typo.
addPosition :: BS.ByteString -> String -> String
addPosition input msg
  | Just fragment <- unexpectedFragment
  , Just offset <- findSubstring fragment source =
      msg ++ positionAt offset
  | "end-of-input" `isInfixOf` msg = msg ++ positionAt (length source)
  | otherwise = msg
  where
    source = BSC.unpack input

    unexpectedFragment = do
      rest <- stripToInfix "Unexpected " msg
      case reads rest :: [(String, String)] of
        [(fragment, _)] | not (null fragment) -> Just fragment
        _ -> Nothing

    positionAt offset =
      let consumed = take offset source
          line = 1 + length (filter (== '\n') consumed)
          column = 1 + length (takeWhile (/= '\n') (reverse consumed))
       in " (line " ++ show line ++ ", column " ++ show column ++ ")"

    stripToInfix needle haystack =
      case filter (needle `isPrefixOf`) (tails haystack) of
        (found : _) -> Just (drop (length needle) found)
        [] -> Nothing

    findSubstring needle haystack =
      case [i | (i, t) <- zip [0 :: Int ..] (tails haystack), needle `isPrefixOf` t] of
        (i : _) -> Just i
        [] -> Nothing

parseVersion :: Value -> Parser Int
parseVersion = withObject "SpellFile" (.: "version")

-- Decoding ------------------------------------------------------------------

parseCircleV1 :: Value -> Parser Circle
parseCircleV1 = withObject "SpellFile" $ \o -> do
  _name <- o .:? "name" :: Parser (Maybe Text)
  circleValue <- o .: "circle"
  parseCircle circleValue <?> Key "circle"

parseCircle :: Value -> Parser Circle
parseCircle = withObject "circle" $ \o -> do
  outer <- parseRingPair "outer" parseOuterRune o
  bridge <- parseSlot "bridge" parseBridgeRune o
  inner <- parseRingPair "inner" parseInnerRune o
  coreValue <- slotValue o "core"
  circleCore <- case coreValue of
    Nothing -> pure emptyCore
    Just v -> parseCore v <?> Key "core"
  phases <- parseSlot "phases" parsePhaseConfig o
  fields <- parseFields o
  pure
    Circle
      { outerRings = outer
      , interLayer = bridge
      , innerRings = inner
      , core = circleCore
      , circlePhases = phases
      , circleFields = fields
      }

emptyCore :: Core
emptyCore = Core Nothing (Nodes Nothing Nothing Nothing Nothing)

-- | A key whose absence and JSON @null@ both mean "empty slot".
slotValue :: Object -> AK.Key -> Parser (Maybe Value)
slotValue o key = do
  mv <- o .:? key
  pure $ case mv of
    Just Null -> Nothing
    other -> other

parseSlot :: AK.Key -> (Value -> Parser a) -> Object -> Parser (Maybe a)
parseSlot key p o = do
  mv <- slotValue o key
  traverse (\v -> p v <?> Key key) mv

-- | A ring pair is an array of 0–2 slots; index 0 = inner layer (ringA),
-- index 1 = outer layer (ringB). Missing entries are empty slots; more
-- than 2 entries is a load error.
parseRingPair :: AK.Key -> (Value -> Parser a) -> Object -> Parser (TwoOf (Maybe a))
parseRingPair key p o = do
  mv <- slotValue o key
  case mv of
    Nothing -> pure (TwoOf Nothing Nothing)
    Just v -> flip (<?>) (Key key) $ case v of
      Array items
        | length items > 2 ->
            fail $
              "ring array has "
                ++ show (length items)
                ++ " layers; a ring holds at most 2 (index 0 = inner layer, 1 = outer layer)"
        | otherwise -> do
            let layers = toList items
            a <- parseAt layers 0
            b <- parseAt layers 1
            pure (TwoOf a b)
      _ -> fail "expected an array of ring layers (or null)"
  where
    parseAt layers i = case drop i layers of
      [] -> pure Nothing
      (Null : _) -> pure Nothing
      (v : _) -> Just <$> (p v <?> Index i)

-- Rune parsers ---------------------------------------------------------------

runeTag :: String -> [T.Text] -> Value -> (T.Text -> Object -> Parser a) -> Parser a
runeTag slotName valid v k = withObject slotName go v
  where
    go o = do
      tag <- o .: "rune"
      if tag `elem` valid
        then k tag o
        else
          fail $
            "unknown rune tag "
              ++ show (T.unpack tag)
              ++ " for the "
              ++ slotName
              ++ "; valid tags here: "
              ++ T.unpack (T.intercalate ", " valid)

parseOuterRune :: Value -> Parser OuterRune
parseOuterRune = \v ->
  runeTag "outer ring slot" ["shape", "radiate", "range", "style"] v $ \tag o -> case tag of
    "shape" -> do
      shapeValue <- o .: "shape"
      ShapeRune <$> (parseFaceShape shapeValue <?> Key "shape")
    "range" -> RangeRune <$> exprField o "expr"
    -- The key is "billboard", not "shape": "shape" is already the
    -- ShapeRune's face-geometry key (spec 0015 §1 point 3).
    "style" -> StyleRune <$> ((o .: "billboard" >>= parseBillboard) <?> Key "billboard")
    _ -> RadiateRune <$> (o .: "mode" >>= parseRadiationMode)

parseBillboard :: Value -> Parser BillboardShape
parseBillboard = withText "billboard" $ \t -> case t of
  "square" -> pure BillboardSquare
  "soft-dot" -> pure BillboardSoftDot
  "ring" -> pure BillboardRing
  "spark" -> pure BillboardSpark
  other ->
    fail $
      "unknown billboard "
        ++ show (T.unpack other)
        ++ "; valid billboards: square, soft-dot, ring, spark"

parseFaceShape :: Value -> Parser FaceShape
parseFaceShape = withObject "shape" $ \o -> do
  kind <- o .: "kind" :: Parser Text
  case kind of
    "hollow-square" -> HollowSquare <$> (o .: "size" >>= positive "size")
    "rect" -> do
      w <- o .: "w" >>= positive "w"
      h <- o .: "h" >>= positive "h"
      pure (Rect (V2 (realToFrac w) (realToFrac h)))
    "ring" -> do
      rIn <- o .: "rInner" >>= positive "rInner"
      rOut <- o .: "rOuter" >>= positive "rOuter"
      if rIn < rOut
        then pure (Ring rIn rOut)
        else fail $ "ring needs rInner < rOuter, got rInner = " ++ show rIn ++ ", rOuter = " ++ show rOut
    "diamond" -> Diamond <$> (o .: "size" >>= positive "size")
    -- Func-spec 0021's four. Validation mirrors what the samplers assume:
    -- a polygon needs three sides to have an interior, a star needs two
    -- points, and both ring-like shapes need their radii ordered.
    "polygon" -> do
      sides <- o .: "sides" >>= atLeastInt "sides" 3
      radius <- o .: "radius" >>= positive "radius"
      pure (Polygon sides radius)
    "star" -> do
      points <- o .: "points" >>= atLeastInt "points" 2
      outer <- o .: "outer" >>= positive "outer"
      inner <- o .: "inner" >>= nonNegative "inner"
      if inner < outer
        then pure (Star points outer inner)
        else
          fail $
            "star needs inner < outer, got inner = "
              ++ show inner
              ++ ", outer = "
              ++ show outer
    "cross" -> do
      len <- o .: "length" >>= positive "length"
      width <- o .: "width" >>= positive "width"
      pure (Cross len width)
    "sector" -> do
      inner <- o .: "inner" >>= nonNegative "inner"
      outer <- o .: "outer" >>= positive "outer"
      sweep <- o .: "sweep" >>= inRange "sweep" 0 (2 * pi)
      if inner < outer
        then pure (Sector inner outer sweep)
        else
          fail $
            "sector needs inner < outer, got inner = "
              ++ show inner
              ++ ", outer = "
              ++ show outer
    other ->
      fail $
        "unknown shape kind "
          ++ show (T.unpack other)
          ++ "; valid kinds: hollow-square, rect, ring, diamond, polygon, star, cross, sector"

parseRadiationMode :: Value -> Parser RadiationMode
parseRadiationMode = withText "mode" $ \t -> case t of
  "along-normal" -> pure AlongNormal
  "radial-outward" -> pure RadialOutward
  "radial-inward" -> pure RadialInward
  "tangential-swirl" -> pure TangentialSwirl
  other ->
    fail $
      "unknown radiation mode "
        ++ show (T.unpack other)
        ++ "; valid modes: along-normal, radial-outward, radial-inward, tangential-swirl"

parseBridgeRune :: Value -> Parser BridgeRune
parseBridgeRune = \v ->
  runeTag "bridge slot" ["phase", "converge", "amplify"] v $ \tag o -> case tag of
    "converge" -> ConvergeRune <$> exprField o "expr"
    "amplify" -> AmplifyRune <$> exprField o "expr"
    _ -> do
      shift <- o .: "shift" >>= nonNegative "shift"
      pure (PhaseRune (Seconds shift))

parseInnerRune :: Value -> Parser InnerRune
parseInnerRune = \v ->
  runeTag "inner ring slot" ["trajectory", "timing", "formula"] v $ \tag o -> case tag of
    "trajectory" -> TrajectoryRune <$> parseTrajectory o
    "formula" ->
      FormulaRune
        <$> (ExprV3 <$> exprField o "x" <*> exprField o "y" <*> exprField o "z")
    _ -> TimingRune <$> parseEnvelope o

parseTrajectory :: Object -> Parser Trajectory
parseTrajectory o = do
  kind <- o .: "kind" :: Parser Text
  case kind of
    "forward" -> Forward <$> o .: "speed"
    "spiral" -> do
      speed <- o .: "speed"
      radius <- o .: "radius" >>= positive "radius"
      freq <- o .: "freq"
      pure (Spiral speed radius freq)
    "orbit" -> do
      radius <- o .: "radius" >>= positive "radius"
      freq <- o .: "freq"
      pure (Orbit radius freq)
    -- Func-spec 0021's four. Frequencies are non-negative (a negative one
    -- is the same path traced the other way and would only be a second
    -- spelling of the same spell); amplitudes and speeds stay free, since
    -- a negative one is a meaningful mirror.
    "wave" -> do
      speed <- o .: "speed"
      amplitude <- o .: "amplitude"
      freq <- o .: "freq" >>= nonNegative "freq"
      pure (Wave speed amplitude freq)
    "ballistic" -> do
      speed <- o .: "speed"
      gravity <- o .: "gravity"
      pure (Ballistic speed gravity)
    "pulse" -> do
      speed <- o .: "speed"
      freq <- o .: "freq" >>= nonNegative "freq"
      pure (Pulse speed freq)
    "zigzag" -> do
      speed <- o .: "speed"
      amplitude <- o .: "amplitude"
      freq <- o .: "freq" >>= nonNegative "freq"
      pure (Zigzag speed amplitude freq)
    other ->
      fail $
        "unknown trajectory kind "
          ++ show (T.unpack other)
          ++ "; valid kinds: forward, spiral, orbit, wave, ballistic, pulse, zigzag"

parseEnvelope :: Object -> Parser Envelope
parseEnvelope o = do
  delay <- o .: "delay" >>= nonNegative "delay"
  duration <- o .: "duration" >>= nonNegative "duration"
  lifetime <- o .: "lifetime" >>= positive "lifetime"
  pure (Envelope (Seconds delay) (Seconds duration) (Seconds lifetime))

parseCore :: Value -> Parser Core
parseCore = withObject "core" $ \o -> do
  center <- parseSlot "center" parseEssence o
  nodesValue <- slotValue o "nodes"
  nodes <- case nodesValue of
    Nothing -> pure (Nodes Nothing Nothing Nothing Nothing)
    Just v -> parseNodes v <?> Key "nodes"
  pure (Core center nodes)

-- | Force fields (spec 0007 §4.6): an opt-in circle-level array, not a
-- rune slot. A missing key and @null@ both mean "no fields", which is the
-- ADR-0010 D9 compatibility case every pre-0007 spell file takes.
parseFields :: Object -> Parser [ForceField]
parseFields o = do
  mv <- slotValue o "fields"
  case mv of
    Nothing -> pure []
    Just v -> flip (<?>) (Key "fields") $ case v of
      Array items ->
        sequence [parseForceField item <?> Index i | (i, item) <- zip [0 ..] (toList items)]
      _ -> fail "expected an array of force fields (or null)"

-- | Field validation lives here, at the boundary: 'softening' keeps the
-- attractor's singularity finite, 'falloff' may not amplify with
-- distance, and a zero 'axis' has no swirl plane to define. The core
-- normalizes the axis when it evaluates, so any non-zero vector is fine.
parseForceField :: Value -> Parser ForceField
parseForceField = withObject "force field" $ \o -> do
  kind <- o .: "kind" :: Parser Text
  case kind of
    "gravity" -> Gravity <$> vec3Field o "accel"
    "attractor" -> do
      center <- vec3Field o "center"
      strength <- o .: "strength"
      softening <- o .: "softening" >>= positive "softening"
      pure (PointAttractor center (realToFrac (strength :: Double)) (realToFrac softening))
    "vortex" -> do
      center <- vec3Field o "center"
      axis <- vec3Field o "axis"
      _ <- nonZeroAxis axis <?> Key "axis"
      strength <- o .: "strength"
      falloff <- o .: "falloff" >>= nonNegative "falloff"
      pure (Vortex center axis (realToFrac (strength :: Double)) (realToFrac falloff))
    -- Func-spec 0021's three. 'dir' gets the same non-zero check 'axis'
    -- gets and for the same reason: the core normalizes it, so a zero
    -- vector would silently mean "no wind" instead of being rejected.
    "wind" -> do
      dir <- vec3Field o "dir"
      _ <- nonZeroAxis dir <?> Key "dir"
      strength <- o .: "strength"
      turbulence <- o .: "turbulence" >>= nonNegative "turbulence"
      pure (Wind dir (realToFrac (strength :: Double)) (realToFrac turbulence))
    "turbulence" -> do
      strength <- o .: "strength"
      scale <- o .: "scale" >>= positive "scale"
      pure (Turbulence (realToFrac (strength :: Double)) (realToFrac scale))
    "spring" -> do
      center <- vec3Field o "center"
      k <- o .: "k" >>= positive "k"
      pure (Spring center (realToFrac k))
    other ->
      fail $
        "unknown force field kind "
          ++ show (T.unpack other)
          ++ "; valid kinds: gravity, attractor, vortex, wind, turbulence, spring"

-- | A @[x, y, z]@ array of numbers.
vec3Field :: Object -> AK.Key -> Parser V3
vec3Field o key = do
  v <- o .: key
  flip (<?>) (Key key) $ case v of
    Array items -> case toList items of
      [x, y, z] -> V3 <$> number x <*> number y <*> number z
      other ->
        fail $
          "expected an array of 3 numbers, got " ++ show (length other) ++ " elements"
    _ -> fail "expected an array of 3 numbers"
  where
    number val = realToFrac <$> (parseJSON val :: Parser Double)

nonZeroAxis :: V3 -> Parser ()
nonZeroAxis (V3 x y z)
  | x /= 0 || y /= 0 || z /= 0 = pure ()
  | otherwise = fail "axis must be a non-zero vector"

-- | Lifecycle staging (spec 0006 §4.5): opt-in circle-level key, not a
-- rune slot — no "rune" tag, just the two durations.
parsePhaseConfig :: Value -> Parser PhaseConfig
parsePhaseConfig = withObject "phases" $ \o -> do
  draw <- o .: "draw" >>= positive "draw"
  converge <- o .: "converge" >>= nonNegative "converge"
  pure (PhaseConfig (Seconds draw) (Seconds converge))

parseEssence :: Value -> Parser EssenceRune
parseEssence = withObject "core center" $ \o -> do
  element <- o .: "element" >>= parseElement
  power <- o .: "power" >>= positive "power"
  pure (EssenceRune element power)

parseElement :: Value -> Parser Element
parseElement = withText "element" $ \t -> case t of
  "neutral" -> pure Neutral
  "fire" -> pure Fire
  "water" -> pure Water
  "lightning" -> pure Lightning
  "metal" -> pure Metal
  "wood" -> pure Wood
  "earth" -> pure Earth
  "yin" -> pure Yin
  "yang" -> pure Yang
  other ->
    fail $
      "unknown element "
        ++ show (T.unpack other)
        ++ "; valid elements: neutral, fire, water, lightning, "
        ++ "metal, wood, earth, yin, yang"

parseNodes :: Value -> Parser (Nodes (Maybe NodeRune))
parseNodes = withObject "nodes" $ \o ->
  Nodes
    <$> parseSlot "north" parseNodeRune o
    <*> parseSlot "south" parseNodeRune o
    <*> parseSlot "east" parseNodeRune o
    <*> parseSlot "west" parseNodeRune o

parseNodeRune :: Value -> Parser NodeRune
parseNodeRune = \v ->
  runeTag "core node slot" ["dir-bias"] v $ \_tag o ->
    DirBias <$> o .: "strength"

-- | A formula string field: parsed with 'parseExpr' right here at the
-- boundary, so a 'Right' circle never carries an unchecked formula. The
-- failure message is 'renderExprParseError' (line/column position); aeson
-- prepends the JSON path (spec 0004 §4.6).
exprField :: Object -> AK.Key -> Parser Expr
exprField o key = do
  raw <- o .: key :: Parser Text
  case parseExpr raw of
    Right e -> pure e
    Left err ->
      fail ("invalid formula:\n" ++ renderExprParseError err) <?> Key key

-- Validation helpers ---------------------------------------------------------

positive :: String -> Double -> Parser Double
positive name x
  | x > 0 = pure x
  | otherwise = fail $ name ++ " must be > 0, got " ++ show x

nonNegative :: String -> Double -> Parser Double
nonNegative name x
  | x >= 0 = pure x
  | otherwise = fail $ name ++ " must be >= 0, got " ++ show x

-- | A count with a floor (func-spec 0021): a polygon with two sides and a
-- star with one point have no interior to sample.
atLeastInt :: String -> Int -> Int -> Parser Int
atLeastInt name lo x
  | x >= lo = pure x
  | otherwise = fail $ name ++ " must be >= " ++ show lo ++ ", got " ++ show x

-- | A half-open range @(lo, hi]@: the sector's sweep may be a full turn
-- but not a degenerate zero one.
inRange :: String -> Double -> Double -> Double -> Parser Double
inRange name lo hi x
  | x > lo && x <= hi = pure x
  | otherwise =
      fail $
        name ++ " must be > " ++ show lo ++ " and <= " ++ show hi ++ ", got " ++ show x

-- Encoding -------------------------------------------------------------------

-- | Encode a circle back to the v1 schema. @loadCircle . saveCircle ≡ Right@
-- (roundtrip guarded by the S2 property test). Empty slots encode as
-- explicit @null@ — decodable by the same rules as missing keys.
saveCircle :: Circle -> BS.ByteString
saveCircle circle =
  BL.toStrict . encode $
    object
      [ "version" .= (1 :: Int)
      , "name" .= ("unnamed" :: Text)
      , "circle"
          .= object
            [ "outer" .= encodeRing encodeOuterRune (outerRings circle)
            , "bridge" .= maybe Null encodeBridgeRune (interLayer circle)
            , "inner" .= encodeRing encodeInnerRune (innerRings circle)
            , "core" .= encodeCore (core circle)
            , "phases" .= maybe Null encodePhaseConfig (circlePhases circle)
            , "fields" .= map encodeForceField (circleFields circle)
            ]
      ]

encodeRing :: (a -> Value) -> TwoOf (Maybe a) -> Value
encodeRing enc (TwoOf a b) = toJSON [maybe Null enc a, maybe Null enc b]

encodeOuterRune :: OuterRune -> Value
encodeOuterRune rune = case rune of
  ShapeRune shape -> object ["rune" .= ("shape" :: Text), "shape" .= encodeFaceShape shape]
  RadiateRune mode -> object ["rune" .= ("radiate" :: Text), "mode" .= encodeRadiationMode mode]
  RangeRune e -> object ["rune" .= ("range" :: Text), "expr" .= renderExpr e]
  StyleRune shape -> object ["rune" .= ("style" :: Text), "billboard" .= encodeBillboard shape]

encodeBillboard :: BillboardShape -> Text
encodeBillboard shape = case shape of
  BillboardSquare -> "square"
  BillboardSoftDot -> "soft-dot"
  BillboardRing -> "ring"
  BillboardSpark -> "spark"

encodeFaceShape :: FaceShape -> Value
encodeFaceShape shape = case shape of
  HollowSquare size -> object ["kind" .= ("hollow-square" :: Text), "size" .= size]
  Rect (V2 w h) -> object ["kind" .= ("rect" :: Text), "w" .= w, "h" .= h]
  Ring rIn rOut -> object ["kind" .= ("ring" :: Text), "rInner" .= rIn, "rOuter" .= rOut]
  Diamond size -> object ["kind" .= ("diamond" :: Text), "size" .= size]
  Polygon sides radius ->
    object ["kind" .= ("polygon" :: Text), "sides" .= sides, "radius" .= radius]
  Star points outer inner ->
    object
      [ "kind" .= ("star" :: Text)
      , "points" .= points
      , "outer" .= outer
      , "inner" .= inner
      ]
  Cross len width ->
    object ["kind" .= ("cross" :: Text), "length" .= len, "width" .= width]
  Sector inner outer sweep ->
    object
      [ "kind" .= ("sector" :: Text)
      , "inner" .= inner
      , "outer" .= outer
      , "sweep" .= sweep
      ]

encodeRadiationMode :: RadiationMode -> Text
encodeRadiationMode mode = case mode of
  AlongNormal -> "along-normal"
  RadialOutward -> "radial-outward"
  RadialInward -> "radial-inward"
  TangentialSwirl -> "tangential-swirl"

encodeBridgeRune :: BridgeRune -> Value
encodeBridgeRune rune = case rune of
  PhaseRune (Seconds shift) -> object ["rune" .= ("phase" :: Text), "shift" .= shift]
  ConvergeRune e -> object ["rune" .= ("converge" :: Text), "expr" .= renderExpr e]
  AmplifyRune e -> object ["rune" .= ("amplify" :: Text), "expr" .= renderExpr e]

encodeInnerRune :: InnerRune -> Value
encodeInnerRune rune = case rune of
  -- A formula trajectory is only reachable through 'FormulaRune' in the
  -- schema, so both spellings encode to the same "formula" object (they
  -- compile identically).
  TrajectoryRune (Formula v3) -> encodeFormula v3
  TrajectoryRune t -> object (("rune" .= ("trajectory" :: Text)) : trajectoryFields t)
  TimingRune (Envelope (Seconds d) (Seconds dur) (Seconds life)) ->
    object
      [ "rune" .= ("timing" :: Text)
      , "delay" .= d
      , "duration" .= dur
      , "lifetime" .= life
      ]
  FormulaRune v3 -> encodeFormula v3

encodeFormula :: ExprV3 -> Value
encodeFormula (ExprV3 x y z) =
  object
    [ "rune" .= ("formula" :: Text)
    , "x" .= renderExpr x
    , "y" .= renderExpr y
    , "z" .= renderExpr z
    ]

trajectoryFields :: Trajectory -> [Pair]
trajectoryFields t = case t of
  Forward speed -> ["kind" .= ("forward" :: Text), "speed" .= speed]
  Spiral speed radius freq ->
    ["kind" .= ("spiral" :: Text), "speed" .= speed, "radius" .= radius, "freq" .= freq]
  Orbit radius freq ->
    ["kind" .= ("orbit" :: Text), "radius" .= radius, "freq" .= freq]
  Wave speed amplitude freq ->
    ["kind" .= ("wave" :: Text), "speed" .= speed, "amplitude" .= amplitude, "freq" .= freq]
  Ballistic speed gravity ->
    ["kind" .= ("ballistic" :: Text), "speed" .= speed, "gravity" .= gravity]
  Pulse speed freq ->
    ["kind" .= ("pulse" :: Text), "speed" .= speed, "freq" .= freq]
  Zigzag speed amplitude freq ->
    ["kind" .= ("zigzag" :: Text), "speed" .= speed, "amplitude" .= amplitude, "freq" .= freq]
  -- Unreachable: encodeInnerRune intercepts formula trajectories above;
  -- kept total for the exhaustiveness check.
  Formula (ExprV3 x y z) ->
    ["x" .= renderExpr x, "y" .= renderExpr y, "z" .= renderExpr z]

encodeCore :: Core -> Value
encodeCore c =
  object
    [ "center" .= maybe Null encodeEssence (coreCenter c)
    , "nodes"
        .= object
          [ "north" .= encodeNodeSlot (north nodes)
          , "south" .= encodeNodeSlot (south nodes)
          , "east" .= encodeNodeSlot (east nodes)
          , "west" .= encodeNodeSlot (west nodes)
          ]
    ]
  where
    nodes = coreNodes c

encodeEssence :: EssenceRune -> Value
encodeEssence (EssenceRune element power) =
  object ["element" .= encodeElement element, "power" .= power]

encodeElement :: Element -> Text
encodeElement e = case e of
  Neutral -> "neutral"
  Fire -> "fire"
  Water -> "water"
  Lightning -> "lightning"
  Metal -> "metal"
  Wood -> "wood"
  Earth -> "earth"
  Yin -> "yin"
  Yang -> "yang"

encodePhaseConfig :: PhaseConfig -> Value
encodePhaseConfig (PhaseConfig (Seconds d) (Seconds c)) =
  object ["draw" .= d, "converge" .= c]

encodeForceField :: ForceField -> Value
encodeForceField field = case field of
  Gravity accel -> object ["kind" .= ("gravity" :: Text), "accel" .= encodeV3 accel]
  PointAttractor center strength softening ->
    object
      [ "kind" .= ("attractor" :: Text)
      , "center" .= encodeV3 center
      , "strength" .= toDouble strength
      , "softening" .= toDouble softening
      ]
  Vortex center axis strength falloff ->
    object
      [ "kind" .= ("vortex" :: Text)
      , "center" .= encodeV3 center
      , "axis" .= encodeV3 axis
      , "strength" .= toDouble strength
      , "falloff" .= toDouble falloff
      ]
  Wind dir strength turbulence ->
    object
      [ "kind" .= ("wind" :: Text)
      , "dir" .= encodeV3 dir
      , "strength" .= toDouble strength
      , "turbulence" .= toDouble turbulence
      ]
  Turbulence strength scale ->
    object
      [ "kind" .= ("turbulence" :: Text)
      , "strength" .= toDouble strength
      , "scale" .= toDouble scale
      ]
  Spring center k ->
    object
      [ "kind" .= ("spring" :: Text)
      , "center" .= encodeV3 center
      , "k" .= toDouble k
      ]

encodeV3 :: V3 -> Value
encodeV3 (V3 x y z) = toJSON (map toDouble [x, y, z])

-- | Float widens to Double exactly, and the JSON literal aeson writes for
-- it reads back to the same Double — so the field roundtrip is lossless.
toDouble :: Float -> Double
toDouble = realToFrac

encodeNodeSlot :: Maybe NodeRune -> Value
encodeNodeSlot slot = case slot of
  Nothing -> Null
  Just (DirBias strength) -> object ["rune" .= ("dir-bias" :: Text), "strength" .= strength]
