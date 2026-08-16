-- | The smallest possible /Haskell/ host for the particle magic library
-- (enhance-0001 E1).
--
-- It is the sibling of @examples\/c\/main.c@ and has the same job: do
-- what a game engine does, minus the drawing. Load a spell file, cast it,
-- run 120 fixed steps of advance + observe, feed nothing to a GPU and
-- print one line per frame instead. Those lines are the evidence -- they
-- must match the C host's line for line, which is what turns "the library
-- is complete, rendering lives outside it" into a checkable statement.
--
-- The reason this file exists at all: until enhance-0001, the /native/
-- consumption route was the only one of the three with no runnable proof.
-- C had @examples\/c@, C# had @examples\/unity@, and Haskell -- the
-- library's own language -- had only fragments inside docs/integration.md
-- that nothing compiled and nothing tested.
--
-- Build (from this directory, NOT from the repo root):
--
-- > cd examples/haskell
-- > cabal run pm-haskell-host
-- > cabal run pm-haskell-host -- ../../assets/spells/spiral-spark.json
--
-- The frozen output for the default arguments is @expected-output.txt@
-- next to this file, so the smoke is a diff:
--
-- > cabal run -v0 pm-haskell-host | diff - expected-output.txt
--
-- @test\/ExampleHostSpec.hs@ in the parent project recomputes those same
-- lines two independent ways -- through 'Magic.Interface' and through the
-- C ABI shim -- and asserts both equal that file, so the golden cannot go
-- stale without @cabal test@ noticing.
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import GHC.Float (float2Double)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hSetNewlineMode, noNewlineTranslation, stdout)
import Text.Printf (printf)

-- The entire import surface of a Haskell host (docs/integration.md §3).
-- Nothing from Magic.* outside these three modules is a contract.
import Magic.Codec (loadCircle, renderLoadError)
import Magic.Interface
  ( ActiveSpell
  , BlendMode (..)
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer
  , RenderBatch (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , isFinished
  , observeSpell
  , pbCount
  , pbLife
  , pbPosX
  , pbPosY
  , pbPosZ
  , pbSize
  , spellAge
  )
import Magic.Projection (V2 (..), ViewPlane (..), depthOrder, orthographic)

-- Run parameters -------------------------------------------------------------
--
-- Every constant here is @examples/c/main.c@'s, so the two hosts can be
-- diffed against each other.

defaultSpell :: FilePath
defaultSpell = "../../assets/spells/ring-fire.json"

frames :: Int
frames = 120

casterPosition, casterDirection :: V3
casterPosition = V3 1.5 0.25 (-2.0)
casterDirection = V3 0.0 0.0 1.0

castSeed :: Seed
castSeed = Seed 20260814

-- | The fixed step, in seconds.
--
-- A Haskell host would normally just write @1 \/ 60@: 'DeltaTime' is a
-- 'Double' and there is no reason to give that up. This example
-- deliberately uses the double /nearest/ @1 \/ 60 :: Float@ instead --
-- the value a C host's @float dt@ parameter narrows to on the way in
-- (@pm_advance@ takes a @CFloat@ and widens it with @float2Double@).
--
-- That one line is the difference between "the two hosts agree" and "the
-- two hosts agree to five decimal places", and it is a genuine fact about
-- the C ABI rather than an artefact of this file: a C host and a Haskell
-- host that both write @1/60@ in their own source are /not/ stepping the
-- same simulation. Determinism is per-input (ADR-0011 D8), and @dt@ is an
-- input.
simDt :: DeltaTime
simDt = DeltaTime (float2Double (1 / 60 :: Float))

main :: IO ()
main = do
  -- LF on every platform. Without this, a Windows run emits CRLF and the
  -- smoke below turns into "every line differs" -- which is exactly the
  -- kind of noise that trains people to stop running the smoke.
  hSetNewlineMode stdout noNewlineTranslation
  args <- getArgs
  let path = case args of
        (p : _) -> p
        [] -> defaultSpell
  bytes <- BS.readFile path
  case loadCircle bytes of
    -- Load errors carry a JSON path and are already human-readable; the
    -- demo prints this exact string onto its HUD.
    Left err -> putStrLn (renderLoadError err) >> exitFailure
    Right circle ->
      -- A cast can still fail on a well-formed circle: 'BudgetExceeded'
      -- is the one to expect, and it is reported here rather than at the
      -- first frame precisely so a host never has to handle it mid-loop.
      case castSpell (CastRequest circle context) of
        Left cerr -> putStrLn ("cast failed: " ++ show cerr) >> exitFailure
        Right spell -> do
          printf "spell: %s\n" path
          final <- runFrames 0 spell
          printf "finished: %d\n" (fromEnum (isFinished final))
          reportProjection (observeSpell final)

-- | Where the spell goes off and which way it faces. The facing is not a
-- cosmetic default: the initial face is perpendicular to it and the
-- extrusion runs along it, so a 2D host that picks a facing parallel to
-- the axis its 'ViewPlane' drops gets a spell that renders as its own
-- footprint (integration.md §3.3).
context :: CastContext
context =
  CastContext
    { casterPos = casterPosition
    , casterFacing = casterDirection
    , seed = castSeed
    }

-- | The fixed-timestep loop. One step per frame here because the
-- observations are the point; a real host runs an accumulator
-- (integration.md §2.4) so a slow render frame still advances the
-- simulation by whole steps.
runFrames :: Int -> ActiveSpell -> IO ActiveSpell
runFrames i spell
  | i >= frames = pure spell
  | otherwise = do
      let stepped = advanceSpell (FrameInput simDt) spell
          FrameOutput bs = observeSpell stepped
          Time age = spellAge stepped
          total = sum (map (pbCount . rbParticles) bs)
      printf
        "frame %3d  age %8.5f  batches %d  particles %4d  blend %d  checksum %.6f\n"
        i
        age
        (length bs)
        total
        (leadBlend bs)
        (checksum bs)
      runFrames (i + 1) stepped

-- | The blend mode a host would set before the first draw call, encoded
-- the way @batch_info[2]@ encodes it (@PM_BLEND_ALPHA@ = 0,
-- @PM_BLEND_ADDITIVE@ = 1). @-1@ means the frame has nothing to draw.
leadBlend :: [RenderBatch] -> Int
leadBlend [] = -1
leadBlend (b : _) = case rbBlend b of
  BlendAlpha -> 0
  BlendAdditive -> 1

-- | A stand-in for "the host did something with all six columns".
--
-- The association matters, not the number: the C host accumulates
-- @checksum += x + y + z + size + life@ per particle, so the per-particle
-- sum is formed first and only then added to the running total. Written
-- as @acc + x + y + ...@ this would associate the other way and the two
-- hosts would disagree in the last digits.
checksum :: [RenderBatch] -> Double
checksum = foldl' (\acc b -> bufferSum acc (rbParticles b)) 0

bufferSum :: Double -> ParticleBuffer -> Double
bufferSum start pb = foldl' add start [0 .. pbCount pb - 1]
  where
    add acc i =
      acc
        + ( ( ( (at pbPosX i + at pbPosY i)
                  + at pbPosZ i
              )
                + at pbSize i
            )
              + at pbLife i
          )
    at col i = float2Double (col pb U.! i)

-- | The 2D half of the story (enhance-0001 §1.2): 'Magic.Projection' is
-- reachable from an outside package, and it is all a flat host needs from
-- the library -- drop an axis, and get a painter's-order permutation.
--
-- Screen origin, pixels-per-unit and the y-flip are deliberately absent:
-- those are the host's, and the recipe for choosing them is
-- integration.md §3.3.
reportProjection :: FrameOutput -> IO ()
reportProjection (FrameOutput []) = putStrLn "projection: nothing left to draw"
reportProjection (FrameOutput (b : _)) =
  mapM_ report [SideXY, TopXZ]
  where
    pb = rbParticles b
    report :: ViewPlane -> IO ()
    report plane = do
      printf "projection %s: %d particles, far to near\n" (show plane) (pbCount pb)
      -- One permutation per plane, reused across the rows: 'depthOrder'
      -- sorts the whole batch, so calling it per row would be quadratic.
      let order = depthOrder plane pb
      mapM_ (row plane order) [0 .. min 3 (pbCount pb) - 1]
    row :: ViewPlane -> U.Vector Int -> Int -> IO ()
    row plane order k = do
      let i = order U.! k
          (V2 u v, d) =
            orthographic plane (V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i))
      printf
        "  %d  slot %4d  plane (%9.5f, %9.5f)  depth %9.5f\n"
        k
        i
        (float2Double u)
        (float2Double v)
        (float2Double d)
