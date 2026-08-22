-- | T5 (magic-semantics F003): the zero-ripple regression guard.
-- 'compileWithManaCap Nothing' \/ 'compileManyWithManaCap Nothing' must be
-- bit-for-bit 'compile' \/ 'compileMany' ('CompiledSpell'\'s 'Eq'), proven
-- in the same run rather than against a recorded golden file — no file
-- under @test\/golden\/@ is read or written here, and none is expected to
-- change. Checked over every shipped spell and over randomly generated
-- circles ('SigilGen.genAnyCircle') alike.
module ManaCapZeroRippleSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf)
import Magic.Circle (Circle)
import Magic.Codec (loadCircle)
import Magic.Compile (compile, compileMany, compileManyWithManaCap, compileWithManaCap)
import SigilGen (genAnyCircle)
import System.Directory (listDirectory)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (counterexample, forAll, (.&&.), (===))

spellDir :: FilePath
spellDir = "assets/spells"

loadAllSpells :: IO [(FilePath, Circle)]
loadAllSpells = do
  names <- filter (".json" `isSuffixOf`) <$> listDirectory spellDir
  mapM loadOne names
  where
    loadOne name = do
      bytes <- BS.readFile (spellDir ++ "/" ++ name)
      circle <- either (fail . show) pure (loadCircle bytes)
      pure (name, circle)

checkOne :: (FilePath, Circle) -> Spec
checkOne (name, circle) =
  it (name ++ ": Nothing == compile / compileMany, bit for bit") $ do
    compileWithManaCap Nothing circle `shouldBe` compile circle
    compileManyWithManaCap Nothing [circle] `shouldBe` compileMany [circle]

spec :: Spec
spec = describe "compileWithManaCap / compileManyWithManaCap Nothing: zero ripple (magic-semantics F003 T5)" $ do
  circles <- runIO loadAllSpells

  describe "every shipped spell in assets/spells" $
    mapM_ checkOne circles

  prop "every randomly generated circle (SigilGen.genAnyCircle)" $
    forAll genAnyCircle $ \c ->
      counterexample
        "compileWithManaCap Nothing /= compile"
        (compileWithManaCap Nothing c === compile c)
        .&&. counterexample
          "compileManyWithManaCap Nothing [c] /= compileMany [c]"
          (compileManyWithManaCap Nothing [c] === compileMany [c])
