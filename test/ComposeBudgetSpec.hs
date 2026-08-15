-- | S3 (func-spec 0012 §7): 'compileMany' — the fold over the 'Semigroup'
-- plus the one thing composition must not let through, an unbounded
-- particle count.
--
-- Two circles that each fit under 'budgetCap' can exceed it together, so
-- the composed total is checked against the same cap and refused with the
-- same 'BudgetExceeded' constructor — carrying the /combined/ demand, so
-- a host is told what it actually asked for. No new error constructor:
-- the caller's recovery ("cast fewer circles, or weaker ones") is the
-- same one a single over-budget circle calls for.
module ComposeBudgetSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompileError (..)
  , CompiledSpell (..)
  , ParticleBudget (..)
  , budgetCap
  , compile
  , compileMany
  )
import Magic.Interface (Circle)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

exampleNames :: [String]
exampleNames =
  [ "bare-sigil"
  , "converge-flame"
  , "empty"
  , "grand-sigil"
  , "gravity-well"
  , "lissajous"
  , "pulse-ring"
  , "ring-fire"
  , "spiral-spark"
  , "square-burst"
  ]

loadCircleOf :: String -> IO Circle
loadCircleOf name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

-- | @round (power * 256)@ casting particles, and nothing else.
denseCircle :: Double -> IO Circle
denseCircle power =
  either (fail . show) pure . loadCircle . BS8.pack $
    "{ \"version\": 1, \"name\": \"budget-fixture\", \"circle\": \
    \{ \"core\": { \"center\": { \"element\": \"water\", \"power\": "
      ++ show power
      ++ " }, \"nodes\": { \"north\": null, \"south\": null, \
         \\"east\": null, \"west\": null } } } }"

rightOrFail :: (Show e) => Either e a -> IO a
rightOrFail = either (fail . show) pure

spec :: Spec
spec = do
  circles <- runIO (mapM loadCircleOf exampleNames)
  let anyCircle = elements (zip exampleNames circles)

  describe "compileMany (func-spec 0012 S3)" $ do
    it "of the empty list is the empty spell" $
      compileMany [] `shouldBe` Right (mempty :: CompiledSpell)

    prop "of a singleton is exactly compile" $
      forAll anyCircle $ \(_, c) -> compileMany [c] === compile c

    prop "budgets concatenate and sum" $
      forAll anyCircle $ \(_, a) -> forAll anyCircle $ \(_, b) ->
        case (compile a, compile b, compileMany [a, b]) of
          (Right sa, Right sb, Right sab) ->
            conjoin
              [ counterexample "total" (spellBudget sab === spellBudget sa + spellBudget sb)
              , counterexample
                  "per emitter"
                  ( budgetPerEmitter (spellBudgetPlan sab)
                      === budgetPerEmitter (spellBudgetPlan sa)
                        U.++ budgetPerEmitter (spellBudgetPlan sb)
                  )
              , counterexample
                  "aligned with the concatenated emitters"
                  ( U.length (budgetPerEmitter (spellBudgetPlan sab))
                      === V.length (spellEmitters sab)
                  )
              ]
          other -> counterexample ("unexpected: " ++ show other) False

    prop "is the fold: compileMany xs == mconcat of the compiled xs" $
      forAll (resize 4 (listOf anyCircle)) $ \named ->
        let cs = map snd named
         in case (compileMany cs, traverse compile cs) of
              (Right composed, Right parts) -> composed === mconcat parts
              (l, r) -> counterexample ("unexpected: " ++ show (l, r)) False

  describe "the composed budget is checked against the same cap" $ do
    it "refuses two circles that each fit but do not fit together" $ do
      c <- denseCircle 40.0
      one <- rightOrFail (compile c)
      spellBudget one `shouldBe` 10240
      spellBudget one `shouldSatisfy` (<= budgetCap)
      compileMany [c, c] `shouldBe` Left (BudgetExceeded 20480 budgetCap)

    it "accepts two that exactly fill the cap (the boundary is inclusive)" $ do
      c <- denseCircle 32.0
      composed <- rightOrFail (compileMany [c, c])
      spellBudget composed `shouldBe` 16384
      spellBudget composed `shouldBe` budgetCap

    it "and a component that cannot compile fails the whole composition" $ do
      good <- loadCircleOf "ring-fire"
      tooBig <- denseCircle 80.0
      compileMany [good, tooBig] `shouldBe` Left (BudgetExceeded 20480 budgetCap)
      compileMany [tooBig, good] `shouldBe` Left (BudgetExceeded 20480 budgetCap)
