-- | T2 (func-spec 0001 §8): V3 algebra properties.
module TypesSpec (spec) where

import Magic.Types
  ( Seed (..)
  , V3 (..)
  , cross
  , dot
  , hashChan
  , norm
  , normalize
  , vscale
  )
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- Components bounded so products stay well inside Float range and
-- tolerances can be scaled sensibly.
genV3 :: Gen V3
genV3 = V3 <$> component <*> component <*> component
  where
    component = realToFrac <$> choose (-100 :: Double, 100)

approx :: Float -> Float -> Float -> Expectation
approx tolerance expected actual =
  abs (expected - actual) `shouldSatisfy` (<= tolerance)

spec :: Spec
spec = describe "Magic.Types (V3 algebra)" $ do
  prop "addition commutes (bit-exact: IEEE + is commutative)" $
    forAll genV3 $ \a -> forAll genV3 $ \b ->
      a + b == b + a

  prop "addition associates within tolerance" $
    forAll genV3 $ \a -> forAll genV3 $ \b -> forAll genV3 $ \c ->
      let V3 x1 y1 z1 = (a + b) + c
          V3 x2 y2 z2 = a + (b + c)
          tol = 1e-3
       in abs (x1 - x2) <= tol && abs (y1 - y2) <= tol && abs (z1 - z2) <= tol

  prop "zero is the additive identity" $
    forAll genV3 $ \a -> a + V3 0 0 0 == a

  prop "normalize yields unit length for non-degenerate vectors" $
    forAll genV3 $ \v ->
      norm v > 1e-3 ==> abs (norm (normalize v) - 1) <= 1e-4

  it "normalize maps the zero vector to zero" $
    normalize (V3 0 0 0) `shouldBe` V3 0 0 0

  prop "cross product is orthogonal to both operands" $
    forAll genV3 $ \a -> forAll genV3 $ \b ->
      let c = cross a b
          tol = 0.05 * (1 + norm a * norm b)
       in abs (dot c a) <= tol && abs (dot c b) <= tol

  prop "dot of a vector with itself is its squared norm" $
    forAll genV3 $ \a ->
      let n = norm a
       in abs (dot a a - n * n) <= 0.05 * (1 + n * n)

  prop "scaling scales the norm by |s|" $
    forAll genV3 $ \a -> forAll (choose (-10 :: Double, 10)) $ \sD ->
      let s = realToFrac sD :: Float
       in abs (norm (vscale s a) - abs s * norm a) <= 0.01 * (1 + abs s * norm a)

  describe "hashChan (deterministic random channels)" $ do
    prop "always lands in [0, 1)" $
      \(sd :: Word) i c ->
        let v = hashChan (Seed (fromIntegral sd)) i c
         in v >= 0 && v < 1

    it "is deterministic in (seed, index, channel)" $
      hashChan (Seed 42) 7 1 `shouldBe` hashChan (Seed 42) 7 1

    it "differs across particle indices (spot check)" $
      let vs = [hashChan (Seed 42) i 0 | i <- [0 .. 255]]
       in length (filter (/= head vs) vs) `shouldSatisfy` (> 200)
