-- | S4 (func-spec 0019 §6): the release document, the README and the CI
-- workflow must agree about which platforms are supported.
--
-- A support tier is a promise, and the only thing that makes it one is
-- that a machine verifies it: a platform is Tier 1 exactly when it is in
-- the CI matrix. Three files state that list — @docs\/release.md@ §1,
-- @README.md@'s "Building and CI" table, and
-- @.github\/workflows\/ci.yml@'s @matrix.os@ — and this spec asserts set
-- equality between all three, in both directions. Adding a runner to CI
-- without promoting it in the docs fails here, and so does promising a
-- tier nobody verifies.
--
-- The other three assertions keep the rest of the policy from drifting
-- into prose: the tag format is checked against the version the package
-- actually declares (so the example in the document cannot go stale),
-- ADR-0016 has to exist and be accepted, and the release checklist has to
-- name all three CI commands.
module ReleaseDocSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isAlphaNum, isSpace)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

releaseDocPath :: FilePath
releaseDocPath = "docs/release.md"

readmePath :: FilePath
readmePath = "README.md"

workflowPath :: FilePath
workflowPath = ".github/workflows/ci.yml"

adrPath :: FilePath
adrPath = "docs/adr/adr-0016-release-compatibility-policy.md"

cabalPath :: FilePath
cabalPath = "particle-magic.cabal"

readUtf8 :: FilePath -> IO String
readUtf8 path = dropCR . T.unpack . TE.decodeUtf8 <$> BS.readFile path
  where
    -- A Windows checkout with core.autocrlf=true hands these documents
    -- back CRLF-terminated, which leaves a trailing carriage return on
    -- every 'lines' result and breaks the line-exact assertions below.
    -- These files are prose and YAML: no carriage return in them is ever
    -- significant.
    dropCR = filter (/= '\r')

-- | Every GitHub runner label (@\<something\>-latest@) named anywhere in
-- a document, deduplicated and sorted.
--
-- Tier 2 platforms are deliberately written as prose ("macOS", "other
-- Linux distributions") rather than as runner labels, which is what makes
-- this scan mean "the Tier 1 list" without needing to parse a table.
runnerLabels :: String -> [String]
runnerLabels = sort . nub . filter ("-latest" `isSuffixOf`) . tokens
  where
    isWordChar c = isAlphaNum c || c == '-'
    tokens s = case dropWhile (not . isWordChar) s of
      "" -> []
      rest -> let (tok, more) = span isWordChar rest in tok : tokens more

-- | The three commands the release checklist has to mention, because
-- they are the three CI runs on every push.
checklistCommands :: [String]
checklistCommands =
  [ "cabal build all"
  , "cabal test"
  , "magic-validate"
  ]

fieldValue :: String -> String -> Maybe String
fieldValue key contents =
  case [trim (drop (length key + 1) (trim l)) | l <- lines contents, (key ++ ":") `isPrefixOf` trim l] of
    (v : _) -> Just v
    [] -> Nothing

spec :: Spec
spec = describe "the release policy is written down consistently (func-spec 0019 §6 S4)" $ do
  it "names the same Tier 1 platforms in the release doc, the README and CI" $ do
    releaseDoc <- readUtf8 releaseDocPath
    readme <- readUtf8 readmePath
    yml <- readUtf8 workflowPath
    let inCi = runnerLabels yml
    -- Non-empty, or all three could agree by being silent.
    inCi `shouldSatisfy` ((>= 2) . length)
    runnerLabels releaseDoc `shouldBe` inCi
    runnerLabels readme `shouldBe` inCi

  it "documents the tag format, and the example matches the declared version" $ do
    releaseDoc <- readUtf8 releaseDocPath
    cabalFile <- readUtf8 cabalPath
    releaseDoc `shouldSatisfy` ("tag" `isInfixOf`)
    case fieldValue "version" cabalFile of
      Nothing -> expectationFailure "no version: field in the cabal file"
      Just version -> do
        -- The rule is "v ++ the cabal version, character for
        -- character", so the tag it produces today is derived here
        -- rather than copied.
        let tag = 'v' : version
        (tag, tag `isInfixOf` releaseDoc) `shouldBe` (tag, True)
        releaseDoc `shouldSatisfy` ("git tag" `isInfixOf`)

  it "has an accepted ADR behind it" $ do
    adr <- readUtf8 adrPath
    let ls = lines adr
        frontmatter = takeWhile (/= "---") (drop 1 ls)
    take 1 ls `shouldBe` ["---"]
    [l | l <- frontmatter, "status:" `isPrefixOf` l] `shouldBe` ["status: accepted"]
    [l | l <- frontmatter, "id:" `isPrefixOf` l] `shouldBe` ["id: adr-0016"]

  it "gives a release checklist that covers what CI runs" $ do
    releaseDoc <- readUtf8 releaseDocPath
    mapM_
      (\cmd -> (cmd, cmd `isInfixOf` releaseDoc) `shouldBe` (cmd, True))
      checklistCommands

  -- The one promise a host actually has to code against, and the one
  -- this round narrowed (ADR-0016 D4): the document has to state the
  -- per-platform scope rather than leaving the old unqualified claim.
  it "states the scope of the determinism guarantee" $ do
    releaseDoc <- readUtf8 releaseDocPath
    releaseDoc `shouldSatisfy` ("adr-0016" `isInfixOf`)
    releaseDoc `shouldSatisfy` ("ulp" `isInfixOf`)

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
