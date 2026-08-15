-- | S4 (func-spec 0014 §7): end-to-end acceptance of the authoring round.
--
-- Two claims, and they are the two halves of what "authoring tools" is
-- supposed to mean.
--
-- The tool tells the truth: run @magic-validate@'s pure half over the
-- real @assets\/spells@ directory — the very files the demo ships and
-- cycles through — and every one of them passes, with numbers that agree
-- with the compiler's own.
--
-- The demo did not change: this round added a directory scan to a loop
-- whose entire claim to correctness is that nothing observational can
-- touch the simulation. So a run in which no file is created or deleted
-- must produce exactly what func-spec 0013 delivered — same frames, same
-- casts, same per-frame batches — and it is asserted against a reference
-- aged straight through 'Magic.Interface', which is the one witness that
-- cannot itself have drifted (the 0008/0013 idiom).
module Acceptance14Spec (spec) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as M
import Effectful (runPureEff)
import System.Directory (listDirectory)
import Test.Hspec

import Magic.Codec (loadCircle)
import Magic.Interface
  ( ActiveSpell
  , BlendMode (..)
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , observeSpell
  , pbCount
  )

import App.Effects (HudView (..), ViewMode (..), noInput)
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScript
  , runFileWatchScriptDirs
  , runRaylibHeadlessWith
  )
import Validate (Report (..), Stats (..), exitCodeFor, renderReport, validateBytes)

spellDir :: FilePath
spellDir = "assets/spells"

frames :: Int
frames = 120

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

demoSpell :: FilePath
demoSpell = spellDir ++ "/ring-fire.json"

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = [demoSpell]
    , lcSpellIndex = 0
    , lcCamera = defaultCamera
    , lcCastCtx = ctx
    , lcWindowSize = (1280, 720)
    , lcWindowTitle = "acceptance"
    }

examplePaths :: IO [FilePath]
examplePaths = do
  entries <- listDirectory spellDir
  pure [spellDir ++ "/" ++ e | e <- sort entries, ".json" `isSuffixOf` e]

-- | The spell aged exactly the way the loop ages it, sampled once per
-- frame — the reference every run is checked against.
referenceSummaries :: IO [(BlendMode, Int)]
referenceSummaries = do
  bytes <- BS.readFile demoSpell
  circle <- either (fail . show) pure (loadCircle bytes)
  spell0 <- either (fail . show) pure (castSpell (CastRequest circle ctx))
  let dt = FrameInput (DeltaTime (1 / 60))
      ages :: [ActiveSpell]
      ages = drop 1 (iterate (advanceSpell dt) spell0)
      summarize out = [(rbBlend b, pbCount (rbParticles b)) | b <- batches out]
  pure (concatMap (summarize . observeSpell) (take frames ages))

-- | A run with the pre-0014 interpreter, which knows nothing about
-- directory scans.
runUnscanned :: IO (LoopStats, HeadlessLog)
runUnscanned = do
  bytes <- BS.readFile demoSpell
  pure
    . runPureEff
    . runRaylibHeadlessWith (replicate frames noInput) frames
    . runFileWatchScript bytes []
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

-- | The same run, with a scan that keeps answering the list the demo
-- already has — the quiet case, which is every frame of a real session
-- but the handful where the author touches the directory.
runQuietlyScanned :: IO (LoopStats, HeadlessLog)
runQuietlyScanned = do
  bytes <- BS.readFile demoSpell
  pure
    . runPureEff
    . runRaylibHeadlessWith (replicate frames noInput) frames
    . runFileWatchScriptDirs (M.singleton demoSpell (bytes, [])) [[demoSpell]]
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

spec :: Spec
spec = do
  describe "magic-validate against the shipped assets (func-spec 0014 §1.1)" $ do
    it "every example the demo cycles through passes" $ do
      paths <- examplePaths
      reports <- mapM (\p -> validateBytes p <$> BS.readFile p) paths
      concatMap (renderReport False) reports
        `shouldBe` unlines ["OK " ++ p | p <- paths]
      exitCodeFor reports `shouldBe` 0

    it "and every one of them fits inside the cap it reports" $ do
      paths <- examplePaths
      reports <- mapM (\p -> validateBytes p <$> BS.readFile p) paths
      let stats = [s | Report _ (Right s) <- reports]
      length stats `shouldBe` length paths
      stats `shouldSatisfy` all (\s -> stBudget s <= stCap s)
      stats `shouldSatisfy` all (\s -> stBudget s == sum (stPerEmitter s))
      stats `shouldSatisfy` all (\s -> stEmitters s == length (stPerEmitter s))

  describe "the zero-ripple law: a quiet directory changes nothing (§1.5)" $ do
    it "an untouched run is still func-spec 0013's run, frame for frame" $ do
      (stats, logR) <- runUnscanned
      reference <- referenceSummaries
      lsFrames stats `shouldBe` frames
      lsSimSteps stats `shouldBe` frames
      lsCasts stats `shouldBe` 1
      hlScenes logR `shouldBe` reference
      hlFlats logR `shouldBe` []
      map hvView (hlHuds logR) `shouldSatisfy` all (== View3D)

    it "and a run that DOES scan, and finds the same files, is the same run" $ do
      (scanned, scannedLog) <- runQuietlyScanned
      (still, stillLog) <- runUnscanned
      hlScenes scannedLog `shouldBe` hlScenes stillLog
      hlHuds scannedLog `shouldBe` hlHuds stillLog
      lsFrames scanned `shouldBe` lsFrames still
      lsSimSteps scanned `shouldBe` lsSimSteps still
      lsCasts scanned `shouldBe` lsCasts still
      lsFinalAge scanned `shouldBe` lsFinalAge still
