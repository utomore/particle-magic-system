-- | enhance-0001: the Haskell reference host in @examples\/haskell\/@.
--
-- Same predicament as @BindingContractSpec@, and the same remedy. The
-- example is a /separate cabal package/ on purpose — that is what makes
-- it evidence that an outside project can consume this library — and the
-- price of that is that @cabal build all@ never compiles it. Without a
-- text-and-golden check here, the example would be free to rot: a renamed
-- export, a changed sampler or a new dependency would all ship green.
--
-- Four things are asserted.
--
--   * __The example is an outside consumer.__ Its cabal file depends on
--     @magic-boundary@, cannot reach @magic-core@, and links no renderer.
--     Its @cabal.project@ points back at the repo root, which is the
--     offline stand-in for the @source-repository-package@ stanza a real
--     host writes.
--   * __Its import surface is the documented one.__ Every @Magic.*@
--     module it imports is named by integration.md §3, and no other. Both
--     directions matter: the doc's list is the contract, and the example
--     is the thing held to it.
--   * __The golden is what the example prints.__
--     @examples\/haskell\/expected-output.txt@ is recomputed here through
--     plain 'Magic.Interface' and compared line by line, so the file a
--     reader diffs against is a checked artefact rather than a snapshot
--     somebody took once.
--   * __Both example hosts see the same simulation.__ The same 120 frames
--     driven through the C ABI shim, exactly as @examples\/c\/main.c@
--     drives it, produce the same numbers. That is enhance-0001 §2.1's
--     acceptance: the two hosts are diffable against each other, not
--     merely each self-consistent. (Projection equivalence across the two
--     paths is @Acceptance11Spec@'s job and is not repeated here.)
--
-- One detail is load-bearing and worth stating once: 'pm_advance' takes a
-- @float@ and widens it, so a C host stepping @1.0f\/60.0f@ and a Haskell
-- host stepping @1\/60 :: Double@ are running /different/ simulations.
-- Determinism is per-input (ADR-0011 D8), and @dt@ is an input. The
-- example narrows on purpose; 'FFIHarness.referenceStates' has always
-- done the same, which is why both sides line up here for free.
module ExampleHostSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector.Unboxed as U
import FFIHarness (Observed (..), castOk, observeRaw, referenceStates, spellBytes, testCtx)
import Foreign.C.Types (CDouble (..), CFloat (..))
import Foreign.StablePtr (StablePtr)
import GHC.Float (float2Double)
import GoldenPlatform (platformScopeNote, referencePlatform)
import Magic.FFI (SpellCell, pm_advance, pm_age, pm_free, pm_is_finished)
import Magic.Interface
  ( ActiveSpell
  , BlendMode (..)
  , FrameOutput (..)
  , ParticleBuffer
  , RenderBatch (..)
  , Time (..)
  , V3 (..)
  , isFinished
  , observeSpell
  , pbCount
  , pbLife
  , pbPosX
  , pbPosY
  , pbPosZ
  , pbSize
  , spellAge
  )
import Magic.Projection (V2 (..), ViewPlane (..), depthOrder, orthographic)
import System.Directory (listDirectory)
import Test.Hspec
import Text.Printf (printf)
import Text.Read (readMaybe)

-- Where the example lives -----------------------------------------------------

exampleDir :: FilePath
exampleDir = "examples/haskell"

goldenPath, mainPath, projectPath, cabalPath :: FilePath
goldenPath = exampleDir ++ "/expected-output.txt"
mainPath = exampleDir ++ "/Main.hs"
projectPath = exampleDir ++ "/cabal.project"
cabalPath = exampleDir ++ "/particle-magic-example.cabal"

-- | The example's own run parameters, restated here on purpose: this
-- module is the independent second computation, so it may not read them
-- off the example's source. The cast context is 'testCtx', which
-- @examples\/c\/main.c@ already uses — that shared context is what makes
-- the two hosts comparable at all.
exampleSpell :: String
exampleSpell = "ring-fire"

exampleSpellPath :: String
exampleSpellPath = "../../assets/spells/" ++ exampleSpell ++ ".json"

frames :: Int
frames = 120

-- | The step as a @float@ — the width the C ABI's @dt@ parameter has.
dtFloat :: Float
dtFloat = 1 / 60

-- | The six columns and the batch table a host allocates. Matching
-- @examples\/c\/main.c@'s @MAX_BATCHES@ matters (a smaller table would
-- turn into @PM_ERR_CAPACITY@ rather than a different number).
hostCapacity, hostMaxBatches :: Int
hostCapacity = 16384
hostMaxBatches = 8

spec :: Spec
spec = describe "Haskell reference host (enhance-0001 E1)" $ do
  describe "S1 — it is an outside consumer, not a stanza of this package" $ do
    it "depends on magic-boundary and cannot reach magic-core" $ do
      deps <- exampleDeps
      map depName deps `shouldSatisfy` elem "magic-boundary"
      map depName deps `shouldSatisfy` notElem "magic-core"

    it "links no renderer and no effect system (it draws nothing, by design)" $ do
      deps <- exampleDeps
      map depName deps `shouldSatisfy` all (`notElem` ["h-raylib", "effectful"])

    it "stays inside the host whitelist {base, magic-boundary, bytestring, vector}" $ do
      deps <- exampleDeps
      map depName deps `shouldSatisfy` all (`elem` ["base", "magic-boundary", "bytestring", "vector"])

    it "resolves particle-magic through its own cabal.project, pointing at the repo root" $ do
      project <- readUtf8 projectPath
      packageEntries project `shouldSatisfy` elem "../.."

    it "shows the source-repository-package form a real host would write instead" $ do
      project <- readUtf8 projectPath
      project `shouldSatisfy` hasInfix "source-repository-package"

  describe "S2 — its import surface is the one integration.md §3 promises" $ do
    it "imports only the documented boundary modules" $ do
      imports <- exampleMagicImports
      imports `shouldSatisfy` not . null
      imports `shouldSatisfy` all (`elem` documentedModules)

    it "imports nothing the guide does not show in an import position" $ do
      imports <- exampleMagicImports
      doc <- readUtf8 "docs/integration.md"
      mapM_ (\m -> (m, hasInfix ("import " ++ m) doc) `shouldBe` (m, True)) imports

  describe "S3 — the golden is what the example prints" $
    it "matches an independent recomputation through Magic.Interface" $ do
      expected <- goldenLines
      actual <- referenceRun
      -- Zipped so a failure names the offending line instead of dumping
      -- 130 of them twice.
      length actual `shouldBe` length expected
      mapM_ (uncurry sameLine) (zip actual expected)

  describe "S4 — the C host sees the same simulation" $
    it "reproduces every frame line through the C ABI, as examples/c/main.c drives it" $ do
      expected <- goldenLines
      actual <- ffiRun
      let comparable = takeWhile (not . isPrefixOf "projection") (drop 1 expected)
      length actual `shouldBe` length comparable
      mapM_ (uncurry sameLine) (zip actual comparable)

  describe "S5 — the example ships with the package" $
    it "lists every one of its files in extra-source-files" $ do
      shipped <- exampleFiles
      declared <- extraSourceFiles
      shipped `shouldSatisfy` not . null
      mapM_ (\f -> (f, f `elem` declared) `shouldBe` (f, True)) shipped

  describe "S6 — integration.md carries the 2D/pixel-art recipe" $ do
    it "has the recipe section" $ do
      doc <- readUtf8 "docs/integration.md"
      doc `shouldSatisfy` hasInfix "2D／像素風宿主食譜"

    it "names both view planes and the facing that decides between them" $ do
      doc <- readUtf8 "docs/integration.md"
      mapM_
        (\needle -> (needle, hasInfix needle doc) `shouldBe` (needle, True))
        ["SideXY", "TopXZ", "casterFacing"]

    it "points a Haskell host at the runnable example" $ do
      doc <- readUtf8 "docs/integration.md"
      doc `shouldSatisfy` hasInfix "examples/haskell"

-- The two runs ----------------------------------------------------------------

-- | The example's whole output, recomputed through 'Magic.Interface'.
referenceRun :: IO [String]
referenceRun = do
  bytes <- spellBytes exampleSpell
  let states = referenceStates bytes (replicate frames dtFloat)
      final = last states
  pure $
    ("spell: " ++ exampleSpellPath)
      : zipWith referenceFrame [0 .. frames - 1] states
      ++ finishedLine (fromEnum (isFinished final))
      : projectionBlock (observeSpell final)

referenceFrame :: Int -> ActiveSpell -> String
referenceFrame i st = frameLine i age (length bs) total (leadBlend bs) (checksum bs)
  where
    FrameOutput bs = observeSpell st
    Time age = spellAge st
    total = sum (map (pbCount . rbParticles) bs)

-- | The same 120 frames driven through the C ABI shim in process — the
-- call sequence of @examples\/c\/main.c@, in its order.
ffiRun :: IO [String]
ffiRun = do
  bytes <- spellBytes exampleSpell
  handle <- castOk bytes testCtx
  ls <- mapM (ffiFrame handle) [0 .. frames - 1]
  done <- pm_is_finished handle
  pm_free handle
  pure (ls ++ [finishedLine (fromIntegral done)])

ffiFrame :: StablePtr SpellCell -> Int -> IO String
ffiFrame handle i = do
  pm_advance handle (CFloat dtFloat)
  obs <- observeRaw handle hostCapacity hostMaxBatches
  CDouble age <- pm_age handle
  let batches = fromIntegral (obCode obs)
      total = sum [infoAt obs (4 * b + 1) | b <- [0 .. batches - 1]]
      blend = if batches > 0 then infoAt obs 2 else -1
  pure (frameLine i age batches total blend (ffiChecksum obs total))

infoAt :: Observed -> Int -> Int
infoAt obs i = fromIntegral (obInfo obs !! i)

-- | @checksum += x + y + z + size + life@, per particle, in the C host's
-- association: the per-particle sum is formed first and only then added
-- to the running total. Written the other way the two hosts would part
-- company in the last digits.
ffiChecksum :: Observed -> Int -> Double
ffiChecksum obs total = foldl add 0 [0 .. total - 1]
  where
    add acc i =
      acc
        + ( ((at obPosX i + at obPosY i) + at obPosZ i)
              + at obSize i
              + at obLife i
          )
    at col i = float2Double (col obs !! i)

-- Shared formatting -----------------------------------------------------------

frameLine :: Int -> Double -> Int -> Int -> Int -> Double -> String
frameLine =
  printf "frame %3d  age %8.5f  batches %d  particles %4d  blend %d  checksum %.6f"

finishedLine :: Int -> String
finishedLine = printf "finished: %d"

leadBlend :: [RenderBatch] -> Int
leadBlend [] = -1
leadBlend (b : _) = case rbBlend b of
  BlendAlpha -> 0
  BlendAdditive -> 1

checksum :: [RenderBatch] -> Double
checksum = foldl (\acc b -> bufferSum acc (rbParticles b)) 0

bufferSum :: Double -> ParticleBuffer -> Double
bufferSum start pb = foldl add start [0 .. pbCount pb - 1]
  where
    add acc i =
      acc
        + ( (((at pbPosX i + at pbPosY i) + at pbPosZ i) + at pbSize i)
              + at pbLife i
          )
    at col i = float2Double (col pb U.! i)

projectionBlock :: FrameOutput -> [String]
projectionBlock (FrameOutput []) = ["projection: nothing left to draw"]
projectionBlock (FrameOutput (b : _)) = concatMap forPlane [SideXY, TopXZ]
  where
    pb = rbParticles b
    forPlane :: ViewPlane -> [String]
    forPlane plane =
      planeHeader (show plane) (pbCount pb)
        : [rowLine (depthOrder plane pb) plane k | k <- [0 .. min 3 (pbCount pb) - 1]]
    rowLine :: U.Vector Int -> ViewPlane -> Int -> String
    rowLine order plane k =
      projectionRow k i (float2Double u) (float2Double v) (float2Double d)
      where
        i = order U.! k
        (V2 u v, d) =
          orthographic plane (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i))

planeHeader :: String -> Int -> String
planeHeader = printf "projection %s: %d particles, far to near"

projectionRow :: Int -> Int -> Double -> Double -> Double -> String
projectionRow = printf "  %d  slot %4d  plane (%9.5f, %9.5f)  depth %9.5f"

-- Comparison ------------------------------------------------------------------

-- | One golden line against one produced line, under ADR-0016's scoping.
--
-- @expected-output.txt@ is a golden like every other in this repository
-- and inherits the same law: bit-for-bit /on the platform it was recorded
-- on/ (windows\/x86_64), structural everywhere else. It is worth being
-- concrete about why this file needs it at all, because the numbers here
-- are not positions — they are a @checksum@ column and projected plane
-- coordinates, both of them /sums/ over the position columns. So the 1 ulp
-- that libm's @sin@\/@cos@ can differ by (func-spec 0019 S2 measured it:
-- 1.79e-07 world units, @pbPosX@ and @pbPosZ@ only) does not stay at 1 ulp
-- once a few hundred particles have been added up. The first Linux run of
-- this spec differed in exactly one digit of one frame's checksum
-- (81.830827 vs 81.830826), which is that effect and nothing else.
--
-- Everything that is /not/ a float is still compared exactly on every
-- platform: the frame index, the particle count, the batch count, the
-- blend code, the slot permutation the depth order produces. That is the
-- cross-platform half of the law — same particles, same order, same
-- counts — and it is the half that would catch a real regression.
sameLine :: String -> String -> Expectation
sameLine actual expected
  | referencePlatform = actual `shouldBe` expected
  | tokensAgree = pure ()
  | otherwise =
      expectationFailure
        ( "line differs beyond the cross-platform tolerance:\n  golden: "
            ++ expected
            ++ "\n  actual: "
            ++ actual
            ++ "\n  "
            ++ platformScopeNote
        )
  where
    tokensAgree = length as == length es && and (zipWith tokenEq as es)
    (as, es) = (tokenize actual, tokenize expected)

    -- The punctuation is dropped on both sides alike, so the words around
    -- the numbers ("frame", "slot", "plane", "depth") still have to line
    -- up — only the numerals get the tolerance.
    tokenize = words . map (\c -> if c `elem` ("()," :: String) then ' ' else c)

    tokenEq a e = case (readMaybe a, readMaybe e) of
      (Just x, Just y) -> abs (x - y) <= 1e-5 * (1 + max (abs x) (abs y :: Double))
      _ -> a == e

-- Parsers ---------------------------------------------------------------------

goldenLines :: IO [String]
goldenLines = lines <$> readUtf8 goldenPath

exampleDeps :: IO [String]
exampleDeps = stanzaDeps cabalPath "executable pm-haskell-host"

-- | Sublibrary deps are written @particle-magic:magic-boundary@; compare
-- by the part after the colon (the same convention "BoundarySpec" uses).
depName :: String -> String
depName d = case break (== ':') d of
  (n, "") -> n
  (_, ':' : n) -> n
  (n, _) -> n

packageEntries :: String -> [String]
packageEntries = fieldEntriesIn "packages:"

extraSourceFiles :: IO [FilePath]
extraSourceFiles = fieldEntriesIn "extra-source-files:" <$> readUtf8 "particle-magic.cabal"

-- | Values of a multi-line cabal field: the first entry sits inline with
-- the key, the rest on indented continuation lines.
fieldEntriesIn :: String -> String -> [String]
fieldEntriesIn key contents = go (lines contents)
  where
    go [] = []
    go (l : ls)
      | key `isPrefixOf` trim l =
          let inline = trim (drop (length key) (trim l))
           in filter (not . null) (inline : map trim (takeWhile continues ls))
      | otherwise = go ls
    continues l =
      not (null l) && isSpace (head l) && not (null (trim l)) && not ("--" `isPrefixOf` trim l)

-- | The @Magic.*@ modules the example imports.
exampleMagicImports :: IO [String]
exampleMagicImports = do
  source <- readUtf8 mainPath
  pure (sort (dedupe [m | l <- lines source, Just m <- [importedModule l], "Magic." `isPrefixOf` m]))

-- | The modules integration.md §3 declares to be the Haskell host's whole
-- contract. A literal, so a module quietly dropped from the guide fails
-- here instead of silently shrinking the check.
documentedModules :: [String]
documentedModules = ["Magic.Codec", "Magic.Interface", "Magic.Projection", "Magic.Columns"]

-- | Everything under @examples\/haskell@ that is checked in (the build
-- tree is not).
exampleFiles :: IO [FilePath]
exampleFiles = do
  entries <- listDirectory exampleDir
  pure (sort [exampleDir ++ "/" ++ e | e <- entries, e /= "dist-newstyle"])

-- | @build-depends:@ names of one stanza of a cabal file.
stanzaDeps :: FilePath -> String -> IO [String]
stanzaDeps path header = do
  contents <- readUtf8 path
  let body = drop 1 (dropWhile (\l -> trim l /= header) (lines contents))
      stanza = takeWhile (\l -> null (trim l) || isSpace (head l)) body
  pure (depsIn stanza)

depsIn :: [String] -> [String]
depsIn ls = case break (isPrefixOf "build-depends:" . trim) ls of
  (_, []) -> []
  (_, field : rest) ->
    let inline = trim (drop (length "build-depends:") (trim field))
        cont = takeWhile continues rest
        entries = concatMap (splitOn ',') (inline : map trim cont)
     in [name | e <- entries, let name = nameOf e, not (null name)]
  where
    -- A continuation is indented and is not the next field: a field's key
    -- carries the colon, a dependency line starts with a comma.
    continues l =
      not (null (trim l)) && isSpace (head l) && not (isFieldStart (trim l))
    isFieldStart l = not ("," `isPrefixOf` l) && ':' `elem` takeWhile (not . isSpace) l
    nameOf =
      trim
        . takeWhile (\c -> not (isSpace c) && c `notElem` ("^>=<" :: String))
        . trim
        . dropWhile (== ',')
        . trim

-- Tiny helpers ----------------------------------------------------------------

-- | UTF-8 with carriage returns dropped — the same reason
-- "ReleaseMetaSpec" does it: a Windows checkout is CRLF and a Linux one
-- is LF, and both run in CI.
readUtf8 :: FilePath -> IO String
readUtf8 path = filter (/= '\r') . T.unpack . TE.decodeUtf8 <$> BS.readFile path

hasInfix :: String -> String -> Bool
hasInfix = isInfixOf

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOn c rest

dedupe :: [String] -> [String]
dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- | Module name of an @import [qualified] M (…)@ line.
importedModule :: String -> Maybe String
importedModule l = case words (trim l) of
  ("import" : "qualified" : m : _) -> Just (takeWhile (/= '(') m)
  ("import" : m : _) -> Just (takeWhile (/= '(') m)
  _ -> Nothing
