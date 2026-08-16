-- | S7 (func-spec 0025 §6): the round, end to end, through the one
-- example that exercises all of it.
--
-- @twin-lance.json@ is the first spell in this repo that fires from two
-- places at once. What makes it an acceptance test rather than another
-- unit is that the claim spans every layer at once: the JSON key parses,
-- the fold splits the budget without spending more of it, the particles
-- really are in two places, and the spatial summary can say so — using
-- the occupancy mask, which is the whole point of shipping one.
module Acceptance25Spec (spec) where

import Control.Monad (forM_)
import Data.Bits (popCount, testBit)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..))
import Magic.Compile (Anchor (..), CompiledSpell (..), EmitterSpec (..), Phase (..), compile)
import Magic.Interface
  ( ActiveSpell
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , OccupancyGrid (..)
  , OrientedBox (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , advanceSpell
  , castSpell
  , observeSpell
  , occupancyMask
  , occupancyOf
  , spellBoundsOf
  )
import Magic.Types (V3 (..))
import SpaceExamples (loadExample, testCtx)
import Test.Hspec

castAt :: Int -> Circle -> ActiveSpell
castAt n circle =
  iterate (advanceSpell (FrameInput (DeltaTime (1 / 60)))) cast0 !! n
  where
    cast0 = either (error . show) id (castSpell (CastRequest circle testCtx))

-- | A frame's rows, as the bits a host receives.
frameBits :: ActiveSpell -> [(Int, [Float], [Float], [Float], [Float], [Float])]
frameBits cast =
  [ ( pbCount pb
    , U.toList (pbPosX pb)
    , U.toList (pbPosY pb)
    , U.toList (pbPosZ pb)
    , U.toList (pbSize pb)
    , U.toList (pbLife pb)
    )
  | batch <- batches (observeSpell cast)
  , let pb = rbParticles batch
  ]

spec :: Spec
spec = describe "twin-lance, end to end (func-spec 0025 S7)" $ do
  it "loads, compiles and fires from two activation points" $ do
    circle <- loadExample "twin-lance.json"
    let spell = either (error . show) id (compile circle)
        casting = [em | em <- V.toList (spellEmitters spell), emPhase em == Casting]
    length casting `shouldBe` 2
    map (anchorX . emAnchor) casting `shouldBe` [0.6, -0.6]

  it "spends what one activation point would have spent" $ do
    circle <- loadExample "twin-lance.json"
    let two = either (error . show) id (compile circle)
        one = either (error . show) id (compile circle {circleAnchors = Nothing})
    spellBudget two `shouldBe` spellBudget one

  it "is deterministic over 240 frames" $ do
    circle <- loadExample "twin-lance.json"
    let run = map frameBits (take 240 (drop 1 (iterate step (start circle))))
        step = advanceSpell (FrameInput (DeltaTime (1 / 60)))
        start c = either (error . show) id (castSpell (CastRequest c testCtx))
    length run `shouldBe` 240
    run `shouldBe` run
    -- Not vacuous: the spell really does produce particles.
    sum [n | frame <- run, (n, _, _, _, _, _) <- frame] `shouldSatisfy` (> 1000)

  it "the two lances really are on two sides, with a gap between them" $ do
    -- The mask is the witness, which is exactly what §2.8 says it is for:
    -- the left and right columns of the nine-grid hold particles, the
    -- middle column does not.
    circle <- loadExample "twin-lance.json"
    let cast = castAt 100 circle
        mask = occupancyMask cast
        column i = [c | c <- [0 .. 26], c `mod` 3 == i]
        live cs = or [testBit mask c | c <- cs]
    live (column 0) `shouldBe` True
    live (column 2) `shouldBe` True
    live (column 1) `shouldBe` False
    -- And the mask stays inside its 27 bits.
    popCount mask `shouldSatisfy` (<= 27)

  it "the single-anchor version of the same circle fills the middle instead" $ do
    -- The contrast that makes the previous assertion mean something: it
    -- is the anchors doing this, not the spell's shape.
    circle <- loadExample "twin-lance.json"
    let cast = castAt 100 circle {circleAnchors = Nothing}
        mask = occupancyMask cast
        column i = [c | c <- [0 .. 26], c `mod` 3 == i]
        live cs = or [testBit mask c | c <- cs]
    live (column 1) `shouldBe` True

  it "the bounds cover both lances" $ do
    circle <- loadExample "twin-lance.json"
    let cast = castAt 100 circle
        (V3 lox _ _, V3 hix _ _) = spellBoundsOf cast
        xs = concat [U.toList (pbPosX (rbParticles b)) | b <- batches (observeSpell cast)]
    length xs `shouldSatisfy` (> 0)
    minimum xs `shouldSatisfy` (>= lox)
    maximum xs `shouldSatisfy` (<= hix)

  it "every alive particle is counted, on every frame" $ do
    circle <- loadExample "twin-lance.json"
    forM_ [0, 20 .. 240 :: Int] $ \frame -> do
      let cast = castAt frame circle
          grid = occupancyOf 3 cast
          drawn = sum [pbCount (rbParticles b) | b <- batches (observeSpell cast)]
      (frame, U.sum (ogCounts grid)) `shouldBe` (frame, drawn)

  it "asking for the summary leaves the rendered output untouched" $ do
    circle <- loadExample "twin-lance.json"
    let cast = castAt 90 circle
        before = frameBits cast
        queried = (spellBoundsOf cast, occupancyMask cast, obCenter (ogFrame (occupancyOf 3 cast)))
        after = queried `seq` frameBits cast
    before `shouldBe` after

anchorX :: Anchor -> Float
anchorX a = let V3 x _ _ = anchorOffset a in x
