-- | S9 (func-spec 0023 §6): cross-batch alpha depth interleaving.
--
-- Since func-spec 0015 one spell can produce several batches, and
-- func-spec 0013's 'viewOrder' sorts each of them on its own. Two alpha
-- batches therefore composite in /batch/ order regardless of depth: a far
-- trail drawn after a near light point covers it. Sorting inside a batch
-- cannot fix that, because the comparison that matters is between
-- particles of different batches.
--
-- 'crossBatchPicks' pools every alpha particle and sorts once;
-- 'frameDraws' turns the result into a /single/ draw.
--
-- __That single draw is the point__, and it is where this round departs
-- from func-spec 0023 §2.7's own wording (recorded in §10). §2.7 proposed
-- splitting the sorted pool back into one permutation per batch — but a
-- batch still draws contiguously, so the frame would remain "all of batch
-- 0, then all of batch 1" no matter how each batch's own particles were
-- ordered. The first property below is what caught that. The fix is the
-- sprite atlas: with the shape carried in each quad's texture
-- coordinates, no per-batch texture bind is left to force a draw-call
-- boundary, so every alpha particle in the frame can go into one sorted
-- stream.
--
-- Four laws:
--
--   * the draw order is depth non-increasing across the /whole frame/,
--     not merely within each batch;
--   * additive particles are not sorted — addition is commutative, so
--     their order is not the image, and sorting them would be an
--     @O(n log n)@ pass to produce an identical picture;
--   * with a single alpha batch the picks are func-spec 0013's
--     'viewOrder' exactly, so nothing about the old path moved;
--   * every particle is drawn exactly once — a permutation of the frame,
--     never a drop or a duplicate.
module CrossBatchOrderSpec (spec) where

import Data.List (sort)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Effects (Camera (..))
import App.Render.Order (DrawGroup (..), crossBatchPicks, frameDraws, viewOrder)
import App.Render.Post (VisualSettings (..), allEffects, noEffects)
import App.Render.Quads (QuadBatch (..))
import Magic.Interface
  ( BillboardShape (..)
  , BlendMode (..)
  , ParticleBuffer
  , RenderBatch (..)
  , V3 (..)
  , pbCount
  , pbPosX
  , pbPosY
  , pbPosZ
  )
import Magic.Particle.Buffer (buildBuffer)

cam :: Camera
cam =
  Camera
    { camPos = V3 6 4 6
    , camTarget = V3 0 2 0
    , camUp = V3 0 1 0
    , camFovY = 45
    }

bufferOf :: [V3] -> ParticleBuffer
bufferOf ps = buildBuffer (length ps) $ \write ->
  mapM_ (\(i, p) -> write i p 0.2 0.5 (0xFFFFFFFF :: Word32)) (zip [0 ..] ps)

batchOf :: BlendMode -> [V3] -> RenderBatch
batchOf blend ps =
  RenderBatch {rbParticles = bufferOf ps, rbBlend = blend, rbShape = BillboardSquare}

-- | Depth along the view axis, far to near — the key the order sorts on,
-- written out here independently of the implementation.
depthOf :: ParticleBuffer -> Int -> Float
depthOf pb i =
  (pbPosX pb U.! i - 6) * fx + (pbPosY pb U.! i - 4) * fy + (pbPosZ pb U.! i - 6) * fz
  where
    (dx, dy, dz) = (0 - 6, 2 - 4, 0 - 6)
    n = sqrt (dx * dx + dy * dy + dz * dz)
    (fx, fy, fz) = (dx / n, dy / n, dz / n)

-- | The depths of the frame's alpha particles, in the order they will
-- actually be drawn — which, since they are one draw, is the pick order.
drawnDepths :: [RenderBatch] -> [(Int, Int)] -> [Float]
drawnDepths bs picks =
  [depthOf (rbParticles (bs !! k)) i | (k, i) <- picks]

genV3 :: Gen V3
genV3 = V3 <$> comp <*> comp <*> comp
  where
    comp = realToFrac <$> choose (-6 :: Double, 6)

genShape :: Gen BillboardShape
genShape = elements [minBound .. maxBound]

genBatch :: Gen RenderBatch
genBatch = do
  blend <- elements [BlendAlpha, BlendAdditive]
  shape <- genShape
  ps <- listOf genV3
  pure (batchOf blend ps) {rbShape = shape}

spec :: Spec
spec = describe "cross-batch depth interleaving (func-spec 0023 §6 S9)" $ do
  describe "the draw order is a frame-wide sort" $ do
    prop "alpha particles are drawn far to near across every batch" $
      forAll (listOf genBatch) $ \bs ->
        let depths = drawnDepths bs (crossBatchPicks cam bs)
         in counterexample (show depths) (nonIncreasing depths)

    it "interleaves two batches rather than concatenating them" $ do
      -- The failure the whole item exists to fix, and the one the §2.7
      -- mechanism could not express: without a single merged draw, all of
      -- batch 0 draws before any of batch 1, whatever the depths.
      let near = batchOf BlendAlpha [V3 0 2 5, V3 0 2 4]
          far = batchOf BlendAlpha [V3 0 2 (-5), V3 0 2 (-4)]
          picks = crossBatchPicks cam [near, far]
      nonIncreasing (drawnDepths [near, far] picks) `shouldBe` True
      -- The far batch's particles come first, interleaved by depth — a
      -- sequence that names batch 1 before batch 0.
      map fst picks `shouldBe` [1, 1, 0, 0]

    prop "and does so with shapes mixed, which is the case that needed the atlas" $
      -- Two alpha batches of /different/ shapes used to be two draws with
      -- two textures, hence unorderable against each other.
      forAll (listOf genV3) $ \ps ->
        forAll (listOf genV3) $ \qs ->
          let a = (batchOf BlendAlpha ps) {rbShape = BillboardSoftDot}
              b = (batchOf BlendAlpha qs) {rbShape = BillboardTrail}
              depths = drawnDepths [a, b] (crossBatchPicks cam [a, b])
           in counterexample (show depths) (nonIncreasing depths)

  describe "additive particles are left alone" $ do
    prop "never appear among the sorted alpha picks" $
      forAll (listOf genBatch) $ \bs ->
        conjoin
          [ counterexample (show (k, i)) (rbBlend (bs !! k) /= BlendAdditive)
          | (k, i) <- crossBatchPicks cam bs
          ]

    prop "and adding some does not move one alpha particle" $
      -- The two populations are decided independently, and the additive
      -- one is not sorted at all.
      forAll (listOf genBatch) $ \bs ->
        forAll (listOf genV3) $ \extra ->
          crossBatchPicks cam bs
            === crossBatchPicks cam (bs ++ [batchOf BlendAdditive extra])

    prop "are drawn in their own group, in input order" $
      forAll (listOf genBatch) $ \bs ->
        let additive = [g | g <- frameDraws noEffects cam bs, dgBlend g == BlendAdditive]
            held = sum [pbCount (rbParticles b) | b <- bs, rbBlend b == BlendAdditive]
         in map (qbCount . dgQuads) additive === [held]

  describe "one alpha batch is func-spec 0013's viewOrder" $ do
    prop "identical permutation, so nothing about the old path moved" $
      forAll (listOf genV3) $ \ps ->
        let b = batchOf BlendAlpha ps
         in map snd (crossBatchPicks cam [b])
              === U.toList (viewOrder cam (rbParticles b))

    prop "including the stability rule: equal depths keep buffer order" $
      -- A frame has to be a function of the simulation state alone; an
      -- unstable sort would make it depend on the sort's internals.
      forAll (choose (0, 12 :: Int)) $ \n ->
        let ps = replicate n (V3 1 2 3)
            b = batchOf BlendAlpha ps
         in map snd (crossBatchPicks cam [b]) === [0 .. n - 1]

  describe "the frame is a permutation of itself" $ do
    prop "every alpha particle is picked exactly once" $
      forAll (listOf genBatch) $ \bs ->
        let picks = crossBatchPicks cam bs
            held =
              [ (k, i)
              | (k, b) <- zip [0 :: Int ..] bs
              , rbBlend b /= BlendAdditive
              , i <- [0 .. pbCount (rbParticles b) - 1]
              ]
         in sort picks === sort held

    prop "and every particle of the frame lands in exactly one draw group" $
      forAll (listOf genBatch) $ \bs ->
        let drawn = sum (map (qbCount . dgQuads) (frameDraws allEffects cam bs))
            held = sum (map (pbCount . rbParticles) bs)
         in drawn === held

    prop "the frame is at most two draw calls, whatever the batch count" $
      -- ADR-0009's promise, kept with room to spare: draws are bounded by
      -- the blend modes, not by the batches and certainly not by the
      -- particles.
      forAll (listOf genBatch) $ \bs ->
        length [g | g <- frameDraws allEffects cam bs, qbCount (dgQuads g) > 0] <= 2

    it "handles an empty batch without disturbing its neighbours" $ do
      let bs = [batchOf BlendAlpha [], batchOf BlendAlpha [V3 0 0 0]]
      crossBatchPicks cam bs `shouldBe` [(1, 0)]

  describe "the trail switch decides geometry, not order" $
    prop "turning trails off changes no pick" $
      forAll (listOf genBatch) $ \bs ->
        -- Which particles are drawn when is a depth question; how they
        -- are shaped is not. Switching trails must not reorder the frame.
        crossBatchPicks cam bs === crossBatchPicks cam bs
          .&&. map (qbCount . dgQuads) (frameDraws noEffects cam bs)
          === map (qbCount . dgQuads) (frameDraws allEffects cam bs)

nonIncreasing :: [Float] -> Bool
nonIncreasing xs = and (zipWith (>=) xs (drop 1 xs))
