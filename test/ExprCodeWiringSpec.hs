-- | S3 (func-spec 0022 §6): the bytecode wired into 'Magic.Compile.compile'
-- and 'Magic.Particle.Analytic.sample' — and __law 1 end to end__.
--
-- S1 proves @evalCode . compileExpr ≡ evalExpr@ over arbitrary formulas.
-- This module proves the thing that claim is /for/: with the compiled
-- programs in the hot path, every shipped example spell samples the same
-- bits it always did.
--
-- The witness here is an A\/B against the reference evaluator on the /same
-- build/: 'Magic.Compile.noEmitterCode' blanks an emitter's compiled
-- programs, and the sampler then falls back to 'Magic.Expr.evalFinite' over
-- the AST. Sampling both variants at the same 240 frame times and comparing
-- all six SoA columns bit for bit is a stronger statement than a recorded
-- baseline could make: a golden file says "the same as some earlier build",
-- this says "the same as the reference implementation, right now, on every
-- spell we ship". The 'Magic.Interface.FrameOutput'-level golden — the whole
-- pipeline including the force-field overlay and batch splitting — is
-- @test\/PerfGoldenSpec.hs@, which the same round leaves untouched and green.
module ExprCodeWiringSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import GHC.Float (castFloatToWord32)
import Magic.Circle (Circle (..), TwoOf (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( Appearance (..)
  , CompiledSpell (..)
  , EmitterCode (..)
  , EmitterSpec (..)
  , Motion (..)
  , ParticleBudget (..)
  , compile
  , emitterBounds
  , emitterCodeOf
  , noEmitterCode
  )
import Magic.Expr (BinOp (..), Expr (..), ExprV3 (..), Var (..))
import Magic.Expr.Code (compileExpr, compileExprV3)
import Magic.Particle.Analytic (sample)
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Rune (BridgeRune (..), InnerRune (..), OuterRune (..))
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..))

import Test.Hspec

-- | Every shipped example, so no spell shape escapes the comparison.
examples :: [String]
examples =
  [ "bare-sigil"
  , "converge-flame"
  , "empty"
  , "grand-sigil"
  , "gravity-well"
  , "lattice-seal"
  , "lissajous"
  , "pulse-ring"
  , "ring-fire"
  , "soft-bloom"
  , "spiral-spark"
  , "square-burst"
  , "twin-lance"
  , "wuxing-seal"
  , "yin-yang"
  ]

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

-- | 4 seconds at 60 Hz — the same window @PerfGoldenSpec@ walks, so the
-- ramp-up, the steady state and the die-out are all covered.
frameTimes :: [Time]
frameTimes = [Time (fromIntegral n / 60) | n <- [1 .. 240 :: Int]]

compiledExample :: String -> IO CompiledSpell
compiledExample name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (compile circle)

-- | The same spell with every compiled program removed: the sampler falls
-- back to walking the AST, which is the reference answer.
stripCode :: CompiledSpell -> CompiledSpell
stripCode spell =
  spell {spellEmitters = V.map (\em -> em {emCode = noEmitterCode}) (spellEmitters spell)}

-- | Every column as raw bit patterns — the only comparison strong enough,
-- since @(==)@ on 'Float' would miss a NaN and would equate ±0.
digest :: ParticleBuffer -> (Int, [Word32])
digest pb =
  ( pbCount pb
  , concat
      [ bitsOf (pbPosX pb)
      , bitsOf (pbPosY pb)
      , bitsOf (pbPosZ pb)
      , bitsOf (pbSize pb)
      , bitsOf (pbLife pb)
      , U.toList (pbColor pb)
      ]
  )
  where
    bitsOf = map castFloatToWord32 . U.toList

-- | Compile a circle to its single emitter.
theEmitter :: Circle -> EmitterSpec
theEmitter c = case compile c of
  Right spell | not (V.null (spellEmitters spell)) -> V.head (spellEmitters spell)
  other -> error ("expected at least one emitter, got: " ++ show other)

eA, eB :: Expr
eA = Bin Mul (Var VarT) (Lit 2)
eB = Bin Add (Lit 1) (Var VarLife)

v3A :: ExprV3
v3A = ExprV3 (Var VarT) (Lit 0) (Lit 1)

spec :: Spec
spec = describe "bytecode in the hot path (func-spec 0022 §6 S3)" $ do
  describe "law 1, end to end: every shipped example samples the same bits" $
    mapM_ exampleSampling examples

  describe "compile fills the cache, and fills it from the emitter's own AST" $ do
    it "every emitter of every example carries the code its formulas compile to" $
      mapM_
        ( \name -> do
            spell <- compiledExample name
            let drifted =
                  [ (name, e)
                  | (e, em) <- zip [0 :: Int ..] (V.toList (spellEmitters spell))
                  , emCode em /= emitterCodeOf em
                  ]
            drifted `shouldBe` []
        )
        examples

    it "the shipped examples do carry formulas, so the check is not vacuous" $ do
      spells <- mapM compiledExample examples
      let slots = concatMap (map emCode . V.toList . spellEmitters) spells
      length (filter (/= noEmitterCode) slots) `shouldSatisfy` (> 0)

  describe "one witness per Expr rune (the four §4.3 landing spots)" $ do
    it "RangeRune (outer) compiles into emcRange" $ do
      let em = theEmitter emptyCircle {outerRings = TwoOf (Just (RangeRune eA)) Nothing}
      motRange (emMotion em) `shouldBe` Just eA
      emcRange (emCode em) `shouldBe` Just (compileExpr eA)
      emCode em `shouldBe` noEmitterCode {emcRange = Just (compileExpr eA)}

    it "ConvergeRune (bridge) compiles into emcConverge" $ do
      let em = theEmitter emptyCircle {interLayer = Just (ConvergeRune eA)}
      emcConverge (emCode em) `shouldBe` Just (compileExpr eA)
      emCode em `shouldBe` noEmitterCode {emcConverge = Just (compileExpr eA)}

    it "AmplifyRune (bridge) compiles into emcAmplify" $ do
      let em = theEmitter emptyCircle {interLayer = Just (AmplifyRune eB)}
      emcAmplify (emCode em) `shouldBe` Just (compileExpr eB)
      emCode em `shouldBe` noEmitterCode {emcAmplify = Just (compileExpr eB)}

    it "FormulaRune (inner) compiles into emcTraject" $ do
      let em = theEmitter emptyCircle {innerRings = TwoOf (Just (FormulaRune v3A)) Nothing}
      emcTraject (emCode em) `shouldBe` Just (compileExprV3 v3A)
      emCode em `shouldBe` noEmitterCode {emcTraject = Just (compileExprV3 v3A)}

    it "a circle with no Expr runes compiles to no code at all" $
      emCode (theEmitter emptyCircle) `shouldBe` noEmitterCode

    it "and each of the four still samples bit-identically to the AST path" $ do
      let circles =
            [ ("range", emptyCircle {outerRings = TwoOf (Just (RangeRune eA)) Nothing})
            , ("converge", emptyCircle {interLayer = Just (ConvergeRune eA)})
            , ("amplify", emptyCircle {interLayer = Just (AmplifyRune eB)})
            , ("formula", emptyCircle {innerRings = TwoOf (Just (FormulaRune v3A)) Nothing})
            ]
      mapM_
        ( \(name, c) -> do
            spell <- either (fail . show) pure (compile c)
            let diffs =
                  [ t
                  | t <- frameTimes
                  , digest (sample spell ctx t) /= digest (sample (stripCode spell) ctx t)
                  ]
            (name, diffs) `shouldBe` (name, [])
        )
        circles

  describe "nothing else about a compiled spell moved" $ do
    it "spellBudget and its per-emitter breakdown are untouched by the cache" $
      mapM_
        ( \name -> do
            spell <- compiledExample name
            let plan = spellBudgetPlan spell
            budgetTotal plan `shouldBe` spellBudget spell
            U.sum (budgetPerEmitter plan) `shouldBe` spellBudget spell
            U.length (budgetPerEmitter plan) `shouldBe` V.length (spellEmitters spell)
            spellBudget (stripCode spell) `shouldBe` spellBudget spell
        )
        examples

    it "emitterBounds reads the AST, so blanking the cache cannot move a box" $
      mapM_
        ( \name -> do
            spell <- compiledExample name
            let horizon = spellLifetime spell
                boxes s = [emitterBounds ctx horizon em | em <- V.toList (spellEmitters s)]
            boxes (stripCode spell) `shouldBe` boxes spell
        )
        examples

    it "a CompiledSpell is still plain data: comparable, and showable in full" $
      mapM_
        ( \name -> do
            spell <- compiledExample name
            -- Deriving Eq and Show at all is the type-level half of "no
            -- closures in here"; forcing both is the value-level half.
            spell `shouldBe` spell
            length (show spell) `shouldSatisfy` (> 0)
        )
        examples

exampleSampling :: String -> Spec
exampleSampling name = it (name ++ ": 240 frames, six columns, bit for bit") $ do
  spell <- compiledExample name
  let reference = stripCode spell
      diffs = [t | t <- frameTimes, digest (sample spell ctx t) /= digest (sample reference ctx t)]
  case diffs of
    [] -> pure ()
    (Time t : _) ->
      expectationFailure
        ( name
            ++ ": "
            ++ show (length diffs)
            ++ " frame(s) differ between the bytecode and the AST evaluator, first at t="
            ++ show t
        )
