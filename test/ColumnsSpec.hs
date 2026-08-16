-- | S2 (func-spec 0011 §7): the boundary's column → buffer door.
--
-- 'Magic.Columns.fromColumns' exists so the FFI shell can hand raw host
-- arrays to 'Magic.Projection.depthOrder' without reimplementing it, and
-- its whole job is to make that impossible to do wrongly: the buffer it
-- returns satisfies 'bufferInvariant' by construction, and columns that
-- do not line up never become a buffer at all.
--
-- Two laws carry it: /accepted iff all six lengths agree/, and /the
-- result is the same buffer 'fromParticles' would have built/ — which is
-- what makes it a door into the existing type rather than a second,
-- subtly different way to make one.
module ColumnsSpec (spec) where

import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Columns (ColumnError (..), fromColumns)
import Magic.Particle.Buffer
  ( ParticleBuffer (..)
  , bufferInvariant
  , emptyBuffer
  , fromParticles
  )
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | One particle's worth of the six columns.
type Row = (Float, Float, Float, Float, Float, Word32)

newtype Rows = Rows [Row]
  deriving (Show)

instance Arbitrary Rows where
  arbitrary = do
    n <- choose (0, 40)
    Rows <$> vectorOf n row
    where
      row =
        (,,,,,)
          <$> coord
          <*> coord
          <*> coord
          <*> choose (0.01, 5)
          <*> choose (0, 1)
          <*> arbitrary
      coord = choose (-100, 100)

columnsOf :: [Row] -> (U.Vector Float, U.Vector Float, U.Vector Float, U.Vector Float, U.Vector Float, U.Vector Word32)
columnsOf rows =
  ( U.fromList [x | (x, _, _, _, _, _) <- rows]
  , U.fromList [y | (_, y, _, _, _, _) <- rows]
  , U.fromList [z | (_, _, z, _, _, _) <- rows]
  , U.fromList [s | (_, _, _, s, _, _) <- rows]
  , U.fromList [l | (_, _, _, _, l, _) <- rows]
  , U.fromList [c | (_, _, _, _, _, c) <- rows]
  )

build :: [Row] -> Either ColumnError ParticleBuffer
build rows = fromColumns xs ys zs sizes lifes colors
  where
    (xs, ys, zs, sizes, lifes, colors) = columnsOf rows

-- | The same rows through the core's own constructor helper.
reference :: [Row] -> ParticleBuffer
reference rows = fromParticles [(V3 x y z, s, l, c) | (x, y, z, s, l, c) <- rows]

-- | Six lengths, at least two of which differ.
newtype Ragged = Ragged [Int]
  deriving (Show)

instance Arbitrary Ragged where
  arbitrary = Ragged <$> (vectorOf 6 (choose (0, 8)) `suchThat` ragged)
    where
      ragged (l : rest) = any (/= l) rest
      ragged [] = False

spec :: Spec
spec = describe "Magic.Columns (func-spec 0011 §0.3)" $ do
  describe "fromColumns, aligned columns" $ do
    prop "accepts them and keeps every column bit for bit" $ \(Rows rows) ->
      let (xs, ys, zs, sizes, lifes, colors) = columnsOf rows
       in build rows
            === Right
              ParticleBuffer
                { pbPosX = xs
                , pbPosY = ys
                , pbPosZ = zs
                , pbSize = sizes
                , pbLife = lifes
                , pbColor = colors
                , -- Func-spec 0023: the six-column door leaves the
                  -- velocity columns empty, which is what makes
                  -- 'fromColumns' still produce exactly the buffer it
                  -- always did.
                  pbVelX = U.empty
                , pbVelY = U.empty
                , pbVelZ = U.empty
                , pbCount = length rows
                }

    prop "establishes the buffer invariant by construction" $ \(Rows rows) ->
      case build rows of
        Left err -> counterexample (show err) False
        Right pb -> property (bufferInvariant pb)

    prop "agrees with the core's own fromParticles" $ \(Rows rows) ->
      build rows === Right (reference rows)

    it "builds the empty buffer from six empty columns" $
      build [] `shouldBe` Right emptyBuffer

  describe "fromColumns, ragged columns" $ do
    prop "rejects them, reporting all six lengths in field order" $ \(Ragged lengths) ->
      let floats i = U.replicate (lengths !! i) (0 :: Float)
       in fromColumns (floats 0) (floats 1) (floats 2) (floats 3) (floats 4) (U.replicate (lengths !! 5) 0)
            === Left (LengthMismatch lengths)

    it "names the odd column out — the point of carrying all six" $ do
      let f = U.replicate 3 (0 :: Float)
      fromColumns f f f f (U.replicate 2 0) (U.replicate 3 0)
        `shouldBe` Left (LengthMismatch [3, 3, 3, 3, 2, 3])

    it "a short colour column is caught too (the one that is not a Float)" $ do
      let f = U.replicate 3 (0 :: Float)
      fromColumns f f f f f (U.replicate 1 0)
        `shouldBe` Left (LengthMismatch [3, 3, 3, 3, 3, 1])
