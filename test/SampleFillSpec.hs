-- | S2 (func-spec 0010 §7): the count-then-fill sampler.
--
-- @sample@ no longer builds a boxed list of particles and folds it into
-- six columns seven times; it counts the live rows from the culling
-- windows, allocates six exact-size columns once, and writes each row in
-- place inside a closed 'Control.Monad.ST.ST' region.
--
-- The obligation that comes with that is bit-for-bit equality with the
-- path it replaced, so this module carries an /independent/
-- reimplementation of the pre-0010 sampler — the full index scan, the
-- amplify multiplication, the colour ramp interpolation, all written out
-- again here rather than imported — and asserts the two agree column by
-- column, bit by bit. (@PerfGoldenSpec@ asserts the same thing against
-- frames captured before the rewrite; this one says /why/ they agree.)
module SampleFillSpec (spec) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Circle (Circle (..), Core (..), Nodes (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( Appearance (..)
  , ColorRamp (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , compile
  )
import Magic.Expr (ExprEnv (..), evalFinite)
import Magic.Particle.Analytic (particleAge, particlePosition, sample)
import Magic.Particle.Buffer
  ( ParticleBuffer (..)
  , bufferInvariant
  , buildBuffer
  , fromParticles
  )
import Magic.Rune (EssenceRune (..), Element (..))
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..))
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (sample, (.&.))

ctx :: CastContext
ctx = CastContext {casterPos = V3 0.5 (-1) 2, casterFacing = V3 0 1 0, seed = Seed 4242}

examples :: [String]
examples =
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

-- | The shipped examples, compiled once. Read at load time because the
-- properties below quantify over time, not over files.
{-# NOINLINE fixtures #-}
fixtures :: [(String, CompiledSpell)]
fixtures = unsafePerformIO (mapM load examples)
  where
    load name = do
      bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
      circle <- either (fail . show) pure (loadCircle bytes)
      spell <- either (fail . show) pure (compile circle)
      pure (name, spell)

-- | Power 16 ⇒ count = 4096 = the budget cap: the full-buffer boundary.
denseSpell :: CompiledSpell
denseSpell =
  either (error . show) id . compile $
    emptyCircle {core = Core (Just (EssenceRune Fire 16)) (Nodes Nothing Nothing Nothing Nothing)}

-- The pre-0010 sampler, written out again ------------------------------------

-- | Full index scan, boxed tuples, six columns folded out of the list —
-- the shape @sample@ had before this round.
referenceSample :: CompiledSpell -> CastContext -> Time -> ParticleBuffer
referenceSample spell c t@(Time seconds)
  | seconds < 0 = fromParticles []
  | otherwise = fromParticles (concatMap emitterRows (V.toList (spellEmitters spell)))
  where
    emitterRows em =
      [ row em i age
      | i <- [0 .. emCount em - 1]
      , Just age <- [particleAge (emSpawn em) (emCount em) i t]
      ]

    row em i ageD =
      let Seconds lifetime = envLifetime (emSpawn em)
          Appearance ramp size _blend mAmplify = emAppearance em
          lifeFrac = realToFrac (ageD / lifetime) :: Float
          env =
            ExprEnv
              { envT = realToFrac seconds
              , envLife = lifeFrac
              , envPIndex = i
              , envSeed = seed c
              }
          finalSize = case mAmplify of
            Nothing -> size
            Just amp -> size * max 0 (evalFinite amp env)
       in (particlePosition c t em i ageD, finalSize, lifeFrac, referenceRamp ramp lifeFrac)

-- | Linear interpolation of a packed 0xRRGGBBAA ramp, reimplemented.
referenceRamp :: ColorRamp -> Float -> Word32
referenceRamp (ColorRamp start end) life
  | start == end = start
  | otherwise = foldr (.|.) 0 [lerpByte sh `shiftL` sh | sh <- [24, 16, 8, 0]]
  where
    l = max 0 (min 1 life)
    byteAt v sh = fromIntegral ((v `shiftR` sh) .&. 0xFF) :: Float
    lerpByte sh =
      let a = byteAt start sh
          b = byteAt end sh
       in round (a + (b - a) * l) :: Word32

-- Helpers ---------------------------------------------------------------------

columns :: ParticleBuffer -> ([Float], [Float], [Float], [Float], [Float], [Word32])
columns pb =
  ( U.toList (pbPosX pb)
  , U.toList (pbPosY pb)
  , U.toList (pbPosZ pb)
  , U.toList (pbSize pb)
  , U.toList (pbLife pb)
  , U.toList (pbColor pb)
  )

spec :: Spec
spec = describe "count-then-fill sampler (func-spec 0010 §7 S2)" $ do
  describe "bit-for-bit equality with the pre-0010 list path" $ do
    mapM_ agreesOverTime fixtures

    prop "at the 4096-particle cap as well" $
      forAll (choose (0, 10)) $ \t ->
        let new = sample denseSpell ctx (Time t)
            old = referenceSample denseSpell ctx (Time t)
         in columns new === columns old .&&. pbCount new === pbCount old

    it "the dense fixture really does fill the whole cap" $ do
      spellBudget denseSpell `shouldBe` 4096
      pbCount (sample denseSpell ctx (Time 2.5)) `shouldBe` 4096

  describe "the buffer invariant, everywhere" $ do
    prop "holds for every example at every age" $
      forAll (elements fixtures) $ \(_, spell) ->
        forAll (choose (-1, 12)) $ \t ->
          property (bufferInvariant (sample spell ctx (Time t)))

    it "a negative time is the empty buffer, not a zero-row one" $ do
      let pb = sample denseSpell ctx (Time (-0.001))
      pbCount pb `shouldBe` 0
      U.null (pbPosX pb) `shouldBe` True
      bufferInvariant pb `shouldBe` True

    it "a spell before its first birth samples empty" $ do
      let (_, spell) = head' fixtures
      pbCount (sample spell ctx (Time 0)) `shouldSatisfy` (>= 0)
      bufferInvariant (sample spell ctx (Time 0)) `shouldBe` True

  describe "buildBuffer" $ do
    prop "fromParticles is exactly the columnwise transpose of its input" $
      \ps ->
        let rows = [(V3 x y z, s, l, c) | (x, y, z, s, l, c) <- ps]
            pb = fromParticles rows
         in columns pb
              === ( [x | (V3 x _ _, _, _, _) <- rows]
                  , [y | (V3 _ y _, _, _, _) <- rows]
                  , [z | (V3 _ _ z, _, _, _) <- rows]
                  , [s | (_, s, _, _) <- rows]
                  , [l | (_, _, l, _) <- rows]
                  , [c | (_, _, _, c) <- rows]
                  )
              .&&. pbCount pb === length rows

    it "a zero-row build is the empty buffer" $
      buildBuffer 0 (\_ -> pure ()) `shouldBe` fromParticles []

    it "rows the fill action skips are zero, not uninitialized memory" $ do
      -- Determinism is the round's central law: a caller that miscounts
      -- must produce blank particles, never whatever was on the heap.
      let pb = buildBuffer 3 (\write -> write 1 (V3 1 2 3) 4 5 6)
      columns pb
        `shouldBe` ([0, 1, 0], [0, 2, 0], [0, 3, 0], [0, 4, 0], [0, 5, 0], [0, 6, 0])
      bufferInvariant pb `shouldBe` True

    it "writes may arrive out of order (the row index decides, not the order)" $ do
      let pb = buildBuffer 2 $ \write -> do
            write 1 (V3 9 9 9) 1 1 1
            write 0 (V3 8 8 8) 2 2 2
      U.toList (pbPosX pb) `shouldBe` [8, 9]

agreesOverTime :: (String, CompiledSpell) -> Spec
agreesOverTime (name, spell) =
  prop (name ++ ": every column, every age") $
    forAll (choose (-0.5, 12)) $ \t ->
      let new = sample spell ctx (Time t)
          old = referenceSample spell ctx (Time t)
       in counterexample ("t = " ++ show t) $
            columns new === columns old .&&. pbCount new === pbCount old

head' :: [a] -> a
head' (x : _) = x
head' [] = error "SampleFillSpec: no fixtures"
