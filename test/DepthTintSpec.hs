-- | S4 (func-spec 0013 §7): the 2D depth tint.
--
-- The top view drops the vertical axis, so a formation that is spread
-- out in height arrives on screen as one flat blob. Darkening by depth
-- is the first cue against that (func-spec 0013 §8-4 books the rest),
-- and it has to be a cue that can be switched off completely: with the
-- tint at its default of 0 the colour stream must be the one func-spec
-- 0008 shipped, byte for byte, or every 2D assertion written before this
-- round would be measuring something else.
module DepthTintSpec (spec) where

import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word8)
import Magic.Particle.Buffer (ParticleBuffer (..), emptyBuffer, fromParticles)
import Magic.Projection (ViewPlane (..), depthOrder)
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Effects (FlatView (..))
import App.Loop (flatViewFor)
import App.Render.Flat (buildFlatQuads)
import App.Render.Quads (QuadBatch (..))

topView :: FlatView
topView = flatViewFor (1280, 720) TopXZ

sideView :: FlatView
sideView = flatViewFor (1280, 720) SideXY

withTint :: Float -> FlatView -> FlatView
withTint t fv = fv {fvDepthTint = t}

newtype Particles = Particles [(V3, Float, Float, Word32)]
  deriving (Show)

instance Arbitrary Particles where
  arbitrary = do
    n <- choose (0, 24)
    Particles <$> vectorOf n particle
    where
      particle = do
        p <- V3 <$> choose (-8, 8) <*> choose (-8, 8) <*> choose (-8, 8)
        s <- choose (0.01, 2)
        l <- choose (0, 1)
        c <- arbitrary
        pure (p, s, l, c)

bufferOf :: Particles -> ParticleBuffer
bufferOf (Particles ps) = fromParticles ps

-- | The same particles, all one colour. Depth is the only thing left
-- that can vary the output, which is what a claim about the shading
-- alone has to be stated over — two particles of different colours say
-- nothing about which one the tint darkened more.
uniformly :: Particles -> ParticleBuffer
uniformly (Particles ps) = fromParticles [(p, s, l, 0xC0C0C0FF) | (p, s, l, _) <- ps]

-- | The four colour bytes of quad @j@'s vertex @k@.
colorAt :: QuadBatch -> Int -> Int -> [Word8]
colorAt qb j k = [qbColors qb S.! (base + i) | i <- [0 .. 3]]
  where
    base = j * 16 + k * 4

expectedColor :: Word32 -> [Word8]
expectedColor c =
  [ fromIntegral (c `div` 0x1000000)
  , fromIntegral ((c `div` 0x10000) `mod` 0x100)
  , fromIntegral ((c `div` 0x100) `mod` 0x100)
  , fromIntegral (c `mod` 0x100)
  ]

-- | Perceived brightness of quad @j@: the sum of its RGB, which is all
-- a monotonicity claim needs.
brightnessAt :: QuadBatch -> Int -> Int
brightnessAt qb j = sum (map fromIntegral (take 3 (colorAt qb j 0)))

alphaAt :: QuadBatch -> Int -> Word8
alphaAt qb j = colorAt qb j 0 !! 3

-- | @(quad slot, source particle)@ pairs, in emission (far to near)
-- order.
slots :: FlatView -> ParticleBuffer -> [(Int, Int)]
slots fv pb = zip [0 ..] (U.toList (depthOrder (fvPlane fv) pb))

-- | A stack of particles at different heights, all the same colour, seen
-- from above: the exact case the tint exists for.
stack :: ParticleBuffer
stack = fromParticles [(V3 0 (fromIntegral k) 0, 1, 1, 0xC0C0C0FF) | k <- [0 .. 4 :: Int]]

spec :: Spec
spec = do
  describe "the tint is off by default (func-spec 0013 §1-4)" $ do
    prop "colours are the buffer's own, byte for byte" $ \ps ->
      forAll (elements [sideView, topView]) $ \fv ->
        let pb = bufferOf ps
            qb = buildFlatQuads fv pb
         in conjoin
              [ property (all (\k -> colorAt qb j k == expectedColor (pbColor pb U.! i)) [0 .. 3])
              | (j, i) <- slots fv pb
              ]

    prop "a tint of 0 is bit-identical to the same view with no tint field set" $ \ps ->
      let pb = bufferOf ps
       in qbColors (buildFlatQuads (withTint 0 topView) pb) === qbColors (buildFlatQuads topView pb)

    prop "a negative tint is treated as off, not as brightening" $ \ps ->
      let pb = bufferOf ps
       in qbColors (buildFlatQuads (withTint (-2) topView) pb) === qbColors (buildFlatQuads topView pb)

  describe "with the tint on" $ do
    it "the near end keeps its colour and the far end is darkened" $ do
      let qb = buildFlatQuads (withTint 0.5 topView) stack
          n = qbCount qb
      -- Emission is far to near, so the last quad is the nearest one.
      colorAt qb (n - 1) 0 `shouldBe` expectedColor 0xC0C0C0FF
      brightnessAt qb 0 `shouldSatisfy` (< brightnessAt qb (n - 1))

    prop "brightness never decreases from the far end to the near end" $ \ps ->
      forAll (choose (0.1, 1)) $ \t ->
        let qb = buildFlatQuads (withTint t topView) (uniformly ps)
            bs = map (brightnessAt qb) [0 .. qbCount qb - 1]
         in property (and (zipWith (<=) bs (drop 1 bs)))

    prop "alpha is never touched: transparency is not a depth cue" $ \ps ->
      forAll (choose (0, 1)) $ \t ->
        let pb = bufferOf ps
            fv = withTint t topView
            qb = buildFlatQuads fv pb
         in conjoin
              [ alphaAt qb j === last (expectedColor (pbColor pb U.! i))
              | (j, i) <- slots fv pb
              ]

    prop "geometry is untouched: the tint is a colour, not a transform" $ \ps ->
      forAll (choose (0, 1)) $ \t ->
        let pb = bufferOf ps
         in qbPositions (buildFlatQuads (withTint t topView) pb)
              === qbPositions (buildFlatQuads topView pb)

    prop "a stronger tint is never brighter" $ \ps ->
      let pb = bufferOf ps
          bright t = map (brightnessAt (buildFlatQuads (withTint t topView) pb)) [0 .. pbCount pb - 1]
       in property (and (zipWith (>=) (bright 0.3) (bright 0.9)))

    it "clamps at 1: the far end goes black, never below" $ do
      let qb = buildFlatQuads (withTint 5 topView) stack
      take 3 (colorAt qb 0 0) `shouldBe` [0, 0, 0]
      alphaAt qb 0 `shouldBe` 0xFF

    it "a batch with no depth range is left alone" $ do
      -- One particle, and several at the same height: in both cases
      -- "far" and "near" are the same depth, so there is nothing to
      -- normalise against and nothing to shade.
      let one = fromParticles [(V3 0 3 0, 1, 1, 0xC0C0C0FF)]
          flat = fromParticles [(V3 (fromIntegral k) 3 0, 1, 1, 0xC0C0C0FF) | k <- [0 .. 3 :: Int]]
          qbOne = buildFlatQuads (withTint 1 topView) one
          qbFlat = buildFlatQuads (withTint 1 topView) flat
      colorAt qbOne 0 0 `shouldBe` expectedColor 0xC0C0C0FF
      map (\j -> colorAt qbFlat j 0) [0 .. 3] `shouldSatisfy` all (== expectedColor 0xC0C0C0FF)

    it "an empty buffer is still empty" $
      qbCount (buildFlatQuads (withTint 1 topView) emptyBuffer) `shouldBe` 0

    it "works in the side view too, where depth is the dropped Z" $ do
      let pb = fromParticles [(V3 0 0 (-4), 1, 1, 0xC0C0C0FF), (V3 0 0 4, 1, 1, 0xC0C0C0FF)]
          qb = buildFlatQuads (withTint 0.5 sideView) pb
      brightnessAt qb 0 `shouldSatisfy` (< brightnessAt qb 1)
