-- | S6 (func-spec 0025 §6): the spatial summary crosses the C ABI.
--
-- The same equivalence law every FFI spec in this repo states (ADR-0011
-- D8): each entry point equals its 'Magic.Interface' function, value for
-- value, with the crossing adding nothing. Anything that is true only on
-- the C side is a bug.
--
-- Exercised in process — the foreign-exported functions are ordinary
-- Haskell functions, so real @Ptr@s and real capacities go in, exactly as
-- a C host would send them. Every output array is over-allocated and
-- pre-filled with a sentinel, so "nothing was written at all" is a claim
-- this file can check rather than assume.
module FFISpaceSpec (spec) where

import Control.Monad (forM_)
import Data.Bits (testBit)
import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word64)
import FFIHarness (castOk, referenceAt, referenceSpell, spellBytes, testCtx)
import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CFloat (..), CInt (..))
import Foreign.Marshal.Array (peekArray, withArray)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.StablePtr (StablePtr)
import Foreign.Storable (peek)
import Magic.FFI
  ( SpellCell
  , nullScene
  , nullSpell
  , pmErrArgs
  , pmErrCapacity
  , pmOccupancyDimDefault
  , pmOk
  , pm_advance
  , pm_emitter_box
  , pm_emitter_count
  , pm_free
  , pm_occupancy
  , pm_occupancy_mask
  , pm_scene_cast
  , pm_scene_free
  , pm_scene_new
  , pm_scene_spell_bounds
  , pm_spell_bounds
  , pm_spell_box
  )
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , OccupancyGrid (..)
  , OrientedBox (..)
  , Seed (..)
  , V3 (..)
  , emitterBoxOf
  , emittersOf
  , occupancyMask
  , occupancyOf
  , spellBoundsOf
  , spellBoxOf
  )
import SpaceExamples (exampleNames)
import Test.Hspec

sentinel :: CFloat
sentinel = -987654.0

intSentinel :: CInt
intSentinel = -987654

-- | Example names as 'spellBytes' wants them (it appends the extension).
baseNames :: IO [FilePath]
baseNames = map (\n -> take (length n - length ".json") n) <$> exampleNames

-- | One example cast through the C ABI and, in step with it, through
-- plain 'Magic.Interface' — the two sides every assertion below compares.
withCast :: FilePath -> Int -> (StablePtr SpellCell -> ActiveSpell -> IO a) -> IO a
withCast name frames k = do
  bytes <- spellBytes name
  handle <- castOk bytes testCtx
  let dts = replicate frames (1 / 60 :: Float)
  mapM_ (pm_advance handle . CFloat) dts
  result <- k handle (referenceAt (referenceSpell bytes testCtx) dts)
  pm_free handle
  pure result

spec :: Spec
spec = describe "spatial summary across the C ABI (func-spec 0025 S6)" $ do
  it "pm_spell_bounds equals spellBoundsOf" $ do
    names <- baseNames
    forM_ names $ \name -> withCast name 60 $ \handle reference -> do
      pair <-
        withArray (replicate 3 sentinel) $ \outMin ->
          withArray (replicate 3 sentinel) $ \outMax -> do
            code <- pm_spell_bounds handle outMin outMax
            (name, code) `shouldBe` (name, pmOk)
            (,) <$> peekV3 outMin <*> peekV3 outMax
      (name, pair) `shouldBe` (name, spellBoundsOf reference)

  it "pm_spell_box equals spellBoxOf, axes row major" $ do
    names <- baseNames
    forM_ names $ \name -> withCast name 60 $ \handle reference -> do
      box <- readBox name (pm_spell_box handle)
      (name, box) `shouldBe` (name, spellBoxOf reference)

  it "pm_emitter_count and pm_emitter_box walk the same emitters" $ do
    names <- baseNames
    forM_ names $ \name -> withCast name 60 $ \handle reference -> do
      n <- pm_emitter_count handle
      let ems = emittersOf reference
      (name, fromIntegral n :: Int) `shouldBe` (name, length ems)
      forM_ (zip [0 :: Int ..] ems) $ \(i, em) -> do
        box <- readBox (name ++ " #" ++ show i) (pm_emitter_box handle (fromIntegral i))
        (name, i, box) `shouldBe` (name, i, emitterBoxOf reference em)

  it "pm_occupancy equals occupancyOf, cell for cell" $ do
    names <- baseNames
    forM_ names $ \name ->
      forM_ [1, 3, 4 :: Int] $ \dim -> withCast name 90 $ \handle reference -> do
        let cells = dim * dim * dim
        counts <-
          withArray (replicate (cells + 4) intSentinel) $ \out -> do
            written <- pm_occupancy handle (fromIntegral dim) out (fromIntegral cells)
            (name, dim, written) `shouldBe` (name, dim, fromIntegral cells)
            slots <- peekArray (cells + 4) out
            -- Nothing past the promised range was touched.
            (name, drop cells slots) `shouldBe` (name, replicate 4 intSentinel)
            pure (map fromIntegral (take cells slots))
        (name, dim, counts)
          `shouldBe` (name, dim, U.toList (ogCounts (occupancyOf dim reference)))

  it "pm_occupancy_mask equals occupancyMask" $ do
    names <- baseNames
    forM_ names $ \name -> withCast name 90 $ \handle reference -> do
      mask <- pm_occupancy_mask handle
      (name, mask) `shouldBe` (name, occupancyMask reference)
      -- ... and it is the default grid's own answer, bit by bit.
      let counts = U.toList (ogCounts (occupancyOf (fromIntegral pmOccupancyDimDefault) reference))
      (name, [testBit mask c | c <- [0 .. length counts - 1]])
        `shouldBe` (name, [n > 0 | n <- counts])

  describe "the failure paths, all-or-nothing" $ do
    it "pm_occupancy refuses a short array and writes nothing" $
      withCast "square-burst" 60 $ \handle _ ->
        withArray (replicate 32 intSentinel) $ \out -> do
          -- dim 3 needs 27 cells; offer 26.
          pm_occupancy handle 3 out 26 `shouldReturn` pmErrCapacity
          peekArray 32 out `shouldReturn` replicate 32 intSentinel

    it "pm_occupancy refuses a non-positive dim, and a NULL array" $
      withCast "square-burst" 60 $ \handle _ ->
        withArray (replicate 8 intSentinel) $ \out -> do
          pm_occupancy handle 0 out 8 `shouldReturn` pmErrArgs
          pm_occupancy handle (-2) out 8 `shouldReturn` pmErrArgs
          pm_occupancy handle 1 nullPtr 8 `shouldReturn` pmErrCapacity
          peekArray 8 out `shouldReturn` replicate 8 intSentinel

    it "pm_occupancy_mask answers 0 for a NULL handle" $
      pm_occupancy_mask nullSpell `shouldReturn` (0 :: Word32)

    it "pm_emitter_count answers 0 for a NULL handle" $
      pm_emitter_count nullSpell `shouldReturn` 0

    it "pm_emitter_box refuses an out-of-range index, writing nothing" $
      withCast "square-burst" 60 $ \handle _ -> do
        n <- pm_emitter_count handle
        withArray (replicate 3 sentinel) $ \center ->
          withArray (replicate 9 sentinel) $ \axes ->
            withArray (replicate 3 sentinel) $ \half -> do
              pm_emitter_box handle n center axes half `shouldReturn` pmErrArgs
              pm_emitter_box handle (-1) center axes half `shouldReturn` pmErrArgs
              peekArray 3 center `shouldReturn` replicate 3 sentinel
              peekArray 9 axes `shouldReturn` replicate 9 sentinel
              peekArray 3 half `shouldReturn` replicate 3 sentinel

    it "the box entry points refuse NULL outputs and NULL handles" $
      withCast "square-burst" 60 $ \handle _ ->
        withArray (replicate 9 sentinel) $ \p -> do
          pm_spell_bounds handle nullPtr p `shouldReturn` pmErrArgs
          pm_spell_bounds handle p nullPtr `shouldReturn` pmErrArgs
          pm_spell_bounds nullSpell p p `shouldReturn` pmErrArgs
          pm_spell_box handle nullPtr p p `shouldReturn` pmErrArgs
          pm_spell_box nullSpell p p p `shouldReturn` pmErrArgs
          peekArray 9 p `shouldReturn` replicate 9 sentinel

  describe "the scene entry point" $ do
    it "pm_scene_spell_bounds equals the spell's own bounds" $ do
      bytes <- spellBytes "square-burst"
      scene <- pm_scene_new 100000
      sid <-
        withCString' bytes $ \json ->
          withV3' (casterPos testCtx) $ \pos ->
            withV3' (casterFacing testCtx) $ \facing ->
              with (0 :: CInt) $ \outId -> do
                code <- pm_scene_cast scene json pos facing seedWord nullPtr 0 outId
                code `shouldBe` pmOk
                peek outId
      pair <-
        withArray (replicate 3 sentinel) $ \outMin ->
          withArray (replicate 3 sentinel) $ \outMax -> do
            pm_scene_spell_bounds scene sid outMin outMax `shouldReturn` pmOk
            (,) <$> peekV3 outMin <*> peekV3 outMax
      pair `shouldBe` spellBoundsOf (referenceSpell bytes testCtx)
      pm_scene_free scene

    it "refuses an unknown id, a NULL scene and NULL outputs" $ do
      scene <- pm_scene_new 100000
      withArray (replicate 3 sentinel) $ \p -> do
        pm_scene_spell_bounds scene 99 p p `shouldReturn` pmErrArgs
        pm_scene_spell_bounds nullScene 0 p p `shouldReturn` pmErrArgs
        pm_scene_spell_bounds scene 0 nullPtr p `shouldReturn` pmErrArgs
        peekArray 3 p `shouldReturn` replicate 3 sentinel
      pm_scene_free scene

-- | Read the three output arrays of a box entry point back into an
-- 'OrientedBox', asserting that the call succeeded.
readBox :: String -> (Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> IO CInt) -> IO OrientedBox
readBox label call =
  withArray (replicate 3 sentinel) $ \center ->
    withArray (replicate 9 sentinel) $ \axes ->
      withArray (replicate 3 sentinel) $ \half -> do
        code <- call center axes half
        (label, code) `shouldBe` (label, pmOk)
        c <- peekV3 center
        as <- map unwrap <$> peekArray 9 axes
        V3 hu hv hn <- peekV3 half
        case as of
          [ux, uy, uz, vx, vy, vz, nx, ny, nz] ->
            pure
              OrientedBox
                { obCenter = c
                , obAxisU = V3 ux uy uz
                , obAxisV = V3 vx vy vz
                , obAxisN = V3 nx ny nz
                , obHalfU = hu
                , obHalfV = hv
                , obHalfN = hn
                }
          _ -> error "peekArray 9 returned the wrong length"

peekV3 :: Ptr CFloat -> IO V3
peekV3 p = do
  vs <- map unwrap <$> peekArray 3 p
  case vs of
    [x, y, z] -> pure (V3 x y z)
    _ -> error "peekArray 3 returned the wrong length"

unwrap :: CFloat -> Float
unwrap (CFloat f) = f

-- Marshalling the scene cast's arguments, the same way "FFIHarness" does
-- for the single-spell path (its helpers are private to it).

withCString' :: BS.ByteString -> (CString -> IO a) -> IO a
withCString' bytes = withArray (map fromIntegral (BS.unpack bytes) ++ [0] :: [CChar])

withV3' :: V3 -> (Ptr CFloat -> IO a) -> IO a
withV3' (V3 x y z) = withArray [CFloat x, CFloat y, CFloat z]

seedWord :: Word64
seedWord = let Seed s = seed testCtx in s
