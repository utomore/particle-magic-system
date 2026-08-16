-- | S2 (func-spec 0021 §7): the face-shape vocabulary, four to eight.
--
-- The load-bearing test here is the __conservative-bound property__
-- (§2.2). Adding a 'FaceShape' constructor without a 'sampleShape' case
-- or a 'Magic.Compile.shapeRadius' case is an exhaustiveness error, so
-- GHC catches it. Adding one whose @shapeRadius@ is /too small/ is not:
-- it type-checks, samples fine, and then makes the conservative AABB
-- 'Magic.Compile.emitterBounds' hands the host a lie — with the symptom
-- that particles vanish in batches from certain camera angles, and only
-- on a host that actually culls. So the bound is asserted as a property
-- over random indices, for all eight shapes at once: the four new ones
-- because they are new, the four old ones because the net is free.
--
-- Everything else here is about the four new samplers producing points
-- that are actually inside the shape they name — a polygon sample outside
-- the polygon would satisfy the radius bound perfectly well.
module FaceShapeVocabSpec (spec) where

import Magic.Compile (shapeRadius)
import Magic.Particle.Analytic (sampleShape)
import Magic.Rune (FaceShape (..))
import Magic.Types (V2 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Shape parameters as 'Magic.Codec' would admit them: radii ordered,
-- counts above their floor, extents positive. The bound is claimed about
-- shapes a spell file can actually contain.
newtype ValidShape = ValidShape FaceShape
  deriving (Show)

instance Arbitrary ValidShape where
  arbitrary =
    ValidShape
      <$> oneof
        [ HollowSquare <$> choose (0.1, 4)
        , Rect <$> (V2 <$> choose (0.1, 4) <*> choose (0.1, 4))
        , ordered Ring
        , Diamond <$> choose (0.1, 4)
        , Polygon <$> choose (3, 12) <*> choose (0.1, 4)
        , do
            points <- choose (2, 9)
            (inner, outer) <- orderedPair
            pure (Star points outer inner)
        , Cross <$> choose (0.1, 4) <*> choose (0.1, 2)
        , do
            (inner, outer) <- orderedPair
            Sector inner outer <$> choose (0.05, 2 * pi)
        ]
    where
      ordered con = uncurry con <$> orderedPair
      orderedPair = do
        inner <- choose (0, 3)
        delta <- choose (0.05, 2)
        pure (inner, inner + delta)

norm2 :: V2 -> Float
norm2 (V2 x y) = sqrt (x * x + y * y)

finite2 :: V2 -> Bool
finite2 (V2 x y) = ok x && ok y
  where
    ok v = not (isNaN v) && not (isInfinite v)

-- | Slack for one float rounding at the bound itself; the claim is
-- "conservative", not "conservative to the last ulp".
epsilon :: Float
epsilon = 1e-4

sampledAt :: FaceShape -> [V2]
sampledAt s = [sampleShape s i 0 | i <- [0 .. 199]]

spec :: Spec
spec = describe "face-shape vocabulary, 4 -> 8 (func-spec 0021 S2)" $ do
  describe "the conservative-bound law (§2.2)" $ do
    prop "|sampleShape s i| never exceeds shapeRadius s, for all eight shapes" $
      \(ValidShape s) ->
        forAll (choose (0, 100000)) $ \i ->
          let p = sampleShape s i 0
           in counterexample (show (s, i, p, norm2 p, shapeRadius s)) $
                norm2 p <= shapeRadius s + epsilon

    prop "and every sample is finite" $ \(ValidShape s) ->
      forAll (choose (0, 100000)) $ \i -> finite2 (sampleShape s i 0)

    it "bounds each new shape by the radius func-spec 0021 §2.2 names" $ do
      shapeRadius (Polygon 6 1.5) `shouldBe` 1.5
      shapeRadius (Star 5 2 0.8) `shouldBe` 2
      shapeRadius (Sector 0.4 1.7 1) `shouldBe` 1.7
      -- The far corner of an arm, not the arm length alone.
      shapeRadius (Cross 2 1) `shouldSatisfy` \r ->
        abs (r - sqrt (2 * 2 + 0.5 * 0.5)) < epsilon

  describe "Polygon samples land inside the polygon" $
    it "satisfies every edge half-plane of a regular n-gon" $
      mapM_
        ( \n ->
            let r = 1.5 :: Double
                rf = realToFrac r :: Float
                apothem = rf * cos (pi / fromIntegral n)
                -- Edge k's outward normal bisects vertices k and k+1.
                edgeNormal k =
                  let th = 2 * pi * (fromIntegral k + 0.5) / fromIntegral n
                   in V2 (cos th) (sin th)
                inside (V2 x y) =
                  and
                    [ let V2 nx ny = edgeNormal k in x * nx + y * ny <= apothem + epsilon
                    | k <- [0 .. n - 1]
                    ]
             in mapM_ (\p -> (n, p) `shouldSatisfy` (inside . snd)) (sampledAt (Polygon n r))
        )
        [3, 5, 6, 8 :: Int]

  describe "Star spans the band between its two radii" $ do
    it "keeps every sample inside the outer radius" $
      mapM_
        (\p -> p `shouldSatisfy` ((<= 2 + epsilon) . norm2))
        (sampledAt (Star 5 2 0.6))

    it "reaches past the inner radius — the points are actually drawn" $
      maximum (map norm2 (sampledAt (Star 5 2 0.6))) `shouldSatisfy` (> 0.6)

    it "collapses to a polygon-like disc when the radii are equal" $
      maximum (map norm2 (sampledAt (Star 5 1 1))) `shouldSatisfy` (<= 1 + epsilon)

  describe "Cross samples stay within an arm" $
    it "is always within half a width of one of the two axes" $
      mapM_
        ( \p ->
            let V2 x y = p
             in (p, min (abs x) (abs y)) `shouldSatisfy` ((<= 0.5 / 2 + epsilon) . snd)
        )
        (sampledAt (Cross 2 0.5))

  describe "Sector samples stay inside the wedge" $ do
    it "never leaves the half-sweep on either side" $
      mapM_
        ( \p@(V2 x y) ->
            (p, atan2 y x) `shouldSatisfy` ((<= 1.2 / 2 + epsilon) . abs . snd)
        )
        (sampledAt (Sector 0.5 1.5 1.2))

    it "stays inside the annulus, inner radius included" $
      mapM_
        ( \p ->
            (p, norm2 p)
              `shouldSatisfy` (\(_, r) -> r >= 0.5 - epsilon && r <= 1.5 + epsilon)
        )
        (sampledAt (Sector 0.5 1.5 1.2))

    it "sweeps the whole disc at a full turn" $ do
      let angles = [atan2 y x | V2 x y <- sampledAt (Sector 0 1 (2 * pi))]
      maximum angles `shouldSatisfy` (> 2)
      minimum angles `shouldSatisfy` (< (-2))

  -- The pre-0021 samplers were not edited, and the twelve golden files
  -- under test/golden/perf-0010 (recorded on the pre-0021 build) are the
  -- evidence for that end to end — they cover ring, hollow-square and
  -- diamond. 'Rect' has no shipped example, so these four values, taken
  -- at 0021, are the local net it gets from here on.
  describe "the existing four sample exactly what they did" $
    it "reproduces the recorded first four indices" $ do
      take 2 (sampledAt (HollowSquare 2.4))
        `shouldBe` [V2 (-0.45456585) (-0.13707338), V2 0.8535012 0.56383306]
      take 2 (sampledAt (Rect (V2 2 4)))
        `shouldBe` [V2 (-0.51260746) 1.7271707, V2 0.9035244 0.26750588]
      take 2 (sampledAt (Ring 1 1.5))
        `shouldBe` [V2 5.8259487e-2 1.4701519, V2 1.2475531 (-0.3901372)]
      take 2 (sampledAt (Diamond 0.6))
        `shouldBe` [V2 (-0.41285786) 0.10529337, V2 0.23093145 0.31118318]
