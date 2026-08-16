-- | S4 (func-spec 0009 §8): the C contract cannot drift.
--
-- Three texts have to agree — the @foreign export@ list in "Magic.FFI",
-- the declarations in @include\/particle_magic.h@, and the
-- @foreign-library@ stanza in the cabal file — and nothing in the compiler
-- checks that, because a host links against the header while GHC compiles
-- the exports. A drift would surface as a wrong-arity call in someone
-- else's engine. So this spec parses all three (plus @cbits\/pm_init.c@ and
-- the core's own cap) the way @test\/BoundarySpec.hs@ parses the package
-- boundary, and fails in CI instead.
--
-- Func-spec 0011 adds the three projection-era entry points to the same
-- three-way check, and replaces the old @PM_MAX_PARTICLES == budgetCap@
-- pin with the pair of laws that let the core's cap move without
-- disturbing the frozen header (§2). Its header and define parsers are
-- exported so @test\/BindingContractSpec.hs@ can hold the C# binding to
-- the same header without a second copy of them.
module FFIContractSpec
  ( spec

    -- * Header parsers (shared with "BindingContractSpec")
  , headerFunctions
  , headerDefines
  , readUtf8
  ) where

import Control.Exception (evaluate)
import Data.Char (isAlphaNum, isSpace)
import Data.List (isPrefixOf, nub, sort)
import Magic.Compile (budgetCap)
import Magic.FFI
  ( blendCode
  , pm_max_particles
  , pmAbiVersion
  , pmErrArgs
  , pmErrBudget
  , pmErrCapacity
  , pmErrJson
  , pmErrQuota
  , pmMaxParticles
  , pmOk
  , pmPlaneSideXY
  , pmPlaneTopXZ
  , shapeCode
  )
import Magic.Interface (BillboardShape (..), BlendMode (..))
import System.IO (IOMode (ReadMode), hClose, hGetContents, hSetEncoding, openFile, utf8)
import Test.Hspec

ffiSource, headerFile, cbitsFile, cabalFile, defFile :: FilePath
ffiSource = "src/ffi/Magic/FFI.hs"
headerFile = "include/particle_magic.h"
cbitsFile = "cbits/pm_init.c"
cabalFile = "particle-magic.cabal"
defFile = "particle-magic-ffi.def"

-- | The two entry points the header declares that are /not/ Haskell
-- exports: starting and stopping the runtime cannot itself be a Haskell
-- call, so they live in @cbits@ (ADR-0011 D5).
cbitsEntries :: [String]
cbitsEntries = ["pm_init", "pm_shutdown"]

spec :: Spec
spec = describe "C ABI contract (func-spec 0009 §8 S4)" $ do
  it "declares in the header exactly what Haskell exports, plus the RTS pair" $ do
    exports <- foreignExports
    declared <- headerFunctions
    sort declared `shouldBe` sort (nub (exports ++ cbitsEntries))

  it "exports every entry point the spec froze" $ do
    exports <- foreignExports
    sort exports
      `shouldBe` sort
        [ "pm_abi_version"
        , "pm_cast"
        , "pm_cast_ex"
        , "pm_advance"
        , "pm_is_finished"
        , "pm_age"
        , "pm_observe"
        , "pm_free"
        , "pm_max_particles"
        , "pm_project"
        , "pm_depth_order"
        , -- func-spec 0018: the scene layer's ten, add-only. Growing this
          -- list is the whole point of a frozen contract — what it forbids
          -- is a name leaving it or changing shape, not a name joining it.
          "pm_scene_new"
        , "pm_scene_free"
        , "pm_scene_cast"
        , "pm_scene_cast_many"
        , "pm_scene_dismiss"
        , "pm_scene_advance"
        , "pm_scene_observe"
        , "pm_scene_budget"
        , "pm_scene_count"
        , "pm_scene_spells"
        ]

  it "exports through the Windows .def file exactly what the header declares" $ do
    exported <- defExports
    declared <- headerFunctions
    sort exported `shouldBe` sort declared

  it "defines the RTS pair in cbits, where the header says it is" $ do
    source <- stripComments <$> readUtf8 cbitsFile
    mapM_ (\name -> source `shouldSatisfy` defines name) cbitsEntries

  -- The two halves of func-spec 0011 §2. Before it, one assertion tied
  -- PM_MAX_PARTICLES, pmMaxParticles and budgetCap together, which welded
  -- the core's cap onto a frozen header: raising the cap would have
  -- silently changed a constant hosts compiled against. Split in two, the
  -- header keeps its first-generation promise and the /query/ carries the
  -- current truth.
  it "pins PM_MAX_PARTICLES at the first generation's value (frozen header)" $ do
    header <- headerDefines
    lookup "PM_MAX_PARTICLES" header `shouldBe` Just 4096

  it "mirrors the core's cap through the pm_max_particles query" $ do
    queried <- pm_max_particles
    queried `shouldBe` pmMaxParticles
    fromIntegral queried `shouldBe` budgetCap

  it "agrees with Haskell on the ABI version" $ do
    header <- headerDefines
    lookup "PM_ABI_VERSION" header `shouldBe` Just (fromIntegral pmAbiVersion)

  it "agrees with Haskell on every error code" $ do
    header <- headerDefines
    let expected =
          [ ("PM_OK", pmOk)
          , ("PM_ERR_JSON", pmErrJson)
          , ("PM_ERR_BUDGET", pmErrBudget)
          , ("PM_ERR_CAPACITY", pmErrCapacity)
          , ("PM_ERR_ARGS", pmErrArgs)
          , ("PM_ERR_QUOTA", pmErrQuota)
          ]
    mapM_ (\(name, value) -> lookup name header `shouldBe` Just (fromIntegral value)) expected

  -- Func-spec 0018 S1. The value is pinned here as a literal rather than
  -- only mirrored, because a host's `switch` on the return code compiles
  -- the number in: PM_ERR_QUOTA moving would silently reclassify every
  -- refusal already deployed.
  it "pins the scene quota code at -5, on both sides" $ do
    pmErrQuota `shouldBe` -5
    header <- headerDefines
    lookup "PM_ERR_QUOTA" header `shouldBe` Just (-5)

  -- The scene handle is opaque exactly as PmSpell is, and the two
  -- sentences a host most needs about it (size your columns from
  -- global_cap; a scene's spells have no PmSpell*) live in the header's
  -- Scenes section. Same trick as "right-handed" above: a sentinel word
  -- keeps prose from being edited away.
  it "declares the scene handle opaque and documents global_cap" $ do
    header <- readUtf8 headerFile
    header `shouldSatisfy` isInfixOf' "typedef struct PmScene PmScene;"
    header `shouldSatisfy` isInfixOf' "global_cap"

  it "agrees with Haskell on the view-plane selectors" $ do
    header <- headerDefines
    lookup "PM_PLANE_SIDE_XY" header `shouldBe` Just (fromIntegral pmPlaneSideXY)
    lookup "PM_PLANE_TOP_XZ" header `shouldBe` Just (fromIntegral pmPlaneTopXZ)

  -- Two facts that used to live only in docs/integration.md, i.e. only for
  -- readers who found that file. A host reads the header (func-spec 0011
  -- §3.1); getting either wrong is silent — reversed channels, or a
  -- vortex spinning backwards — so the header has to say them, and a
  -- sentinel word each keeps them from being edited away.
  it "documents the colour packing and the coordinate handedness" $ do
    header <- readUtf8 headerFile
    header `shouldSatisfy` isInfixOf' "0xRRGGBBAA"
    header `shouldSatisfy` isInfixOf' "right-handed"

  it "agrees with Haskell on the batch_info enums and stride" $ do
    header <- headerDefines
    lookup "PM_BLEND_ALPHA" header `shouldBe` Just (fromIntegral (blendCode BlendAlpha))
    lookup "PM_BLEND_ADDITIVE" header `shouldBe` Just (fromIntegral (blendCode BlendAdditive))
    lookup "PM_SHAPE_SQUARE" header `shouldBe` Just (fromIntegral (shapeCode BillboardSquare))
    lookup "PM_BATCH_INFO_STRIDE" header `shouldBe` Just 4

  -- Func-spec 0015 S3: the wire code is the constructor's declaration
  -- index, so the mirror is walked over the whole Bounded enum — in both
  -- directions, which is what catches a shape added to the sum without a
  -- define, a define without a constructor, or one slipped into the
  -- middle of the declaration order (the SQUARE = 0 pin breaks first).
  it "mirrors every billboard shape as a PM_SHAPE_* define, both directions" $ do
    header <- headerDefines
    let shapes = [minBound .. maxBound] :: [BillboardShape]
    mapM_
      (\s -> lookup (shapeMacro s) header `shouldBe` Just (fromIntegral (shapeCode s)))
      shapes
    let defined = [name | (name, _) <- header, "PM_SHAPE_" `isPrefixOf` name]
    sort defined `shouldBe` sort (map shapeMacro shapes)

  it "pins the frozen shape and stride values (func-spec 0015 §0.1)" $ do
    shapeCode BillboardSquare `shouldBe` 0
    header <- headerDefines
    -- Sentinel: shapes gaining parameters would need a wider stride; the
    -- stride is frozen, which is exactly why they never do (ADR-0013).
    lookup "PM_BATCH_INFO_STRIDE" header `shouldBe` Just 4

  it "keeps the foreign library on the shell-layer dependency whitelist" $ do
    deps <- stanzaField "foreign-library particle-magic-ffi" "build-depends"
    let names = map depName (splitOn ',' deps)
    names `shouldSatisfy` all (`elem` ["base", "magic-boundary", "bytestring", "vector"])
    names `shouldSatisfy` elem "magic-boundary"
    names `shouldSatisfy` notElem "magic-core"

  it "builds the foreign library from the sources this spec checks" $ do
    body <- stanzaBody "foreign-library particle-magic-ffi"
    let has field value = any (\l -> (field ++ ":") `isPrefixOf` trim l && value `isInfixOf'` l) body
    has "hs-source-dirs" "src/ffi" `shouldBe` True
    has "other-modules" "Magic.FFI" `shouldBe` True
    has "c-sources" "cbits/pm_init.c" `shouldBe` True
    has "include-dirs" "include" `shouldBe` True
    has "type" "native-shared" `shouldBe` True

  it "lets the test-suite reach the FFI module in process" $ do
    dirs <- stanzaField "test-suite spec" "hs-source-dirs"
    map trim (splitOn ',' dirs) `shouldSatisfy` elem "src/ffi"

-- | Constructor → header macro, stated as a table on purpose: this file
-- is the header's side of the mirror, so it must not be derived from the
-- same 'Enum' instance it checks.
shapeMacro :: BillboardShape -> String
shapeMacro shape = case shape of
  BillboardSquare -> "PM_SHAPE_SQUARE"
  BillboardSoftDot -> "PM_SHAPE_SOFT_DOT"
  BillboardRing -> "PM_SHAPE_RING"
  BillboardSpark -> "PM_SHAPE_SPARK"

-- Parsers --------------------------------------------------------------------

-- | Names in @foreign export ccall <name>@ declarations.
foreignExports :: IO [String]
foreignExports = do
  contents <- readUtf8 ffiSource
  pure [name | l <- lines contents, Just name <- [exportName (words (trim l))]]
  where
    exportName ("foreign" : "export" : "ccall" : name : _) = Just name
    exportName _ = Nothing

-- | Function names declared in the header: the identifier immediately
-- before the parameter list of each declaration. Comments and
-- preprocessor lines are dropped first — @#define PM_ERR_JSON (-1)@ has a
-- parenthesis too, and is not a declaration.
headerFunctions :: IO [String]
headerFunctions = do
  contents <- stripComments <$> readUtf8 headerFile
  let code = unwords [trim l | l <- lines contents, not ("#" `isPrefixOf` trim l)]
  pure [name | chunk <- splitOn ';' code, Just name <- [declName chunk]]
  where
    declName chunk =
      let (returnAndName, rest) = break (== '(') (unwords (words chunk))
       in if null rest || "typedef" `elem` words chunk
            then Nothing
            else case reverse (takeWhile isIdentChar (reverse (trim returnAndName))) of
              "" -> Nothing
              name -> Just name

-- | Symbol names listed under @EXPORTS@ in the module definition file.
-- Windows exports nothing from the shared library without them, so a name
-- missing here is a link error inside someone else's engine — exactly the
-- kind of drift this spec exists to catch.
defExports :: IO [String]
defExports = do
  contents <- readUtf8 defFile
  pure
    [ trim l
    | l <- drop 1 (dropWhile (\l -> trim l /= "EXPORTS") (lines contents))
    , let t = trim l
    , not (null t)
    , not (";" `isPrefixOf` t)
    ]

-- | @#define NAME VALUE@ pairs whose value is an integer literal, with the
-- header's @(-1)@ style unwrapped.
headerDefines :: IO [(String, Int)]
headerDefines = do
  contents <- readUtf8 headerFile
  pure [pair | l <- lines (stripComments contents), Just pair <- [define (words l)]]
  where
    define ("#define" : name : value : _) = (,) name <$> readInt value
    define _ = Nothing
    readInt raw = case reads (unwrap raw) of
      [(n, "")] -> Just n
      _ -> Nothing
    unwrap ('(' : rest) = takeWhile (/= ')') rest
    unwrap other = other

-- | Does this C source define the named function (@name(@ at the start of
-- a line, possibly behind an export attribute)?
defines :: String -> String -> Bool
defines name source =
  any (\l -> (name ++ "(") `isInfixOf'` l && not ("//" `isPrefixOf` trim l)) (lines source)

-- | Everything outside @/* … */@ spans. Line comments do not appear in
-- this header, and would be harmless if they did.
stripComments :: String -> String
stripComments = outside
  where
    outside ('/' : '*' : rest) = inside rest
    outside (c : rest) = c : outside rest
    outside [] = []
    inside ('*' : '/' : rest) = ' ' : outside rest
    inside (_ : rest) = inside rest
    inside [] = []

isIdentChar :: Char -> Bool
isIdentChar c = isAlphaNum c || c == '_'

-- | Read a source file as UTF-8 regardless of the machine's locale — the
-- sources this spec parses carry the project's usual typography, and a
-- Windows codepage would choke on the first em dash.
readUtf8 :: FilePath -> IO String
readUtf8 path = do
  h <- openFile path ReadMode
  hSetEncoding h utf8
  contents <- hGetContents h
  _ <- evaluate (length contents)
  hClose h
  pure contents

-- Cabal stanza reading (same shape as test/BoundarySpec.hs, kept separate
-- so that spec's frozen assertions stay untouched) ---------------------------

stanzaBody :: String -> IO [String]
stanzaBody header = do
  contents <- readUtf8 cabalFile
  case stanzaLines header (lines contents) of
    Nothing -> do
      expectationFailure ("stanza not found: " ++ header)
      pure []
    Just body -> pure body

-- | The (possibly continued) value of a field inside a stanza.
stanzaField :: String -> String -> IO String
stanzaField header field = do
  body <- stanzaBody header
  case break (\l -> (field ++ ":") `isPrefixOf` trim l) body of
    (_, []) -> do
      expectationFailure ("field not found: " ++ field ++ " in " ++ header)
      pure ""
    (_, fieldLine : rest) ->
      let firstChunk = drop (length field + 1) (trim fieldLine)
          continuation = takeWhile isContinuation rest
          isContinuation l =
            let t = trim l
             in not (null t) && ("," `isPrefixOf` t || not (':' `elem` takeWhile (/= ' ') t))
       in pure (unwords (firstChunk : map trim continuation))

stanzaLines :: String -> [String] -> Maybe [String]
stanzaLines header ls =
  case dropWhile (\l -> trim l /= header || indented l) ls of
    [] -> Nothing
    (_ : rest) -> Just (takeWhile (\l -> indented l || null (trim l)) rest)
  where
    indented l = case l of
      (c : _) -> isSpace c
      [] -> False

-- | Sublibrary deps are written @particle-magic:magic-boundary@; compare
-- by the part after the colon, and drop any version constraint.
depName :: String -> String
depName d =
  let bare = takeWhile (\c -> isIdentChar c || c == '-' || c == ':') (trim d)
   in case break (== ':') bare of
        (n, "") -> n
        (_, ':' : n) -> n
        (n, _) -> n

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (chunk, []) -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn c rest

isInfixOf' :: String -> String -> Bool
isInfixOf' needle haystack = any (needle `isPrefixOf`) (tails' haystack)
  where
    tails' [] = [[]]
    tails' xs@(_ : rest) = xs : tails' rest

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
