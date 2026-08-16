-- | S6 (func-spec 0021 §7): second-tier top-view readability.
--
-- Func-spec 0013 gave the top view its first depth cue (darkening) and
-- booked the rest in its §8-4; func-spec 0008 §9-8 is where the problem
-- was first written down. The complaint is structural: an orthographic
-- projection maps every depth to the same scale /by definition/, so a
-- formation extruded along its normal arrives as one flat mat of quads.
-- Darkening recovers ordering; it does not recover extent.
--
-- The two cues here recover extent, and both do it by moving sizes only:
-- near particles are drawn larger and far ones smaller ('fvDepthScale'),
-- with a floor under the result so the near layer keeps an edge worth
-- recognising ('fvOutlineFloor'). Positions are never touched — a depth
-- cue that moved particles would be lying about where the spell is.
--
-- The first test is the one func-spec 0013 established as this layer's
-- convention and 0021 inherits: at the defaults the output is what the
-- pre-0021 build produced, bit for bit, not merely equal to it.
module FlatReadabilitySpec (spec) where

import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Particle.Buffer (ParticleBuffer (..), emptyBuffer, fromParticles)
import Magic.Projection (ViewPlane (..), depthOrder)
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Effects (FlatView (..))
import App.Loop (depthScaleStrength, flatViewFor, outlineFloorPixels)
import App.Render.Flat (buildFlatQuads, screenOf)
import App.Render.Quads (QuadBatch (..))

topView :: FlatView
topView = flatViewFor (1280, 720) TopXZ

readable :: FlatView -> FlatView
readable fv =
  fv {fvDepthScale = depthScaleStrength, fvOutlineFloor = outlineFloorPixels}

newtype Particles = Particles [(V3, Float, Float, Word32)]
  deriving (Show)

instance Arbitrary Particles where
  arbitrary = do
    n <- choose (0, 24)
    Particles <$> vectorOf n particle
    where
      particle = do
        p <- V3 <$> choose (-8, 8) <*> choose (-8, 8) <*> choose (-8, 8)
        s <- choose (0.05, 2)
        l <- choose (0, 1)
        c <- arbitrary
        pure (p, s, l, c)

bufferOf :: Particles -> ParticleBuffer
bufferOf (Particles ps) = fromParticles ps

vertexAt :: QuadBatch -> Int -> Int -> (Float, Float)
vertexAt qb j k =
  ( qbPositions qb S.! (j * 12 + k * 3)
  , qbPositions qb S.! (j * 12 + k * 3 + 1)
  )

-- | Half the on-screen width of quad @j@, read back off its vertices.
-- Vertex 0 is @(-r, -u)@ and vertex 1 is @(+r, -u)@, so their x gap is
-- the full edge.
--
-- Reconstructed, so it carries one rounding the renderer never performs:
-- claims about it are inequalities or come with a tolerance, never
-- equalities. The exact claim is made against the vertices themselves.
halfExtentAt :: QuadBatch -> Int -> Float
halfExtentAt qb j = (fst (vertexAt qb j 1) - fst (vertexAt qb j 0)) / 2

centerAt :: QuadBatch -> Int -> (Float, Float)
centerAt qb j = ((x0 + x2) / 2, (y0 + y2) / 2)
  where
    (x0, y0) = vertexAt qb j 0
    (x2, y2) = vertexAt qb j 2

centers :: QuadBatch -> [(Float, Float)]
centers qb = map (centerAt qb) [0 .. qbCount qb - 1]

-- | Same centre to within a thousandth of a pixel. The midpoint above is
-- reconstructed from two corners whose distance from it changed, so it
-- rounds differently even when the renderer placed the quad at exactly
-- the same spot; "did not move" is the claim, not "rounds identically".
sameCenters :: [(Float, Float)] -> [(Float, Float)] -> Property
sameCenters as bs =
  counterexample (show (as, bs)) $
    length as == length bs
      && and [abs (ax - bx) < 1e-3 && abs (ay - by) < 1e-3 | ((ax, ay), (bx, by)) <- zip as bs]

-- | A stack of same-sized particles at different heights, seen from
-- above: the exact case both cues exist for. Emission is far to near, so
-- the last quad is the nearest one.
stack :: ParticleBuffer
stack =
  fromParticles [(V3 0 (fromIntegral k) 0, 0.5, 1, 0xC0C0C0FF) | k <- [0 .. 4 :: Int]]

spec :: Spec
spec = describe "top-view readability, second tier (func-spec 0021 S6)" $ do
  describe "the zero-ripple law: both cues are off by default" $ do
    it "starts a fresh flat view with the flattening and the floor disabled" $ do
      fvDepthScale topView `shouldBe` 1
      fvOutlineFloor topView `shouldBe` 0

    -- Asserted on the vertices the renderer actually writes, not on a
    -- reconstructed half-extent: the claim is that the quad corners are
    -- still centre ± size·ppu/2, bit for bit.
    prop "at the defaults every corner is exactly centre ± size × ppu / 2" $ \ps ->
      let pb = bufferOf ps
          qb = buildFlatQuads topView pb
          order = depthOrder (fvPlane topView) pb
          ppu = fvPixelsPerUnit topView
       in conjoin
            [ conjoin
                [ vertexAt qb j 0 === (sx - h, sy + h)
                , vertexAt qb j 1 === (sx + h, sy + h)
                , vertexAt qb j 2 === (sx + h, sy - h)
                , vertexAt qb j 3 === (sx - h, sy - h)
                ]
            | j <- [0 .. qbCount qb - 1]
            , let i = order U.! j
                  (sx, sy) =
                    screenOf topView (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i))
                  h = (pbSize pb U.! i) * ppu * 0.5
            ]

    prop "setting the knobs to their off values changes nothing, bit for bit" $ \ps ->
      let pb = bufferOf ps
          explicit = topView {fvDepthScale = 1, fvOutlineFloor = 0}
       in qbPositions (buildFlatQuads explicit pb) === qbPositions (buildFlatQuads topView pb)

    prop "the cues never touch colour — that is the tint's job" $ \ps ->
      let pb = bufferOf ps
       in qbColors (buildFlatQuads (readable topView) pb)
            === qbColors (buildFlatQuads topView pb)

  describe "depth flattening restores the size gradient" $ do
    it "draws the near end larger than the far end, from equal sizes" $ do
      let qb = buildFlatQuads (topView {fvDepthScale = 3}) stack
          n = qbCount qb
      halfExtentAt qb 0 `shouldSatisfy` (< halfExtentAt qb (n - 1))

    it "orders the sizes monotonically from far to near" $ do
      let qb = buildFlatQuads (topView {fvDepthScale = 3}) stack
          hs = map (halfExtentAt qb) [0 .. qbCount qb - 1]
      and (zipWith (<=) hs (drop 1 hs)) `shouldBe` True

    it "leaves the middle of the batch at its own size" $ do
      let qb = buildFlatQuads (topView {fvDepthScale = 3}) stack
          plain = 0.5 * fvPixelsPerUnit topView * 0.5
      -- Five particles evenly spaced: index 2 sits at the midpoint,
      -- where the exponent is zero and the factor is exactly 1.
      abs (halfExtentAt qb 2 - plain) `shouldSatisfy` (< 1e-3)

    it "a stronger coefficient spreads the extremes further apart" $ do
      let spread k =
            let qb = buildFlatQuads (topView {fvDepthScale = k}) stack
                n = qbCount qb
             in halfExtentAt qb (n - 1) - halfExtentAt qb 0
      spread 1.5 `shouldSatisfy` (< spread 4)

    prop "a batch with no depth range is left at its plain sizes" $ \ps ->
      let Particles raw = ps
          -- Every particle at the same height: nothing to normalise
          -- against, so the cue has nothing to say.
          flatPb = fromParticles [(V3 x 3 z, s, l, c) | (V3 x _ z, s, l, c) <- raw]
       in qbPositions (buildFlatQuads (topView {fvDepthScale = 3}) flatPb)
            === qbPositions (buildFlatQuads topView flatPb)

  describe "the outline floor keeps a readable edge" $ do
    prop "no quad is ever drawn below the floor" $ \ps ->
      forAll (choose (1, 12)) $ \floorPx ->
        let pb = bufferOf ps
            qb = buildFlatQuads (topView {fvOutlineFloor = floorPx}) pb
         in conjoin
              [ counterexample (show (j, halfExtentAt qb j)) $
                  halfExtentAt qb j >= floorPx * 0.5 - 1e-4
              | j <- [0 .. qbCount qb - 1]
              ]

    prop "and every half-extent stays strictly positive" $ \ps ->
      let pb = bufferOf ps
          qb = buildFlatQuads (readable topView) pb
       in conjoin [halfExtentAt qb j > 0 | j <- [0 .. qbCount qb - 1]]

    it "never shrinks a particle that was already above the floor" $ do
      let big = fromParticles [(V3 0 0 0, 4, 1, 0xFFFFFFFF)]
          plain = buildFlatQuads topView big
          floored = buildFlatQuads (topView {fvOutlineFloor = 3}) big
      halfExtentAt floored 0 `shouldBe` halfExtentAt plain 0

  describe "both cues are size-only" $ do
    prop "particle centres are untouched by the flattening" $ \ps ->
      let pb = bufferOf ps
       in sameCenters
            (centers (buildFlatQuads (topView {fvDepthScale = 3}) pb))
            (centers (buildFlatQuads topView pb))

    prop "and untouched by the outline floor" $ \ps ->
      let pb = bufferOf ps
       in sameCenters
            (centers (buildFlatQuads (topView {fvOutlineFloor = 6}) pb))
            (centers (buildFlatQuads topView pb))

    prop "the quad count never changes" $ \ps ->
      let pb = bufferOf ps
       in qbCount (buildFlatQuads (readable topView) pb) === pbCount pb

    it "an empty buffer is still empty" $
      qbCount (buildFlatQuads (readable topView) emptyBuffer) `shouldBe` 0
