-- | S3 (func-spec 0005 §8): the extended 'Raylib' effect under the
-- headless interpreter.
--
-- The real 'runLoop' runs against the test interpreters (the 0001
-- technique), so what the window would have been told each frame is
-- available as data: one scene and one HUD per frame, carrying exactly
-- what 'observeSpell' produced.
module SceneEffectsSpec (spec) where

import qualified Data.ByteString as BS
import App.Effects (HudView (..), ReloadStatus (..))
import App.Loop (LoopConfig (..), LoopStats (..), defaultCamera, runLoop)
import App.TestInterp
  ( HeadlessLog (..)
  , runClockVirtual
  , runFileWatchScript
  , runRaylibHeadless
  )
import Effectful (runPureEff)
import Magic.Codec (loadCircle, saveCircle)
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
  , emptyCircle
  , observeSpell
  , pbCount
  )
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 7}

testConfig :: LoopConfig
testConfig =
  LoopConfig
    { lcSimDt = 1 / 60
    , lcMaxStepsPerFrame = 8
    , lcSpellPaths = ["virtual-spell.json"]
    , lcSpellIndex = 0
    , lcCamera = defaultCamera
    , lcCastCtx = ctx
    , lcWindowSize = (640, 360)
    , lcWindowTitle = "headless"
    }

runHeadless :: BS.ByteString -> Int -> IO (LoopStats, HeadlessLog)
runHeadless bytes frames =
  pure
    . runPureEff
    . runRaylibHeadless frames
    . runFileWatchScript bytes []
    . runClockVirtual (1 / 60)
    $ runLoop testConfig

-- | The spell the loop is driving, aged the same way the loop ages it:
-- one fixed step per virtual frame.
referenceSpell :: BS.ByteString -> Int -> IO ActiveSpell
referenceSpell bytes frames = do
  circle <- either (fail . show) pure (loadCircle bytes)
  spell0 <- either (fail . show) pure (castSpell (CastRequest circle ctx))
  let dt = FrameInput (DeltaTime (1 / 60))
  pure (foldl (\s _ -> advanceSpell dt s) spell0 [1 .. frames])

summaryOf :: FrameOutput -> [(BlendMode, Int)]
summaryOf out = [(rbBlend b, pbCount (rbParticles b)) | b <- batches out]

spec :: Spec
spec = describe "DrawScene / DrawHud / PollInput under the headless interpreter" $ do
  it "renders exactly one scene and one HUD per frame" $ do
    let frames = 90
    (stats, logR) <- runHeadless (saveCircle emptyCircle) frames
    lsFrames stats `shouldBe` frames
    hlFrames logR `shouldBe` frames
    length (hlScenes logR) `shouldBe` frames
    length (hlHuds logR) `shouldBe` frames

  it "the scene summary matches what observeSpell produces at that age" $ do
    let frames = 45
    (_, logR) <- runHeadless (saveCircle emptyCircle) frames
    mapM_
      ( \k -> do
          spell <- referenceSpell (saveCircle emptyCircle) k
          [hlScenes logR !! (k - 1)] `shouldBe` summaryOf (observeSpell spell)
      )
      [1, 5, 20, 45]

  it "a fire spell reaches the renderer as an additive batch" $ do
    bytes <- BS.readFile "assets/spells/ring-fire.json"
    -- 120 virtual frames = 2s, past ring-fire's first particle births.
    (_, logR) <- runHeadless bytes 120
    map fst (hlScenes logR) `shouldSatisfy` all (== BlendAdditive)
    map snd (hlScenes logR) `shouldSatisfy` any (> 0)

  it "the HUD reports the same particle count the scene was given" $ do
    bytes <- BS.readFile "assets/spells/ring-fire.json"
    (_, logR) <- runHeadless bytes 120
    map hvParticles (hlHuds logR) `shouldBe` map snd (hlScenes logR)

  it "the HUD reports the live path, a rising age and an idle reload state" $ do
    let frames = 30
    (_, logR) <- runHeadless (saveCircle emptyCircle) frames
    let huds = hlHuds logR
    map hvSpellPath huds `shouldSatisfy` all (== "virtual-spell.json")
    map hvReload huds `shouldSatisfy` all (== ReloadIdle)
    -- One fixed step per virtual frame: age at frame k is k*dt.
    let ages = map hvSpellAge huds
        expected = [fromIntegral k * (1 / 60) | k <- [1 .. frames :: Int]]
    zipWith (\a b -> abs (a - b)) ages expected `shouldSatisfy` all (< 1e-9)
    hvFps (last huds) `shouldSatisfy` (> 0)

  it "counts every batch it is handed, so the 0001 draw-call assertions still hold" $ do
    let frames = 60
    (_, logR) <- runHeadless (saveCircle emptyCircle) frames
    hlDrawCalls logR `shouldBe` frames
    hlDrawCalls logR `shouldBe` length (hlScenes logR)
