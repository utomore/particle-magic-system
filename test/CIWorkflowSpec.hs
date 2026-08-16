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
-- follows the machine's locale (the same reason SchemaDocSpec does it).
readUtf8 :: FilePath -> IO String
readUtf8 path = T.unpack . TE.decodeUtf8 <$> BS.readFile path

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

-- | Line index of the first line containing a needle.
lineOf :: String -> String -> Maybe Int
lineOf needle contents =
  case [i | (i, l) <- zip [0 ..] (lines contents), needle `isInfixOf` l] of
    (i : _) -> Just i
    [] -> Nothing

spec :: Spec
spec = describe "the CI workflow says what it is supposed to say (func-spec 0019 §6 S1)" $ do
  it "runs on push and on pull requests" $ do
    yml <- readUtf8 workflowPath
    yml `shouldSatisfy` ("\non:" `isInfixOf`)
    yml `shouldSatisfy` ("push:" `isInfixOf`)
    yml `shouldSatisfy` ("pull_request:" `isInfixOf`)

  it "covers both Tier 1 platforms in its matrix" $ do
    yml <- readUtf8 workflowPath
    matrixOses yml `shouldBe` ["ubuntu-latest", "windows-latest"]

  it "runs build, then test, then validate -- all three, in that order" $ do
    yml <- readUtf8 workflowPath
    mapM_ (\cmd -> (cmd, cmd `isInfixOf` yml) `shouldBe` (cmd, True)) ciCommands
    let positions = map (`lineOf` yml) ciCommands
    positions `shouldBe` sort positions

  it "points magic-validate at the shipped spells" $ do
    yml <- readUtf8 workflowPath
    let validateLines = [l | l <- lines yml, "cabal run magic-validate" `isInfixOf` l]
    validateLines `shouldSatisfy` any ("assets/spells" `isInfixOf`)

  -- h-raylib compiles raylib's C sources and links against the system
  -- X11/GL headers; without these the Linux job cannot build the demo
  -- executable at all. README documents the same list.
  it "installs the Linux system dependencies h-raylib needs" $ do
    yml <- readUtf8 workflowPath
    mapM_
      (\pkg -> (pkg, pkg `isInfixOf` yml) `shouldBe` (pkg, True))
      ["libx11-dev", "libxrandr-dev", "libxinerama-dev", "libxcursor-dev", "libxi-dev", "libgl1-mesa-dev"]

  -- A cold cache means recompiling raylib and the whole dependency
  -- closure on every push, which is the difference between CI being used
  -- and CI being ignored.
  it "caches the cabal store and the build tree" $ do
    yml <- readUtf8 workflowPath
    yml `shouldSatisfy` ("actions/cache" `isInfixOf`)
    yml `shouldSatisfy` ("cabal-store" `isInfixOf`)
    yml `shouldSatisfy` ("dist-newstyle" `isInfixOf`)

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
