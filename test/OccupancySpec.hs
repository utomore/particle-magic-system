-- | S2 (func-spec 0025 §6): the occupancy grid.
--
-- The headline law is conservation — the counts sum to the buffer's row
-- count, so no particle is dropped and none is counted twice. It is the
-- one property that makes the grid usable at all: a host asking "is
-- anything in that cell" has to be able to trust a zero.
--
-- The second is comparability (§2.7): the frame a grid divides up does
-- not move while the spell runs, so cell 5 means the same region on two
-- consecutive frames. Fitting the frame to each frame's own particles
-- would be tighter and would silently destroy exactly that.
module OccupancySpec (spec) where

import Control.Monad (forM_)
import qualified Data.Bits as Bits
import Data.Bits (popCount, testBit)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Interface (advanceSpell, castSpell)
import qualified Magic.Interface as I
import qualified Magic.Particle.Analytic as Analytic
import Magic.Particle.Buffer (ParticleBuffer (..), emptyBuffer, fromParticles)
import Magic.Space
  ( OccupancyGrid (..)
  , OrientedBox (..)
  , occupancyDimDefault
  , occupancyMask
  , occupancyOf
  , spellBox
  )
import Magic.Types (Seconds (..), Time (..), V3 (..), vscale)
import SpaceExamples (exampleSpells, loadExample, testCtx)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | A frame with axes that are NOT the world's, so an implementation that
-- quietly used world coordinates fails everything below.
tiltedFrame :: OrientedBox
tiltedFrame =
  OrientedBox
    { obCenter = V3 1 2 3
    , obAxisU = V3 s 0 s
    , obAxisV = V3 0 1 0
    , obAxisN = V3 (negate s) 0 s
    , obHalfU = 3
    , obHalfV = 3
    , obHalfN = 3
    }
  where
    s = sqrt 0.5

-- | The world-axis frame, where a cell index is easy to compute by hand.
unitFrame :: OrientedBox
unitFrame =
  OrientedBox
    { obCenter = V3 0 0 0
    , obAxisU = V3 1 0 0
    , obAxisV = V3 0 1 0
    , obAxisN = V3 0 0 1
    , obHalfU = 3
    , obHalfV = 3
    , obHalfN = 3
    }

bufferOf :: [V3] -> ParticleBuffer
bufferOf ps = fromParticles [(p, 0.05, 0.5, 0xFFFFFFFF) | p <- ps]

-- | A point at the center of cell (i, j, k) of 'unitFrame' with dim 3:
-- each cell is 2 units wide, spanning [-3, -1), [-1, 1), [1, 3).
cellCenter :: Int -> Int -> Int -> V3
cellCenter i j k = V3 (coord i) (coord j) (coord k)
  where
    coord c = fromIntegral (c :: Int) * 2 - 2

spec :: Spec
spec = describe "occupancy grid (func-spec 0025 S2)" $ do
  describe "the conservation law" $ do
    prop "the counts sum to the row count, for any dim and any points" $
      forAll (choose (1, 5)) $ \dim ->
        forAll (listOf pointGen) $ \ps ->
          let grid = occupancyOf dim tiltedFrame (bufferOf ps)
           in U.sum (ogCounts grid) === length ps

    prop "and for the real particles of every example, at any instant" $
      forAll (choose (0, 8)) $ \t -> ioProperty $ do
        spells <- exampleSpells
        pure $
          conjoin
            [ counterexample (name ++ " at t = " ++ show t) $
                U.sum (ogCounts grid) === pbCount buffer
            | (name, spell) <- spells
            , let buffer = Analytic.sample spell testCtx (Time t)
                  frame = spellBox testCtx (Seconds 8) spell
                  grid = occupancyOf 3 frame buffer
            ]

    it "the cell count is exactly dim cubed" $
      forM_ [1 .. 5 :: Int] $ \dim ->
        U.length (ogCounts (occupancyOf dim unitFrame emptyBuffer)) `shouldBe` dim * dim * dim

  describe "the index order is (k*N + j)*N + i, U fastest" $ do
    it "puts one particle in exactly the cell its coordinates name" $
      forM_ [(i, j, k) | i <- [0 .. 2], j <- [0 .. 2], k <- [0 .. 2]] $ \(i, j, k) -> do
        let grid = occupancyOf 3 unitFrame (bufferOf [cellCenter i j k])
            expected = (k * 3 + j) * 3 + i
        ((i, j, k), U.toList (ogCounts grid)) `shouldBe` ((i, j, k), oneAt 27 expected)

    it "steps along U with stride 1, V with 3 and the normal with 9" $ do
      let cellOf p = head [c | (c, n) <- zip [0 :: Int ..] (U.toList (ogCounts (occupancyOf 3 unitFrame (bufferOf [p])))), n > 0]
      cellOf (cellCenter 1 1 1) `shouldBe` 13
      cellOf (cellCenter 2 1 1) - cellOf (cellCenter 1 1 1) `shouldBe` 1
      cellOf (cellCenter 1 2 1) - cellOf (cellCenter 1 1 1) `shouldBe` 3
      cellOf (cellCenter 1 1 2) - cellOf (cellCenter 1 1 1) `shouldBe` 9

    it "reads the tilted frame's own axes, not the world's" $ do
      -- Two units along the frame's U axis is cell (2,1,1); the same
      -- displacement in world +X straddles U and the normal.
      let alongU = obCenter tiltedFrame + vscale 2 (obAxisU tiltedFrame)
          grid = occupancyOf 3 tiltedFrame (bufferOf [alongU])
      U.toList (ogCounts grid) `shouldBe` oneAt 27 ((1 * 3 + 1) * 3 + 2)

  describe "the edges" $ do
    it "clamps a particle outside the frame into the boundary cell" $ do
      let far = V3 1000 (-1000) 1000
          grid = occupancyOf 3 unitFrame (bufferOf [far])
      U.sum (ogCounts grid) `shouldBe` 1
      U.toList (ogCounts grid) `shouldBe` oneAt 27 ((2 * 3 + 0) * 3 + 2)

    it "N = 1 degenerates to a single cell holding everything" $ do
      let ps = [V3 x 0 0 | x <- [-100, -1, 0, 1, 100]]
          grid = occupancyOf 1 unitFrame (bufferOf ps)
      U.toList (ogCounts grid) `shouldBe` [5]

    it "a non-positive dim is read as 1 rather than as an empty grid" $
      U.toList (ogCounts (occupancyOf 0 unitFrame (bufferOf [V3 0 0 0]))) `shouldBe` [1]

    it "an empty buffer is all zeros, and mask 0" $ do
      U.toList (ogCounts (occupancyOf 3 unitFrame emptyBuffer))
        `shouldBe` replicate 27 (0 :: Int)
      occupancyMask unitFrame emptyBuffer `shouldBe` 0

    it "a frame with no width puts everything on its middle plane" $ do
      let flat = unitFrame {obHalfN = 0}
          grid = occupancyOf 3 flat (bufferOf [V3 0 0 5, V3 0 0 (-5)])
      -- k is forced to 1; both particles land in the middle plane.
      sum [U.toList (ogCounts grid) !! c | c <- [9 .. 17]] `shouldBe` 2

  describe "the Word32 fast path" $ do
    prop "bit c is set exactly when cell c is non-empty" $
      forAll (listOf pointGen) $ \ps ->
        let counts = U.toList (ogCounts (occupancyOf occupancyDimDefault tiltedFrame (bufferOf ps)))
            mask = occupancyMask tiltedFrame (bufferOf ps)
         in conjoin
              [ counterexample ("cell " ++ show c) (testBit mask c === (n > 0))
              | (c, n) <- zip [0 ..] counts
              ]

    it "never sets a bit above 26 (27 cells in 32)" $
      property $ \(ps :: [(Float, Float, Float)]) ->
        let mask = occupancyMask tiltedFrame (bufferOf [V3 x y z | (x, y, z) <- ps])
         in Bits.zeroBits === (mask `andBits` complement27)

    it "popCount answers how many cells are live" $ do
      let ps = [cellCenter 0 0 0, cellCenter 2 2 2, cellCenter 2 2 2]
          mask = occupancyMask unitFrame (bufferOf ps)
      popCount mask `shouldBe` 2

  describe "the comparability law (func-spec 0025 section 2.7)" $ do
    it "the frame is the same on every frame of a cast" $ do
      circle <- loadExample "square-burst.json"
      let Right cast0 = castSpell (I.CastRequest circle testCtx)
          step s = advanceSpell (I.FrameInput (I.DeltaTime (1 / 60))) s
          casts = take 120 (iterate step cast0)
          frames = map (ogFrame . I.occupancyOf 3) casts
      length frames `shouldBe` 120
      -- Every frame's grid divides up the very same box.
      filter (/= head frames) frames `shouldBe` []

    it "and so a cell means the same region as the spell evolves" $ do
      circle <- loadExample "square-burst.json"
      let Right cast0 = castSpell (I.CastRequest circle testCtx)
          step s = advanceSpell (I.FrameInput (I.DeltaTime (1 / 60))) s
          casts = take 120 (iterate step cast0)
          grids = map (I.occupancyOf 3) casts
      -- Not vacuous: the counts really do move between cells.
      length (filter (/= ogCounts (head grids)) (map ogCounts grids)) `shouldSatisfy` (> 10)
      map ogDim grids `shouldBe` replicate 120 3

  it "is deterministic: the same inputs give the same grid" $ do
    let ps = [V3 0.5 (-1.25) 2, V3 (-2) 0 0, V3 1 1 1]
    occupancyOf 4 tiltedFrame (bufferOf ps) `shouldBe` occupancyOf 4 tiltedFrame (bufferOf ps)

-- | Bitwise and, named rather than imported: 'Test.QuickCheck' exports a
-- @(.&.)@ of its own.
andBits :: Word32 -> Word32 -> Word32
andBits = (Bits..&.)

complement27 :: Word32
complement27 = 0xFFFFFFFF - (2 ^ (27 :: Int) - 1)

oneAt :: Int -> Int -> [Int]
oneAt n c = [if i == c then 1 else 0 | i <- [0 .. n - 1]]

pointGen :: Gen V3
pointGen = V3 <$> coord <*> coord <*> coord
  where
    coord = frequency [(6, choose (-5, 5)), (1, choose (-500, 500))]
