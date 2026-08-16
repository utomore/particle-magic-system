-- | Spatial summary of a compiled spell (func-spec 0025, ADR-0019): the
-- system's third output, after 'Magic.Interface.RenderBatch' and errors.
--
-- It answers one question the rest of the system cannot: __where is this
-- spell right now?__ — as a fitted oriented box, as its world AABB, and
-- as an occupancy grid a host can use for broad-phase collision, AoE
-- tests or frustum culling.
--
-- This is deliberately __not__ a spatial partition (architecture §7's
-- explicit non-goal, §11's permanent one). The distinction that keeps it
-- on the right side of that line, and that ADR-0019 records:
--
-- * it is an /outward summary/, never a simulation accelerator;
-- * it reads an already-computed buffer and influences no particle;
-- * it is a pure function with zero cross-frame state, discardable and
--   recomputable at any moment;
-- * it is @O(particle count)@, one pass, and changes no complexity class;
-- * remove it and the particle output is bit-for-bit identical.
--
-- In one sentence: it is 'Magic.Interface.RenderBatch'\'s sibling, not
-- 'Magic.Particle.Field.FieldState'\'s. Nothing here opens a door to
-- particle-to-particle interaction.
--
-- __Frozen__ once func-spec 0025 delivers: the meaning of 'OrientedBox'
-- and 'OccupancyGrid', the grid's index order, and the rule that decides
-- the grid's frame.
module Magic.Space
  ( -- * Oriented boxes
    OrientedBox (..)
  , emitterBox
  , boxToAABB
  , spellBounds
  , spellBox

    -- * Occupancy
  , OccupancyGrid (..)
  , occupancyOf
  , occupancyMask
  , occupancyDimDefault
  ) where

import Control.Monad.ST (runST)
import Data.Bits (setBit)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MU
import Data.Word (Word32)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Interval (..)
  , IntervalEnv (..)
  , Motion (..)
  , SpawnPattern (..)
  , emitterBounds
  , evalInterval
  , ivSub
  , maxMagnitude
  , shapeRadius
  )
import Magic.Expr (ExprV3 (..))
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Rune
  ( Anchor (..)
  , Envelope (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Sigil (strokeRadius)
import Magic.Types
  ( CastContext (..)
  , Seconds (..)
  , V3 (..)
  , basisFromNormal
  , dot
  , normalize
  , vscale
  )

-- | A box that is allowed to be turned: a center, three orthonormal axes
-- and three half-extents along them.
--
-- The axes are always a face coordinate system —
-- @(right, up, normal)@ from 'Magic.Types.basisFromNormal' — because
-- that is the frame every position in this system is built in
-- (spec 0002 §4.3). No second coordinate convention is introduced: a box
-- whose axes were the world's would have to be loose in exactly the
-- direction spells are long in.
data OrientedBox = OrientedBox
  { obCenter :: !V3
  , obAxisU :: !V3
  -- ^ Face right (unit).
  , obAxisV :: !V3
  -- ^ Face up (unit).
  , obAxisN :: !V3
  -- ^ Face normal (unit).
  , obHalfU :: !Float
  , obHalfV :: !Float
  , obHalfN :: !Float
  }
  deriving (Eq, Show)

-- | A conservative box containing every position an emitter can sample
-- over @[0, horizon]@, with the radius resolved __per axis__ in the
-- emitter's own face frame.
--
-- The same interval arithmetic 'Magic.Compile.emitterBounds' runs, split
-- three ways instead of collapsed into one radius: travel along the
-- normal lands on 'obHalfN' only, the spawn shape's extent and the
-- lateral radius land on 'obHalfU' \/ 'obHalfV' only, and the node drift
-- contributes its own three components rather than its length. A beam
-- that flies 8 units along its normal therefore stops claiming 8 units
-- sideways, which is the whole point (func-spec 0025 §1).
--
-- Conservative in the same sense as 'Magic.Compile.emitterBounds': every
-- position 'Magic.Particle.Analytic.particlePosition' produces lies
-- inside, and nothing is promised about how tightly. 'emitterBounds'
-- itself is untouched by all of this — it is a frozen export whose
-- /numbers/ a host may already depend on, so the tighter bound arrives as
-- a new function rather than as a better version of the old one
-- (func-spec 0025 §2.3).
--
-- Two places where the split has to be honest about what it cannot know:
--
-- * 'RadialOutward' radiates along an in-plane direction that varies per
--   particle, and its lateral pair is that direction's own basis — so
--   every trajectory term is charged to all three axes. (With
--   'SpawnAtAnchor' the spawn offset is exactly zero, the sampler falls
--   back to the face normal, and the tight 'AlongNormal' split applies.)
-- * a convergence curve pulls positions towards the travel axis, so it
--   can only rescale the part of the offset perpendicular to that axis:
--   under 'AlongNormal' that is precisely the two in-plane half-extents,
--   and nothing touches 'obHalfN'.
emitterBox :: CastContext -> Seconds -> EmitterSpec -> OrientedBox
emitterBox ctx (Seconds horizon) em =
  OrientedBox
    { obCenter = anchorW
    , obAxisU = u
    , obAxisV = w
    , obAxisN = faceNormal
    , obHalfU = halfU
    , obHalfV = halfV
    , obHalfN = halfN
    }
  where
    -- Caster frame: +Z = facing, X/Y = the facing's face-plane basis.
    -- Identical to 'Magic.Particle.Analytic.emitterFrame', which is what
    -- makes the containment law provable rather than approximate.
    facing = normalize (casterFacing ctx)
    (fu, fw) = basisFromNormal facing
    toWorld (V3 x y z) = vscale x fu + vscale y fw + vscale z facing
    anchorW = casterPos ctx + toWorld (anchorOffset (emAnchor em))
    faceNormal = normalize (toWorld (anchorNormal (emAnchor em)))
    (u, w) = basisFromNormal faceNormal

    Motion spawnPattern trajectory radiation drift mRange mConverge = emMotion em
    V3 driftU driftV driftN = drift
    Seconds lifetime = envLifetime (emSpawn em)

    maxAge = realToFrac (min lifetime (max 0 horizon)) :: Float

    indexRange = Interval 0 (fromIntegral (max 0 (emCount em - 1)))
    birthEnv = IntervalEnv (Interval (negate maxAge) (realToFrac (max 0 horizon))) (Interval 0 0) indexRange
    frameEnv = IntervalEnv (Interval 0 (realToFrac (max 0 horizon))) (Interval 0 1) indexRange
    ageEnv = IntervalEnv (Interval 0 maxAge) (Interval 0 1) indexRange

    rangeScale = maybe 1 (\e -> maxMagnitude (evalInterval e birthEnv)) mRange

    -- In-plane only: the sampler adds @sx·u + sy·w@ and nothing along the
    -- normal. Bounding @|p|@ bounds each component of it.
    spawnRadius = case spawnPattern of
      SpawnAtAnchor _ -> 0
      SpawnOnShape shape -> rangeScale * shapeRadius shape
      SpawnOnStroke stroke -> rangeScale * strokeRadius stroke

    -- With no spawn offset the sampler's radial fallback IS the face
    -- normal (@norm outward < 1e-6@), so the tight split applies.
    effectiveRadiation = case spawnPattern of
      SpawnAtAnchor _ -> AlongNormal
      _ -> radiation

    -- (along the travel axis, in the travel axis' lateral plane).
    (travelRadius, lateralRadius) = case trajectory of
      Forward speed -> (abs (realToFrac speed) * maxAge, 0)
      Spiral speed radius' _ -> (abs (realToFrac speed) * maxAge, abs (realToFrac radius'))
      Orbit radius' _ -> (0, abs (realToFrac radius'))
      Formula (ExprV3 x y z) ->
        ( maxMagnitude (evalInterval z ageEnv)
        , maxMagnitude (evalInterval x ageEnv) + maxMagnitude (evalInterval y ageEnv)
        )
      -- Func-spec 0021's four. Each bound is the closed form's own
      -- supremum over @age ∈ [0, maxAge]@, not a sample of it — the same
      -- standard the four above are held to.
      --
      -- 'Wave' and 'Zigzag' travel like 'Forward'; their lateral term is a
      -- sine and a triangle wave, both of which live in @[−1, 1]@, so the
      -- amplitude is the exact lateral bound.
      Wave speed amplitude _ -> (abs (realToFrac speed) * maxAge, abs (realToFrac amplitude))
      Zigzag speed amplitude _ -> (abs (realToFrac speed) * maxAge, abs (realToFrac amplitude))
      -- The parabola @speed·a − ½·g·a²@ turns around inside the window
      -- whenever the apex falls in it, so the endpoint is not the maximum.
      -- Bounding the two terms separately is loose by at most the apex
      -- term and never wrong.
      Ballistic speed gravity ->
        (abs (realToFrac speed) * maxAge + 0.5 * abs (realToFrac gravity) * maxAge * maxAge, 0)
      -- 'Pulse' integrates @mean·(1 − cos)@, an integrand in @[0, 2·mean]@,
      -- so the displacement cannot exceed @2·|mean|·maxAge@. Bounding the
      -- integrand rather than the closed form is what keeps this finite as
      -- the frequency approaches zero.
      Pulse meanSpeed _ -> (2 * abs (realToFrac meanSpeed) * maxAge, 0)

    -- The per-particle drift spread draws its two coefficients from
    -- 'Magic.Types.hashChan' shifted to [-0.5, 0.5], on the two in-plane
    -- axes only — so half the spread, per axis, is the exact bound.
    spreadRadius = case spawnPattern of
      SpawnAtAnchor spread -> 0.5 * abs spread
      SpawnOnShape _ -> 0
      SpawnOnStroke _ -> 0

    (trajU, trajV, trajN) = case effectiveRadiation of
      AlongNormal -> (lateralRadius, lateralRadius, travelRadius)
      -- The axis is some in-plane direction and its lateral pair is that
      -- axis' own basis: neither is aligned with (u, w, n), so every term
      -- is charged to every axis. Func-spec 0021's two additions travel
      -- along a per-particle axis for the same reason ('RadialInward' is
      -- 'RadialOutward' reversed, 'TangentialSwirl' is its perpendicular),
      -- so they take the same conservative split rather than a tighter one
      -- that would have to know the spawn direction.
      RadialOutward -> radial
      RadialInward -> radial
      TangentialSwirl -> radial

    radial = let m = travelRadius + lateralRadius in (m, m, m)

    rawU = spawnRadius + trajU + maxAge * (spreadRadius + abs driftU)
    rawV = spawnRadius + trajV + maxAge * (spreadRadius + abs driftV)
    rawN = trajN + maxAge * abs driftN

    -- pos = raw − (1 − k_c)·transverse, with transverse ⟂ the travel axis.
    convergeSlack = case mConverge of
      Nothing -> 0
      Just e -> maxMagnitude (ivSub (Interval 1 1) (evalInterval e frameEnv))

    -- The fitted box is only ever an improvement on the frozen cube, never
    -- a regression — so each half-extent is capped by the frozen radius.
    --
    -- This is always valid: 'emitterBounds' bounds @|offset|@ itself, and
    -- a bound on a vector's length bounds its component along every unit
    -- direction, this box's axes included. It is not decoration either.
    -- The convergence term above charges @slack@ against the sum of the
    -- three half-extents whenever the travel axis is per-particle, which
    -- can exceed the cube that charges it against the length once — a
    -- combination no example spell had until func-spec 0021 shipped a
    -- 'RadialInward' circle with a converge curve (yin-yang). Capping
    -- makes "fitted never larger than frozen" true by construction rather
    -- than true of the examples that happen to exist.
    (loFrozen, hiFrozen) = emitterBounds ctx (Seconds horizon) em
    frozenRadius = case (loFrozen, hiFrozen) of
      (V3 lx _ _, V3 hx _ _) -> 0.5 * (hx - lx)

    halfU = min frozenRadius fittedU
    halfV = min frozenRadius fittedV
    halfN = min frozenRadius fittedN

    (fittedU, fittedV, fittedN) = case (convergeSlack, effectiveRadiation) of
      (0, _) -> (rawU, rawV, rawN)
      -- Travel axis = the normal ⇒ the transverse part is exactly the
      -- in-plane offset, component for component.
      (slack, AlongNormal) -> (rawU * (1 + slack), rawV * (1 + slack), rawN)
      -- Unknown in-plane axis ⇒ |transverse| ≤ |offset|, which only the
      -- sum of the three half-extents bounds. All three per-particle
      -- radiation modes (func-spec 0021 added the latter two) land here
      -- for the same reason: the travel axis is not known at compile time.
      (slack, _) ->
        let total = slack * (rawU + rawV + rawN)
         in (rawU + total, rawV + total, rawN + total)

-- | The world axis-aligned box containing an oriented one, as
-- @(min corner, max corner)@ — for a host that would rather not do the
-- projection itself. Each world axis picks up the half-extent of every
-- box axis, weighted by how much of that axis points along it.
boxToAABB :: OrientedBox -> (V3, V3)
boxToAABB box = (obCenter box - extent, obCenter box + extent)
  where
    V3 ux uy uz = obAxisU box
    V3 vx vy vz = obAxisV box
    V3 nx ny nz = obAxisN box
    hu = obHalfU box
    hv = obHalfV box
    hn = obHalfN box
    extent =
      V3
        (hu * abs ux + hv * abs vx + hn * abs nx)
        (hu * abs uy + hv * abs vy + hn * abs ny)
        (hu * abs uz + hv * abs vz + hn * abs nz)

-- | The whole spell's world AABB: the union of every emitter's
-- 'emitterBox', which the host would otherwise fold itself.
--
-- A spell with no emitters (@mempty@, e.g. @castSpells []@) reports a
-- degenerate box at the caster: it occupies a point, which is true, and
-- is what a union over nothing has to mean for the result to keep
-- containing every particle there is.
spellBounds :: CastContext -> Seconds -> CompiledSpell -> (V3, V3)
spellBounds ctx horizon spell = case boxes of
  [] -> (casterPos ctx, casterPos ctx)
  (b : bs) -> foldl union (boxToAABB b) bs
  where
    boxes = V.toList (V.map (emitterBox ctx horizon) (spellEmitters spell))
    union (lo, hi) b =
      let (lo', hi') = boxToAABB b
       in (vmin lo lo', vmax hi hi')
    vmin (V3 a b' c) (V3 d e f) = V3 (min a d) (min b' e) (min c f)
    vmax (V3 a b' c) (V3 d e f) = V3 (max a d) (max b' e) (max c f)

-- | The whole spell as one oriented box, in the __caster's__ frame:
-- @(right, up, facing)@ of 'Magic.Types.casterFacing'.
--
-- The caster frame rather than any one emitter's: a spell may fire from
-- several activation points with different normals (func-spec 0025 S4),
-- and there is exactly one frame every one of them is expressed in. For
-- the ordinary single-anchor spell (@anchorNormal = +Z@) the two coincide,
-- so this is the emitter's own frame with no widening at all.
--
-- Each emitter box is projected onto the three caster axes and the
-- extremes taken, which is conservative and cheap; a rotating-calipers
-- fit would be tighter and would break the comparability law the grid
-- rests on (§2.7), since the tightest frame moves with the contents.
spellBox :: CastContext -> Seconds -> CompiledSpell -> OrientedBox
spellBox ctx horizon spell = case boxes of
  [] ->
    OrientedBox
      { obCenter = casterPos ctx
      , obAxisU = fu
      , obAxisV = fw
      , obAxisN = facing
      , obHalfU = 0
      , obHalfV = 0
      , obHalfN = 0
      }
  bs ->
    let (loU, hiU) = spanOn fu bs
        (loV, hiV) = spanOn fw bs
        (loN, hiN) = spanOn facing bs
        midU = (loU + hiU) / 2
        midV = (loV + hiV) / 2
        midN = (loN + hiN) / 2
     in OrientedBox
          { obCenter = vscale midU fu + vscale midV fw + vscale midN facing
          , obAxisU = fu
          , obAxisV = fw
          , obAxisN = facing
          , obHalfU = (hiU - loU) / 2
          , obHalfV = (hiV - loV) / 2
          , obHalfN = (hiN - loN) / 2
          }
  where
    facing = normalize (casterFacing ctx)
    (fu, fw) = basisFromNormal facing
    boxes = V.toList (V.map (emitterBox ctx horizon) (spellEmitters spell))

    -- A box's extreme coordinates along one unit axis: the center's
    -- projection plus the box's own support in that direction.
    spanOn axis bs =
      ( minimum [projectionOf b axis - supportOf b axis | b <- bs]
      , maximum [projectionOf b axis + supportOf b axis | b <- bs]
      )
    projectionOf b axis = dot (obCenter b) axis
    supportOf b axis =
      obHalfU b * abs (dot (obAxisU b) axis)
        + obHalfV b * abs (dot (obAxisV b) axis)
        + obHalfN b * abs (dot (obAxisN b) axis)

-- Occupancy -------------------------------------------------------------------

-- | The grid dimension whose cell count fits a single 32-bit word:
-- @3³ = 27 ≤ 32@, so 'occupancyMask' can answer "which cells hold
-- particles" without a buffer at all.
--
-- 27 is not a coincidence. It is this system's own nine-grid — ADR-0003's
-- up\/down\/left\/right plus center, the same figure 'Magic.Rune.HollowSquare'
-- draws — extruded along the normal, which is architecture §3.3's "the
-- initial face is expanded into a solid along the normal" discretized.
occupancyDimDefault :: Int
occupancyDimDefault = 3

-- | An @N³@ count of how many particles fall in each cell of a box.
--
-- Index order is @(k*N + j)*N + i@ with @i@ along 'obAxisU', @j@ along
-- 'obAxisV' and @k@ along 'obAxisN' — U fastest, so a host walking the
-- array in order walks the face plane row by row, plane by plane along
-- the normal.
data OccupancyGrid = OccupancyGrid
  { ogDim :: !Int
  -- ^ @N@ (always ≥ 1).
  , ogFrame :: !OrientedBox
  -- ^ The box the cells divide up. Fixed for a spell's whole life
  -- (func-spec 0025 §2.7): cell 5 must mean the same region on frame 10
  -- and frame 11, or a host cannot compare two frames and "particles
  -- entered this region" is not expressible. Fitting the frame to each
  -- frame's actual particles would be tighter and would destroy exactly
  -- that.
  , ogCounts :: !(U.Vector Int)
  -- ^ @N³@ counts. Their sum is the buffer's 'pbCount': every particle
  -- lands in exactly one cell.
  }
  deriving (Eq, Show)

-- | One @O(particle count)@ read-only pass over a buffer.
--
-- Particles outside the frame are clamped into the boundary cell. The
-- frame is a conservative box, so in theory nothing is ever outside it;
-- the clamp is a defence against the float edge cases theory does not
-- cover (a position landing exactly on a face, an infinite bound), not a
-- semantic. It is also what makes the sum law total.
--
-- The buffer is read and nothing else: no column is touched, no
-- cross-frame state exists, and the same @(dim, frame, buffer)@ always
-- gives the same grid.
occupancyOf :: Int -> OrientedBox -> ParticleBuffer -> OccupancyGrid
occupancyOf dim frame pb =
  OccupancyGrid
    { ogDim = n
    , ogFrame = frame
    , ogCounts = counts
    }
  where
    n = max 1 dim

    -- One mutable counter vector, one walk of the rows, nothing allocated
    -- per particle. The 'ST' region is closed, so this stays a pure
    -- function — ADR-0007 is about effects escaping, not about internal
    -- mutation (the same reasoning 'Magic.Particle.Buffer.buildBuffer'
    -- rests on).
    -- The frame is torn down into plain 'Float's once, so the walk below
    -- does arithmetic on unboxed values and constructs no 'V3' per
    -- particle. Same three projections as the readable spelling
    -- (@dot (p - center) axis@), one allocation fewer per row.
    !(V3 cx cy cz) = obCenter frame
    !(V3 ux uy uz) = obAxisU frame
    !(V3 vx vy vz) = obAxisV frame
    !(V3 nx ny nz) = obAxisN frame

    -- Everything a cell index needs, per axis, resolved once: the offset
    -- that moves the frame's near face to zero, the cells-per-unit scale
    -- (so no division runs per particle), and the fallback for an axis
    -- with no width at all — a frame that is flat along one axis puts
    -- every particle on its middle plane.
    !nF = fromIntegral n :: Float
    !middle = n `div` 2
    !(halfU, scaleU, flatU) = axisSetup (obHalfU frame)
    !(halfV, scaleV, flatV) = axisSetup (obHalfV frame)
    !(halfN, scaleN, flatN) = axisSetup (obHalfN frame)
    axisSetup half
      | half > 0 = (half, nF / (2 * half), False)
      | otherwise = (0, 0, True)

    counts = runST $ do
      cells <- MU.replicate (n * n * n) 0
      let go !r
            | r >= rows = pure ()
            | otherwise = do
                let !x = U.unsafeIndex colX r - cx
                    !y = U.unsafeIndex colY r - cy
                    !z = U.unsafeIndex colZ r - cz
                    !i = axisCell flatU halfU scaleU (x * ux + y * uy + z * uz)
                    !j = axisCell flatV halfV scaleV (x * vx + y * vy + z * vz)
                    !k = axisCell flatN halfN scaleN (x * nx + y * ny + z * nz)
                MU.unsafeModify cells (+ 1) ((k * n + j) * n + i)
                go (r + 1)
      go 0
      U.unsafeFreeze cells

    !rows = pbCount pb
    !colX = pbPosX pb
    !colY = pbPosY pb
    !colZ = pbPosZ pb

    -- @truncate@ rather than @floor@ because the argument is compared
    -- against 0 first, and the two agree on non-negative values.
    axisCell :: Bool -> Float -> Float -> Float -> Int
    axisCell flat half scale proj
      | flat = middle
      | isNaN v = middle
      | v <= 0 = 0
      | v >= nF = n - 1
      | otherwise = truncate v
      where
        !v = (proj + half) * scale
    {-# INLINE axisCell #-}

-- | The @N = 3@ fast path: bit @c@ is set exactly when cell @c@ of
-- @'occupancyOf' 3@ holds at least one particle.
--
-- 27 cells fit in one 'Word32', so a host doing broad-phase gets the
-- whole answer in a single query with no array to size, no capacity to
-- check and no allocation — an overlap test is one @popCount@ or one
-- bitwise @and@. Cells 27..31 are always clear.
occupancyMask :: OrientedBox -> ParticleBuffer -> Word32
occupancyMask frame pb =
  U.ifoldl' (\acc c count -> if count > 0 then setBit acc c else acc) 0 counts
  where
    counts = ogCounts (occupancyOf occupancyDimDefault frame pb)
