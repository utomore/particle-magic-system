-- | S4 (func-spec 0021 §7): the force-field vocabulary, three to six.
--
-- The selection criterion for this round's three fields was a frozen
-- signature: @fieldAccel :: [ForceField] -> V3 -> V3@ sees a position and
-- nothing else (spec 0007, ADR-0010), so a field needing the particle's
-- velocity — drag, magnetism — cannot be added at any price without
-- changing that signature and rewriting the hot path. Func-spec 0021 §7-2
-- books those explicitly rather than smuggling them in.
--
-- So the first property is the criterion itself, asserted rather than
-- asserted-in-prose: each new field is a pure function of position. The
-- rest are the individual laws — 'Spring' linear about its centre,
-- 'Wind' and 'Turbulence' bounded and deterministic — plus the one thing
-- the whole layer must not lose: an empty field list is still exactly
-- zero (ADR-0010 D9's compatibility case).
module FieldVocabSpec (spec) where

import Magic.Particle.Field (fieldAccel)
import Magic.Rune (ForceField (..))
import Magic.Types (V3 (..), norm, vscale)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

newtype ValidField = ValidField ForceField
  deriving (Show)

-- | Parameters as 'Magic.Codec' admits them: softening and scale and
-- stiffness positive, falloff and turbulence non-negative, axis non-zero.
instance Arbitrary ValidField where
  arbitrary =
    ValidField
      <$> oneof
        [ Gravity <$> vec
        , PointAttractor <$> vec <*> choose (-8, 8) <*> choose (0.1, 3)
        , Vortex <$> vec <*> nonZeroVec <*> choose (-8, 8) <*> choose (0, 3)
        , Wind <$> nonZeroVec <*> choose (-8, 8) <*> choose (0, 4)
        , Turbulence <$> choose (-8, 8) <*> choose (0.1, 8)
        , Spring <$> vec <*> choose (0.1, 8)
        ]
    where
      vec = V3 <$> choose (-6, 6) <*> choose (-6, 6) <*> choose (-6, 6)
      nonZeroVec = do
        v@(V3 x y z) <- vec
        pure (if x == 0 && y == 0 && z == 0 then V3 0 0 1 else v)

newtype Point = Point V3
  deriving (Show)

instance Arbitrary Point where
  arbitrary =
    Point <$> (V3 <$> choose (-20, 20) <*> choose (-20, 20) <*> choose (-20, 20))

finite3 :: V3 -> Bool
finite3 (V3 x y z) = all ok [x, y, z]
  where
    ok v = not (isNaN v) && not (isInfinite v)

epsilon :: Float
epsilon = 1e-3

newFields :: [ForceField]
newFields =
  [ Wind (V3 0 1 0) 1.5 0.8
  , Turbulence 2 1.5
  , Spring (V3 0 1 0) 3
  ]

spec :: Spec
spec = describe "force-field vocabulary, 3 -> 6 (func-spec 0021 S4)" $ do
  describe "the frozen-signature criterion (§2.5)" $ do
    prop "every field is a pure function of position: same point, same accel" $
      \(ValidField f) (Point p) -> fieldAccel [f] p === fieldAccel [f] p

    prop "and produces a finite acceleration everywhere" $
      \(ValidField f) (Point p) -> finite3 (fieldAccel [f] p)

    prop "fields still superpose: the sum is the sum of the parts" $
      \(ValidField a) (ValidField b) (Point p) ->
        let V3 sx sy sz = fieldAccel [a, b] p
            V3 ax ay az = fieldAccel [a] p
            V3 bx by bz = fieldAccel [b] p
         in counterexample (show (a, b, p)) $
              abs (sx - (ax + bx)) < epsilon
                && abs (sy - (ay + by)) < epsilon
                && abs (sz - (az + bz)) < epsilon

  describe "the zero-field fast path is untouched (ADR-0010 D9)" $ do
    prop "an empty field list is exactly the zero vector" $ \(Point p) ->
      fieldAccel [] p === V3 0 0 0

    it "and the existing three still answer what they always did" $ do
      fieldAccel [Gravity (V3 0 (-3) 0)] (V3 5 5 5) `shouldBe` V3 0 (-3) 0
      -- An attractor pulls towards its centre.
      let V3 _ ay _ = fieldAccel [PointAttractor (V3 0 0 0) 6 0.5] (V3 0 2 0)
      ay `shouldSatisfy` (< 0)

  describe "Spring: a linear restoring force" $ do
    it "pulls back towards the centre, never away" $ do
      let center = V3 0 1 0
          V3 _ ay _ = fieldAccel [Spring center 3] (V3 0 4 0)
      ay `shouldSatisfy` (< 0)

    prop "is exactly linear in the offset from its centre: a(2d) = 2·a(d)" $
      forAll (choose (0.1, 8)) $ \k ->
        \(Point center) (Point offset) ->
          let f = Spring center k
              V3 ax ay az = fieldAccel [f] (center + offset)
              V3 bx by bz = fieldAccel [f] (center + vscale 2 offset)
           in counterexample (show (center, offset, k)) $
                abs (bx - 2 * ax) < epsilon
                  && abs (by - 2 * ay) < epsilon
                  && abs (bz - 2 * az) < epsilon

    prop "vanishes exactly at its centre — no singularity to fall into" $
      \(Point center) ->
        forAll (choose (0.1, 8)) $ \k ->
          fieldAccel [Spring center k] center === V3 0 0 0

  describe "Wind and Turbulence: deterministic, bounded wobble" $ do
    prop "the wobble repeats exactly at the same point" $
      \(Point p) ->
        conjoin [fieldAccel [f] p === fieldAccel [f] p | f <- newFields]

    prop "Turbulence stays within a bound set by its strength" $
      \(Point p) ->
        forAll (choose (0.1, 8)) $ \noiseScale ->
          forAll (choose (0.1, 6)) $ \strength ->
            -- Every component is a difference of two cosines scaled by a
            -- frequency component, so |accel| is bounded by strength times
            -- a constant of the potential; 8 is a comfortable one.
            norm (fieldAccel [Turbulence strength noiseScale] p) <= 8 * strength

    it "Wind's steady term is its direction at zero turbulence" $ do
      let a = fieldAccel [Wind (V3 0 2 0) 1.5 0] (V3 3 4 5)
      a `shouldBe` V3 0 1.5 0

    it "Wind actually varies with position once turbulence is on" $ do
      let f = Wind (V3 0 1 0) 1 1
      fieldAccel [f] (V3 0 0 0) `shouldNotBe` fieldAccel [f] (V3 1.3 0.7 2.1)

    it "a larger scale makes Turbulence vary more slowly" $ do
      let variation noiseScale =
            maximum
              [ norm (fieldAccel [Turbulence 1 noiseScale] (V3 d 0 0) - fieldAccel [Turbulence 1 noiseScale] (V3 0 0 0))
              | d <- [0.05, 0.1 .. 0.5]
              ]
      variation 8 `shouldSatisfy` (< variation 0.5)

    -- Backing §2.5's claim that the wobble is divergence-free: a field
    -- with divergence pumps particles into sources and sinks, which reads
    -- as clumping rather than as turbulence. Checked numerically, since
    -- the analytic identity is what the implementation is built on.
    it "Turbulence is divergence-free, to the accuracy of a difference quotient" $ do
      let h = 1e-2 :: Float
          f = Turbulence 1 1.5
          partial pick step p =
            let V3 ax ay az = fieldAccel [f] (p + step)
                V3 bx by bz = fieldAccel [f] (p - step)
             in (pick (ax, ay, az) - pick (bx, by, bz)) / (2 * h)
          divergenceAt p =
            partial (\(x, _, _) -> x) (V3 h 0 0) p
              + partial (\(_, y, _) -> y) (V3 0 h 0) p
              + partial (\(_, _, z) -> z) (V3 0 0 h) p
      mapM_
        (\p -> (p, divergenceAt p) `shouldSatisfy` ((< 1e-2) . abs . snd))
        [V3 0 0 0, V3 1.3 (-0.7) 2.1, V3 (-4) 3 0.5, V3 8 8 8]
