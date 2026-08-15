-- | S3 (func-spec 0016 §7): 'sigilPlan' — the derivation rules that turn
-- a circle into the strokes it is drawn with.
--
-- The claim being guarded is the hybrid rule (ADR-0014): /structure sets
-- the skeleton, the digest sets the ornament/. So the layer count is a
-- function of which slots are occupied (a table this module spells out),
-- the symmetry order is centered on that same count, and everything else
-- — which stroke, at which phase, with which parameters — is a function
-- of the digest alone.
--
-- Plus the two bounds that must hold by construction rather than by
-- luck: @Σ skCount@ never exceeds 'sigilBudget', and the func-spec 0006
-- §4.4 'ShapeRune' exception survives.
module SigilPlanSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import Magic.Circle (Circle (..), TwoOf (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Rune
  ( BridgeRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Sigil
  ( SigilPlan (..)
  , SigilStroke (..)
  , StrokeKind (..)
  , sigilBudget
  , sigilPlan
  )
import Magic.Types (Seconds (..))
import SigilGen (genAnyCircle)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

filler :: Int -> Circle -> Circle
filler n c = case n of
  0 -> c {outerRings = TwoOf (ringA (outerRings c)) (Just (RadiateRune AlongNormal))}
  1 -> c {outerRings = TwoOf (Just (RadiateRune RadialOutward)) (ringB (outerRings c))}
  2 -> c {interLayer = Just (PhaseRune (Seconds 0))}
  3 -> c {innerRings = TwoOf (ringA (innerRings c)) (Just (TrajectoryRune (Forward 1)))}
  _ -> c {innerRings = TwoOf (Just (TrajectoryRune (Forward 2))) (ringB (innerRings c))}

-- | A circle with exactly @k@ of the five ring slots occupied.
withRingSlots :: Int -> Circle
withRingSlots k = foldr filler emptyCircle [0 .. k - 1]

planOf :: Circle -> SigilPlan
planOf = sigilPlan

strokesOf :: Circle -> [SigilStroke]
strokesOf = V.toList . spStrokes . planOf

exampleCircle :: String -> IO Circle
exampleCircle name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

spec :: Spec
spec = describe "sigilPlan: structure sets the skeleton, the digest the ornament (S3)" $ do
  prop "is a deterministic function of the circle" $
    forAll genAnyCircle $ \c -> sigilPlan c === sigilPlan c

  describe "the skeleton comes from the structure" $ do
    it "the all-empty circle still gets its boundary group" $ do
      let strokes = strokesOf emptyCircle
      map skKind strokes `shouldSatisfy` \ks -> case ks of
        (ArcRing 1 : Ticks _ : _) -> True
        _ -> False
      length strokes `shouldBe` 2

    it "occupied ring slots map to layers: k slots -> 2 boundary strokes + k layers" $
      sequence_
        [ length (strokesOf (withRingSlots k)) `shouldBe` 2 + k
        | k <- [0 .. 5]
        ]

    it "layer radii come from func-spec 0006's bands, outside in" $ do
      let layers = drop 2 (strokesOf (withRingSlots 5))
      map skRadius layers `shouldBe` [1.30, 1.15, 1.00, 0.85, 0.70]

    it "the boundary group is always first, at the silhouette radius" $
      sequence_
        [ map skRadius (take 2 (strokesOf (withRingSlots k))) `shouldBe` [1.5, 1.4]
        | k <- [0 .. 5]
        ]

    prop "the symmetry order stays in [3..9] for any circle" $
      forAll genAnyCircle $ \c ->
        let s = spSymmetry (sigilPlan c)
         in counterexample (show s) (s >= 3 && s <= 9)

    it "the symmetry order is centered on the occupancy count (digest moves it by at most 1)" $
      sequence_
        [ abs (spSymmetry (planOf (withRingSlots k)) - min 9 (3 + k)) `shouldSatisfy` (<= 1)
        | k <- [0 .. 5]
        ]

  describe "the ornament comes from the digest" $ do
    it "two circles with the same occupancy but different contents differ" $ do
      let a = emptyCircle {interLayer = Just (PhaseRune (Seconds 0.1))}
          b = emptyCircle {interLayer = Just (PhaseRune (Seconds 0.2))}
      length (strokesOf a) `shouldBe` length (strokesOf b)
      strokesOf a `shouldNotBe` strokesOf b

    prop "every stroke's particle count is a whole number of arms" $
      forAll genAnyCircle $ \c ->
        conjoin
          [ counterexample (show sk) (skCount sk `mod` max 1 (skSymmetry sk) === 0)
          | sk <- strokesOf c
          ]

  describe "the budget bound holds by construction" $ do
    prop "Sigma skCount + shape previews <= sigilBudget for any circle" $
      forAll genAnyCircle $ \c ->
        let plan = sigilPlan c
            total =
              sum (map skCount (V.toList (spStrokes plan)))
                + sum (map snd (V.toList (spShapes plan)))
         in counterexample (show total) (total <= sigilBudget)

    it "a fully-loaded circle is under budget with every stroke still alive" $ do
      let plan = planOf (withRingSlots 5)
      V.length (spStrokes plan) `shouldBe` 7
      all ((> 0) . skCount) (V.toList (spStrokes plan)) `shouldBe` True

    it "clipping keeps the order and drops nothing that survives rounding" $ do
      -- Every kind's nominal counts are chosen so five layers at symmetry
      -- 9 overshoot; the clip is what brings them back.
      let plan = planOf (withRingSlots 5)
          counts = map skCount (V.toList (spStrokes plan))
      sum counts `shouldSatisfy` (<= sigilBudget)
      counts `shouldSatisfy` all (> 0)

  describe "the func-spec 0006 §4.4 ShapeRune exception survives" $ do
    it "an outer slot holding a ShapeRune previews the player's shape instead of a stroke" $ do
      let shape = Diamond 2
          c = emptyCircle {outerRings = TwoOf Nothing (Just (ShapeRune shape))}
          plan = planOf c
      V.toList (spShapes plan) `shouldBe` [(shape, 64)]
      -- ...and contributes no stroke of its own: boundary group only.
      length (V.toList (spStrokes plan)) `shouldBe` 2

    it "a non-ShapeRune outer occupant gets a stroke, not a preview" $ do
      let c = emptyCircle {outerRings = TwoOf Nothing (Just (RadiateRune RadialOutward))}
          plan = planOf c
      spShapes plan `shouldBe` V.empty
      length (V.toList (spStrokes plan)) `shouldBe` 3

  describe "the three shipped sigils are three different figures" $
    it "bare-sigil, grand-sigil and lattice-seal have pairwise distinct plans" $ do
      plans <- mapM (fmap sigilPlan . exampleCircle) ["bare-sigil", "grand-sigil", "lattice-seal"]
      sequence_
        [ (a, b) `shouldSatisfy` uncurry (/=)
        | (i, a) <- zip [0 :: Int ..] plans
        , (j, b) <- zip [0 ..] plans
        , i < j
        ]
