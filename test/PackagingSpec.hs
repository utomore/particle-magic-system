{-# LANGUAGE OverloadedStrings #-}

-- | host-runtime F007: the shape of a release drop.
--
-- Nothing here runs the library. What it guards is the other half of
-- shipping: that the list of files a host receives is written down once,
-- machine-readably, and that everything else which claims to describe
-- that list still agrees with it. @packaging\/artifacts.json@ is the
-- authority; @docs\/release.md@ §6 restates it for people; the two
-- packaging scripts write the version file the manifest declares. This
-- spec asserts all three agree, in both directions, so that dropping a
-- file from a platform -- or adding one and forgetting to say so -- turns
-- @cabal test@ red rather than turning up in someone's engine.
--
-- Deliberately static: it reads files, it does not build or pack. The
-- measurements the manifest is making claims about are made elsewhere and
-- recorded in the feature document --- @pack.sh --verify@ in a clean WSL
-- environment for the Linux closure, @smoke-msvc.ps1@ for the MSVC import
-- library. A guard test's job is to keep those results from silently
-- expiring, not to repeat them on every run.
module PackagingSpec (spec) where

import Data.Aeson (FromJSON (parseJSON), eitherDecodeStrict', withObject, (.:))
import qualified Data.ByteString as BS
import Data.Char (isDigit, isSpace)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

manifestPath, releaseDocPath, integrationDocPath :: FilePath
manifestPath = "packaging/artifacts.json"
releaseDocPath = "docs/release.md"
integrationDocPath = "docs/integration.md"

cabalPath, headerPath, defPath :: FilePath
cabalPath = "particle-magic.cabal"
headerPath = "include/particle_magic.h"
defPath = "particle-magic-ffi.def"

packShPath, packPs1Path, smokePs1Path :: FilePath
packShPath = "packaging/pack.sh"
packPs1Path = "packaging/pack.ps1"
smokePs1Path = "packaging/smoke-msvc.ps1"

-- | UTF-8 bytes with carriage returns dropped: this tree is CRLF on
-- Windows and LF on Linux, and a line-comparing spec would otherwise
-- disagree with itself across the two CI runners. Same note as
-- "ReleaseDocSpec".
readUtf8 :: FilePath -> IO String
readUtf8 path = filter (/= '\r') . T.unpack . TE.decodeUtf8 <$> BS.readFile path

-- ---------------------------------------------------------------- manifest

data ArtifactFile = ArtifactFile
  { afName :: String
  , afRole :: String
  }
  deriving (Eq, Show)

data Platform = Platform
  { pfId :: String
  , pfVerified :: Bool
  , pfFiles :: [ArtifactFile]
  }
  deriving (Eq, Show)

data VersionFile = VersionFile
  { vfName :: String
  , vfFields :: [String]
  }
  deriving (Eq, Show)

data Manifest = Manifest
  { mVersionFile :: VersionFile
  , mPlatforms :: [Platform]
  }
  deriving (Eq, Show)

instance FromJSON ArtifactFile where
  parseJSON = withObject "ArtifactFile" $ \o ->
    ArtifactFile <$> o .: "name" <*> o .: "role"

instance FromJSON Platform where
  parseJSON = withObject "Platform" $ \o ->
    Platform <$> o .: "id" <*> o .: "verified" <*> o .: "files"

instance FromJSON VersionFile where
  parseJSON = withObject "VersionFile" $ \o ->
    VersionFile <$> o .: "name" <*> o .: "fields"

instance FromJSON Manifest where
  parseJSON = withObject "Manifest" $ \o ->
    Manifest <$> o .: "version-file" <*> o .: "platforms"

loadManifest :: IO Manifest
loadManifest = do
  bytes <- BS.readFile manifestPath
  case eitherDecodeStrict' bytes of
    Left err -> fail (manifestPath ++ ": " ++ err)
    Right m -> pure m

-- | The closed role vocabulary. Written here as well as used in the
-- manifest so that the two pin each other: a seventh role has to be
-- argued for in both places.
roleVocabulary :: [String]
roleVocabulary =
  [ "runtime"
  , "runtime-closure"
  , "import-lib-mingw"
  , "import-lib-msvc"
  , "header"
  , "version"
  ]

expectedPlatformIds :: [String]
expectedPlatformIds = sort ["windows-x86_64", "linux-x86_64", "macos-x86_64", "macos-arm64"]

manifestFileNames :: Manifest -> [String]
manifestFileNames = sort . nub . concatMap (map afName . pfFiles) . mPlatforms

-- ------------------------------------------------------------- doc scanning

-- | The contents of a numbered top-level section of a markdown document,
-- from its own heading up to the next one.
section :: String -> String -> [String]
section marker doc =
  case dropWhile (not . (marker `isPrefixOf`)) (lines doc) of
    [] -> []
    (h : rest) -> h : takeWhile (not . isTopHeading) rest
  where
    isTopHeading l = "## " `isPrefixOf` l

-- | Every backtick-delimited span in a chunk of markdown.
backtickSpans :: [String] -> [String]
backtickSpans = concatMap spansOf
  where
    spansOf l = case dropWhile (/= '`') l of
      ('`' : rest) ->
        let (tok, more) = span (/= '`') rest
         in tok : case more of
              ('`' : r) -> spansOf r
              _ -> []
      _ -> []

-- | Which of those spans name a shipped file.
--
-- Suffix match against the extensions the manifest actually uses, plus
-- the one glob (@*.so*@, the Linux closure). A span is excluded if it
-- contains a slash (those are paths to things in this repository, not
-- files in a drop) or begins with a dot (prose about a file /type/, as in
-- "the .so is linked with"). Anything else with a shipped extension has
-- to be in the manifest, which is the direction that catches a document
-- promising a file nobody packs.
artifactNames :: [String] -> [String]
artifactNames = sort . nub . filter isArtifact . backtickSpans
  where
    exts = [".dll", ".dll.a", ".lib", ".h", ".json", ".so", ".dylib"]
    isArtifact tok
      | tok == "*.so*" = True
      | '/' `elem` tok = False
      | "." `isPrefixOf` tok = False
      | otherwise = any (`isSuffixOf` tok) exts

-- | The @"key":@ occurrences between the two markers the packaging
-- scripts wrap their version-file literal in. Scanning the literal itself
-- rather than a comment is the point: what the script writes is what gets
-- compared, so the two cannot drift apart within one file either.
versionFieldsBetweenMarkers :: String -> [String]
versionFieldsBetweenMarkers contents =
  sort . nub . concatMap quotedKeys $
    takeWhile (not . ("pm-version.json END" `isInfixOf`)) $
      drop 1 $
        dropWhile (not . ("pm-version.json BEGIN" `isInfixOf`)) (lines contents)

quotedKeys :: String -> [String]
quotedKeys ('"' : rest) =
  let (tok, more) = span (/= '"') rest
   in case more of
        ('"' : ':' : r) -> tok : quotedKeys r
        ('"' : r) -> quotedKeys r
        _ -> []
quotedKeys (_ : cs) = quotedKeys cs
quotedKeys [] = []

-- | Exported symbols listed in the Windows module definition file.
defExports :: String -> [String]
defExports contents =
  [ t
  | l <- drop 1 (dropWhile (not . ("EXPORTS" `isPrefixOf`)) (map trim (lines contents)))
  , let t = trim l
  , not (null t)
  , not (";" `isPrefixOf` t)
  ]

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

fieldValue :: String -> String -> Maybe String
fieldValue key contents =
  case [trim (drop (length key + 1) (trim l)) | l <- lines contents, (key ++ ":") `isPrefixOf` trim l] of
    (v : _) -> Just v
    [] -> Nothing

-- ------------------------------------------------------------------- spec

spec :: Spec
spec = describe "packaging content (host-runtime F007, design.md C4)" $ do
  -- T1
  it "has a manifest that parses, covers four platforms and uses only the closed role vocabulary" $ do
    m <- loadManifest
    sort (map pfId (mPlatforms m)) `shouldBe` expectedPlatformIds

    -- Vacuity guard: agreement between empty lists is not agreement.
    length (manifestFileNames m) `shouldSatisfy` (>= 6)
    mapM_
      (\p -> (pfId p, length (pfFiles p) >= 3) `shouldBe` (pfId p, True))
      (mPlatforms m)

    let roles = nub (sort (concatMap (map afRole . pfFiles) (mPlatforms m)))
        strays = filter (`notElem` roleVocabulary) roles
    strays `shouldBe` []

    -- Every platform ships something to run, a header to compile against
    -- and a version file to identify it by.
    mapM_
      ( \p ->
          let rs = map afRole (pfFiles p)
           in (pfId p, sort (filter (`elem` ["runtime", "header", "version"]) rs))
                `shouldBe` (pfId p, ["header", "runtime", "version"])
      )
      (mPlatforms m)

    -- Windows is the one platform with two link-time paths into it.
    case filter ((== "windows-x86_64") . pfId) (mPlatforms m) of
      [win] -> do
        let rs = map afRole (pfFiles win)
        rs `shouldSatisfy` elem "import-lib-mingw"
        rs `shouldSatisfy` elem "import-lib-msvc"
      _ -> expectationFailure "no windows-x86_64 platform in the manifest"

  -- T2
  it "says the same thing in docs/release.md as in the manifest, both ways" $ do
    m <- loadManifest
    releaseDoc <- readUtf8 releaseDocPath
    let sec = section "## 6." releaseDoc
    sec `shouldSatisfy` (not . null)
    artifactNames sec `shouldBe` manifestFileNames m

    -- The honesty field has to survive the trip into prose: a platform
    -- the manifest calls unverified must be labelled as such where a
    -- human reads it.
    let unverified = map pfId (filter (not . pfVerified) (mPlatforms m))
        secText = unlines sec
    unverified `shouldSatisfy` (not . null)
    mapM_ (\i -> (i, i `isInfixOf` secText) `shouldBe` (i, True)) unverified
    secText `shouldSatisfy` ("未驗證" `isInfixOf`)

  -- T3
  it "has one version-file field set, agreed on by the manifest and both packaging scripts" $ do
    m <- loadManifest
    packSh <- readUtf8 packShPath
    packPs1 <- readUtf8 packPs1Path

    vfName (mVersionFile m) `shouldBe` "pm-version.json"
    let declared = sort (nub (vfFields (mVersionFile m)))
    declared `shouldSatisfy` (not . null)
    versionFieldsBetweenMarkers packSh `shouldBe` declared
    versionFieldsBetweenMarkers packPs1 `shouldBe` declared

    -- Two of those fields are copies of a constant that lives elsewhere.
    -- Assert the sources are still where the scripts look, and still
    -- well formed, so a moved constant fails here rather than producing
    -- a drop that lies about itself.
    cabalFile <- readUtf8 cabalPath
    header <- readUtf8 headerPath
    case fieldValue "version" cabalFile of
      Nothing -> expectationFailure "no version: field in the cabal file"
      Just v -> do
        v `shouldSatisfy` all (\c -> isDigit c || c == '.')
        length (filter (== '.') v) `shouldBe` 3
    let abiDefine = "#define PM_ABI_VERSION" :: String
        abis =
          [ trim (drop (length abiDefine) l)
          | l <- lines header
          , abiDefine `isPrefixOf` l
          ]
    case abis of
      [abi] -> do
        abi `shouldSatisfy` (not . null)
        abi `shouldSatisfy` all isDigit
      other -> expectationFailure ("expected one PM_ABI_VERSION define, got " ++ show other)

    mapM_
      (\s -> s `shouldSatisfy` ("particle-magic.cabal" `isInfixOf`))
      [packSh, packPs1]
    mapM_
      (\s -> s `shouldSatisfy` ("particle_magic.h" `isInfixOf`))
      [packSh, packPs1]

  -- T4
  it "makes the Windows import library from the export list the DLL was linked with" $ do
    packPs1 <- readUtf8 packPs1Path
    defFile <- readUtf8 defPath

    -- The .def is the input, not a second copy of the truth, and both
    -- producers are named so a machine without MSVC still has a path.
    packPs1 `shouldSatisfy` ("particle-magic-ffi.def" `isInfixOf`)
    packPs1 `shouldSatisfy` ("lib.exe" `isInfixOf`)
    packPs1 `shouldSatisfy` ("llvm-dlltool" `isInfixOf`)

    -- This feature does not touch a symbol. FFIContractSpec owns the
    -- header/.def reconciliation; all that is asserted here is that the
    -- list packaging feeds to lib.exe is the one that was there.
    let syms = defExports defFile
    length syms `shouldBe` 35
    syms `shouldBe` nub syms
    mapM_ (\s -> (s, "pm_" `isPrefixOf` s) `shouldBe` (s, True)) syms

  -- T5
  it "ships the MSVC smoke script and names it where a releaser will look" $ do
    smoke <- readUtf8 smokePs1Path
    releaseDoc <- readUtf8 releaseDocPath
    let secText = unlines (section "## 6." releaseDoc)

    mapM_
      (\p -> (p, p `isInfixOf` secText) `shouldBe` (p, True))
      [packShPath, packPs1Path, smokePs1Path]

    -- It has to build with MSVC and check what it linked, or it is not
    -- evidence of anything.
    smoke `shouldSatisfy` ("cl.exe" `isInfixOf`)
    smoke `shouldSatisfy` ("dumpbin" `isInfixOf`)
    smoke `shouldSatisfy` ("particle-magic-ffi.lib" `isInfixOf`)
    smoke `shouldSatisfy` ("main.c" `isInfixOf`)

  -- T7
  it "writes macOS build settings and admits they are unverified" $ do
    m <- loadManifest
    cabalFile <- readUtf8 cabalPath
    packSh <- readUtf8 packShPath

    cabalFile `shouldSatisfy` ("if os(darwin)" `isInfixOf`)
    cabalFile `shouldSatisfy` ("-install_name" `isInfixOf`)
    cabalFile `shouldSatisfy` ("@rpath/libparticle-magic-ffi.dylib" `isInfixOf`)

    -- The Linux branch's two mechanisms, and the macOS branch's, are in
    -- the script rather than only in prose.
    packSh `shouldSatisfy` ("$ORIGIN" `isInfixOf`)
    packSh `shouldSatisfy` ("ldd" `isInfixOf`)
    packSh `shouldSatisfy` (".dylib" `isInfixOf`)
    packSh `shouldSatisfy` ("lipo" `isInfixOf`)

    let macos = filter (("macos-" `isPrefixOf`) . pfId) (mPlatforms m)
    map pfId macos `shouldSatisfy` ((== 2) . length)
    map pfVerified macos `shouldBe` [False, False]

    -- ... and the platforms that were measured are not quietly dragged
    -- down with them.
    let others = filter (not . ("macos-" `isPrefixOf`) . pfId) (mPlatforms m)
    map pfVerified others `shouldBe` [True, True]

  -- T8
  it "tells a C host how to link with MSVC and how @rpath works on macOS" $ do
    doc <- readUtf8 integrationDocPath
    cabalFile <- readUtf8 cabalPath

    let headings = [l | l <- lines doc, "### " `isPrefixOf` l]
        msvcHeads = [h | h <- headings, "MSVC" `isInfixOf` h]
        rpathHeads = [h | h <- headings, "@rpath" `isInfixOf` h]
    msvcHeads `shouldSatisfy` ((>= 1) . length)
    rpathHeads `shouldSatisfy` ((>= 1) . length)

    let msvcSection =
          takeWhile (\l -> not ("### " `isPrefixOf` l) && not ("## " `isPrefixOf` l)) $
            drop 1 $
              dropWhile (not . (`elem` msvcHeads)) (lines doc)
        msvcText = unlines msvcSection
    msvcText `shouldSatisfy` ("lib.exe" `isInfixOf`)
    msvcText `shouldSatisfy` ("particle-magic-ffi.lib" `isInfixOf`)

    let rpathSection =
          takeWhile (\l -> not ("### " `isPrefixOf` l) && not ("## " `isPrefixOf` l)) $
            drop 1 $
              dropWhile (not . (`elem` rpathHeads)) (lines doc)
        rpathText = unlines rpathSection
    rpathText `shouldSatisfy` ("install_name" `isInfixOf`)
    rpathText `shouldSatisfy` ("lipo" `isInfixOf`)
    -- macOS is unverified; the guide has to say so where it is read, in
    -- the manifest's own words so the two cannot drift into disagreeing.
    rpathText `shouldSatisfy` ("verified: false" `isInfixOf`)
    rpathText `shouldSatisfy` ("驗證" `isInfixOf`)

    -- And this module is compiled: hspec-discover finds it, but cabal
    -- still has to be told, and a spec cabal does not know about is a
    -- spec that silently stops running.
    let listed = [t | l <- lines cabalFile, let t = trim l, t == "PackagingSpec" || t == ", PackagingSpec"]
    listed `shouldSatisfy` ((== 1) . length)
