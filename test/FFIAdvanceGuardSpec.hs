-- | host-runtime F005 T4–T5: what the four advance entry points do with a
-- @dt@ that is not a length of time.
--
-- The bug this closes is small to describe and fatal to run into. Nothing
-- checked @dt@, so a host that fed one NaN frame — a clock read before it
-- was initialised, a division by a zero frame count — poisoned the
-- spell's age permanently. From then on @age + dt@ was NaN, @isFinished@
-- compared NaN against the lifetime and got 'False' forever, and the
-- documented host loop @while (!pm_is_finished(s))@ never ended. An
-- infinite @dt@ does the same thing one step later, and a negative one
-- rewinds a clock that is not supposed to run backwards.
--
-- C2.6 splits the answer in two, because the frozen signatures allow no
-- other:
--
--   * 'pm_advance' and 'pm_scene_advance' return @void@ — they are in the
--     frozen 31 and cannot grow a return value — so they take the half of
--     the promise a @void@ can keep: an illegal @dt@ changes nothing at
--     all. Not the age, not one particle.
--   * 'pm_advance_ex' and 'pm_scene_advance_ex' are the add-only variants
--     (C1.12) that also say so, with 'pmErrArgs'. They exist for exactly
--     this, and for the invalid handle the @void@ pair also cannot report.
--
-- Zero is legal in both: a paused host stepping 0 is asking for a no-op
-- and gets one, with 'pmOk'.
--
-- Every "unchanged" here is a bit-pattern comparison. An age asserted with
-- '==' would accept @-0.0@ for @0.0@, and a spell's particle columns
-- compared with '==' would accept the same swap in 16k places.
module FFIAdvanceGuardSpec (spec) where

import qualified Data.ByteString as BS
import Data.Word (Word32, Word64)
import FFIHarness
  ( Observed (..)
  , batchTuples
  , castOk
  , referenceAt
  , referenceSpell
  , spellBytes
  , testCtx
  )
import FFISceneSpec (exampleBudget, sceneCastOk, sceneObserve, withSceneHandle)
import Foreign.C.Types (CDouble (..), CFloat (..), CInt (..))
import Foreign.StablePtr (StablePtr)
import GHC.Float (castDoubleToWord64, castFloatToWord32)
import Magic.FFI
  ( SpellCell
  , nullScene
  , nullSpell
  , pmErrArgs
  , pmOk
  , pm_advance
  , pm_advance_ex
  , pm_age
  , pm_free
  , pm_is_finished
  , pm_scene_advance
  , pm_scene_advance_ex
  )
import Magic.Interface (Time (..), spellAge)
import Test.Hspec

spec :: Spec
spec = describe "advance guards (host-runtime F005, C2.6 / C1.12)" $ do
  -- T4 -------------------------------------------------------------------
  it "the _ex advance rejects non-finite and negative dt, leaving the age untouched" $ do
    bytes <- spellBytes "ring-fire"
    handle <- castOk bytes testCtx
    mapM_ (\_ -> pm_advance_ex handle (CFloat dt60) `shouldReturn` pmOk) [1 .. 3 :: Int]
    baseline <- ageBits handle
    mapM_
      ( \(label, bad) -> do
          code <- pm_advance_ex handle bad
          (label, code) `shouldBe` (label, pmErrArgs)
          now <- ageBits handle
          (label, now) `shouldBe` (label, baseline)
      )
      illegalDts
    -- Zero is the one edge that is legal, and it too must not move a bit.
    pm_advance_ex handle 0 `shouldReturn` pmOk
    ageBits handle `shouldReturn` baseline
    -- And the legal path is still the same simulation: four frames of
    -- 1/60, matching the reference exactly.
    pm_advance_ex handle (CFloat dt60) `shouldReturn` pmOk
    ageBits handle `shouldReturn` referenceAgeBits bytes (replicate 4 dt60)
    pm_free handle

  it "the _ex advance calls an unusable handle an argument error" $ do
    -- The void pm_advance tolerates NULL silently; the variant with an
    -- error channel uses it, as every other classifying entry point does.
    pm_advance_ex nullSpell (CFloat dt60) `shouldReturn` pmErrArgs
    bytes <- spellBytes "ring-fire"
    freed <- castOk bytes testCtx
    pm_free freed
    pm_advance_ex freed (CFloat dt60) `shouldReturn` pmErrArgs
    pm_scene_advance_ex nullScene (CFloat dt60) `shouldReturn` pmErrArgs

  it "the scene _ex advance rejects the same dt values, leaving every spell untouched" $ do
    bytes <- spellBytes "ring-fire"
    let cap = exampleBudget bytes
    withSceneHandle cap $ \sc -> do
      _ <- sceneCastOk sc bytes testCtx
      -- Long enough that the emitters have actually produced particles:
      -- comparing two empty observations would prove nothing, so the
      -- next assertion insists the baseline has something in it.
      mapM_ (\_ -> pm_scene_advance_ex sc (CFloat dt60) `shouldReturn` pmOk) [1 .. 40 :: Int]
      settled <- sceneObserve sc cap 32
      liveParticles settled `shouldSatisfy` (> 0)
      let baseline = sceneBits settled
      mapM_
        ( \(label, bad) -> do
            code <- pm_scene_advance_ex sc bad
            (label, code) `shouldBe` (label, pmErrArgs)
            now <- sceneBits <$> sceneObserve sc cap 32
            (label, now == baseline) `shouldBe` (label, True)
        )
        illegalDts
      pm_scene_advance_ex sc 0 `shouldReturn` pmOk
      afterZero <- sceneBits <$> sceneObserve sc cap 32
      afterZero `shouldBe` baseline
      -- A legal step does move it, or the assertions above prove nothing.
      pm_scene_advance_ex sc (CFloat dt60) `shouldReturn` pmOk
      moved <- sceneBits <$> sceneObserve sc cap 32
      moved `shouldSatisfy` (/= baseline)

  -- T5 -------------------------------------------------------------------
  it "the void advance is a no-op on an illegal dt and unchanged on a legal one" $ do
    bytes <- spellBytes "ring-fire"
    handle <- castOk bytes testCtx
    mapM_ (\_ -> pm_advance handle (CFloat dt60)) [1 .. 3 :: Int]
    baseline <- ageBits handle
    finishedBefore <- pm_is_finished handle
    mapM_
      ( \(label, bad) -> do
          pm_advance handle bad
          now <- ageBits handle
          (label, now) `shouldBe` (label, baseline)
          finished <- pm_is_finished handle
          (label, finished) `shouldBe` (label, finishedBefore)
      )
      illegalDts
    -- 3 already run plus 117 more: the same 120-frame sequence the rest of
    -- the suite compares against, so a guard that skipped a legal frame
    -- would show up here.
    mapM_ (\_ -> pm_advance handle (CFloat dt60)) [1 .. 117 :: Int]
    ageBits handle `shouldReturn` referenceAgeBits bytes (replicate 120 dt60)
    pm_free handle

  it "the void scene advance is a no-op on an illegal dt" $ do
    bytes <- spellBytes "ring-fire"
    let cap = exampleBudget bytes
    withSceneHandle cap $ \sc -> do
      _ <- sceneCastOk sc bytes testCtx
      mapM_ (\_ -> pm_scene_advance sc (CFloat dt60)) [1 .. 40 :: Int]
      settled <- sceneObserve sc cap 32
      liveParticles settled `shouldSatisfy` (> 0)
      let baseline = sceneBits settled
      mapM_
        ( \(label, bad) -> do
            pm_scene_advance sc bad
            now <- sceneBits <$> sceneObserve sc cap 32
            (label, now == baseline) `shouldBe` (label, True)
        )
        illegalDts

  it "a NaN frame no longer freezes a host's while (!pm_is_finished) loop" $ do
    -- The regression, written the way the header tells a host to write it.
    -- Before the guard this loop did not terminate: the NaN age made
    -- isFinished answer False for the rest of the process.
    bytes <- spellBytes "ring-fire"
    handle <- castOk bytes testCtx
    pm_advance handle (CFloat nanF)
    let bound = 5000 :: Int
        loop n
          | n >= bound = pure n
          | otherwise = do
              finished <- pm_is_finished handle
              if finished /= 0
                then pure n
                else pm_advance handle (CFloat dt60) >> loop (n + 1)
    frames <- loop 0
    frames `shouldSatisfy` (< bound)
    -- And the age is a number, not a NaN, at the end of it.
    CDouble age <- pm_age handle
    age `shouldSatisfy` (\a -> not (isNaN a) && a > 0)
    pm_free handle

-- Fixtures --------------------------------------------------------------------

dt60 :: Float
dt60 = 1 / 60

nanF, infF :: Float
nanF = 0 / 0
infF = 1 / 0

-- | Every @dt@ the four advances refuse, labelled so a failure names the
-- one that got through.
illegalDts :: [(String, CFloat)]
illegalDts =
  [ ("NaN", CFloat nanF)
  , ("+Infinity", CFloat infF)
  , ("-Infinity", CFloat (-infF))
  , ("-1/60", CFloat (-dt60))
  , ("a whole negative second", CFloat (-1))
  , -- The smallest negative float there is: a guard written as
    -- @dt < -epsilon@ would wave it through.
    ("the smallest negative float", CFloat (-1.0e-45))
  ]

-- | The spell's age as a bit pattern — @==@ on a 'Double' would call
-- @-0.0@ and @0.0@ the same age, and would call two NaNs unequal.
ageBits :: StablePtr SpellCell -> IO Word64
ageBits h = do
  CDouble age <- pm_age h
  pure (castDoubleToWord64 age)

-- | The age the plain 'Magic.Interface' path reaches over the same frame
-- sequence, as the same bit pattern. The @dt@ values are 'Float' because
-- the C ABI's are: a host stepping @1.0f\/60.0f@ and one stepping
-- @1\/60 :: Double@ run different simulations, and 'referenceAt' narrows
-- the same way the boundary does.
referenceAgeBits :: BS.ByteString -> [Float] -> Word64
referenceAgeBits bytes dts =
  let Time age = spellAge (referenceAt (referenceSpell bytes testCtx) dts)
   in castDoubleToWord64 age

-- | Particles across every batch of an observation. A scene that has not
-- emitted anything yet compares equal to itself no matter what was done
-- to it, so the "unchanged" assertions are only worth something once this
-- is positive.
liveParticles :: Observed -> Int
liveParticles obs =
  sum [count | (_, count, _, _) <- batchTuples (max 0 (fromIntegral (obCode obs))) obs]

-- | Everything @pm_scene_observe@ wrote, as bit patterns: five float
-- columns, the colour column, the batch descriptors and the return code.
-- Comparing these is how "the scene did not move" is asserted without a
-- per-spell clock to read (a scene has no @pm_scene_age@).
sceneBits :: Observed -> ([Word32], [CInt])
sceneBits obs =
  ( concatMap
      (map castFloatToWord32)
      [obPosX obs, obPosY obs, obPosZ obs, obSize obs, obLife obs]
      ++ obColor obs
  , obCode obs : obInfo obs
  )
