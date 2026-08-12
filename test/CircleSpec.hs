-- | T-S1 (func-spec 0002 §8): the real circle slot structure and the new
-- face-plane vocabulary (V2, basisFromNormal).
module CircleSpec (spec) where

import Data.Maybe (isNothing)
import Magic.Circle
  ( Circle (..)
  , Core (..)
  , Nodes (..)
  , TwoOf (..)
  , emptyCircle
  )
import Magic.Rune
  ( InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (V2 (..), V3 (..), basisFromNormal, dot, norm)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Arbitrary non-degenerate normals: components in a sane range, length
-- comfortably above zero so 'basisFromNormal' is well conditioned.
newtype NonZeroV3 = NonZeroV3 V3
  deriving (Show)

instance Arbitrary NonZeroV3 where
  arbitrary =
    fmap NonZeroV3 $
      suchThat
        (V3 <$> component <*> component <*> component)
        (\v -> norm v > 1e-2)
    where
      component = choose (-10, 10)

spec :: Spec
spec = describe "Magic.Circle structure ADTs (spec 0002 S1)" $ do
  it "emptyCircle has every slot Nothing" $ do
    let c = emptyCircle
    ringA (outerRings c) `shouldSatisfy` isNothing
    ringB (outerRings c) `shouldSatisfy` isNothing
    interLayer c `shouldSatisfy` isNothing
    ringA (innerRings c) `shouldSatisfy` isNothing
    ringB (innerRings c) `shouldSatisfy` isNothing
    coreCenter (core c) `shouldSatisfy` isNothing
    north (coreNodes (core c)) `shouldSatisfy` isNothing
    south (coreNodes (core c)) `shouldSatisfy` isNothing
    east (coreNodes (core c)) `shouldSatisfy` isNothing
    west (coreNodes (core c)) `shouldSatisfy` isNothing

  it "TwoOf construction and access keep A/B apart" $ do
    let pair = TwoOf (Just (RadiateRune RadialOutward)) Nothing
    ringA pair `shouldBe` Just (RadiateRune RadialOutward)
    ringB pair `shouldBe` (Nothing :: Maybe OuterRune)

  it "Nodes construction and access address all four directions" $ do
    let nodes =
          Nodes
            { north = Just (DirBias 1.0)
            , south = Nothing
            , east = Just (DirBias (-0.5))
            , west = Nothing
            }
    north nodes `shouldBe` Just (DirBias 1.0)
    south nodes `shouldBe` Nothing
    east nodes `shouldBe` Just (DirBias (-0.5))
    west nodes `shouldBe` Nothing

  it "a populated circle roundtrips through its record fields" $ do
    let c =
          emptyCircle
            { innerRings = TwoOf (Just (TrajectoryRune (Forward 3))) Nothing
            }
    ringA (innerRings c) `shouldBe` Just (TrajectoryRune (Forward 3))
    ringB (innerRings c) `shouldBe` Nothing

  it "V2 componentwise Num arithmetic" $ do
    V2 1 2 + V2 3 4 `shouldBe` V2 4 6
    V2 3 4 - V2 1 2 `shouldBe` V2 2 2
    V2 2 3 * V2 4 5 `shouldBe` V2 8 15
    negate (V2 1 (-2)) `shouldBe` V2 (-1) 2
    abs (V2 (-3) 4) `shouldBe` V2 3 4
    (5 :: V2) `shouldBe` V2 5 5

  prop "basisFromNormal: both basis vectors are unit length" $
    \(NonZeroV3 n) ->
      let (u, w) = basisFromNormal n
       in abs (norm u - 1) < 1e-4 && abs (norm w - 1) < 1e-4

  prop "basisFromNormal: basis vectors and normal are pairwise orthogonal" $
    \(NonZeroV3 n) ->
      let (u, w) = basisFromNormal n
          nn = norm n
       in abs (dot u w) < 1e-4
            && abs (dot u n / nn) < 1e-4
            && abs (dot w n / nn) < 1e-4

  it "basisFromNormal matches the 0001 fountain basis rule for +Y facing" $ do
    -- facing (0,1,0): refAxis = X, u = normalize (n × X) = (0,0,-1),
    -- w = n × u = (-1,0,0) — the exact lateral pair the 0001 stub used.
    let (u, w) = basisFromNormal (V3 0 1 0)
    u `shouldBe` V3 0 0 (-1)
    w `shouldBe` V3 (-1) 0 0
