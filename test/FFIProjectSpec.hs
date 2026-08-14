-- | S3 (func-spec 0011 §7): the two projection entry points of the C ABI.
--
-- Both are supposed to be 'Magic.Projection' with a type crossing in
-- front of it and nothing else (the zero-new-semantics rule, func-spec
-- 0009 §2), so both are tested as equivalences against the Haskell
-- function they wrap — bit for bit, because @orthographic@ is pure
-- component selection and the FFI marshalling goes through a cast pointer
-- for exactly that reason.
--
-- Every output array is over-allocated by 'guardSlots' and pre-filled
-- with a sentinel, so each property also asserts the negative: nothing
-- outside the promised range is touched, and on the error path nothing is
-- touched at all.
module FFIProjectSpec (spec) where

import Data.Word (Word32)
import Foreign.C.Types (CFloat (..), CInt (..))
import Foreign.Marshal.Array (peekArray, withArray)
import Foreign.Ptr (nullPtr)
import qualified Data.Vector.Unboxed as U
import Magic.Columns (fromColumns)
import Magic.FFI (pm_depth_order, pm_project, pmErrArgs, pmOk, pmPlaneSideXY, pmPlaneTopXZ)
import Magic.Particle.Buffer (ParticleBuffer, fromParticles)
import Magic.Projection (V2 (..), ViewPlane (..), depthOrder, orthographic)
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Test.QuickCheck.Monadic (assert, monadicIO, monitor, run)

-- | Positions whose depths collide often, so 'pm_depth_order' has to
-- reproduce the Haskell sort's /stability/, not just its ordering.
newtype Positions = Positions [V3]
  deriving (Show)

instance Arbitrary Positions where
  arbitrary = do
    n <- choose (0, 40)
    Positions <$> vectorOf n position
    where
      position =
        V3
          <$> choose (-100, 100)
          <*> elements [-2, -1, 0, 1, 2, 3.5]
          <*> elements [-2, -1, 0, 1, 2, 3.5]

-- | The full particle rows, for the padding law: whatever the other three
-- columns hold, the order must not move.
newtype Rows = Rows [(V3, Float, Float, Word32)]
  deriving (Show)

instance Arbitrary Rows where
  arbitrary = do
    Positions ps <- arbitrary
    Rows <$> traverse row ps
    where
      row p = (,,,) p <$> choose (0.01, 5) <*> choose (0, 1) <*> arbitrary

genPlane :: Gen (ViewPlane, CInt)
genPlane = elements [(SideXY, pmPlaneSideXY), (TopXZ, pmPlaneTopXZ)]

-- Host-side marshalling ------------------------------------------------------

guardSlots :: Int
guardSlots = 4

floatSentinel :: Float
floatSentinel = -12345.5

intSentinel :: CInt
intSentinel = -999

-- | Everything @pm_project@ wrote: the status code and the three output
-- arrays in full, guard region included.
data Projected = Projected
  { prCode :: CInt
  , prU :: [Float]
  , prV :: [Float]
  , prDepth :: [Float]
  }
  deriving (Eq, Show)

-- | Call @pm_project@ as a C host would. @slots@ is how many elements the
-- host allocates before the guard region; @count@ is what it claims.
projectRaw :: CInt -> [V3] -> Int -> CInt -> Bool -> IO Projected
projectRaw plane ps slots count outputsPresent =
  withColumn [x | V3 x _ _ <- ps] $ \px ->
    withColumn [y | V3 _ y _ <- ps] $ \py ->
      withColumn [z | V3 _ _ z <- ps] $ \pz ->
        withOut $ \outU ->
          withOut $ \outV ->
            withOut $ \outD -> do
              let use p = if outputsPresent then p else nullPtr
              code <- pm_project plane px py pz count (use outU) (use outV) (use outD)
              Projected code <$> floats outU <*> floats outV <*> floats outD
  where
    allocated = slots + guardSlots
    withColumn xs = withArray (map CFloat xs ++ replicate guardSlots (CFloat floatSentinel))
    withOut = withArray (replicate allocated (CFloat floatSentinel))
    floats p = map (\(CFloat f) -> f) <$> peekArray allocated p

-- | Call @pm_depth_order@ the same way.
depthOrderRaw :: CInt -> [V3] -> Int -> CInt -> Bool -> IO (CInt, [CInt])
depthOrderRaw plane ps slots count outputPresent =
  withColumn [x | V3 x _ _ <- ps] $ \px ->
    withColumn [y | V3 _ y _ <- ps] $ \py ->
      withColumn [z | V3 _ _ z <- ps] $ \pz ->
        withArray (replicate (slots + guardSlots) intSentinel) $ \out -> do
          code <- pm_depth_order plane px py pz count (if outputPresent then out else nullPtr)
          (,) code <$> peekArray (slots + guardSlots) out
  where
    withColumn xs = withArray (map CFloat xs ++ replicate guardSlots (CFloat floatSentinel))

-- | The guard region of an over-allocated array, which nothing may write.
guardRegion :: [a] -> [a]
guardRegion = take guardSlots . reverse

-- Reference paths -------------------------------------------------------------

bufferOf :: [V3] -> ParticleBuffer
bufferOf ps = fromParticles [(p, 1, 1, 0) | p <- ps]

spec :: Spec
spec = describe "C ABI projection (func-spec 0011 §7 S3)" $ do
  describe "pm_project" $ do
    prop "is orthographic, point by point, bit for bit" $ \(Positions ps) ->
      forAll genPlane $ \(plane, code) -> monadicIO $ do
        let n = length ps
        result <- run (projectRaw code ps n (fromIntegral n) True)
        let expected = map (orthographic plane) ps
        monitor (counterexample (show result))
        assert (prCode result == pmOk)
        assert (take n (prU result) == [u | (V2 u _, _) <- expected])
        assert (take n (prV result) == [v | (V2 _ v, _) <- expected])
        assert (take n (prDepth result) == [d | (_, d) <- expected])

    prop "writes nothing past the count it was given" $ \(Positions ps) ->
      forAll genPlane $ \(_, code) -> monadicIO $ do
        let n = length ps
        result <- run (projectRaw code ps n (fromIntegral n) True)
        assert (all (== floatSentinel) (guardRegion (prU result)))
        assert (all (== floatSentinel) (guardRegion (prV result)))
        assert (all (== floatSentinel) (guardRegion (prDepth result)))

    prop "projects a prefix when the host asks for one" $ \(Positions ps) ->
      forAll genPlane $ \(plane, code) ->
        forAll (choose (0, length ps)) $ \k -> monadicIO $ do
          result <- run (projectRaw code ps (length ps) (fromIntegral k) True)
          let expected = map (orthographic plane) (take k ps)
          assert (prCode result == pmOk)
          assert (take k (prU result) == [u | (V2 u _, _) <- expected])
          -- untouched past k, sentinel and all
          assert (all (== floatSentinel) (drop k (prU result)))

    it "rejects an unknown plane, writing nothing" $ do
      let ps = [V3 1 2 3, V3 4 5 6]
      mapM_
        ( \plane -> do
            result <- projectRaw plane ps 2 2 True
            prCode result `shouldBe` pmErrArgs
            prU result `shouldSatisfy` all (== floatSentinel)
        )
        [2, -1, 99]

    it "rejects a negative count, writing nothing" $ do
      result <- projectRaw pmPlaneSideXY [V3 1 2 3] 1 (-1) True
      prCode result `shouldBe` pmErrArgs
      prU result `shouldSatisfy` all (== floatSentinel)

    it "rejects a NULL output column when there is anything to write" $ do
      result <- projectRaw pmPlaneSideXY [V3 1 2 3] 1 1 False
      prCode result `shouldBe` pmErrArgs

    it "tolerates NULL columns when the count is zero (as pm_observe does)" $ do
      code <- pm_project pmPlaneSideXY nullPtr nullPtr nullPtr 0 nullPtr nullPtr nullPtr
      code `shouldBe` pmOk

  describe "pm_depth_order" $ do
    prop "is depthOrder, index by index" $ \(Positions ps) ->
      forAll genPlane $ \(plane, code) -> monadicIO $ do
        let n = length ps
        (status, indices) <- run (depthOrderRaw code ps n (fromIntegral n) True)
        let expected = map fromIntegral (U.toList (depthOrder plane (bufferOf ps)))
        monitor (counterexample (show indices))
        assert (status == pmOk)
        assert (take n indices == expected)
        assert (all (== intSentinel) (guardRegion indices))

    -- pm_depth_order only receives positions, so the buffer it sorts is
    -- completed with zero size/life/colour columns. This is the law that
    -- makes that padding legitimate rather than a coincidence.
    prop "zero padding cannot reach the result" $ \(Rows rows) ->
      forAll genPlane $ \(plane, _) ->
        let ps = [p | (p, _, _, _) <- rows]
            padded =
              fromColumns
                (U.fromList [x | V3 x _ _ <- ps])
                (U.fromList [y | V3 _ y _ <- ps])
                (U.fromList [z | V3 _ _ z <- ps])
                (U.replicate (length ps) 0)
                (U.replicate (length ps) 0)
                (U.replicate (length ps) 0)
         in fmap (depthOrder plane) padded === Right (depthOrder plane (fromParticles rows))

    it "rejects an unknown plane, writing nothing" $ do
      (status, indices) <- depthOrderRaw 7 [V3 1 2 3] 1 1 True
      status `shouldBe` pmErrArgs
      indices `shouldSatisfy` all (== intSentinel)

    it "rejects a negative count, writing nothing" $ do
      (status, indices) <- depthOrderRaw pmPlaneSideXY [V3 1 2 3] 1 (-1) True
      status `shouldBe` pmErrArgs
      indices `shouldSatisfy` all (== intSentinel)

    it "rejects a NULL output when there is anything to write" $ do
      (status, _) <- depthOrderRaw pmPlaneSideXY [V3 1 2 3] 1 1 False
      status `shouldBe` pmErrArgs

    it "the two planes really disagree across the boundary too" $ do
      -- The same pair ProjectSpec uses, now through C pointers.
      let ps = [V3 0 0 (-5), V3 0 (-5) 5]
      (_, side) <- depthOrderRaw pmPlaneSideXY ps 2 2 True
      (_, top) <- depthOrderRaw pmPlaneTopXZ ps 2 2 True
      take 2 side `shouldBe` [0, 1]
      take 2 top `shouldBe` [1, 0]
