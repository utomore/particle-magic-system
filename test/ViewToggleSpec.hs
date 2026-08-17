-- | S4 (func-spec 0008 §8): the loop's view state machine.
--
-- Two things are asserted here. First, that Tab and V do what the demo
-- promises — including remembering the plane while still in 3D. Second,
-- and the point of the whole round: that switching the view is purely an
-- observation-side act. The simulation is driven by 'advanceSpell' and
-- sampled by 'observeSpell' regardless of which backend consumes the
-- result, so a run that toggles must produce, frame for frame, the same
-- batches as a run that never touches the keyboard (ADR-0008: the output
-- carries no dimension assumption).
module ViewToggleSpec (spec) where

import qualified Data.ByteString as BS
import Effectful (runPureEff)
import Data.List (isInfixOf)
import Magic.Interface (BlendMode, CastContext (..), Seed (..), V3 (..))
import Magic.Projection (ViewPlane (..))
import Test.Hspec

import App.Effects
  ( DemoInput (..)
  , FlatView (..)
  , HudView (..)
  , ReloadStatus (..)
  , ViewMode (..)
  , noInput
  , panelViewClosed
  )
import App.Hud (formatHud)
import App.Render.Post (noEffects)
import App.Loop
  ( LoopConfig (..)
  , LoopStats (..)
  , ViewState (..)
  , applyViewInput
  , defaultCamera
  , defaultViewState
  , flatViewFor
  , runLoop
  )
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScript
  , runRaylibHeadlessWith
  )

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = ["a.json"]
    , lcSpellIndex = 0
    , lcCamera = defaultCamera
    , lcCastCtx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 7}
    , lcWindowSize = (1280, 720)
    , lcWindowTitle = "headless"
    }

runDemo :: BS.ByteString -> [DemoInput] -> Int -> (LoopStats, HeadlessLog)
runDemo bytes inputs frames =
  runPureEff
    . runRaylibHeadlessWith inputs frames
    . runFileWatchScript bytes []
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

-- | @(frame, key)@ presses, idle everywhere else (the 0005 idiom).
script :: Int -> [(Int, DemoInput -> DemoInput)] -> [DemoInput]
script frames presses =
  [ foldr ($) noInput [f | (j, f) <- presses, j == k]
  | k <- [1 .. frames]
  ]

tab, vee :: DemoInput -> DemoInput
tab i = i {diToggleBackend = True}
vee i = i {diTogglePlane = True}

-- | A view state in a given backend and plane, everything else at its
-- default (func-spec 0013 widened 'applyViewInput' from the
-- @(mode, plane)@ pair to the whole observation state).
start :: ViewMode -> ViewPlane -> ViewState
start mode plane =
  (defaultViewState (1280, 720) defaultCamera)
    { vsMode = mode
    , vsPlane = plane
    , vsFlat = flatViewFor (1280, 720) plane
    }

-- | The pair the 0008 assertions were written against.
modeAfter :: DemoInput -> ViewState -> (ViewMode, ViewPlane)
modeAfter input vs = (vsMode vs', vsPlane vs')
  where
    vs' = applyViewInput input vs

-- | What each frame drew, in frame order, whichever backend drew it. The
-- HUD says which path a frame took, so the two logs can be zipped back
-- into one sequence.
perFrameSummary :: HeadlessLog -> [(BlendMode, Int)]
perFrameSummary logR = go (map hvView (hlHuds logR)) (hlScenes logR) (hlFlats logR)
  where
    go [] _ _ = []
    go (View3D : vs) (s : ss) fs = s : go vs ss fs
    go (View2D _ : vs) ss ((_, b, n) : fs) = (b, n) : go vs ss fs
    go _ _ _ = error "draw log does not line up with the HUD log"

fireBytes :: IO BS.ByteString
fireBytes = BS.readFile "assets/spells/ring-fire.json"

spec :: Spec
spec = do
  describe "applyViewInput (func-spec 0008 §4.4, widened by 0013 §4)" $ do
    it "Tab enters the 2D backend on the remembered plane, and leaves again" $ do
      modeAfter (tab noInput) (start View3D SideXY) `shouldBe` (View2D SideXY, SideXY)
      modeAfter (tab noInput) (start (View2D SideXY) SideXY) `shouldBe` (View3D, SideXY)

    it "V flips the plane in 2D" $ do
      modeAfter (vee noInput) (start (View2D SideXY) SideXY) `shouldBe` (View2D TopXZ, TopXZ)
      modeAfter (vee noInput) (start (View2D TopXZ) TopXZ) `shouldBe` (View2D SideXY, SideXY)

    it "V in 3D changes nothing on screen but is remembered for the next 2D visit" $ do
      modeAfter (vee noInput) (start View3D SideXY) `shouldBe` (View3D, TopXZ)

    it "idle input is the identity, on the whole view state" $ do
      applyViewInput noInput (start (View2D TopXZ) TopXZ) `shouldBe` start (View2D TopXZ) TopXZ
      applyViewInput noInput (start View3D SideXY) `shouldBe` start View3D SideXY

    it "both keys on one frame is defined: backend first, then plane" $
      modeAfter (tab (vee noInput)) (start View3D SideXY) `shouldBe` (View2D TopXZ, TopXZ)

    it "flipping the plane re-derives the 2D view for the new axes" $ do
      let flipped = applyViewInput (vee noInput) (start (View2D SideXY) SideXY)
      vsFlat flipped `shouldBe` flatViewFor (1280, 720) TopXZ

    it "the camera is untouched by the view keys" $ do
      let pressed = applyViewInput (tab (vee noInput)) (start View3D SideXY)
      vsCamera pressed `shouldBe` defaultCamera

  describe "flatViewFor" $ do
    it "keeps the window size and puts the side view's caster near the bottom" $ do
      let fv = flatViewFor (1280, 720) SideXY
      fvScreenSize fv `shouldBe` (1280, 720)
      fst (fvOrigin fv) `shouldBe` 640
      snd (fvOrigin fv) `shouldSatisfy` (> 360)

    it "centres the top view, where a formation spreads around the origin" $
      fvOrigin (flatViewFor (1280, 720) TopXZ) `shouldBe` (640, 360)

  describe "toggling the backend from the keyboard" $ do
    it "Tab switches the draw path, and switches it back" $ do
      bytes <- fireBytes
      let frames = 90
          (_, logR) = runDemo bytes (script frames [(30, tab), (60, tab)]) frames
      -- Frames 1..29 and 60..90 are 3D; 30..59 are 2D.
      length (hlScenes logR) `shouldBe` 29 + 31
      length (hlFlats logR) `shouldBe` 30
      map hvView (hlHuds logR)
        `shouldBe` replicate 29 View3D ++ replicate 30 (View2D SideXY) ++ replicate 31 View3D

    it "V switches the plane while in 2D" $ do
      bytes <- fireBytes
      let frames = 60
          (_, logR) = runDemo bytes (script frames [(10, tab), (30, vee)]) frames
          planes = map (\(p, _, _) -> p) (hlFlats logR)
      length planes `shouldBe` 51
      take 20 planes `shouldSatisfy` all (== SideXY)
      drop 20 planes `shouldSatisfy` all (== TopXZ)

    it "the plane is remembered across backends: V in 3D, then Tab, lands on top view" $ do
      bytes <- fireBytes
      let frames = 40
          (_, logR) = runDemo bytes (script frames [(5, vee), (20, tab)]) frames
      map (\(p, _, _) -> p) (hlFlats logR) `shouldSatisfy` all (== TopXZ)
      -- Nothing was drawn flat before the Tab.
      length (hlFlats logR) `shouldBe` 21

    it "every frame draws exactly once, through one path or the other" $ do
      bytes <- fireBytes
      let frames = 90
          (stats, logR) = runDemo bytes (script frames [(30, tab), (60, tab)]) frames
      lsFrames stats `shouldBe` frames
      length (hlScenes logR) + length (hlFlats logR) `shouldBe` frames
      hlDrawCalls logR `shouldBe` frames

  describe "the view is decoupled from the simulation" $ do
    it "toggling never re-casts the spell" $ do
      bytes <- fireBytes
      let frames = 90
          presses = [(20, tab), (35, vee), (50, tab), (70, vee)]
          (toggled, _) = runDemo bytes (script frames presses) frames
          (plain, _) = runDemo bytes (script frames []) frames
      lsCasts toggled `shouldBe` lsCasts plain
      lsSimSteps toggled `shouldBe` lsSimSteps plain
      lsFinalAge toggled `shouldBe` lsFinalAge plain

    it "produces the same batches frame for frame as a run that never toggles" $ do
      bytes <- fireBytes
      let frames = 120
          presses = [(20, tab), (35, vee), (50, tab), (70, tab), (100, vee)]
          (_, toggled) = runDemo bytes (script frames presses) frames
          (_, plain) = runDemo bytes (script frames []) frames
      perFrameSummary toggled `shouldBe` hlScenes plain
      map hvParticles (hlHuds toggled) `shouldBe` map hvParticles (hlHuds plain)

    it "the spell keeps ageing straight through a toggle" $ do
      bytes <- fireBytes
      let frames = 60
          (_, logR) = runDemo bytes (script frames [(30, tab)]) frames
          ages = map hvSpellAge (hlHuds logR)
      zipWith (\a b -> abs (a - b)) ages [fromIntegral k * (1 / 60) | k <- [1 .. frames :: Int]]
        `shouldSatisfy` all (< 1e-9)

  describe "the HUD reports the live view" $ do
    it "names the backend and the plane" $ do
      let says view = unlines (formatHud (baseHud {hvView = view}))
      says View3D `shouldSatisfy` ("view: 3D" `isInfixOf`)
      says (View2D SideXY) `shouldSatisfy` ("2D side (X/Y)" `isInfixOf`)
      says (View2D TopXZ) `shouldSatisfy` ("2D top (X/Z)" `isInfixOf`)

    it "documents the keys that switch it" $ do
      let out = unlines (formatHud baseHud)
      out `shouldSatisfy` ("[Tab]" `isInfixOf`)
      out `shouldSatisfy` ("[V]" `isInfixOf`)

    it "matches the path the frame actually took" $ do
      bytes <- fireBytes
      let frames = 40
          (_, logR) = runDemo bytes (script frames [(10, tab), (25, vee)]) frames
          huds = hlHuds logR
      hvView (huds !! 8) `shouldBe` View3D
      hvView (huds !! 9) `shouldBe` View2D SideXY
      hvView (huds !! 24) `shouldBe` View2D TopXZ

baseHud :: HudView
baseHud =
  HudView
    { hvFps = 60
    , hvParticles = 0
    , hvSpellPath = "a.json"
    , hvSpellAge = 0
    , hvReload = ReloadIdle
    , hvView = View3D
    , hvCamera = defaultCamera
    , hvFlat = flatViewFor (1280, 720) SideXY
    , hvVisual = noEffects
    , hvPanel = panelViewClosed
    }
