-- | T5 (func-spec 0026): the two things this round promised not to move.
--
--   * __The digest.__ 'Magic.Sigil.hashCircle' decides what a sigil
--     /looks like/, and ADR-0014 D3 froze it: changing it silently
--     redraws every spell in the game. @linger@ and @hold@ are time and
--     look-over-time, not geometry, so they ride alongside the fold the
--     way force fields and activation points do — carried, never folded.
--     The cheapest possible implementation of that promise is to do
--     nothing, which is exactly what makes it worth a test.
--
--   * __Zero ripple.__ A circle with no @"sigil"@ key must compile and
--     sample to what it always did. Asserted structurally rather than
--     against a recording: @Just (SigilTiming 0 False)@ and 'Nothing'
--     produce the same 'CompiledSpell' and the same 240 frames, and the
--     shipped examples still match the goldens they had before this round
--     (@test\/PerfGoldenSpec.hs@ carries that half; the coverage
--     assertion at the end keeps it from going vacuous).
module SigilTimingInvariantSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import Data.Maybe (isJust)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Circle (Circle (..), SigilTiming (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile (CompiledSpell, compile)
import Magic.Interface
  ( CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , advanceSpell
  , castSpell
  , observeSpell
  )
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Sigil (hashCircle)
import Magic.Types (CastContext (..), Seconds (..), Seed (..), V3 (..))
import SigilGen (genAnyCircle)
import System.Directory (listDirectory)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

spellDir :: FilePath
spellDir = "assets/spells"

-- | Every shipped example whose circle has a @phases@ key, and therefore
-- a sigil for this round to have disturbed. Derived from the directory:
-- a later round that ships another phased example is covered without
-- anyone remembering to add it here.
phasedExamples :: IO [String]
phasedExamples = do
  entries <- listDirectory spellDir
  let names = sort [take (length e - 5) e | e <- entries, ".json" `isSuffixOf` e]
  circles <- mapM circleFile names
  pure [n | (n, c) <- zip names circles, isJust (circlePhases c)]

circleFile :: String -> IO Circle
circleFile name = do
  bytes <- BS.readFile (spellDir ++ "/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

compiled :: Circle -> CompiledSpell
compiled = either (error . show) id . compile

-- | The pre-0026 reading of a circle: whatever it says about its sigil's
-- clock, ignored. lingering-seal.json names one, so "the same circle
-- without the key" has to be constructed rather than assumed.
sigilless :: Circle -> Circle
sigilless c = c {circleSigil = Nothing}

noop :: Circle -> Circle
noop c = c {circleSigil = Just (SigilTiming (Seconds 0) False)}

-- | Timings chosen to reach every branch a digest could conceivably
-- notice, the codec's two caps included.
timings :: [SigilTiming]
timings =
  [ SigilTiming (Seconds 0) False
  , SigilTiming (Seconds 0) True
  , SigilTiming (Seconds 2) True
  , SigilTiming (Seconds (-2)) False
  , SigilTiming (Seconds 60) True
  , SigilTiming (Seconds (-60)) False
  ]

frameCount :: Int
frameCount = 240

-- | Four seconds at 60 Hz, as raw columns rather than a digest: this is a
-- differential between two circles computed in the same run, so there is
-- nothing to record and no reason to lose information to a hash.
walk :: Circle -> [(Int, [Float], [Word32])]
walk circle =
  let spell0 = either (error . show) id (castSpell (CastRequest circle ctx))
      step = FrameInput (DeltaTime (1 / 60))
      ages = drop 1 (iterate (advanceSpell step) spell0)
   in map (frameOf . observeSpell) (take frameCount ages)

frameOf :: FrameOutput -> (Int, [Float], [Word32])
frameOf out = (sum (map pbCount bufs), concatMap floats bufs, concatMap colors bufs)
  where
    bufs = map rbParticles (batches out)
    floats b =
      concatMap
        (U.toList . ($ b))
        [pbPosX, pbPosY, pbPosZ, pbSize, pbLife]
    colors = U.toList . pbColor

spec :: Spec
spec = describe "what func-spec 0026 promised not to move (T5)" $ do
  describe "the digest is untouched (ADR-0014 D3)" $ do
    it "hashCircle ignores circleSigil, on the empty circle" $
      mapM_
        (\st -> hashCircle (emptyCircle {circleSigil = Just st}) `shouldBe` hashCircle emptyCircle)
        timings

    it "and on every shipped example with a sigil to redraw" $ do
      names <- phasedExamples
      names `shouldSatisfy` ((>= 8) . length)
      mapM_
        ( \name -> do
            c <- circleFile name
            mapM_
              ( \st ->
                  (name, hashCircle (c {circleSigil = Just st}))
                    `shouldBe` (name, hashCircle (sigilless c))
              )
              timings
        )
        names

    prop "...and on any circle at all" $
      forAll genAnyCircle $ \c ->
        conjoin
          [hashCircle (c {circleSigil = Just st}) === hashCircle c | st <- timings]

  describe "zero ripple" $ do
    it "the explicit no-op timing compiles to the very same spell" $ do
      names <- phasedExamples
      mapM_
        ( \name -> do
            c <- circleFile name
            (name, compiled (noop c)) `shouldBe` (name, compiled (sigilless c))
        )
        names

    it "and samples to the same 240 frames, bit for bit" $ do
      names <- phasedExamples
      mapM_
        ( \name -> do
            c <- circleFile name
            (name, walk (noop c)) `shouldBe` (name, walk (sigilless c))
        )
        names

    prop "for any circle, not only the shipped ones" $
      forAll genAnyCircle $ \c -> compile (noop c) === compile (sigilless c)

  describe "the golden net still covers the sigils" $
    it "every phased example has a golden, so the recorded half is not vacuous" $ do
      names <- phasedExamples
      goldens <- listDirectory "test/golden/perf-0010"
      let netted = sort [take (length g - 4) g | g <- goldens, ".txt" `isSuffixOf` g]
      [n | n <- names, n `notElem` netted] `shouldBe` []
