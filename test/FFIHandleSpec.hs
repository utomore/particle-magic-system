-- | host-runtime F002: the generation-tagged handle.
--
-- Before this feature a @PmSpell*@ was a live 'StablePtr'. Freed, freed
-- twice, or forged, it was undefined behaviour — @deRefStablePtr@ on a
-- released table entry reads whatever is there now, and the usual symptom
-- is a dead host process. The subsystem's first acceptance criterion (P-1)
-- says the library never terminates its host, so the handle became a word
-- that encodes (kind, slot, generation) and two module-level tables
-- resolve.
--
-- The cases below are the feature's TodoList, one to one: the word layout,
-- the table's lifecycle, the two allocation sites, the per-symbol answer
-- table for invalid handles, the internals the specs drive, the
-- bit-for-bit regression on legal handles, and the cost of resolution.
module FFIHandleSpec (spec) where

import Control.Exception (ErrorCall, SomeException, catch, evaluate, try)
import Data.Either (isLeft)
import Data.List (isInfixOf, nub)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import FFIContractSpec (readUtf8)
import FFIHarness
  ( Observed (..)
  , batchTuples
  , castOk
  , intSentinel
  , observeRaw
  , referenceAt
  , referenceSpell
  , spellBytes
  , testCtx
  )
import Foreign.C.Types (CDouble (..), CFloat (..), CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray)
import Foreign.Ptr (Ptr, WordPtr, nullPtr, ptrToWordPtr, wordPtrToPtr)
import Foreign.StablePtr (StablePtr, castPtrToStablePtr, castStablePtrToPtr)
import Foreign.Storable (peek, poke)
import GHC.Float (castFloatToWord32)
import Magic.FFI
  ( SceneCell
  , SpellCell
  , blendCode
  , freeSceneHandle
  , freeSpellHandle
  , isNullScene
  , isNullSpell
  , newSceneHandle
  , newSpellHandle
  , pmErrArgs
  , pmMaxParticles
  , pm_advance
  , pm_age
  , pm_emitter_box
  , pm_emitter_count
  , pm_free
  , pm_is_finished
  , pm_observe
  , pm_observe_ex
  , pm_occupancy
  , pm_occupancy_mask
  , pm_scene_advance
  , pm_scene_budget
  , pm_scene_cast
  , pm_scene_cast_many
  , pm_scene_count
  , pm_scene_dismiss
  , pm_scene_free
  , pm_scene_new
  , pm_scene_observe
  , pm_scene_spell_bounds
  , pm_scene_spells
  , pm_spell_bounds
  , pm_spell_box
  , sceneRegistryStats
  , shapeCode
  , spellRegistryStats
  )
import Magic.FFI.Registry
  ( Decoded (..)
  , HandleKind (..)
  , decodeHandle
  , encodeHandle
  , handleGenerationLimit
  , handleSlotLimit
  )
import Magic.Interface
  ( ActiveSpell
  , ParticleBuffer
      ( pbColor
      , pbCount
      , pbLife
      , pbPosX
      , pbPosY
      , pbPosZ
      , pbSize
      , pbVelX
      , pbVelY
      , pbVelZ
      )
  , RenderBatch (..)
  , batches
  , observeSpell
  )
import Magic.Scene (SceneConfig (..), newScene)
import System.Mem (getAllocationCounter)
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = describe "generation-tagged handles (host-runtime F002)" $ do
  -- T1 -----------------------------------------------------------------
  it "round-trips kind, slot and generation through the handle word" $
    property $ \slotSeed genSeed ->
      let slot = (slotSeed :: Int) `mod` handleSlotLimit
          gen = 1 + (genSeed :: Word) `mod` (handleGenerationLimit - 1)
          bothWays kind other =
            let w = encodeHandle kind slot gen
             in [ decodeHandle kind w == DecSlot slot gen
                , -- the synthetic bit: never zero, never an aligned address
                  odd w
                , w /= 0
                , wordPtrToPtr (fromIntegral w) /= (nullPtr :: Ptr ())
                , -- the kind bit tells the two handle spaces apart
                  decodeHandle other w == DecForged
                ]
       in and (bothWays KindSpell KindScene ++ bothWays KindScene KindSpell)

  it "reads zero as NULL and an unsynthesised word as never-issued" $ do
    decodeHandle KindSpell 0 `shouldBe` DecNull
    decodeHandle KindScene 0 `shouldBe` DecNull
    decodeHandle KindSpell 0x1234 `shouldBe` DecForged
    decodeHandle KindSpell (encodeHandle KindSpell 0 1) `shouldBe` DecSlot 0 1

  -- T2 -----------------------------------------------------------------
  it "reuses slots with a fresh generation and never repeats a handle value" $ do
    (live0, _) <- spellRegistryStats
    firstBatch <- traverse (const (newSpellHandle unusedSpell)) [1 .. batchSize]
    (live1, count1) <- spellRegistryStats
    live1 `shouldBe` live0 + batchSize

    let (freed, kept) = splitAt half firstBatch
    mapM_ freeSpellHandle freed
    (live2, count2) <- spellRegistryStats
    live2 `shouldBe` live1 - half
    count2 `shouldBe` count1

    -- a released handle no longer resolves, and releasing it again is a
    -- no-op rather than a corrupted table
    mapM_ (\h -> pm_is_finished h `shouldReturn` pmErrArgs) freed
    mapM_ freeSpellHandle freed
    spellRegistryStats `shouldReturn` (live2, count2)

    secondBatch <- traverse (const (newSpellHandle unusedSpell)) [1 .. half]
    (live3, count3) <- spellRegistryStats
    live3 `shouldBe` live1
    -- the freed slots came back: the table did not grow
    count3 `shouldBe` count1

    -- and yet no handle value was ever handed out twice
    let issued = map handleWordOf (firstBatch ++ secondBatch)
    length (nub issued) `shouldBe` length issued
    issued `shouldSatisfy` all (/= 0)

    mapM_ freeSpellHandle (kept ++ secondBatch)

  -- T3 -----------------------------------------------------------------
  it "casts and frees through the registry, with no StablePtr left in the path" $ do
    bytes <- spellBytes "ring-fire"
    (spellLive0, _) <- spellRegistryStats
    handle <- castOk bytes testCtx
    isNullSpell handle `shouldBe` False
    liveSpells `shouldReturn` (spellLive0 + 1)
    pm_free handle
    liveSpells `shouldReturn` spellLive0
    pm_free handle
    liveSpells `shouldReturn` spellLive0

    (sceneLive0, _) <- sceneRegistryStats
    scene <- pm_scene_new 256
    isNullScene scene `shouldBe` False
    liveScenes `shouldReturn` (sceneLive0 + 1)
    pm_scene_free scene
    liveScenes `shouldReturn` sceneLive0
    pm_scene_free scene
    liveScenes `shouldReturn` sceneLive0

    -- The stable pointer table is out of the picture entirely: the three
    -- calls that made a freed handle undefined behaviour are gone from the
    -- shell.
    source <- readUtf8 "src/ffi/Magic/FFI.hs"
    mapM_
      (\name -> (name, name `isInfixOf` source) `shouldBe` (name, False))
      ["newStablePtr", "freeStablePtr", "deRefStablePtr"]

  -- T4 -----------------------------------------------------------------
  it "answers the invalid-handle table for freed, double-freed and forged handles" $ do
    forEachInvalidSpell $ \source handle ->
      mapM_ (\(name, check) -> labelled source name (check handle)) spellCases
    forEachInvalidScene $ \source handle ->
      mapM_ (\(name, check) -> labelled source name (check handle)) sceneCases

  -- T6 -----------------------------------------------------------------
  it "exposes the registry internals the specs drive" $ do
    -- The registry is lazy in the cell's contents, which is what lets a
    -- spec put a bottom behind a perfectly legal handle. Forcing the age
    -- therefore reaches the bottom — proof that the handle resolved.
    poisoned <- newSpellHandle (error "poisoned spell")
    isNullSpell poisoned `shouldBe` False
    reached <- try (pm_age poisoned >>= evaluate) :: IO (Either ErrorCall CDouble)
    reached `shouldSatisfy` isLeft

    -- A forged handle never gets that far: it is rejected before anything
    -- behind it is touched.
    forgedAge <- pm_age forgedSpell >>= evaluate
    forgedAge `shouldBe` 0

    freeSpellHandle poisoned
    (pm_age poisoned >>= evaluate) `shouldReturn` 0

    poisonedScene <- newSceneHandle (error "poisoned scene")
    isNullScene poisonedScene `shouldBe` False
    reachedScene <-
      try (pm_scene_count poisonedScene >>= evaluate) :: IO (Either ErrorCall CInt)
    reachedScene `shouldSatisfy` isLeft
    freeSceneHandle poisonedScene
    pm_scene_count poisonedScene `shouldReturn` pmErrArgs

  -- T7 -----------------------------------------------------------------
  it "leaves a legal handle's output bit-identical" $
    mapM_ bitIdentical ["ring-fire", "spiral-spark", "grand-sigil", "converge-flame"]

  -- T8 -----------------------------------------------------------------
  it "resolves in constant cost regardless of how many handles are live" $ do
    bytes <- spellBytes "ring-fire"
    handle <- castOk bytes testCtx
    _ <- ageLoop handle 1000 -- warm up, so the first nursery block is not measured
    lonely <- allocationOf (ageLoop handle probeCalls)

    fillers <- traverse (const (newSpellHandle unusedSpell)) [1 .. crowd]
    (_, countWithCrowd) <- spellRegistryStats
    crowded <- allocationOf (ageLoop handle probeCalls)

    -- One IORef read and one vector read, whatever the table holds: the
    -- per-call allocation does not move with the number of live handles.
    -- The tolerance is the allocation counter's own granularity (it is
    -- synchronised per nursery block, not per allocation), which over
    -- 200k calls is far below one byte per call.
    abs (lonely - crowded) `shouldSatisfy` (< 65536)
    (lonely `div` fromIntegral probeCalls) `shouldSatisfy` (< 128)

    mapM_ freeSpellHandle fillers
    refilled <- traverse (const (newSpellHandle unusedSpell)) [1 .. crowd]
    (_, countAfterReuse) <- spellRegistryStats
    countAfterReuse `shouldBe` countWithCrowd
    mapM_ freeSpellHandle refilled
    pm_free handle

-- Fixtures --------------------------------------------------------------------

batchSize, half, crowd, probeCalls :: Int
batchSize = 64
half = 32
crowd = 4096
probeCalls = 200000

liveSpells :: IO Int
liveSpells = fst <$> spellRegistryStats

liveScenes :: IO Int
liveScenes = fst <$> sceneRegistryStats

-- | A spell nobody looks at. The registry is lazy in the cell's contents,
-- so a bottom is a perfectly good stand-in when the test only cares about
-- slots and generations.
unusedSpell :: ActiveSpell
unusedSpell = error "FFIHandleSpec: this spell is never observed"

handleWordOf :: StablePtr a -> WordPtr
handleWordOf = ptrToWordPtr . castStablePtrToPtr

synthesise :: HandleKind -> Int -> Word -> StablePtr a
synthesise kind slot gen =
  castPtrToStablePtr (wordPtrToPtr (fromIntegral (encodeHandle kind slot gen)))

-- | A handle the library never issued: the last representable slot, which
-- no table will ever have allocated.
forgedSpell :: StablePtr SpellCell
forgedSpell = synthesise KindSpell (handleSlotLimit - 1) 7

forgedScene :: StablePtr SceneCell
forgedScene = synthesise KindScene (handleSlotLimit - 1) 7

-- | The ways a non-NULL handle can be invalid, each handed to the caller
-- with a label.
forEachInvalidSpell :: (String -> StablePtr SpellCell -> IO ()) -> IO ()
forEachInvalidSpell k = do
  freed <- do
    h <- newSpellHandle unusedSpell
    freeSpellHandle h
    pure h
  k "freed spell handle" freed
  k "double-freed spell handle" freed
  k "forged spell handle" forgedSpell
  -- A scene handle where a spell handle belongs: the kind bit catches it,
  -- and the scene must survive the whole sweep (pm_free must not have
  -- released it).
  scenesBefore <- liveScenes
  scene <- pm_scene_new 128
  k "scene handle as a spell handle" (castPtrToStablePtr (castStablePtrToPtr scene))
  liveScenes `shouldReturn` (scenesBefore + 1)
  pm_scene_count scene `shouldReturn` 0
  pm_scene_free scene

forEachInvalidScene :: (String -> StablePtr SceneCell -> IO ()) -> IO ()
forEachInvalidScene k = do
  freed <- do
    h <- newSceneHandle (newScene (SceneConfig 64))
    freeSceneHandle h
    pure h
  k "freed scene handle" freed
  k "double-freed scene handle" freed
  k "forged scene handle" forgedScene
  spellsBefore <- liveSpells
  spell <- newSpellHandle unusedSpell
  k "spell handle as a scene handle" (castPtrToStablePtr (castStablePtrToPtr spell))
  liveSpells `shouldReturn` (spellsBefore + 1)
  freeSpellHandle spell

-- | Name the source and the symbol when an expectation fails; without it a
-- table-driven sweep reports only "expected -4".
labelled :: String -> String -> IO () -> IO ()
labelled source name act =
  act `catch` \e ->
    expectationFailure
      (source ++ " → " ++ name ++ ": " ++ show (e :: SomeException))

-- Per-symbol answers ----------------------------------------------------------

-- | The invalid-handle column of the feature's per-symbol table, for the
-- twelve entry points that take a @PmSpell*@.
spellCases :: [(String, StablePtr SpellCell -> IO ())]
spellCases =
  [ ("pm_advance", \h -> pm_advance h 0.016)
  , ("pm_is_finished", \h -> pm_is_finished h `shouldReturn` pmErrArgs)
  , ("pm_age", \h -> pm_age h `shouldReturn` 0)
  , ("pm_observe", \h -> observeAll h `shouldReturn` pmErrArgs)
  , ("pm_observe_ex", \h -> observeExAll h `shouldReturn` pmErrArgs)
  , ("pm_free", pm_free)
  ,
    ( "pm_spell_bounds"
    , \h -> allocaArray 3 $ \lo ->
        allocaArray 3 $ \hi -> pm_spell_bounds h lo hi `shouldReturn` pmErrArgs
    )
  , ("pm_spell_box", \h -> withBoxOut (pm_spell_box h) `shouldReturn` pmErrArgs)
  , ("pm_emitter_count", \h -> pm_emitter_count h `shouldReturn` pmErrArgs)
  , ("pm_emitter_box", \h -> withBoxOut (pm_emitter_box h 0) `shouldReturn` pmErrArgs)
  ,
    ( "pm_occupancy"
    , \h -> allocaArray 27 $ \out -> pm_occupancy h 3 out 27 `shouldReturn` pmErrArgs
    )
  , ("pm_occupancy_mask", \h -> pm_occupancy_mask h `shouldReturn` 0)
  ]

-- | The same column for the ten entry points that take a @PmScene*@.
sceneCases :: [(String, StablePtr SceneCell -> IO ())]
sceneCases =
  [ ("pm_scene_free", pm_scene_free)
  ,
    ( "pm_scene_cast"
    , \h -> withIdSentinel $ \outId ->
        pm_scene_cast h nullPtr nullPtr nullPtr 0 nullPtr 0 outId `shouldReturn` pmErrArgs
    )
  ,
    ( "pm_scene_cast_many"
    , \h -> withIdSentinel $ \outId ->
        pm_scene_cast_many h nullPtr 0 nullPtr nullPtr 0 nullPtr 0 outId
          `shouldReturn` pmErrArgs
    )
  , ("pm_scene_dismiss", \h -> pm_scene_dismiss h 0)
  , ("pm_scene_advance", \h -> pm_scene_advance h 0.016)
  ,
    ( "pm_scene_observe"
    , \h ->
        pm_scene_observe h nullPtr nullPtr nullPtr nullPtr nullPtr nullPtr 0 nullPtr 0
          `shouldReturn` pmErrArgs
    )
  ,
    ( "pm_scene_budget"
    , \h -> alloca $ \used ->
        alloca $ \capacity -> pm_scene_budget h used capacity `shouldReturn` pmErrArgs
    )
  , ("pm_scene_count", \h -> pm_scene_count h `shouldReturn` pmErrArgs)
  ,
    ( "pm_scene_spells"
    , \h -> allocaArray 4 $ \ids -> pm_scene_spells h ids 4 `shouldReturn` pmErrArgs
    )
  ,
    ( "pm_scene_spell_bounds"
    , \h -> allocaArray 3 $ \lo ->
        allocaArray 3 $ \hi -> pm_scene_spell_bounds h 0 lo hi `shouldReturn` pmErrArgs
    )
  ]

-- | Both scene cast entry points refuse an invalid handle /before/ they
-- pre-set @out_id@, so a host's id word is left exactly as a NULL scene
-- leaves it: untouched.
withIdSentinel :: (Ptr CInt -> IO ()) -> IO ()
withIdSentinel k =
  alloca $ \outId -> do
    poke outId intSentinel
    k outId
    peek outId `shouldReturn` intSentinel

withBoxOut :: (Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> IO CInt) -> IO CInt
withBoxOut k =
  allocaArray 3 $ \center ->
    allocaArray 9 $ \axes ->
      allocaArray 3 $ \halfExtents -> k center axes halfExtents

observeAll :: StablePtr SpellCell -> IO CInt
observeAll h =
  pm_observe h nullPtr nullPtr nullPtr nullPtr nullPtr nullPtr 0 nullPtr 0

observeExAll :: StablePtr SpellCell -> IO CInt
observeExAll h =
  pm_observe_ex
    h
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    nullPtr
    0
    nullPtr
    0

-- The bit-for-bit regression ---------------------------------------------------

dt :: Float
dt = 1 / 60

frames, maxBatches :: Int
frames = 120
maxBatches = 64

-- | A legal handle's output, nine columns and @batch_info@, compared with
-- the plain 'Magic.Interface' path bit pattern by bit pattern (a @Float@
-- comparison would let a @-0.0@ through).
bitIdentical :: String -> IO ()
bitIdentical name = do
  bytes <- spellBytes name
  handle <- castOk bytes testCtx
  mapM_ (\_ -> pm_advance handle (CFloat dt)) [1 .. frames]
  obs <- observeRaw handle (fromIntegral pmMaxParticles) maxBatches
  nine <- observeNine handle (fromIntegral pmMaxParticles)
  pm_free handle

  let reference = referenceAt (referenceSpell bytes testCtx) (replicate frames dt)
      refBatches = batches (observeSpell reference)
      buffers = map rbParticles refBatches
      column f = concatMap (U.toList . f) buffers
      -- An absent velocity column is written out as zeros (func-spec
      -- 0023), so the reference has to say the same thing.
      velocity f =
        concatMap
          (\pb -> if U.null (f pb) then replicate (pbCount pb) 0 else U.toList (f pb))
          buffers
      written = sum (map pbCount buffers)
      counts = map pbCount buffers
      offsets = scanl (+) 0 counts
      bits = map castFloatToWord32

  obCode obs `shouldBe` fromIntegral (length refBatches)
  -- guard against a vacuously green comparison
  (name, written) `shouldSatisfy` ((> 0) . snd)
  same name "pos.x" (bits (take written (obPosX obs))) (bits (column pbPosX))
  same name "pos.y" (bits (take written (obPosY obs))) (bits (column pbPosY))
  same name "pos.z" (bits (take written (obPosZ obs))) (bits (column pbPosZ))
  same name "size" (bits (take written (obSize obs))) (bits (column pbSize))
  same name "life" (bits (take written (obLife obs))) (bits (column pbLife))
  same name "color" (take written (obColor obs)) (column pbColor)
  same name "vel.x" (bits (take written (ncVelX nine))) (bits (velocity pbVelX))
  same name "vel.y" (bits (take written (ncVelY nine))) (bits (velocity pbVelY))
  same name "vel.z" (bits (take written (ncVelZ nine))) (bits (velocity pbVelZ))
  batchTuples (length refBatches) obs
    `shouldBe` [ (off, n, fromIntegral (blendCode (rbBlend b)), fromIntegral (shapeCode (rbShape b)))
               | (off, n, b) <- zip3 offsets counts refBatches
               ]

same :: (Eq a) => String -> String -> a -> a -> Expectation
same name field actual expected =
  if actual == expected
    then pure ()
    else expectationFailure (name ++ ": " ++ field ++ " is not bit-identical")

-- | The three velocity columns of 'pm_observe_ex'; the other six are
-- already covered through 'observeRaw'.
data NineColumns = NineColumns
  { ncVelX :: [Float]
  , ncVelY :: [Float]
  , ncVelZ :: [Float]
  }

observeNine :: StablePtr SpellCell -> Int -> IO NineColumns
observeNine handle capacity =
  withArray (replicate capacity (CFloat 0)) $ \px ->
    withArray (replicate capacity (CFloat 0)) $ \py ->
      withArray (replicate capacity (CFloat 0)) $ \pz ->
        withArray (replicate capacity (CFloat 0)) $ \psize ->
          withArray (replicate capacity (CFloat 0)) $ \plife ->
            withArray (replicate capacity (0 :: Word32)) $ \pcolor ->
              withArray (replicate capacity (CFloat 0)) $ \pvx ->
                withArray (replicate capacity (CFloat 0)) $ \pvy ->
                  withArray (replicate capacity (CFloat 0)) $ \pvz ->
                    allocaArray (4 * maxBatches) $ \pinfo -> do
                      _ <-
                        pm_observe_ex
                          handle
                          px
                          py
                          pz
                          psize
                          plife
                          pcolor
                          pvx
                          pvy
                          pvz
                          (fromIntegral capacity)
                          pinfo
                          (fromIntegral maxBatches)
                      let floats p = map (\(CFloat f) -> f) <$> peekArray capacity p
                      NineColumns <$> floats pvx <*> floats pvy <*> floats pvz

-- Cost ------------------------------------------------------------------------

-- | Sum the ages so the optimiser cannot drop the calls, and so the
-- returned @CDouble@ is actually forced.
ageLoop :: StablePtr SpellCell -> Int -> IO Double
ageLoop handle = go 0
  where
    go !acc 0 = pure acc
    go !acc k = do
      CDouble v <- pm_age handle
      go (acc + v) (k - 1)

allocationOf :: IO a -> IO Integer
allocationOf act = do
  start <- getAllocationCounter
  _ <- act
  end <- getAllocationCounter
  pure (fromIntegral (start - end))
