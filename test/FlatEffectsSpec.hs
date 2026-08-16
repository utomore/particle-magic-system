-- | S3 (func-spec 0008 §8): the 'DrawFlat' operation under the headless
-- interpreter.
--
-- 'DrawFlat' is an additive extension of the 0005 effect (no existing
-- signature moved), so this spec asserts two things: what the new
-- operation records, and that a run which never toggles the backend
-- records nothing at all — the regression sentinel that keeps the 3D
-- path honest.
module FlatEffectsSpec (spec) where

import qualified Data.ByteString as BS
import Effectful (Eff, runPureEff, (:>))
import Magic.Codec (saveCircle)
import Magic.Interface
  ( BlendMode (..)
  , BillboardShape (..)
  , CastContext (..)
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , emptyCircle
  )
import Magic.Particle.Buffer (fromParticles)
import Magic.Projection (ViewPlane (..))
import Test.Hspec

import App.Effects
  ( DemoInput (..)
  , FlatView (..)
  , Raylib
  , drawFlat
  , drawScene
  , noInput
  )
import App.Loop (LoopConfig (..), defaultCamera, runLoop)
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScript
  , runRaylibHeadless
  )

flatView :: ViewPlane -> FlatView
flatView plane =
  FlatView
    { fvPlane = plane
    , fvScreenSize = (1280, 720)
    , fvOrigin = (640, 576)
    , fvPixelsPerUnit = 60
    , fvDepthTint = 0
    , fvDepthScale = 1
    , fvOutlineFloor = 0
    }

batchOf :: BlendMode -> Int -> RenderBatch
batchOf blend n =
  RenderBatch
    { rbParticles = fromParticles [(V3 0 (fromIntegral i) 0, 1, 1, 0xFFFFFFFF) | i <- [1 .. n]]
    , rbBlend = blend
    , rbShape = BillboardSquare
    }

record :: (forall es. (Raylib :> es) => Eff es ()) -> HeadlessLog
record action = snd (runPureEff (runRaylibHeadless 0 action))

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = ["virtual-spell.json"]
    , lcSpellIndex = 0
    , lcCamera = defaultCamera
    , lcCastCtx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 7}
    , lcWindowSize = (640, 360)
    , lcWindowTitle = "headless"
    }

runIdleLoop :: BS.ByteString -> Int -> HeadlessLog
runIdleLoop bytes frames =
  snd
    . runPureEff
    . runRaylibHeadless frames
    . runFileWatchScript bytes []
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

spec :: Spec
spec = describe "the DrawFlat operation (func-spec 0008 §4.3)" $ do
  it "records the plane, blend mode and particle count of every batch" $ do
    let logR = record (drawFlat (flatView SideXY) [batchOf BlendAdditive 3, batchOf BlendAlpha 5])
    hlFlats logR `shouldBe` [(SideXY, BlendAdditive, 3), (SideXY, BlendAlpha, 5)]

  it "reports the plane it was actually handed" $ do
    let logR = record (drawFlat (flatView TopXZ) [batchOf BlendAlpha 2])
    map (\(p, _, _) -> p) (hlFlats logR) `shouldBe` [TopXZ]

  it "counts towards the draw calls, exactly like DrawScene does" $ do
    let flat = record (drawFlat (flatView SideXY) [batchOf BlendAlpha 1, batchOf BlendAlpha 1])
        scene = record (drawScene defaultCamera [batchOf BlendAlpha 1, batchOf BlendAlpha 1])
    hlDrawCalls flat `shouldBe` 2
    hlDrawCalls flat `shouldBe` hlDrawCalls scene

  it "leaves the 3D scene log alone, and vice versa" $ do
    let flat = record (drawFlat (flatView SideXY) [batchOf BlendAlpha 1])
        scene = record (drawScene defaultCamera [batchOf BlendAlpha 1])
    hlScenes flat `shouldBe` []
    hlFlats scene `shouldBe` []

  it "an empty batch list is a no-op that still records nothing" $ do
    let logR = record (drawFlat (flatView SideXY) [])
    hlFlats logR `shouldBe` []
    hlDrawCalls logR `shouldBe` 0

  describe "the added input fields" $ do
    it "are idle in noInput, so every existing script keeps its meaning" $ do
      diToggleBackend noInput `shouldBe` False
      diTogglePlane noInput `shouldBe` False
      -- Func-spec 0013's additions, held to the same standard: an idle
      -- frame must carry no gesture at all, not a zero-sized one.
      diToggleTint noInput `shouldBe` False
      diOrbitDrag noInput `shouldBe` Nothing
      diPanDrag noInput `shouldBe` Nothing
      diWheel noInput `shouldBe` 0
      diCursor noInput `shouldBe` (0, 0)

    it "a run that never toggles draws through the 3D path only" $ do
      let frames = 60
          logR = runIdleLoop (saveCircle emptyCircle) frames
      hlFlats logR `shouldBe` []
      length (hlScenes logR) `shouldBe` frames
      hlDrawCalls logR `shouldBe` frames
