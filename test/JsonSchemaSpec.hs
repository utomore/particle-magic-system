{-# LANGUAGE OverloadedStrings #-}

-- | S1 (func-spec 0024 §6): the machine-readable schema, and the law that
-- keeps it honest.
--
-- Sixth outing for this repository's text-contract guard (BoundarySpec →
-- FFIContractSpec → BindingContractSpec → SchemaDocSpec → CIWorkflowSpec →
-- here), and the first one that closes a /cycle/ rather than pinning one
-- document to another:
--
--   * this file: the schema's tag vocabulary ≡ the quoted vocabulary of
--     @docs\/spell-schema.md@, both directions;
--   * @SchemaDocSpec@ (func-spec 0014): every key the shipped examples use
--     appears in that same document;
--   * @CircleCodecSpec@\/@CodecSpec@: @loadCircle . saveCircle ≡ Right@, so
--     the examples' tags are the tags "Magic.Codec" accepts.
--
-- Transitively: add a constructor to "Magic.Rune" and a tag to
-- "Magic.Codec" without touching the other two, and this suite is red.
-- That is the whole point of writing the generator as a declaration table
-- instead of deriving it (func-spec 0024 §7-5) — a derivation would have
-- made the omission silently correct.
module JsonSchemaSpec (spec) where

import Data.Aeson (Value (Array, Object), decodeStrict)
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Schema
  ( generateSchema
  , keywordsUsedBy
  , normalizeNewlines
  , refTargets
  , schemaEnumValues
  , supportedKeywords
  , validateJson
  )
import System.Directory (listDirectory)
import Test.Hspec

schemaPath :: FilePath
schemaPath = "docs/spell.schema.json"

docPath :: FilePath
docPath = "docs/spell-schema.md"

spellDir :: FilePath
spellDir = "assets/spells"

-- | The generated document, decoded. Every test below reads it through
-- here rather than off disk, so a broken generator fails as a broken
-- generator rather than as a stale file.
schemaValue :: Value
schemaValue = case decodeStrict generateSchema of
  Just v -> v
  Nothing -> error "generateSchema did not produce decodable JSON"

exampleNames :: IO [FilePath]
exampleNames = do
  entries <- listDirectory spellDir
  pure [spellDir ++ "/" ++ e | e <- sort entries, ".json" `isSuffixOf` e]

readUtf8 :: FilePath -> IO String
readUtf8 path = T.unpack . TE.decodeUtf8 <$> BS.readFile path

spec :: Spec
spec = describe "docs/spell.schema.json (func-spec 0024 S1)" $ do
  -- Golden mode, exactly as func-spec 0024 §2.1 asks for: the file is
  -- committed because external tool chains want a URL, and the generator
  -- is the authority, so the only relationship worth asserting is that
  -- they are the same document.
  it "the committed file is what the generator produces" $ do
    onDisk <- BS.readFile schemaPath
    normalizeNewlines onDisk `shouldBe` normalizeNewlines generateSchema

  describe "three-way consistency (§2.1)" $ do
    -- Bidirectional set equality, which is stronger than func-spec 0014's
    -- one-directional guard and deliberately so: this pair is generated
    -- from the same vocabulary, so "the document mentions a tag that does
    -- not exist" is a real failure here, not the harmless case it is for
    -- prose about keys.
    it "the schema's tag vocabulary equals the author document's" $ do
      doc <- readUtf8 docPath
      let fromSchema = schemaEnumValues schemaValue
          fromDoc = docVocabulary doc
      -- Non-empty, or a broken extractor would let this pass vacuously.
      length fromSchema `shouldSatisfy` (> 40)
      [v | v <- fromSchema, v `notElem` fromDoc] `shouldBe` []
      [v | v <- fromDoc, v `notElem` fromSchema] `shouldBe` []

    -- The count is written down so that adding a tag to both ends and
    -- forgetting the third (the codec) still costs somebody a deliberate
    -- edit here. 49 at func-spec 0024's delivery: 11 rune tags, 5
    -- billboards, 8 face shapes, 4 radiation modes, 7 trajectories, 9
    -- elements, 6 force fields, minus "ring" counted twice.
    it "and there are 49 tags in it" $
      length (schemaEnumValues schemaValue) `shouldBe` 49

  describe "the schema is a well-formed draft-07 document" $ do
    it "declares the draft-07 meta-schema" $ do
      onDisk <- readUtf8 schemaPath
      onDisk `shouldSatisfy` ("http://json-schema.org/draft-07/schema#" `isInfixOf`)

    -- The validator below implements a subset of draft-07 and silently
    -- ignores everything else, so this is the assertion that stops the
    -- next three tests from being about nothing.
    it "uses only keywords the validator implements" $
      [k | k <- keywordsUsedBy schemaValue, k `notElem` supportedKeywords] `shouldBe` []

    it "and every keyword it lists as supported is a draft-07 keyword" $
      -- Guards the other direction of the same list: a typo in
      -- 'supportedKeywords' would otherwise widen the allowance above.
      supportedKeywords `shouldSatisfy` all (`elem` draft07Keywords)

    it "every $ref resolves to a definition that exists" $ do
      let defined = definitionNames schemaValue
      [r | r <- refTargets schemaValue, r `notElem` defined] `shouldBe` []

    it "and every definition is reachable from the root" $ do
      let used = refTargets schemaValue
      [d | d <- definitionNames schemaValue, d `notElem` used] `shouldBe` []

    -- draft-07 says a $ref's siblings are ignored; the validator obeys
    -- that, so the generator must never write any or a constraint would
    -- vanish without a sound.
    it "and no $ref carries sibling keywords" $
      refsWithSiblings schemaValue `shouldBe` []

  describe "every shipped example is a well-shaped spell file" $
    it "validates all of assets/spells/*.json" $ do
      names <- exampleNames
      length names `shouldSatisfy` (>= 16)
      failures <- mapM validateFile names
      concat failures `shouldBe` []

  describe "and known-bad files are rejected (witnesses)" $
    mapM_ witness badFiles

-- | One bad document, the reason it is bad, and the fragment its
-- complaint must mention. The fragment matters: a validator that
-- rejected everything would pass a bare "not empty" assertion.
badFiles :: [(String, BS.ByteString, String)]
badFiles =
  [ ( "a version this build does not read"
    , "{\"version\": 2, \"circle\": {}}"
    , "$.version"
    )
  , ( "no circle at all"
    , "{\"version\": 1}"
    , "missing required key circle"
    )
  , ( "an element that does not exist"
    , "{\"version\":1,\"circle\":{\"core\":{\"center\":{\"element\":\"plasma\",\"power\":1}}}}"
    , "\"plasma\" is not one of"
    )
  , ( "a rune tag in the wrong slot"
    , "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"timing\",\"delay\":0,\"duration\":1,\"lifetime\":1}]}}"
    , "\"rune\" must be one of"
    )
  , ( "a ring shape missing its outer radius"
    , "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"shape\",\"shape\":{\"kind\":\"ring\",\"rInner\":1.0}}]}}"
    , "missing required key rOuter"
    )
  , ( "power written as a string"
    , "{\"version\":1,\"circle\":{\"core\":{\"center\":{\"element\":\"fire\",\"power\":\"1.5\"}}}}"
    , "expected number, got string"
    )
  , ( "power at zero"
    , "{\"version\":1,\"circle\":{\"core\":{\"center\":{\"element\":\"fire\",\"power\":0}}}}"
    , "expected > 0"
    )
  , ( "a third ring layer"
    , "{\"version\":1,\"circle\":{\"inner\":[null,null,null]}}"
    , "at most 2 elements"
    )
  , ( "an empty anchors array"
    , "{\"version\":1,\"circle\":{\"anchors\":[]}}"
    , "at least 1 element"
    )
  , ( "a two-component anchor offset"
    , "{\"version\":1,\"circle\":{\"anchors\":[{\"offset\":[0,0],\"normal\":[0,0,1]}]}}"
    , "at least 3 elements"
    )
  , ( "a polygon with two sides"
    , "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"shape\",\"shape\":{\"kind\":\"polygon\",\"sides\":2,\"radius\":1}}]}}"
    , "expected >= 3, got 2"
    )
  , ( "a force field kind nobody implements"
    , "{\"version\":1,\"circle\":{\"fields\":[{\"kind\":\"antigravity\",\"accel\":[0,1,0]}]}}"
    , "\"kind\" must be one of"
    )
  ]

witness :: (String, BS.ByteString, String) -> Spec
witness (why, bytes, fragment) =
  it ("rejects " ++ why) $ case decodeStrict bytes of
    Nothing -> expectationFailure ("witness is not valid JSON: " ++ BSC.unpack bytes)
    Just document -> do
      let errs = validateJson schemaValue document
      errs `shouldSatisfy` (not . null)
      unlines errs `shouldSatisfy` (fragment `isInfixOf`)

validateFile :: FilePath -> IO [String]
validateFile path = do
  bytes <- BS.readFile path
  case decodeStrict bytes of
    Nothing -> pure [path ++ ": not valid JSON"]
    Just document -> pure (map ((path ++ ": ") ++) (validateJson schemaValue document))

-- Reading the author document ------------------------------------------------

-- | The tags @docs\/spell-schema.md@ names, which it writes as quoted
-- inline code: @`"fire"`@, @`"trajectory"`@, @`"hollow-square"`@.
--
-- The quotes are what separate a /value/ from a /key/ in that document's
-- own typography — keys are written bare (@`element`@, @`power`@) — so
-- this extractor needs no table of exceptions and no cooperation from the
-- prose beyond the convention the document already follows.
--
-- Fenced blocks are dropped first: they are JSON samples, where a quoted
-- string is just as likely to be a spell's name as a tag.
docVocabulary :: String -> [String]
docVocabulary doc =
  nub (sort [ident | span_ <- inlineCode (stripFences doc), Just ident <- [quotedIdent span_]])

stripFences :: String -> String
stripFences = unlines . go False . lines
  where
    go _ [] = []
    go inside (l : rest)
      | "```" `isPrefixOf` dropWhile isSpace l = go (not inside) rest
      | inside = go inside rest
      | otherwise = l : go inside rest

-- | The odd-indexed pieces of a split on backticks are the code spans.
inlineCode :: String -> [String]
inlineCode = odds . splitOn '`'
  where
    odds xs = [x | (i, x) <- zip [0 :: Int ..] xs, odd i]

quotedIdent :: String -> Maybe String
quotedIdent s = do
  body <- unquote s
  case body of
    (c : _) | c `elem` ['a' .. 'z'], all identChar body -> Just body
    _ -> Nothing
  where
    unquote ('"' : rest) = case reverse rest of
      ('"' : revBody) -> Just (reverse revBody)
      _ -> Nothing
    unquote _ = Nothing
    identChar c = c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c == '-'

-- Reading the schema ----------------------------------------------------------

-- | The names under @definitions@, straight off the decoded document.
--
-- Deliberately /not/ through "Schema"'s own traversal: 'refTargets' is
-- what the two reachability tests are checking, so the other side of each
-- comparison has to be arrived at independently.
definitionNames :: Value -> [String]
definitionNames value = case value of
  Object o | Just (Object defs) <- KM.lookup "definitions" o ->
    sort (map AK.toString (KM.keys defs))
  _ -> []

-- | Every @$ref@ object in the document that carries a second key.
--
-- A generic walk over every object anywhere, not the schema-shaped one
-- "Schema" uses: a stray sibling in a place that walk does not visit
-- would be exactly the kind of thing this is looking for.
refsWithSiblings :: Value -> [Value]
refsWithSiblings = go
  where
    go value = case value of
      Object o ->
        [value | KM.member "$ref" o, KM.size o > 1]
          ++ concatMap go (KM.elems o)
      Array items -> concatMap go (toList items)
      _ -> []

-- | Every keyword draft-07 defines. Only used to check that
-- 'supportedKeywords' contains no typos.
draft07Keywords :: [String]
draft07Keywords =
  [ "$comment"
  , "$id"
  , "$ref"
  , "$schema"
  , "additionalItems"
  , "additionalProperties"
  , "allOf"
  , "anyOf"
  , "const"
  , "contains"
  , "contentEncoding"
  , "contentMediaType"
  , "default"
  , "definitions"
  , "dependencies"
  , "description"
  , "else"
  , "enum"
  , "examples"
  , "exclusiveMaximum"
  , "exclusiveMinimum"
  , "format"
  , "if"
  , "items"
  , "maxItems"
  , "maxLength"
  , "maxProperties"
  , "maximum"
  , "minItems"
  , "minLength"
  , "minProperties"
  , "minimum"
  , "multipleOf"
  , "not"
  , "oneOf"
  , "pattern"
  , "patternProperties"
  , "properties"
  , "propertyNames"
  , "readOnly"
  , "required"
  , "then"
  , "title"
  , "type"
  , "uniqueItems"
  , "writeOnly"
  ]

-- Small helpers ---------------------------------------------------------------

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (chunk, []) -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn c rest
