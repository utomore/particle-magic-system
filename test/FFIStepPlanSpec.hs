-- | host-runtime F005 T1–T3: the fixed-timestep planner on the C side.
--
-- C1.7 does not ask for a planner that behaves /like/ the boundary
-- layer's — it asks for the same one, bit for bit. That is a claim about
-- an implementation, and the only honest way to check it is to run both
-- and compare the bit patterns, which is what the property at the bottom
-- does over whole frame sequences: the accumulator is fed back in, so a
-- discrepancy of one ulp on frame 3 is still visible on frame 40.
--
-- The reason it can pass at all is that @pm_plan_steps@ does not
-- reimplement anything: it type-crosses and calls 'Magic.Step.plan'. The
-- test's real job is therefore to fail the day somebody "optimises" it
-- into a second copy — the clamp, the epsilon and the drop-the-backlog
-- rule are exactly the parts a rewrite would get subtly wrong.
--
-- Around that sits the argument check, which /is/ new behaviour on this
-- side of the boundary and needs saying: 'Magic.Step.plan' is a pure
-- function with no error channel, and its answers on non-finite or
-- negative input are actively dangerous to a host (a silently emptied
-- accumulator, a permanently poisoned one, or a negative step count about
-- to be used as a loop bound). Those are PM_ERR_ARGS here, and the error
-- path writes no byte at all — asserted with both out slots pre-filled,
-- the way every other all-or-nothing entry point in this suite is.
module FFIStepPlanSpec (spec) where

import Data.Word (Word64)
import Foreign.C.Types (CDouble (..), CInt (..))
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Magic.FFI (pmErrArgs, pmOk, pm_plan_steps)
import Magic.Step (StepPlan (..), plan)
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = describe "fixed-timestep planner over the C ABI (host-runtime F005)" $ do
  -- T1 -------------------------------------------------------------------
  it "plans a typical 60Hz frame exactly as Magic.Step.plan does" $ do
    let dt = 1 / 60
        maxSteps = 8
        elapsed = 1 / 30
        StepPlan refSteps refAcc = plan dt maxSteps elapsed 0
    (code, steps, acc) <- callPlan dt maxSteps elapsed 0
    code `shouldBe` pmOk
    -- Two frames' worth of backlog is two steps, with nothing left over:
    -- the value a host would have computed by hand, so a wired-up-wrong
    -- out parameter cannot hide behind "whatever the reference said".
    steps `shouldBe` 2
    refSteps `shouldBe` 2
    bits acc `shouldBe` bits (CDouble refAcc)

  it "clamps a long hitch and drops the backlog, exactly as the planner does" $ do
    -- A whole second of backlog at 60Hz is 60 steps; the clamp keeps 8 and
    -- throws the other 52 away, which is what makes the simulation slow
    -- down rather than freeze.
    let dt = 1 / 60
        StepPlan refSteps refAcc = plan dt 8 1.0 0
    (code, steps, acc) <- callPlan dt 8 1.0 0
    code `shouldBe` pmOk
    steps `shouldBe` 8
    refSteps `shouldBe` 8
    bits acc `shouldBe` bits (CDouble refAcc)
    acc `shouldBe` 0

  it "absorbs a backlog an ulp short of dt through the planner's epsilon" $ do
    -- The epsilon is a `where` binding inside 'Magic.Step.plan' with no
    -- way out of that module, so a C-side reimplementation could not even
    -- copy it — which is the point. An accumulator one ulp below dt is a
    -- step that a naive `acc >= dt` would lose.
    let dt = 1 / 60
        shy = nextBelow dt
        StepPlan refSteps _ = plan dt 8 0 shy
    (code, steps, _) <- callPlan dt 8 0 shy
    code `shouldBe` pmOk
    shy `shouldSatisfy` (< dt)
    steps `shouldBe` 1
    refSteps `shouldBe` 1

  it "mirrors the planner's dt <= 0 rule instead of rejecting it" $ do
    -- Deliberately NOT C2.6's rule for the advances. A planner's dt is the
    -- host's fixed setting, an advance's is its per-frame input; a zero or
    -- negative setting means "run no steps", and the accumulator comes
    -- back untouched rather than being confiscated.
    mapM_
      ( \dt -> do
          (code, steps, acc) <- callPlan dt 8 0.5 0.25
          (dt, code) `shouldBe` (dt, pmOk)
          (dt, steps) `shouldBe` (dt, 0)
          (dt, bits acc) `shouldBe` (dt, bits 0.25)
      )
      [0, -0.0, -1 / 60, -1e9]

  -- T2 -------------------------------------------------------------------
  it "rejects bad arguments with PM_ERR_ARGS and writes nothing" $ do
    mapM_
      ( \(label, dt, maxSteps, elapsed, accIn) -> do
          (code, steps, acc) <- callPlan dt maxSteps elapsed accIn
          (label, code) `shouldBe` (label, pmErrArgs)
          -- Bit patterns, not values: an out parameter overwritten with
          -- something that happens to compare equal is still a write.
          (label, steps) `shouldBe` (label, stepSentinel)
          (label, bits acc) `shouldBe` (label, bits accSentinel)
      )
      badArguments

  it "rejects a NULL out parameter without touching the other one" $ do
    -- Each direction separately: a check written as `a == NULL && b ==
    -- NULL` would pass a two-NULL test and still scribble on a host that
    -- passed one.
    nullSteps <- withAccOut (\outAcc -> pm_plan_steps (1 / 60) 8 (1 / 30) 0 nullPtr outAcc)
    fst nullSteps `shouldBe` pmErrArgs
    bits (snd nullSteps) `shouldBe` bits accSentinel
    nullAcc <- withStepsOut (\outSteps -> pm_plan_steps (1 / 60) 8 (1 / 30) 0 outSteps nullPtr)
    fst nullAcc `shouldBe` pmErrArgs
    snd nullAcc `shouldBe` stepSentinel
    both <- pm_plan_steps (1 / 60) 8 (1 / 30) 0 nullPtr nullPtr
    both `shouldBe` pmErrArgs

  it "would have handed a host a poisoned or negative plan (the regression)" $ do
    -- Why the check above is not bureaucracy: this is what the planner
    -- alone answers for the same inputs. Each line is a live host bug —
    -- a vanished backlog, an accumulator that never recovers, and a step
    -- count about to become `for (i = 0; i < steps; i++)`.
    accAfter (plan (0 / 0) 8 0.5 0.25) `shouldBe` 0 -- backlog confiscated
    accAfter (plan (1 / 60) 8 (1 / 0) 0.25) `shouldSatisfy` isInfinite
    stepsToRun (plan (1 / 60) (-3) 0.5 0.25) `shouldSatisfy` (< 0)
    stepsToRun (plan (1 / 60) 8 0.5 (-0.9)) `shouldSatisfy` (< 0)

  -- T3 -------------------------------------------------------------------
  it "is bit-identical to Magic.Step.plan over a frame sequence" $
    property prop_bitIdentical

  it "keeps its post-condition over the same sequences" $
    property prop_postCondition

-- Calling the entry point ------------------------------------------------------

-- | A step count nothing may leave behind, and an accumulator value with a
-- bit pattern no plan produces.
stepSentinel :: CInt
stepSentinel = -999

accSentinel :: CDouble
accSentinel = -12345.5

-- | @pm_plan_steps@ with both out slots pre-filled, handing back the code
-- and whatever the slots hold afterwards — so "wrote nothing" and "wrote
-- the answer" are the same assertion shape.
callPlan :: Double -> Int -> Double -> Double -> IO (CInt, CInt, CDouble)
callPlan dt maxSteps elapsed accIn =
  with stepSentinel $ \outSteps ->
    with accSentinel $ \outAcc -> do
      code <-
        pm_plan_steps
          (CDouble dt)
          (fromIntegral maxSteps)
          (CDouble elapsed)
          (CDouble accIn)
          outSteps
          outAcc
      (,,) code <$> peek outSteps <*> peek outAcc

-- | Run a call that supplies its own step pointer, reporting the
-- accumulator slot's contents.
withAccOut :: (Ptr CDouble -> IO CInt) -> IO (CInt, CDouble)
withAccOut k = with accSentinel $ \outAcc -> (,) <$> k outAcc <*> peek outAcc

withStepsOut :: (Ptr CInt -> IO CInt) -> IO (CInt, CInt)
withStepsOut k = with stepSentinel $ \outSteps -> (,) <$> k outSteps <*> peek outSteps

-- | @(label, dt, max_steps, elapsed, acc_in)@ for every input the C side
-- refuses. The labels are what a failure reports; a bare tuple of doubles
-- would say only "expected -4".
badArguments :: [(String, Double, Int, Double, Double)]
badArguments =
  [ ("dt = NaN", nan, 8, 1 / 30, 0.25)
  , ("dt = +Inf", inf, 8, 1 / 30, 0.25)
  , ("dt = -Inf", -inf, 8, 1 / 30, 0.25)
  , ("elapsed = NaN", 1 / 60, 8, nan, 0.25)
  , ("elapsed = +Inf", 1 / 60, 8, inf, 0.25)
  , ("elapsed = -Inf", 1 / 60, 8, -inf, 0.25)
  , ("acc_in = NaN", 1 / 60, 8, 1 / 30, nan)
  , ("acc_in = +Inf", 1 / 60, 8, 1 / 30, inf)
  , ("acc_in = -Inf", 1 / 60, 8, 1 / 30, -inf)
  , ("max_steps = -1", 1 / 60, -1, 1 / 30, 0.25)
  , ("max_steps = minBound-ish", 1 / 60, -100000, 1 / 30, 0.25)
  , ("acc_in = -0.5", 1 / 60, 8, 1 / 30, -0.5)
  , ("acc_in = tiny negative", 1 / 60, 8, 1 / 30, -5e-324)
  ]

nan, inf :: Double
nan = 0 / 0
inf = 1 / 0

-- | The largest 'Double' strictly below a positive one.
nextBelow :: Double -> Double
nextBelow x = castWord64ToDouble (castDoubleToWord64 x - 1)

-- | Compare by bit pattern: @==@ on doubles calls @0.0@ and @-0.0@ equal,
-- and this spec is about bits.
bits :: CDouble -> Word64
bits (CDouble d) = castDoubleToWord64 d

-- The property ----------------------------------------------------------------

-- | One host's loop: a fixed step, a clamp, and the frame times it saw.
data PlanRun = PlanRun
  { runDt :: Double
  , runMax :: Int
  , runFrames :: [Double]
  }
  deriving (Show)

instance Arbitrary PlanRun where
  arbitrary = do
    dt <-
      elements
        -- Exact dyadic steps (where the slicing law is bit-exact),
        -- the two rates hosts actually ship, and the degenerate
        -- settings the planner answers with zero steps.
        [1 / 64, 1 / 128, 1 / 32, 1 / 256, 1 / 60, 1 / 30, 1 / 144, 0, -1 / 60]
    maxSteps <- choose (0, 12)
    n <- choose (1, 40)
    frames <- vectorOf n (frameGen dt)
    pure (PlanRun dt maxSteps frames)

  shrink (PlanRun dt maxSteps frames) =
    [PlanRun dt maxSteps fs | fs <- shrink frames, not (null fs)]

-- | One frame's elapsed time. Mostly a frame worth of it, nudged by a few
-- ulps — clock timestamps are differenced by the host, so that noise is
-- the normal case and it is exactly what the planner's epsilon is for.
-- The rest are the interesting ones: a stall long enough to trip the
-- clamp, a paused frame, and a negative reading (which the planner reads
-- as zero rather than rewinding).
frameGen :: Double -> Gen Double
frameGen dt =
  frequency
    [ (6, do k <- choose (-4, 4 :: Int); pure (nudge k (abs dt)))
    , (2, choose (0, 0.05))
    , (2, choose (0.2, 3))
    , (1, pure 0)
    , (1, choose (-1, 0))
    ]
  where
    nudge k x
      | x <= 0 = x
      | otherwise = castWord64ToDouble (castDoubleToWord64 x + fromIntegral k)

-- | The law: over a whole sequence, with the accumulator fed back in,
-- the C side and 'Magic.Step.plan' agree bit for bit — both on the step
-- count and on the accumulator.
prop_bitIdentical :: PlanRun -> Property
prop_bitIdentical (PlanRun dt maxSteps frames) = ioProperty (go 0 frames)
  where
    go _ [] = pure (property True)
    go acc (elapsed : rest) = do
      (code, steps, CDouble accOut) <- callPlan dt maxSteps elapsed acc
      let StepPlan refSteps refAcc = plan dt maxSteps elapsed acc
      if code /= pmOk
        then pure (counterexample ("unexpected code " ++ show code) False)
        else
          if fromIntegral steps /= refSteps || castDoubleToWord64 accOut /= castDoubleToWord64 refAcc
            then
              pure
                ( counterexample
                    ( "frame acc="
                        ++ show acc
                        ++ " elapsed="
                        ++ show elapsed
                        ++ ": C gave "
                        ++ show (steps, accOut)
                        ++ ", plan gave "
                        ++ show (refSteps, refAcc)
                    )
                    False
                )
            else go accOut rest

-- | The header's promise to a host that trusts the return code:
-- @*out_steps@ is a usable loop bound and @*out_acc@ is a usable
-- accumulator. Both are provable from the planner's shape, which is
-- exactly why they are cheap to assert and worth asserting.
prop_postCondition :: PlanRun -> Property
prop_postCondition (PlanRun dt maxSteps frames) = ioProperty (go 0 frames)
  where
    go _ [] = pure (property True)
    go acc (elapsed : rest) = do
      (code, steps, CDouble accOut) <- callPlan dt maxSteps elapsed acc
      if code /= pmOk
        then pure (counterexample ("unexpected code " ++ show code) False)
        else
          if steps < 0 || fromIntegral steps > maxSteps || accOut < 0
            then
              pure
                ( counterexample
                    ("out of range: steps=" ++ show steps ++ " acc=" ++ show accOut)
                    False
                )
            else go accOut rest
