{-# LANGUAGE OverloadedStrings #-}

-- | JSON codec for the spell-file contract (func-spec 0001 §6, ADR-0005).
--
-- Skeleton schema (v1 minimal subset):
--
-- > { "version": 1, "name": "empty", "circle": {} }
--
-- The version field is part of the permanent contract: any @version /= 1@
-- is rejected with the offending version in the error, and syntax/shape
-- errors carry aeson's position path (@$.foo@).
module Magic.Codec
  ( loadCircle
  , saveCircle
  , LoadError (..)
  , renderLoadError
  ) where

import Data.Aeson (Value, eitherDecodeStrict, encode, object, withObject, (.=))
import Data.Aeson.Types (Parser, parseEither, (.:), (.:?))
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Text (Text)
import Magic.Circle (Circle, emptyCircle)

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

parseCircleV1 :: Value -> Parser Circle
parseCircleV1 = withObject "SpellFile" $ \o -> do
  _name <- o .:? "name" :: Parser (Maybe Text)
  circleValue <- o .: "circle"
  withObject "circle" (\_slots -> pure emptyCircle) circleValue

-- | Encode a circle back to the v1 schema. @loadCircle . saveCircle ≡ Right@
-- (roundtrip guarded by test T4).
saveCircle :: Circle -> BS.ByteString
saveCircle _circle =
  BL.toStrict . encode $
    object
      [ "version" .= (1 :: Int)
      , "name" .= ("unnamed" :: Text)
      , "circle" .= object []
      ]
