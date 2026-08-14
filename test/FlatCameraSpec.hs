-- | S3 (func-spec 0013 §7): the 2D view's pan, zoom and resize.
--
-- 'screenOf' is the whole contract of the flat presentation layer, so
-- every control here is stated as what it does to 'screenOf' rather than
-- as what it does to the record's fields: panning translates it,
-- zooming scales it about the cursor, resizing keeps the middle of the
-- screen in the middle of the screen. The zoom's fixed point is the one
-- that matters most in the hand — a zoom that drifts is a zoom you have
-- to chase with a pan.
module FlatCameraSpec (spec) where

import Magic.Interface (V3 (..))
import Magic.Projection (ViewPlane (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Effects (FlatView (..))
import App.Loop (flatViewFor)
import App.Render.Flat
  ( maxPixelsPerUnit
  , minPixelsPerUnit
  , panBy
  , resizeTo
  , screenOf
  , zoomAt
  )

sideView :: FlatView
sideView = flatViewFor (1280, 720) SideXY

topView :: FlatView
topView = flatViewFor (1280, 720) TopXZ

-- | Screen-magnitude tolerance: positions are hundreds of pixels, so a
-- relative bound on that magnitude is the honest one (the 0008
-- @FlatQuadSpec@ uses the same shape).
nearPixels :: Float -> Float -> Bool
nearPixels a b = abs (a - b) <= 1e-3 * (1 + max (abs a) (abs b))

genPoint :: Gen V3
genPoint = V3 <$> choose (-8, 8) <*> choose (-8, 8) <*> choose (-8, 8)

genPlane :: Gen ViewPlane
genPlane = elements [SideXY, TopXZ]

viewFor :: ViewPlane -> FlatView
viewFor SideXY = sideView
viewFor TopXZ = topView

spec :: Spec
spec = do
  describe "the defaults are func-spec 0008's constants, untouched" $ do
    it "keeps the side view's scale, origin and screen size" $ do
      fvPixelsPerUnit sideView `shouldBe` 60
      fvScreenSize sideView `shouldBe` (1280, 720)
      fvOrigin sideView `shouldBe` (640, 576)

    it "centres the top view" $
      fvOrigin topView `shouldBe` (640, 360)

    it "starts with the depth tint off, so the 2D output is 0008's" $ do
      fvDepthTint sideView `shouldBe` 0
      fvDepthTint topView `shouldBe` 0

  describe "panBy" $ do
    it "a zero drag is the identity, exactly" $
      panBy (0, 0) sideView `shouldBe` sideView

    prop "translates every screen position by the drag" $
      forAll ((,,) <$> genPlane <*> genPoint <*> ((,) <$> choose (-500, 500) <*> choose (-500, 500))) $
        \(plane, p, d@(dx, dy)) ->
          let fv = viewFor plane
              (x0, y0) = screenOf fv p
              (x1, y1) = screenOf (panBy d fv) p
           in property (nearPixels x1 (x0 + dx) && nearPixels y1 (y0 + dy))

    prop "changes nothing but the origin" $
      forAll ((,) <$> choose (-500, 500) <*> choose (-500, 500)) $ \d ->
        let fv = panBy d sideView
         in fvPlane fv === fvPlane sideView
              .&&. fvScreenSize fv === fvScreenSize sideView
              .&&. fvPixelsPerUnit fv === fvPixelsPerUnit sideView

    it "composes: two drags are their sum" $ do
      let stepwise = panBy (30, -70) (panBy (10, 20) sideView)
          combined = panBy (40, -50) sideView
      fst (fvOrigin stepwise) `shouldSatisfy` nearPixels (fst (fvOrigin combined))
      snd (fvOrigin stepwise) `shouldSatisfy` nearPixels (snd (fvOrigin combined))

  describe "zoomAt" $ do
    it "a zero wheel is the identity, exactly" $
      zoomAt (400, 300) 0 sideView `shouldBe` sideView

    prop "the world point under the cursor stays under the cursor" $
      forAll ((,,) <$> genPlane <*> genPoint <*> choose (-8, 8)) $ \(plane, p, notches) ->
        let fv = viewFor plane
            cursor = screenOf fv p
            (x1, y1) = screenOf (zoomAt cursor notches fv) p
         in property (nearPixels x1 (fst cursor) && nearPixels y1 (snd cursor))

    prop "stays inside the zoom clamp for any wheel input" $
      forAll (choose (-200, 200)) $ \notches ->
        let ppu = fvPixelsPerUnit (zoomAt (640, 360) notches sideView)
         in property (ppu >= minPixelsPerUnit && ppu <= maxPixelsPerUnit)

    it "scrolling towards the viewer magnifies, away shrinks" $ do
      fvPixelsPerUnit (zoomAt (640, 360) 1 sideView) `shouldSatisfy` (> 60)
      fvPixelsPerUnit (zoomAt (640, 360) (-1) sideView) `shouldSatisfy` (< 60)

    it "keeps its fixed point even when the zoom hits the stop" $ do
      let cursor = screenOf sideView (V3 2 1 0)
          (x1, y1) = screenOf (zoomAt cursor 500 sideView) (V3 2 1 0)
      fvPixelsPerUnit (zoomAt cursor 500 sideView) `shouldBe` maxPixelsPerUnit
      x1 `shouldSatisfy` nearPixels (fst cursor)
      y1 `shouldSatisfy` nearPixels (snd cursor)

    it "changes nothing but the scale and the origin" $ do
      let fv = zoomAt (100, 200) 3 topView
      fvPlane fv `shouldBe` TopXZ
      fvScreenSize fv `shouldBe` fvScreenSize topView
      fvDepthTint fv `shouldBe` fvDepthTint topView

  describe "resizeTo" $ do
    it "resizing to the same size is the identity, exactly" $
      resizeTo (1280, 720) sideView `shouldBe` sideView

    it "adopts the new size" $
      fvScreenSize (resizeTo (800, 600) sideView) `shouldBe` (800, 600)

    prop "keeps the middle of the screen showing the same place" $
      forAll ((,,) <$> genPoint <*> choose (200, 3000) <*> choose (200, 3000)) $
        \(p, w, h) ->
          let fv = sideView
              fv' = resizeTo (w, h) fv
              (x0, y0) = screenOf fv p
              (x1, y1) = screenOf fv' p
              (w0, h0) = fvScreenSize fv
              -- Offsets from the screen centre are what must be equal;
              -- the centre itself moved with the window.
              dx = fromIntegral w * 0.5 - fromIntegral (w0 :: Int) * 0.5
              dy = fromIntegral h * 0.5 - fromIntegral (h0 :: Int) * 0.5
           in property (nearPixels x1 (x0 + dx) && nearPixels y1 (y0 + dy))

    prop "does not rescale: a resize is not a zoom" $
      forAll ((,) <$> choose (200, 3000) <*> choose (200, 3000)) $ \(w, h) ->
        fvPixelsPerUnit (resizeTo (w, h) sideView) === fvPixelsPerUnit sideView

    it "a pan survives a resize" $ do
      let panned = panBy (100, 0) sideView
          resized = resizeTo (1280, 900) panned
      fst (fvOrigin resized) `shouldSatisfy` nearPixels (fst (fvOrigin panned))
