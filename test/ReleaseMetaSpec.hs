-- | S3 (func-spec 0019 §6): the package metadata is part of the release
-- policy, so the policy is machine-checked rather than remembered.
--
-- Four facts, each of which is a rule in @docs\/release.md@ §2–§3:
--
--   * the version in the cabal file has a section of its own in
--     @CHANGELOG.md@ — bumping the version and writing down what changed
--     are two halves of one action, not two actions;
--   * @tested-with:@ is present, well formed, and names the compiler CI
--     actually installs (the other end of the same equality
--     @test\/CIWorkflowSpec.hs@ asserts);
--   * every @build-depends@ entry in every stanza carries a @^>=@ upper
--     bound, so a future release of a dependency cannot silently break a
--     downstream build of the public sublibraries;
--   * the tag that would be cut for this version follows the documented
--     format.
--
-- Same discipline as BoundarySpec, which parses the same file for a
-- different property: line scanning, no extra dependency.
module ReleaseMetaSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isDigit, isSpace)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

cabalPath :: FilePath
cabalPath = "particle-magic.cabal"

changelogPath :: FilePath
changelogPath = "CHANGELOG.md"

workflowPath :: FilePath
workflowPath = ".github/workflows/ci.yml"

readUtf8 :: FilePath -> IO String
readUtf8 path = T.unpack . TE.decodeUtf8 <$> BS.readFile path

-- | Value of a top-level @field: value@ line.
fieldValue :: String -> String -> Maybe String
fieldValue key contents =
  case [trim (drop (length key + 1) (trim l)) | l <- lines contents, (key ++ ":") `isPrefixOf` trim l] of
    (v : _) -> Just (unquote v)
    [] -> Nothing
  where
    unquote s = case s of
      ('\'' : rest) -> takeWhile (/= '\'') rest
      ('"' : rest) -> takeWhile (/= '"') rest
      _ -> s

-- | Every dependency entry of every @build-depends@ field in the file,
-- with its version constraint still attached.
--
-- Continuation lines of a @build-depends@ field are the ones beginning
-- with a comma — which is how every stanza in this package is written,
-- and the vacuity guard in the test below is what keeps that true.
allDepEntries :: String -> [String]
allDepEntries contents = go (filter (not . isComment) (lines contents))
  where
    isComment l = "--" `isPrefixOf` trim l
    go [] = []
    go (l : ls)
      | "build-depends:" `isPrefixOf` trim l =
          let rest = takeWhile isContinuation ls
              body = drop (length "build-depends:") (trim l) : map trim rest
           in filter (not . null) (map trim (splitOn ',' (unwords body)))
                ++ go (drop (length rest) ls)
      | otherwise = go ls
    isContinuation x = "," `isPrefixOf` trim x

-- | @particle-magic:magic-core@ and friends: same package, so the version
-- is this package's own and an external bound would be meaningless.
isInternal :: String -> Bool
isInternal entry = "particle-magic:" `isPrefixOf` entry

depName :: String -> String
depName = takeWhile (\c -> not (isSpace c) && c `notElem` "^><=&|")

spec :: Spec
spec = describe "release metadata (func-spec 0019 §6 S3, docs/release.md §2)" $ do
  it "has a CHANGELOG section for the version it currently declares" $ do
    cabalFile <- readUtf8 cabalPath
    changelog <- readUtf8 changelogPath
    case fieldValue "version" cabalFile of
      Nothing -> expectationFailure "no version: field in the cabal file"
      Just version -> do
        version `shouldSatisfy` (all (\c -> isDigit c || c == '.'))
        length (filter (== '.') version) `shouldBe` 3
        let headings = [l | l <- lines changelog, "## " `isPrefixOf` l]
        (version, any (version `isInfixOf`) headings) `shouldBe` (version, True)

  it "would be tagged in the documented format" $ do
    cabalFile <- readUtf8 cabalPath
    releaseDoc <- readUtf8 "docs/release.md"
    case fieldValue "version" cabalFile of
      Nothing -> expectationFailure "no version: field in the cabal file"
      Just version -> do
        let tag = 'v' : version
        (tag, tag `isInfixOf` releaseDoc) `shouldBe` (tag, True)

  it "declares the compiler it was tested with, well formed" $ do
    cabalFile <- readUtf8 cabalPath
    case fieldValue "tested-with" cabalFile of
      Nothing -> expectationFailure "no tested-with: field in the cabal file"
      Just declared -> do
        declared `shouldSatisfy` (not . null)
        case words declared of
          ["GHC", ver] -> do
            ver `shouldSatisfy` ("==" `isPrefixOf`)
            drop 2 ver `shouldSatisfy` all (\c -> isDigit c || c == '.')
          other -> expectationFailure ("malformed tested-with: " ++ show other)

  it "was tested with the compiler CI installs" $ do
    cabalFile <- readUtf8 cabalPath
    yml <- readUtf8 workflowPath
    let declared = do
          v <- fieldValue "tested-with" cabalFile
          case words v of
            ["GHC", ver] -> Just (dropWhile (== '=') ver)
            _ -> Nothing
    declared `shouldSatisfy` (/= Nothing)
    declared `shouldBe` fieldValue "GHC_VERSION" yml

  it "gives every external dependency a PVP upper bound" $ do
    cabalFile <- readUtf8 cabalPath
    let entries = allDepEntries cabalFile
        external = filter (not . isInternal) entries
    -- Vacuity guard: this package has well over forty dependency
    -- entries across its seven stanzas. If the parser ever stops seeing
    -- them, this fails instead of passing on an empty list.
    length external `shouldSatisfy` (> 40)
    map depName (filter (not . ("^>=" `isInfixOf`)) external) `shouldBe` []

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (chunk, []) -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn c rest
