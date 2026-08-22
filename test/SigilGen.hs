-- | Generators shared by the func-spec 0016 specs: whole 'Circle' values
-- (every slot, phases and fields included — the digest is a fold over
-- /all/ of it) and 'SigilStroke' values.
--
-- Not a *Spec module, so hspec-discover leaves it alone; same role
-- 'ExprGen' plays for the formula specs.
module SigilGen
  ( genAnyCircle
  , genStroke
  , genStrokeOfKind
  , genSpin
  , allKindsOf
  ) where

import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..))
import Magic.Expr (Expr (..), ExprV3 (..), Var (..))
import Magic.Rune
  ( BillboardShape (..)
  , BridgeRune (..)
  , Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , ForceField (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Sigil (SigilSpin (..), SigilStroke (..), StrokeKind (..))
import Magic.Types (Seconds (..), V2 (..), V3 (..))
import Test.QuickCheck

genPositive :: Gen Double
genPositive = choose (0.05, 50)

genSigned :: Gen Double
genSigned = choose (-20, 20)

genShape :: Gen FaceShape
genShape =
  oneof
    [ HollowSquare <$> genPositive
    , Rect <$> (V2 <$> (realToFrac <$> genPositive) <*> (realToFrac <$> genPositive))
    , do
        rIn <- genPositive
        extra <- genPositive
        pure (Ring rIn (rIn + extra))
    , Diamond <$> genPositive
    ]

-- | Small formulas: the digest has to be sensitive to their leaves, and a
-- deep tree adds nothing the shallow one does not already witness.
--
-- Literals are non-negative, matching the surface grammar (a negative
-- constant is 'Neg' of a literal — 'Magic.Expr.Parse.renderExpr'\'s
-- roundtrip contract, same rule 'ExprGen' follows).
genExprSmall :: Gen Expr
genExprSmall =
  oneof
    [ Lit . realToFrac . abs <$> genSigned
    , Var <$> elements [VarT, VarLife, VarPIndex]
    , Chan <$> chooseInt (0, 7)
    , Neg . Lit . realToFrac . abs <$> genSigned
    ]

genOuter :: Gen OuterRune
genOuter =
  oneof
    [ ShapeRune <$> genShape
    , RadiateRune <$> elements [AlongNormal, RadialOutward]
    , RangeRune <$> genExprSmall
    , StyleRune <$> elements [minBound .. maxBound :: BillboardShape]
    ]

genBridge :: Gen BridgeRune
genBridge =
  oneof
    [ PhaseRune . Seconds <$> choose (0, 5)
    , ConvergeRune <$> genExprSmall
    , AmplifyRune <$> genExprSmall
    ]

genInner :: Gen InnerRune
genInner =
  oneof
    [ TrajectoryRune <$> genTrajectory
    , TimingRune <$> genEnvelope
    , FormulaRune <$> genExprV3
    ]

-- | The built-in trajectories only. @Formula@ is reachable through
-- 'FormulaRune' (which is how the codec spells it — a
-- @TrajectoryRune (Formula _)@ decodes back as @FormulaRune@, spec 0004
-- §4.3), so generating it here would only be testing that
-- normalization.
genTrajectory :: Gen Trajectory
genTrajectory =
  oneof
    [ Forward <$> genSigned
    , Spiral <$> genSigned <*> genPositive <*> genSigned
    , Orbit <$> genPositive <*> genSigned
    ]

genExprV3 :: Gen ExprV3
genExprV3 = ExprV3 <$> genExprSmall <*> genExprSmall <*> genExprSmall

genEnvelope :: Gen Envelope
genEnvelope =
  Envelope
    <$> (Seconds <$> choose (0, 5))
    <*> (Seconds <$> choose (0, 10))
    <*> (Seconds <$> genPositive)

-- | Codec-valid fields only (softening > 0, falloff >= 0): the digest
-- properties are quantified over circles that survive a save/load
-- roundtrip, so a field the codec would reject is out of scope.
genField :: Gen ForceField
genField =
  oneof
    [ Gravity <$> genV3
    , PointAttractor <$> genV3 <*> genF <*> genPos
    , Vortex <$> genV3 <*> genV3 <*> genF <*> genNonNeg
    ]
  where
    genV3 = V3 <$> genF <*> genF <*> genF
    genF = realToFrac <$> genSigned
    genPos = realToFrac <$> choose (0.05 :: Double, 20)
    genNonNeg = realToFrac <$> choose (0 :: Double, 20)

genMaybe :: Gen a -> Gen (Maybe a)
genMaybe g = oneof [pure Nothing, Just <$> g]

-- | Every slot of the ADT is reachable, phases and fields included.
--
-- Activation points are deliberately left at 'Nothing': the sigil is
-- drawn once however many places the spell fires from (func-spec 0025
-- §2.6), so they are not part of what a sigil generator varies. The
-- sigil's time axis is left at 'Nothing' for the opposite reason
-- (func-spec 0026): every consumer of this generator asserts a law about
-- the /geometry/, and a generated @linger@ or @hold@ would vary the
-- timing underneath them without varying anything they measure. The
-- volumetric stack (magic-semantics F002) is left at 'Nothing' too, for
-- the same reason as the timing axis: it varies how many copies of the
-- geometry exist, not the geometry itself.
genAnyCircle :: Gen Circle
genAnyCircle =
  Circle
    <$> (TwoOf <$> genMaybe genOuter <*> genMaybe genOuter)
    <*> genMaybe genBridge
    <*> (TwoOf <$> genMaybe genInner <*> genMaybe genInner)
    <*> (Core <$> genMaybe (EssenceRune <$> elements [Neutral, Fire, Water, Lightning] <*> choose (0.05, 10)) <*> genNodes)
    <*> genMaybe (PhaseConfig <$> (Seconds <$> choose (0.1, 3)) <*> (Seconds <$> choose (0, 2)))
    <*> (resize 3 (listOf genField))
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
  where
    genNodes =
      Nodes
        <$> genMaybe (DirBias <$> genSigned)
        <*> genMaybe (DirBias <$> genSigned)
        <*> genMaybe (DirBias <$> genSigned)
        <*> genMaybe (DirBias <$> genSigned)

-- Strokes ---------------------------------------------------------------------

-- | One representative of each of the six kinds, at the given symmetry
-- order — the property suites walk this list so no kind can be forgotten.
allKindsOf :: Int -> [StrokeKind]
allKindsOf sym =
  [ ArcRing 0.75
  , Polygram sym 2
  , Spokes 0.3
  , Ticks 0.12
  , Rose 3
  , GlyphBand 0x0A5B
  ]

-- | A stroke whose particle count is a multiple of its symmetry (which is
-- what 'Magic.Sigil.sigilPlan' always produces), so every arm gets the
-- same number of steps.
genStroke :: Gen SigilStroke
genStroke = do
  sym <- chooseInt (1, 9)
  kind <- elements (allKindsOf sym)
  genStrokeOfKind sym kind

genStrokeOfKind :: Int -> StrokeKind -> Gen SigilStroke
genStrokeOfKind sym kind = do
  radius <- realToFrac <$> choose (0.2 :: Double, 2.0)
  phase <- realToFrac <$> choose (0 :: Double, 6.28)
  jitter <- elements [0, 0.015, 0.05]
  steps <- chooseInt (4, 40)
  spin <- genSpin
  pure
    SigilStroke
      { skKind = kind
      , skRadius = radius
      , skSymmetry = sym
      , skPhase = phase
      , skJitter = jitter
      , skCount = steps * sym
      , skSpin = spin
      }

-- | Angular motion, generated the way 'Magic.Sigil.sigilPlan' produces it
-- (func-spec 0020 §3.2): the acceleration carries the rate's sign, the
-- charge-up ends at a non-negative landmark, and a standing-still stroke
-- is always in the sample.
genSpin :: Gen SigilSpin
genSpin = do
  sgn <- elements [-1, 1 :: Float]
  rate <- realToFrac <$> choose (0.05 :: Double, 0.45)
  accel <- realToFrac <$> choose (0 :: Double, 0.30)
  ramp <- realToFrac <$> choose (0 :: Double, 2.4)
  frequency
    [ (1, pure (SigilSpin 0 0 ramp))
    , (6, pure (SigilSpin (sgn * rate) (sgn * accel) ramp))
    ]
