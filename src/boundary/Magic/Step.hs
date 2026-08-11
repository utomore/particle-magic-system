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
-- resets to 0) — the simulation slows down instead of freezing.
plan :: Double -> Int -> Double -> Double -> StepPlan
plan dt maxSteps elapsed acc
  | dt <= 0 = StepPlan 0 acc
  | otherwise =
      let acc' = acc + max 0 elapsed
          n = floor (acc' / dt)
       in if n > maxSteps
            then StepPlan maxSteps 0
            else StepPlan n (max 0 (acc' - fromIntegral n * dt))
