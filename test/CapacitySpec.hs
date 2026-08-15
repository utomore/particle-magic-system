-- | S1 (func-spec 0012 §7): the particle cap rises, and the three things
-- that had to survive it.
--
--   1. The /value/: 16384, the largest power of two whose whole per-frame
--      CPU cost (sampling + quad expansion) stays under 2 ms at func-spec
--      0010 §9.2's measured constants. A sentinel, so the next round that
--      moves it has to come here and say so.
--   2. The /mirror/: the C ABI answers the new cap through
--      @pm_max_particles@, while @PM_MAX_PARTICLES@ in the header stays
--      pinned at the first generation's 4096 — func-spec 0011 §9.4's two
--      laws, exercised for the first time by an actual raise. (The
--      three-way contract itself is @FFIContractSpec@'s; this is the
--      0012-side witness that the raise went through the pipe 0011 laid.)
--   3. The /renderer/: the demo's mesh is not resized to follow the cap.
--      A batch bigger than the mesh is drawn in consecutive chunks, and
--      the chunks are the batch — concatenating their vertex streams
--      reproduces the whole one exactly, which is the part that can be
--      tested without a GPU (the visual half is the manual smoke, §9).
module CapacitySpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Vector.Storable as S
import Magic.Codec (loadCircle)
import Magic.Compile (CompileError (..), budgetCap, compile)
import Magic.FFI (pm_max_particles, pmMaxParticles)
import Magic.Interface
  ( CastContext (..)
  , CastRequest (..)
  , Circle
  , DeltaTime (..)
  , FrameInput (..)
  , ParticleBuffer
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , batches
  , castSpell
  , maxSpellParticles
  , observeSpell
  , pbCount
  )
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import App.Render.Chunk (chunkBatch)
import App.Render.Quads (QuadBatch (..), buildQuads)
import FFIContractSpec (headerDefines)

-- | A circle whose essence power drives the particle count to @round
-- (power * 256)@ — the one lever that reaches the cap from JSON.
denseBytes :: Double -> BS.ByteString
denseBytes power =
  BS8.pack
    ( "{ \"version\": 1, \"name\": \"capacity-fixture\", \"circle\": \
      \{ \"core\": { \"center\": { \"element\": \"fire\", \"power\": "
        ++ show power
        ++ " }, \"nodes\": { \"north\": null, \"south\": null, \
           \\"east\": null, \"west\": null } } } }"
    )

denseCircle :: Double -> IO Circle
denseCircle power = either (fail . show) pure (loadCircle (denseBytes power))

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

camPos, camTarget, camUp :: V3
camPos = V3 6 4 6
camTarget = V3 0 2 0
camUp = V3 0 1 0

-- | Sample a dense spell after enough frames for its whole budget to be
-- alive (births are staggered across the envelope lifetime).
denseBuffer :: Double -> IO ParticleBuffer
denseBuffer power = do
  circle <- denseCircle power
  spell <- either (fail . show) pure (castSpell (CastRequest circle ctx))
  let dt = FrameInput (DeltaTime (1 / 60))
      aged = iterate (advanceSpell dt) spell !! 240
  case batches (observeSpell aged) of
    (b : _) -> pure (rbParticles b)
    [] -> fail "dense fixture produced no batch"

spec :: Spec
spec = do
  describe "the raised cap (func-spec 0012 S1)" $ do
    it "budgetCap is 16384" $
      budgetCap `shouldBe` 16384

    it "and maxSpellParticles is the same number, not a second one" $
      maxSpellParticles `shouldBe` budgetCap

    it "which is a power of two, and above the 4096 it replaced" $ do
      budgetCap `shouldSatisfy` (> 4096)
      (budgetCap, popCountOf budgetCap) `shouldBe` (budgetCap, 1)

    it "compiles a circle of 6144 particles — refused before this round" $ do
      circle <- denseCircle 24.0
      case compile circle of
        Left err -> expectationFailure ("expected a compile, got " ++ show err)
        Right _ -> pure ()

    it "still refuses one past the new cap, reporting demand and cap" $ do
      circle <- denseCircle 80.0
      compile circle `shouldBe` Left (BudgetExceeded 20480 16384)

  describe "the C ABI mirror (func-spec 0011 §9.4, exercised)" $ do
    it "pm_max_particles answers the core's new cap" $ do
      queried <- pm_max_particles
      fromIntegral queried `shouldBe` budgetCap
      fromIntegral pmMaxParticles `shouldBe` budgetCap

    it "while PM_MAX_PARTICLES in the header is untouched at 4096" $ do
      defines <- headerDefines
      lookup "PM_MAX_PARTICLES" defines `shouldBe` Just 4096

  describe "chunked drawing (func-spec 0012 §2)" $ do
    it "a 6144-particle spell exceeds the demo's mesh capacity" $ do
      pb <- denseBuffer 24.0
      pbCount pb `shouldSatisfy` (> 4096)

    it "and its chunks concatenate back into the whole batch, bit for bit" $ do
      pb <- denseBuffer 24.0
      let whole = buildQuads camPos camTarget camUp pb
          pieces = chunkBatch 4096 whole
      length pieces `shouldBe` 2
      map qbCount pieces `shouldBe` [4096, pbCount pb - 4096]
      S.concat (map qbPositions pieces) `shouldBe` qbPositions whole
      S.concat (map qbColors pieces) `shouldBe` qbColors whole

    it "a batch within capacity is one chunk — the pre-0012 single draw" $ do
      pb <- denseBuffer 4.0
      let whole = buildQuads camPos camTarget camUp pb
      pbCount pb `shouldSatisfy` (<= 4096)
      chunkBatch 4096 whole `shouldBe` [whole]

    prop "the union law holds at every capacity and count" $
      forAll (choose (1, 40)) $ \n ->
        forAll (choose (1, 12)) $ \cap' ->
          let whole = syntheticBatch n
              pieces = chunkBatch cap' whole
           in conjoin
                [ counterexample "counts sum" (sum (map qbCount pieces) === n)
                , counterexample "each within capacity" (all ((<= cap') . qbCount) pieces)
                , counterexample "positions concatenate" (S.concat (map qbPositions pieces) === qbPositions whole)
                , counterexample "colors concatenate" (S.concat (map qbColors pieces) === qbColors whole)
                , counterexample "piece count" (length pieces === (n + cap' - 1) `div` cap')
                ]

    it "an empty batch draws nothing, and a nonpositive capacity means no limit" $ do
      chunkBatch 4096 (syntheticBatch 0) `shouldBe` []
      chunkBatch 0 (syntheticBatch 7) `shouldBe` [syntheticBatch 7]

-- | A 'QuadBatch' with recognisable, all-distinct vertex data: the
-- chunking law is about slicing, so the streams only need to be
-- well-formed and distinguishable.
syntheticBatch :: Int -> QuadBatch
syntheticBatch n =
  QuadBatch
    { qbPositions = S.generate (n * 12) fromIntegral
    , qbColors = S.generate (n * 16) fromIntegral
    , qbCount = n
    }

popCountOf :: Int -> Int
popCountOf x
  | x <= 0 = 0
  | otherwise = (x `mod` 2) + popCountOf (x `div` 2)
