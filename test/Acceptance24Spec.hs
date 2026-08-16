{-# LANGUAGE OverloadedStrings #-}

-- | S6 (func-spec 0024 §6): end-to-end acceptance of the second authoring
-- round.
--
-- Four claims, one per thing the round delivered, plus the one that ties
-- them together.
--
--   * @magic-schema --check@ is green against the repository as it stands,
--     so the committed schema is the generator's output and an external
--     tool chain pointing at it is pointing at the truth.
--   * @magic-inspect@ reports on every shipped example without failing.
--   * @magic-validate --json@ does the same, and agrees with itself.
--   * the two tools agree with each other, which is the point of their
--     sharing 'Validate.defaultContext' rather than each having one.
--   * and a run that drives the panel is deterministic over 240 frames —
--     the panel is the first shell feature that touches the simulation, so
--     "the same keys produce the same frames" is a claim that had to be
--     made fresh for it.
module Acceptance24Spec (spec) where

import Data.Aeson (Value (Array, Bool, Object), decodeStrict)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Foldable (toList)
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as M
import Effectful (runPureEff)
import System.Directory (listDirectory)
import Test.Hspec

import Magic.Codec (loadCircle)
import Magic.Interface (CastContext (..), Circle, Seed (..), V3 (..))

import App.Effects (DemoInput (..), HudView (..), PanelView (..), noInput)
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.TestInterp
  ( HeadlessLog (..)
  , WriteLog
  , runClockVirtual
  , runFileWatchScriptWrites
  , runRaylibHeadlessWith
  )
import Inspect (inspectReport)
import Schema (SchemaOptions (..), generateSchema, normalizeNewlines, parseSchemaArgs)
import Validate (Report (..), Stats (..), exitCodeFor, renderJsonReport, validateBytes)

spellDir :: FilePath
spellDir = "assets/spells"

schemaPath :: FilePath
schemaPath = "docs/spell.schema.json"

demoSpell :: FilePath
demoSpell = spellDir ++ "/grand-sigil.json"

-- | 240 frames at 1/60 is four seconds: past grand-sigil's 1.8s prelude,
-- so the run covers drawing, converging and casting, and long enough that
-- a difference anywhere would have somewhere to show up.
frames :: Int
frames = 240

examplePaths :: IO [FilePath]
examplePaths = do
  entries <- listDirectory spellDir
  pure [spellDir ++ "/" ++ e | e <- sort entries, ".json" `isSuffixOf` e]

loadFile :: FilePath -> IO Circle
loadFile path = do
  bytes <- BS.readFile path
  either (fail . show) pure (loadCircle bytes)

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = [demoSpell]
    , lcSpellIndex = 0
    , lcCamera = defaultCamera
    , lcCastCtx =
        CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}
    , lcWindowSize = (1280, 720)
    , lcWindowTitle = "acceptance-0024"
    }

-- | Open the panel, walk the selection along, nudge in both directions,
-- and save — the session an author actually has, as a key script.
editSession :: [DemoInput]
editSession =
  concat
    [ [noInput {diTogglePanel = True}]
    , concat
        [ [ noInput {diPanelNext = True}
          , noInput {diPanelInc = True}
          , noInput {diPanelInc = True}
          , noInput
          , noInput {diPanelDec = True}
          , noInput
          ]
        | _ <- [1 :: Int .. 6]
        ]
    , [noInput {diPanelSave = True}]
    ]

runSession :: IO (LoopStats, HeadlessLog, WriteLog)
runSession = do
  bytes <- BS.readFile demoSpell
  let ((stats, logR), writes) =
        runPureEff
          . runFileWatchScriptWrites (M.singleton demoSpell (bytes, [])) []
          . runRaylibHeadlessWith (editSession ++ repeat noInput) frames
          . runClockVirtual (1 / 60)
          $ runLoop testConfig
  pure (stats, logR, writes)

spec :: Spec
spec = do
  describe "magic-schema against the repository (func-spec 0024 S1)" $ do
    it "--check with no path means the committed schema" $
      parseSchemaArgs ["--check"] `shouldBe` Right (SchemaCheck schemaPath)

    it "and it agrees with the generator, so --check exits 0" $ do
      onDisk <- BS.readFile schemaPath
      normalizeNewlines onDisk `shouldBe` normalizeNewlines generateSchema

  describe "magic-inspect against the shipped assets (S2)" $ do
    it "reports on every example the demo cycles through" $ do
      paths <- examplePaths
      circles <- mapM loadFile paths
      let reports = map inspectReport circles
      length reports `shouldSatisfy` (>= 16)
      [p | (p, Left _) <- zip paths reports] `shouldBe` []

    it "and every report has all four sections" $ do
      paths <- examplePaths
      circles <- mapM loadFile paths
      let headings ls = [l | l <- ls, not (null l), take 1 l /= " "]
      sequence_
        [ headings ls `shouldBe` ["spell", "timeline", "emitters", "batches"]
        | Right ls <- map inspectReport circles
        ]

  describe "magic-validate --json against the shipped assets (S3)" $ do
    it "passes every example, and says so in JSON" $ do
      paths <- examplePaths
      reports <- mapM (\p -> validateBytes p <$> BS.readFile p) paths
      exitCodeFor reports `shouldBe` 0
      let out = renderJsonReport True reports
      case decodeStrict (BSC.pack out) of
        Just (Object o)
          | Just (Array files) <- KM.lookup "files" o -> do
              length (toList files) `shouldBe` length paths
              [okOf f | f <- toList files] `shouldSatisfy` all (== Just True)
              KM.lookup "failed" o `shouldBe` decodeStrict "0"
        _ -> expectationFailure "the --json report is not the expected shape"

  -- The reason the two tools share a context instead of each defining
  -- one: an author who reads a budget in one and a budget in the other
  -- must not have to wonder which is right.
  it "and the two tools report the same budget for every example (S2 + S3)" $ do
    paths <- examplePaths
    circles <- mapM loadFile paths
    reports <- mapM (\p -> validateBytes p <$> BS.readFile p) paths
    let fromValidate = [stBudget s | Report _ (Right s) <- reports]
        fromInspect =
          [ n
          | Right ls <- map inspectReport circles
          , l <- ls
          , ("budget" : total : _) <- [words l]
          , (n, "") <- reads total :: [(Int, String)]
          ]
    length fromInspect `shouldBe` length paths
    fromInspect `shouldBe` fromValidate

  describe "a panel session is deterministic (S6)" $ do
    it "the same keys produce the same 240 frames, twice" $ do
      (statsA, logA, writesA) <- runSession
      (statsB, logB, writesB) <- runSession
      lsFrames statsA `shouldBe` frames
      statsA `shouldBe` statsB
      hlScenes logA `shouldBe` hlScenes logB
      hlFrames3D logA `shouldBe` hlFrames3D logB
      hlHuds logA `shouldBe` hlHuds logB
      writesA `shouldBe` writesB

    it "and the session did what it was told: it edited, and it saved" $ do
      (stats, logR, writes) <- runSession
      -- Twelve up-nudges and six down ones, each a re-cast, plus the
      -- initial cast.
      lsCasts stats `shouldBe` 19
      map fst writes `shouldBe` [demoSpell]
      -- The panel is open from the first frame to the last, and by the
      -- end there is nothing outstanding.
      map pvOpen (panelsOf logR) `shouldSatisfy` all id
      map pvDirty (panelsOf logR) `shouldSatisfy` (not . lastOr True)

    it "and the file it wrote is a spell file the codec reads back" $ do
      (_, _, writes) <- runSession
      [loadCircle bytes | (_, bytes) <- writes] `shouldSatisfy` all isRight

panelsOf :: HeadlessLog -> [PanelView]
panelsOf = map hvPanel . hlHuds

okOf :: Value -> Maybe Bool
okOf value = case value of
  Object o | Just (Bool b) <- KM.lookup "ok" o -> Just b
  _ -> Nothing

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

lastOr :: Bool -> [Bool] -> Bool
lastOr fallback xs = case reverse xs of
  (x : _) -> x
  [] -> fallback
