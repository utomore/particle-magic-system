-- | Projection abstraction (ADR-0008): the core simulates in an abstract
-- 3D space and never knows which dimension the host renders in. This
-- module is where "which dimension" is decided — and it is pure, so the
-- decision is property-testable without a window.
--
-- 'project' is the 3D case (identity: the raylib backend consumes
-- abstract-space coordinates and lets the GPU do the perspective).
-- Func-spec 0008 adds the 2D case: an orthographic 'ViewPlane' selection
-- plus the painter's-order permutation a flat renderer needs, which is
-- exactly ADR-0008's "2D = orthographic projection: drop one axis and
-- pick a depth-sorting strategy".
--
-- Deliberately pixel-free: screen origin, pixels-per-unit and the y-flip
-- belong to the shell (@App.Render.Flat@), not to the core.
module Magic.Project
  ( project
  , ViewPlane (..)
  , orthographic
  , depthOrder

    -- * Re-export
  , V2 (..)
  -- ^ The plane coordinate type ('Magic.Types', 0001 vocabulary).
  -- Re-exported so the shell — which may only depend on magic-boundary —
  -- can pattern match on what 'orthographic' returns.
  ) where

import Control.Monad.ST (ST)
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MU
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Types (V2 (..), V3 (..))

-- | The 3D case: no projection of our own.
project :: V3 -> V3
project = id

-- | Which axis the orthographic camera looks along.
data ViewPlane
  = SideXY
  -- ^ Viewer at @+Z@ looking towards @-Z@: plane = @(x, y)@, Z dropped.
  -- The default — spells fire upwards, so this is the natural side view.
  | TopXZ
  -- ^ Viewer at @+Y@ looking down: plane = @(x, z)@, Y dropped.
  deriving (Eq, Show)

-- | Plane coordinates plus a depth. Convention: larger depth is further
-- away (SideXY: @depth = -z@; TopXZ: @depth = -y@).
--
-- Componentwise selection, no arithmetic beyond the sign flip — the
-- projected coordinates are bit-identical to the source ones.
orthographic :: ViewPlane -> V3 -> (V2, Float)
orthographic SideXY (V3 x y z) = (V2 x y, negate z)
orthographic TopXZ (V3 x y z) = (V2 x z, negate y)

-- | Painter's permutation: the indices @[0 .. pbCount-1]@ ordered by
-- depth, far to near (decreasing depth), so drawing them in this order
-- puts nearer particles on top without a depth buffer.
--
-- Stable: equal depths keep their buffer order, which is what makes the
-- rendering deterministic. Returns an index permutation rather than a
-- reordered buffer, so the SoA layout (ADR-0006) is never copied and the
-- permutation laws can be asserted directly.
--
-- Implementation (func-spec 0010 S5, redeeming func-spec 0008 §9's note):
-- an in-place introsort over one unboxed @(depth, index)@ vector, no
-- boxed list of the batch anywhere. Stability is /not/ asked of the
-- algorithm: the comparison breaks ties on the buffer index, which makes
-- it a strict total order (no two rows ever compare equal), and under a
-- total order every correct sort produces the same, unique, permutation —
-- the one a stable sort produces. So the frozen 0008 law survives a sort
-- that reorders equal elements freely, because there are none.
depthOrder :: ViewPlane -> ParticleBuffer -> U.Vector Int
depthOrder plane pb = U.map snd (U.modify introsort keyed)
  where
    n = pbCount pb
    keyed = U.generate n (\i -> (sanitize (depthAt i), i))
    depthAt i =
      snd
        ( orthographic
            plane
            (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i))
        )

-- | NaN has no place in an ordering, and one NaN key would turn the
-- comparison into a non-order the partition loops could walk off the end
-- of. It is folded to @-Infinity@ /once/, while the keys are built, so
-- the comparison itself stays two arithmetic tests.
--
-- A NaN depth needs a NaN position, which the analytic layer cannot
-- produce ('Magic.Expr.evalFinite' flushes them); this is about the sort
-- being total for any input, not about a case that occurs. Note that
-- @-0.0@ is deliberately /not/ normalized: it compares equal to @0.0@, so
-- the two tie-break on the index exactly as the previous 'Data.List.sortOn'
-- implementation did.
sanitize :: Float -> Float
sanitize d = if isNaN d then -1 / 0 else d

-- | Far-to-near, ties broken by ascending buffer index: a strict total
-- order on @(depth, index)@ pairs with distinct indices.
before :: (Float, Int) -> (Float, Int) -> Bool
before (d1, i1) (d2, i2) = d1 > d2 || (d1 == d2 && i1 < i2)
{-# INLINE before #-}

-- | Introsort: quicksort with median-of-three pivots, falling back to
-- heapsort past a recursion-depth limit (so the worst case stays
-- @O(n log n)@) and to insertion sort on short runs.
--
-- Hand-written rather than pulled from @vector-algorithms@: magic-core's
-- dependency whitelist is @{base, vector, deepseq}@ (func-spec 0001 §3,
-- guarded by @test\/BoundarySpec.hs@) and a sort is not a reason to widen
-- an architectural boundary.
introsort :: MU.MVector s (Float, Int) -> ST s ()
introsort v = go v (2 * ilog2 (MU.length v))
  where
    go w limit
      | len <= 16 = insertionSort w
      | limit <= 0 = heapSort w
      | otherwise = do
          medianToFront w
          p <- partitionHoare w
          go (MU.slice 0 (p + 1) w) (limit - 1)
          go (MU.slice (p + 1) (len - p - 1) w) (limit - 1)
      where
        len = MU.length w

ilog2 :: Int -> Int
ilog2 k = go k 0
  where
    go m acc
      | m <= 1 = acc
      | otherwise = go (m `div` 2) (acc + 1)

-- | Median of first, middle and last, moved to index 0 — the pivot
-- Hoare's partition below reads from there.
medianToFront :: MU.MVector s (Float, Int) -> ST s ()
medianToFront w = do
  let len = MU.length w
      mid = len `div` 2
      lst = len - 1
  a <- MU.read w 0
  b <- MU.read w mid
  c <- MU.read w lst
  let medianAt
        | before a b = if before b c then mid else if before a c then lst else 0
        | before a c = 0
        | before b c = lst
        | otherwise = mid
  MU.swap w 0 medianAt

-- | Hoare's partition with the pivot value taken from index 0. Returns
-- @p@ with @0 <= p < len - 1@ such that everything in @[0 .. p]@ precedes
-- everything in @[p+1 .. len-1]@ — so both halves are strictly smaller
-- than the input and the recursion terminates.
partitionHoare :: MU.MVector s (Float, Int) -> ST s Int
partitionHoare w = do
  pivot <- MU.read w 0
  let down j = do
        a <- MU.read w j
        if before pivot a then down (j - 1) else pure j
      up i = do
        a <- MU.read w i
        if before a pivot then up (i + 1) else pure i
      loop i j = do
        j' <- down (j - 1)
        i' <- up (i + 1)
        if i' < j'
          then MU.swap w i' j' >> loop i' j'
          else pure j'
  loop (-1) (MU.length w)

insertionSort :: MU.MVector s (Float, Int) -> ST s ()
insertionSort w = mapM_ place [1 .. MU.length w - 1]
  where
    place i = do
      x <- MU.read w i
      let shift j
            | j < 0 = pure (j + 1)
            | otherwise = do
                a <- MU.read w j
                if before x a
                  then MU.write w (j + 1) a >> shift (j - 1)
                  else pure (j + 1)
      k <- shift (i - 1)
      MU.write w k x

-- | Max-heap by the /reverse/ of 'before', so repeatedly moving the root
-- to the back leaves the array in 'before' order.
heapSort :: MU.MVector s (Float, Int) -> ST s ()
heapSort w = do
  mapM_ (\i -> siftDown i len) [len `div` 2 - 1, len `div` 2 - 2 .. 0]
  mapM_ (\end -> MU.swap w 0 end >> siftDown 0 end) [len - 1, len - 2 .. 1]
  where
    len = MU.length w
    -- "Greater" in heap terms = comes last in 'before' order.
    siftDown root end = do
      let child = 2 * root + 1
      if child >= end
        then pure ()
        else do
          l <- MU.read w child
          biggest <-
            if child + 1 < end
              then do
                r <- MU.read w (child + 1)
                pure (if before l r then child + 1 else child)
              else pure child
          p <- MU.read w root
          b <- MU.read w biggest
          if before p b
            then MU.swap w root biggest >> siftDown biggest end
            else pure ()
