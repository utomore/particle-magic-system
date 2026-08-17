-- | S5 (func-spec 0024 §6): the panel's save, and how it meets hot reload.
--
-- __Why this one hits a real disk.__ func-spec 0014 §9.2 recorded the
-- lesson the hard way: a law of the form "the IO side produces it, the
-- pure side compares it equal" is not tested by a test that models the IO
-- side. The round-trip below therefore writes an actual file with the
-- actual writer the demo uses, reads it back with 'BS.readFile', and
-- compares the decoded circle — no interpreter anywhere in the chain.
--
-- The confluence rules (func-spec 0024 §2.5) are the other half, and those
-- ARE headless: what is being asserted there is the loop's arbitration
-- between the panel and the watcher, which is a decision, not an effect.
module PanelWriteBackSpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Effectful (runPureEff)
import System.Directory
  ( createDirectoryIfMissing
  , getPermissions
  , getTemporaryDirectory
  , listDirectory
  , setOwnerWritable
  , setPermissions
  )
import Test.Hspec

import Magic.Codec (loadCircle, saveCircle)
import Magic.Interface (Circle, CastContext (..), Seed (..), V3 (..))

import App.Effects (DemoInput (..), HudView (..), PanelView (..), noInput)
import App.HotReload (writeBytesIO)
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.Panel (ParamSpec (..), applyParam, discardedNote, paramsOf, savedNote)
import App.TestInterp
  ( HeadlessLog (..)
  , WriteLog
  , runClockVirtual
  , runFileWatchScriptWrites
  , runRaylibHeadlessWith
  )

spellDir :: FilePath
spellDir = "assets/spells"

demoSpell :: FilePath
demoSpell = spellDir ++ "/grand-sigil.json"

otherSpell :: FilePath
otherSpell = spellDir ++ "/ring-fire.json"

frames :: Int
frames = 40

testConfig :: [FilePath] -> LoopConfig
testConfig paths =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = paths
    , lcSpellIndex = 0
    , lcCamera = defaultCamera
    , lcCastCtx =
        CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}
    , lcWindowSize = (1280, 720)
    , lcWindowTitle = "writeback"
    }

loadFile :: FilePath -> IO Circle
loadFile path = do
  bytes <- BS.readFile path
  either (fail . show) pure (loadCircle bytes)

spec :: Spec
spec = do
  describe "the round-trip law, against a real filesystem (func-spec 0024 S5)" $ do
    it "an edited circle written with saveCircle reads back equal" $ do
      dir <- scratchDir
      circle <- loadFile demoSpell
      let edited = nudgeEvery circle
          path = dir ++ "/roundtrip.json"
      result <- writeBytesIO path (saveCircle edited)
      result `shouldBe` Right ()
      onDisk <- BS.readFile path
      loadCircle onDisk `shouldBe` Right edited

    -- Every shipped example, not one: the law has to hold for the shapes,
    -- the fields and the anchors too, and those live in different files.
    it "and so does every shipped example, edited the same way" $ do
      dir <- scratchDir
      names <- listDirectory spellDir
      let jsons = [spellDir ++ "/" ++ n | n <- names, ".json" `isSuffix` n]
      forM_ (zip [0 :: Int ..] jsons) $ \(i, source) -> do
        circle <- loadFile source
        let edited = nudgeEvery circle
            path = dir ++ "/example-" ++ show i ++ ".json"
        _ <- writeBytesIO path (saveCircle edited)
        onDisk <- BS.readFile path
        loadCircle onDisk `shouldBe` Right edited

    it "leaves no temp file behind" $ do
      dir <- scratchDir
      circle <- loadFile demoSpell
      _ <- writeBytesIO (dir ++ "/clean.json") (saveCircle circle)
      entries <- listDirectory dir
      [e | e <- entries, ".tmp" `isSuffix` e] `shouldBe` []

    -- The one outcome a tool that writes an author's spell must never
    -- have: the old file gone and the new one not there either.
    it "does not damage the original when the write fails" $ do
      dir <- scratchDir
      circle <- loadFile demoSpell
      let path = dir ++ "/readonly.json"
      before <- pure (saveCircle circle)
      _ <- writeBytesIO path before
      readOnly path
      let other = nudgeEvery circle
      result <- writeBytesIO path (saveCircle other)
      writable path
      case result of
        Right () ->
          -- Some filesystems let a rename replace a read-only file. Then
          -- there was no failure to survive, and the file must be the NEW
          -- one, whole -- which is the same promise from the other side.
          BS.readFile path `shouldReturn` saveCircle other
        Left _ -> do
          BS.readFile path `shouldReturn` before
          entries <- listDirectory dir
          [e | e <- entries, ".tmp" `isSuffix` e] `shouldBe` []

  describe "the panel and hot reload, arbitrated (§2.5)" $ do
    it "a panel edit changes the circle and never the file" $ do
      (_, logR, writes) <- runPanel [demoSpell] (openThen [nudge]) []
      writes `shouldBe` []
      dirtyFrames logR `shouldSatisfy` (> 0)

    it "[S] writes the circle the panel is holding, in canonical form" $ do
      circle <- loadFile demoSpell
      (_, _, writes) <- runPanel [demoSpell] (openThen [nudge, save]) []
      map fst writes `shouldBe` [demoSpell]
      -- What was written is a legal spell file, and it is the edited
      -- circle rather than the one on disk.
      case map snd writes of
        [bytes] -> do
          loadCircle bytes `shouldSatisfy` isRight
          loadCircle bytes `shouldNotBe` Right circle
        other -> expectationFailure ("expected one write, got " ++ show (length other))

    it "and says so, and stops calling itself unsaved" $ do
      (_, logR, _) <- runPanel [demoSpell] (openThen [nudge, save]) []
      notesOf logR `shouldSatisfy` elem (savedNote demoSpell)
      -- The last frame is after the save, so nothing is outstanding.
      map pvDirty (panelsOf logR) `shouldSatisfy` (not . last')

    -- The second-jump rule. Saving makes the watcher fire; reloading then
    -- would re-cast, and a re-cast restarts the spell at age zero for no
    -- reason the author can see.
    it "does not re-cast when the watcher reports the save it caused" $ do
      (saved, _, _) <- runPanel [demoSpell] (openThen [nudge, save]) [False, False, False, True]
      (unsavedRun, _, _) <- runPanel [demoSpell] (openThen [nudge]) [False, False, False, False]
      -- One cast at startup, one for the adjustment, and no third.
      lsCasts saved `shouldBe` 2
      lsCasts unsavedRun `shouldBe` 2

    -- ... but a change the loop did NOT cause still wins, and takes the
    -- unsaved edits with it.
    it "reloads on an external change, discarding unsaved edits and saying so" $ do
      (external, logR, writes) <- runPanel [demoSpell] (openThen [nudge]) [False, False, True]
      writes `shouldBe` []
      lsCasts external `shouldBe` 3
      notesOf logR `shouldSatisfy` elem (discardedNote "the file changed on disk")
      map pvDirty (panelsOf logR) `shouldSatisfy` (not . last')

    it "discards unsaved edits when the spell is switched, and never auto-saves" $ do
      (_, logR, writes) <- runPanel [demoSpell, otherSpell] (openThen [nudge, nextSpell]) []
      writes `shouldBe` []
      notesOf logR `shouldSatisfy` elem (discardedNote "switched spell")

-- Fixtures ---------------------------------------------------------------------

-- | Move every parameter one step up. A single edit would leave most of
-- the schema untested; this one exercises every numeric field the file
-- has, which is what makes the round-trip law worth stating.
nudgeEvery :: Circle -> Circle
nudgeEvery circle0 = go circle0 (map psPath (paramsOf circle0))
  where
    go circle [] = circle
    go circle (path : rest) = case [s | s <- paramsOf circle, psPath s == path] of
      (spec : _) -> go (applyParam path (psValue spec + psStep spec) circle) rest
      [] -> go circle rest

openThen :: [DemoInput] -> [DemoInput]
openThen rest = noInput {diTogglePanel = True} : rest

nudge :: DemoInput
nudge = noInput {diPanelInc = True}

save :: DemoInput
save = noInput {diPanelSave = True}

nextSpell :: DemoInput
nextSpell = noInput {diNextSpell = True}

-- | A headless run with writes that are real to the interpreter: written
-- bytes come back from the next read, so a reload after a save lands on
-- what was saved.
runPanel
  :: [FilePath]
  -> [DemoInput]
  -> [Bool]
  -> IO (LoopStats, HeadlessLog, WriteLog)
runPanel paths inputs changeScript = do
  table <- mapM (\p -> (,) p . (\b -> (b, changeScript)) <$> BS.readFile p) paths
  let ((stats, logR), writes) =
        runPureEff
          . runFileWatchScriptWrites (M.fromList table) []
          . runRaylibHeadlessWith (inputs ++ repeat noInput) frames
          . runClockVirtual (1 / 60)
          $ runLoop (testConfig paths)
  pure (stats, logR, writes)

panelsOf :: HeadlessLog -> [PanelView]
panelsOf = map hvPanel . hlHuds

notesOf :: HeadlessLog -> [String]
notesOf = mapMaybe pvNote . panelsOf

dirtyFrames :: HeadlessLog -> Int
dirtyFrames = length . filter pvDirty . panelsOf

-- Small helpers ----------------------------------------------------------------

isSuffix :: String -> String -> Bool
isSuffix suffix s = length s >= length suffix && drop (length s - length suffix) s == suffix

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

last' :: [Bool] -> Bool
last' xs = case reverse xs of
  (x : _) -> x
  [] -> False

readOnly :: FilePath -> IO ()
readOnly path = do
  perms <- getPermissions path
  setPermissions path (setOwnerWritable False perms)

writable :: FilePath -> IO ()
writable path = do
  perms <- getPermissions path
  setPermissions path (setOwnerWritable True perms)

-- | A scratch directory of this suite's own.
scratchDir :: IO FilePath
scratchDir = do
  tmp <- getTemporaryDirectory
  let dir = tmp ++ "/particle-magic-panel-0024"
  createDirectoryIfMissing True dir
  pure dir

