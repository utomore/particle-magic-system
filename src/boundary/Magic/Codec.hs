{-# LANGUAGE OverloadedStrings #-}

-- | JSON codec for the spell-file contract (spec 0002 §4.7, ADR-0005).
--
-- Schema v1, full slot form. Backward compatible with the 0001 skeleton
-- subset: a missing key, @null@ and an absent array element all mean "empty
-- slot", so @"circle": {}@ still decodes to 'emptyCircle' and the shipped
-- @empty.json@ loads byte-for-byte unchanged.
--
-- Runes are tagged by a @"rune"@ field. Valid tags this round:
-- outer @shape@ | @radiate@, bridge @phase@, inner @trajectory@ | @timing@,
-- nodes @dir-bias@. Unknown tags (including future spec-0003 tags) are load
-- errors listing the valid tags for that slot. All new errors go through
-- the frozen 'LoadError' machinery as 'JsonError' with an aeson JSON path
-- (e.g. @$.circle.inner[0]@) — no new constructors.
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
import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..), emptyCircle)
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..), V2 (..))

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
  pure
    Circle
      { outerRings = outer
      , interLayer = bridge
      , innerRings = inner
      , core = circleCore
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
  runeTag "outer ring slot" ["shape", "radiate"] v $ \tag o -> case tag of
    "shape" -> do
      shapeValue <- o .: "shape"
      ShapeRune <$> (parseFaceShape shapeValue <?> Key "shape")
    _ -> RadiateRune <$> (o .: "mode" >>= parseRadiationMode)

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
    other ->
      fail $
        "unknown shape kind "
          ++ show (T.unpack other)
          ++ "; valid kinds: hollow-square, rect, ring, diamond"

parseRadiationMode :: Value -> Parser RadiationMode
parseRadiationMode = withText "mode" $ \t -> case t of
  "along-normal" -> pure AlongNormal
  "radial-outward" -> pure RadialOutward
  other ->
    fail $
      "unknown radiation mode "
        ++ show (T.unpack other)
        ++ "; valid modes: along-normal, radial-outward"

parseBridgeRune :: Value -> Parser BridgeRune
parseBridgeRune = \v ->
  runeTag "bridge slot" ["phase"] v $ \_tag o -> do
    shift <- o .: "shift" >>= nonNegative "shift"
    pure (PhaseRune (Seconds shift))

parseInnerRune :: Value -> Parser InnerRune
parseInnerRune = \v ->
  runeTag "inner ring slot" ["trajectory", "timing"] v $ \tag o -> case tag of
    "trajectory" -> TrajectoryRune <$> parseTrajectory o
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
    other ->
      fail $
        "unknown trajectory kind "
          ++ show (T.unpack other)
          ++ "; valid kinds: forward, spiral, orbit"

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
  other ->
    fail $
      "unknown element "
        ++ show (T.unpack other)
        ++ "; valid elements: neutral, fire, water, lightning"

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

-- Validation helpers ---------------------------------------------------------

positive :: String -> Double -> Parser Double
positive name x
  | x > 0 = pure x
  | otherwise = fail $ name ++ " must be > 0, got " ++ show x

nonNegative :: String -> Double -> Parser Double
nonNegative name x
  | x >= 0 = pure x
  | otherwise = fail $ name ++ " must be >= 0, got " ++ show x

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
            ]
      ]

encodeRing :: (a -> Value) -> TwoOf (Maybe a) -> Value
encodeRing enc (TwoOf a b) = toJSON [maybe Null enc a, maybe Null enc b]

encodeOuterRune :: OuterRune -> Value
encodeOuterRune rune = case rune of
  ShapeRune shape -> object ["rune" .= ("shape" :: Text), "shape" .= encodeFaceShape shape]
  RadiateRune mode -> object ["rune" .= ("radiate" :: Text), "mode" .= encodeRadiationMode mode]

encodeFaceShape :: FaceShape -> Value
encodeFaceShape shape = case shape of
  HollowSquare size -> object ["kind" .= ("hollow-square" :: Text), "size" .= size]
  Rect (V2 w h) -> object ["kind" .= ("rect" :: Text), "w" .= w, "h" .= h]
  Ring rIn rOut -> object ["kind" .= ("ring" :: Text), "rInner" .= rIn, "rOuter" .= rOut]
  Diamond size -> object ["kind" .= ("diamond" :: Text), "size" .= size]

encodeRadiationMode :: RadiationMode -> Text
encodeRadiationMode mode = case mode of
  AlongNormal -> "along-normal"
  RadialOutward -> "radial-outward"

encodeBridgeRune :: BridgeRune -> Value
encodeBridgeRune (PhaseRune (Seconds shift)) =
  object ["rune" .= ("phase" :: Text), "shift" .= shift]

encodeInnerRune :: InnerRune -> Value
encodeInnerRune rune = case rune of
  TrajectoryRune t -> object (("rune" .= ("trajectory" :: Text)) : trajectoryFields t)
  TimingRune (Envelope (Seconds d) (Seconds dur) (Seconds life)) ->
    object
      [ "rune" .= ("timing" :: Text)
      , "delay" .= d
      , "duration" .= dur
      , "lifetime" .= life
      ]

trajectoryFields :: Trajectory -> [Pair]
trajectoryFields t = case t of
  Forward speed -> ["kind" .= ("forward" :: Text), "speed" .= speed]
  Spiral speed radius freq ->
    ["kind" .= ("spiral" :: Text), "speed" .= speed, "radius" .= radius, "freq" .= freq]
  Orbit radius freq ->
    ["kind" .= ("orbit" :: Text), "radius" .= radius, "freq" .= freq]

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

encodeNodeSlot :: Maybe NodeRune -> Value
encodeNodeSlot slot = case slot of
  Nothing -> Null
  Just (DirBias strength) -> object ["rune" .= ("dir-bias" :: Text), "strength" .= strength]
