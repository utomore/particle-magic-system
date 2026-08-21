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

-- host-runtime F003 changed the three-way model. Every entry point except
-- the three lifecycle ones is now a C function in @cbits\/pm_gate.c@ that
-- checks the runtime state and then calls the Haskell export, which has
-- been renamed @pm_hs_*@ and is no longer public. So the identity that
-- used to be "header = Haskell exports + the RTS pair" is now two:
--
-- @
-- header ≡ .def EXPORTS ≡ the PM_EXPORT'd symbols in cbits
-- foreign export symbols ≡ pm_hs_ + (header \\ lifecycle)
-- @
--
-- The second one is what makes a future entry point join the gate by
-- existing: add a symbol and forget its wrapper, and this spec is red.

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
  , pmErrInternal
  , pmErrJson
  , pmErrQuota
  , pmErrState
  , pmMaxParticles
  , pmOccupancyDimDefault
  , pmOk
  , pmPlaneSideXY
  , pmPlaneTopXZ
  , shapeCode
  )
import Magic.Interface (BillboardShape (..), BlendMode (..))
import System.IO (IOMode (ReadMode), hClose, hGetContents, hSetEncoding, openFile, utf8)
import Test.Hspec

ffiSource, headerFile, cbitsFile, gateFile, cabalFile, defFile, integrationDoc, bindingFile :: FilePath
ffiSource = "src/ffi/Magic/FFI.hs"
headerFile = "include/particle_magic.h"
cbitsFile = "cbits/pm_init.c"
gateFile = "cbits/pm_gate.c"
cabalFile = "particle-magic.cabal"
defFile = "particle-magic-ffi.def"
integrationDoc = "docs/integration.md"

-- | The C# reference binding. "BindingContractSpec" owns the entry-point
-- and constant reconciliation; host-runtime F004 only needs to know that
-- its prose did not stay behind when the header's did not.
bindingFile = "bindings/csharp/ParticleMagic.cs"

-- | The three entry points the header declares that have no Haskell
-- counterpart at all: starting and stopping the runtime cannot itself be a
-- Haskell call, so they live in @cbits@ (ADR-0011 D5, host-runtime F003).
cbitsEntries :: [String]
cbitsEntries = ["pm_init", "pm_init_ex", "pm_shutdown"]

-- | The prefix the gate gives the Haskell side of each public symbol.
hsPrefix :: String
hsPrefix = "pm_hs_"

-- | @pm_advance@ → @pm_hs_advance@: the public name with its @pm_@
-- replaced, which is what @src\/ffi\/Magic\/FFI.hs@ declares.
gatedName :: String -> String
gatedName name = hsPrefix ++ drop (length ("pm_" :: String)) name

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
        , -- func-spec 0023: the nine-column observation. Add-only again,
          -- and the sharpest example of why the rule is worth keeping —
          -- the six-column entry point above could not carry velocity, so
          -- it did not have to try.
          "pm_observe_ex"
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
        , -- func-spec 0025: the spatial summary's seven, add-only again.
          "pm_spell_bounds"
        , "pm_spell_box"
        , "pm_emitter_count"
        , "pm_emitter_box"
        , "pm_occupancy"
        , "pm_occupancy_mask"
        , "pm_scene_spell_bounds"
        , -- host-runtime F005: the planner the boundary layer already had,
          -- plus the two advances' error-code variants. Add-only for the
          -- fourth time — the void pm_advance and pm_scene_advance keep
          -- their frozen signatures and gain only the promise that an
          -- illegal dt does nothing.
          "pm_plan_steps"
        , "pm_advance_ex"
        , "pm_scene_advance_ex"
        ]

  it "exports through the Windows .def file exactly what the header declares" $ do
    exported <- defExports
    declared <- headerFunctions
    sort exported `shouldBe` sort declared

  it "defines the RTS pair in cbits, where the header says it is" $ do
    source <- stripComments <$> readUtf8 cbitsFile
    mapM_ (\name -> source `shouldSatisfy` defines name) cbitsEntries

  -- host-runtime F003 T6. The gate's own guard, and the reason the lists
  -- below are computed rather than written down: a symbol added by a later
  -- feature (F005's three, say) joins the C ABI by existing, and fails
  -- here until it has a wrapper in cbits/pm_gate.c and a pm_hs_ name of
  -- its own. "Every symbol is gated" is not a property a reviewer can
  -- check by reading one file.
  it "routes every C symbol through the gate and keeps the Haskell exports internal" $ do
    declared <- headerFunctions
    defined <- cbitsPublicSymbols
    symbols <- foreignExportSymbols
    sort defined `shouldBe` sort declared
    sort symbols `shouldBe` sort (map gatedName (filter (`notElem` cbitsEntries) declared))
    -- Nothing public is called pm_hs_*: the gate is the outside.
    filter (hsPrefix `isPrefixOf`) declared `shouldBe` []

  -- host-runtime F003 T1. The configuration struct, its bounds and the
  -- per-platform table a host needs in order to know what its settings
  -- actually did. Sentinel words again: the prose is the only part of the
  -- promise a host can read.
  it "declares PmConfig, its bounds and the per-platform runtime table" $ do
    header <- readUtf8 headerFile
    header `shouldSatisfy` isInfixOf' "typedef struct PmConfig {"
    header `shouldSatisfy` isInfixOf' "Which settings take effect where"
    header `shouldSatisfy` isInfixOf' "PM_GC_NONMOVING"
    header `shouldSatisfy` isInfixOf' "one-way door"
    -- The criterion host-runtime F011 has to implement pm_stats against:
    -- unavailable, never zero.
    header `shouldSatisfy` isInfixOf' "getRTSStatsEnabled"
    header `shouldSatisfy` isInfixOf' "UNAVAILABLE"
    declared <- headerFunctions
    declared `shouldSatisfy` elem "pm_init_ex"
    defined <- headerDefines
    let bounds =
          [ ("PM_GC_DEFAULT", 0)
          , ("PM_GC_NONMOVING", 1)
          , ("PM_STATS_OFF", 0)
          , ("PM_STATS_ON", 1)
          , ("PM_MAX_CAPABILITIES", 256)
          , ("PM_NURSERY_MIN_BYTES", 8192)
          , ("PM_NURSERY_MAX_BYTES", 1073741824)
          ]
    mapM_ (\(name, value) -> lookup name defined `shouldBe` Just value) bounds
    -- Add-only: the generation does not move for any of this.
    lookup "PM_ABI_VERSION" defined `shouldBe` Just 1

  -- host-runtime F003 T8. Without this the two above are untestable: the
  -- test suite has to be built from the same C sources the shipped library
  -- is, or FFIRuntimeSpec would have nothing to call.
  it "builds the foreign library and the test suite from the same C sources" $ do
    let hasSource stanza source = do
          body <- stanzaBody stanza
          any (source `isInfixOf'`) body `shouldBe` True
    mapM_
      (\stanza -> mapM_ (hasSource stanza) ["cbits/pm_init.c", "cbits/pm_gate.c"])
      ["foreign-library particle-magic-ffi", "test-suite spec"]

  -- host-runtime F003 T11. The integration guide is where a host learns
  -- what to pass; sentinel strings keep the section from being edited away
  -- and keep §4.4's lifecycle rules from going back to describing a
  -- process that dies.
  it "documents the runtime contract per platform in the integration guide" $ do
    doc <- readUtf8 integrationDoc
    mapM_
      (\needle -> doc `shouldSatisfy` isInfixOf' needle)
      [ "pm_init_ex"
      , "PmConfig"
      , "PM_ERR_STATE"
      , "PM_STATS_ON"
      , "getRTSStatsEnabled"
      , "8192"
      ]

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

  -- host-runtime F008 T1. The pair above says the two constants may
  -- differ; this says the header stops claiming they do not. "Today it
  -- answers PM_MAX_PARTICLES" was written before func-spec 0012 raised
  -- the core cap and was false from that day on, which is the failure
  -- mode a frozen header invites: the value stayed honest, the prose
  -- around it did not. The sentinel keeps the replacement from being
  -- tidied away, and the last assertion pins the prose to the fact rather
  -- than to a number that would expire again.
  it "says what pm_max_particles actually answers" $ do
    header <- readUtf8 headerFile
    (["Today it answers"], isInfixOf' "Today it answers" header)
      `shouldBe` (["Today it answers"], False)
    header `shouldSatisfy` isInfixOf' "more than PM_MAX_PARTICLES"
    queried <- pm_max_particles
    defined <- headerDefines
    case lookup "PM_MAX_PARTICLES" defined of
      Nothing -> expectationFailure "no PM_MAX_PARTICLES define in the header"
      Just frozen -> fromIntegral queried `shouldSatisfy` (> frozen)

  -- host-runtime F008 T2. The same sentence had a second copy in the
  -- Haskell shell. Fixing one and not the other is how a third copy gets
  -- written next time, so both are pinned here, and the haddock is
  -- required to carry the sentinel in the block that belongs to the
  -- query rather than anywhere in the file.
  it "keeps the Haskell-side haddock in step with the query" $ do
    source <- readUtf8 ffiSource
    (["Today it answers"], isInfixOf' "Today it answers" source)
      `shouldBe` (["Today it answers"], False)
    let haddock = haddockAbove "pm_max_particles :: IO CInt" source
    haddock `shouldSatisfy` not . null
    haddock `shouldSatisfy` isInfixOf' "more than @PM_MAX_PARTICLES@"

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
          , -- host-runtime F001: the firewall's code and the out-of-order
            -- code, minted together so the header, the Haskell mirror and
            -- the C# binding reconcile once instead of twice.
            ("PM_ERR_INTERNAL", pmErrInternal)
          , ("PM_ERR_STATE", pmErrState)
          ]
    mapM_ (\(name, value) -> lookup name header `shouldBe` Just (fromIntegral value)) expected

  -- host-runtime F001 T1. Literals on both sides for the same reason
  -- PM_ERR_QUOTA is pinned: a host's `switch` on the return code compiles
  -- the number in, so either of these moving would silently reclassify
  -- every report already deployed.
  it "pins the internal and state codes at -6 and -7, on both sides" $ do
    pmErrInternal `shouldBe` -6
    pmErrState `shouldBe` -7
    header <- headerDefines
    lookup "PM_ERR_INTERNAL" header `shouldBe` Just (fromIntegral pmErrInternal)
    lookup "PM_ERR_STATE" header `shouldBe` Just (fromIntegral pmErrState)

  -- host-runtime F001 T2. The firewall's promise is only worth what a host
  -- can read, so the header states it; a sentinel word keeps the paragraph
  -- from being edited away, and the two assertions after it say that
  -- stating it cost the frozen contract nothing (no symbol joined the 31,
  -- the generation did not move).
  it "documents the firewall's sentinels and keeps PM_ABI_VERSION at 1" $ do
    header <- readUtf8 headerFile
    header `shouldSatisfy` isInfixOf' "PM_ERR_INTERNAL"
    header `shouldSatisfy` isInfixOf' "Never terminates your process"
    header `shouldSatisfy` isInfixOf' "returns -6.0"
    header `shouldSatisfy` isInfixOf' "pm_occupancy_mask returns 0"
    declared <- headerFunctions
    -- The 31 frozen entry points plus pm_init_ex (host-runtime F003) and
    -- F005's three: the count moves only when a name JOINS, which is what
    -- add-only means.
    length declared `shouldBe` 35
    defined <- headerDefines
    lookup "PM_ABI_VERSION" defined `shouldBe` Just 1

  -- host-runtime F004 T5. The thread model used to be one sentence --
  -- "one handle is owned by one thread" -- which told a host neither what
  -- was allowed nor what a violation would cost. C2.2 replaced it with two
  -- lists, and this is what keeps them there: sentinel phrases from each
  -- half, the retired sentence asserted ABSENT, and the frozen surface
  -- asserted unmoved, because saying all this was meant to cost the C
  -- contract exactly nothing.
  it "documents which operations may run concurrently" $ do
    header <- readUtf8 headerFile
    mapM_
      (\needle -> (needle, isInfixOf' needle header) `shouldBe` (needle, True))
      [ -- The promise itself, and the two lists' anchors.
        "no lost updates"
      , "never starts an OS thread"
      , "different handles"
      , "pm_free"
      , "pm_shutdown"
      ]
    -- The sentence C2.2 retired must not come back.
    (["one handle is owned by one thread"], isInfixOf' "one handle is owned by one thread" header)
      `shouldBe` (["one handle is owned by one thread"], False)
    -- Prose only: no symbol joined, no constant moved.
    declared <- headerFunctions
    length declared `shouldBe` 35
    defined <- headerDefines
    lookup "PM_ABI_VERSION" defined `shouldBe` Just 1

  -- host-runtime F004 T6. The header is normative but a C# host reads the
  -- binding and a Unity host reads the guide, so all three have to say the
  -- same thing. Sentinels on the way in, the retired claims asserted out.
  it "keeps the integration guide and the C# binding in step with the header's thread model" $ do
    doc <- readUtf8 integrationDoc
    (["不丟更新"], isInfixOf' "不丟更新" doc) `shouldBe` (["不丟更新"], True)
    mapM_
      (\needle -> (needle, isInfixOf' needle doc) `shouldBe` (needle, False))
      ["一個 handle 屬於一個執行緒", "庫內無鎖"]
    binding <- readUtf8 bindingFile
    ("one scene per thread", isInfixOf' "one scene per thread" binding)
      `shouldBe` ("one scene per thread", False)

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

  -- Func-spec 0025 S6. Pinned as a literal on both sides for the same
  -- reason PM_ERR_QUOTA is: a host's bit indices into the occupancy mask
  -- are compiled in, so this number moving would silently reinterpret
  -- every mask already deployed rather than fail to build.
  it "pins the default occupancy dimension at 3, on both sides" $ do
    pmOccupancyDimDefault `shouldBe` 3
    header <- headerDefines
    lookup "PM_OCCUPANCY_DIM_DEFAULT" header `shouldBe` Just 3

  it "keeps the whole 3-cubed grid inside one 32-bit mask" $
    -- The reason the fast path can exist at all (func-spec 0025 §2.8);
    -- a larger default would need pm_occupancy's array instead.
    (fromIntegral pmOccupancyDimDefault :: Int) ^ (3 :: Int) `shouldSatisfy` (<= 32)

  it "keeps PM_ABI_VERSION at 1 across the func-spec 0025 additions" $ do
    -- Every entry point this round is new, so no host compiled against an
    -- earlier header is affected: the generation does not move.
    pmAbiVersion `shouldBe` 1
    header <- headerDefines
    lookup "PM_ABI_VERSION" header `shouldBe` Just 1

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

  -- host-runtime F002 / C2.3. The header used to promise undefined
  -- behaviour for a freed or forged handle, which is exactly the promise
  -- ADR-022 D3 withdrew. The prose is the only part of that change a host
  -- can read, so it is pinned here: the sentinel word keeps the new
  -- paragraph from being edited away, and the surrounding assertions state
  -- that documenting handle safety cost the frozen contract nothing.
  it "documents handle safety instead of undefined behaviour" $ do
    header <- readUtf8 headerFile
    header `shouldSatisfy` isInfixOf' "generation-tagged"
    header `shouldSatisfy` isInfixOf' "Handle safety"
    header `shouldSatisfy` (not . isInfixOf' "undefined behaviour")
    -- The neutral answers of the seven symbols with no error channel are
    -- part of the documented promise, not an implementation detail.
    header `shouldSatisfy` isInfixOf' "pm_occupancy_mask returns 0"
    declared <- headerFunctions
    length declared `shouldBe` 35
    defined <- headerDefines
    sort (map fst defined)
      `shouldBe` sort
        [ "PM_ABI_VERSION"
        , -- host-runtime F003: the runtime configuration's vocabulary.
          "PM_GC_DEFAULT"
        , "PM_GC_NONMOVING"
        , "PM_STATS_OFF"
        , "PM_STATS_ON"
        , "PM_MAX_CAPABILITIES"
        , "PM_NURSERY_MIN_BYTES"
        , "PM_NURSERY_MAX_BYTES"
        , "PM_MAX_PARTICLES"
        , "PM_OK"
        , "PM_ERR_JSON"
        , "PM_ERR_BUDGET"
        , "PM_ERR_CAPACITY"
        , "PM_ERR_ARGS"
        , "PM_ERR_QUOTA"
        , "PM_ERR_INTERNAL"
        , "PM_ERR_STATE"
        , "PM_OCCUPANCY_DIM_DEFAULT"
        , "PM_PLANE_SIDE_XY"
        , "PM_PLANE_TOP_XZ"
        , "PM_BLEND_ALPHA"
        , "PM_BLEND_ADDITIVE"
        , "PM_SHAPE_SQUARE"
        , "PM_SHAPE_SOFT_DOT"
        , "PM_SHAPE_RING"
        , "PM_SHAPE_SPARK"
        , "PM_SHAPE_TRAIL"
        , "PM_BATCH_INFO_STRIDE"
        ]
    lookup "PM_ABI_VERSION" defined `shouldBe` Just 1

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
  BillboardTrail -> "PM_SHAPE_TRAIL"

-- Parsers --------------------------------------------------------------------

-- | Haskell names in @foreign export ccall [\"<symbol>\"] <name>@
-- declarations. Since host-runtime F003 every export carries an explicit
-- external name, and the Haskell name is then the word after it; the
-- unquoted form is still accepted so that adding one back does not
-- silently drop it from the audit.
foreignExports :: IO [String]
foreignExports = do
  contents <- readUtf8 ffiSource
  pure [name | l <- lines contents, Just (_, name) <- [exportNames (words (trim l))]]

-- | The C symbols those declarations actually produce — @pm_hs_*@ now,
-- which is what the gate in @cbits\/pm_gate.c@ calls.
foreignExportSymbols :: IO [String]
foreignExportSymbols = do
  contents <- readUtf8 ffiSource
  pure [sym | l <- lines contents, Just (sym, _) <- [exportNames (words (trim l))]]

-- | @(C symbol, Haskell name)@ for one @foreign export ccall@ line.
exportNames :: [String] -> Maybe (String, String)
exportNames ("foreign" : "export" : "ccall" : rest) = case rest of
  (quoted : name : _) | ('"' : sym) <- quoted -> Just (takeWhile (/= '"') sym, name)
  (name : _) -> Just (name, name)
  [] -> Nothing
exportNames _ = Nothing

-- | Public symbols the C sources define, i.e. the ones carrying the
-- library's export attribute. Preprocessor lines are skipped: the
-- @#define PM_EXPORT __declspec(dllexport)@ that introduces the macro
-- mentions it too.
cbitsPublicSymbols :: IO [String]
cbitsPublicSymbols = do
  sources <- mapM readUtf8 [cbitsFile, gateFile]
  pure (nub [name | l <- concatMap lines sources, Just name <- [exported l]])
  where
    exported l
      | "#" `isPrefixOf` trim l = Nothing
      | not ("PM_EXPORT" `isInfixOf'` trim l) = Nothing
      | otherwise = case break (== '(') l of
          (_, "") -> Nothing
          (lhs, _) -> case reverse (takeWhile isIdentChar (reverse (trim lhs))) of
            "" -> Nothing
            name -> Just name

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

-- | The run of haddock comment lines immediately above a declaration
-- (host-runtime F008 T2). Scoped rather than whole-file so that a
-- sentinel present somewhere else entirely cannot stand in for the one
-- that belongs to this function.
haddockAbove :: String -> String -> String
haddockAbove decl contents =
  case break (decl `isPrefixOf`) (lines contents) of
    (_, []) -> ""
    (before, _) -> unlines (reverse (takeWhile (("--" `isPrefixOf`) . trim) (reverse before)))

isInfixOf' :: String -> String -> Bool
isInfixOf' needle haystack = any (needle `isPrefixOf`) (tails' haystack)
  where
    tails' [] = [[]]
    tails' xs@(_ : rest) = xs : tails' rest

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
