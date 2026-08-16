-- | The shipped example circles, loaded once and shared by the func-spec
-- 0025 specs.
--
-- Every spatial law this round states is stated over /the actual spell
-- files/, not over hand-built fixtures: the point of a conservative bound
-- is that it holds for the shapes players really write, and the examples
-- are the closest thing this repo has to that. A fixture that only
-- exercises the arithmetic the bound was derived from would agree with
-- itself.
module SpaceExamples
  ( exampleNames
  , exampleCircles
  , exampleSpells
  , loadExample
  , testCtx
  ) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import Magic.Circle (Circle)
import Magic.Codec (loadCircle)
import Magic.Compile (CompiledSpell, compile)
import Magic.Types (CastContext (..), Seed (..), V3 (..))
import System.Directory (listDirectory)

-- | Off the origin and not facing +Z, so a bug that confuses the caster
-- frame with the world frame — or drops the anchor offset — cannot hide.
testCtx :: CastContext
testCtx = CastContext {casterPos = V3 1 2 3, casterFacing = V3 0 1 0, seed = Seed 42}

exampleNames :: IO [FilePath]
exampleNames = do
  entries <- listDirectory "assets/spells"
  pure [e | e <- sort entries, ".json" `isSuffixOf` e]

loadExample :: FilePath -> IO Circle
loadExample name = do
  bytes <- BS.readFile ("assets/spells/" ++ name)
  case loadCircle bytes of
    Left err -> error (name ++ ": " ++ show err)
    Right circle -> pure circle

exampleCircles :: IO [(FilePath, Circle)]
exampleCircles = do
  names <- exampleNames
  mapM (\n -> (,) n <$> loadExample n) names

exampleSpells :: IO [(FilePath, CompiledSpell)]
exampleSpells = do
  circles <- exampleCircles
  pure [(n, either (error . ((n ++ ": ") ++) . show) id (compile c)) | (n, c) <- circles]
