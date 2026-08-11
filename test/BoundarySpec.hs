-- | T1 (func-spec 0001 §8): the architecture boundary is enforced by the
-- cabal package structure. This spec parses @particle-magic.cabal@ and
-- asserts:
--
--   * @magic-core@'s build-depends ⊆ {base, vector, deepseq}
--   * the executable's build-depends do NOT include @magic-core@
--   * @magic-boundary@'s build-depends ⊆ core ∪ {aeson, bytestring, text}
module BoundarySpec (spec) where

import Data.Char (isSpace)
import Data.List (isPrefixOf)
import Test.Hspec

spec :: Spec
spec = describe "cabal package boundary (func-spec 0001 §3)" $ do
  it "magic-core build-depends is within the pure whitelist {base, vector, deepseq}" $ do
    deps <- stanzaDeps "library magic-core"
    deps `shouldSatisfy` all (`elem` ["base", "vector", "deepseq"])
    deps `shouldSatisfy` ("base" `elem`)

  it "executable does not depend on magic-core (shell cannot import core internals)" $ do
    deps <- stanzaDeps "executable particle-magic"
    deps `shouldSatisfy` all (\d -> depName d /= "magic-core")
    deps `shouldSatisfy` any (\d -> depName d == "magic-boundary")

  it "magic-boundary only adds serialization deps {aeson, bytestring, text} over core" $ do
    deps <- stanzaDeps "library magic-boundary"
    let allowed = ["base", "vector", "deepseq", "aeson", "bytestring", "text"]
    deps `shouldSatisfy` all (\d -> depName d `elem` allowed || depName d == "magic-core")
    deps `shouldSatisfy` any (\d -> depName d == "magic-core")

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
