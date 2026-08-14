-- | Orbit-camera arithmetic (func-spec 0013 §2): the pure half of the
-- 3D camera controls.
--
-- The demo's camera is an orbit camera — it always looks at a fixed
-- target and only its position moves, on a sphere around that target.
-- Expressing it that way makes the two controls total functions with
-- laws instead of incremental vector nudges that drift: dragging changes
-- the two angles and nothing else, the wheel changes the radius and
-- nothing else.
--
-- Renderer-agnostic and effect-free, like everything the raylib backend
-- is handed: 'Camera' is our own record ('App.Effects'), so the whole
-- control scheme is property-testable headless (@test\/CameraSpec.hs@).
module App.Camera
  ( Orbit (..)
  , toOrbit
  , fromOrbit
  , orbit
  , dolly
  , minRadius
  , maxRadius
  , maxElevation
  ) where

import App.Effects (Camera (..))
import Magic.Interface (V3 (..))

-- | A camera position in spherical coordinates around 'camTarget'.
--
-- Angles are degrees, the unit the controls and the HUD are written in.
-- Azimuth turns around the world @+Y@ axis measured from @+Z@ towards
-- @+X@; elevation is the angle above the @XZ@ plane.
data Orbit = Orbit
  { obRadius :: !Float
  , obAzimuth :: !Float
  , obElevation :: !Float
  }
  deriving (Eq, Show)

-- | Closest and furthest the wheel may pull the camera. A hard clamp
-- rather than damping: the demo's spells live within a few units of the
-- caster, and passing through the target flips the view inside out.
minRadius, maxRadius :: Float
minRadius = 1
maxRadius = 50

-- | Elevation is clamped just short of the poles: at exactly ±90° the
-- position becomes collinear with 'camUp' and the look-at basis is
-- degenerate (billboarding would have to guess a right vector).
maxElevation :: Float
maxElevation = 89

-- | Where the camera sits, relative to its target.
--
-- A camera sitting exactly on its target has no direction to report;
-- it reads as radius 0 at the origin angles, and 'dolly' is what pushes
-- it back out.
toOrbit :: Camera -> Orbit
toOrbit cam
  | r < 1e-6 = Orbit {obRadius = 0, obAzimuth = 0, obElevation = 0}
  | otherwise =
      Orbit
        { obRadius = r
        , obAzimuth = toDegrees (atan2 ox oz)
        , obElevation = toDegrees (asin (clamp (-1) 1 (oy / r)))
        }
  where
    V3 ox oy oz = camPos cam `sub` camTarget cam
    r = sqrt (ox * ox + oy * oy + oz * oz)

-- | Rebuild the camera position from spherical coordinates, keeping
-- every other field of the camera it came from.
fromOrbit :: Orbit -> Camera -> Camera
fromOrbit ob cam = cam {camPos = camTarget cam `add` V3 ox oy oz}
  where
    r = obRadius ob
    az = toRadians (obAzimuth ob)
    el = toRadians (obElevation ob)
    horizontal = r * cos el
    ox = horizontal * sin az
    oy = r * sin el
    oz = horizontal * cos az

-- | Drag the camera around its target: @orbit (dAzimuth, dElevation)@,
-- both in degrees.
--
-- Laws (@test\/CameraSpec.hs@): the target, the radius, the up vector and
-- the field of view are all conserved; elevation never leaves
-- @[-'maxElevation', 'maxElevation']@; a zero drag is the identity, on
-- the nose — the round trip through the trigonometry is skipped
-- entirely, so an idle frame cannot make the camera drift.
orbit :: (Float, Float) -> Camera -> Camera
orbit (dAz, dEl) cam
  | dAz == 0 && dEl == 0 = cam
  | otherwise = fromOrbit ob' cam
  where
    ob = toOrbit cam
    ob' =
      ob
        { obAzimuth = wrapDegrees (obAzimuth ob + dAz)
        , obElevation = clamp (-maxElevation) maxElevation (obElevation ob + dEl)
        }

-- | Wheel zoom: @dolly notches@ pulls the camera in for a positive
-- number of wheel notches and pushes it out for a negative one, by a
-- constant factor per notch, with the radius clamped to
-- @['minRadius', 'maxRadius']@.
--
-- Implemented by scaling the offset vector rather than by a round trip
-- through 'Orbit', so the view direction is preserved exactly rather
-- than to within two trigonometric conversions. A zero delta is the
-- identity on the nose, for the same reason it is in 'orbit'.
dolly :: Float -> Camera -> Camera
dolly notches cam
  | notches == 0 = cam
  | r < 1e-6 = cam {camPos = camTarget cam `add` V3 0 0 (clampRadius r')}
  | otherwise = cam {camPos = camTarget cam `add` scale (clampRadius r' / r) offset}
  where
    offset@(V3 ox oy oz) = camPos cam `sub` camTarget cam
    r = sqrt (ox * ox + oy * oy + oz * oz)
    r' = r * (dollyPerNotch ** negate notches)

-- | Radius factor of one wheel notch. Multiplicative, so a notch feels
-- the same close up and far away.
dollyPerNotch :: Float
dollyPerNotch = 1.15

clampRadius :: Float -> Float
clampRadius = clamp minRadius maxRadius

clamp :: Float -> Float -> Float -> Float
clamp lo hi x = max lo (min hi x)

-- | Fold an angle into @[-180, 180)@ so a long drag cannot accumulate an
-- unbounded azimuth (which would lose float precision).
wrapDegrees :: Float -> Float
wrapDegrees a
  | wrapped > 180 = wrapped - 360
  | otherwise = wrapped
  where
    wrapped = a - 360 * fromIntegral (floor ((a + 180) / 360) :: Int)

toRadians :: Float -> Float
toRadians d = d * pi / 180

toDegrees :: Float -> Float
toDegrees r = r * 180 / pi

add :: V3 -> V3 -> V3
add (V3 ax ay az) (V3 bx by bz) = V3 (ax + bx) (ay + by) (az + bz)

sub :: V3 -> V3 -> V3
sub (V3 ax ay az) (V3 bx by bz) = V3 (ax - bx) (ay - by) (az - bz)

scale :: Float -> V3 -> V3
scale k (V3 x y z) = V3 (k * x) (k * y) (k * z)
