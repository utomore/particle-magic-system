-- | S7 (func-spec 0013 §7): end-to-end acceptance of the observation
-- controls, headless.
--
-- The round added a camera, a pan, a zoom and a tint to a demo whose
-- whole claim to correctness is that observation cannot touch
-- simulation. So there are two things to prove, and they pull in
-- opposite directions.
--
-- The zero-input law: a run nobody touches must produce exactly what
-- func-spec 0008 delivered — same frames, same casts, same per-frame
-- batches, and a view state that never moved off its defaults. Every
-- control added here is the identity on idle input, by construction, and
-- this is where that is cashed in end to end.
--
-- The decoupling law: a run that orbits, zooms, pans, switches backend
-- and flips the tint must produce the *same simulation* as the untouched
-- one, frame for frame — while visibly moving the view. A control that
-- changed nothing would pass the first law trivially, so both are
-- asserted against the same script.
module Acceptance13Spec (spec) where

import qualified Data.ByteString as BS
import Effectful (runPureEff)
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
import Magic.Projection (ViewPlane (..))
import Test.Hspec

import App.Camera (toOrbit, obRadius)
import App.Effects
  ( Camera (..)
  , DemoInput (..)
  , FlatView (..)
  , HudView (..)
  , ViewMode (..)
  , noInput
  )
import App.Loop
  ( LoopConfig (..)
  , LoopStats (..)
  , defaultCamera
  , flatViewFor
  , runLoop
  )
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScript
  , runRaylibHeadlessWith
  )

frames :: Int
frames = 120

windowSize :: (Int, Int)
windowSize = (1280, 720)

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = ["fire.json"]
    , lcSpellIndex = 0
    , lcCamera = defaultCamera
    , lcCastCtx = ctx
    , lcWindowSize = windowSize
    , lcWindowTitle = "acceptance"
    }

script :: [(Int, DemoInput -> DemoInput)] -> [DemoInput]
script presses =
  [ foldr ($) noInput [f | (j, f) <- presses, j == k]
  | k <- [1 .. frames]
  ]

tab, vee, tee :: DemoInput -> DemoInput
tab i = i {diToggleBackend = True}
vee i = i {diTogglePlane = True}
tee i = i {diToggleTint = True}

drag :: (Float, Float) -> DemoInput -> DemoInput
drag d i = i {diOrbitDrag = Just d, diPanDrag = Just d}

wheel :: Float -> DemoInput -> DemoInput
wheel w i = i {diWheel = w, diCursor = (640, 360)}

runDemo :: [DemoInput] -> IO (LoopStats, HeadlessLog)
runDemo inputs = do
  bytes <- BS.readFile "assets/spells/ring-fire.json"
  pure
    . runPureEff
    . runRaylibHeadlessWith inputs frames
    . runFileWatchScript bytes []
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

-- | The spell aged exactly the way the loop ages it, sampled once per
-- frame — the reference every run is checked against (the 0008 idiom).
referenceSummaries :: IO [(BlendMode, Int)]
referenceSummaries = do
  bytes <- BS.readFile "assets/spells/ring-fire.json"
  circle <- either (fail . show) pure (loadCircle bytes)
  spell0 <- either (fail . show) pure (castSpell (CastRequest circle ctx))
  let dt = FrameInput (DeltaTime (1 / 60))
      ages :: [ActiveSpell]
      ages = drop 1 (iterate (advanceSpell dt) spell0)
      summarize out = [(rbBlend b, pbCount (rbParticles b)) | b <- batches out]
  pure (concatMap (summarize . observeSpell) (take frames ages))

-- | What each frame drew, in frame order, whichever backend drew it.
perFrameSummary :: HeadlessLog -> [(BlendMode, Int)]
perFrameSummary logR = go (map hvView (hlHuds logR)) (hlScenes logR) (hlFlats logR)
  where
    go [] _ _ = []
    go (View3D : vs) (s : ss) fs = s : go vs ss fs
    go (View2D _ : vs) ss ((_, b, n) : fs) = (b, n) : go vs ss fs
    go _ _ _ = error "draw log does not line up with the HUD log"

-- | A run that exercises every control this round added.
steered :: [DemoInput]
steered =
  script $
    [(k, drag (12, -5)) | k <- [10 .. 20]]
      ++ [(25, wheel 3)]
      ++ [(40, tab), (45, tee)]
      ++ [(k, drag (7, 4)) | k <- [50 .. 60]]
      ++ [(65, wheel (-2)), (70, vee)]
      ++ [(90, tab), (100, wheel 1)]

spec :: Spec
spec = do
  describe "the zero-input law (func-spec 0013 §1-6)" $ do
    it "an untouched run is still func-spec 0008's run, frame for frame" $ do
      (stats, logR) <- runDemo (script [])
      reference <- referenceSummaries
      lsFrames stats `shouldBe` frames
      lsSimSteps stats `shouldBe` frames
      lsCasts stats `shouldBe` 1
      hlScenes logR `shouldBe` reference
      hlFlats logR `shouldBe` []
      map hvView (hlHuds logR) `shouldSatisfy` all (== View3D)

    it "leaves the camera exactly where the config put it, every frame" $ do
      (_, logR) <- runDemo (script [])
      map hvCamera (hlHuds logR) `shouldSatisfy` all (== defaultCamera)

    it "leaves the 2D view at func-spec 0008's constants, every frame" $ do
      (_, logR) <- runDemo (script [])
      map hvFlat (hlHuds logR) `shouldSatisfy` all (== flatViewFor windowSize SideXY)

    it "keeps the depth tint off, so the flat colours are 0008's" $ do
      (_, logR) <- runDemo (script [])
      map (fvDepthTint . hvFlat) (hlHuds logR) `shouldSatisfy` all (== 0)

  describe "the decoupling law: steering the view never touches the spell" $ do
    it "produces the same batches frame for frame as the untouched run" $ do
      (_, moved) <- runDemo steered
      (_, still) <- runDemo (script [])
      perFrameSummary moved `shouldBe` hlScenes still
      map hvParticles (hlHuds moved) `shouldBe` map hvParticles (hlHuds still)

    it "casts, steps and ages identically" $ do
      (moved, _) <- runDemo steered
      (still, _) <- runDemo (script [])
      lsCasts moved `shouldBe` lsCasts still
      lsSimSteps moved `shouldBe` lsSimSteps still
      lsFinalAge moved `shouldBe` lsFinalAge still

    it "every frame still draws exactly once, through one path or the other" $ do
      (stats, logR) <- runDemo steered
      lsFrames stats `shouldBe` frames
      length (hlScenes logR) + length (hlFlats logR) `shouldBe` frames
      hlDrawCalls logR `shouldBe` frames

  describe "the controls actually move the view" $ do
    it "dragging orbits the camera without moving its target or its radius" $ do
      (_, logR) <- runDemo (script [(k, drag (12, -5)) | k <- [10 .. 20]])
      let cams = map hvCamera (hlHuds logR)
          final = last cams
      camPos final `shouldNotBe` camPos defaultCamera
      camTarget final `shouldBe` camTarget defaultCamera
      abs (obRadius (toOrbit final) - obRadius (toOrbit defaultCamera))
        `shouldSatisfy` (< 1e-3)
      -- Nothing moved before the first drag frame.
      take 9 cams `shouldSatisfy` all (== defaultCamera)

    it "the wheel dollies in, and only while it is turning" $ do
      (_, logR) <- runDemo (script [(30, wheel 4)])
      let radii = map (obRadius . toOrbit . hvCamera) (hlHuds logR)
      take 29 radii `shouldSatisfy` all (== obRadius (toOrbit defaultCamera))
      last radii `shouldSatisfy` (< obRadius (toOrbit defaultCamera))
      -- One notch of input, one change: the radius then holds.
      drop 30 radii `shouldSatisfy` all (== last radii)

    it "in 2D the same gestures pan and zoom instead, leaving the camera alone" $ do
      (_, logR) <- runDemo (script ([(1, tab)] ++ [(k, drag (10, 6)) | k <- [5 .. 15]] ++ [(20, wheel 2)]))
      let flats = map hvFlat (hlHuds logR)
          final = last flats
      map hvCamera (hlHuds logR) `shouldSatisfy` all (== defaultCamera)
      fvOrigin final `shouldNotBe` fvOrigin (flatViewFor windowSize SideXY)
      fvPixelsPerUnit final `shouldSatisfy` (> fvPixelsPerUnit (flatViewFor windowSize SideXY))

    it "T switches the depth tint on and off again" $ do
      (_, logR) <- runDemo (script [(10, tab), (20, tee), (60, tee)])
      let tints = map (fvDepthTint . hvFlat) (hlHuds logR)
      take 19 tints `shouldSatisfy` all (== 0)
      take 20 (drop 20 tints) `shouldSatisfy` all (> 0)
      drop 60 tints `shouldSatisfy` all (== 0)

    it "switching plane re-derives the 2D view, pan and zoom included" $ do
      (_, logR) <- runDemo (script ([(1, tab)] ++ [(k, drag (30, 0)) | k <- [5 .. 15]] ++ [(20, vee)]))
      let flats = map hvFlat (hlHuds logR)
      -- Panned away by frame 19, back on the top view's default at 20.
      fvOrigin (flats !! 18) `shouldNotBe` fvOrigin (flatViewFor windowSize SideXY)
      flats !! 19 `shouldBe` flatViewFor windowSize TopXZ
