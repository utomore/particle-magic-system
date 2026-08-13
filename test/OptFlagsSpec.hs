-- | S8 (func-spec 0005 §8): optimisation flags and the benchmark stanza.
--
-- The measured baseline in the spec's acceptance record is only
-- meaningful if the code that produced it was optimised, and a @-O2@ that
-- silently falls out of the cabal file would invalidate every number
-- taken after it. Same lightweight stanza parsing as 'BoundarySpec'.
module OptFlagsSpec (spec) where

import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf)
import Test.Hspec

optimisedStanzas :: [String]
optimisedStanzas =
  [ "library magic-core"
  , "library magic-boundary"
  , "executable particle-magic"
  , "benchmark bench"
  ]

spec :: Spec
spec = describe "build flags (func-spec 0005 §3.1)" $ do
  mapM_
    ( \header -> it (header ++ " is compiled with -O2") $ do
        opts <- stanzaField "ghc-options:" header
        opts `shouldSatisfy` ("-O2" `elem`) . words
    )
    optimisedStanzas

  it "a benchmark stanza exists and runs bench/Bench.hs" $ do
    body <- stanzaBody "benchmark bench"
    unwords body `shouldSatisfy` ("Bench.hs" `isInfixOf`)
    mainIs <- stanzaField "main-is:" "benchmark bench"
    trim mainIs `shouldBe` "Bench.hs"

  it "the benchmark does not drag h-raylib into a measured build" $ do
    body <- stanzaBody "benchmark bench"
    unwords body `shouldSatisfy` not . ("h-raylib" `isInfixOf`)

stanzaBody :: String -> IO [String]
stanzaBody header = do
  contents <- readFile "particle-magic.cabal"
  case stanzaLines header (lines contents) of
    Nothing -> do
      expectationFailure ("stanza not found: " ++ header)
      pure []
    Just body -> pure body

-- | The (single-line) value of a field inside a stanza.
stanzaField :: String -> String -> IO String
stanzaField field header = do
  body <- stanzaBody header
  case filter ((field `isPrefixOf`) . trim) body of
    (l : _) -> pure (drop (length field) (trim l))
    [] -> do
      expectationFailure (field ++ " not found in " ++ header)
      pure ""

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

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
