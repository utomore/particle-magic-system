-- | S5 (func-spec 0012 §7): the acceptance run for the composition round.
--
-- Init.md's parameter table had one row that never landed: several
-- circles stacking into one effect. This spec is that row becoming a
-- fact, stated on the public path only:
--
--   * the /superposition law/ — a composed cast's sampled buffer is its
--     components' buffers concatenated, bit for bit, at every frame of a
--     240-frame flight. This is the whole claim of composition: stacking
--     circles adds effects, it does not reinterpret them;
--   * /no regression/ — every shipped example, cast through the new
--     composition entry point as a one-element list, reproduces the
--     single-circle path exactly. Raising the cap and adding a 'Monoid'
--     moved nothing that already worked;
--   * /the scene layer end to end/ — three spells under one quota, flown
--     240 frames, deterministic and quota-honest at every frame;
--   * /the two documented exceptions/ (ADR-0012): force fields fuse
--     across a composition, and the composed batch carries the first
--     component's blend mode. Both are decisions, so both are asserted
--     rather than left to be discovered.
module Acceptance12Spec (spec) where

import qualified Data.ByteString as BS
import Data.Bits (shiftR, xor, (.&.))
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word64)
import GHC.Float (castFloatToWord32)
import Magic.Codec (loadCircle)
import Magic.Compile (BlendMode (..))
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
  , batches
  , budgetPlanOf
  , budgetTotal
  , castSpell
  , castSpells
  , maxSpellParticles
  , observeSpell
  , pbColor
  , pbCount
  , pbLife
  , pbPosX
  , pbPosY
  , pbPosZ
  , pbSize
  )
import Magic.Particle.Buffer (bufferInvariant)
import Magic.Scene
  ( SceneConfig (..)
  , SpellId (..)
  , advanceScene
  , castInto
  , castManyInto
  , dismiss
  , newScene
  , observeScene
  , sceneBudget
  , sceneSpells
  )
import Test.Hspec

-- | Every shipped example except the one that carries force fields:
-- fusion makes the superposition law deliberately false there, and that
-- exception gets its own assertion at the bottom.
fieldlessExamples :: [String]
fieldlessExamples =
  [ "bare-sigil"
  , "converge-flame"
  , "empty"
  , "grand-sigil"
  , "lissajous"
  , "pulse-ring"
  , "ring-fire"
  , "spiral-spark"
  , "square-burst"
  ]

allExamples :: [String]
allExamples = "gravity-well" : fieldlessExamples

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

dt :: FrameInput
dt = FrameInput (DeltaTime (1 / 60))

frameCount :: Int
frameCount = 240

loadCircleOf :: String -> IO Circle
loadCircleOf name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

castOf :: String -> IO ActiveSpell
castOf name = do
  circle <- loadCircleOf name
  either (fail . show) pure (castSpell (CastRequest circle ctx))

-- | Every row of every batch of one frame, as raw bits.
rowsOf :: FrameOutput -> [[Word32]]
rowsOf out = concatMap rows (map rbParticles (batches out))
  where
    rows :: ParticleBuffer -> [[Word32]]
    rows pb =
      [ [ castFloatToWord32 (pbPosX pb U.! i)
        , castFloatToWord32 (pbPosY pb U.! i)
        , castFloatToWord32 (pbPosZ pb U.! i)
        , castFloatToWord32 (pbSize pb U.! i)
        , castFloatToWord32 (pbLife pb U.! i)
        , pbColor pb U.! i
        ]
      | i <- [0 .. pbCount pb - 1]
      ]

-- | Fly a spell and record every frame's rows.
flight :: ActiveSpell -> [[[Word32]]]
flight = go frameCount
  where
    go k spell
      | k <= 0 = []
      | otherwise =
          let spell' = advanceSpell dt spell
           in rowsOf (observeSpell spell') : go (k - 1) spell'

fnv1a :: [Word32] -> Word64
fnv1a = foldl word 0xcbf29ce484222325
  where
    word h w = foldl byte h [(w `shiftR` s) .&. 0xFF | s <- [0, 8, 16, 24]]
    byte h b = (h `xor` fromIntegral b) * 0x100000001b3

spec :: Spec
spec = do
  describe "the superposition law (func-spec 0012 §1-5)" $ do
    mapM_ superposition (pairs fieldlessExamples)

  describe "composition does not disturb what already worked" $ do
    mapM_ singletonIdentity allExamples

    it "every example still fits under the raised cap, with room to compose" $
      mapM_
        ( \name -> do
            spell <- castOf name
            budgetTotal (budgetPlanOf spell) `shouldSatisfy` (<= maxSpellParticles)
        )
        allExamples

    it "and every frame of a composed flight is a legal buffer" $ do
      a <- loadCircleOf "grand-sigil"
      b <- loadCircleOf "ring-fire"
      composed <- either (fail . show) pure (castSpells [a, b] ctx)
      let go k spell
            | k <= 0 = pure ()
            | otherwise = do
                let spell' = advanceSpell dt spell
                mapM_
                  (\batch -> rbParticles batch `shouldSatisfy` bufferInvariant)
                  (batches (observeSpell spell'))
                go (k - 1 :: Int) spell'
      go frameCount composed

  describe "the two documented exceptions (ADR-0012)" $ do
    it "force fields fuse: a field circle moves a fieldless one's particles" $ do
      well <- loadCircleOf "gravity-well"
      fire <- loadCircleOf "ring-fire"
      fused <- either (fail . show) pure (castSpells [well, fire] ctx)
      apart <- either (fail . show) pure (castSpells [fire] ctx)
      let fusedRows = last (flight fused)
          apartRows = last (flight apart)
          tailRows = drop (length fusedRows - length apartRows) fusedRows
      length apartRows `shouldSatisfy` (> 0)
      length tailRows `shouldBe` length apartRows
      fnv1a (concat tailRows) `shouldNotBe` fnv1a (concat apartRows)

    it "the composed batch carries the first component's blend mode" $ do
      -- ring-fire is a fire circle (additive); pulse-ring is water (alpha).
      fire <- loadCircleOf "ring-fire"
      water <- loadCircleOf "pulse-ring"
      fireFirst <- either (fail . show) pure (castSpells [fire, water] ctx)
      waterFirst <- either (fail . show) pure (castSpells [water, fire] ctx)
      blendOf fireFirst `shouldBe` BlendAdditive
      blendOf waterFirst `shouldBe` BlendAlpha

  describe "the scene layer, end to end" $ do
    it "flies three spells under one quota for 240 frames, deterministically" $ do
      fire <- loadCircleOf "ring-fire"
      spark <- loadCircleOf "spiral-spark"
      well <- loadCircleOf "gravity-well"
      let run = do
            s0 <- pure (newScene (SceneConfig 10000))
            (_, s1) <- admit (castInto (CastRequest fire ctx) s0)
            (_, s2) <- admit (castInto (CastRequest spark ctx) s1)
            (idc, s3) <- admit (castManyInto [well, fire] ctx s2)
            let walk k scene acc
                  | k <= (0 :: Int) = pure (reverse acc)
                  | otherwise = do
                      let scene' = advanceScene dt (if k == 120 then dismiss idc scene else scene)
                          (used, cap') = sceneBudget scene'
                      used `shouldSatisfy` (<= cap')
                      walk (k - 1) scene' (fnv1a (concat (rowsOf (observeScene scene'))) : acc)
            walk frameCount s3 []
      left <- run
      right <- run
      left `shouldBe` right
      length (filter (/= fnv1a []) left) `shouldSatisfy` (> 100)

    it "and a scene that outlives its spells is empty and free again" $ do
      fire <- loadCircleOf "ring-fire"
      (_, scene) <- admit (castInto (CastRequest fire ctx) (newScene (SceneConfig 10000)))
      let flown = iterate (advanceScene dt) scene !! 3000
      sceneSpells flown `shouldBe` ([] :: [SpellId])
      sceneBudget flown `shouldBe` (0, 10000)
      batches (observeScene flown) `shouldBe` []

-- | The superposition law for one ordered pair of examples.
superposition :: (String, String) -> Spec
superposition (a, b) =
  it (a ++ " <> " ++ b ++ ": composed rows are the components' rows, concatenated") $ do
    ca <- loadCircleOf a
    cb <- loadCircleOf b
    composed <- either (fail . show) pure (castSpells [ca, cb] ctx)
    solo <- either (fail . show) pure (castSpells [ca] ctx)
    solo' <- either (fail . show) pure (castSpells [cb] ctx)
    let composedFrames = flight composed
        expected = zipWith (++) (flight solo) (flight solo')
    map (fnv1a . concat) composedFrames `shouldBe` map (fnv1a . concat) expected
    map length composedFrames `shouldBe` map length expected

-- | Casting one circle through the composition entry point must be the
-- single-circle path, frame for frame.
singletonIdentity :: String -> Spec
singletonIdentity name =
  it (name ++ ": castSpells [c] is castSpell c, for all 240 frames") $ do
    circle <- loadCircleOf name
    composed <- either (fail . show) pure (castSpells [circle] ctx)
    single <- either (fail . show) pure (castSpell (CastRequest circle ctx))
    flight composed `shouldBe` flight single

-- | Consecutive pairs plus a wrap-around, so every example takes part in
-- a composition without running all 81 combinations.
pairs :: [a] -> [(a, a)]
pairs xs = zip xs (drop 1 xs ++ take 1 xs)

blendOf :: ActiveSpell -> BlendMode
blendOf spell = case batches (observeSpell spell) of
  (batch : _) -> rbBlend batch
  [] -> error "acceptance fixture produced no batch"

admit :: (Show e) => Either e a -> IO a
admit = either (fail . show) pure
