-- | S4 (func-spec 0024 §6): the parameter panel's pure half.
--
-- The panel is the first thing in this demo that can change what is
-- /simulated/ — everything added since func-spec 0008 was observation-side
-- and therefore harmless by construction. So the laws below are about
-- containment: an adjustment changes exactly one number, never the shape
-- of the circle; a value that would break the codec is refused rather than
-- adopted; and with the panel closed the whole feature is not there.
module ParamPanelSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import Effectful (runPureEff)
import System.Directory (listDirectory)
import Test.Hspec
import Test.QuickCheck

import Magic.Codec (loadCircle, saveCircle)
import Magic.Interface (Circle, emptyCircle)

import App.Effects (DemoInput (..), HudView (..), PanelView (..), noInput, panelViewClosed)
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.Panel
  ( PanelAction (..)
  , ParamPath
  , PanelState (..)
  , ParamSpec (..)
  , applyParam
  , panelClosed
  , paramsOf
  , stepPanel
  )
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScript
  , runRaylibHeadlessWith
  )
import Magic.Interface (CastContext (..), Seed (..), V3 (..))

spellDir :: FilePath
spellDir = "assets/spells"

frames :: Int
frames = 90

demoSpell :: FilePath
demoSpell = spellDir ++ "/grand-sigil.json"

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
    , lcWindowTitle = "panel"
    }

examplePaths :: IO [FilePath]
examplePaths = do
  entries <- listDirectory spellDir
  pure [spellDir ++ "/" ++ e | e <- sort entries, ".json" `isSuffixOf` e]

loadExample :: FilePath -> IO Circle
loadExample path = do
  bytes <- BS.readFile path
  either (fail . show) pure (loadCircle bytes)

-- | Only the panel keys, so a run can press them without pressing
-- anything else.
panelInput :: DemoInput
panelInput = noInput

openPanel :: DemoInput
openPanel = panelInput {diTogglePanel = True}

-- | Every key the panel owns except the one that opens it. Pressing these
-- with the panel shut is what the zero-input law is about.
allPanelKeys :: DemoInput
allPanelKeys =
  panelInput
    { diPanelPrev = True
    , diPanelNext = True
    , diPanelDec = True
    , diPanelInc = True
    , diPanelSave = True
    }

runWith :: [DemoInput] -> IO (LoopStats, HeadlessLog)
runWith inputs = do
  bytes <- BS.readFile demoSpell
  pure
    . runPureEff
    . runRaylibHeadlessWith inputs frames
    . runFileWatchScript bytes []
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

spec :: Spec
spec = do
  circles <- runIO (mapM loadExample =<< examplePaths)
  grand <- runIO (loadExample demoSpell)

  describe "paramsOf (func-spec 0024 S4)" $ do
    it "lists nothing for a circle with no slots" $ do
      paramsOf emptyCircle `shouldBe` []

    it "lists only numbers that are actually in the file" $ do
      let labels = map psLabel (paramsOf grand)
      -- grand-sigil has a ring shape, a phase shift, a spiral, an
      -- envelope, an essence, two node biases and staging.
      labels
        `shouldMatchList` [ "outer[0].shape.rInner"
                          , "outer[0].shape.rOuter"
                          , "bridge.shift"
                          , "inner[0].freq"
                          , "inner[0].radius"
                          , "inner[0].speed"
                          , "inner[1].delay"
                          , "inner[1].duration"
                          , "inner[1].lifetime"
                          , "core.center.power"
                          , "core.nodes.east.strength"
                          , "core.nodes.north.strength"
                          , "phases.converge"
                          , "phases.draw"
                          ]

    it "and its order is stable" $
      map psLabel (paramsOf grand) `shouldBe` map psLabel (paramsOf grand)

    it "reports each number's current value" $ do
      let value label = [psValue s | s <- paramsOf grand, psLabel s == label]
      value "outer[0].shape.rInner" `shouldBe` [1.0]
      value "outer[0].shape.rOuter" `shouldBe` [1.5]
      value "core.center.power" `shouldBe` [1.5]
      value "phases.draw" `shouldBe` [1.2]

  describe "applyParam" $ do
    -- Idempotence holds outright: applying the same request twice is
    -- applying it once, whether or not the codec took it.
    it "is idempotent" $
      property $ \(NonNegative i) (v :: Double) ->
        forAll (elements circles) $ \circle ->
          let specs = paramsOf circle
           in not (null specs) ==>
                let path = psPath (specs !! (i `mod` length specs))
                 in applyParam path v (applyParam path v circle)
                      === applyParam path v circle

    -- Overwrite is the same law with a condition the codec puts on it: a
    -- request the codec refuses leaves the circle as it was, so it cannot
    -- also erase the one before it. Guarded on both applications being
    -- adopted, which is what "the panel moved the slider" means; the
    -- refusal case has its own example below.
    it "overwrites rather than accumulates, whenever both values are adopted" $
      property $ \(NonNegative i) (v :: Double) (v' :: Double) ->
        forAll (elements circles) $ \circle ->
          let specs = paramsOf circle
           in not (null specs) ==>
                let spec = specs !! (i `mod` length specs)
                    path = psPath spec
                    once = applyParam path v circle
                    intermediate = applyParam path v' circle
                 in adopted spec v circle
                      && adopted spec v intermediate
                      ==> applyParam path v intermediate === once

    it "changes the value it was asked to change" $ do
      let [radius] = [s | s <- paramsOf grand, psLabel s == "outer[0].shape.rOuter"]
          circle' = applyParam (psPath radius) 2.25 grand
      [psValue s | s <- paramsOf circle', psLabel s == "outer[0].shape.rOuter"]
        `shouldBe` [2.25]

    it "and leaves every other value alone" $ do
      let [radius] = [s | s <- paramsOf grand, psLabel s == "outer[0].shape.rOuter"]
          circle' = applyParam (psPath radius) 2.25 grand
          others c = [(psLabel s, psValue s) | s <- paramsOf c, psLabel s /= "outer[0].shape.rOuter"]
      others circle' `shouldBe` others grand

    -- The containment law: a number moved, never a slot added, removed or
    -- retyped. Asserted on the parameter set itself, which IS the slot
    -- occupancy as far as anything numeric is concerned.
    it "never changes the circle's structure" $
      property $ \(NonNegative i) (v :: Double) ->
        forAll (elements circles) $ \circle ->
          let specs = paramsOf circle
           in not (null specs) ==>
                let path = psPath (specs !! (i `mod` length specs))
                 in map psLabel (paramsOf (applyParam path v circle)) === map psLabel specs

    it "clamps to the parameter's range" $
      property $ \(NonNegative i) (v :: Double) ->
        forAll (elements circles) $ \circle ->
          let specs = paramsOf circle
           in not (null specs) ==>
                let spec = specs !! (i `mod` length specs)
                    circle' = applyParam (psPath spec) v circle
                    after = [psValue s | s <- paramsOf circle', psPath s == psPath spec]
                 in all (\x -> x >= psMin spec - 1e-9 && x <= psMax spec + 1e-9) after

    -- The panel proposes; the codec disposes. Pushing the inner radius
    -- past the outer one is the clearest case: rather than building a
    -- circle 'saveCircle' would write and 'loadCircle' would then refuse,
    -- the adjustment simply does not take.
    it "refuses a value the codec would reject, leaving the circle as it was" $ do
      let [inner] = [s | s <- paramsOf grand, psLabel s == "outer[0].shape.rInner"]
          circle' = applyParam (psPath inner) 4.0 grand
      circle' `shouldBe` grand

    it "and every circle it produces still round-trips through the codec" $
      property $ \(NonNegative i) (v :: Double) ->
        forAll (elements circles) $ \circle ->
          let specs = paramsOf circle
           in not (null specs) ==>
                let path = psPath (specs !! (i `mod` length specs))
                    circle' = applyParam path v circle
                 in loadCircle (saveCircle circle') === Right circle'

  describe "the panel's state machine" $ do
    it "starts closed, and [P] opens it" $ do
      let (st1, _, _) = stepPanel openPanel grand panelClosed
      pnOpen panelClosed `shouldBe` False
      pnOpen st1 `shouldBe` True

    it "and [P] again closes it" $ do
      let (st1, _, _) = stepPanel openPanel grand panelClosed
          (st2, _, _) = stepPanel openPanel grand st1
      pnOpen st2 `shouldBe` False

    it "wraps the selection at both ends" $ do
      let open = panelClosed {pnOpen = True}
          n = length (paramsOf grand)
          next s = let (s', _, _) = stepPanel panelInput {diPanelNext = True} grand s in s'
          prev s = let (s', _, _) = stepPanel panelInput {diPanelPrev = True} grand s in s'
      pnIndex (prev open) `shouldBe` n - 1
      pnIndex (iterate next open !! n) `shouldBe` 0

    it "moves the selected value by one step and asks for a re-cast" $ do
      let open = panelClosed {pnOpen = True}
          spec = case paramsOf grand of { (s : _) -> s; [] -> error "grand-sigil has parameters" }
          (st', circle', action) = stepPanel panelInput {diPanelInc = True} grand open
      action `shouldBe` PanelRecast
      pnDirty st' `shouldBe` True
      [psValue s | s <- paramsOf circle', psPath s == psPath spec]
        `shouldBe` [psValue spec + psStep spec]

    it "asks for a save when [S] is pressed, without changing the circle" $ do
      let open = panelClosed {pnOpen = True}
          (_, circle', action) = stepPanel panelInput {diPanelSave = True} grand open
      action `shouldBe` PanelSave
      circle' `shouldBe` grand

    -- The zero-input law, at the level of the state machine: with the
    -- panel shut, every key it owns is inert.
    it "ignores every panel key while it is closed" $ do
      let (st', circle', action) = stepPanel allPanelKeys grand panelClosed
      st' `shouldBe` panelClosed
      circle' `shouldBe` grand
      action `shouldBe` PanelIdle

  describe "the zero-input law, at the level of the frame (§S4)" $ do
    it "a run that presses every panel key, panel shut, draws the idle run" $ do
      (idleStats, idleLog) <- runWith (replicate frames noInput)
      (keyedStats, keyedLog) <- runWith (replicate frames allPanelKeys)
      hlScenes keyedLog `shouldBe` hlScenes idleLog
      hlFrames3D keyedLog `shouldBe` hlFrames3D idleLog
      hlDrawCalls keyedLog `shouldBe` hlDrawCalls idleLog
      lsCasts keyedStats `shouldBe` lsCasts idleStats
      lsFinalAge keyedStats `shouldBe` lsFinalAge idleStats

    it "and reports the panel closed on every frame of it" $ do
      (_, keyedLog) <- runWith (replicate frames allPanelKeys)
      map hvPanel (hlHuds keyedLog) `shouldSatisfy` all (== panelViewClosed)

    it "while a run that opens it reports it open, with its parameters" $ do
      (_, openedLog) <- runWith (openPanel : replicate (frames - 1) noInput)
      let panels = map hvPanel (hlHuds openedLog)
      panels `shouldSatisfy` all pvOpen
      map (length . pvParams) panels
        `shouldSatisfy` all (== length (paramsOf grand))


-- | Did the codec take this request?
--
-- Either the circle moved, or it was already exactly where the request
-- would have put it. A /refused/ request leaves the circle alone AND
-- leaves the value somewhere other than the clamped target, so the two
-- cases cannot be confused — except when six-decimal rounding lands
-- between them, which shows up as a discard rather than a false pass.
adopted :: ParamSpec -> Double -> Circle -> Bool
adopted spec v circle =
  applyParam path v circle /= circle
    || valueAt path circle == Just (min (psMax spec) (max (psMin spec) v))
  where
    path = psPath spec

valueAt :: ParamPath -> Circle -> Maybe Double
valueAt path circle = case [psValue s | s <- paramsOf circle, psPath s == path] of
  (x : _) -> Just x
  [] -> Nothing
