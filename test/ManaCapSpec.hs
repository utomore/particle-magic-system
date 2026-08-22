-- | T2 (magic-semantics F003): 'compileWithManaCap' / 'compileManyWithManaCap'
-- — the mana-capped compile entry points. 'Nothing' is bit-for-bit
-- 'compile' \/ 'compileMany' (the zero-ripple law); a 'Just' cap is checked
-- only after the particle budget passes, and 'compileManyWithManaCap'
-- checks the /summed/ mana of the whole composition, not each circle on
-- its own.
module ManaCapSpec (spec) where

import qualified Data.ByteString as BS
import Magic.Circle (Circle (..), Core (..), Nodes (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompileError (..)
  , budgetCap
  , compile
  , compileMany
  , compileManyWithManaCap
  , compileWithManaCap
  , manaCost
  )
import Magic.Rune (Element (..), EssenceRune (..), NodeRune (..))
import Test.Hspec

noNodes :: Nodes (Maybe NodeRune)
noNodes = Nodes Nothing Nothing Nothing Nothing

loadCircleOf :: String -> IO Circle
loadCircleOf name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

-- | Only the core center occupied: enough power pushes the particle count
-- past 'budgetCap' while the mana cost stays a single essence weight (2,
-- for the five-elements row) — for the "particle check runs first"
-- assertion below.
denseCircle :: Double -> Circle
denseCircle power = emptyCircle {core = Core (Just (EssenceRune Water power)) noNodes}

spec :: Spec
spec = describe "compileWithManaCap / compileManyWithManaCap (magic-semantics F003 T2)" $ do
  circle <- runIO (loadCircleOf "grand-sigil")
  let cost = manaCost circle

  it "grand-sigil has a non-zero mana cost (sanity, so the tests below are non-vacuous)" $
    cost `shouldSatisfy` (> 0)

  describe "Nothing is bit-for-bit compile / compileMany" $ do
    it "compileWithManaCap Nothing == compile" $
      compileWithManaCap Nothing circle `shouldBe` compile circle
    it "compileManyWithManaCap Nothing == compileMany" $
      compileManyWithManaCap Nothing [circle, circle] `shouldBe` compileMany [circle, circle]

  describe "a mana cap at or above the cost behaves exactly like compile" $ do
    it "at the cost" $
      compileWithManaCap (Just cost) circle `shouldBe` compile circle
    it "well above the cost" $
      compileWithManaCap (Just (cost + 1000)) circle `shouldBe` compile circle

  it "a mana cap below the cost is ManaExceeded, carrying (cost, cap)" $
    compileWithManaCap (Just (cost - 1)) circle `shouldBe` Left (ManaExceeded cost (cost - 1))

  it "particle budget is checked first: an over-budget circle stays BudgetExceeded" $ do
    let c = denseCircle 100.0
    compile c `shouldBe` Left (BudgetExceeded 25600 budgetCap)
    compileWithManaCap (Just 1000000) c `shouldBe` Left (BudgetExceeded 25600 budgetCap)

  describe "compileManyWithManaCap checks the summed mana, not each circle alone" $ do
    it "a cap that fits one circle but not the pair is ManaExceeded with the summed total" $
      compileManyWithManaCap (Just cost) [circle, circle]
        `shouldBe` Left (ManaExceeded (cost + cost) cost)
    it "a cap that fits the summed total behaves like compileMany" $
      compileManyWithManaCap (Just (cost + cost)) [circle, circle]
        `shouldBe` compileMany [circle, circle]
