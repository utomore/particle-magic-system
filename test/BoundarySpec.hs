-- | T1 (func-spec 0001 §8): the architecture boundary is enforced by the
-- cabal package structure. This spec parses @particle-magic.cabal@ and
-- asserts:
--
--   * @magic-core@'s build-depends ⊆ {base, vector, deepseq, parallel}
--   * the executable's build-depends do NOT include @magic-core@
--   * @magic-boundary@'s build-depends ⊆ core ∪ {aeson, bytestring, text,
--     megaparsec, parser-combinators} (the last two added by func-spec 0003)
--
-- Func-spec 0022 S5 widens the core whitelist for the first time since
-- func-spec 0001, by one entry: @parallel@ (ADR-0017). That is a small
-- change to a line and a large one to a principle, so this round also adds
-- the check that says /why/ it was allowed — "Control.Parallel.Strategies"
-- is a pure API, and the core and boundary layers still have no @IO@ and no
-- @Eff@ anywhere in them (ADR-0007). A dependency that made the core
-- effectful would have to be refused no matter how fast it was; this test
-- is the difference between having that rule and merely stating it.
module BoundarySpec (spec) where

import Data.Char (isAlphaNum, isSpace)
import Data.List (isPrefixOf, sort)
import System.Directory (doesDirectoryExist, listDirectory)
import System.IO (IOMode (ReadMode), hGetContents, hSetEncoding, openFile, utf8)
import Test.Hspec

spec :: Spec
spec = describe "cabal package boundary (func-spec 0001 §3)" $ do
  it "magic-core build-depends is within the pure whitelist {base, vector, deepseq, parallel}" $ do
    deps <- stanzaDeps "library magic-core"
    deps `shouldSatisfy` all (`elem` coreWhitelist)
    deps `shouldSatisfy` ("base" `elem`)

  -- The widening is deliberate and exactly one entry wide: a later round
  -- that wants a second one has to change this line, and changing it means
  -- writing the ADR that justifies it.
  it "and the whitelist has grown by exactly 'parallel' (func-spec 0022, ADR-0017)" $ do
    deps <- stanzaDeps "library magic-core"
    sort deps `shouldBe` sort coreWhitelist

  -- ADR-0007, restated as a property of the source rather than of the
  -- dependency list: 'parallel' was admissible precisely because it does
  -- not put an effect in a core signature. If that ever stops being true,
  -- this fails before anyone has to notice it in review.
  it "core and boundary carry no IO and no Eff anywhere in their source (ADR-0007)" $ do
    offenders <- effectfulModules ["src/core", "src/boundary"]
    offenders `shouldBe` []

  -- A check that can only pass is not a check. The shell layers are where
  -- the effects are supposed to be, so the same scan must find them there.
  it "and the scan is not vacuous: it finds the effects the shell layers do have" $ do
    shell <- effectfulModules ["app", "src/ffi"]
    map snd shell `shouldSatisfy` ("IO" `elem`)
    map snd shell `shouldSatisfy` ("Eff" `elem`)

  it "executable does not depend on magic-core (shell cannot import core internals)" $ do
    deps <- stanzaDeps "executable particle-magic"
    deps `shouldSatisfy` all (\d -> depName d /= "magic-core")
    deps `shouldSatisfy` any (\d -> depName d == "magic-boundary")

  -- func-spec 0014 S1: the authoring CLI is the boundary layer's third
  -- consumer, and the discipline that makes it worth having is exactly
  -- the executable's. It may not reach into the core, and it may not
  -- pull in a renderer -- a tool that could open a window would no
  -- longer be evidence that the library is complete without one.
  it "magic-validate does not depend on magic-core, and does not link a renderer" $ do
    deps <- stanzaDeps "executable magic-validate"
    deps `shouldSatisfy` all (\d -> depName d /= "magic-core")
    deps `shouldSatisfy` any (\d -> depName d == "magic-boundary")
    deps `shouldSatisfy` all (\d -> depName d `notElem` ["h-raylib", "effectful"])

  it "magic-validate stays inside the tool whitelist {base, magic-boundary, aeson, bytestring, vector, directory}" $ do
    deps <- stanzaDeps "executable magic-validate"
    let allowed = ["base", "aeson", "bytestring", "vector", "directory"]
    deps `shouldSatisfy` all (\d -> depName d `elem` allowed || depName d == "magic-boundary")

  it "magic-boundary only adds serialization + parsing deps {aeson, bytestring, text, megaparsec, parser-combinators} over core" $ do
    deps <- stanzaDeps "library magic-boundary"
    let allowed = ["base", "vector", "deepseq", "aeson", "bytestring", "text", "megaparsec", "parser-combinators"]
    deps `shouldSatisfy` all (\d -> depName d `elem` allowed || depName d == "magic-core")
    deps `shouldSatisfy` any (\d -> depName d == "magic-core")

-- | The core's dependency whitelist, in one place so the two assertions
-- above cannot drift apart.
coreWhitelist :: [String]
coreWhitelist = ["base", "vector", "deepseq", "parallel"]

-- | @(module path, offending token)@ for every source file under the given
-- roots that mentions @IO@ or @Eff@ in code.
--
-- Comments are stripped first, since the honest ones say things like "no IO
-- in the core" and a check that tripped over its own documentation would be
-- worse than none. Qualified names are compared whole, so @Data.IORef@ and
-- @GHC.IO.Handle@ would be caught while an ordinary identifier ending in
-- those letters is not.
effectfulModules :: [FilePath] -> IO [(FilePath, String)]
effectfulModules roots = do
  files <- concat <$> mapM haskellFiles roots
  concat <$> mapM check (sort files)
  where
    check path = do
      src <- readUtf8 path
      pure [(path, tok) | tok <- tokensOf (stripComments src), tok `elem` ["IO", "Eff"]]

-- | The sources are UTF-8 (they are full of §, → and 魔法陣); 'readFile'
-- would decode them in the machine's locale and fall over on Windows.
readUtf8 :: FilePath -> IO String
readUtf8 path = do
  h <- openFile path ReadMode
  hSetEncoding h utf8
  contents <- hGetContents h
  length contents `seq` pure contents

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles root = do
  isDir <- doesDirectoryExist root
  if not isDir
    then pure [root | ".hs" `isSuffixOfStr` root]
    else do
      entries <- listDirectory root
      concat <$> mapM (haskellFiles . ((root ++ "/") ++)) entries

isSuffixOfStr :: String -> String -> Bool
isSuffixOfStr suffix s = length s >= length suffix && drop (length s - length suffix) s == suffix

-- | Drop @--@ line comments and @{- … -}@ blocks (pragmas included: they
-- open with @{-@ too, and none of them names an effect).
stripComments :: String -> String
stripComments = outside
  where
    outside s = case s of
      [] -> []
      ('-' : '-' : rest) -> ' ' : outside (dropWhile (/= '\n') rest)
      ('{' : '-' : rest) -> ' ' : block (1 :: Int) rest
      (c : rest) -> c : outside rest

    block _ [] = []
    block n ('{' : '-' : rest) = block (n + 1) rest
    block n ('-' : '}' : rest)
      | n <= 1 = ' ' : outside rest
      | otherwise = block (n - 1) rest
    block n ('\n' : rest) = '\n' : block n rest
    block n (_ : rest) = block n rest

-- | Split into Haskell name tokens: alphanumerics, @_@, @'@ and the @.@ of
-- a qualified name.
tokensOf :: String -> [String]
tokensOf s = case dropWhile (not . nameChar) s of
  [] -> []
  rest -> let (tok, more) = span nameChar rest in tok : tokensOf more
  where
    nameChar c = isAlphaNum c || c `elem` "_'."

-- | Sublibrary deps are written @particle-magic:magic-core@; compare by the
-- part after the colon.
depName :: String -> String
depName d = case break (== ':') d of
  (n, "") -> n
  (_, ':' : n) -> n
  (n, _) -> n

stanzaDeps :: String -> IO [String]
stanzaDeps header = do
  contents <- readFile "particle-magic.cabal"
  let ls = lines contents
  case stanzaLines header ls of
    Nothing -> do
      expectationFailure ("stanza not found: " ++ header)
      pure []
    Just body -> pure (buildDepends body)

-- | Lines belonging to the stanza with the given header (indented block
-- following a column-0 header line).
stanzaLines :: String -> [String] -> Maybe [String]
stanzaLines header ls =
  case dropWhile (\l -> trim l /= header || indented l) ls of
    [] -> Nothing
    (_ : rest) -> Just (takeWhile (\l -> indented l || null (trim l)) rest)
  where
    indented l = case l of
      (c : _) -> isSpace c
      [] -> False

-- | Extract dependency names from the (possibly multi-line) build-depends
-- field inside a stanza body.
buildDepends :: [String] -> [String]
buildDepends body =
  case break (\l -> "build-depends:" `isPrefixOf` trim l) body of
    (_, []) -> []
    (_, fieldLine : rest) ->
      let firstChunk = drop (length "build-depends:") (trim fieldLine)
          continuation = takeWhile (not . isFieldLine) rest
          isFieldLine l =
            let t = trim l
             in not (null t)
                  && ',' `notElem` takeWhile (/= ':') t
                  && ':' `elem` t
                  && not ("," `isPrefixOf` t)
          chunks = firstChunk : map trim continuation
          entries = splitOn ',' (unwords chunks)
       in filter (not . null) (map (takeWhile (not . isDepEnd) . trim) entries)
  where
    isDepEnd c = isSpace c || c `elem` "^><=&|"

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (chunk, []) -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn c rest

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
