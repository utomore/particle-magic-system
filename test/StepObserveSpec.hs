-- | S1 (func-spec 0005 §8): 'stepSpell' is exactly 'advanceSpell'
-- followed by 'observeSpell'.
--
-- This is the law that lets the main loop run n fixed simulation steps
-- but sample only once per rendered frame. Until 0005 the loop stepped up
-- to 8 times and threw 7 'FrameOutput's away; laziness happened to make
-- that free, but nothing enforced it. The decomposition is frozen here so
-- the saving is structural instead of accidental.
module StepObserveSpec (spec) where

import qualified Data.ByteString as BS
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , emptyCircle
  , isFinished
  , observeSpell
  , spellAge
  , stepSpell
  )
import Magic.Codec (loadCircle)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

emptySpell :: ActiveSpell
emptySpell = case castSpell (CastRequest emptyCircle ctx) of
  Right s -> s
  Left e -> error ("empty circle must cast: " ++ show e)

spellFrom :: FilePath -> IO ActiveSpell
spellFrom path = do
  bytes <- BS.readFile path
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (castSpell (CastRequest circle ctx))

-- | Walk a dt sequence, checking the law at every step. Returns 'Nothing'
-- on success or the index of the first mismatch.
lawHolds :: ActiveSpell -> [Double] -> Maybe Int
lawHolds spell0 = go (0 :: Int) spell0
  where
    go _ _ [] = Nothing
    go i s (dt : rest) =
      let fi = FrameInput (DeltaTime dt)
          (stepped, out) = stepSpell fi s
          advanced = advanceSpell fi s
          observed = observeSpell advanced
          agrees =
            spellAge stepped == spellAge advanced
              && out == observed
              && isFinished stepped == isFinished advanced
       in if agrees then go (i + 1) stepped rest else Just i

spec :: Spec
spec = describe "advance/observe decomposition (func-spec 0005 §4.1)" $ do
  prop "stepSpell fi s == (advanceSpell fi s, observeSpell (advanceSpell fi s))" $
    forAll (listOf1 (choose (0, 0.2))) $ \dts ->
      lawHolds emptySpell dts === Nothing

  it "the law holds for every example spell over a full lifetime" $
    mapM_
      ( \path -> do
          spell <- spellFrom path
          lawHolds spell (replicate 400 (1 / 60)) `shouldBe` Nothing
      )
      [ "assets/spells/ring-fire.json"
      , "assets/spells/square-burst.json"
      , "assets/spells/spiral-spark.json"
      , "assets/spells/converge-flame.json"
      , "assets/spells/lissajous.json"
      , "assets/spells/pulse-ring.json"
      ]

  prop "observeSpell is idempotent: sampling never moves the spell" $
    forAll (choose (0, 12)) $ \t ->
      let s = advanceSpell (FrameInput (DeltaTime t)) emptySpell
       in observeSpell s === observeSpell s

  prop "advanceSpell accumulates dt exactly like stepSpell" $
    forAll (listOf1 (choose (0, 0.2))) $ \dts ->
      let step s dt = fst (stepSpell (FrameInput (DeltaTime dt)) s)
          adv s dt = advanceSpell (FrameInput (DeltaTime dt)) s
          Time a = spellAge (foldl step emptySpell dts)
          Time b = spellAge (foldl adv emptySpell dts)
       in a === b

  it "advancing without observing still flips isFinished at the lifetime" $ do
    spell <- spellFrom "assets/spells/ring-fire.json"
    let dt = FrameInput (DeltaTime (1 / 60))
        aged = foldl (\s _ -> advanceSpell dt s) spell [1 .. 620 :: Int]
    isFinished spell `shouldBe` False
    isFinished aged `shouldBe` True
