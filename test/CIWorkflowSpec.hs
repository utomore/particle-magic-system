-- | S1 (func-spec 0019 §6): the CI workflow is a contract, so it gets a
-- test.
--
-- Fifth outing for this repo's text-contract guard (BoundarySpec reads the
-- cabal file, FFIContractSpec the C header and the .def, BindingContractSpec
-- the C# binding, SchemaDocSpec the author's schema document — and here,
-- a YAML file). The failure this prevents is mundane and entirely real:
-- somebody comments out the @magic-validate@ step to get a red build
-- through, or drops @ubuntu-latest@ from the matrix while chasing an
-- unrelated failure, and nothing says so until an asset rots or a
-- platform quietly stops being Tier 1. Here it fails in @cabal test@.
--
-- The trigger policy is asserted here too, and for a different kind of
-- reason: on a private repository runner minutes cost money, so "when
-- does this run" is a budget decision, not a detail (ADR-0016 D5).
--
-- Parsed by line scanning rather than with a YAML library: the test
-- suite's dependency list is part of the architecture's discipline, and
-- the handful of facts asserted below do not need a parser.
module CIWorkflowSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

workflowPath :: FilePath
workflowPath = ".github/workflows/ci.yml"

cabalPath :: FilePath
cabalPath = "particle-magic.cabal"

-- | Read as UTF-8 bytes rather than through 'readFile', whose decoding
-- follows the machine's locale (the same reason SchemaDocSpec does it),
-- with the carriage returns dropped.
--
-- That second half is not tidiness. This repository is cloned with
-- @core.autocrlf=true@ on Windows and untranslated on Linux, so the very
-- same committed file arrives as CRLF on one CI runner and LF on the
-- other — and a spec that compares whole lines would then pass on one
-- platform and fail on the other, which is precisely the class of bug
-- the two-platform matrix exists to catch.
readUtf8 :: FilePath -> IO String
readUtf8 path = filter (/= '\r') . T.unpack . TE.decodeUtf8 <$> BS.readFile path

-- | The three commands, in the order CI must run them: most expensive
-- first, because a red build makes the other two meaningless.
ciCommands :: [String]
ciCommands =
  [ "cabal build all"
  , "cabal test"
  , "cabal run magic-validate"
  ]

-- | Value of a @key: value@ line anywhere in the file, trimmed and
-- unquoted.
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

-- | The body of the top-level @on:@ block — every line indented under it.
--
-- Scoped rather than scanning the whole file, because the words @push@
-- and @tags@ appear in this workflow's prose too, and a trigger policy
-- that is asserted by grepping comments is not asserted at all.
triggerBlock :: String -> [String]
triggerBlock contents =
  case dropWhile ((/= "on:") . trim) (lines contents) of
    [] -> []
    (_ : rest) -> takeWhile indentedOrBlank rest
  where
    indentedOrBlank l = case l of
      (c : _) -> isSpace c
      [] -> True

-- | The runner labels of the @os:@ matrix line, e.g. @[windows-latest,
-- ubuntu-latest]@.
matrixOses :: String -> [String]
matrixOses contents =
  case [trim (drop 3 (trim l)) | l <- lines contents, "os:" `isPrefixOf` trim l] of
    (v : _) -> sort (map trim (splitOn ',' (takeWhile (/= ']') (drop 1 (dropWhile (/= '[') v)))))
    [] -> []

-- | The GHC version the package claims to have been tested with, read out
-- of @tested-with: GHC ==9.14.1@.
testedWithGhc :: String -> Maybe String
testedWithGhc contents = do
  v <- fieldValue "tested-with" contents
  case words v of
    ["GHC", ver] -> Just (dropWhile (== '=') ver)
    _ -> Nothing

-- | The file's lines with comments blanked out, indices preserved.
--
-- Everything asserted about what CI /does/ is asserted against these
-- rather than the raw text: a step that somebody comments out must fail
-- this spec, which is the whole reason it exists — and this file's own
-- prose mentions the commands it documents, so matching anywhere would
-- make the assertions unfalsifiable.
effectiveLines :: String -> [String]
effectiveLines = map blankComment . lines
  where
    blankComment l = if "#" `isPrefixOf` trim l then "" else l

-- | Line index of the first effective (non-comment) line containing a
-- needle.
lineOf :: String -> String -> Maybe Int
lineOf needle contents =
  case [i | (i, l) <- zip [0 ..] (effectiveLines contents), needle `isInfixOf` l] of
    (i : _) -> Just i
    [] -> Nothing

spec :: Spec
spec = describe "the CI workflow says what it is supposed to say (func-spec 0019 §6 S1)" $ do
  it "gates pull requests into main, and can be run on demand" $ do
    yml <- readUtf8 workflowPath
    yml `shouldSatisfy` ("\non:" `isInfixOf`)
    triggerBlock yml `shouldSatisfy` any ("pull_request:" `isInfixOf`)
    triggerBlock yml `shouldSatisfy` any ("branches: [main]" `isInfixOf`)
    triggerBlock yml `shouldSatisfy` any ("workflow_dispatch:" `isInfixOf`)

  it "re-verifies on a release tag" $ do
    yml <- readUtf8 workflowPath
    -- docs/release.md §4 step 3: "CI green on both Tier 1 platforms" is a
    -- step of the release procedure, so cutting the tag runs it rather
    -- than trusting that somebody remembered to.
    triggerBlock yml `shouldSatisfy` any ("tags:" `isInfixOf`)
    triggerBlock yml `shouldSatisfy` any ("'v*'" `isInfixOf`)

  -- ADR-0016 D5. Runner minutes are billed on a private repository and
  -- Windows costs double, so a branch-push trigger would spend the
  -- monthly allowance on work in progress -- and alongside
  -- @pull_request@ it would run every job twice for nothing. Re-adding
  -- one has to be a decision, so it fails here first.
  it "does not fire on every branch push" $ do
    yml <- readUtf8 workflowPath
    let pushBranches =
          [ l
          | l <- triggerBlock yml
          , "branches:" `isInfixOf` l
          , not ("[main]" `isInfixOf` l)
          ]
    pushBranches `shouldBe` []
    -- The tag trigger is the only 'push:' this workflow may carry, and a
    -- 'push:' with no 'tags:' under it would be a branch trigger.
    let pushLines = [i | (i, l) <- zip [0 :: Int ..] (triggerBlock yml), "push:" `isInfixOf` l]
    length pushLines `shouldSatisfy` (<= 1)
    case pushLines of
      [] -> pure ()
      (i : _) -> drop (i + 1) (triggerBlock yml) `shouldSatisfy` any ("tags:" `isInfixOf`)

  it "covers both Tier 1 platforms in its matrix" $ do
    yml <- readUtf8 workflowPath
    matrixOses yml `shouldBe` ["ubuntu-latest", "windows-latest"]

  it "runs build, then test, then validate -- all three, in that order" $ do
    yml <- readUtf8 workflowPath
    -- A commented-out step is not a step: 'lineOf' reads past comments,
    -- so deleting the validate line by hashing it out fails here.
    mapM_ (\cmd -> (cmd, lineOf cmd yml /= Nothing) `shouldBe` (cmd, True)) ciCommands
    let positions = map (`lineOf` yml) ciCommands
    positions `shouldBe` sort positions

  it "points magic-validate at the shipped spells" $ do
    yml <- readUtf8 workflowPath
    let validateLines = [l | l <- effectiveLines yml, "cabal run magic-validate" `isInfixOf` l]
    validateLines `shouldSatisfy` any ("assets/spells" `isInfixOf`)

  -- h-raylib compiles raylib's C sources and links against the system
  -- X11/GL headers; without these the Linux job cannot build the demo
  -- executable at all. README documents the same list.
  it "installs the Linux system dependencies h-raylib needs" $ do
    yml <- readUtf8 workflowPath
    mapM_
      (\pkg -> (pkg, lineOf pkg yml /= Nothing) `shouldBe` (pkg, True))
      ["libx11-dev", "libxrandr-dev", "libxinerama-dev", "libxcursor-dev", "libxi-dev", "libgl1-mesa-dev"]

  -- A cold cache means recompiling raylib and the whole dependency
  -- closure on every push, which is the difference between CI being used
  -- and CI being ignored.
  it "caches the cabal store and the build tree" $ do
    yml <- readUtf8 workflowPath
    mapM_
      (\needle -> (needle, lineOf needle yml /= Nothing) `shouldBe` (needle, True))
      ["actions/cache", "cabal-store", "dist-newstyle"]

  -- The two halves of this equality are asserted from both ends: here,
  -- and from the package side in ReleaseMetaSpec. A workflow that
  -- installs a compiler the package has never been tested with is a
  -- green tick that means nothing.
  it "installs exactly the GHC the package declares it was tested with" $ do
    yml <- readUtf8 workflowPath
    cabalFile <- readUtf8 cabalPath
    let ciGhc = fieldValue "GHC_VERSION" yml
    ciGhc `shouldSatisfy` (/= Nothing)
    ciGhc `shouldBe` testedWithGhc cabalFile

  it "uses that one version everywhere it names a compiler" $ do
    yml <- readUtf8 workflowPath
    case fieldValue "GHC_VERSION" yml of
      Nothing -> expectationFailure "no GHC_VERSION in the workflow"
      Just ghc ->
        -- Any literal copy of the version outside its own definition
        -- would be a second source of truth.
        [ l
          | l <- lines yml
          , ghc `isInfixOf` l
          , not ("GHC_VERSION:" `isInfixOf` l)
          , not ("#" `isPrefixOf` trim l)
          ]
          `shouldBe` []

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (chunk, []) -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn c rest
