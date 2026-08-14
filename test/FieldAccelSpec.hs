-- | S2 (func-spec 0007 §8): the geometry of 'fieldAccel'. Each of the
-- three v1 fields (ADR-0010 D5) is pinned by the property that makes it
-- that field — constant, central, swirling — plus the superposition law
-- that lets a circle carry several at once.
module FieldAccelSpec (spec) where

import Magic.Particle.Field (fieldAccel)
import Magic.Rune (ForceField (..))
import Magic.Types (V3 (..), cross, dot, norm, normalize, vscale)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, forAll, suchThat)

-- Generators -------------------------------------------------------------------

coord :: Gen Float
coord = choose (-8, 8)

point :: Gen V3
point = V3 <$> coord <*> coord <*> coord

-- | A point at a non-degenerate distance from the given center.
pointAwayFrom :: V3 -> Gen V3
pointAwayFrom c = point `suchThat` \p -> norm (p - c) > 0.25

nonZeroVec :: Gen V3
nonZeroVec = point `suchThat` \v -> norm v > 0.5

strength :: Gen Float
strength = choose (0.5, 10)

-- | Kept away from 0 so the near-singular magnitudes stay in a range
-- where a fixed Float tolerance is meaningful; the softening bound
-- property below covers the whole legal range's purpose (no blow-up).
softening :: Gen Float
softening = choose (0.5, 2)

falloff :: Gen Float
falloff = choose (0, 3)

-- | Componentwise comparison with a tolerance — these are Float sums of
-- square roots, so exact equality is the wrong assertion everywhere
-- except the empty-field case.
close :: Float -> V3 -> V3 -> Bool
close eps (V3 ax ay az) (V3 bx by bz) =
  abs (ax - bx) <= eps && abs (ay - by) <= eps && abs (az - bz) <= eps

spec :: Spec
spec = describe "fieldAccel: field geometry (spec 0007 S2)" $ do
  describe "the empty field list" $
    prop "is exactly zero everywhere (the D9 degenerate case)" $
      forAll point $ \p -> fieldAccel [] p == V3 0 0 0

  describe "Gravity" $ do
    prop "is the same constant acceleration at every point" $
      forAll ((,,) <$> point <*> point <*> point) $ \(a, p, q) ->
        fieldAccel [Gravity a] p == a && fieldAccel [Gravity a] q == a

  describe "PointAttractor" $ do
    prop "positive strength pulls straight towards the center" $
      forAll ((,,) <$> point <*> strength <*> softening) $ \(c, s, soft) ->
        forAll (pointAwayFrom c) $ \p ->
          let a = fieldAccel [PointAttractor c s soft] p
              toCenter = normalize (c - p)
           in norm a > 0 && close 1e-4 (normalize a) toCenter

    prop "negative strength pushes straight away from the center" $
      forAll ((,,) <$> point <*> strength <*> softening) $ \(c, s, soft) ->
        forAll (pointAwayFrom c) $ \p ->
          let a = fieldAccel [PointAttractor c (negate s) soft] p
              awayFromCenter = normalize (p - c)
           in norm a > 0 && close 1e-4 (normalize a) awayFromCenter

    prop "the magnitude strictly decreases with distance" $
      forAll ((,,) <$> point <*> strength <*> softening) $ \(c, s, soft) ->
        forAll ((,) <$> nonZeroVec <*> choose (0.5, 3)) $ \(dir, k :: Float) ->
          let unit = normalize dir
              near = c + vscale 1 unit
              far = c + vscale (1 + k) unit
           in norm (fieldAccel [PointAttractor c s soft] far)
                < norm (fieldAccel [PointAttractor c s soft] near)

    prop "softening bounds the magnitude at the center by strength/softening^2" $
      forAll ((,,) <$> point <*> strength <*> softening) $ \(c, s, soft) ->
        forAll point $ \p ->
          norm (fieldAccel [PointAttractor c s soft] p) <= s / (soft * soft) + 1e-4

    it "is exactly zero at the singular point itself (no NaN, no infinity)" $
      fieldAccel [PointAttractor (V3 1 2 3) 5 0.5] (V3 1 2 3) `shouldBe` V3 0 0 0

  describe "Vortex" $ do
    prop "is perpendicular to both the axis and the off-axis (radial) direction" $
      forAll ((,,) <$> point <*> nonZeroVec <*> strength) $ \(c, axis0, s) ->
        forAll ((,) <$> point <*> falloff) $ \(p, f) ->
          let axis = normalize axis0
              offset = p - c
              offAxis = offset - vscale (dot offset axis) axis
              a = fieldAccel [Vortex c axis0 s f] p
           in norm offAxis < 1e-3 -- degenerate: on the axis, no swirl
                || (abs (dot a axis) <= 1e-3 && abs (dot a (normalize offAxis)) <= 1e-3)

    prop "with falloff = 0 the magnitude is |strength| regardless of off-axis distance" $
      forAll ((,,) <$> point <*> nonZeroVec <*> strength) $ \(c, axis0, s) ->
        forAll point $ \p ->
          let axis = normalize axis0
              offset = p - c
              offAxis = offset - vscale (dot offset axis) axis
              a = fieldAccel [Vortex c axis0 s 0] p
           in norm offAxis < 1e-3 || abs (norm a - s) <= 1e-3

    prop "falloff > 0 weakens the swirl the further off-axis you go" $
      forAll ((,,) <$> point <*> nonZeroVec <*> strength) $ \(c, axis0, s) ->
        forAll ((,) <$> nonZeroVec <*> choose (0.5, 3)) $ \(dir, k :: Float) ->
          let axis = normalize axis0
              offset = dir - vscale (dot dir axis) axis
           in norm offset < 1e-2
                || let unit = normalize offset
                       near = c + unit
                       far = c + vscale (1 + k) unit
                    in norm (fieldAccel [Vortex c axis0 s 1.5] far)
                         < norm (fieldAccel [Vortex c axis0 s 1.5] near)

    prop "swirls in the (axis cross radial) sense, right-handed about the axis" $
      forAll ((,,) <$> point <*> nonZeroVec <*> strength) $ \(c, axis0, s) ->
        forAll point $ \p ->
          let axis = normalize axis0
              offset = p - c
              offAxis = offset - vscale (dot offset axis) axis
              a = fieldAccel [Vortex c axis0 s 0.5] p
           in norm offAxis < 1e-3 || dot a (cross axis offAxis) > 0

    it "is exactly zero on the axis itself (no NaN from the degenerate tangent)" $
      fieldAccel [Vortex (V3 0 0 0) (V3 0 0 1) 4 0.2] (V3 0 0 2.5) `shouldBe` V3 0 0 0

  describe "superposition" $ do
    prop "a field list is the sum of its fields evaluated one at a time" $
      forAll ((,,) <$> point <*> nonZeroVec <*> strength) $ \(c, axis, s) ->
        forAll ((,,) <$> point <*> point <*> softening) $ \(p, g, soft) ->
          let fields = [Gravity g, PointAttractor c s soft, Vortex c axis s 0.4]
              summed = foldr ((+) . (\f -> fieldAccel [f] p)) (V3 0 0 0) fields
           in close 1e-3 (fieldAccel fields p) summed

    prop "a repeated field doubles the acceleration" $
      forAll ((,) <$> point <*> point) $ \(g, p) ->
        close 1e-4 (fieldAccel [Gravity g, Gravity g] p) (vscale 2 g)
