-- | S1 (func-spec 0020 §7): 'SigilSpin' and the piecewise angle function.
--
-- Two claims carry this round.
--
-- The first is about /time/: the angle is a C¹ piecewise-closed form of
-- the cast clock whose angular speed is bounded by
-- @|rate| + |accel|·rampEnd@ — a bound that does not grow with the
-- spell's length. Before func-spec 0017 a plain quadratic was safe
-- because the sigil only lived ~1.5 s; now it lives for the whole cast
-- (ADR-0015 D1) and a constant angular acceleration would spin the figure
-- into a blurred disc by the end (§2.3). This spec is what stops that.
--
-- The second is about /geometry/: the rotation is an isometry of the face
-- plane about the origin, so func-spec 0016's three laws — index order is
-- draw order, @n@ arms are exact rotations of each other, and
-- @|p| <= strokeRadius@ — survive it word for word. That third one is why
-- 'Magic.Compile.emitterBounds', spec 0010's culling and the whole of
-- @Magic.Compile@ needed no change at all (§2.2).
module SigilSpinSpec (spec) where

import Magic.Sigil
  ( SigilSpin (..)
  , SigilStroke (..)
  , StrokeKind (..)
  , sampleStroke
  , spinAngle
  , staticSpin
  , strokeParam
  , strokeRadius
  )
import Magic.Types (V2 (..))
import SigilGen (allKindsOf, genSpin, genStroke)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

magV2 :: V2 -> Float
magV2 (V2 x y) = sqrt (x * x + y * y)

finite :: Float -> Bool
finite v = not (isNaN v || isInfinite v)

rotate :: Float -> V2 -> V2
rotate th (V2 x y) = V2 (x * cos th - y * sin th) (x * sin th + y * cos th)

-- | What the sampler does with a stroke at cast time @t@ (the one line
-- 'Magic.Particle.Analytic.positionIn' gained this round).
spun :: SigilStroke -> Double -> Int -> V2
spun sk t i = rotate (spinAngle (skSpin sk) t) (sampleStroke sk i)

-- | Step of the difference quotient. Central differences are /exact/ for
-- a quadratic, so on either branch this measures the true angular speed
-- up to float rounding, not up to a truncation error.
step :: Double
step = 0.01

-- | Angular speed, measured the way an observer would: by how far the
-- figure turned between two nearby instants.
omegaAt :: SigilSpin -> Double -> Float
omegaAt sp t = (spinAngle sp (t + step) - spinAngle sp (t - step)) / realToFrac (2 * step)

-- | The bound the piecewise shape exists to provide.
omegaBound :: SigilSpin -> Float
omegaBound sp = abs (ssRate sp) + abs (ssAccel sp) * max 0 (ssRampEnd sp)

-- | Indices of one arm, in order.
armIndices :: SigilStroke -> Int -> [Int]
armIndices sk arm = [arm, arm + sym .. skCount sk - 1]
  where
    sym = max 1 (skSymmetry sk)

-- | A jitter-free stroke of the given kind, turning at the given rate.
crisp :: Int -> StrokeKind -> Int -> SigilSpin -> SigilStroke
crisp sym kind steps sp =
  SigilStroke
    { skKind = kind
    , skRadius = 1.2
    , skSymmetry = sym
    , skPhase = 0.3
    , skJitter = 0
    , skCount = steps * sym
    , skSpin = sp
    }

-- | Cast-clock instants: a spell's own span, plus a little before and
-- after.
genCastTime :: Gen Double
genCastTime = choose (-1, 12)

spec :: Spec
spec = describe "sigil spin: the angle function (func-spec 0020 S1)" $ do
  describe "the angle at the start of the cast" $ do
    prop "spinAngle sp 0 == 0 for every spin (the starting phase lives in skPhase)" $
      forAll genSpin $ \sp -> spinAngle sp 0 === 0

    prop "and so is every instant before it (total, clamped)" $
      forAll genSpin $ \sp ->
        forAll (choose (-1e6, 0)) $ \t -> spinAngle sp t === 0

    prop "staticSpin never turns at all" $
      forAll genCastTime $ \t -> spinAngle staticSpin t === 0

  describe "the piecewise shape" $ do
    prop "C1 at the charge-up landmark: the angular speed does not jump" $
      forAll genSpin $ \sp0 ->
        forAll (choose (0.2 :: Double, 2.4)) $ \r0 ->
          let sp = sp0 {ssRampEnd = realToFrac r0}
              r = realToFrac (ssRampEnd sp) :: Double
              left = (spinAngle sp r - spinAngle sp (r - step)) / realToFrac step
              right = (spinAngle sp (r + step) - spinAngle sp r) / realToFrac step
              slack = abs (ssAccel sp) * realToFrac step + 1e-3
           in counterexample (show (left, right, slack)) (abs (left - right) <= slack)

    prop "the angular speed is bounded by |rate| + |accel|*rampEnd, at every t" $
      forAll genSpin $ \sp ->
        forAll genCastTime $ \t ->
          let w = omegaAt sp t
           in counterexample (show (t, w, omegaBound sp)) (abs w <= omegaBound sp + 1e-3)

    prop "the charge-up really does speed the stroke up, then holds it" $
      forAll genSpin $ \sp0 ->
        let sp = sp0 {ssRampEnd = 2, ssRate = 0.2, ssAccel = 0.2}
            duringA = abs (omegaAt sp 0.5)
            duringB = abs (omegaAt sp 1.5)
            afterA = abs (omegaAt sp 3)
            afterB = abs (omegaAt sp 9)
         in counterexample (show (duringA, duringB, afterA, afterB)) $
              duringA < duringB
                .&&. duringB < afterA
                .&&. abs (afterA - afterB) <= 1e-3
                .&&. afterA <= omegaBound sp + 1e-3

    prop "negating the spin negates the angle, exactly" $
      forAll genSpin $ \sp ->
        forAll genCastTime $ \t ->
          spinAngle sp {ssRate = negate (ssRate sp), ssAccel = negate (ssAccel sp)} t
            === negate (spinAngle sp t)

  describe "total and finite" $ do
    it "no time, however extreme, produces a NaN or an infinity" $
      sequence_
        [ spinAngle sp t `shouldSatisfy` finite
        | sp <-
            [ staticSpin
            , SigilSpin 0.45 0.30 2.4
            , SigilSpin (-0.45) (-0.30) 2.4
            , SigilSpin 0.45 0.30 0
            ]
        , t <- [-1e12, -1e6, -1, 0, 1e-9, 1, 12, 1e6, 1e12]
        ]

    prop "finite for any generated spin at any generated time" $
      forAll genSpin $ \sp ->
        forAll genCastTime $ \t -> property (finite (spinAngle sp t))

  -- The isometry laws (§2.2). Each one is func-spec 0016's, restated
  -- about the /rotated/ sample, and each is proved structurally rather
  -- than statistically: a rotation about the origin is a linear isometry
  -- that commutes with the arm rotations.
  describe "func-spec 0016's three laws survive the rotation" $ do
    prop "index order is draw order: the rotation is a rigid relabeling" $
      forAll genStroke $ \sk ->
        forAll genCastTime $ \t ->
          let th = spinAngle (skSpin sk) t
              back i = rotate (negate th) (spun sk t i)
           in conjoin
                [ counterexample (show (i, back i, sampleStroke sk i)) $
                    magV2 (back i - sampleStroke sk i) <= 1e-5 * (1 + strokeRadius sk)
                | i <- [0 .. skCount sk - 1]
                ]

    prop "...so the curve parameter is still strictly increasing along an arm" $
      forAll genStroke $ \sk ->
        let sym = max 1 (skSymmetry sk)
         in conjoin
              [ let params = map (strokeParam sk) (armIndices sk arm)
                 in counterexample (show params) (and (zipWith (<) params (drop 1 params)))
              | arm <- [0 .. sym - 1]
              ]

    it "arm k is still arm 0 rotated by 2*pi*k/sym, at every instant" $
      sequence_
        [ let sk = crisp sym kind 9 sp
              phi = 2 * pi * fromIntegral arm / fromIntegral sym
              base = map (spun sk t) (armIndices sk 0)
              other = map (spun sk t) (armIndices sk arm)
           in sequence_
                [ magV2 (a - b) `shouldSatisfy` (< 1e-5)
                | (a, b) <- zip (map (rotate phi) base) other
                ]
        | sym <- [2 .. 6]
        , kind <- allKindsOf sym
        , arm <- [1 .. sym - 1]
        , sp <- [staticSpin, SigilSpin 0.45 0.3 1.8, SigilSpin (-0.2) (-0.1) 0.5]
        , t <- [0, 0.7, 2.5, 6.5 :: Double]
        ]

    prop "the rotation preserves length, so |p| <= strokeRadius still holds" $
      forAll genStroke $ \sk ->
        forAll genCastTime $ \t ->
          conjoin
            [ let p = sampleStroke sk i
                  q = spun sk t i
               in counterexample (show (i, p, q, strokeRadius sk)) $
                    abs (magV2 q - magV2 p) <= 1e-5 * (1 + strokeRadius sk)
                      && magV2 q <= strokeRadius sk + 1e-5
            | i <- [0 .. skCount sk - 1]
            ]
