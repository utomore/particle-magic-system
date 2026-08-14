-- | S7 (func-spec 0007 §8): the frozen laws of the public interface,
-- re-proved now that 'ActiveSpell' carries cross-frame state.
--
-- Spec 0005 froze @stepSpell fi s == let s' = advanceSpell fi s in (s',
-- observeSpell s')@ when the only state was a clock; a mutable-feeling
-- integration state is exactly the kind of addition that can break it (by
-- integrating in @observeSpell@, or twice in @stepSpell@). ADR-0010 D7's
-- replay contract and D8's "a reload is a re-cast" are re-checked here for
-- the same reason.
module FieldStepObserveSpec (spec) where

import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), PhaseConfig (..), emptyCircle)
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , isFinished
  , observeSpell
  , spellAge
  , stepSpell
  )
import Magic.Rune (ForceField (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, forAll, listOf1)

ctx :: CastContext
ctx = CastContext {casterPos = V3 0.5 0 (-1), casterFacing = V3 0 1 0, seed = Seed 606}

fields :: [ForceField]
fields =
  [ Gravity (V3 0 (-4.5) 0)
  , PointAttractor (V3 1 0 2) 5 0.4
  , Vortex (V3 0 0 0) (V3 0 1 0) 3 0.25
  ]

-- | Fields on a plain discharge, and fields on a phased circle (so the
-- laws are checked with both the fast and the multi-emitter path).
fixtures :: [(String, Circle)]
fixtures =
  [ ("plain discharge + 3 fields", emptyCircle {circleFields = fields})
  ,
    ( "phased circle + 3 fields"
    , emptyCircle
        { circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))
        , circleFields = fields
        }
    )
  , ("no fields (the D9 path)", emptyCircle)
  ]

cast :: Circle -> ActiveSpell
cast circle = case castSpell CastRequest {circleOf = circle, ctxOf = ctx} of
  Right s -> s
  Left err -> error (show err)

-- | Realistic frame times: 60 Hz with jitter, plus the occasional hitch.
genDts :: Gen [Double]
genDts = listOf1 (choose (0.004, 0.1))

frameOf :: FrameOutput -> [(Int, [Float])]
frameOf out =
  [ ( pbCount buf
    , concat [U.toList (pbPosX buf), U.toList (pbPosY buf), U.toList (pbPosZ buf)]
    )
  | batch <- batches out
  , let buf = rbParticles batch
  ]

-- | Every frame a dt sequence produces.
render :: Circle -> [Double] -> [[(Int, [Float])]]
render circle dts = go (cast circle) dts
  where
    go _ [] = []
    go s (dt : rest) =
      let (s', out) = stepSpell (FrameInput (DeltaTime dt)) s
       in frameOf out : go s' rest

spec :: Spec
spec = describe "interface laws with fields (spec 0007 S7)" $ mapM_ laws fixtures

laws :: (String, Circle) -> Spec
laws (label, circle) = describe label $ do
  prop "decomposition: stepSpell == advanceSpell then observeSpell (every step)" $
    forAll genDts $ \dts ->
      firstBreak (cast circle) dts == Nothing

  prop "replay (D7): the same circle, context and dt sequence render identically" $
    forAll genDts $ \dts -> render circle dts == render circle dts

  prop "the clock is unaffected by the field layer" $
    forAll genDts $ \dts ->
      let final = foldl (\s dt -> advanceSpell (FrameInput (DeltaTime dt)) s) (cast circle) dts
          Time t = spellAge final
       in abs (t - sum' dts) < 1e-9

  it "a re-cast resets the field state to rest (D8: a hot reload is a re-cast)" $ do
    let walked = foldl (\s _ -> advanceSpell (FrameInput (DeltaTime 0.05)) s) (cast circle) [1 .. 40 :: Int]
        recast = cast circle
        fresh = foldl (\s _ -> advanceSpell (FrameInput (DeltaTime 0.05)) s) recast [1 .. 40 :: Int]
    spellAge recast `shouldBe` Time 0
    frameOf (observeSpell recast) `shouldBe` frameOf (observeSpell (cast circle))
    -- The re-cast walks the identical arc, so no state survived the recast.
    frameOf (observeSpell fresh) `shouldBe` frameOf (observeSpell walked)

  it "isFinished still keys off the clock alone" $ do
    let long = foldl (\s _ -> advanceSpell (FrameInput (DeltaTime 0.5)) s) (cast circle) [1 .. 40 :: Int]
    isFinished (cast circle) `shouldBe` False
    isFinished long `shouldBe` True

-- | Index of the first step at which the decomposition law fails.
firstBreak :: ActiveSpell -> [Double] -> Maybe Int
firstBreak spell0 = go 0 spell0
  where
    go _ _ [] = Nothing
    go i s (dt : rest) =
      let fi = FrameInput (DeltaTime dt)
          (stepped, out) = stepSpell fi s
          advanced = advanceSpell fi s
          agrees =
            spellAge stepped == spellAge advanced
              && frameOf out == frameOf (observeSpell advanced)
              -- and the two states are indistinguishable from here on:
              && frameOf (observeSpell (advanceSpell fi stepped))
                == frameOf (observeSpell (advanceSpell fi advanced))
       in if agrees then go (i + 1) advanced rest else Just i

sum' :: [Double] -> Double
sum' = foldl (+) 0
