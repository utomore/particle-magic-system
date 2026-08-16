-- | S5 (func-spec 0005 §8): HUD formatting and the frame-rate average.
--
-- Formatting lives in a pure module precisely so what the player reads is
-- decided here, not inside the raylib interpreter.
module HudSpec (spec) where

import Data.List (isInfixOf)
import App.Effects
  ( FlatView (..)
  , HudView (..)
  , PanelView (..)
  , ReloadStatus (..)
  , ViewMode (..)
  , panelViewClosed
  )
import App.Hud (formatHud, fpsEma)
import App.Loop (defaultCamera, flatViewFor)
import App.Render.Post (noEffects)
import Magic.Projection (ViewPlane (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

baseView :: HudView
baseView =
  HudView
    { hvFps = 59.94
    , hvParticles = 256
    , hvSpellPath = "assets/spells/ring-fire.json"
    , hvSpellAge = 1.5
    , hvReload = ReloadIdle
    , hvView = View3D
    , hvCamera = defaultCamera
    , hvFlat = flatViewFor (1280, 720) SideXY
    , hvVisual = noEffects
    , hvPanel = panelViewClosed
    }

hudText :: HudView -> String
hudText = unlines . formatHud

spec :: Spec
spec = do
  describe "formatHud" $ do
    it "reports fps, particle count, spell path and age" $ do
      let out = hudText baseView
      out `shouldSatisfy` ("59.9" `isInfixOf`)
      out `shouldSatisfy` ("256" `isInfixOf`)
      out `shouldSatisfy` ("assets/spells/ring-fire.json" `isInfixOf`)
      out `shouldSatisfy` ("1.50" `isInfixOf`)

    it "reports where the orbit camera is while 3D is live" $ do
      let out = hudText baseView
      out `shouldSatisfy` ("cam:" `isInfixOf`)
      -- defaultCamera sits sqrt 76 ≈ 8.7 units from its target.
      out `shouldSatisfy` ("8.7" `isInfixOf`)

    it "reports the 2D scale and tint instead once the flat view is live" $ do
      let flat = flatViewFor (1280, 720) TopXZ
          out = hudText baseView {hvView = View2D TopXZ, hvFlat = flat}
      out `shouldSatisfy` ("zoom:" `isInfixOf`)
      out `shouldSatisfy` ("60 px/unit" `isInfixOf`)
      out `shouldSatisfy` ("tint: off" `isInfixOf`)
      out `shouldSatisfy` (not . ("cam:" `isInfixOf`))

    it "says so when the depth tint is on" $ do
      let flat = (flatViewFor (1280, 720) TopXZ) {fvDepthTint = 0.5}
      hudText baseView {hvView = View2D TopXZ, hvFlat = flat}
        `shouldSatisfy` ("tint: on" `isInfixOf`)

    it "documents the keys and the mouse gestures that steer the view" $ do
      let out = hudText baseView
      out `shouldSatisfy` ("[T]" `isInfixOf`)
      out `shouldSatisfy` ("[drag]" `isInfixOf`)
      out `shouldSatisfy` ("[wheel]" `isInfixOf`)

    it "says the reload state is idle before anything is reloaded" $
      hudText baseView `shouldSatisfy` ("idle" `isInfixOf`)

    it "reports a successful reload with its timestamp" $ do
      let out = hudText baseView {hvReload = ReloadOk 3.25}
      out `shouldSatisfy` ("ok" `isInfixOf`)
      out `shouldSatisfy` ("3.25" `isInfixOf`)

    it "reports a failure with its timestamp and the full error text" $ do
      let out = hudText baseView {hvReload = ReloadFailed 3.25 "boom"}
      out `shouldSatisfy` ("FAILED" `isInfixOf`)
      out `shouldSatisfy` ("3.25" `isInfixOf`)
      out `shouldSatisfy` ("boom" `isInfixOf`)

    it "expands a multi-line error into one HUD line each" $ do
      let err = "at $.circle.outer[0]:\nunknown rune tag\nexpected: shape, radiate"
          ls = formatHud baseView {hvReload = ReloadFailed 0 err}
      length (filter ("unknown rune tag" `isInfixOf`) ls) `shouldBe` 1
      length (filter ("expected: shape, radiate" `isInfixOf`) ls) `shouldBe` 1
      -- No line may still contain a newline, or drawText would run off.
      ls `shouldSatisfy` all (notElem '\n')

    it "never claims a failure without saying anything" $ do
      let ls = formatHud baseView {hvReload = ReloadFailed 0 ""}
      length ls `shouldSatisfy` (> 4)
      unlines ls `shouldSatisfy` ("no message" `isInfixOf`)

    prop "every line is newline-free for any view" $
      \fps n path age ->
        let view =
              baseView
                { hvFps = fps
                , hvParticles = n
                , hvSpellPath = filter (/= '\n') path
                , hvSpellAge = age
                }
         in all (notElem '\n') (formatHud view)

  describe "fpsEma" $ do
    it "converges to 1/dt for a constant frame time" $ do
      let dt = 1 / 60
          converged = foldl (\e _ -> fpsEma 0.1 dt e) 0 [1 .. 500 :: Int]
      abs (converged - 60) `shouldSatisfy` (< 1e-3)

    prop "converges to 1/dt for any constant frame time in range" $
      forAll (choose (1 / 240, 1 / 10)) $ \dt ->
        let converged = foldl (\e _ -> fpsEma 0.2 dt e) 0 [1 .. 500 :: Int]
         in abs (converged - 1 / dt) < 1e-3 * (1 / dt)

    prop "is non-negative and finite for arbitrary inputs" $
      \alpha dt ema ->
        let r = fpsEma alpha dt ema
         in r >= 0 && not (isNaN r) && not (isInfinite r)

    it "an alpha of 0 keeps the previous value; 1 jumps straight to it" $ do
      fpsEma 0 (1 / 60) 10 `shouldBe` 10
      abs (fpsEma 1 (1 / 60) 10 - 60) `shouldSatisfy` (< 1e-9)

    it "a stopped clock carries the previous value forward" $ do
      fpsEma 0.1 0 42 `shouldBe` 42
      fpsEma 0.1 (-1) 42 `shouldBe` 42
