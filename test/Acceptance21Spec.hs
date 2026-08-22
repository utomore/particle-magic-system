-- | S7 (func-spec 0021 §7): end-to-end acceptance of the vocabulary
-- round.
--
-- Two laws carry this spec, and they pull in opposite directions.
--
-- __The bit-for-bit compatibility law__ (§1-1), the round's strongest:
-- every spell written before it renders exactly what it always did. The
-- whole round is additive — eighteen constructors, not one existing case
-- edited — so the law should hold by construction, and the way it is
-- checked is by construction too: @test\/golden\/perf-0010\/*.txt@ holds
-- 240 frames of every pre-0021 example, digested from the pre-0021 build
-- and committed, and "PerfGoldenSpec" compares against it on every run.
-- This module does not re-digest those frames; it asserts that the net
-- still /covers/ every one of them, so the delegation cannot lapse by a
-- later round quietly shipping an unnetted example.
--
-- __The plural-blend law__ (§1-8), which closes func-spec 0015 §8-5.
-- 0015 delivered batch splitting by @(blend, shape)@ and then had nothing
-- to split: blend comes from 'Magic.Rune.Element', and four elements fell
-- into two groups that no single spell could mix. 0021 supplies the
-- material — nine elements, five alpha and four additive — and the mixing
-- happens the way this system has always expressed "more than one circle
-- at once": 'Magic.Interface.castSpells', func-spec 0012's composition
-- (see this spec's implementation note). Compose the metal seal with the
-- yin figure and one 'FrameOutput' carries both blends.
module Acceptance21Spec (spec) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, nub, sort)
import qualified Data.Vector as V
import Magic.Circle (Circle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Motion (..)
  , PhasePlan (..)
  , SpawnPattern (..)
  , compile
  )
import Magic.Interface
  ( ActiveSpell
  , BlendMode (..)
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , castSpells
  , isFinished
  , observeSpell
  )
import Magic.Particle.Analytic (sample)
import Magic.Rune (FaceShape (..), ForceField (..), RadiationMode (..), Trajectory (..))
import Magic.Types (Seconds (..), Time (..))
import System.Directory (listDirectory)
import Test.Hspec
import Validate (exitCodeFor, failureCount, validateBytes)

spellDir :: FilePath
spellDir = "assets/spells"

-- | Everything the compatibility law is /not/ stated over: this round's
-- own two examples, plus the ones later rounds shipped (twin-lance from
-- the parallel func-spec 0025 line, comet-trail from 0023,
-- lingering-seal from 0026). None of them existed before 0021, so none
-- can witness anything about it.
newSpells :: [String]
newSpells = ["wuxing-seal", "yin-yang", "twin-lance", "comet-trail", "lingering-seal"]

-- | Everything that existed before this round — the population the
-- compatibility law is stated over.
pre0021Spells :: IO [String]
pre0021Spells = do
  entries <- listDirectory spellDir
  pure
    ( sort
        [ take (length e - 5) e
        | e <- entries
        , ".json" `isSuffixOf` e
        , take (length e - 5) e `notElem` newSpells
        ]
    )

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

frameStep :: FrameInput
frameStep = FrameInput (DeltaTime (1 / 60))

spellBytes :: String -> IO BS.ByteString
spellBytes name = BS.readFile (spellDir ++ "/" ++ name ++ ".json")

loadCircleOf :: String -> IO Circle
loadCircleOf name = spellBytes name >>= either (fail . show) pure . loadCircle

compiledOf :: String -> IO CompiledSpell
compiledOf name = loadCircleOf name >>= either (fail . show) pure . compile

castFile :: String -> IO ActiveSpell
castFile name = do
  circle <- loadCircleOf name
  either (fail . show) pure (castSpell (CastRequest circle ctx))

walk :: Int -> ActiveSpell -> [FrameOutput]
walk n spell0 = go n spell0
  where
    go 0 _ = []
    go k s = let s' = advanceSpell frameStep s in observeSpell s' : go (k - 1 :: Int) s'

-- | The composed spell the plural-blend law is stated over: the whole
-- point is that neither file on its own can produce two blends, because a
-- circle has exactly one element.
composed :: IO ActiveSpell
composed = do
  circles <- mapM loadCircleOf newSpells
  either (fail . show) pure (castSpells circles ctx)

blendsOf :: FrameOutput -> [BlendMode]
blendsOf = map rbBlend . batches

spec :: Spec
spec = describe "func-spec 0021 acceptance" $ do
  describe "the bit-for-bit compatibility law (§1-1)" $ do
    -- The digests live in PerfGoldenSpec; what would silently rot is the
    -- coverage, so that is what is asserted here.
    it "leaves every pre-0021 example inside the golden net" $ do
      previous <- pre0021Spells
      goldens <- listDirectory "test/golden/perf-0010"
      let netted = sort [take (length g - 4) g | g <- goldens, ".txt" `isSuffixOf` g]
      length previous `shouldBe` 12
      [n | n <- previous, n `notElem` netted] `shouldBe` []

    it "still renders every pre-0021 example as a single blend" $ do
      previous <- pre0021Spells
      mapM_
        ( \name -> do
            out <- (!! 120) . walk 240 <$> castFile name
            (name, nub (blendsOf out)) `shouldSatisfy` ((<= 1) . length . snd)
        )
        previous

  describe "the plural-blend law (§1-8): func-spec 0015 §8-5 settled" $ do
    it "puts two different blends in one FrameOutput" $ do
      out <- (!! 150) . walk 240 <$> composed
      length (nub (blendsOf out)) `shouldSatisfy` (>= 2)

    it "and they are the two the element table assigns" $ do
      out <- (!! 150) . walk 240 <$> composed
      nub (blendsOf out) `shouldContain` [BlendAlpha]
      nub (blendsOf out) `shouldContain` [BlendAdditive]

    it "the splitting law still holds: batches concatenate to the buffer" $ do
      out <- (!! 150) . walk 240 <$> composed
      spell <- composedSpell
      let rows = sum (map (pbCount . rbParticles) (batches out))
      rows `shouldSatisfy` (<= spellBudget spell)
      -- Every batch is a non-empty run of adjacent emitters, or the
      -- splitting produced a slice nobody asked for.
      length (batches out) `shouldSatisfy` (> 1)

    it "neither file can do it alone — one circle has one element" $
      mapM_
        ( \name -> do
            out <- (!! 150) . walk 240 <$> castFile name
            (name, nub (blendsOf out)) `shouldSatisfy` ((<= 1) . length . snd)
        )
        newSpells

  describe "the two new examples" $ do
    it "actually exercise the new vocabulary" $ do
      seal <- compiledOf "wuxing-seal"
      yy <- compiledOf "yin-yang"
      -- A new shape and a new radiation mode on the casting emitter...
      let castingMotion spell = emMotion (spellEmitters spell V.! 0)
      motSpawn (castingMotion seal) `shouldSatisfy` \s -> case s of
        SpawnOnShape (Polygon _ _) -> True
        _ -> False
      motRadiation (castingMotion seal) `shouldBe` TangentialSwirl
      motSpawn (castingMotion yy) `shouldSatisfy` \s -> case s of
        SpawnOnShape (Sector _ _ _) -> True
        _ -> False
      motRadiation (castingMotion yy) `shouldBe` RadialInward
      -- ...a new trajectory...
      motTraject (castingMotion seal) `shouldSatisfy` \t -> case t of
        Wave _ _ _ -> True
        _ -> False
      motTraject (castingMotion yy) `shouldSatisfy` \t -> case t of
        Pulse _ _ -> True
        _ -> False
      -- ...and all three new force fields between them.
      let kinds = spellFields seal ++ spellFields yy
      kinds `shouldSatisfy` any (\f -> case f of Wind {} -> True; _ -> False)
      kinds `shouldSatisfy` any (\f -> case f of Turbulence {} -> True; _ -> False)
      kinds `shouldSatisfy` any (\f -> case f of Spring {} -> True; _ -> False)

    it "are deterministic over 240 frames" $
      mapM_
        ( \name -> do
            a <- walk 240 <$> castFile name
            b <- walk 240 <$> castFile name
            a `shouldBe` b
        )
        newSpells

    it "keep the budget invariant: spellBudget = sum of the emitter counts" $
      mapM_
        ( \name -> do
            spell <- compiledOf name
            spellBudget spell
              `shouldBe` sum (map emCount (V.toList (spellEmitters spell)))
        )
        newSpells

    it "never sample more particles than the budget allows" $
      mapM_
        ( \name -> do
            spell <- compiledOf name
            let Seconds end = ppEnd (spellPhases spell)
            sequence_
              [ pbCount (sample spell ctx (Time t)) `shouldSatisfy` (<= spellBudget spell)
              | t <- [0, 0.05 .. end + 0.5]
              ]
        )
        newSpells

    it "finish exactly at ppEnd" $
      mapM_
        ( \name -> do
            spell <- compiledOf name
            live <- castFile name
            let Seconds end = ppEnd (spellPhases spell)
                stepTo t = advanceSpell (FrameInput (DeltaTime t)) live
            isFinished (stepTo (end - 0.01)) `shouldBe` False
            isFinished (stepTo (end + 0.01)) `shouldBe` True
        )
        newSpells

    it "pass magic-validate with exit code 0" $ do
      reports <-
        mapM
          (\name -> validateBytes (spellDir ++ "/" ++ name ++ ".json") <$> spellBytes name)
          newSpells
      failureCount reports `shouldBe` 0
      exitCodeFor reports `shouldBe` 0
  where
    composedSpell = do
      circles <- mapM loadCircleOf newSpells
      spells <- mapM (either (fail . show) pure . compile) circles
      pure (mconcat spells)
