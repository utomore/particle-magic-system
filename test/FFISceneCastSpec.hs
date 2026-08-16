-- | S3 (func-spec 0018 §7): admission and observation across the C
-- boundary.
--
-- The three entry points that carry the round's actual content, each
-- checked against the pure function it is supposed to be a type crossing
-- of:
--
--   * @pm_scene_cast@ classifies exactly what 'castInto' classifies —
--     including the new 'pmErrQuota', which is the one code a host can
--     act on (dismiss something and retry) rather than only report;
--   * a refusal changes /nothing/: all three scene queries answer the
--     same after it as before, because 'castInto' hands the caller's own
--     scene back and the cell is never written;
--   * @pm_scene_observe@ is 'observeScene' bit for bit — the same six
--     columns, the same @batch_info@, the same all-or-nothing capacity
--     rule, with no hint of which spell a batch came from (func-spec
--     0018 §0.3).
module FFISceneCastSpec
  ( spec

    -- * Shared with "Acceptance18Spec"
  , mismatch
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.List (isInfixOf)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import FFIHarness
  ( Observed (..)
  , floatSentinel
  , guardSlots
  , intSentinel
  , spellBytes
  , testCtx
  , wordSentinel
  )
import FFISceneSpec
  ( CastOutcome (..)
  , exampleBudget
  , sceneCast
  , sceneCastMany
  , sceneCastOk
  , sceneBudgetOf
  , sceneIds
  , sceneObserve
  , withSceneHandle
  )
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CFloat (..), CInt)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (withArray)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.StablePtr (StablePtr)
import GHC.Float (float2Double)
import Magic.Codec (loadCircle)
import Magic.FFI
  ( SceneCell
  , pm_scene_advance
  , pm_scene_cast
  , pm_scene_cast_many
  , pm_scene_count
  , pmErrArgs
  , pmErrBudget
  , pmErrCapacity
  , pmErrJson
  , pmErrQuota
  , pmOk
  , refusalCode
  )
import Magic.Interface
  ( BillboardShape (..)
  , BlendMode (..)
  , CastContext
  , CastRequest (..)
  , Circle
  , CompileError (..)
  , DeltaTime (..)
  , FrameInput (..)
  , ParticleBuffer (pbColor, pbCount, pbLife, pbPosX, pbPosY, pbPosZ, pbSize)
  , RenderBatch (..)
  , batches
  )
import Magic.Scene
  ( CastRefusal (..)
  , Scene
  , SceneConfig (..)
  , advanceScene
  , castInto
  , castManyInto
  , newScene
  , observeScene
  )
import Test.Hspec

-- | Not a circle at all.
badSyntax :: BS.ByteString
badSyntax = BS8.pack "{ \"version\": 1, \"circle\": { "

-- | Decodes fine and then asks for 80 × 256 = 20480 particles, past the
-- core's own cap — so it fails to /compile/, which is a different refusal
-- from failing to fit a scene (func-spec 0009's fixture, reused).
overBudget :: BS.ByteString
overBudget =
  BS8.pack
    "{ \"version\": 1, \"circle\": { \"core\": { \"center\": { \"element\": \"fire\", \"power\": 80.0 } } } }"

spec :: Spec
spec = describe "scene casting over the C ABI (func-spec 0018 §7 S3)" $ do
  describe "classification agrees with castInto" $ do
    it "answers PM_ERR_JSON for something that is not a circle" $
      withSceneHandle 16384 $ \sc -> do
        outcome <- sceneCast sc badSyntax testCtx
        coCode outcome `shouldBe` pmErrJson
        coMessage outcome `shouldSatisfy` isInfixOf "spell"
        -- ... and the reference path never even reaches castInto
        loadCircle badSyntax `shouldSatisfy` isLeft

    it "answers PM_ERR_BUDGET for a circle the core refuses to compile" $
      withSceneHandle 16384 $ \sc -> do
        outcome <- sceneCast sc overBudget testCtx
        coCode outcome `shouldBe` pmErrBudget
        refusalOf 16384 overBudget `shouldSatisfy` isCompileFailed
        coMessage outcome `shouldSatisfy` isInfixOf "20480"

    it "answers PM_ERR_QUOTA when the spell compiles but the scene is full" $ do
      bytes <- spellBytes "ring-fire"
      other <- spellBytes "spiral-spark"
      let cap = exampleBudget bytes
      withSceneHandle cap $ \sc -> do
        _ <- sceneCastOk sc bytes testCtx
        outcome <- sceneCast sc other testCtx
        coCode outcome `shouldBe` pmErrQuota
        coId outcome `shouldBe` (-1)

    it "maps every CastRefusal constructor to the code it is documented as" $ do
      refusalCode (CompileFailed (BudgetExceeded 20480 16384)) `shouldBe` pmErrBudget
      refusalCode (QuotaExceeded 10 3) `shouldBe` pmErrQuota
      -- the two are genuinely distinct, which is the whole reason
      -- PM_ERR_QUOTA was added rather than reusing PM_ERR_BUDGET
      pmErrQuota `shouldNotBe` pmErrBudget

    it "answers PM_ERR_ARGS for a NULL out_id" $
      withSceneHandle 16384 $ \sc -> do
        bytes <- spellBytes "ring-fire"
        code <- withNullOutId sc bytes
        code `shouldBe` pmErrArgs

    it "answers PM_ERR_ARGS for a negative count or a NULL circle array" $
      withSceneHandle 16384 $ \sc -> do
        negative <- castManyRaw sc nullPtr (-1)
        negative `shouldBe` pmErrArgs
        missing <- castManyRaw sc nullPtr 2
        missing `shouldBe` pmErrArgs

  it "reports both of the quota's numbers in err_buf" $ do
    bytes <- spellBytes "ring-fire"
    let cap = exampleBudget bytes
    withSceneHandle cap $ \sc -> do
      _ <- sceneCastOk sc bytes testCtx
      outcome <- sceneCast sc bytes testCtx
      -- `need` is the one thing pm_scene_budget cannot tell the host
      -- afterwards, so it has to survive in the text (func-spec 0018 §8-2)
      coMessage outcome `shouldSatisfy` isInfixOf (show cap)
      coMessage outcome `shouldSatisfy` isInfixOf "0 left"

  it "leaves the scene untouched on every refusal path" $ do
    bytes <- spellBytes "ring-fire"
    let cap = exampleBudget bytes
    withSceneHandle cap $ \sc -> do
      sid <- sceneCastOk sc bytes testCtx
      before <- snapshot sc
      quota <- sceneCast sc bytes testCtx
      json <- sceneCast sc badSyntax testCtx
      compileFail <- sceneCast sc overBudget testCtx
      map coCode [quota, json, compileFail] `shouldBe` [pmErrQuota, pmErrJson, pmErrBudget]
      after <- snapshot sc
      after `shouldBe` before
      -- the survivor is still the one that was admitted
      snd3 before `shouldBe` [sid]

  describe "cast_many is castManyInto" $ do
    it "admits a composition as one spell with one share of the quota" $ do
      ring <- spellBytes "ring-fire"
      spark <- spellBytes "spiral-spark"
      withSceneHandle 16384 $ \sc -> do
        outcome <- sceneCastMany sc [ring, spark] testCtx
        coCode outcome `shouldBe` pmOk
        (_, used, _) <- sceneBudgetOf sc
        let expected = exampleBudget ring + exampleBudget spark
        used `shouldBe` fromIntegral expected
        (code, ids) <- sceneIds sc 4
        code `shouldBe` 1 -- one spell, not two
        take 1 ids `shouldBe` [coId outcome]

    it "samples exactly what castManyInto samples" $ do
      ring <- spellBytes "ring-fire"
      spark <- spellBytes "spiral-spark"
      withSceneHandle 16384 $ \sc -> do
        outcome <- sceneCastMany sc [ring, spark] testCtx
        coCode outcome `shouldBe` pmOk
        obs <- sceneObserve sc 16384 32
        obs `shouldMatch` referenceMany 16384 [ring, spark] testCtx

    it "casts the empty composition, which costs nothing" $
      withSceneHandle 16384 $ \sc -> do
        outcome <- sceneCastMany sc [] testCtx
        coCode outcome `shouldBe` pmOk
        coId outcome `shouldBe` 0
        (_, used, _) <- sceneBudgetOf sc
        used `shouldBe` 0
        obs <- sceneObserve sc 16384 32
        obCode obs `shouldBe` 0

    it "refuses the whole composition when one circle does not decode" $ do
      ring <- spellBytes "ring-fire"
      withSceneHandle 16384 $ \sc -> do
        outcome <- sceneCastMany sc [ring, badSyntax] testCtx
        coCode outcome `shouldBe` pmErrJson
        (_, used, _) <- sceneBudgetOf sc
        used `shouldBe` 0

  describe "observe is observeScene" $ do
    it "matches the pure path bit for bit, over a whole flight" $ do
      ring <- spellBytes "ring-fire"
      spark <- spellBytes "spiral-spark"
      withSceneHandle 16384 $ \sc -> do
        _ <- sceneCastOk sc ring testCtx
        _ <- sceneCastOk sc spark testCtx
        let reference = referenceTwo 16384 [ring, spark] testCtx
        mapM_
          (\ref -> do
              obs <- sceneObserve sc 16384 32
              obs `shouldMatch` ref
              pm_scene_advance sc (CFloat hostDt))
          (take 60 (iterate (advanceScene frame) reference))

    it "concatenates in spell-id order, never merging across spells" $ do
      ring <- spellBytes "ring-fire"
      withSceneHandle 16384 $ \sc -> do
        _ <- sceneCastOk sc ring testCtx
        one <- sceneObserve sc 16384 32
        _ <- sceneCastOk sc ring testCtx
        two <- sceneObserve sc 16384 32
        -- the same spell twice: the second observation is the first's
        -- batch list, doubled, not fused into one wider batch
        obCode two `shouldBe` 2 * obCode one
        let n = fromIntegral (obCode one)
        infoOf n two `shouldBe` infoOf n one

    it "refuses a short column and writes nothing at all" $ do
      ring <- spellBytes "ring-fire"
      withSceneHandle 16384 $ \sc -> do
        _ <- sceneCastOk sc ring testCtx
        -- particles are born over time, so a freshly cast scene has
        -- nothing to overflow with
        mapM_ (\_ -> pm_scene_advance sc (CFloat hostDt)) [1 :: Int .. 60]
        full <- sceneObserve sc 16384 32
        let total = totalOf full
        total `shouldSatisfy` (> 0)
        short <- sceneObserve sc (total - 1) 32
        obCode short `shouldBe` pmErrCapacity
        obPosX short `shouldBe` replicate (total - 1 + guardSlots) floatSentinel
        obColor short `shouldBe` replicate (total - 1 + guardSlots) wordSentinel
        obInfo short `shouldBe` replicate (4 * 32 + guardSlots) intSentinel

    it "refuses a short batch_info array and writes nothing at all" $ do
      ring <- spellBytes "ring-fire"
      withSceneHandle 16384 $ \sc -> do
        _ <- sceneCastOk sc ring testCtx
        _ <- sceneCastOk sc ring testCtx
        full <- sceneObserve sc 16384 32
        let nBatches = fromIntegral (obCode full)
        nBatches `shouldSatisfy` (> 1)
        short <- sceneObserve sc 16384 (nBatches - 1)
        obCode short `shouldBe` pmErrCapacity
        obInfo short `shouldBe` replicate (4 * (nBatches - 1) + guardSlots) intSentinel

-- Reference path --------------------------------------------------------------

-- | One frame of the reference clock. The dt is widened from @float@
-- exactly as the C ABI widens it: @1\/60 :: Double@ and
-- @float2Double (1\/60 :: Float)@ are different numbers, and the law
-- compares bit patterns, so the reference has to take the host's rounding
-- rather than its own.
frame :: FrameInput
frame = FrameInput (DeltaTime (float2Double hostDt))

hostDt :: Float
hostDt = 1 / 60

-- | The scene a host would have built through 'Magic.Interface' alone.
referenceTwo :: Int -> [BS.ByteString] -> CastContext -> Scene
referenceTwo cap chunks ctx = foldl admit (newScene (SceneConfig cap)) chunks
  where
    admit scene bytes =
      case castInto CastRequest {circleOf = circleOf' bytes, ctxOf = ctx} scene of
        Left refusal -> error ("reference cast refused: " ++ show refusal)
        Right (_, scene') -> scene'

-- | The same for the composition entry point.
referenceMany :: Int -> [BS.ByteString] -> CastContext -> Scene
referenceMany cap chunks ctx =
  case castManyInto (map circleOf' chunks) ctx (newScene (SceneConfig cap)) of
    Left refusal -> error ("reference composition refused: " ++ show refusal)
    Right (_, scene') -> scene'

circleOf' :: BS.ByteString -> Circle
circleOf' bytes = case loadCircle bytes of
  Left err -> error ("reference load failed: " ++ show err)
  Right circle -> circle

-- | What 'castInto' answers for a single circle in a fresh scene, so a
-- spec can state "the C code is this classification" rather than assume it.
refusalOf :: Int -> BS.ByteString -> Either CastRefusal ()
refusalOf cap bytes = case loadCircle bytes of
  Left err -> error ("reference load failed: " ++ show err)
  Right circle ->
    either Left (const (Right ())) $
      castInto CastRequest {circleOf = circle, ctxOf = testCtx} (newScene (SceneConfig cap))

-- | @pm_scene_observe@'s output equals 'observeScene''s, in the six
-- columns, the batch descriptors and the returned batch count.
shouldMatch :: Observed -> Scene -> Expectation
shouldMatch obs scene = case mismatch obs scene of
  Nothing -> pure ()
  Just why -> expectationFailure ("pm_scene_observe differs from observeScene: " ++ why)

-- | Where the two paths differ, if anywhere. Pure and total, so
-- "Acceptance18Spec" can carry it into a QuickCheck counterexample
-- instead of an exception.
mismatch :: Observed -> Scene -> Maybe String
mismatch obs scene
  | obCode obs /= fromIntegral n = disagree "batch count" (obCode obs) (fromIntegral n)
  | total /= expected = disagree "particle total" total expected
  | otherwise = firstDifference
  where
    bs = batches (observeScene scene)
    n = length bs
    total = totalOf obs
    expected = sum (map (pbCount . rbParticles) bs)
    column f = concatMap (U.toList . f . rbParticles) bs
    disagree what a b = Just (what ++ ": " ++ show a ++ " vs " ++ show b)
    firstDifference =
      case [why | (why, differs) <- checks, differs] of
        [] -> Nothing
        (why : _) -> Just why
    checks =
      [ ("pos_x", take total (obPosX obs) /= column pbPosX)
      , ("pos_y", take total (obPosY obs) /= column pbPosY)
      , ("pos_z", take total (obPosZ obs) /= column pbPosZ)
      , ("size", take total (obSize obs) /= column pbSize)
      , ("life", take total (obLife obs) /= column pbLife)
      , ("color", take total (obColor obs) /= (column pbColor :: [Word32]))
      , ("batch_info", infoOf n obs /= referenceInfo bs)
      ]

-- | The batch descriptors the C side must produce for these batches:
-- @(offset, count, blend, shape)@.
referenceInfo :: [RenderBatch] -> [(Int, Int, Int, Int)]
referenceInfo bs =
  [ (off, pbCount (rbParticles b), blendWire (rbBlend b), shapeWire (rbShape b))
  | (off, b) <- zip (scanl (+) 0 (map (pbCount . rbParticles) bs)) bs
  ]

blendWire :: BlendMode -> Int
blendWire BlendAlpha = 0
blendWire BlendAdditive = 1

shapeWire :: BillboardShape -> Int
shapeWire BillboardSquare = 0
shapeWire BillboardSoftDot = 1
shapeWire BillboardRing = 2
shapeWire BillboardSpark = 3

-- Reading the harness's buffers -----------------------------------------------

infoOf :: Int -> Observed -> [(Int, Int, Int, Int)]
infoOf n obs =
  [ (at (4 * i), at (4 * i + 1), at (4 * i + 2), at (4 * i + 3))
  | i <- [0 .. n - 1]
  ]
  where
    at i = fromIntegral (obInfo obs !! i)

totalOf :: Observed -> Int
totalOf obs = sum [c | (_, c, _, _) <- infoOf (max 0 (fromIntegral (obCode obs))) obs]

-- | The three scene queries at once — the whole observable state a
-- refusal must leave alone.
snapshot :: StablePtr SceneCell -> IO (CInt, [CInt], (CInt, CInt, CInt))
snapshot sc = do
  n <- pm_scene_count sc
  (_, ids) <- sceneIds sc (fromIntegral n)
  budget <- sceneBudgetOf sc
  pure (n, take (fromIntegral n) ids, budget)

-- Calls the harness deliberately cannot make (it always provides the
-- pointers), so they are spelled out here ------------------------------------

-- | @pm_scene_cast@ with @out_id@ @NULL@: a host that forgot the one
-- output it asked for.
withNullOutId :: StablePtr SceneCell -> BS.ByteString -> IO CInt
withNullOutId sc bytes =
  withCStringBytes bytes $ \json ->
    allocaBytes 256 $ \err ->
      pm_scene_cast sc json nullPtr nullPtr 0 err 256 nullPtr

-- | @pm_scene_cast_many@ with a raw array pointer and count, so a @NULL@
-- array and a negative count can both be handed over.
castManyRaw :: StablePtr SceneCell -> Ptr CString -> CInt -> IO CInt
castManyRaw sc arr count =
  allocaBytes 256 $ \err ->
    alloca $ \outId ->
      pm_scene_cast_many sc arr count nullPtr nullPtr 0 err 256 outId

withCStringBytes :: BS.ByteString -> (CString -> IO a) -> IO a
withCStringBytes bytes =
  withArray (map fromIntegral (BS.unpack bytes) ++ [0] :: [CChar])

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

isCompileFailed :: Either CastRefusal () -> Bool
isCompileFailed (Left (CompileFailed _)) = True
isCompileFailed _ = False

snd3 :: (a, b, c) -> b
snd3 (_, b, _) = b
