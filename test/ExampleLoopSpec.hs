-- | host-runtime F008: the texts a non-Haskell host actually reads.
--
-- A host never opens "Magic.Compile". It opens @include\/particle_magic.h@,
-- copies @examples\/c\/main.c@ and follows @docs\/integration.md@ -- and
-- none of those three is compiled by @cabal build@, so nothing in the
-- toolchain notices when what they say stops being true. Two things had
-- stopped being true: the particle cap ("today it answers
-- PM_MAX_PARTICLES", which had not been so since func-spec 0012 raised the
-- core cap to 16384), and the main loop (a bare @while (acc >= dt)@ with
-- no ceiling, which one loading hitch turns into the spiral of death).
--
-- This spec is the guard that keeps them fixed. It compares text against
-- text and text against fact; it links nothing and runs no example. The
-- one thing it does execute is 'plan', to show that the rewritten loop
-- still advances exactly once per synthetic frame -- which is what makes
-- @ExampleHostSpec@'s golden survive the rewrite unchanged.
--
-- Deliberately self-contained (the same discipline as "ReleaseDocSpec" and
-- "CIWorkflowSpec"): its file readers and its @os:@ parser are local
-- copies. The one import is @headerDefines@ from "FFIContractSpec", which
-- owns the header parsers precisely so a second copy of them does not have
-- to exist.
module ExampleLoopSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isDigit, isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import FFIContractSpec (headerDefines)
import Magic.Step (StepPlan (..), plan)
import Test.Hspec

headerPath, mainCPath, sceneCPath :: FilePath
headerPath = "include/particle_magic.h"
mainCPath = "examples/c/main.c"
sceneCPath = "examples/c/scene.c"

rendererPath, smokePath, unityReadmePath :: FilePath
rendererPath = "examples/unity/SpellRenderer.cs"
smokePath = "examples/unity/PmSmoke.cs"
unityReadmePath = "examples/unity/README.md"

integrationPath, ciPath, cabalPath, ffiPath :: FilePath
integrationPath = "docs/integration.md"
ciPath = ".github/workflows/ci.yml"
cabalPath = "particle-magic.cabal"
ffiPath = "src/ffi/Magic/FFI.hs"

-- | UTF-8 bytes with carriage returns dropped: this tree is CRLF on
-- Windows and LF on Linux, and a text-comparing spec would otherwise
-- disagree with itself across the two CI runners.
readUtf8 :: FilePath -> IO String
readUtf8 path = filter (/= '\r') . T.unpack . TE.decodeUtf8 <$> BS.readFile path

hasInfix :: String -> String -> Bool
hasInfix = isInfixOf

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | Assert a needle is present, naming it in the failure instead of
-- printing @False /= True@.
want :: String -> String -> Expectation
want haystack needle = (needle, hasInfix needle haystack) `shouldBe` (needle, True)

-- | ... and the mirror, for a phrase that had to go away.
reject :: String -> String -> Expectation
reject haystack needle = (needle, hasInfix needle haystack) `shouldBe` (needle, False)

-- ------------------------------------------------------------ text slicing

-- | The lines strictly between two marker lines, exclusive of both. Empty
-- when either marker is missing, which every caller guards against: a
-- vacuous block would make every @want@ on it fail rather than pass, but
-- every @reject@ on it pass, and that asymmetry is exactly the false green
-- this spec exists to avoid.
between :: String -> String -> String -> String
between from to contents =
  case dropWhile (not . (from `isPrefixOf`)) (lines contents) of
    [] -> ""
    (_ : rest) ->
      let body = takeWhile (not . (to `isPrefixOf`)) rest
       in if length body == length rest then "" else unlines body

-- | A numbered markdown section: its heading line plus everything up to
-- the next heading at the same level or above.
mdSection :: String -> String -> String
mdSection marker doc =
  case dropWhile (not . (marker `isPrefixOf`)) (lines doc) of
    [] -> ""
    (h : rest) -> unlines (h : takeWhile (not . isHeading) rest)
  where
    depth = length (takeWhile (== '#') marker)
    isHeading l =
      let hashes = length (takeWhile (== '#') l)
       in hashes > 0 && hashes <= depth && " " `isPrefixOf` drop hashes l

-- | Only the fenced code blocks of a chunk of markdown.
--
-- Scoped this tightly on purpose. Asserting "the section mentions
-- pm_plan_steps" passes on the prose ABOUT the planner while the recipe
-- printed underneath is still the hand-rolled loop -- verified by
-- reverting the §2.4 recipe and watching the looser assertion stay green.
-- What a host copies is the code block, so the code block is what gets
-- asserted.
fencedCode :: String -> String
fencedCode = unlines . go False . lines
  where
    go _ [] = []
    go inside (l : ls)
      | "```" `isPrefixOf` trim l = go (not inside) ls
      | inside = l : go inside ls
      | otherwise = go inside ls

-- | A C function's body: from the line the signature starts on, down to
-- and including the first line that is a lone closing brace.
cFunction :: String -> String -> String
cFunction marker contents =
  case dropWhile (not . (marker `isPrefixOf`)) (lines contents) of
    [] -> ""
    body -> unlines (takeWhileInclusive (\l -> trim l /= "}") body)
  where
    takeWhileInclusive _ [] = []
    takeWhileInclusive p (x : xs)
      | p x = x : takeWhileInclusive p xs
      | otherwise = [x]

countOf :: String -> String -> Int
countOf needle = length . filter (needle `isPrefixOf`) . tails'
  where
    tails' [] = [[]]
    tails' xs@(_ : rest) = xs : tails' rest

-- | The value of a C# @const int Name = N;@ whose name contains @frag@.
csharpConstInt :: String -> String -> Maybe Int
csharpConstInt frag contents =
  case [l | l <- map trim (lines contents), "const int " `isPrefixOf` l, frag `isInfixOf` l] of
    (l : _) -> case span isDigit (dropWhile (not . isDigit) l) of
      ("", _) -> Nothing
      (ds, _) -> Just (read ds)
    [] -> Nothing

-- | The runner labels of the workflow's @os:@ matrix line. A local copy of
-- "CIWorkflowSpec"'s parser, on purpose: these two specs check different
-- claims about the same line and neither should be able to break the
-- other by refactoring.
matrixOses :: String -> [String]
matrixOses contents =
  case [trim (drop 3 (trim l)) | l <- lines contents, "os:" `isPrefixOf` trim l] of
    (v : _) -> sort (map trim (splitOn ',' (takeWhile (/= ']') (drop 1 (dropWhile (/= '[') v)))))
    [] -> []

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (chunk, []) -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn c rest

-- ------------------------------------------------------------------- spec

spec :: Spec
spec = describe "what a non-Haskell host reads (host-runtime F008)" $ do
  -- T3
  it "teaches the query and the planner in the header's usage sketches" $ do
    header <- readUtf8 headerPath
    let single = between " * Usage:" " * Scenes:" header
        scene = between " * Scenes:" " * Two things to get right" header
        note = between " * Two things to get right" " * Coordinate system:" header

    -- Vacuity guard first: a sketch this spec could not find would make
    -- every rejection below pass for the wrong reason.
    mapM_
      (\(n, b) -> (n, null b) `shouldBe` (n, False))
      [("single-cast sketch", single), ("scene sketch", scene), ("the two notes", note)]

    mapM_ (want single) ["pm_max_particles()", "pm_plan_steps", "pm_advance_ex", "cap, info, 8"]
    -- The two lines this feature exists to retire.
    mapM_ (reject single) ["PM_MAX_PARTICLES, info", "pm_advance(s,"]

    mapM_ (want scene) ["pm_plan_steps", "pm_scene_advance_ex"]
    reject scene "pm_scene_advance(sc,"

    -- ... while the note that was already right is left alone: a scene's
    -- columns come from its own cap, not from the per-spell query.
    want note "global_cap"

  -- T4
  it "sizes examples/c/main.c from the query, never from the frozen macro" $ do
    src <- readUtf8 mainCPath
    want src "pm_max_particles("
    want src "alloc_columns(&cols, cap)"
    -- The whole point: the frozen macro is gone from the example.
    reject src "PM_MAX_PARTICLES"

    -- Every column allocated is a column released. Counted inside the two
    -- functions so that a seventh malloc with no matching free is red,
    -- and so that pm_free's substring cannot be mistaken for a free().
    let allocBody = cFunction "static int alloc_columns" src
        freeBody = cFunction "static void free_columns" src
    (countOf "malloc(" allocBody, countOf "free(" freeBody) `shouldBe` (6, 6)
    want src "free_columns(&cols);"

  -- T5
  it "drives main.c's 120 frames through the planner, exactly one step each" $ do
    src <- readUtf8 mainCPath
    mapM_
      (want src)
      [ "#define FRAMES 120"
      , "#define FIXED_DT_F (1.0f / 60.0f)"
      , "#define FIXED_DT   ((double)FIXED_DT_F)"
      , "#define MAX_STEPS_PER_FRAME 8"
      , "pm_plan_steps(FIXED_DT, MAX_STEPS_PER_FRAME, FIXED_DT, acc,"
      , "pm_advance_ex(spell, FIXED_DT_F)"
      ]
    reject src "pm_advance(spell, DT)"

    -- ... and the arithmetic behind "the golden does not move": the
    -- example feeds the planner exactly one fixed step of synthetic
    -- elapsed time, so it plans one step and carries nothing over. Same
    -- float-to-double widening the C macros do.
    let fixedDt = realToFrac (1 / 60 :: Float) :: Double
    plan fixedDt 8 fixedDt 0 `shouldBe` StepPlan 1 0

  -- T6
  it "plans the scene example's steps too" $ do
    src <- readUtf8 sceneCPath
    mapM_ (want src) ["pm_plan_steps", "pm_scene_advance_ex", "MAX_STEPS_PER_FRAME"]
    reject src "pm_scene_advance(scene, DT)"
    -- The capacity path was already right; this checks it was not tidied
    -- away while the loop next to it was rewritten.
    mapM_ (want src) ["probe_budget", "alloc_columns(&cols, cap)"]

  -- T7
  it "plans SpellRenderer's steps with a per-frame ceiling" $ do
    src <- readUtf8 rendererPath
    mapM_ (want src) ["pm_plan_steps", "pm_advance_ex", "double accumulator;"]
    reject src "while (accumulator >="
    reject src "float accumulator;"
    csharpConstInt "MaxSteps" src `shouldBe` Just 8

  -- T8
  it "primes the accumulator with the type SpellRenderer declares" $ do
    smoke <- readUtf8 smokePath
    -- The reflection is by name and the field kept its name, so this
    -- still resolves; what changed is the boxed type handed to SetValue,
    -- and a float there is an ArgumentException at run time.
    want smoke "GetField(\"accumulator\""
    want smoke "accumulator.SetValue(renderer, 0.1)"
    reject smoke "accumulator.SetValue(renderer, 0.1f)"

    readme <- readUtf8 unityReadmePath
    mapM_ (want readme) ["pm_plan_steps", "pm_scene_advance_ex"]

  -- T9
  it "shows the planner in every loop recipe the guide prints" $ do
    doc <- readUtf8 integrationPath
    let recipes =
          [ ("§2.4", fencedCode (mdSection "### 2.4" doc))
          , ("§4.2", fencedCode (mdSection "### 4.2" doc))
          , ("§5.4", fencedCode (mdSection "### 5.4" doc))
          ]
    mapM_ (\(n, s) -> (n, null (trim s)) `shouldBe` (n, False)) recipes
    -- The code a host copies plans its steps ...
    mapM_ (\(n, s) -> (n, hasInfix "pm_plan_steps" s) `shouldBe` (n, True)) recipes
    -- ... and does not roll its own accumulator next to it.
    mapM_ (\(n, s) -> (n, hasInfix "accumulator +=" s) `shouldBe` (n, False)) recipes

    -- §6 is a prose checklist, not a code block; it carries the same rule
    -- in words.
    let s6 = mdSection "## 6." doc
    (null s6) `shouldBe` False
    want s6 "pm_plan_steps"

    -- And neither hand-rolled loop survives anywhere in the guide.
    mapM_
      (reject doc)
      ["while (accumulator >= FIXED_DT)", "while (accumulator >= FixedDt)", "accumulator +="]

    -- §4.2 is the executable one's twin, so it sizes from the query and
    -- still says which file to read for the rest.
    let s42 = mdSection "### 4.2" doc
    reject s42 "PM_MAX_PARTICLES"
    want s42 "examples/c/main.c"

  -- T10
  it "documents every error code the header defines" $ do
    defined <- headerDefines
    doc <- readUtf8 integrationPath
    let sec = mdSection "### 4.3" doc
        codes = [n | (n, _) <- defined, "PM_ERR_" `isPrefixOf` n]
    (null sec) `shouldBe` False
    -- Vacuity guard: an empty code list would make the fold below say
    -- nothing at all.
    length codes `shouldSatisfy` (>= 7)
    mapM_ (want sec) codes

  -- T11
  it "names the platforms the CI matrix actually runs" $ do
    yml <- readUtf8 ciPath
    doc <- readUtf8 integrationPath
    let oses = matrixOses yml
        sec = mdSection "## 8." doc
    oses `shouldBe` ["ubuntu-latest", "windows-latest"]
    (null sec) `shouldBe` False
    mapM_ (want sec) oses
    reject sec "只有 win64"
    -- The DLL size row is correct as it stands (measured 45.8 MiB); all
    -- that is asserted is that it was not deleted along with the row
    -- above it.
    want sec "MB"

  -- T12
  it "is a module cabal was told about" $ do
    cabalSrc <- readUtf8 cabalPath
    let listed =
          [ t
          | l <- lines cabalSrc
          , let t = trim l
          , t == "ExampleLoopSpec" || t == ", ExampleLoopSpec"
          ]
    length listed `shouldBe` 1

  -- T1/T2 live in FFIContractSpec, which owns the header/Haskell prose
  -- sentinels. This is the third text those two corrections had to reach:
  -- the guide's own account of the two constants.
  it "keeps the guide's account of the cap in step with the header's" $ do
    doc <- readUtf8 integrationPath
    ffi <- readUtf8 ffiPath
    reject doc "Today it answers"
    reject ffi "Today it answers"
    want (mdSection "### 2.5" doc) "pm_max_particles()"
    want (mdSection "### 2.5" doc) "16384"
