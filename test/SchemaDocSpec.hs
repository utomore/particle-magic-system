-- | S2 (func-spec 0014 §7): the author-facing schema document cannot go
-- stale.
--
-- Fourth outing for this repo's text-contract guard (BoundarySpec →
-- FFIContractSpec → BindingContractSpec → here): a document that must
-- agree with the code is checked by a test rather than by memory. The
-- rule is deliberately one-directional — every object key that appears in
-- a shipped example must appear in @docs\/spell-schema.md@ — so the day a
-- later spec adds a key and an example using it, @cabal test@ says the
-- documentation is short of it. The other direction (the document
-- describing a key that does not exist) is left to human review: it is
-- the harmless failure, and mechanising it would forbid the document from
-- ever mentioning a key in prose.
module SchemaDocSpec (spec) where

import Data.Aeson (Value (Array, Object), decodeStrict)
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Foldable (toList)
import Data.List (isInfixOf, isSuffixOf, nub, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (listDirectory)
import Test.Hspec

docPath :: FilePath
docPath = "docs/spell-schema.md"

spellDir :: FilePath
spellDir = "assets/spells"

exampleNames :: IO [FilePath]
exampleNames = do
  entries <- listDirectory spellDir
  pure [e | e <- sort entries, ".json" `isSuffixOf` e]

-- | Every object key anywhere in a JSON value, in first-seen order.
keysOf :: Value -> [String]
keysOf value = case value of
  Object o -> concat [AK.toString k : keysOf v | (k, v) <- KM.toList o]
  Array items -> concatMap keysOf (toList items)
  _ -> []

allExampleKeys :: IO [String]
allExampleKeys = do
  names <- exampleNames
  values <- mapM (fmap decodeStrict . BS.readFile . under) names
  pure (nub (sort (concatMap (maybe [] keysOf) values)))
  where
    under n = spellDir ++ "/" ++ n

-- | The document is written in Chinese, so it is read as UTF-8 bytes
-- rather than through 'readFile' — whose decoding follows the machine's
-- locale, and would make this test pass or fail depending on which
-- console code page the developer happens to have.
readDoc :: IO String
readDoc = T.unpack . TE.decodeUtf8 <$> BS.readFile docPath

spec :: Spec
spec = describe "docs/spell-schema.md covers schema v1 (func-spec 0014 §1.3)" $ do
  it "documents every key the shipped examples use" $ do
    doc <- readDoc
    keys <- allExampleKeys
    -- Non-empty, or the guard would pass vacuously the day the asset
    -- directory moves.
    keys `shouldSatisfy` ((> 30) . length)
    [k | k <- keys, not (k `isInfixOf` doc)] `shouldBe` []

  it "references every shipped example by name" $ do
    doc <- readDoc
    names <- exampleNames
    -- 10 examples at func-spec 0014's delivery; soft-bloom.json joins in
    -- func-spec 0015.
    length names `shouldBe` 11
    [n | n <- names, not (n `isInfixOf` doc)] `shouldBe` []

  it "tells the author how to check a file" $ do
    doc <- readDoc
    doc `shouldSatisfy` ("magic-validate" `isInfixOf`)
