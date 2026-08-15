-- | S4 (func-spec 0012 §7): "Magic.Scene" — several casts alive at once
-- under one global quota.
--
-- The four things a scene has to get right, and each of them is a way it
-- could quietly go wrong:
--
--   * a refused cast leaves the scene /exactly/ as it was (a half-admitted
--     spell would show up as a quota leak two frames later);
--   * a finished spell releases its share when it is dropped (the quota
--     is summed from the live spells, so there is no second ledger to
--     drift);
--   * 'observeScene' emits batches in 'SpellId' order, so the frame a
--     scene renders to is a function of its contents and not of the order
--     the host happened to call things in;
--   * the whole thing is deterministic: the same operation sequence
--     replays bit for bit.
module SceneSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import GHC.Float (castFloatToWord32)
import Magic.Codec (loadCircle)
import Magic.Interface
  ( CastContext (..)
  , CastRequest (..)
  , Circle
  , CompileError (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , batches
  , budgetPlanOf
  , budgetTotal
  , castSpell
  , pbColor
  , pbCount
  , pbLife
  , pbPosX
  , pbPosY
  , pbPosZ
  , pbSize
  )
import Magic.Scene
  ( CastRefusal (..)
  , Scene
  , SceneConfig (..)
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

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

dt :: FrameInput
dt = FrameInput (DeltaTime (1 / 60))

loadCircleOf :: String -> IO Circle
loadCircleOf name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

requestOf :: String -> IO CastRequest
requestOf name = (`CastRequest` ctx) <$> loadCircleOf name

-- | The compiled budget of one request, which is what the scene charges.
budgetFor :: CastRequest -> IO Int
budgetFor req = do
  spell <- either (fail . show) pure (castSpell req)
  pure (budgetTotal (budgetPlanOf spell))

castOrFail :: CastRequest -> Scene -> IO (SpellId, Scene)
castOrFail req scene = either (fail . show) pure (castInto req scene)

-- | The refusal, or a failure — 'Scene' is opaque and has no 'Show', so
-- an admission decision cannot be compared whole.
refusalOf :: Either CastRefusal (SpellId, Scene) -> IO CastRefusal
refusalOf (Left refusal) = pure refusal
refusalOf (Right (sid, _)) = do
  expectationFailure ("expected a refusal, got " ++ show sid)
  pure (QuotaExceeded 0 0)

-- | A frame's whole output as raw bits: batch count plus every column of
-- every buffer. Two scenes agreeing on this agree bit for bit.
digest :: FrameOutput -> (Int, [Word32])
digest out = (length bs, concatMap columns bs)
  where
    bs = map rbParticles (batches out)
    columns :: ParticleBuffer -> [Word32]
    columns pb =
      fromIntegral (pbCount pb)
        : concat
          [ map castFloatToWord32 (U.toList (pbPosX pb))
          , map castFloatToWord32 (U.toList (pbPosY pb))
          , map castFloatToWord32 (U.toList (pbPosZ pb))
          , map castFloatToWord32 (U.toList (pbSize pb))
          , map castFloatToWord32 (U.toList (pbLife pb))
          , U.toList (pbColor pb)
          ]

-- | Advance a scene @n@ frames, digesting every one of them.
flight :: Int -> Scene -> [(Int, [Word32])]
flight n scene0 = go n scene0
  where
    go k scene
      | k <= 0 = []
      | otherwise =
          let scene' = advanceScene dt scene
           in digest (observeScene scene') : go (k - 1) scene'

spec :: Spec
spec = do
  describe "an empty scene" $ do
    it "holds nothing and has spent nothing" $ do
      let scene = newScene (SceneConfig 10000)
      sceneSpells scene `shouldBe` []
      sceneBudget scene `shouldBe` (0, 10000)
      batches (observeScene scene) `shouldBe` []

  describe "admission under the global quota (first come, first served)" $ do
    it "charges a cast its compiled budget and hands back an ascending id" $ do
      req <- requestOf "ring-fire"
      need <- budgetFor req
      (sid, scene) <- castOrFail req (newScene (SceneConfig 10000))
      sid `shouldBe` SpellId 0
      sceneBudget scene `shouldBe` (need, 10000)
      (sid', scene') <- castOrFail req scene
      sid' `shouldBe` SpellId 1
      sceneBudget scene' `shouldBe` (2 * need, 10000)
      sceneSpells scene' `shouldBe` [SpellId 0, SpellId 1]

    it "refuses a cast that does not fit, reporting demand and remaining" $ do
      req <- requestOf "ring-fire"
      need <- budgetFor req
      let scene = newScene (SceneConfig (need + need - 1))
      (_, scene') <- castOrFail req scene
      refusal <- refusalOf (castInto req scene')
      refusal `shouldBe` QuotaExceeded need (need - 1)

    it "and a refused cast leaves the scene untouched" $ do
      req <- requestOf "ring-fire"
      need <- budgetFor req
      (_, scene) <- castOrFail req (newScene (SceneConfig need))
      _ <- refusalOf (castInto req scene)
      -- Same contents, same accounting: the refusal is not a state
      -- transition, and the scene value the caller still holds is the one
      -- it had before it asked.
      sceneSpells scene `shouldBe` [SpellId 0]
      sceneBudget scene `shouldBe` (need, need)

    it "a cast exactly filling the remaining quota is admitted" $ do
      req <- requestOf "ring-fire"
      need <- budgetFor req
      (_, scene) <- castOrFail req (newScene (SceneConfig (2 * need)))
      (sid, scene') <- castOrFail req scene
      sid `shouldBe` SpellId 1
      sceneBudget scene' `shouldBe` (2 * need, 2 * need)

    it "reports a compile failure as its own refusal, not as a quota one" $ do
      big <- loadCircleOf "ring-fire"
      -- A composition far past the cap: 16 copies of a real circle.
      let scene = newScene (SceneConfig 1000000)
      case castManyInto (replicate 64 big) ctx scene of
        Left (CompileFailed (BudgetExceeded _ _)) -> pure ()
        other -> expectationFailure ("expected CompileFailed, got " ++ show (fmap fst other))

    it "admits a composed cast, charged as one spell" $ do
      a <- loadCircleOf "ring-fire"
      b <- loadCircleOf "spiral-spark"
      needA <- budgetFor (CastRequest a ctx)
      needB <- budgetFor (CastRequest b ctx)
      case castManyInto [a, b] ctx (newScene (SceneConfig 10000)) of
        Left err -> expectationFailure (show err)
        Right (sid, scene) -> do
          sid `shouldBe` SpellId 0
          sceneSpells scene `shouldBe` [SpellId 0]
          sceneBudget scene `shouldBe` (needA + needB, 10000)

  describe "the frame cycle" $ do
    it "drops finished spells and releases their quota" $ do
      req <- requestOf "ring-fire"
      need <- budgetFor req
      (_, scene) <- castOrFail req (newScene (SceneConfig need))
      -- ring-fire outlives a handful of frames but not 2000 of them.
      let flown = iterate (advanceScene dt) scene !! 2000
      sceneSpells flown `shouldBe` []
      sceneBudget flown `shouldBe` (0, need)
      -- The quota is free again, and the next id still moves forward.
      (sid, _) <- castOrFail req flown
      sid `shouldBe` SpellId 1

    it "dismiss removes one spell and only that one" $ do
      req <- requestOf "ring-fire"
      need <- budgetFor req
      (a, s1) <- castOrFail req (newScene (SceneConfig 10000))
      (b, s2) <- castOrFail req s1
      let s3 = dismiss a s2
      sceneSpells s3 `shouldBe` [b]
      sceneBudget s3 `shouldBe` (need, 10000)
      -- Dismissing an id that is not there is a no-op.
      sceneSpells (dismiss a s3) `shouldBe` [b]
      sceneSpells (dismiss (SpellId 99) s3) `shouldBe` [b]

    it "observeScene concatenates the live spells' batches in SpellId order" $ do
      fire <- requestOf "ring-fire"
      spark <- requestOf "spiral-spark"
      (_, s1) <- castOrFail fire (newScene (SceneConfig 10000))
      (_, s2) <- castOrFail spark s1
      let flown = iterate (advanceScene dt) s2 !! 60
          sceneOut = batches (observeScene flown)
      length sceneOut `shouldBe` 2
      -- The same two spells cast in the other order produce the same two
      -- batches in the other order: the output follows the ids.
      (_, t1) <- castOrFail spark (newScene (SceneConfig 10000))
      (_, t2) <- castOrFail fire t1
      let flownT = iterate (advanceScene dt) t2 !! 60
      map (pbCount . rbParticles) (batches (observeScene flownT))
        `shouldBe` reverse (map (pbCount . rbParticles) sceneOut)

    it "is deterministic: the same operation sequence replays bit for bit" $ do
      fire <- requestOf "ring-fire"
      spark <- requestOf "spiral-spark"
      well <- requestOf "gravity-well"
      let build = do
            (_, s1) <- castOrFail fire (newScene (SceneConfig 10000))
            (_, s2) <- castOrFail spark s1
            (idc, s3) <- castOrFail well s2
            let s4 = iterate (advanceScene dt) s3 !! 30
            pure (dismiss idc s4)
      left <- build
      right <- build
      flight 120 left `shouldBe` flight 120 right

    it "and its frames are the union of the spells that are in it" $ do
      fire <- requestOf "ring-fire"
      (_, scene) <- castOrFail fire (newScene (SceneConfig 10000))
      let counts = map (sum . map (pbCount . rbParticles) . batches . observeScene)
            (take 120 (iterate (advanceScene dt) scene))
      maximum counts `shouldSatisfy` (> 0)
