-- | S5 (func-spec 0009 §8): the cross-boundary determinism law, and the
-- acceptance run for the FFI round.
--
-- ADR-0011 D8 states it as an equivalence, not a promise: for the same
-- @(json, pos, facing, seed, dt sequence)@ the C path and the
-- 'Magic.Interface' path produce bit-identical output. That is the whole
-- claim of the round — the FFI shell adds no semantics of its own — so it
-- is checked frame by frame over a full 120-frame flight, on every shipped
-- example, with an irregular dt cadence a real host would produce.
module Acceptance9Spec (spec) where

import qualified Data.ByteString as BS
import Data.List (nub)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import FFIHarness
  ( Observed (..)
  , batchTuples
  , castOk
  , observeRaw
  , referenceSpell
  , spellBytes
  , testCtx
  )
import Foreign.C.Types (CDouble (..), CFloat (..))
import GHC.Float (float2Double)
import Magic.FFI (pm_advance, pm_age, pm_free, pm_is_finished, pmMaxParticles)
import Magic.Interface
  ( ActiveSpell
  , BillboardShape (..)
  , BlendMode (..)
  , CastContext (..)
  , DeltaTime (..)
  , FrameInput (..)
  , ParticleBuffer (pbColor, pbCount, pbLife, pbPosX, pbPosY, pbPosZ, pbSize)
  , RenderBatch (..)
  , Seed (..)
  , Time (..)
  , advanceSpell
  , batches
  , isFinished
  , observeSpell
  , spellAge
  )
import Test.Hspec

-- | 120 frames of a host that is not perfectly regular: 60Hz with the
-- occasional dropped frame and a couple of long hitches.
cadence :: [Float]
cadence = take 120 (cycle [1 / 60, 1 / 60, 1 / 60, 1 / 30, 0.008, 0.05])

-- | What one frame looks like on either side of the boundary.
data Frame = Frame
  { frAge :: Double
  , frFinished :: Bool
  , frBatches :: [(Int, Int, Int, Int)]
  , frPosX :: [Float]
  , frPosY :: [Float]
  , frPosZ :: [Float]
  , frSize :: [Float]
  , frLife :: [Float]
  , frColor :: [Word32]
  }
  deriving (Eq, Show)

examples :: [String]
examples =
  [ "empty"
  , "bare-sigil"
  , "ring-fire"
  , "spiral-spark"
  , "pulse-ring"
  , "lissajous"
  , "square-burst"
  , "grand-sigil"
  , "converge-flame"
  ]

spec :: Spec
spec = describe "cross-boundary determinism (func-spec 0009 §8 S5)" $ do
  it "matches the Haskell path frame by frame, for every shipped example" $
    mapM_ pathsAgree examples

  it "actually simulates something (the law would be vacuous otherwise)" $ do
    bytes <- spellBytes "ring-fire"
    frames <- ffiRun bytes
    -- particles are born ...
    maximum (map (length . frPosX) frames) `shouldSatisfy` (> 100)
    -- ... and move: almost every frame differs from the one before it
    length (nub (map frPosX frames)) `shouldSatisfy` (> length frames `div` 2)
    -- ... and the clock really advances
    frAge (last frames) `shouldSatisfy` (> 2)

  it "replays: two handles from the same JSON produce the same 120 frames" $ do
    bytes <- spellBytes "grand-sigil"
    first <- ffiRun bytes
    second <- ffiRun bytes
    first `shouldBe` second

  it "keeps observing legally after the spell has finished" $ do
    bytes <- spellBytes "ring-fire"
    handle <- castOk bytes testCtx
    mapM_ (\_ -> pm_advance handle (CFloat 0.5)) [1 :: Int .. 40]
    finished <- pm_is_finished handle
    finished `shouldBe` 1
    obs <- observeRaw handle (fromIntegral pmMaxParticles) 8
    pm_free handle
    obs `shouldSatisfy` (\o -> obCode o >= 0)
    let n = fromIntegral (obCode obs)
        reference = referenceAfter bytes (replicate 40 0.5)
    batchTuples n obs `shouldBe` referenceBatches reference
    sum [c | (_, c, _, _) <- batchTuples n obs] `shouldBe` 0

  it "carries the seed across the boundary (a different seed differs)" $ do
    bytes <- spellBytes "spiral-spark"
    a <- runWith bytes testCtx
    b <- runWith bytes testCtx {seed = Seed 999}
    a `shouldNotBe` b

-- | The law: same input, same output, every frame.
pathsAgree :: String -> Expectation
pathsAgree name = do
  bytes <- spellBytes name
  actual <- ffiRun bytes
  let expected = referenceRun bytes testCtx
  case [i | (i, x, y) <- zip3 [0 :: Int ..] actual expected, x /= y] of
    [] -> length actual `shouldBe` length expected
    (i : _) ->
      expectationFailure
        ( name
            ++ ": frame "
            ++ show i
            ++ " differs across the boundary\n  FFI:       "
            ++ show (actual !! i)
            ++ "\n  reference: "
            ++ show (expected !! i)
        )

-- | Drive the C ABI for the whole cadence, capturing every frame.
ffiRun :: BS.ByteString -> IO [Frame]
ffiRun bytes = runWith bytes testCtx

runWith :: BS.ByteString -> CastContext -> IO [Frame]
runWith bytes ctx = do
  handle <- castOk bytes ctx
  frames <- traverse (frameOf handle) cadence
  pm_free handle
  pure frames
  where
    frameOf handle dt = do
      pm_advance handle (CFloat dt)
      CDouble age <- pm_age handle
      finished <- pm_is_finished handle
      obs <- observeRaw handle (fromIntegral pmMaxParticles) 8
      let n = fromIntegral (obCode obs)
          total = sum [c | (_, c, _, _) <- batchTuples n obs]
      pure
        Frame
          { frAge = age
          , frFinished = finished /= 0
          , frBatches = batchTuples n obs
          , frPosX = take total (obPosX obs)
          , frPosY = take total (obPosY obs)
          , frPosZ = take total (obPosZ obs)
          , frSize = take total (obSize obs)
          , frLife = take total (obLife obs)
          , frColor = take total (obColor obs)
          }

-- | The same cadence through 'Magic.Interface' alone.
referenceRun :: BS.ByteString -> CastContext -> [Frame]
referenceRun bytes ctx =
  map frameOf (drop 1 (scanl advance (referenceSpell bytes ctx) cadence))
  where
    advance spell dt = advanceSpell (FrameInput (DeltaTime (float2Double dt))) spell
    frameOf spell =
      let bs = batches (observeSpell spell)
          buffers = map rbParticles bs
          column f = concatMap (U.toList . f) buffers
          Time age = spellAge spell
       in Frame
            { frAge = age
            , frFinished = isFinished spell
            , frBatches = referenceBatchesOf bs
            , frPosX = column pbPosX
            , frPosY = column pbPosY
            , frPosZ = column pbPosZ
            , frSize = column pbSize
            , frLife = column pbLife
            , frColor = column pbColor
            }

referenceAfter :: BS.ByteString -> [Float] -> ActiveSpell
referenceAfter bytes = foldl advance (referenceSpell bytes testCtx)
  where
    advance spell dt = advanceSpell (FrameInput (DeltaTime (float2Double dt))) spell

referenceBatches :: ActiveSpell -> [(Int, Int, Int, Int)]
referenceBatches = referenceBatchesOf . batches . observeSpell

-- | The batch descriptors the C side must produce for these batches.
referenceBatchesOf :: [RenderBatch] -> [(Int, Int, Int, Int)]
referenceBatchesOf bs =
  [ (off, pbCount (rbParticles b), blendWire (rbBlend b), shapeWire (rbShape b))
  | (off, b) <- zip offsets bs
  ]
  where
    offsets = scanl (+) 0 (map (pbCount . rbParticles) bs)

blendWire :: BlendMode -> Int
blendWire BlendAlpha = 0
blendWire BlendAdditive = 1

shapeWire :: BillboardShape -> Int
shapeWire BillboardSquare = 0
shapeWire BillboardSoftDot = 1
shapeWire BillboardRing = 2
shapeWire BillboardSpark = 3
shapeWire BillboardTrail = 4
