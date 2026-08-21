-- | host-runtime F004: the thread model (design.md C2.2, ADR-022 D4).
--
-- Before this round the C shell had no concurrency story at all. Every
-- entry point that moved a handle forward did it as @readIORef@ / compute
-- / @writeIORef@, so two threads advancing the same spell could each read
-- the same state and each write their own successor: one step happened,
-- one vanished. Nothing reported it. The header's answer was the sentence
-- "one handle is owned by one thread", which tells a host neither what is
-- allowed nor what a violation costs.
--
-- C2.2 replaces it with a promise — __no lost updates__ — and this module
-- is where the promise is checked. Concurrency tests are notoriously good
-- at passing for the wrong reason, so four separate things keep a green
-- run honest:
--
--   1. __A deterministic source audit__ (in the T2 example). @writeIORef@
--      must not appear in @src\/ffi\/Magic\/FFI.hs@ at all: every
--      read-modify-write goes through 'stepCell' \/ 'stepCellWith'. Put the
--      old shape back and this fails on every machine, scheduler included
--      or not. It is the primary defence; the racing tests are corroboration.
--   2. __A teeth check__. The same thread skeleton also drives a
--      deliberately non-atomic twin. If the twin does /not/ lose an update,
--      this runner cannot exhibit the race, and the example says
--      'pendingWith' rather than claiming a pass it did not earn.
--   3. __Bit-pattern assertions with nothing time-shaped in them.__ Every
--      step adds the same @dt@ to whatever came before, so N concurrent
--      advances compose to exactly the N-step sequential fold however they
--      interleave — which makes the expected answer a bit pattern, not a
--      tolerance. Each such comparison is guarded by an assertion that the
--      spell still had particles at that age, so a finished spell cannot
--      turn the comparison into @[] == []@.
--   4. __A repeatable race shape.__ Thread and iteration counts are
--      constants; threads are pinned with 'forkOn'; they all wait on one
--      'MVar' starting gate and are collected through one 'MVar' each.
--      There is no 'Control.Concurrent.threadDelay' anywhere in this file.
module FFIThreadSpec (spec) where

import Control.Concurrent (forkOn, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, bracket_, evaluate, throwIO, try)
import Control.Monad (forM, replicateM, replicateM_)
import qualified Data.ByteString as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, nub, sort)
import Data.Word (Word32)
import FFIContractSpec (readUtf8)
import FFIHarness
  ( Observed (..)
  , castOk
  , observeRaw
  , referenceAt
  , referenceSpell
  , spellBytes
  , testCtx
  )
import FFISceneSpec
  ( CastOutcome (..)
  , exampleBudget
  , sceneCast
  , sceneCastOk
  , sceneIds
  , sceneObserve
  , withSceneHandle
  )
import Foreign.C.Types (CDouble (..), CFloat (..), CInt (..))
import Foreign.Ptr (ptrToWordPtr)
import Foreign.StablePtr (StablePtr, castStablePtrToPtr)
import GHC.Conc (getNumCapabilities, getNumProcessors, setNumCapabilities)
import GHC.Float (castDoubleToWord64, castFloatToWord32)
import Magic.FFI
  ( SpellCell
  , freeSpellHandle
  , newSpellHandle
  , pmErrArgs
  , pmErrInternal
  , pmErrQuota
  , pmOk
  , pm_advance
  , pm_advance_ex
  , pm_age
  , pm_free
  , pm_scene_advance
  , pm_scene_count
  , pm_scene_free
  , pm_scene_new
  , sceneRegistryStats
  , spellRegistryStats
  , stepCell
  , stepCellWith
  )
import Magic.Interface (ActiveSpell, Time (..), spellAge)
import System.Mem (getAllocationCounter)
import Test.Hspec

spec :: Spec
spec = describe "thread model (host-runtime F004, C2.2)" $ do
  -- T1 --------------------------------------------------------------------
  it "never loses an update, however the threads interleave" $
    withRaceCapabilities $ \threads -> do
      -- The shipped combinator, on the simplest cell there is.
      ref <- newIORef (0 :: Int)
      raceOn_ threads $ \_ -> replicateM_ bumps (stepCell ref (+ 1))
      atomic <- readIORef ref
      atomic `shouldBe` threads * bumps

      -- Teeth. The same skeleton, the same counts, over the shape this
      -- feature removed: read, yield, write. If THIS keeps its count, the
      -- runner never interleaved anything and the assertion above proved
      -- nothing, so say so instead of passing.
      twin <- newIORef (0 :: Int)
      raceOn_ threads $ \_ -> replicateM_ bumps (nonAtomicBump twin)
      lossy <- readIORef twin
      if lossy >= threads * bumps
        then
          pendingWith
            ( "this runner cannot exhibit the race: the non-atomic twin kept all "
                ++ show (threads * bumps)
                ++ " updates across "
                ++ show threads
                ++ " capabilities"
            )
        else lossy `shouldSatisfy` (< threads * bumps)

  -- T2 --------------------------------------------------------------------
  it "advances one spell handle exactly N steps under contention" $ do
    -- The deterministic half first: it needs no threads and no scheduler.
    src <- readUtf8 ffiSource
    (ffiSource, "writeIORef" `isInfixOf` src) `shouldBe` (ffiSource, False)
    -- ... and the combinators the six sites were moved onto are really there.
    mapM_
      (\needle -> (needle, needle `isInfixOf` src) `shouldBe` (needle, True))
      ["stepCell ref", "stepCellWith ref"]

    withRaceCapabilities $ \threads -> do
      bytes <- spellBytes "ring-fire"
      let (perThread, total) = sharePerThread threads
      handle <- castOk bytes testCtx
      raceOn_ threads $ \_ -> replicateM_ perThread (pm_advance handle raceDt)

      -- The age is the frozen `double` a host reads; compare its bits, not
      -- its value, so a -0.0 for a 0.0 could not pass.
      CDouble age <- pm_age handle
      let Time refAge = spellAge (referenceAt (referenceSpell bytes testCtx) (replicate total raceDtF))
      castDoubleToWord64 age `shouldBe` castDoubleToWord64 refAge

      -- And the whole observed frame, against the same handle-driven path
      -- walked one step at a time.
      raced <- observeSpellHandle bytes handle
      oneAtATime <- withFreshSpell bytes $ \h -> do
        replicateM_ total (pm_advance h raceDt)
        observeSpellHandle bytes h
      liveParticles oneAtATime `shouldSatisfy` (> 0)
      obsBits raced `shouldBe` obsBits oneAtATime
      pm_free handle

  -- T3 --------------------------------------------------------------------
  it "advances, casts into and dismisses one scene without losing an update" $
    withRaceCapabilities $ \threads -> do
      bytes <- spellBytes "ring-fire"
      let budget = exampleBudget bytes
          (perThread, total) = sharePerThread threads

      -- (a) concurrent advance of one scene against the sequential walk.
      raced <- withSceneHandle (threads * budget) $ \sc -> do
        _ <- sceneCastOk sc bytes testCtx
        raceOn_ threads $ \_ -> replicateM_ perThread (pm_scene_advance sc raceDt)
        sceneObserve sc (threads * budget) 64
      oneAtATime <- withSceneHandle (threads * budget) $ \sc -> do
        _ <- sceneCastOk sc bytes testCtx
        replicateM_ total (pm_scene_advance sc raceDt)
        sceneObserve sc (threads * budget) 64
      liveParticles oneAtATime `shouldSatisfy` (> 0)
      obsBits raced `shouldBe` obsBits oneAtATime

      -- (b) room for exactly one spell per thread: all of them get in, the
      -- quota is spent once per spell, and no two casts share an id.
      withSceneHandle (threads * budget) $ \sc -> do
        outcomes <- raceOn threads $ \_ -> sceneCast sc bytes testCtx
        map coCode outcomes `shouldBe` replicate threads pmOk
        n <- pm_scene_count sc
        n `shouldBe` fromIntegral threads
        (code, ids) <- sceneIds sc threads
        code `shouldBe` fromIntegral threads
        let issued = take threads ids
        sort (nub issued) `shouldBe` sort issued

      -- (c) room for fewer spells than there are threads. Without an atomic
      -- admission two threads would both read the same "used" and both be
      -- let in; here exactly `room` are, and the rest are refused.
      let room = max 1 (threads `div` 2)
      room `shouldSatisfy` (< threads)
      withSceneHandle (room * budget) $ \sc -> do
        outcomes <- raceOn threads $ \_ -> sceneCast sc bytes testCtx
        length (filter ((== pmOk) . coCode) outcomes) `shouldBe` room
        length (filter ((== pmErrQuota) . coCode) outcomes) `shouldBe` threads - room
        n <- pm_scene_count sc
        n `shouldBe` fromIntegral room

  -- T4 --------------------------------------------------------------------
  it "casts and frees on many threads at once" $
    withRaceCapabilities $ \threads -> do
      bytes <- spellBytes "ring-fire"
      (liveSpells0, _) <- spellRegistryStats
      (liveScenes0, _) <- sceneRegistryStats

      -- One whole lifecycle per thread, spell side and scene side, all
      -- allocating and releasing registry slots at the same time.
      results <- raceOn threads $ \_ -> do
        h <- castOk bytes testCtx
        replicateM_ raceSteps (pm_advance h raceDt)
        obs <- observeSpellHandle bytes h
        let word = handleWord h
        pm_free h
        sc <- pm_scene_new (fromIntegral (exampleBudget bytes))
        sid <- sceneCastOk sc bytes testCtx
        let sceneWord = handleWord sc
        pm_scene_free sc
        pure (word, sceneWord, sid, obsBits obs)

      -- Every thread ran the same input, so every thread must have got the
      -- same frame — and the same frame the single-threaded path gives.
      reference <- withFreshSpell bytes $ \h -> do
        replicateM_ raceSteps (pm_advance h raceDt)
        observeSpellHandle bytes h
      liveParticles reference `shouldSatisfy` (> 0)
      map (\(_, _, _, o) -> o) results `shouldBe` replicate threads (obsBits reference)

      -- Handle values never repeat, even though slots are recycled.
      let spellWords = map (\(w, _, _, _) -> w) results
          sceneWords = map (\(_, w, _, _) -> w) results
      length (nub spellWords) `shouldBe` threads
      length (nub sceneWords) `shouldBe` threads

      -- Every slot taken during the storm came back.
      (liveSpells1, _) <- spellRegistryStats
      (liveScenes1, _) <- sceneRegistryStats
      (liveSpells1, liveScenes1) `shouldBe` (liveSpells0, liveScenes0)

  -- T7 --------------------------------------------------------------------
  it "keeps a single-threaded advance inside its cost envelope" $ do
    bytes <- spellBytes "ring-fire"
    handle <- castOk bytes testCtx
    alone <- allocationPerAdvance handle
    -- The same handle again, with a thousand more live handles in the
    -- table: resolution is one lookup whatever the table's size, so the
    -- figure may not move.
    crowd <- replicateM crowdSize (castOk bytes testCtx)
    crowded <- allocationPerAdvance handle
    mapM_ pm_free crowd
    pm_free handle

    -- Not vacuous: an atomic read-modify-write allocates, so a zero here
    -- would mean the loop never ran.
    alone `shouldSatisfy` (> 0)
    alone `shouldSatisfy` (<= advanceAllocationCap)
    crowded `shouldSatisfy` (<= advanceAllocationCap)
    abs (crowded - alone) `shouldSatisfy` (<= 8)

  -- T8 --------------------------------------------------------------------
  it "poisons only the handle whose step failed" $ do
    -- What the combinator does when the transition throws: the new value
    -- is installed and then forced, so the cell keeps a thunk that throws
    -- again on every read. Documented, tested, and deliberately accepted
    -- (F004 §6 / A2) because the alternative is a second forcing pass on
    -- every frame.
    cell <- newIORef (1 :: Int)
    thrown <- try (stepCell cell (\_ -> error "F004: the step failed")) :: IO (Either SomeException ())
    isLeft thrown `shouldBe` True
    reread <- try (readIORef cell >>= evaluate) :: IO (Either SomeException Int)
    isLeft reread `shouldBe` True

    -- A cell whose step succeeds is untouched by any of that.
    ok <- newIORef (1 :: Int)
    stepCellWith ok (\v -> (v + 1, v)) `shouldReturn` 1
    readIORef ok `shouldReturn` 2

    -- And the same story through the C surface: one poisoned handle
    -- answers PM_ERR_INTERNAL for good, while its neighbour is bit-exact.
    bytes <- spellBytes "ring-fire"
    poisoned <- newSpellHandle (error "FFIThreadSpec: poisoned spell" :: ActiveSpell)
    healthy <- castOk bytes testCtx
    replicateM_ 3 $ do
      pm_advance_ex poisoned raceDt `shouldReturn` pmErrInternal
      pm_age poisoned `shouldReturn` (-6.0)
    -- A step that throws is an internal error, never an argument error:
    -- the handle itself resolved perfectly well.
    pmErrInternal `shouldSatisfy` (/= pmErrArgs)

    replicateM_ raceSteps (pm_advance healthy raceDt)
    actual <- observeSpellHandle bytes healthy
    reference <- withFreshSpell bytes $ \h -> do
      replicateM_ raceSteps (pm_advance h raceDt)
      observeSpellHandle bytes h
    liveParticles reference `shouldSatisfy` (> 0)
    obsBits actual `shouldBe` obsBits reference

    freeSpellHandle poisoned
    pm_free healthy

-- Race shape ------------------------------------------------------------------

-- | Threads all start together and are collected one 'MVar' each. No
-- sleeps: the starting gate is an empty 'MVar' the main thread fills once
-- every worker is already blocked reading it, so the workers are released
-- within the same scheduler quantum without anyone guessing a duration.
--
-- An exception in a worker is carried back and rethrown here rather than
-- printed to a stderr the test runner ignores.
raceOn :: Int -> (Int -> IO a) -> IO [a]
raceOn n body = do
  gate <- newEmptyMVar
  slots <- forM [0 .. n - 1] $ \i -> do
    done <- newEmptyMVar
    _ <- forkOn i $ do
      () <- readMVar gate
      outcome <- trySome (body i >>= evaluate)
      putMVar done outcome
    pure done
  putMVar gate ()
  results <- mapM takeMVar slots
  mapM (either throwIO pure) results

trySome :: IO a -> IO (Either SomeException a)
trySome = try

raceOn_ :: Int -> (Int -> IO ()) -> IO ()
raceOn_ n body = () <$ raceOn n body

-- | Run the body with enough capabilities for threads to actually run at
-- the same time, and put the runner back the way it was afterwards (the
-- same courtesy "ParallelSampleSpec" extends).
--
-- Two is the floor because one capability makes every "concurrent" test
-- a sequential one; eight is the ceiling because more threads only make
-- the run longer, not the race sharper.
withRaceCapabilities :: (Int -> IO a) -> IO a
withRaceCapabilities k = do
  original <- getNumCapabilities
  available <- getNumProcessors
  let n = max 2 (min 8 available)
  bracket_ (setNumCapabilities n) (setNumCapabilities original) (k n)

-- | The read-modify-write this feature removed, kept alive here and
-- nowhere else so that "the race is reproducible on this machine" is
-- something the suite demonstrates rather than assumes.
nonAtomicBump :: IORef Int -> IO ()
nonAtomicBump ref = do
  v <- readIORef ref
  yield
  writeIORef ref $! v + 1

-- Constants -------------------------------------------------------------------

ffiSource :: FilePath
ffiSource = "src/ffi/Magic/FFI.hs"

-- | Increments per thread in the T1 counter race.
bumps :: Int
bumps = 20000

-- | Advances a real spell is driven by, in total, however many threads
-- share the work. Fixed rather than per-thread so that the age compared
-- does not depend on the machine's core count: at 'raceDt' = 1\/8192 s
-- this is one second of spell time on every runner, and ring-fire has
-- 2049 particles alive at one second (its timing rune emits for four).
-- A frame with particles in it is what makes the bit-exact comparisons
-- mean something — comparing two empty buffers would pass for free.
raceSteps :: Int
raceSteps = 8192

-- | 'raceSteps' split evenly; the remainder is dropped so that the total
-- is exactly @threads * perThread@ and the reference fold is exact.
sharePerThread :: Int -> (Int, Int)
sharePerThread threads = (perThread, perThread * threads)
  where
    perThread = raceSteps `div` threads

raceDtF :: Float
raceDtF = 1 / 8192

raceDt :: CFloat
raceDt = CFloat raceDtF

-- | Live handles added to the table for the second half of T7.
crowdSize :: Int
crowdSize = 1024

-- | Bytes per 'pm_advance' the shell may allocate. The atomic step's own
-- share is about 100 bytes; the rest is 'advanceSpell' on a fieldless
-- spell plus the loop. Generous enough not to be a flake, tight enough
-- that a per-call lock or a copied table would break it.
advanceAllocationCap :: Integer
advanceAllocationCap = 512

-- Helpers ---------------------------------------------------------------------

-- | Bytes allocated per 'pm_advance', measured after a warm-up so no
-- first-call thunk is charged to the average.
allocationPerAdvance :: StablePtr SpellCell -> IO Integer
allocationPerAdvance h = do
  spin warmUp
  startCounter <- getAllocationCounter
  spin measured
  endCounter <- getAllocationCounter
  -- The counter counts DOWN towards an allocation limit.
  pure (fromIntegral (startCounter - endCounter) `div` fromIntegral measured)
  where
    warmUp = 1000 :: Int
    measured = 20000 :: Int
    spin 0 = pure ()
    spin k = pm_advance h raceDt >> spin (k - 1)

-- | Observe a spell handle into host arrays sized from its own budget.
observeSpellHandle :: BS.ByteString -> StablePtr SpellCell -> IO Observed
observeSpellHandle bytes h = observeRaw h (exampleBudget bytes) 64

-- | A freshly cast spell for the body, freed however the body ends.
withFreshSpell :: BS.ByteString -> (StablePtr SpellCell -> IO a) -> IO a
withFreshSpell bytes k = do
  h <- castOk bytes testCtx
  a <- k h
  pm_free h
  pure a

-- | Every float and word 'pm_observe' wrote, as bit patterns. Comparing
-- 'Float's directly would accept a @-0.0@ where a @0.0@ belongs, in as
-- many places as there are particles.
obsBits :: Observed -> (CInt, [CInt], [Word32])
obsBits o =
  ( obCode o
  , obInfo o
  , concatMap
      (map castFloatToWord32)
      [obPosX o, obPosY o, obPosZ o, obSize o, obLife o]
      ++ obColor o
  )

-- | Particles the batch descriptors account for — the guard against a
-- bit-exact comparison of two empty frames.
liveParticles :: Observed -> Int
liveParticles o = sum [fromIntegral (obInfo o !! (4 * i + 1)) | i <- [0 .. batches - 1]]
  where
    batches = max 0 (fromIntegral (obCode o))

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

handleWord :: StablePtr a -> Word
handleWord = fromIntegral . ptrToWordPtr . castStablePtrToPtr

