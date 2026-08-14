-- | HUD formatting (func-spec 0005 §4.6): pure, so what the overlay says
-- is decided and asserted headless and the raylib backend only has to
-- call @drawText@ once per line.
module App.Hud
  ( formatHud
  , fpsEma
  ) where

import Text.Printf (printf)

import Magic.Projection (ViewPlane (..))

import App.Camera (Orbit (..), toOrbit)
import App.Effects (FlatView (..), HudView (..), ReloadStatus (..), ViewMode (..))

-- | One string per HUD line. A failed load contributes its full error
-- text, expanded so embedded newlines (JSON path + parse position from
-- 'Magic.Codec.renderLoadError') stay readable on screen.
formatHud :: HudView -> [String]
formatHud v =
  [ printf "fps: %.1f" (hvFps v)
  , "particles: " ++ show (hvParticles v)
  , "spell: " ++ hvSpellPath v
  , printf "age: %.2fs" (hvSpellAge v)
  , "view: " ++ viewLabel (hvView v)
  , steerLine v
  ]
    ++ reloadLines (hvReload v)
    ++ [ "[<-] [->] switch spell   [R] recast   [Tab] 2D/3D   [V] plane   [T] depth tint"
       , "[drag] orbit / pan   [wheel] zoom"
       ]

-- | How the current backend reads on screen (func-spec 0008 §4.4).
viewLabel :: ViewMode -> String
viewLabel mode = case mode of
  View3D -> "3D"
  View2D SideXY -> "2D side (X/Y)"
  View2D TopXZ -> "2D top (X/Z)"

-- | Where the live view has been steered to (func-spec 0013 §4): the
-- orbit camera in 3D, the pan/zoom/tint settings in 2D.
--
-- Only the live one is reported. A reader who has just dragged wants to
-- know where they are now, and a line describing the view they are not
-- looking at is noise.
steerLine :: HudView -> String
steerLine v = case hvView v of
  View3D ->
    let ob = toOrbit (hvCamera v)
     in printf
          "cam: r %.1f  az %.0f  el %.0f"
          (obRadius ob)
          (obAzimuth ob)
          (obElevation ob)
  View2D _ ->
    let fv = hvFlat v
        (ox, oy) = fvOrigin fv
     in printf
          "zoom: %.0f px/unit  origin: %.0f, %.0f  tint: %s"
          (fvPixelsPerUnit fv)
          ox
          oy
          (if fvDepthTint fv > 0 then "on" else "off" :: String)

reloadLines :: ReloadStatus -> [String]
reloadLines status = case status of
  ReloadIdle -> ["reload: idle"]
  ReloadOk t -> [printf "reload: ok at %.2fs" t]
  ReloadFailed t err ->
    printf "reload: FAILED at %.2fs" t : map ("  " ++) (linesOf err)
  where
    -- 'lines' drops a trailing empty line, which is what we want, but it
    -- also collapses an all-whitespace error to nothing; keep a marker so
    -- the HUD never claims a failure without saying anything.
    linesOf err = case lines err of
      [] -> ["(no message)"]
      ls -> ls

-- | Exponential moving average of the instantaneous frame rate.
--
-- @fpsEma alpha frameDt ema@. A constant @frameDt@ converges to
-- @1/frameDt@. Guards keep the result finite and non-negative for any
-- input: @alpha@ is clamped to @[0,1]@ and a non-positive @frameDt@
-- (a paused or backwards clock) carries the previous value forward.
fpsEma :: Double -> Double -> Double -> Double
fpsEma alpha frameDt ema
  | frameDt <= 0 = prev
  | otherwise = max 0 (prev + a * (1 / frameDt - prev))
  where
    prev = max 0 ema
    a = min 1 (max 0 alpha)
