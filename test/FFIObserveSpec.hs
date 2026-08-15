-- | S2 (func-spec 0009 §8): @pm_observe@'s copy-out and batch segments.
--
-- Copying is structurally forced (ADR-0011 D3: unboxed vectors have no
-- pointer interface), so the thing that can go wrong is the copy itself —
-- a column written at the wrong offset, a batch descriptor that disagrees
-- with the segment it describes, or a capacity check that fires after the
-- first poke and leaves the host with half a frame. Each of those is a
-- case below, over every shipped example at several ages.
module FFIObserveSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import FFIHarness
  ( Observed (..)
  , batchTuples
  , castOk
  , floatSentinel
  , intSentinel
  , observeRaw
  , referenceAt
  , referenceSpell
  , spellBytes
  , testCtx
  , wordSentinel
  )
import Foreign.C.Types (CFloat (..))
import Magic.FFI (pm_advance, pm_free, pmErrCapacity, pmMaxParticles)
import Magic.Interface
  ( ActiveSpell
  , BillboardShape (..)
  , BlendMode (..)
  , ParticleBuffer (pbColor, pbCount, pbLife, pbPosX, pbPosY, pbPosZ, pbSize)
  , RenderBatch (..)
  , batches
  , observeSpell
  )
import Test.Hspec
import Test.QuickCheck

-- | The examples, and the frame counts each is observed at: 0 (before the
-- first birth), mid-flight, and past the emission window.
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

frameCounts :: [Int]
frameCounts = [0, 1, 30, 90, 200]

dt :: Float
dt = 1 / 60

spec :: Spec
spec = describe "pm_observe copy-out (func-spec 0009 §8 S2)" $ do
  it "reproduces observeSpell's buffers column by column, at every age" $
    mapM_ (\name -> mapM_ (matchesReference name) frameCounts) examples

  it "describes each batch by the segment it actually wrote" $ do
    bytes <- spellBytes "grand-sigil"
    (obs, reference) <- observeAfter bytes 120 (fromIntegral pmMaxParticles) 8
    let refBatches = batches (observeSpell reference)
        counts = map (pbCount . rbParticles) refBatches
        offsets = scanl (+) 0 counts
        expected =
          [ (off, n, blendWire (rbBlend b), shapeWire (rbShape b))
          | (off, n, b) <- zip3 offsets counts refBatches
          ]
    obCode obs `shouldBe` fromIntegral (length refBatches)
    batchTuples (length refBatches) obs `shouldBe` expected

  it "writes nothing outside the capacity it was handed" $ do
    bytes <- spellBytes "ring-fire"
    (obs, reference) <- observeAfter bytes 120 (fromIntegral pmMaxParticles) 8
    let written = totalParticles reference
        tailOf = drop written
    -- everything past the last particle, guard slots included, is untouched
    tailOf (obPosX obs) `shouldSatisfy` all (== floatSentinel)
    tailOf (obPosY obs) `shouldSatisfy` all (== floatSentinel)
    tailOf (obPosZ obs) `shouldSatisfy` all (== floatSentinel)
    tailOf (obSize obs) `shouldSatisfy` all (== floatSentinel)
    tailOf (obLife obs) `shouldSatisfy` all (== floatSentinel)
    tailOf (obColor obs) `shouldSatisfy` all (== wordSentinel)
    drop (4 * length (batches (observeSpell reference))) (obInfo obs)
      `shouldSatisfy` all (== intSentinel)

  it "refuses a short buffer with PM_ERR_CAPACITY and writes nothing at all" $ do
    bytes <- spellBytes "ring-fire"
    (full, reference) <- observeAfter bytes 120 (fromIntegral pmMaxParticles) 8
    let written = totalParticles reference
    written `shouldSatisfy` (> 1)
    obCode full `shouldSatisfy` (> 0)
    (short, _) <- observeAfter bytes 120 (written - 1) 8
    obCode short `shouldBe` pmErrCapacity
    short `shouldSatisfy` untouched

  it "refuses too few batch slots with PM_ERR_CAPACITY, also writing nothing" $ do
    bytes <- spellBytes "ring-fire"
    (obs, _) <- observeAfter bytes 120 (fromIntegral pmMaxParticles) 0
    obCode obs `shouldBe` pmErrCapacity
    obs `shouldSatisfy` untouched

  it "accepts a zero-capacity call while the spell has no live particles" $ do
    bytes <- spellBytes "ring-fire"
    (obs, reference) <- observeAfter bytes 0 0 4
    totalParticles reference `shouldBe` 0
    obCode obs `shouldBe` 1
    batchTuples 1 obs `shouldBe` [(0, 0, blendWire (batchBlend reference), shapeWire (batchShape reference))]

  it "is idempotent: observing twice without advancing gives the same bytes" $ do
    bytes <- spellBytes "spiral-spark"
    handle <- castOk bytes testCtx
    mapM_ (\_ -> pm_advance handle (CFloat dt)) [1 :: Int .. 100]
    first <- observeRaw handle (fromIntegral pmMaxParticles) 8
    second <- observeRaw handle (fromIntegral pmMaxParticles) 8
    pm_free handle
    first `shouldBe` second

  it "matches the reference at an arbitrary frame count (property)" $
    property $ \(NonNegative n) ->
      n <= 400 ==> ioProperty (matchesReference "pulse-ring" n >> pure True)

-- | Advance @n@ frames, then observe through both paths and compare all
-- six columns element by element.
matchesReference :: String -> Int -> IO ()
matchesReference name n = do
  bytes <- spellBytes name
  (obs, reference) <- observeAfter bytes n (fromIntegral pmMaxParticles) 8
  let refBatches = batches (observeSpell reference)
      buffers = map rbParticles refBatches
      column f = concatMap (U.toList . f) buffers
      written = sum (map pbCount buffers)
      what field = name ++ " @" ++ show n ++ " frames: " ++ field
  obCode obs `shouldBe` fromIntegral (length refBatches)
  labelled (what "pos.x") (take written (obPosX obs)) (column pbPosX)
  labelled (what "pos.y") (take written (obPosY obs)) (column pbPosY)
  labelled (what "pos.z") (take written (obPosZ obs)) (column pbPosZ)
  labelled (what "size") (take written (obSize obs)) (column pbSize)
  labelled (what "life") (take written (obLife obs)) (column pbLife)
  labelledW (what "color") (take written (obColor obs)) (column pbColor)

labelled :: String -> [Float] -> [Float] -> Expectation
labelled what actual expected =
  if actual == expected then pure () else expectationFailure (what ++ " differs")

labelledW :: String -> [Word32] -> [Word32] -> Expectation
labelledW what actual expected =
  if actual == expected then pure () else expectationFailure (what ++ " differs")

-- | Cast, advance @n@ frames, observe with the given host capacities, and
-- hand back both the raw C-side result and the reference spell at the same
-- age.
observeAfter :: BS.ByteString -> Int -> Int -> Int -> IO (Observed, ActiveSpell)
observeAfter bytes n capacity maxBatches = do
  handle <- castOk bytes testCtx
  mapM_ (\_ -> pm_advance handle (CFloat dt)) [1 .. n]
  obs <- observeRaw handle capacity maxBatches
  pm_free handle
  pure (obs, referenceAfter bytes n)

-- | The reference spell after @n@ frames of the same dt.
referenceAfter :: BS.ByteString -> Int -> ActiveSpell
referenceAfter bytes n = referenceAt (referenceSpell bytes testCtx) (replicate n dt)

totalParticles :: ActiveSpell -> Int
totalParticles = sum . map (pbCount . rbParticles) . batches . observeSpell

-- | Blend and shape of the spell's first batch. 'observeSpell' always
-- returns at least one batch; a round where it does not is worth failing
-- loudly on.
batchBlend :: ActiveSpell -> BlendMode
batchBlend spell = case batches (observeSpell spell) of
  (b : _) -> rbBlend b
  [] -> error "observeSpell returned no batches"

batchShape :: ActiveSpell -> BillboardShape
batchShape spell = case batches (observeSpell spell) of
  (b : _) -> rbShape b
  [] -> error "observeSpell returned no batches"

-- | The wire codes the header declares (PM_BLEND_*, PM_SHAPE_*), written
-- out independently here so a change to 'Magic.FFI.blendCode' has to be
-- deliberate.
blendWire :: BlendMode -> Int
blendWire BlendAlpha = 0
blendWire BlendAdditive = 1

shapeWire :: BillboardShape -> Int
shapeWire BillboardSquare = 0
shapeWire BillboardSoftDot = 1
shapeWire BillboardRing = 2
shapeWire BillboardSpark = 3

-- | Nothing was written: every slot still holds its sentinel.
untouched :: Observed -> Bool
untouched obs =
  all (all (== floatSentinel)) [obPosX obs, obPosY obs, obPosZ obs, obSize obs, obLife obs]
    && all (== wordSentinel) (obColor obs)
    && all (== intSentinel) (obInfo obs)
