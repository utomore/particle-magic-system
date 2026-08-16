-- | Splitting one staged batch across several GPU uploads (func-spec
-- 0012 S1).
--
-- Raising the core's particle cap decouples two numbers the demo used to
-- keep equal: how many particles a spell may hold, and how many vertices
-- the shared dynamic mesh was allocated for. The mesh deliberately does
-- /not/ grow with the cap — a 16-bit index buffer tops out at 65536
-- vertices, and a bigger upload granularity is worse for the driver, not
-- better (ADR-0009's dynamic-mesh path is unchanged). Instead a batch
-- larger than the mesh is drawn as several consecutive chunks: the draw
-- call count becomes @ceil (particles / capacity)@, still far below one
-- per particle.
--
-- The pure half lives here so the split is a law rather than a hope
-- (@test\/CapacitySpec.hs@): concatenating the chunks' vertex streams
-- reproduces the whole batch's, byte for byte and in order. Chunking is a
-- 'Data.Vector.Storable.slice' — a view, no copying — so the staging cost
-- of a chunked batch is the staging cost of the batch.
module App.Render.Chunk
  ( chunkBatch
  ) where

import qualified Data.Vector.Storable as S

import App.Render.Quads (QuadBatch (..))

-- | Floats per quad in the position stream (4 vertices × xyz) and bytes
-- per quad in the color stream (4 vertices × rgba) — the 'QuadBatch'
-- invariants, named so the slicing arithmetic reads as what it is.
posStride, colStride, uvStride :: Int
posStride = 12
colStride = 16
uvStride = 8

-- | Split a batch into consecutive pieces of at most @cap@ quads each,
-- in draw order.
--
-- A batch that already fits is returned as-is (one element, the original
-- value), so the common case pays nothing and draws exactly as it did
-- before this function existed. An empty batch yields no pieces, and a
-- non-positive capacity is treated as "no limit" rather than as an
-- invitation to loop forever.
chunkBatch :: Int -> QuadBatch -> [QuadBatch]
chunkBatch cap batch
  | n <= 0 = []
  | cap <= 0 || n <= cap = [batch]
  | otherwise = [pieceAt off (min cap (n - off)) | off <- [0, cap .. n - 1]]
  where
    n = qbCount batch
    pieceAt off k =
      QuadBatch
        { qbPositions = window posStride off k (qbPositions batch)
        , qbColors = window colStride off k (qbColors batch)
        , -- Func-spec 0023 S9: two floats per vertex, so eight per quad —
          -- sliced by the same window as the other two streams, since all
          -- three are indexed by the quad.
          qbTexcoords = window uvStride off k (qbTexcoords batch)
        , qbCount = k
        }
    -- take/drop rather than 'S.slice': a batch whose streams are shorter
    -- than its count claims is malformed, and the honest failure mode for
    -- a renderer is drawing less, not an index-out-of-bounds crash.
    window stride off k v = S.take (k * stride) (S.drop (off * stride) v)
