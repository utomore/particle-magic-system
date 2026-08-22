-- | T4 (magic-semantics F003): the two tool-side windows on
-- 'CompileError' — @magic-validate@'s 'renderCompileError' and
-- @magic-inspect@'s 'renderCompileErrorForInspect' — stay exhaustive once
-- 'ManaExceeded' joins 'BudgetExceeded', and a human reading either message
-- can tell the two kinds of overspend apart.
module ManaErrorRenderSpec (spec) where

import Inspect (renderCompileErrorForInspect)
import Magic.Interface (CompileError (..))
import Test.Hspec
import Validate (renderCompileError)

spec :: Spec
spec = describe "ManaExceeded rendering (magic-semantics F003 T4)" $ do
  describe "Validate.renderCompileError" $ do
    it "mentions \"mana\" and both numbers" $ do
      let msg = renderCompileError (ManaExceeded 10 5)
      msg `shouldContain` "mana"
      msg `shouldContain` "10"
      msg `shouldContain` "5"
    it "reads differently from a particle-budget overspend" $
      renderCompileError (ManaExceeded 10 5)
        `shouldNotBe` renderCompileError (BudgetExceeded 10 5)

  describe "Inspect.renderCompileErrorForInspect" $ do
    it "mentions \"mana\" and both numbers" $ do
      let msg = renderCompileErrorForInspect (ManaExceeded 10 5)
      msg `shouldContain` "mana"
      msg `shouldContain` "10"
      msg `shouldContain` "5"
    it "reads differently from a particle-budget overspend" $
      renderCompileErrorForInspect (ManaExceeded 10 5)
        `shouldNotBe` renderCompileErrorForInspect (BudgetExceeded 10 5)
