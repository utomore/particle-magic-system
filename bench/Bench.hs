-- | Baseline measurements (func-spec 0005 §8 S8) — the ground truth the
-- future 10k–100k throughput spec has to improve on.
--
-- Three things are measured, all pure and all on the real per-frame path:
-- casting each example circle, sampling a full particle buffer at a range
-- of ages ('observeSpell'), and expanding that buffer into camera-facing
-- quads ('buildQuads'). Everything here is compiled with @-O2@; numbers
-- taken without it mean nothing.
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Vector.Storable as S
import Magic.Codec (loadCircle)
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , Circle
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , isFinished
  , observeSpell
  , pbCount
  )
import Test.Tasty.Bench (bench, bgroup, defaultMain, nf, whnf)

import App.Render.Quads (QuadBatch (..), buildQuads)

examples :: [FilePath]
examples =
  [ "assets/spells/ring-fire.json"
  , "assets/spells/square-burst.json"
  , "assets/spells/spiral-spark.json"
  , "assets/spells/converge-flame.json"
  ]

-- | A circle whose essence power drives the particle count to the core's
-- 4096 budget cap (count = round (power * 256)). Inline rather than an
-- asset file: it is a measuring instrument, not an example spell.
denseBytes :: BS.ByteString
denseBytes =
  BS8.pack
    "{ \"version\": 1, \"name\": \"bench-dense\", \"circle\": \
    \{ \"core\": { \"center\": { \"element\": \"fire\", \"power\": 16.0 }, \
    \\"nodes\": { \"north\": null, \"south\": null, \"east\": null, \"west\": null } } } }"

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

camPos, camTarget, camUp :: V3
camPos = V3 6 4 6
camTarget = V3 0 2 0
camUp = V3 0 1 0

loadOrDie :: FilePath -> IO Circle
loadOrDie path = do
  bytes <- BS.readFile path
  either (fail . show) pure (loadCircle bytes)

castOrDie :: Circle -> IO ActiveSpell
castOrDie circle = either (fail . show) pure (castSpell (CastRequest circle ctx))

-- | Age a spell by @n@ frames of 1/60s without sampling.
ageBy :: Int -> ActiveSpell -> ActiveSpell
ageBy n s0 = go n s0
  where
    dt = FrameInput (DeltaTime (1 / 60))
    go k s
      | k <= 0 = s
      | otherwise = go (k - 1) (advanceSpell dt s)

-- | Total particles observed — forces every SoA column of the buffer.
countOf :: FrameOutput -> Int
countOf out = sum (map (pbCount . rbParticles) (batches out))

bufferOf :: ActiveSpell -> ParticleBuffer
bufferOf s = case batches (observeSpell s) of
  (b : _) -> rbParticles b
  [] -> error "benchmark fixture produced no batch"

-- | Forcing the summed positions and the color vector's length
-- materializes both staging vectors in full.
forceQuads :: ParticleBuffer -> Float
forceQuads pb =
  let q = buildQuads camPos camTarget camUp pb
   in S.sum (qbPositions q) + fromIntegral (S.length (qbColors q))

-- | Cast and force the compiled spell to its constructor. 'isFinished'
-- reads @spellLifetime@, so the strict 'CompiledSpell' record exists —
-- but its emitter vector's elements stay lazy, so this is the floor of
-- what casting costs, not the whole of it.
castCost :: Circle -> Bool
castCost c = either (const True) isFinished (castSpell (CastRequest c ctx))

-- | What a hot reload actually costs: cast, then sample the first frame,
-- which forces every emitter the interpretation produced.
castAndObserveCost :: Circle -> Int
castAndObserveCost c =
  either (const (-1)) (countOf . observeSpell) (castSpell (CastRequest c ctx))

main :: IO ()
main = do
  circles <- mapM loadOrDie examples
  denseCircle <- either (fail . show) pure (loadCircle denseBytes)
  denseSpell <- castOrDie denseCircle
  -- Births are spread over the envelope lifetime, so by ~2s the whole
  -- budget is alive; the ages below straddle that ramp.
  let ages = [30, 60, 120, 240, 480 :: Int]
      agedSpells = map (`ageBy` denseSpell) ages
      buffer = bufferOf (ageBy 240 denseSpell)

  putStrLn ("benchmark buffer particle count: " ++ show (pbCount buffer))
  putStrLn
    ( "particle counts by age: "
        ++ show [(a, pbCount (bufferOf s)) | (a, s) <- zip ages agedSpells]
    )
  defaultMain
    [ bgroup
        "castSpell (compile only)"
        [ bench name (nf castCost circle)
        | (name, circle) <- zip examples circles
        ]
    , bgroup
        "castSpell + first observe"
        [ bench name (nf castAndObserveCost circle)
        | (name, circle) <- zip examples circles
        ]
    , bgroup
        "observeSpell"
        [ bench ("age " ++ show a ++ " frames") (nf (countOf . observeSpell) s)
        | (a, s) <- zip ages agedSpells
        ]
    , bgroup
        "buildQuads"
        [ bench ("count " ++ show (pbCount buffer)) (whnf forceQuads buffer)
        ]
    ]
