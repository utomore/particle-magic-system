-- | Fixed-timestep planning (func-spec 0001 §5.3). Pure — lives in the
-- boundary layer so both the shell's main loop and the test suite consume
-- the exact same planner.
--
-- Key property (test T6): the same total elapsed time yields the same
-- total number of simulation steps regardless of how it is sliced into
-- frames (while the clamp is not hit) — the foundation of deterministic
-- replay. The simulation always advances by the fixed @dt@; the render
-- frame rate is decoupled via the accumulator.
module Magic.Step
  ( StepPlan (..)
  , plan
  ) where

data StepPlan = StepPlan
  { stepsToRun :: !Int
  , accAfter :: !Double
  }
  deriving (Eq, Show)

-- | @plan dt maxSteps elapsed acc@ decides how many fixed steps to run
-- this frame and the accumulator value to carry over.
--
-- When the backlog exceeds @maxSteps@ (spiral-of-death guard), the plan
-- clamps to @maxSteps@ and DROPS the remaining backlog (accumulator
-- resets to 0) — the simulation slows down instead of freezing. That
-- holds for every finite input, however large: a backlog too big to
-- count in steps still runs @maxSteps@ of them (B001).
plan :: Double -> Int -> Double -> Double -> StepPlan
plan dt maxSteps elapsed acc
  | dt <= 0 = StepPlan 0 acc
  | otherwise =
      let acc' = acc + max 0 elapsed
          -- Clock timestamps are differenced by the caller, so elapsed
          -- carries ±ulp float noise; a frame worth of backlog can land
          -- an ulp short of dt and lose a step. The epsilon (1e-9 of a
          -- frame ≈ 17ps at 60Hz) absorbs that noise. It is far below
          -- the gaps of the exact dyadic grid T6 tests on, so the
          -- bit-exact slicing property is unaffected.
          ratio = acc' / dt + stepEpsilon
       in -- B001: the clamp used to be decided after `floor`, on the
          -- assumption that a backlog measured in steps fits an Int. It
          -- need not: `ratio` is two finite Doubles divided, so it spans
          -- all of Double, and `floor :: Double -> Int` does not saturate
          -- outside Int's range — it answers with a meaningless bit
          -- pattern (0, minBound, or a large negative, varying with the
          -- optimisation level). The `n > maxSteps` guard then missed and
          -- an enormous backlog planned ZERO steps while handing the
          -- backlog straight back — a permanent freeze, the exact opposite
          -- of the drop-the-backlog rule above.
          --
          -- Asking the ratio directly is the same question: `floor ratio`
          -- is an integer, so `floor ratio > maxSteps` and `ratio >=
          -- maxSteps + 1` agree for every ratio that fits — the results
          -- of legal calls are bit-for-bit what they always were — and
          -- `floor` is now only ever reached when its argument is in
          -- range.
          --
          -- `finiteInputs` deliberately withholds the repair from
          -- non-finite ARGUMENTS. `elapsed`/`acc` of ±Inf are refused by
          -- the C ABI (host-runtime F005), and test/FFIStepPlanSpec.hs
          -- cites this function's answers for them as the reason that
          -- check has to exist; healing them here would quietly hollow out
          -- that argument. Finite arguments whose SUM overflows are a
          -- different thing and are repaired.
          if finiteInputs && ratio >= fromIntegral maxSteps + 1
            then StepPlan maxSteps 0
            else
              let n = floor ratio
               in if n > maxSteps
                    then StepPlan maxSteps 0
                    else StepPlan n (max 0 (acc' - fromIntegral n * dt))
  where
    stepEpsilon = 1e-9
    finiteInputs = not (isInfinite elapsed || isInfinite acc)
