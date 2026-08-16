-- | S2 (func-spec 0018 §7): the scene handle and everything around a
-- cast — lifecycle, the two queries, dismissal and the frame advance.
--
-- These are the entry points where a C ABI usually goes wrong, and they
-- go wrong /silently/: a @NULL@ handle that dereferences, a capacity
-- error that has already scribbled over half the host's array, a quota
-- that never comes back when a spell ends. None of those show up as a
-- Haskell type error, so each is asserted here directly, with every
-- buffer over-allocated and sentinel-filled so "nothing was written"
-- is a checkable claim rather than an assumption.
--
-- The scene marshalling helpers live here and are shared with
-- "FFISceneCastSpec" and "Acceptance18Spec", the same way
-- "FFIContractSpec" lends its parsers to "BindingContractSpec".
module FFISceneSpec
  ( spec

    -- * Scene harness (shared with "FFISceneCastSpec" and "Acceptance18Spec")
  , CastOutcome (..)
  , withSceneHandle
  , sceneCast
  , sceneCastMany
  , sceneCastOk
  , sceneBudgetOf
  , sceneIds
  , sceneObserve
  , exampleBudget
  ) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import Data.Word (Word64)
import FFIHarness
  ( Observed (..)
  , guardSlots
  , floatSentinel
  , intSentinel
  , referenceSpell
  , spellBytes
  , testCtx
  , wordSentinel
  )
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CFloat (..), CInt (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (peekArray, pokeArray, withArray)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.StablePtr (StablePtr)
import Foreign.Storable (peek, poke)
import qualified GHC.Foreign as GHCF
import GHC.IO.Encoding (utf8)
import Magic.FFI
  ( SceneCell
  , nullScene
  , pm_scene_advance
  , pm_scene_budget
  , pm_scene_cast
  , pm_scene_cast_many
  , pm_scene_count
  , pm_scene_dismiss
  , pm_scene_free
  , pm_scene_new
  , pm_scene_observe
  , pm_scene_spells
  , pmErrArgs
  , pmErrCapacity
  , pmErrQuota
  , pmOk
  )
import Magic.Interface
  ( CastContext (..)
  , Seed (..)
  , V3 (..)
  , budgetPlanOf
  , budgetTotal
  )
import Test.Hspec

spec :: Spec
spec = describe "scene handle over the C ABI (func-spec 0018 §7 S2)" $ do
  it "opens empty: no spells, no quota spent, the cap it was asked for" $
    withSceneHandle 4096 $ \sc -> do
      n <- pm_scene_count sc
      n `shouldBe` 0
      budget <- sceneBudgetOf sc
      budget `shouldBe` (pmOk, 0, 4096)

  it "lists the live spells in admission order" $ do
    bytes <- spellBytes "ring-fire"
    other <- spellBytes "spiral-spark"
    withSceneHandle 16384 $ \sc -> do
      a <- sceneCastOk sc bytes testCtx
      b <- sceneCastOk sc other testCtx
      c <- sceneCastOk sc bytes testCtx
      pm_scene_count sc `shouldReturn` 3
      (code, ids) <- sceneIds sc 3
      code `shouldBe` 3
      take 3 ids `shouldBe` [a, b, c]
      -- ids ascend and are never reused, which is what makes a stale one
      -- inert rather than ambiguous
      [a, b, c] `shouldBe` [0, 1, 2]

  it "leaves the guard slots alone when the ids fit exactly" $ do
    bytes <- spellBytes "ring-fire"
    withSceneHandle 16384 $ \sc -> do
      _ <- sceneCastOk sc bytes testCtx
      (code, ids) <- sceneIds sc 1
      code `shouldBe` 1
      drop 1 ids `shouldBe` replicate guardSlots intSentinel

  it "refuses to list ids that do not fit, writing nothing at all" $ do
    bytes <- spellBytes "ring-fire"
    withSceneHandle 16384 $ \sc -> do
      _ <- sceneCastOk sc bytes testCtx
      _ <- sceneCastOk sc bytes testCtx
      (code, ids) <- sceneIds sc 1
      code `shouldBe` pmErrCapacity
      -- all-or-nothing: not even the id that would have fitted
      ids `shouldBe` replicate (1 + guardSlots) intSentinel

  it "answers a NULL out_ids array only when there is nothing to write" $
    withSceneHandle 4096 $ \sc ->
      pm_scene_spells sc nullPtr 0 `shouldReturn` 0

  it "treats an unknown, stale or already-dismissed id as a no-op" $ do
    bytes <- spellBytes "ring-fire"
    withSceneHandle 16384 $ \sc -> do
      sid <- sceneCastOk sc bytes testCtx
      before <- sceneBudgetOf sc
      pm_scene_dismiss sc 12345 -- never issued
      pm_scene_dismiss sc (-1) -- the sentinel a refused cast leaves
      pm_scene_count sc `shouldReturn` 1
      sceneBudgetOf sc `shouldReturn` before
      pm_scene_dismiss sc sid
      pm_scene_count sc `shouldReturn` 0
      pm_scene_dismiss sc sid -- the same id, now stale
      pm_scene_count sc `shouldReturn` 0
      (_, used, _) <- sceneBudgetOf sc
      used `shouldBe` 0

  it "takes a negative cap as a scene that admits nothing" $ do
    bytes <- spellBytes "ring-fire"
    -- Legal on the Haskell side, so legal here: refusing it at the C
    -- boundary would be a semantic the pure layer does not have
    -- (func-spec 0018 §2).
    withSceneHandle (-1) $ \sc -> do
      sceneBudgetOf sc `shouldReturn` (pmOk, 0, -1)
      outcome <- sceneCast sc bytes testCtx
      coCode outcome `shouldBe` pmErrQuota
      pm_scene_count sc `shouldReturn` 0

  it "releases a finished spell's share of the quota" $ do
    bytes <- spellBytes "ring-fire"
    let cap = exampleBudget bytes
        wire = fromIntegral cap :: CInt
    -- A cap of exactly one ring-fire: the second cast can only be
    -- admitted once the first has ended.
    withSceneHandle cap $ \sc -> do
      _ <- sceneCastOk sc bytes testCtx
      sceneBudgetOf sc `shouldReturn` (pmOk, wire, wire)
      refused <- sceneCast sc bytes testCtx
      coCode refused `shouldBe` pmErrQuota
      mapM_ (\_ -> pm_scene_advance sc (CFloat 0.5)) [1 :: Int .. 40]
      pm_scene_count sc `shouldReturn` 0
      sceneBudgetOf sc `shouldReturn` (pmOk, 0, wire)
      -- ... and the freed room is really usable again
      again <- sceneCast sc bytes testCtx
      coCode again `shouldBe` pmOk
      pm_scene_count sc `shouldReturn` 1

  it "advances every live spell, not just the first" $ do
    bytes <- spellBytes "ring-fire"
    other <- spellBytes "spiral-spark"
    withSceneHandle 16384 $ \sc -> do
      _ <- sceneCastOk sc bytes testCtx
      _ <- sceneCastOk sc other testCtx
      before <- sceneObserve sc 16384 32
      mapM_ (\_ -> pm_scene_advance sc (CFloat (1 / 60))) [1 :: Int .. 60]
      after <- sceneObserve sc 16384 32
      obCode after `shouldSatisfy` (>= 0)
      -- both spells contributed: two batch lists' worth, and particles
      -- that a frame's worth of advancing has actually moved
      obCode after `shouldSatisfy` (>= 2)
      obPosX after `shouldNotBe` obPosX before
      pm_scene_count sc `shouldReturn` 2

  describe "a NULL scene handle is quiet, never a crash" $ do
    it "frees, dismisses and advances as no-ops" $ do
      pm_scene_free nullScene
      pm_scene_dismiss nullScene 0
      pm_scene_advance nullScene (CFloat 0.016)
      -- reaching here at all is the assertion
      pm_scene_count nullScene `shouldReturn` 0

    it "reports neutral values from the queries" $ do
      pm_scene_count nullScene `shouldReturn` 0
      sceneBudgetOf nullScene `shouldReturn` (pmErrArgs, budgetSentinel, budgetSentinel)
      (code, ids) <- sceneIds nullScene 4
      code `shouldBe` 0
      ids `shouldBe` replicate (4 + guardSlots) intSentinel

    it "observes nothing, touching no column" $ do
      obs <- sceneObserve nullScene 8 2
      obCode obs `shouldBe` 0
      obPosX obs `shouldBe` replicate (8 + guardSlots) floatSentinel
      obColor obs `shouldBe` replicate (8 + guardSlots) wordSentinel
      obInfo obs `shouldBe` replicate (4 * 2 + guardSlots) intSentinel

    it "refuses both cast entry points with PM_ERR_ARGS" $ do
      bytes <- spellBytes "ring-fire"
      one <- sceneCast nullScene bytes testCtx
      coCode one `shouldBe` pmErrArgs
      coId one `shouldBe` idSentinel
      many <- sceneCastMany nullScene [bytes] testCtx
      coCode many `shouldBe` pmErrArgs

-- Harness ---------------------------------------------------------------------

-- | What a scene cast answered: the classified code, whatever landed in
-- @out_id@, and the message the library wrote into the host's buffer.
data CastOutcome = CastOutcome
  { coCode :: CInt
  , coId :: CInt
  , coMessage :: String
  }
  deriving (Eq, Show)

-- | Pre-poked into @out_id@, so a spec can tell "the library wrote an id"
-- from "the library left the slot alone". Note it is /not/ the @-1@ the
-- cast entry points themselves write on the failure path.
idSentinel :: CInt
idSentinel = -99

-- | The same idea for 'pm_scene_budget''s two out parameters.
budgetSentinel :: CInt
budgetSentinel = -777

-- | Open a scene, hand it to the body, free it however the body ends.
withSceneHandle :: Int -> (StablePtr SceneCell -> IO a) -> IO a
withSceneHandle cap = bracket (pm_scene_new (fromIntegral cap)) pm_scene_free

-- | Cast one circle through @pm_scene_cast@, exactly as a C host would.
sceneCast :: StablePtr SceneCell -> BS.ByteString -> CastContext -> IO CastOutcome
sceneCast sc bytes ctx =
  withCStringBytes bytes $ \json ->
    withCastArgs ctx $ \pos facing sd ->
      withOutcome $ \errBuf errLen outId ->
        pm_scene_cast sc json pos facing sd errBuf errLen outId

-- | The composition entry point, over a list of circle JSONs.
sceneCastMany :: StablePtr SceneCell -> [BS.ByteString] -> CastContext -> IO CastOutcome
sceneCastMany sc chunks ctx =
  withCStringList chunks $ \ptrs ->
    withArray ptrs $ \arr ->
      withCastArgs ctx $ \pos facing sd ->
        withOutcome $ \errBuf errLen outId ->
          pm_scene_cast_many sc arr (fromIntegral (length chunks)) pos facing sd errBuf errLen outId

-- | 'sceneCast' for the happy path, answering the id it was given.
sceneCastOk :: StablePtr SceneCell -> BS.ByteString -> CastContext -> IO CInt
sceneCastOk sc bytes ctx = do
  outcome <- sceneCast sc bytes ctx
  if coCode outcome == pmOk
    then pure (coId outcome)
    else error ("scene cast failed unexpectedly: " ++ show outcome)

-- | @(return code, *out_used, *out_cap)@, both out slots pre-filled with
-- 'budgetSentinel' so an untouched one is visible.
sceneBudgetOf :: StablePtr SceneCell -> IO (CInt, CInt, CInt)
sceneBudgetOf sc =
  alloca $ \usedPtr ->
    alloca $ \capPtr -> do
      poke usedPtr budgetSentinel
      poke capPtr budgetSentinel
      code <- pm_scene_budget sc usedPtr capPtr
      (,,) code <$> peek usedPtr <*> peek capPtr

-- | @pm_scene_spells@ into a sentinel-filled array over-allocated by
-- 'guardSlots', returned in full so a spec can check the guard region.
sceneIds :: StablePtr SceneCell -> Int -> IO (CInt, [CInt])
sceneIds sc maxIds = do
  let slots = max 0 maxIds + guardSlots
  withArray (replicate slots intSentinel) $ \out -> do
    code <- pm_scene_spells sc out (fromIntegral maxIds)
    (,) code <$> peekArray slots out

-- | @pm_scene_observe@ into the same over-allocated, sentinel-filled six
-- columns 'FFIHarness.observeRaw' uses for one spell.
sceneObserve :: StablePtr SceneCell -> Int -> Int -> IO Observed
sceneObserve sc capacity maxBatches = do
  let slots = max 0 capacity + guardSlots
      infoSlots = 4 * max 0 maxBatches + guardSlots
  withArray (replicate slots (CFloat floatSentinel)) $ \px ->
    withArray (replicate slots (CFloat floatSentinel)) $ \py ->
      withArray (replicate slots (CFloat floatSentinel)) $ \pz ->
        withArray (replicate slots (CFloat floatSentinel)) $ \psize ->
          withArray (replicate slots (CFloat floatSentinel)) $ \plife ->
            withArray (replicate slots wordSentinel) $ \pcolor ->
              withArray (replicate infoSlots intSentinel) $ \pinfo -> do
                code <-
                  pm_scene_observe
                    sc
                    px
                    py
                    pz
                    psize
                    plife
                    pcolor
                    (fromIntegral capacity)
                    pinfo
                    (fromIntegral maxBatches)
                let floats p = map (\(CFloat f) -> f) <$> peekArray slots p
                Observed code
                  <$> floats px
                  <*> floats py
                  <*> floats pz
                  <*> floats psize
                  <*> floats plife
                  <*> peekArray slots pcolor
                  <*> peekArray infoSlots pinfo

-- | What one shipped example costs the quota, taken off the reference
-- path so the specs never hard-code a number the core may re-tune.
exampleBudget :: BS.ByteString -> Int
exampleBudget bytes = budgetTotal (budgetPlanOf (referenceSpell bytes testCtx))

-- Marshalling -----------------------------------------------------------------

-- | The error buffer and @out_id@ slot every cast call needs, with the
-- outcome read back out of them.
withOutcome :: (CString -> CInt -> Ptr CInt -> IO CInt) -> IO CastOutcome
withOutcome k =
  allocaBytes errCap $ \errBuf ->
    alloca $ \outId -> do
      -- '!' everywhere but the last byte, so an untouched buffer reads
      -- back as a run of '!' instead of running off the end looking for a
      -- terminator the library never wrote.
      pokeArray errBuf (replicate (errCap - 1) 0x21 ++ [0])
      poke outId idSentinel
      code <- k errBuf (fromIntegral errCap) outId
      CastOutcome code <$> peek outId <*> GHCF.peekCString utf8 errBuf
  where
    errCap = 512

withCastArgs :: CastContext -> (Ptr CFloat -> Ptr CFloat -> Word64 -> IO a) -> IO a
withCastArgs ctx k =
  withV3 (casterPos ctx) $ \pos ->
    withV3 (casterFacing ctx) $ \facing ->
      let Seed s = seed ctx in k pos facing s

withV3 :: V3 -> (Ptr CFloat -> IO a) -> IO a
withV3 (V3 x y z) = withArray [CFloat x, CFloat y, CFloat z]

withCStringBytes :: BS.ByteString -> (CString -> IO a) -> IO a
withCStringBytes bytes =
  withArray (map fromIntegral (BS.unpack bytes) ++ [0] :: [CChar])

withCStringList :: [BS.ByteString] -> ([CString] -> IO a) -> IO a
withCStringList [] k = k []
withCStringList (b : bs) k =
  withCStringBytes b $ \p -> withCStringList bs (\ps -> k (p : ps))
