-- | T-S9 (func-spec 0007 §8): headless acceptance of the force-field
-- layer. @gravity-well.json@ is run against its own control — the
-- identical circle with @"fields": []@ — so every difference the test
-- observes is attributable to the field layer and nothing else.
--
-- The window smoke test (does it /look/ like a gravity well) is manual
-- and recorded in spec 0007 §10.
module Acceptance7Spec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..))
import Magic.Codec (loadCircle)
import Magic.Compile (CompiledSpell (..), compile)
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , isFinished
  , observeSpell
  , spellAge
  )
import Magic.Particle.Analytic (sample)
import Magic.Rune (ForceField (..))
import Test.Hspec

wellPath :: FilePath
wellPath = "assets/spells/gravity-well.json"

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 0 1, seed = Seed 1907}

dt :: Double
dt = 1 / 60

loadWell :: IO Circle
loadWell = do
  bytes <- BS.readFile wellPath
  either (fail . show) pure (loadCircle bytes)

cast :: Circle -> IO ActiveSpell
cast circle = either (fail . show) pure (castSpell CastRequest {circleOf = circle, ctxOf = ctx})

compiledOf :: Circle -> IO CompiledSpell
compiledOf = either (fail . show) pure . compile

firstBuffer :: FrameOutput -> ParticleBuffer
firstBuffer out = case batches out of
  (batch : _) -> rbParticles batch
  [] -> error "observeSpell produced no render batch"

-- | Walk @n@ fixed steps, keeping every observed frame.
walk :: Int -> ActiveSpell -> [ParticleBuffer]
walk 0 _ = []
walk n s =
  let s' = advanceSpell (FrameInput (DeltaTime dt)) s
   in firstBuffer (observeSpell s') : walk (n - 1) s'

walkTo :: Int -> ActiveSpell -> ActiveSpell
walkTo n s = foldl (\acc _ -> advanceSpell (FrameInput (DeltaTime dt)) acc) s [1 .. n]

-- | The clock values the walk visits, accumulated as 'advanceSpell' does.
walkTimes :: Int -> [Time]
walkTimes n = map Time (drop 1 (scanl (+) 0 (replicate n dt)))

meanY :: ParticleBuffer -> Float
meanY buf
  | pbCount buf == 0 = 0
  | otherwise = U.sum (pbPosY buf) / fromIntegral (pbCount buf)

strictlyDecreasing :: [Float] -> Bool
strictlyDecreasing xs = and (zipWith (>) xs (drop 1 xs))

spec :: Spec
spec = describe "acceptance: gravity-well vs its fieldless control (spec 0007 S9)" $ do
  it "the example loads and carries the three v1 field kinds" $ do
    circle <- loadWell
    case circleFields circle of
      [Gravity (V3 _ gy _), PointAttractor{}, Vortex{}] -> gy `shouldSatisfy` (< 0)
      other -> expectationFailure ("unexpected fields: " ++ show other)

  it "the fields change nothing about the spell's shape or lifetime" $ do
    circle <- loadWell
    withFields <- compiledOf circle
    control <- compiledOf circle {circleFields = []}
    spellLifetime withFields `shouldBe` spellLifetime control
    spellBudget withFields `shouldBe` spellBudget control
    spellEmitters withFields `shouldBe` spellEmitters control
    spellPhases withFields `shouldBe` spellPhases control
    spellFields control `shouldBe` []

  it "the two runs stay frame-by-frame comparable: same particle count throughout" $ do
    circle <- loadWell
    wellFrames <- walk 240 <$> cast circle
    controlFrames <- walk 240 <$> cast circle {circleFields = []}
    map pbCount wellFrames `shouldBe` map pbCount controlFrames

  it "the well sinks the cloud, deeper as the particles age" $ do
    circle <- loadWell
    wellFrames <- walk 240 <$> cast circle
    controlFrames <- walk 240 <$> cast circle {circleFields = []}
    let sink = zipWith (\w c -> meanY w - meanY c) wellFrames controlFrames
        -- Checkpoints at 0.5 s, 1 s, 1.5 s and 2 s: the cloud's age
        -- distribution is still filling out, so each is deeper than the
        -- last (past ~2 s it reaches a steady state and levels off).
        checkpoints = [sink !! k | k <- [29, 59, 89, 119]]
    sink `shouldSatisfy` all (< 0.05)
    checkpoints `shouldSatisfy` strictlyDecreasing
    last checkpoints `shouldSatisfy` (< -0.5)

  it "the control run is exactly the analytic layer, untouched (D9)" $ do
    circle <- loadWell
    controlFrames <- walk 120 <$> cast circle {circleFields = []}
    plain <- compiledOf circle {circleFields = []}
    let analytic = [sample plain ctx t | t <- walkTimes 120]
    map pbPosY controlFrames `shouldBe` map pbPosY analytic
    map pbPosX controlFrames `shouldBe` map pbPosX analytic
    map pbPosZ controlFrames `shouldBe` map pbPosZ analytic

  it "the field layer neither extends nor shortens the spell" $ do
    circle <- loadWell
    spell <- cast circle
    compiled <- compiledOf circle
    let Seconds lifetime = spellLifetime compiled
        stepsToEnd = ceiling (lifetime / dt) :: Int
    spellAge spell `shouldBe` Time 0
    isFinished spell `shouldBe` False
    isFinished (walkTo (stepsToEnd - 2) spell) `shouldBe` False
    isFinished (walkTo (stepsToEnd + 1) spell) `shouldBe` True
