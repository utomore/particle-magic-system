-- | S2 (func-spec 0013 §7): the orbit camera.
--
-- The point of expressing the controls as spherical coordinates around a
-- fixed target is that each one becomes a law rather than a feel:
-- dragging changes two angles and conserves everything else, the wheel
-- changes the radius and conserves the direction. Those conservation
-- laws are what keep a long session from drifting into a camera nobody
-- can get back — so they are asserted here, not eyeballed.
module CameraSpec (spec) where

import Magic.Interface (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Camera
  ( Orbit (..)
  , dolly
  , fromOrbit
  , maxElevation
  , maxRadius
  , minRadius
  , orbit
  , toOrbit
  )
import App.Effects (Camera (..))
import App.Loop (defaultCamera)

radiusOf :: Camera -> Float
radiusOf = obRadius . toOrbit

directionOf :: Camera -> V3
directionOf cam = V3 (dx / r) (dy / r) (dz / r)
  where
    V3 px py pz = camPos cam
    V3 tx ty tz = camTarget cam
    (dx, dy, dz) = (px - tx, py - ty, pz - tz)
    r = sqrt (dx * dx + dy * dy + dz * dz)

-- | Relative closeness, the tolerance shape the 0005/0008 specs use.
close :: Float -> Float -> Float -> Bool
close eps a b = abs (a - b) <= eps * (1 + max (abs a) (abs b))

closeV3 :: Float -> V3 -> V3 -> Bool
closeV3 eps (V3 ax ay az) (V3 bx by bz) =
  close eps ax bx && close eps ay by && close eps az bz

-- | Drags of a size a hand actually produces, in degrees.
genDrag :: Gen (Float, Float)
genDrag = (,) <$> choose (-720, 720) <*> choose (-720, 720)

spec :: Spec
spec = do
  describe "orbit" $ do
    it "a zero drag is the identity, exactly" $
      orbit (0, 0) defaultCamera `shouldBe` defaultCamera

    prop "conserves the target, the up vector and the field of view" $
      forAll genDrag $ \d ->
        let cam = orbit d defaultCamera
         in camTarget cam === camTarget defaultCamera
              .&&. camUp cam === camUp defaultCamera
              .&&. camFovY cam === camFovY defaultCamera

    prop "conserves the radius: dragging turns the camera, it does not move it in or out" $
      forAll genDrag $ \d ->
        property (close 1e-4 (radiusOf (orbit d defaultCamera)) (radiusOf defaultCamera))

    prop "never passes the poles, whatever is dragged at it" $
      forAll genDrag $ \d ->
        let el = obElevation (toOrbit (orbit d defaultCamera))
         in property (el >= -maxElevation - 1e-3 && el <= maxElevation + 1e-3)

    it "a huge upward drag parks at the elevation clamp instead of flipping over" $
      obElevation (toOrbit (orbit (0, 1000) defaultCamera))
        `shouldSatisfy` close 1e-4 maxElevation

    prop "the azimuth stays in a bounded range however far it is dragged" $
      forAll (choose (-100000, 100000)) $ \dAz ->
        let az = obAzimuth (toOrbit (orbit (dAz, 0) defaultCamera))
         in property (az >= -180 && az <= 180)

    it "a 360 degree drag comes back to where it started" $
      camPos (orbit (360, 0) defaultCamera)
        `shouldSatisfy` closeV3 1e-4 (camPos defaultCamera)

    it "dragging in azimuth swings the camera around the target" $ do
      let cam = defaultCamera {camPos = V3 0 2 8, camTarget = V3 0 2 0}
          turned = orbit (90, 0) cam
      camPos turned `shouldSatisfy` closeV3 1e-4 (V3 8 2 0)

  describe "toOrbit / fromOrbit" $ do
    prop "round-trip: a camera rebuilt from its own orbit is where it was" $
      forAll genDrag $ \d ->
        let cam = orbit d defaultCamera
         in property (closeV3 1e-4 (camPos (fromOrbit (toOrbit cam) cam)) (camPos cam))

    it "a camera sitting on its target reports no radius rather than a NaN" $ do
      let ob = toOrbit defaultCamera {camPos = camTarget defaultCamera}
      obRadius ob `shouldBe` 0
      obElevation ob `shouldSatisfy` (not . isNaN)

  describe "dolly" $ do
    it "a zero wheel is the identity, exactly" $
      dolly 0 defaultCamera `shouldBe` defaultCamera

    prop "conserves the target and the view direction" $
      forAll (choose (-40, 40)) $ \n ->
        let cam = dolly n defaultCamera
         in camTarget cam === camTarget defaultCamera
              .&&. property (closeV3 1e-4 (directionOf cam) (directionOf defaultCamera))

    prop "stays inside the radius clamp for any wheel input" $
      forAll (choose (-1000, 1000)) $ \n ->
        let r = radiusOf (dolly n defaultCamera)
         in property (r >= minRadius - 1e-3 && r <= maxRadius + 1e-3)

    it "scrolling towards the viewer pulls in, away pushes out" $ do
      radiusOf (dolly 1 defaultCamera) `shouldSatisfy` (< radiusOf defaultCamera)
      radiusOf (dolly (-1) defaultCamera) `shouldSatisfy` (> radiusOf defaultCamera)

    it "parks at the near stop rather than passing through the target" $
      radiusOf (dolly 100 defaultCamera) `shouldSatisfy` close 1e-4 minRadius

    it "parks at the far stop rather than leaving the scene" $
      radiusOf (dolly (-100) defaultCamera) `shouldSatisfy` close 1e-4 maxRadius

    it "pushes a camera that has collapsed onto its target back out" $ do
      let collapsed = defaultCamera {camPos = camTarget defaultCamera}
      radiusOf (dolly (-1) collapsed) `shouldSatisfy` close 1e-4 minRadius

  describe "the two controls compose without interfering" $
    prop "a drag then a wheel keeps the drag's angles" $
      forAll genDrag $ \d ->
        let dragged = orbit d defaultCamera
            both = dolly 3 dragged
         in property
              ( close 1e-3 (obAzimuth (toOrbit both)) (obAzimuth (toOrbit dragged))
                  && close 1e-3 (obElevation (toOrbit both)) (obElevation (toOrbit dragged))
              )
