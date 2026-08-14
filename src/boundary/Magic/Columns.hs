-- | Controlled column → buffer construction (func-spec 0011 §0.3).
--
-- 'Magic.Interface' exports 'ParticleBuffer' as a read-only view — fields,
-- no constructor — because a consumer that /samples/ a spell has no
-- business forging a buffer. That discipline stands. But the C ABI shell
-- has the opposite problem: a host hands it six raw arrays and asks for
-- 'Magic.Projection.depthOrder', which eats a 'ParticleBuffer', and the
-- foreign library may not depend on magic-core (the dependency whitelist
-- @test\/FFIContractSpec.hs@ guards). Rebuilding the sort on the FFI side
-- would put semantics in the shell, which func-spec 0009 §2 forbids.
--
-- So this module is the other door: narrow, validating, and open only to
-- consumers that /already hold the columns/. 'fromColumns' checks the six
-- lengths before it builds anything, so
-- 'Magic.Particle.Buffer.bufferInvariant' holds by construction — the
-- caller cannot produce an inconsistent buffer even by accident.
--
-- __Frozen__ (spec 0011 §9): the export list below.
module Magic.Columns
  ( ParticleBuffer
  , ColumnError (..)
  , fromColumns
  ) where

import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Particle.Buffer (ParticleBuffer (..))

-- | Why a set of columns is not a buffer. The payload lists all six
-- lengths in field order (x, y, z, size, life, color), because a caller
-- staring at a mismatch wants to see which column is the odd one out, not
-- just that one exists.
newtype ColumnError = LengthMismatch [Int]
  deriving (Eq, Show)

-- | Build a buffer from six equal-length columns.
--
-- The count is not a parameter: it /is/ the common length. That removes
-- the one failure mode a @count@ argument would add (a count that lies
-- about the vectors), and leaves exactly one thing to check.
fromColumns
  :: U.Vector Float
  -- ^ position x
  -> U.Vector Float
  -- ^ position y
  -> U.Vector Float
  -- ^ position z
  -> U.Vector Float
  -- ^ size
  -> U.Vector Float
  -- ^ life fraction
  -> U.Vector Word32
  -- ^ packed RGBA colour
  -> Either ColumnError ParticleBuffer
fromColumns xs ys zs sizes lifes colors
  | all (== n) lengths =
      Right
        ParticleBuffer
          { pbPosX = xs
          , pbPosY = ys
          , pbPosZ = zs
          , pbSize = sizes
          , pbLife = lifes
          , pbColor = colors
          , pbCount = n
          }
  | otherwise = Left (LengthMismatch lengths)
  where
    n = U.length xs
    lengths =
      [ n
      , U.length ys
      , U.length zs
      , U.length sizes
      , U.length lifes
      , U.length colors
      ]
