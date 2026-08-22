-- | The hspec side of the out-of-process load smoke (host-runtime F006 T12).
--
-- __This spec does not run the harness and loads no shared library.__ That
-- is deliberate and it is the contract card's own wording: hspec "only
-- guards that it is in the shipping list". Running @test\/oop\/oop_smoke.c@
-- needs a C compiler and a built @.dll@\/@.so@, neither of which the test
-- suite may assume; driving it is @test\/oop\/run.sh@'s job, and wiring
-- that into CI is authoring-engineering's @ci-load-smoke-step@.
--
-- What is left for a text-only spec is everything that would otherwise
-- __rust in silence__. The poison library is not built by default, so its
-- export mirror could fall out of step with the shipped one and not even
-- produce a compile error; the probe list could grow in the C file and not
-- in the README; the required-symbol table could fall behind the @.def@,
-- which would quietly weaken the one check that acceptance-tests the export
-- face across a process boundary. Nothing else in the project would notice
-- any of those, so they are checked here.
module OopSmokeSpec (spec) where

import Control.Exception (evaluate)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
import qualified Data.Set as Set
import GHC.IO.Encoding (utf8)
import System.Directory (doesDirectoryExist, listDirectory)
import System.IO (IOMode (ReadMode), hClose, hGetContents, hSetEncoding, openFile)
import Test.Hspec

spec :: Spec
spec = describe "out-of-process load smoke (host-runtime F006)" $ do
  it "ships every file of the harness" $ do
    files <- harnessFiles
    listed <- cabalField "extra-source-files:"
    -- An empty listing would make the next line vacuously true, which is
    -- exactly how a guard like this dies: same discipline as
    -- ExampleHostSpec's S5.
    files `shouldSatisfy` (not . null)
    length files `shouldSatisfy` (>= 7)
    let missing = [f | f <- files, f `notElem` listed]
    missing `shouldBe` []

  it "keeps the poison export mirror in step with the shipped one" $ do
    shipped <- defExports "particle-magic-ffi.def"
    poison <- defExports "test/oop/particle-magic-ffi-poison.def"
    shipped `shouldSatisfy` (not . null)
    poison `shouldSatisfy` (not . null)
    -- Exactly one name more, and not one name fewer.
    Set.toList (Set.difference (Set.fromList poison) (Set.fromList shipped))
      `shouldBe` ["pm_poison_spell"]
    Set.toList (Set.difference (Set.fromList shipped) (Set.fromList poison))
      `shouldBe` []

  it "keeps the poison build out of the shipping one" $ do
    cabal <- readUtf8 "particle-magic.cabal"
    let ls = lines cabal
    -- The flag is manual and off, so no solver decision can turn it on.
    stanza "flag oop-poison" ls `shouldSatisfy` any (("default:" `isPrefixOf`) . trim)
    fieldOf "default:" (stanza "flag oop-poison" ls) `shouldBe` Just "False"
    fieldOf "manual:" (stanza "flag oop-poison" ls) `shouldBe` Just "True"
    -- And the stanza it guards is unbuildable without it.
    let poison = stanza "foreign-library particle-magic-ffi-poison" ls
    poison `shouldSatisfy` any (("if !flag(oop-poison)" ==) . trim)
    poison `shouldSatisfy` any (("buildable:" `isPrefixOf`) . trim)
    fieldOf "buildable:" poison `shouldBe` Just "False"
    -- The shipped library never compiles the poison module.
    let shipped = stanza "foreign-library particle-magic-ffi" ls
    shipped `shouldSatisfy` (not . null)
    unwords shipped `shouldNotSatisfy` ("Magic.FFI.Poison" `isInfixOf`)
    -- ... and the poison one is where the module actually lives.
    unwords poison `shouldSatisfy` ("Magic.FFI.Poison" `isInfixOf`)
    -- Different product name: a harder guard than the flag, because it
    -- survives someone building with -foop-poison by accident.
    unwords poison `shouldSatisfy` ("test/oop/particle-magic-ffi-poison.def" `isInfixOf`)

  it "documents exactly the probes it registers" $ do
    inCode <- registeredProbes
    inDoc <- documentedProbes
    inCode `shouldSatisfy` (not . null)
    inDoc `shouldSatisfy` (not . null)
    sort inDoc `shouldBe` sort inCode

  it "requires exactly the symbols the library ships" $ do
    required <- requiredSymbols
    shipped <- defExports "particle-magic-ffi.def"
    required `shouldSatisfy` (not . null)
    -- The harness FAILs when one of these does not resolve, so this table
    -- falling behind the .def would silently stop acceptance-testing the
    -- newest entry points across a process boundary.
    sort required `shouldBe` sort shipped

-- Sources ---------------------------------------------------------------------

harnessDir :: FilePath
harnessDir = "test/oop"

-- | Every checked-in file under @test\/oop@, recursively. The harness's own
-- executable is a build product (see .gitignore) and is not one.
harnessFiles :: IO [FilePath]
harnessFiles = sort <$> walk harnessDir
  where
    walk dir = do
      entries <- listDirectory dir
      concat
        <$> mapM
          ( \e -> do
              let path = dir ++ "/" ++ e
              isDir <- doesDirectoryExist path
              if isDir
                then walk path
                else pure [path | not (buildProduct e)]
          )
          entries
    buildProduct e = e `elem` ["oop-smoke", "oop-smoke.exe"] || ".obj" `isSuffix` e
    isSuffix suf s = suf `isPrefixOf` reverse' s
      where reverse' = reverse . take (length suf) . reverse

-- | Symbol names under @EXPORTS@ in a module definition file. The same
-- shape FFIContractSpec parses the shipped one with; each spec in this repo
-- carries its own small parsers rather than sharing a helper module.
defExports :: FilePath -> IO [String]
defExports path = do
  contents <- readUtf8 path
  pure
    [ t
    | l <- drop 1 (dropWhile (\l -> trim l /= "EXPORTS") (lines contents))
    , let t = trim l
    , not (null t)
    , not (";" `isPrefixOf` t)
    ]

-- | The probe names registered in the C file's dispatch table.
registeredProbes :: IO [String]
registeredProbes = do
  contents <- readUtf8 (harnessDir ++ "/oop_smoke.c")
  let body =
        takeWhile (not . ("};" `isPrefixOf`))
          (drop 1 (dropWhile (not . ("static const Probe PROBES[]" `isPrefixOf`)) (lines contents)))
  pure [n | l <- body, Just n <- [firstStringLiteral l]]

-- | The names of the entry points the harness insists on resolving.
requiredSymbols :: IO [String]
requiredSymbols = do
  contents <- readUtf8 (harnessDir ++ "/oop_smoke.c")
  let body =
        takeWhile (not . ("NULL};" `isPrefixOf`) . trim)
          (drop 1 (dropWhile (not . ("static const char *const REQUIRED_SYMBOLS[]" `isPrefixOf`)) (lines contents)))
  pure [n | l <- body, Just n <- [firstStringLiteral l]]

-- | The probe names the README's @## Probes@ table lists: the first cell of
-- every row whose first cell is one backticked word. Scoped to that one
-- section, because the README has other tables with backticked cells.
documentedProbes :: IO [String]
documentedProbes = do
  contents <- readUtf8 (harnessDir ++ "/README.md")
  let section =
        takeWhile (not . ("## " `isPrefixOf`))
          (drop 1 (dropWhile (/= "## Probes") (map trim (lines contents))))
  pure [n | l <- section, Just n <- [backtickedCell l]]

backtickedCell :: String -> Maybe String
backtickedCell l = case l of
  ('|' : rest) -> case break (== '|') rest of
    (cell, _) -> case trim cell of
      ('`' : body) | not (null body), last body == '`' ->
        let name = init body
         in if null name || any isSpace name then Nothing else Just name
      _ -> Nothing
  _ -> Nothing

firstStringLiteral :: String -> Maybe String
firstStringLiteral l = case dropWhile (/= '"') l of
  ('"' : rest) -> case break (== '"') rest of
    (s, '"' : _) -> Just s
    _ -> Nothing
  _ -> Nothing

-- Cabal ----------------------------------------------------------------------

-- | The lines of one cabal stanza: its header, then everything indented
-- under it up to the next top-level line.
stanza :: String -> [String] -> [String]
stanza header ls =
  takeWhile (\l -> null (trim l) || startsIndented l)
    (drop 1 (dropWhile (\l -> trim l /= header) ls))

startsIndented :: String -> Bool
startsIndented (c : _) = isSpace c
startsIndented [] = False

-- | The value of a simple @key: value@ line inside a stanza.
fieldOf :: String -> [String] -> Maybe String
fieldOf key ls = case [trim (drop (length key) (trim l)) | l <- ls, key `isPrefixOf` trim l] of
  (v : _) -> Just v
  [] -> Nothing

-- | Values of a multi-line cabal field: the first entry sits inline with
-- the key, the rest on indented continuation lines.
cabalField :: String -> IO [String]
cabalField key = do
  contents <- readUtf8 "particle-magic.cabal"
  pure (go (lines contents))
  where
    go [] = []
    go (l : ls)
      | key `isPrefixOf` trim l =
          let inline = trim (drop (length key) (trim l))
           in filter (not . null) (inline : map trim (takeWhile continues ls))
      | otherwise = go ls
    continues l =
      startsIndented l && not (null (trim l)) && not ("--" `isPrefixOf` trim l)

-- Small helpers ---------------------------------------------------------------

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | Read as UTF-8 whatever the machine's locale is, and drop the CRs the
-- checked-out tree carries on Windows. Same shape as FFIContractSpec's:
-- the README has em dashes in it, so the locale must not get a vote.
readUtf8 :: FilePath -> IO String
readUtf8 path = do
  h <- openFile path ReadMode
  hSetEncoding h utf8
  contents <- hGetContents h
  _ <- evaluate (length contents)
  hClose h
  pure (filter (/= '\r') contents)
