-- | S2 (func-spec 0020 §7): the derivation — how a circle decides how its
-- sigil turns.
--
-- Same hybrid rule func-spec 0016 established (ADR-0014): /the structure
-- sets the skeleton, the digest sets the ornament/. Here the skeleton is
-- the turn /direction/ — neighbouring rings counter-rotate, the
-- silhouette turns positively and slowest — and the digest sets the two
-- magnitudes. The charge-up landmark is neither: it is @castStart@, read
-- straight off the circle's own @phases@ and baked into the data so the
-- sampler never has to ask what phase it is in (§2.3).
--
-- The load-bearing assertion of this module is the last one. Func-spec
-- 0020 §3.2 requires that the bits it reads do not collide with the ones
-- 0016 already spent, because a collision would silently restyle every
-- spell in existence — exactly the break ADR-0014 froze 'hashCircle' to
-- prevent. The witness is a digest over every geometry field 'sigilPlan'
-- produces, captured from the build /before/ this round and pinned below:
-- if 0020 had taken so much as one bit 0016 was using, those numbers move.
--
-- (§3.2's single-bit-flip witness is not what is used here, and cannot
-- be: a layer's ornament comes from @mixW d layerIndex@, which depends on
-- every bit of the digest, so flipping any bit at all changes the
-- geometry. The pinned digest tests the same claim end to end and does
-- not need a new export to do it — see 實作備註-2.)
module SigilMotionSpec (spec) where

import Data.Bits (shiftR, xor)
import qualified Data.ByteString as BS
import Data.List (foldl')
import qualified Data.Vector as V
import Data.Word (Word64)
import GHC.Float (castFloatToWord32)
import Magic.Circle (Circle (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Rune (BridgeRune (..), InnerRune (..), OuterRune (..), RadiationMode (..), Trajectory (..))
import Magic.Sigil
  ( SigilPlan (..)
  , SigilSpin (..)
  , SigilStroke (..)
  , sigilPlan
  )
import Magic.Types (Seconds (..))
import SigilGen (genAnyCircle)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- Fixtures --------------------------------------------------------------------

filler :: Int -> Circle -> Circle
filler n c = case n of
  0 -> c {outerRings = TwoOf (ringA (outerRings c)) (Just (RadiateRune AlongNormal))}
  1 -> c {outerRings = TwoOf (Just (RadiateRune RadialOutward)) (ringB (outerRings c))}
  2 -> c {interLayer = Just (PhaseRune (Seconds 0))}
  3 -> c {innerRings = TwoOf (ringA (innerRings c)) (Just (TrajectoryRune (Forward 1)))}
  _ -> c {innerRings = TwoOf (Just (TrajectoryRune (Forward 2))) (ringB (innerRings c))}

-- | A circle with exactly @k@ of the five ring slots occupied — the same
-- ladder @test\/SigilPlanSpec.hs@ walks.
withRingSlots :: Int -> Circle
withRingSlots k = foldr filler emptyCircle [0 .. k - 1]

-- | The five ring slots occupied but only the /outer/ two and the
-- /inner/ two: a gap in the middle. This is the shape that made
-- 實作備註-3 necessary — with the turn direction keyed on the layer's own
-- index, the two rings either side of the gap would turn the same way.
gappedCircle :: Circle
gappedCircle = filler 3 (filler 1 (filler 0 emptyCircle))

exampleCircle :: String -> IO Circle
exampleCircle name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

strokesOf :: Circle -> [SigilStroke]
strokesOf = V.toList . spStrokes . sigilPlan

spinsOf :: Circle -> [SigilSpin]
spinsOf = map skSpin . strokesOf

-- | @castStart@ as spec 0006 §4.3 defines it, recomputed here from the
-- circle rather than from the compiler, so the assertion is independent
-- of the code it is checking.
castStartOf :: Circle -> Float
castStartOf circle = case circlePhases circle of
  Nothing -> 0
  Just (PhaseConfig (Seconds d) (Seconds c)) -> realToFrac (d + c)

-- The pinned geometry digest ---------------------------------------------------

mix :: Word64 -> Word64 -> Word64
mix h w = let a = (h `xor` w) * 0x100000001B3 in a `xor` (a `shiftR` 29)

mixStr :: Word64 -> String -> Word64
mixStr = foldl' (\h c -> mix h (fromIntegral (fromEnum c)))

mixF :: Word64 -> Float -> Word64
mixF h x = mix h (fromIntegral (castFloatToWord32 x))

-- | Every field of a 'SigilPlan' /except/ 'skSpin', folded bit for bit.
geoDigest :: SigilPlan -> Word64
geoDigest plan =
  foldl' shapeD (foldl' strokeD start (V.toList (spStrokes plan))) (V.toList (spShapes plan))
  where
    start = mix 0xcbf29ce484222325 (fromIntegral (spSymmetry plan))
    strokeD h sk =
      (`mix` fromIntegral (skCount sk))
        . (`mixF` skJitter sk)
        . (`mixF` skPhase sk)
        . (`mix` fromIntegral (skSymmetry sk))
        . (`mixF` skRadius sk)
        $ mixStr h (show (skKind sk))
    shapeD h (shape, cnt) = mix (mixStr h (show shape)) (fromIntegral cnt)

-- | Captured on the pre-0020 build (2026-08-16). Every one of these must
-- still hold: 0020 adds a field, it does not restyle a single figure.
geoBaseline :: [(String, Word64)]
geoBaseline =
  [ ("slots0", 790604333658646031)
  , ("slots1", 16774041902524926684)
  , ("slots2", 4636286695363591915)
  , ("slots3", 2471080696547180508)
  , ("slots4", 13249787510029837091)
  , ("slots5", 16283166243453096943)
  ]

exampleGeoBaseline :: [(String, Word64)]
exampleGeoBaseline =
  [ ("bare-sigil", 16438032747872751099)
  , ("converge-flame", 16976113679035339303)
  , ("empty", 790604333658646031)
  , ("grand-sigil", 4507938170912728483)
  , ("gravity-well", 540547766616725410)
  , ("lattice-seal", 2867691945996268027)
  , ("lissajous", 8645656288436664458)
  , ("pulse-ring", 17028378734177818919)
  , ("ring-fire", 5494360285590931855)
  , ("soft-bloom", 11386783351695236849)
  , ("spiral-spark", 6866269345725959792)
  , ("square-burst", 2283397954805120726)
  ]

spec :: Spec
spec = describe "sigil spin derivation (func-spec 0020 S2)" $ do
  prop "is a deterministic function of the circle, spin included" $
    forAll genAnyCircle $ \c -> sigilPlan c === sigilPlan c

  describe "the direction comes from the structure" $ do
    it "the silhouette turns positively, at the bottom of the band, with no charge-up" $
      sequence_
        [ take 2 (spinsOf (withRingSlots k))
            `shouldBe` [SigilSpin 0.05 0 0, SigilSpin 0.05 0 0]
        | k <- [0 .. 5]
        ]

    it "neighbouring rings counter-rotate, all the way in (five layers)" $ do
      let signs = map (signum . ssRate) (spinsOf (withRingSlots 5))
      -- Two silhouette strokes are one group, then the five layers.
      signs `shouldBe` [1, 1, -1, 1, -1, 1, -1]

    it "a gap in the middle does not break the alternation (實作備註-3)" $ do
      let signs = map (signum . ssRate) (spinsOf gappedCircle)
      length (strokesOf gappedCircle) `shouldBe` 5
      signs `shouldBe` [1, 1, -1, 1, -1]

    it "the three shipped sigils alternate too" $
      mapM_
        ( \name -> do
            circle <- exampleCircle name
            let signs = drop 2 (map (signum . ssRate) (spinsOf circle))
            signs `shouldBe` take (length signs) (cycle [-1, 1])
        )
        ["grand-sigil", "lattice-seal", "soft-bloom"]

    prop "the direction is never zero for a layer, and never flips inside one" $
      forAll genAnyCircle $ \c ->
        conjoin
          [ counterexample (show sp) $
              signum (ssRate sp)
                =/= 0
                .&&. (ssAccel sp === 0 .||. signum (ssAccel sp) === signum (ssRate sp))
          | sp <- spinsOf c
          ]

  describe "the magnitudes come from the digest" $ do
    prop "|ssRate| stays inside the band [0.05, 0.45]" $
      forAll genAnyCircle $ \c ->
        conjoin
          [ counterexample (show sp) (abs (ssRate sp) >= 0.05 && abs (ssRate sp) <= 0.45)
          | sp <- spinsOf c
          ]

    prop "|ssAccel| stays inside [0, 0.30]" $
      forAll genAnyCircle $ \c ->
        conjoin
          [ counterexample (show sp) (abs (ssAccel sp) >= 0 && abs (ssAccel sp) <= 0.30)
          | sp <- spinsOf c
          ]

    it "two circles that differ only in content spin differently" $ do
      let a = emptyCircle {interLayer = Just (PhaseRune (Seconds 0.1))}
          b = emptyCircle {interLayer = Just (PhaseRune (Seconds 0.2))}
      length (spinsOf a) `shouldBe` length (spinsOf b)
      drop 2 (spinsOf a) `shouldNotBe` drop 2 (spinsOf b)

    it "the shipped sigils actually charge up (some layer has a real acceleration)" $
      mapM_
        ( \name -> do
            circle <- exampleCircle name
            maximum (map (abs . ssAccel) (spinsOf circle)) `shouldSatisfy` (> 0.01)
        )
        ["grand-sigil", "lattice-seal", "soft-bloom"]

  describe "the charge-up landmark is castStart, baked in at compile time" $ do
    prop "ssRampEnd == phDraw + phConverge for every stroke of any circle" $
      forAll genAnyCircle $ \c ->
        conjoin
          [counterexample (show sp) (ssRampEnd sp === castStartOf c) | sp <- spinsOf c]

    it "the shipped sigils carry their own castStart" $
      mapM_
        ( \(name, expected) -> do
            circle <- exampleCircle name
            map ssRampEnd (spinsOf circle) `shouldSatisfy` all (== expected)
        )
        [("bare-sigil", 1.5), ("grand-sigil", 1.8), ("lattice-seal", 2.4), ("soft-bloom", 2.0)]

  describe "0020's bits do not collide with 0016's (§3.2)" $ do
    it "the derived geometry of the slot ladder is bit-for-bit the pre-0020 build's" $
      sequence_
        [ (name, geoDigest (sigilPlan (withRingSlots k))) `shouldBe` (name, expected)
        | (k, (name, expected)) <- zip [0 ..] geoBaseline
        ]

    it "and so is every shipped example's" $
      mapM_
        ( \(name, expected) -> do
            circle <- exampleCircle name
            (name, geoDigest (sigilPlan circle)) `shouldBe` (name, expected)
        )
        exampleGeoBaseline

    it "covers every shipped example" $
      length exampleGeoBaseline `shouldBe` 12
