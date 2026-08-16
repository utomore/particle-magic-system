-- | S5 (func-spec 0025 §6): the boundary's spatial queries are the core's
-- functions and nothing else.
--
-- Same discipline as every boundary addition since spec 0005: the layer
-- crosses types and picks the horizon, and takes no other decision. What
-- IS a decision here — and so is stated rather than assumed — is which
-- horizon each query uses: "up to now" for one emitter, "ever" for the
-- spell, the second being what the occupancy frame needs to stay
-- comparable across frames (§2.7).
--
-- The other half is a negative claim: 'FrameOutput' did not change. The
-- spatial summary is a query precisely so that no host's pattern match
-- broke and no spell that does not want it pays for it (§2.2).
module SpaceInterfaceSpec (spec) where

import Control.Monad (forM_)
import Data.Bits (testBit)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), TwoOf (..), emptyCircle)
import Magic.Compile (CompiledSpell (..), compile)
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
  , boxToAABB
  , castSpell
  , emitterBoxOf
  , emittersOf
  , observeSpell
  , occupancyDimDefault
  , occupancyMask
  , occupancyOf
  , spellBoundsOf
  , spellBoxOf
  )
import Magic.Rune (InnerRune (..), Trajectory (..))
import qualified Magic.Space as Space
import Magic.Types (Seconds (..), V3 (..))
import SpaceExamples (exampleCircles, testCtx)
import Test.Hspec

-- | A cast advanced by @n@ sixtieths of a second.
castAt :: Int -> Circle -> ActiveSpell
castAt n circle =
  iterate (advanceSpell (FrameInput (DeltaTime (1 / 60)))) cast0 !! n
  where
    cast0 = either (error . show) id (castSpell (CastRequest circle testCtx))

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

-- | A spell that visibly travels, so "the box grows with the horizon" is
-- not a claim about rounding.
travelling :: Circle
travelling = emptyCircle {innerRings = TwoOf (Just (TrajectoryRune (Forward 6))) Nothing}

spec :: Spec
spec = describe "the boundary's spatial queries (func-spec 0025 S5)" $ do
  it "emitterBoxOf is emitterBox at the cast's current age" $ do
    circles <- exampleCircles
    forM_ circles $ \(name, circle) ->
      forM_ [0, 37, 150 :: Int] $ \frame -> do
        let cast = castAt frame circle
            age = Seconds (fromIntegral frame / 60)
            label = name ++ " @ frame " ++ show frame
        (label, map (emitterBoxOf cast) (emittersOf cast))
          `shouldBe` ( label
                     , map
                        (Space.emitterBox testCtx age)
                        (V.toList (spellEmitters (compiledOf circle)))
                     )

  it "spellBoundsOf and spellBoxOf are the core's, at the spell's lifetime" $ do
    circles <- exampleCircles
    forM_ circles $ \(name, circle) -> do
      let cast = castAt 90 circle
          spell = compiledOf circle
          life = spellLifetime spell
      (name, spellBoundsOf cast) `shouldBe` (name, Space.spellBounds testCtx life spell)
      (name, spellBoxOf cast) `shouldBe` (name, Space.spellBox testCtx life spell)

  it "occupancyOf grids the observed particles over spellBoxOf" $ do
    circles <- exampleCircles
    forM_ circles $ \(name, circle) ->
      forM_ [30, 120 :: Int] $ \frame -> do
        let cast = castAt frame circle
            label = name ++ " @ frame " ++ show frame
            grid = occupancyOf 3 cast
        (label, ogFrame grid) `shouldBe` (label, spellBoxOf cast)
        (label, ogDim grid) `shouldBe` (label, 3)
        -- The rows counted are exactly the rows the host is about to draw.
        (label, U.sum (ogCounts grid))
          `shouldBe` (label, sum (map particleCount (batches (observeSpell cast))))

  it "occupancyMask agrees with the dim-3 grid it is the fast path for" $ do
    circles <- exampleCircles
    forM_ circles $ \(name, circle) -> do
      let cast = castAt 100 circle
          counts = U.toList (ogCounts (occupancyOf occupancyDimDefault cast))
          mask = occupancyMask cast
      (name, [testBit mask c | c <- [0 .. length counts - 1]])
        `shouldBe` (name, [n > 0 | n <- counts])

  describe "the horizons, which are the layer's only decision" $ do
    it "an emitter box grows as the cast runs" $ do
      let boxAt n = let cast = castAt n travelling in emitterBoxOf cast (head (emittersOf cast))
      obHalfN (boxAt 0) `shouldSatisfy` (< obHalfN (boxAt 60))

    it "but the spell box does not: it is the same on every frame" $ do
      circles <- exampleCircles
      forM_ circles $ \(name, circle) -> do
        let boxes = [spellBoxOf (castAt n circle) | n <- [0, 30, 90, 240]]
        (name, filter (/= head boxes) boxes) `shouldBe` (name, [])

    it "and the whole-life bounds contain every current-age emitter box" $ do
      circles <- exampleCircles
      forM_ circles $ \(name, circle) -> do
        let cast = castAt 60 circle
            (lo, hi) = spellBoundsOf cast
        forM_ (zip [0 :: Int ..] (emittersOf cast)) $ \(e, em) -> do
          let (elo, ehi) = boxToAABB (emitterBoxOf cast em)
              label = name ++ " emitter " ++ show e
          (label, leq lo elo, leq ehi hi) `shouldBe` (label, True, True)

  describe "FrameOutput did not change (func-spec 0025 section 2.2)" $ do
    it "still has exactly one field, the batch list" $ do
      -- A record construction naming every field there is: adding one
      -- would stop this line compiling, which is the point.
      let out = FrameOutput {batches = []}
      batches out `shouldBe` []

    it "and asking a spatial query changes nothing about the output" $ do
      circles <- exampleCircles
      forM_ circles $ \(name, circle) -> do
        let cast = castAt 75 circle
            before = summarize (observeSpell cast)
            queried =
              ( spellBoundsOf cast
              , occupancyMask cast
              , U.sum (ogCounts (occupancyOf 4 cast))
              )
            after = queried `seq` summarize (observeSpell cast)
        (name, before) `shouldBe` (name, after)

-- | The observed rows, flattened to comparable values.
summarize :: FrameOutput -> [(Int, [Float], [Float], [Float], [Float], [Float])]
summarize out =
  [ ( pbCount pb
    , U.toList (pbPosX pb)
    , U.toList (pbPosY pb)
    , U.toList (pbPosZ pb)
    , U.toList (pbSize pb)
    , U.toList (pbLife pb)
    )
  | batch <- batches out
  , let pb = rbParticles batch
  ]

particleCount :: RenderBatch -> Int
particleCount = pbCount . rbParticles

leq :: V3 -> V3 -> Bool
leq (V3 ax ay az) (V3 bx by bz) = ax <= bx + 1e-3 && ay <= by + 1e-3 && az <= bz + 1e-3
