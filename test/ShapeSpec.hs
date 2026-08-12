-- | T-S3 (func-spec 0002 §8): the face-shape sampler. Property tests over
-- arbitrary particle indices and channel bases: every sampled point lies
-- on its shape (ring annulus, diamond L1 ball, hollow-square band with an
-- empty cavity, rect bounds), and sampling is deterministic.
module ShapeSpec (spec) where

import Magic.Particle.Analytic (sampleShape)
import Magic.Rune (FaceShape (..))
import Magic.Types (V2 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Sampler inputs: particle index and channel base.
genInputs :: Gen (Int, Int)
genInputs = (,) <$> chooseInt (0, 5000) <*> chooseInt (0, 64)

genSize :: Gen Double
genSize = choose (0.1, 20)

-- | Float tolerance: points are computed in Float, bounds in Double.
eps :: Float
eps = 1e-3

spec :: Spec
spec = describe "sampleShape (spec 0002 S3)" $ do
  prop "Ring: sampled radius lies in [rInner, rOuter]" $
    forAll ((,,) <$> genSize <*> genSize <*> genInputs) $
      \(rIn, extra, (i, c)) ->
        let rOut = rIn + extra
            V2 x y = sampleShape (Ring rIn rOut) i c
            r = sqrt (x * x + y * y)
         in r >= realToFrac rIn - eps && r <= realToFrac rOut + eps

  prop "Diamond: |x| + |y| <= size" $
    forAll ((,) <$> genSize <*> genInputs) $
      \(size, (i, c)) ->
        let V2 x y = sampleShape (Diamond size) i c
         in abs x + abs y <= realToFrac size + eps

  prop "Rect: point within the width/height bounds" $
    forAll ((,,) <$> genSize <*> genSize <*> genInputs) $
      \(w, h, (i, c)) ->
        let V2 x y = sampleShape (Rect (V2 (realToFrac w) (realToFrac h))) i c
         in abs x <= realToFrac w / 2 + eps && abs y <= realToFrac h / 2 + eps

  prop "HollowSquare: point on the band, never in the center cavity" $
    forAll ((,) <$> genSize <*> genInputs) $
      \(size, (i, c)) ->
        let V2 x y = sampleShape (HollowSquare size) i c
            half = realToFrac size / 2
            cavity = realToFrac size / 6
         in (abs x <= half + eps && abs y <= half + eps)
              && not (abs x < cavity - eps && abs y < cavity - eps)

  prop "same input, same point (determinism)" $
    forAll ((,) <$> genSize <*> genInputs) $
      \(size, (i, c)) ->
        sampleShape (Diamond size) i c == sampleShape (Diamond size) i c

  it "different indices spread over the shape (spot check)" $ do
    let points = [sampleShape (Ring 1 2) i 0 | i <- [0 .. 63]]
        xs = [x | V2 x _ <- points]
    -- Not all in one spot: the x coordinates span a real interval.
    maximum xs - minimum xs `shouldSatisfy` (> 0.5)
