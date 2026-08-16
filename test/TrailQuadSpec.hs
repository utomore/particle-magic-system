-- | S6 (func-spec 0023 §6): velocity-stretched trail quads.
--
-- The geometry half of the round. Four things have to be true, and the
-- first is the one that makes the rest safe to have:
--
--   * a particle that is not moving draws the square it always drew,
--     __bit for bit__ — not "very nearly", because a trail batch's
--     stationary particles and a square batch's particles must be
--     indistinguishable or turning trails on would perturb every quad in
--     the frame;
--   * the stretch runs along the velocity /as the camera sees it/;
--   * the quad is still a quad: four coplanar corners in the same
--     rotational order, so 'App.Render.Quads.quadIndices' and
--     'quadTexcoords' still mean what they meant;
--   * the length is bounded. A player-written @formula@ trajectory can
--     produce arbitrarily fast particles, and an unbounded trail draws
--     one quad across the whole frame — which reads as a broken renderer,
--     not as a fast particle.
module TrailQuadSpec (spec) where

import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Render.Quads
  ( QuadBatch (..)
  , buildQuads
  , buildTrailQuads
  , trailMaxStretch
  , trailStretchOf
  , trailStretchPerUnit
  )
import Magic.Particle.Buffer (ParticleBuffer (..), buildBuffer, buildBufferWithVelocity)
import Magic.Types (V3 (..))

camPos, camTarget, camUp :: V3
camPos = V3 6 4 6
camTarget = V3 0 2 0
camUp = V3 0 1 0

-- | A buffer with velocities.
withVel :: [(V3, Float, V3)] -> ParticleBuffer
withVel rows = buildBufferWithVelocity (length rows) $ \write writeVel ->
  mapM_
    (\(i, (p, s, v)) -> write i p s 0.5 0xFFFFFFFF >> writeVel i v)
    (zip [0 ..] rows)

-- | The same particles with no velocity columns at all.
withoutVel :: [(V3, Float, V3)] -> ParticleBuffer
withoutVel rows = buildBuffer (length rows) $ \write ->
  mapM_ (\(i, (p, s, _)) -> write i p s 0.5 (0xFFFFFFFF :: Word32)) (zip [0 ..] rows)

-- | The four corners of quad @j@, as vectors.
cornersOf :: QuadBatch -> Int -> [V3]
cornersOf qb j =
  [ V3 (at (base + k * 3)) (at (base + k * 3 + 1)) (at (base + k * 3 + 2))
  | k <- [0 .. 3]
  ]
  where
    base = j * 12
    at i = qbPositions qb S.! i

cross3 :: V3 -> V3 -> V3
cross3 (V3 ax ay az) (V3 bx by bz) =
  V3 (ay * bz - az * by) (az * bx - ax * bz) (ax * by - ay * bx)

dot3 :: V3 -> V3 -> Float
dot3 (V3 ax ay az) (V3 bx by bz) = ax * bx + ay * by + az * bz

norm3 :: V3 -> Float
norm3 v = sqrt (dot3 v v)

genV3 :: Gen V3
genV3 = V3 <$> comp <*> comp <*> comp
  where
    comp = realToFrac <$> choose (-8 :: Double, 8)

genRow :: Gen (V3, Float, V3)
genRow = do
  p <- genV3
  s <- realToFrac <$> choose (0.05 :: Double, 1.5)
  v <- genV3
  pure (p, s, v)

spec :: Spec
spec = describe "trail quads (func-spec 0023 §6 S6)" $ do
  describe "a still particle is the square it always was" $ do
    prop "zero velocity reproduces buildQuads, bit for bit" $
      forAll (listOf ((\(p, s, _) -> (p, s, V3 0 0 0)) <$> genRow)) $ \rows ->
        let trailed = buildTrailQuads camPos camTarget camUp (withVel rows)
            plain = buildQuads camPos camTarget camUp (withVel rows)
         in qbPositions trailed === qbPositions plain
              .&&. qbColors trailed === qbColors plain
              .&&. qbCount trailed === qbCount plain

    prop "an absent velocity column does too" $
      -- A trail-tagged batch of a spell that computed no velocity draws
      -- squares rather than failing — the same forgiving rule
      -- @pm_observe_ex@ follows on the C side.
      forAll (listOf genRow) $ \rows ->
        let pb = withoutVel rows
         in qbPositions (buildTrailQuads camPos camTarget camUp pb)
              === qbPositions (buildQuads camPos camTarget camUp pb)

    it "treats a velocity pointing straight at the camera as still" $ do
      -- It has no projection onto the billboard plane, so there is no
      -- direction to stretch along and nothing to draw differently.
      let view = camTarget - camPos
          rows = [(V3 0 2 0, 0.4, view)]
          pb = withVel rows
      qbPositions (buildTrailQuads camPos camTarget camUp pb)
        `shouldBe` qbPositions (buildQuads camPos camTarget camUp pb)

  describe "the stretch follows the velocity" $ do
    prop "the long axis is parallel to the velocity's screen projection" $
      forAll genRow $ \(p, s, v) ->
        let pb = withVel [(p, s, v)]
            corners = cornersOf (buildTrailQuads camPos camTarget camUp pb) 0
            -- Corner 1 − corner 0 is the quad's first axis, doubled.
            axis = corners !! 1 - head corners
            -- The velocity with its towards-camera component removed.
            forward = vscale3 (1 / norm3 (camTarget - camPos)) (camTarget - camPos)
            planar = v - vscale3 (dot3 v forward) forward
         in norm3 planar > 1e-3 && norm3 axis > 1e-6 ==>
              let a = vscale3 (1 / norm3 axis) axis
                  b = vscale3 (1 / norm3 planar) planar
               in counterexample (show (a, b)) (abs (dot3 a b) > 0.99)

    prop "and points the same way, not the opposite way" $
      -- The sprite's opaque end is at +x (App.Render.Sprite), so a
      -- reversed axis would put the comet's head at its tail.
      forAll genRow $ \(p, s, v) ->
        let pb = withVel [(p, s, v)]
            corners = cornersOf (buildTrailQuads camPos camTarget camUp pb) 0
            axis = corners !! 1 - head corners
            forward = vscale3 (1 / norm3 (camTarget - camPos)) (camTarget - camPos)
            planar = v - vscale3 (dot3 v forward) forward
         in norm3 planar > 1e-3 && norm3 axis > 1e-6 ==>
              dot3 axis planar > 0

  describe "it is still a quad" $ do
    prop "the four corners stay coplanar" $
      forAll genRow $ \row ->
        let corners = cornersOf (buildTrailQuads camPos camTarget camUp (withVel [row])) 0
            [c0, c1, c2, c3] = take 4 corners
            n = cross3 (c1 - c0) (c3 - c0)
            outOfPlane = abs (dot3 n (c2 - c0))
         in counterexample (show corners) (outOfPlane <= 1e-3 * (1 + norm3 n))

    prop "opposite corners still share a midpoint (a parallelogram)" $
      -- The vertex order 'quadIndices' and 'quadTexcoords' were written
      -- against: (-a,-b), (+a,-b), (+a,+b), (-a,+b).
      forAll genRow $ \row ->
        let corners = cornersOf (buildTrailQuads camPos camTarget camUp (withVel [row])) 0
            [c0, c1, c2, c3] = take 4 corners
            m1 = vscale3 0.5 (c0 + c2)
            m2 = vscale3 0.5 (c1 + c3)
         in counterexample (show (m1, m2)) (norm3 (m1 - m2) <= 1e-3)

    prop "emits four vertices per particle, as the invariant says" $
      forAll (listOf genRow) $ \rows ->
        let qb = buildTrailQuads camPos camTarget camUp (withVel rows)
         in S.length (qbPositions qb) === qbCount qb * 4 * 3
              .&&. S.length (qbColors qb) === qbCount qb * 4 * 4

  describe "the length is bounded" $ do
    it "starts at 1, so a barely-moving particle keeps its own size" $
      -- The trail grows out of the particle rather than replacing it.
      trailStretchOf 0 `shouldBe` 1

    prop "grows with speed, and never past the cap" $
      forAll (choose (0, 1e6 :: Double)) $ \speed ->
        let k = trailStretchOf (realToFrac speed)
         in k >= 1 .&&. k <= trailMaxStretch

    it "grows at the frozen rate below the cap" $
      trailStretchOf 2 `shouldBe` 1 + 2 * trailStretchPerUnit

    prop "a very fast particle is capped rather than filling the frame" $
      forAll genV3 $ \p ->
        forAll (choose (1e3, 1e7 :: Double)) $ \speed ->
          let size = 0.4
              v = V3 (realToFrac speed) 0 0
              corners = cornersOf (buildTrailQuads camPos camTarget camUp (withVel [(p, size, v)])) 0
              longest = maximum [norm3 (a - b) | a <- corners, b <- corners]
           in -- Diagonal of a quad whose half-axes are (size/2 · cap) and
              -- (size/2): bounded by the cap, and by nothing about the
              -- speed.
              counterexample (show longest) (longest <= size * trailMaxStretch * 1.5)

vscale3 :: Float -> V3 -> V3
vscale3 k (V3 x y z) = V3 (k * x) (k * y) (k * z)
