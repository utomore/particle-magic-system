-- | The sigil layer (func-spec 0016): a circle's formation geometry,
-- derived from the circle itself.
--
-- Two things live here, and the second is built out of the first:
--
-- * 'hashCircle' — a structural digest of the whole 'Circle' ADT, every
--   leaf included (floats enter by their /bits/, never by a decimal
--   approximation, so the same spell file digests identically on every
--   platform). Frozen once delivered: the digest picks a spell's looks,
--   so changing the function silently redraws every existing spell
--   (ADR-0014, architecture §11's hard-point table).
--
-- * 'sigilPlan' — the strokes the circle is drawn with. Structure sets
--   the skeleton (which layers exist, at which radii, roughly how
--   symmetric), the digest sets the ornament (which stroke each layer is
--   drawn with, its phase, its parameters). So "five rings because five
--   slots are filled" stays readable while every spell still gets its
--   own figure.
--
-- Func-spec 0020 adds a third, smaller thing on top of the second:
-- 'SigilSpin', the angular motion a stroke carries. It is a rotation
-- /about the face origin/ applied after 'sampleStroke', which is what
-- keeps it orthogonal to everything else here — the six closed forms are
-- untouched, and because a rotation preserves length, 'strokeRadius' and
-- every bound built on it (@Magic.Compile.emitterBounds@, spec 0010's
-- culling) are untouched too.
--
-- Strokes are /curves walked at a constant pace/, not clouds: index @i@
-- maps to a point that advances monotonically along the curve
-- ('strokeParam'). Combined with the frozen spawn schedule
-- (@firstBirth env n i = envDelay + (i\/n)·envLifetime@, spec 0002 §4.2),
-- that means the sigil is /drawn/ rather than fading in — with no new
-- scheduling machinery at all. Symmetric arms are the index's other
-- projection (@arm = i `mod` sym@, @j = i `div` sym@), so @n@ arms are
-- drawn at once, each advancing along its own copy of the curve.
--
-- Zero IO, zero dependencies beyond the core whitelist (ADR-0007,
-- func-spec 0001): the float-to-bits casts are @base@'s.
module Magic.Sigil
  ( -- * Structural digest (frozen once delivered — ADR-0014)
    hashCircle

    -- * The plan
  , SigilPlan (..)
  , SigilStroke (..)
  , StrokeKind (..)
  , sigilPlan
  , sigilBudget

    -- * Angular motion (func-spec 0020 — frozen once delivered)
  , SigilSpin (..)
  , spinAngle
  , staticSpin

    -- * Closed-form stroke sampling
  , sampleStroke
  , strokeParam
  , strokeRadius
  ) where

import Data.Bits (popCount, shiftL, shiftR, testBit, xor, (.&.))
import qualified Data.Vector as V
import Data.Word (Word16, Word64)
import GHC.Float (castDoubleToWord64, castFloatToWord32)
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), TwoOf (..))
import Magic.Expr (Expr (..), ExprV3 (..))
import Magic.Rune
  ( BillboardShape
  , BridgeRune (..)
  , Element
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..), Seed (..), V2 (..), hashChan)

-- The digest -----------------------------------------------------------------

-- | Structural digest of a whole 'Circle': deterministic, sensitive to
-- every leaf of the ADT (down to an 'Expr'\'s literals), and stable
-- across a @saveCircle@ \/ @loadCircle@ roundtrip.
--
-- Frozen the moment func-spec 0016 delivers (ADR-0014, "the digest is a
-- contract"): players identify a spell by the figure it draws, so a
-- different digest function is a silent visual break of every spell in
-- existence — the same severity as changing 'Magic.Expr' semantics.
--
-- Floats and doubles enter through 'castFloatToWord32' \/
-- 'castDoubleToWord64', never through a decimal rendering: the digest of
-- a spell file must not depend on how a platform prints @0.1@.
hashCircle :: Circle -> Word64
hashCircle c = hcCircle digestSeed c

-- | Arbitrary non-zero start value ("Sigil001" in ASCII). Pinned forever.
digestSeed :: Word64
digestSeed = 0x5369_6769_6C30_3031

-- | The project's one hash arithmetic: splitmix64's mixing shape with the
-- exact constants 'Magic.Types.hashChan' uses (architecture §4.3). Not
-- commutative, so field order is part of the structure being digested.
mixW :: Word64 -> Word64 -> Word64
mixW h w =
  let z0 = h + w * 0x9E37_79B9_7F4A_7C15
      z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xBF58_476D_1CE4_E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D0_49BB_1331_11EB
   in z2 `xor` (z2 `shiftR` 31)
{-# INLINE mixW #-}

-- | Mix in a constructor\/position tag.
tagW :: Word64 -> Int -> Word64
tagW h n = mixW h (fromIntegral n)
{-# INLINE tagW #-}

hcFloat :: Word64 -> Float -> Word64
hcFloat h x = mixW h (fromIntegral (castFloatToWord32 x))

hcDouble :: Word64 -> Double -> Word64
hcDouble h x = mixW h (castDoubleToWord64 x)

hcSeconds :: Word64 -> Seconds -> Word64
hcSeconds h (Seconds s) = hcDouble h s

hcEnum :: (Enum a) => Word64 -> a -> Word64
hcEnum h a = tagW h (fromEnum a)

hcMaybe :: (Word64 -> a -> Word64) -> Word64 -> Maybe a -> Word64
hcMaybe _ h Nothing = tagW h 0
hcMaybe f h (Just a) = f (tagW h 1) a

hcTwoOf :: (Word64 -> a -> Word64) -> Word64 -> TwoOf (Maybe a) -> Word64
hcTwoOf f h (TwoOf a b) = hcMaybe f (tagW (hcMaybe f h a) 0x5A) b

-- | The digest covers what the circle /means/ — its slots, its runes,
-- its lifecycle staging — and deliberately not 'circleFields'.
--
-- A force field is the circle's physical environment, neither a slot's
-- meaning nor a modulation of one (ADR-0010 D4), and spec 0007 delivered
-- the law that fields change nothing else the interpreter produces. Since
-- the digest picks the drawn figure, folding fields into it would mean
-- hanging a gravity well on a spell silently redraws its sigil — a
-- visible break of that law. So fields ride alongside here exactly as
-- they do through 'Magic.Compile.compile': carried, never folded.
hcCircle :: Word64 -> Circle -> Word64
hcCircle h0 c = h5
  where
    h1 = hcTwoOf hcOuterRune (tagW h0 1) (outerRings c)
    h2 = hcMaybe hcBridgeRune (tagW h1 2) (interLayer c)
    h3 = hcTwoOf hcInnerRune (tagW h2 3) (innerRings c)
    h4 = hcCore (tagW h3 4) (core c)
    h5 = hcMaybe hcPhaseConfig (tagW h4 5) (circlePhases c)

hcOuterRune :: Word64 -> OuterRune -> Word64
hcOuterRune h rune = case rune of
  ShapeRune s -> hcFaceShape (tagW h 0) s
  RadiateRune m -> hcRadiation (tagW h 1) m
  RangeRune e -> hcExpr (tagW h 2) e
  StyleRune s -> hcBillboard (tagW h 3) s

-- | Constructor tags are append-only, exactly like the constructors they
-- stand for (func-spec 0021 §2.4): a tag reused or renumbered would
-- silently redraw every already-written spell that uses the shape, which
-- is the ADR-0014 hazard this whole module is built around. Func-spec
-- 0021's four shapes take tags 4–7 and leave 0–3 where they were.
hcFaceShape :: Word64 -> FaceShape -> Word64
hcFaceShape h shape = case shape of
  HollowSquare size -> hcDouble (tagW h 0) size
  Rect (V2 w hgt) -> hcFloat (hcFloat (tagW h 1) w) hgt
  Ring rIn rOut -> hcDouble (hcDouble (tagW h 2) rIn) rOut
  Diamond size -> hcDouble (tagW h 3) size
  Polygon sides radius -> hcDouble (tagW (tagW h 4) sides) radius
  Star points rOut rIn -> hcDouble (hcDouble (tagW (tagW h 5) points) rOut) rIn
  Cross len width -> hcDouble (hcDouble (tagW h 6) len) width
  Sector rIn rOut sweep -> hcDouble (hcDouble (hcDouble (tagW h 7) rIn) rOut) sweep

hcRadiation :: Word64 -> RadiationMode -> Word64
hcRadiation h m = tagW h $ case m of
  AlongNormal -> 0
  RadialOutward -> 1
  RadialInward -> 2
  TangentialSwirl -> 3

hcBillboard :: Word64 -> BillboardShape -> Word64
hcBillboard = hcEnum

hcBridgeRune :: Word64 -> BridgeRune -> Word64
hcBridgeRune h rune = case rune of
  PhaseRune s -> hcSeconds (tagW h 0) s
  ConvergeRune e -> hcExpr (tagW h 1) e
  AmplifyRune e -> hcExpr (tagW h 2) e

hcInnerRune :: Word64 -> InnerRune -> Word64
hcInnerRune h rune = case rune of
  TrajectoryRune t -> hcTrajectory (tagW h 0) t
  TimingRune e -> hcEnvelope (tagW h 1) e
  FormulaRune v -> hcExprV3 (tagW h 2) v

hcTrajectory :: Word64 -> Trajectory -> Word64
hcTrajectory h t = case t of
  Forward speed -> hcDouble (tagW h 0) speed
  Spiral speed radius freq -> hcDouble (hcDouble (hcDouble (tagW h 1) speed) radius) freq
  Orbit radius freq -> hcDouble (hcDouble (tagW h 2) radius) freq
  Formula v -> hcExprV3 (tagW h 3) v
  Wave speed amp freq -> hcDouble (hcDouble (hcDouble (tagW h 4) speed) amp) freq
  Ballistic speed gravity -> hcDouble (hcDouble (tagW h 5) speed) gravity
  Pulse speed freq -> hcDouble (hcDouble (tagW h 6) speed) freq
  Zigzag speed amp freq -> hcDouble (hcDouble (hcDouble (tagW h 7) speed) amp) freq

hcEnvelope :: Word64 -> Envelope -> Word64
hcEnvelope h (Envelope d dur life) = hcSeconds (hcSeconds (hcSeconds h d) dur) life

hcCore :: Word64 -> Core -> Word64
hcCore h (Core center nodes) =
  hcNodes (hcMaybe hcEssence (tagW h 0) center) nodes

hcEssence :: Word64 -> EssenceRune -> Word64
hcEssence h (EssenceRune el power) = hcDouble (hcElement h el) power

hcElement :: Word64 -> Element -> Word64
hcElement = hcEnum

hcNodes :: Word64 -> Nodes (Maybe NodeRune) -> Word64
hcNodes h (Nodes n s e w) =
  foldl' (hcMaybe hcNodeRune) (tagW h 7) [n, s, e, w]

hcNodeRune :: Word64 -> NodeRune -> Word64
hcNodeRune h (DirBias bias) = hcDouble h bias

hcPhaseConfig :: Word64 -> PhaseConfig -> Word64
hcPhaseConfig h (PhaseConfig d c) = hcSeconds (hcSeconds h d) c

hcExprV3 :: Word64 -> ExprV3 -> Word64
hcExprV3 h (ExprV3 x y z) = hcExpr (hcExpr (hcExpr h x) y) z

-- | Structural fold over the formula AST: shape /and/ leaves, so two
-- different formulas cannot share a digest by accident.
hcExpr :: Word64 -> Expr -> Word64
hcExpr h e = case e of
  Lit x -> hcFloat (tagW h 0) x
  Var v -> hcEnum (tagW h 1) v
  Chan n -> tagW (tagW h 2) n
  Neg a -> hcExpr (tagW h 3) a
  Bin op a b -> hcExpr (hcExpr (hcEnum (tagW h 4) op) a) b
  Fun1 f a -> hcExpr (hcEnum (tagW h 5) f) a
  Fun2 f a b -> hcExpr (hcExpr (hcEnum (tagW h 6) f) a) b
  Fun3 f a b c -> hcExpr (hcExpr (hcExpr (hcEnum (tagW h 7) f) a) b) c

-- The plan --------------------------------------------------------------------

-- | What a circle is drawn with. A compile-time intermediate value:
-- 'Magic.Compile.compile' turns it into emitters and drops it — nothing
-- of 'SigilPlan' reaches @CompiledSpell@ except the individual
-- 'SigilStroke's riding inside their spawn patterns.
data SigilPlan = SigilPlan
  { spSymmetry :: !Int
  -- ^ The whole sigil's symmetry order, 3..9.
  , spStrokes :: !(V.Vector SigilStroke)
  -- ^ Every stroke, in draw order: the boundary group first, then the
  -- occupied ring layers outside in.
  , spShapes :: !(V.Vector (FaceShape, Int))
  -- ^ The func-spec 0006 §4.4 exception, preserved: an outer-ring slot
  -- holding a 'ShapeRune' previews the player's own drawn shape instead
  -- of being given a stroke. @(shape, particle count)@.
  }
  deriving (Eq, Show)

-- | One stroke of the sigil: a curve, how many times it repeats around
-- the circle, and how densely it is walked.
data SigilStroke = SigilStroke
  { skKind :: !StrokeKind
  , skRadius :: !Float
  -- ^ Base radius in face coordinates.
  , skSymmetry :: !Int
  -- ^ Repeated arms (1 = drawn once).
  , skPhase :: !Float
  -- ^ Starting angle, radians.
  , skJitter :: !Float
  -- ^ Normal-direction wobble. Not noise — it is what keeps a drawn line
  -- from looking like printed vector art. @0@ makes sampling bit-for-bit
  -- reproducible with no hash channel consulted at all.
  , skCount :: !Int
  -- ^ Particle count; the unit the budget is settled in. Always a
  -- multiple of 'skSymmetry' as produced by 'sigilPlan', so every arm
  -- gets the same number of points and the curve parameter closes at 1.
  , skSpin :: !SigilSpin
  -- ^ How the stroke turns about the face origin (func-spec 0020). The
  -- starting angle is /not/ here: it lives in 'skPhase', which already
  -- means exactly that (§2.4), and keeping it there is what makes
  -- @spinAngle sp 0 == 0@ — the sigil at @t = 0@ is bit-for-bit the
  -- figure 0016 drew.
  }
  deriving (Eq, Show)

-- | One stroke's angular motion, all of it relative to the face-plane
-- origin (func-spec 0020 §3.1). Frozen once 0020 delivers.
--
-- Two coefficients and a landmark, in that order: a base angular speed, a
-- charge-up angular acceleration, and the moment the charge-up stops.
-- 'ssRampEnd' is @castStart@, baked in at compile time — the same trick
-- spec 0006 used for the phase staging and 0017 for @ppEnd@: /a phase
-- landmark crosses into the sampler as data, never as a query/. The
-- sampler still knows nothing about phases.
data SigilSpin = SigilSpin
  { ssRate :: !Float
  -- ^ Base angular speed, rad\/s. Negative = the other way round.
  , ssAccel :: !Float
  -- ^ Angular acceleration during the charge-up, rad\/s². Same sign as
  -- 'ssRate' as produced by 'sigilPlan' (a stroke speeds up, it never
  -- turns around mid-cast).
  , ssRampEnd :: !Float
  -- ^ End of the charge-up, in seconds since the cast started
  -- (= @castStart@). Past it the angular speed is held constant, which
  -- is what keeps @|ω|@ bounded no matter how long the spell runs.
  }
  deriving (Eq, Show)

-- | A stroke that does not turn. @spinAngle staticSpin ≡ 0@.
staticSpin :: SigilSpin
staticSpin = SigilSpin {ssRate = 0, ssAccel = 0, ssRampEnd = 0}

-- | Seconds since the cast started → the angle the stroke has turned
-- through (func-spec 0020 §2.3).
--
-- Piecewise: quadratic while the sigil is charging, linear once it has
-- fired.
--
-- > t <= r:  rate·t + ½·accel·t²
-- > t >  r:  rate·r + ½·accel·r² + (rate + accel·r)·(t − r)
--
-- The two branches agree in value /and/ in derivative at @t = r@, so the
-- angular speed is continuous (C¹) and never jumps. It is also
-- /bounded/: @|ω(t)| <= |rate| + |accel|·r@ for every @t@, independent
-- of how long the spell lasts. That bound is the whole reason the
-- function is piecewise rather than a plain quadratic — a sigil now
-- lives for the entire cast (ADR-0015 D1), and a constant angular
-- acceleration over 8 seconds turns it into a blurred disc.
--
-- Total: negative times (which only a test ever asks for) clamp to 0, so
-- the bound holds on the whole real line and @spinAngle sp 0 == 0@ is
-- also the value at every @t <= 0@.
spinAngle :: SigilSpin -> Double -> Float
spinAngle sp tCast
  | t <= r = rate * t + 0.5 * accel * t * t
  | otherwise = rate * r + 0.5 * accel * r * r + (rate + accel * r) * (t - r)
  where
    t = max 0 (realToFrac tCast) :: Float
    r = max 0 (ssRampEnd sp)
    rate = ssRate sp
    accel = ssAccel sp
{-# INLINE spinAngle #-}

-- | The stroke vocabulary. Each kind is a closed-form @(arm, s) -> point@
-- with no allocation and no state; @s@ always advances monotonically with
-- the index, which is what makes the sigil draw itself.
data StrokeKind
  = -- | Arc of a ring: sweep as a fraction of a full turn (1 = closed).
    ArcRing !Float
  | -- | Star polygon @{n\/k}@: @n@ vertices, stepping @k@ each time. A
    -- @k@ sharing a factor with @n@ (or 0) falls back to 1, so the traced
    -- vertex set is always the full regular @n@-gon.
    Polygram !Int !Int
  | -- | Radial spoke of the given length, ending at 'skRadius'.
    Spokes !Float
  | -- | Short tangential tick on the ring, centered on the arm angle.
    Ticks !Float
  | -- | Rose curve @r = skRadius·|cos(k·θ)|@.
    Rose !Int
  | -- | A glyph on the 3×3 lattice: the low 12 bits pick from the 12
    -- candidate segments (3 rows × 2 + 3 columns × 2). These glyphs mean
    -- nothing — they are ornament, not a writing system (func-spec 0016
    -- §8-1).
    GlyphBand !Word16
  deriving (Eq, Show)

-- | Particle budget of one sigil plan (strokes + shape previews). The
-- node and center emitters keep func-spec 0006's structural constants and
-- are counted outside this cap (at most 64 particles all told).
sigilBudget :: Int
sigilBudget = 1536

-- | Normal-direction wobble every stroke gets by default.
defaultJitter :: Float
defaultJitter = 0.015

-- | Particle count of a 'ShapeRune' preview — func-spec 0006's ring-slot
-- constant, unchanged.
shapePreviewCount :: Int
shapePreviewCount = 64

tau :: Float
tau = 2 * pi

-- | @bitsAt w off n@: the @n@ bits of @w@ starting at @off@, as an 'Int'.
--
-- == The digest's bit allocation
--
-- Every direct @bitsAt@ read in this module, so a later round can pick
-- free bits instead of quietly restyling every spell in existence
-- (func-spec 0020 §3.2 — this table is the thing that stops a fourth
-- round from colliding).
--
-- From the top-level digest @d = hashCircle circle@:
--
-- > bits  0.. 1   0016  symmetry order, ±1 around the structural center
-- > bits 40..47   0016  the boundary tick group's starting phase
--
-- From a layer's own word @dl = mixW d layerIndex@:
--
-- > bits  3.. 5   0016  which of the six stroke kinds
-- > bits  8..17   0016  starting phase (skPhase)
-- > bits 18..26   0016  ArcRing sweep
-- > bits 21..23   0016  Polygram step k        (kind-exclusive with the above)
-- > bits 24..27   0016  Spokes length          (kind-exclusive)
-- > bits 28..31   0016  Ticks length           (kind-exclusive)
-- > bits 32..33   0016  Rose petal count       (kind-exclusive)
-- > bits 34..40   0020  |ssRate|   — angular speed
-- > bits 41..47   0020  |ssAccel|  — charge-up angular acceleration
-- > bits 48..59   0016  GlyphBand mask
-- > bits  0.. 2   free
-- > bits  6.. 7   free
-- > bits 60..63   free
--
-- 0020 reads no new bits of @d@ itself: the boundary group's spin is
-- fixed by the structure (outermost ⇒ positive, slowest of the band), and
-- so is every stroke's /direction/ (layer parity). Only the two
-- magnitudes come from the digest.
bitsAt :: Word64 -> Int -> Int -> Int
bitsAt w off n = fromIntegral ((w `shiftR` off) .&. ((1 `shiftL` n) - 1))

clampI :: Int -> Int -> Int -> Int
clampI lo hi = max lo . min hi

-- | What occupies a ring layer.
data Occupant
  = Vacant
  | Filled
  | -- | Outer-ring 'ShapeRune': preview the player's shape (0006 §4.4).
    Drawn !FaceShape

-- | Circle → the strokes that draw it (func-spec 0016 §3's derivation
-- table).
--
-- Skeleton from the structure: the boundary group is unconditional ("a
-- sigil always has a silhouette", inherited from 0006), each occupied
-- ring slot adds a layer at its own radius band, and the symmetry order
-- is centered on how many slots are filled. Ornament from the digest:
-- which stroke each layer is drawn with, its phase and its parameters.
--
-- Total 'skCount' never exceeds 'sigilBudget': over budget, every stroke
-- is scaled down proportionally (order-preserving, deterministic) and
-- strokes that round to nothing are dropped — the bound holds by
-- construction rather than by luck.
sigilPlan :: Circle -> SigilPlan
sigilPlan circle =
  SigilPlan
    { spSymmetry = sym
    , spStrokes = V.fromList clipped
    , spShapes = V.fromList shapes
    }
  where
    d = hashCircle circle

    occupancy :: [Occupant]
    occupancy =
      [ outerOccupant (ringB (outerRings circle))
      , outerOccupant (ringA (outerRings circle))
      , plainOccupant (interLayer circle)
      , plainOccupant (ringB (innerRings circle))
      , plainOccupant (ringA (innerRings circle))
      ]

    outerOccupant slot = case slot of
      Nothing -> Vacant
      Just (ShapeRune s) -> Drawn s
      Just _ -> Filled

    plainOccupant slot = case slot of
      Nothing -> Vacant
      Just _ -> Filled

    occCount = length [() | o <- occupancy, notVacant o]
    notVacant Vacant = False
    notVacant _ = True

    -- Structure sets the center, the digest picks within ±1 of it.
    symCenter = clampI 3 9 (3 + occCount)
    sym = clampI 3 9 (symCenter + bitsAt d 0 2 `mod` 3 - 1)

    radii :: [Float]
    radii = [1.30, 1.15, 1.00, 0.85, 0.70]

    layers = zip3 [1 :: Int ..] radii occupancy

    shapes = [(s, shapePreviewCount) | (_, _, Drawn s) <- layers]

    -- The charge-up landmark, read straight off the structure: it is
    -- castStart = phDraw + phConverge (spec 0006 §4.3). Without 'phases'
    -- there are no formation emitters at all, so the value is unobservable
    -- and 0 is as good as anything.
    ramp = case circlePhases circle of
      Nothing -> 0
      Just (PhaseConfig (Seconds drawS) (Seconds convergeS)) ->
        max 0 (realToFrac (drawS + convergeS))

    -- The occupied layers, outside in. The ordinal (1, 2, 3, ...) is
    -- their position in /draw order/, which is what sets the turn
    -- direction: counter-rotation has to be visible between neighbouring
    -- drawn rings, and a vacant slot in the middle must not silently make
    -- two of them turn the same way (func-spec 0020 §3.2, 實作備註-3).
    -- The layer's own index still picks the digest word, so the geometry
    -- 0016 derives is untouched.
    occupied = [(idx, r) | (idx, r, Filled) <- layers]

    raw =
      boundaryGroup sym d ramp
        ++ [layerStroke sym d ramp ord idx r | (ord, (idx, r)) <- zip [1 :: Int ..] occupied]

    total = sum (map skCount raw) + sum (map snd shapes)

    clipped
      | total <= sigilBudget = raw
      | otherwise = [sk | sk <- map shrink raw, skCount sk > 0]
      where
        room = max 0 (sigilBudget - sum (map snd shapes))
        shrink sk =
          let armCount = (skCount sk * room) `div` max 1 total
              armsOf = max 1 (skSymmetry sk)
           in sk {skCount = (armCount `div` armsOf) * armsOf}

-- | The silhouette: a closed ring plus its tick marks. Present on every
-- circle, including the all-empty one — the one stroke group the
-- structure grants unconditionally, and the reason a slot maps to a
-- /group/ of strokes rather than to exactly one.
-- The silhouette is layer index 0, which is what gives it the positive
-- turn direction func-spec 0020 §3.2 asks for and makes the whole draw
-- order alternate: the frame turns one way, the first ring the other.
boundaryGroup :: Int -> Word64 -> Float -> [SigilStroke]
boundaryGroup sym d ramp =
  [ SigilStroke
      { skKind = ArcRing 1
      , skRadius = 1.5
      , skSymmetry = 1
      , skPhase = 0
      , skJitter = defaultJitter
      , skCount = 192
      , skSpin = boundarySpin ramp
      }
  , SigilStroke
      { skKind = Ticks 0.09
      , skRadius = 1.4
      , skSymmetry = sym
      , skPhase = tau * fromIntegral (bitsAt d 40 8) / 256
      , skJitter = defaultJitter
      , skCount = 10 * sym
      , skSpin = boundarySpin ramp
      }
  ]

-- | One occupied ring layer: radius from the structure, everything else
-- from the layer's own slice of the digest.
layerStroke :: Int -> Word64 -> Float -> Int -> Int -> Float -> SigilStroke
layerStroke sym d ramp ord idx radius =
  SigilStroke
    { skKind = kind
    , skRadius = radius
    , skSymmetry = arms
    , skPhase = tau * fromIntegral (bitsAt dl 8 10) / 1024
    , skJitter = defaultJitter
    , skCount = perArm * arms
    , skSpin = layerSpin dl ord ramp
    }
  where
    dl = mixW d (fromIntegral idx)
    kind = case bitsAt dl 3 3 `mod` 6 of
      0 -> ArcRing (0.55 + fromIntegral (bitsAt dl 18 9) / 1137)
      1 -> Polygram sym (2 + bitsAt dl 21 3 `mod` max 1 (sym - 2))
      2 -> Spokes (0.10 + fromIntegral (bitsAt dl 24 4) / 120)
      3 -> Ticks (0.07 + fromIntegral (bitsAt dl 28 4) / 200)
      4 -> Rose (2 + bitsAt dl 32 2)
      _ -> GlyphBand (fromIntegral (bitsAt dl 48 12))
    arms = case kind of
      ArcRing sweep -> if sweep >= 0.999 then 1 else sym
      Polygram _ _ -> 1
      Spokes _ -> sym
      Ticks _ -> 2 * sym
      Rose _ -> 1
      GlyphBand _ -> sym
    perArm = case kind of
      ArcRing _ -> 32
      Polygram n _ -> 20 * max 3 n
      Spokes _ -> 10
      Ticks _ -> 8
      Rose _ -> 168
      GlyphBand _ -> 24

-- Angular motion (func-spec 0020 §3.2) ----------------------------------------

-- | The angular-speed band, rad\/s: one turn per 125 s at the bottom, one
-- per 14 s at the top. Slow enough not to read as spinning-for-the-sake-
-- of-it, fast enough that a viewer can tell it is moving.
spinRateMin, spinRateMax :: Float
spinRateMin = 0.05
spinRateMax = 0.45

-- | Ceiling on the charge-up acceleration, rad\/s². With the shipped
-- sigils' @castStart <= 2.4 s@ this caps the held speed at
-- @0.45 + 0.30·2.4 = 1.17 rad\/s@ — about 5.4 s a turn, still a figure
-- rather than a blur.
spinAccelMax :: Float
spinAccelMax = 0.30

-- | Which way the @n@-th stroke group in draw order turns: the skeleton
-- decides, so /adjacent rings counter-rotate/ reads as a rule rather than
-- as noise. Ordinal 0 is the silhouette, and it turns positively (§3.2).
spinSign :: Int -> Float
spinSign ord = if even ord then 1 else -1

-- | The silhouette's motion: outermost, positive, at the bottom of the
-- band and with no charge-up — the frame turns slowly while the works
-- inside it speed up.
boundarySpin :: Float -> SigilSpin
boundarySpin ramp =
  SigilSpin {ssRate = spinRateMin, ssAccel = 0, ssRampEnd = ramp}

-- | A ring layer's motion. Direction from the structure (its ordinal in
-- draw order), both magnitudes from the layer's own digest word
-- (bits 34..47 — see 'bitsAt').
layerSpin :: Word64 -> Int -> Float -> SigilSpin
layerSpin dl ord ramp =
  SigilSpin
    { ssRate = sgn * (spinRateMin + (spinRateMax - spinRateMin) * unit (bitsAt dl 34 7))
    , ssAccel = sgn * (spinAccelMax * unit (bitsAt dl 41 7))
    , ssRampEnd = ramp
    }
  where
    sgn = spinSign ord
    unit n = fromIntegral n / 127

-- Sampling ---------------------------------------------------------------------

-- | Fixed internal seed for the jitter channel: the wobble is a property
-- of the drawn figure, not of the cast (same reasoning as
-- 'Magic.Particle.Analytic.sampleShape'\'s shape seed).
sigilSeed :: Seed
sigilSeed = Seed 0x5369_6769_6C4A_5452

-- | Arms of a stroke (at least one).
strokeArms :: SigilStroke -> Int
strokeArms sk = max 1 (skSymmetry sk)
{-# INLINE strokeArms #-}

-- | Points along a single arm.
strokeSteps :: SigilStroke -> Int
strokeSteps sk = max 1 (skCount sk `div` strokeArms sk)
{-# INLINE strokeSteps #-}

-- | The curve parameter particle @i@ sits at, in @[0, 1]@.
--
-- This is the "index order is draw order" law made observable: on a fixed
-- arm it is strictly increasing in @i \`div\` symmetry@, so the frozen
-- birth schedule of spec 0002 walks the curve from one end to the other.
strokeParam :: SigilStroke -> Int -> Float
strokeParam sk i = min 1 (max 0 (fromIntegral j / fromIntegral (max 1 (m - 1))))
  where
    j = i `div` strokeArms sk
    m = strokeSteps sk
{-# INLINE strokeParam #-}

-- | @sampleStroke stroke i@: where particle @i@ of the stroke sits, in
-- face coordinates. O(1), allocation-free, total for every index.
sampleStroke :: SigilStroke -> Int -> V2
sampleStroke sk i
  | jitter == 0 = p
  | otherwise = p + scaleV2 (jitter * (hashChan sigilSeed i 0 - 0.5)) nrm
  where
    (p, nrm) = strokeCurve sk i
    jitter = skJitter sk

-- | The un-jittered curve point and the unit normal the jitter rides on.
strokeCurve :: SigilStroke -> Int -> (V2, V2)
strokeCurve sk i = case skKind sk of
  ArcRing sweep ->
    let th = base + tau * sweep * s
        dir = unitAt th
     in (scaleV2 r dir, dir)
  Polygram n0 k0 ->
    let n = max 3 n0
        k1 = abs k0 `mod` n
        k = if k1 == 0 || gcd n k1 /= 1 then 1 else k1
        u = s * fromIntegral n
        q = min (n - 1) (floor u) :: Int
        f = u - fromIntegral q
        vertex t = unitAt (base + tau * fromIntegral t / fromIntegral n)
        a = vertex ((q * k) `mod` n)
        b = vertex (((q + 1) * k) `mod` n)
        p = scaleV2 r (a + scaleV2 f (b - a))
     in (p, normalizeV2 p)
  Spokes len ->
    let l = abs len
        rad = r - l + l * s
        dir = unitAt base
     in (scaleV2 rad dir, perpOf dir)
  Ticks len ->
    let dir = unitAt base
        p = scaleV2 r dir + scaleV2 (abs len * (s - 0.5)) (perpOf dir)
     in (p, dir)
  Rose k0 ->
    let k = max 1 (abs k0)
        ang = tau * s
        dir = unitAt (base + ang)
        rad = r * abs (cos (fromIntegral k * ang))
     in (scaleV2 rad dir, dir)
  GlyphBand mask0 ->
    let mask = let low = mask0 .&. 0x0FFF in if low == 0 then 1 else low
        segs = [b | b <- [0 .. 11], testBit mask b]
        cnt = max 1 (popCount mask)
        segIdx = segs !! (j `mod` cnt)
        stepsPer = max 1 (strokeSteps sk `div` cnt)
        u = min 1 (fromIntegral (j `div` cnt) / fromIntegral (max 1 (stepsPer - 1)))
        (ga, gb) = glyphSegment segIdx
        V2 lx ly = ga + scaleV2 u (gb - ga)
        h = glyphHalf * r
        dir = unitAt base
        p = scaleV2 r dir + scaleV2 (h * lx) (perpOf dir) + scaleV2 (h * ly) dir
     in (p, dir)
  where
    arms = strokeArms sk
    arm = i `mod` arms
    j = i `div` arms
    s = strokeParam sk i
    r = skRadius sk
    base = skPhase sk + tau * fromIntegral arm / fromIntegral arms

-- | Half-extent of a glyph, as a fraction of the stroke radius.
glyphHalf :: Float
glyphHalf = 0.22

-- | The 12 candidate segments of the 3×3 lattice, in bit order: the six
-- horizontal halves (row by row, left half then right), then the six
-- vertical ones (column by column, bottom half then top). Coordinates are
-- the lattice's own, spanning @[-1, 1]@ on both axes.
glyphSegment :: Int -> (V2, V2)
glyphSegment idx
  | idx < 6 =
      let row = fromIntegral (idx `div` 2) - 1
          left = fromIntegral (idx `mod` 2) - 1
       in (V2 left row, V2 (left + 1) row)
  | otherwise =
      let k = idx - 6
          col = fromIntegral (k `div` 2) - 1
          bottom = fromIntegral (k `mod` 2) - 1
       in (V2 col bottom, V2 col (bottom + 1))

-- | An upper bound on @|p|@ for every index of the stroke — the
-- 'Magic.Compile.emitterBounds' counterpart of
-- 'Magic.Compile.shapeRadius', conservative in the same way (over-
-- estimating is allowed, under-estimating is not).
strokeRadius :: SigilStroke -> Float
strokeRadius sk = reach + abs (skJitter sk)
  where
    r = abs (skRadius sk)
    reach = case skKind sk of
      ArcRing _ -> r
      Polygram _ _ -> r
      Spokes len -> max r (abs (r - abs len))
      Ticks len -> r + abs len
      Rose _ -> r
      GlyphBand _ -> r * (1 + 1.5 * glyphHalf)

-- Small V2 helpers (the core has no vector-space class; these mirror
-- 'Magic.Types''s own inline style) ------------------------------------------

unitAt :: Float -> V2
unitAt th = V2 (cos th) (sin th)
{-# INLINE unitAt #-}

perpOf :: V2 -> V2
perpOf (V2 x y) = V2 (negate y) x
{-# INLINE perpOf #-}

scaleV2 :: Float -> V2 -> V2
scaleV2 s (V2 x y) = V2 (s * x) (s * y)
{-# INLINE scaleV2 #-}

normalizeV2 :: V2 -> V2
normalizeV2 v@(V2 x y) =
  let n = sqrt (x * x + y * y)
   in if n < 1e-9 then V2 1 0 else scaleV2 (1 / n) v
{-# INLINE normalizeV2 #-}
