-- | S6 (func-spec 0008 §8): end-to-end acceptance of the 2D backend,
-- headless.
--
-- ADR-0008 claims the core is dimension-agnostic: it simulates in an
-- abstract 3D space and the projection is the shell's business. Until now
-- that was a type-level claim. Here it is an assertion — a full run drawn
-- entirely through the 2D path produces, frame for frame, exactly the
-- 'observeSpell' sequence a 3D run would have produced, and a run that
-- switches back and forth loses nothing at the seams.
--
-- The window half (do the three views actually look right?) is the manual
-- smoke recorded in the spec §10.
module Acceptance8Spec (spec) where

import qualified Data.ByteString as BS
import Effectful (runPureEff)
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
import Magic.Codec (loadCircle)
import Magic.Projection (ViewPlane (..))
import Test.Hspec

import App.Effects (DemoInput (..), HudView (..), ViewMode (..), noInput)
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScript
  , runRaylibHeadlessWith
  )

frames :: Int
frames = 120

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
    , lcWindowSize = (1280, 720)
    , lcWindowTitle = "acceptance"
    }

script :: [(Int, DemoInput -> DemoInput)] -> [DemoInput]
script presses =
  [ foldr ($) noInput [f | (j, f) <- presses, j == k]
  | k <- [1 .. frames]
  ]

tab :: DemoInput -> DemoInput
tab i = i {diToggleBackend = True}

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
-- frame — the reference the renderer is checked against.
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

spec :: Spec
spec = describe "2D backend acceptance (func-spec 0008 S6)" $ do
  it "a run drawn entirely in 2D reproduces the observeSpell sequence frame for frame" $ do
    -- Tab on frame 1: the whole run goes through the flat path.
    (stats, logR) <- runDemo (script [(1, tab)])
    reference <- referenceSummaries
    lsFrames stats `shouldBe` frames
    hlScenes logR `shouldBe` []
    map (\(_, b, n) -> (b, n)) (hlFlats logR) `shouldBe` reference
    -- Same spell, same particles — only the consumer changed.
    map (\(p, _, _) -> p) (hlFlats logR) `shouldSatisfy` all (== SideXY)
    map snd reference `shouldSatisfy` any (> 0)

  it "the same run in 3D produces the same sequence: the output carries no dimension" $ do
    (_, flat) <- runDemo (script [(1, tab)])
    (_, solid) <- runDemo (script [])
    map (\(_, b, n) -> (b, n)) (hlFlats flat) `shouldBe` hlScenes solid

  it "switching back and forth conserves frames and loses nothing at the seams" $ do
    (stats, logR) <- runDemo (script [(30, tab), (70, tab), (95, tab)])
    lsFrames stats `shouldBe` frames
    length (hlScenes logR) + length (hlFlats logR) `shouldBe` frames
    hlDrawCalls logR `shouldBe` frames
    -- 1..29 3D, 30..69 2D, 70..94 3D, 95..120 2D
    length (hlFlats logR) `shouldBe` 40 + 26
    length (hlScenes logR) `shouldBe` 29 + 25
    -- Re-zipped into frame order, the mixed run is still the reference
    -- sequence: no frame is dropped or drawn twice at a switch.
    reference <- referenceSummaries
    perFrameSummary logR `shouldBe` reference
    map hvParticles (hlHuds logR) `shouldBe` map snd reference

  it "the default run is untouched: no toggle, no flat draws" $ do
    (stats, logR) <- runDemo (script [])
    hlFlats logR `shouldBe` []
    length (hlScenes logR) `shouldBe` frames
    map hvView (hlHuds logR) `shouldSatisfy` all (== View3D)
    lsFrames stats `shouldBe` frames
    lsSimSteps stats `shouldBe` frames
    lsCasts stats `shouldBe` 1

-- | What each frame drew, in frame order: the HUD records which backend
-- the frame went through, so the two draw logs zip back into one
-- sequence.
perFrameSummary :: HeadlessLog -> [(BlendMode, Int)]
perFrameSummary logR = go (map hvView (hlHuds logR)) (hlScenes logR) (hlFlats logR)
  where
    go [] _ _ = []
    go (View3D : vs) (s : ss) fs = s : go vs ss fs
    go (View2D _ : vs) ss ((_, b, n) : fs) = (b, n) : go vs ss fs
    go _ _ _ = error "draw log does not line up with the HUD log"
