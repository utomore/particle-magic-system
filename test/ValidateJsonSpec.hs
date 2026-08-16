{-# LANGUAGE OverloadedStrings #-}

-- | S3 (func-spec 0024 §6): @magic-validate --json@.
--
-- Two halves, and the first one matters more than the second.
--
-- The __zero-change law__: func-spec 0014 froze this tool's line format
-- and exit-code semantics because its readers are humans /and/ scripts,
-- and func-spec 0019's CI is one of the scripts. So the tests below pin
-- the old output as a literal — every character of it, padding included —
-- rather than merely checking that it is "still reasonable". A round that
-- adds a flag must be provably invisible to everyone who did not pass it.
--
-- The __new mode__: valid JSON, one entry per file with @path@, @ok@ and
-- @error@, and a verdict that agrees with the human output on every input.
-- The agreement is a property rather than a handful of cases, because the
-- failure it guards against — the two renderers drifting on some kind of
-- input nobody thought to write down — is exactly the kind a fixed list
-- misses.
module ValidateJsonSpec (spec) where

import Data.Aeson (Value (Array, Bool, Object, String), decodeStrict, toJSON)
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Foldable (toList)
import Data.List (isPrefixOf, isSuffixOf, sort)
import qualified Data.Text as T
import System.Directory (listDirectory)
import Test.Hspec
import Test.QuickCheck
import Validate
  ( Options (..)
  , Report (..)
  , exitCodeFor
  , failureCount
  , parseArgs
  , renderJsonReport
  , renderReport
  , validateBytes
  )

spellDir :: FilePath
spellDir = "assets/spells"

-- | A pool of inputs the two renderers must agree on: every shipped
-- example plus the failure modes the tool exists for. Read once, at spec
-- construction, so every test below is a pure function of it.
inputPool :: IO [(FilePath, BS.ByteString)]
inputPool = do
  entries <- listDirectory spellDir
  examples <-
    mapM
      (\e -> (,) (spellDir ++ "/" ++ e) <$> BS.readFile (spellDir ++ "/" ++ e))
      [e | e <- sort entries, ".json" `isSuffixOf` e]
  pure (examples ++ broken)

-- | The failure modes, as @(name, bytes)@. Every one of them is a verdict
-- the tool is supposed to produce, not a crash — and between them they
-- cover all three gates: the JSON parser, the codec, and the compiler.
broken :: [(FilePath, BS.ByteString)]
broken =
  [ ("bad/not-json.json", "{ this is not json")
  , ("bad/version.json", "{\"version\": 7, \"circle\": {}}")
  , ("bad/tag.json", "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"wibble\"}]}}")
  , ("bad/element.json", "{\"version\":1,\"circle\":{\"core\":{\"center\":{\"element\":\"plasma\",\"power\":1}}}}")
  , ("bad/radii.json", "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"shape\",\"shape\":{\"kind\":\"ring\",\"rInner\":2.0,\"rOuter\":1.0}}]}}")
  , ("bad/formula.json", "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"range\",\"expr\":\"sin(\"}]}}")
  , ("bad/budget.json", "{\"version\":1,\"circle\":{\"core\":{\"center\":{\"element\":\"fire\",\"power\":400}}}}")
  , ("bad/anchors.json", "{\"version\":1,\"circle\":{\"anchors\":[]}}")
  ]

spec :: Spec
spec = do
  pool <- runIO inputPool
  let allReports = [validateBytes p b | (p, b) <- pool]

  describe "magic-validate --json (func-spec 0024 S3)" $ do
    describe "the zero-change law (§2.2)" $ do
      it "parses the old command line to the old options, with --json off" $ do
        parseArgs ["a.json"]
          `shouldBe` Right (Options {optStats = False, optJson = False, optPaths = ["a.json"]})
        parseArgs ["--stats", "a.json", "b.json"]
          `shouldBe` Right
            (Options {optStats = True, optJson = False, optPaths = ["a.json", "b.json"]})

      it "and still refuses an unknown option and an empty path list" $ do
        parseArgs ["--wat", "a.json"] `shouldSatisfy` isLeft
        parseArgs ["--stats"] `shouldSatisfy` isLeft
        parseArgs ["--json"] `shouldSatisfy` isLeft

      -- The literal, not a paraphrase of it: one 'OK <path>' line and
      -- nothing else. This is the line func-spec 0014 §9.3 froze.
      it "renders a passing file as exactly the frozen line" $ do
        bytes <- BS.readFile (spellDir ++ "/empty.json")
        renderReport False (validateBytes "assets/spells/empty.json" bytes)
          `shouldBe` "OK assets/spells/empty.json\n"

      it "renders a failing file as FAIL plus two-space-indented detail" $ do
        let report = validateBytes "bad/version.json" "{\"version\": 7, \"circle\": {}}"
            out = lines (renderReport False report)
        take 1 out `shouldBe` ["FAIL bad/version.json"]
        drop 1 out `shouldSatisfy` all ("  " `isPrefixOf`)
        drop 1 out `shouldBe` ["  unsupported spell schema version 7 (this build reads version 1)"]

      -- The six --stats lines, with their exact ten-column padding.
      it "renders --stats as the same six padded fields" $ do
        bytes <- BS.readFile (spellDir ++ "/grand-sigil.json")
        let out = lines (renderReport True (validateBytes "g.json" bytes))
        take 1 out `shouldBe` ["OK g.json"]
        map (take 12) (drop 1 out)
          `shouldBe` [ "  budget    "
                     , "  emitters  "
                     , "  lifetime  "
                     , "  phases    "
                     , "  fields    "
                     , "  extent    "
                     ]

      it "and the exit code is still the number of failures, clamped at 125" $ do
        exitCodeFor allReports `shouldBe` failureCount allReports
        failureCount allReports `shouldBe` length broken
        exitCodeFor [] `shouldBe` 0
        exitCodeFor (replicate 200 (validateBytes "x" "nope")) `shouldBe` 125

    describe "the JSON report" $ do
      it "is valid JSON" $
        decodeStrict (BSC.pack (renderJsonReport False allReports))
          `shouldSatisfy` isJustValue

      it "carries path, ok and error for every file, in the run's order" $
        case decodeStrict (BSC.pack (renderJsonReport False allReports)) >>= filesOf of
          Nothing -> expectationFailure "no files array in the JSON report"
          Just entries -> do
            length entries `shouldBe` length allReports
            [sort (keysOf e) | e <- entries] `shouldSatisfy` all (== ["error", "ok", "path"])
            [pathOf e | e <- entries] `shouldBe` map (Just . repPath) allReports

      -- Key order survives only in the text: aeson's 'Object' is a hash
      -- map, so a decoded entry has lost it. That is precisely why
      -- 'renderJsonReport' writes the document by hand (see its haddock),
      -- and precisely why this assertion has to read the bytes.
      it "and writes those keys in that order, every time" $
        entryKeyOrder (renderJsonReport False allReports)
          `shouldBe` concat (replicate (length allReports) ["path", "ok", "error"])

      it "and reports the run's totals" $
        case decodeStrict (BSC.pack (renderJsonReport False allReports)) of
          Just (Object o) -> do
            KM.lookup "checked" o `shouldBe` Just (toJSON (length allReports))
            KM.lookup "failed" o `shouldBe` Just (toJSON (failureCount allReports))
          _ -> expectationFailure "the JSON report is not an object"

      -- --stats rides along rather than replacing anything: the shape is
      -- --json's business, the detail is --stats's.
      it "attaches a stats object to exactly the files that passed" $
        case decodeStrict (BSC.pack (renderJsonReport True allReports)) >>= filesOf of
          Nothing -> expectationFailure "no files array in the --json --stats report"
          Just entries ->
            [fmap isObject (fieldOf "stats" e) | e <- entries]
              `shouldBe` [okOf e | e <- entries]

      it "and every entry has the stats key when --stats was asked for" $
        case decodeStrict (BSC.pack (renderJsonReport True allReports)) >>= filesOf of
          Nothing -> expectationFailure "no files array in the --json --stats report"
          Just entries ->
            [sort (keysOf e) | e <- entries]
              `shouldSatisfy` all (== ["error", "ok", "path", "stats"])

    -- The property func-spec 0024 §6 S3 asks for: whatever the run, the
    -- two renderers agree file by file on pass and fail.
    it "agrees with the human-readable output on every verdict" $
      property $ \(picks :: [Int]) ->
        let reports =
              [ let (p, b) = pool !! (i `mod` length pool) in validateBytes p b
              | i <- picks
              ]
            fromLines =
              [ takeWhile (/= ' ') l
              | l <- lines (concatMap (renderReport False) reports)
              , not ("  " `isPrefixOf` l)
              ]
            fromJson =
              case decodeStrict (BSC.pack (renderJsonReport False reports)) >>= filesOf of
                Just entries -> [verdict (okOf e) | e <- entries]
                Nothing -> ["<unparseable>"]
         in fromLines === fromJson

verdict :: Maybe Bool -> String
verdict ok = case ok of
  Just True -> "OK"
  Just False -> "FAIL"
  Nothing -> "?"

-- Reading the JSON back --------------------------------------------------------

-- | The per-file keys, in the order the document spells them, read off
-- the text rather than a decoded value.
entryKeyOrder :: String -> [String]
entryKeyOrder out =
  [ key
  | l <- lines out
  , let trimmed = dropWhile (== ' ') l
  , key <- ["path", "ok", "error"]
  , ("\"" ++ key ++ "\":") `isPrefixOf` trimmed
  ]

filesOf :: Value -> Maybe [Value]
filesOf value = case value of
  Object o | Just (Array items) <- KM.lookup "files" o -> Just (toList items)
  _ -> Nothing

keysOf :: Value -> [String]
keysOf value = case value of
  Object o -> map AK.toString (KM.keys o)
  _ -> []

fieldOf :: String -> Value -> Maybe Value
fieldOf name value = case value of
  Object o -> KM.lookup (AK.fromString name) o
  _ -> Nothing

pathOf :: Value -> Maybe FilePath
pathOf value = case fieldOf "path" value of
  Just (String t) -> Just (T.unpack t)
  _ -> Nothing

okOf :: Value -> Maybe Bool
okOf value = case fieldOf "ok" value of
  Just (Bool b) -> Just b
  _ -> Nothing

isObject :: Value -> Bool
isObject value = case value of
  Object _ -> True
  _ -> False

isJustValue :: Maybe Value -> Bool
isJustValue = maybe False (const True)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

