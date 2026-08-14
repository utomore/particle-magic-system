-- | S6 (func-spec 0011 §7): the acceptance run for the host-integration
-- round — the cross-boundary equivalence law, extended over the
-- projection surface.
--
-- Func-spec 0009 proved that @pm_observe@ reproduces 'observeSpell' frame
-- by frame. This round adds two entry points /downstream/ of it, so the
-- law to protect is the composition a real 2D host actually runs:
--
-- @
--   cast → advance ×n → pm_observe → pm_project    ≡ observeSpell → orthographic
--   cast → advance ×n → pm_observe → pm_depth_order ≡ observeSpell → depthOrder
-- @
--
-- Both sides are checked bit for bit, on both view planes, over a full
-- 120-frame flight of every shipped example — the same cadence and the
-- same standard of evidence as @test\/Acceptance9Spec.hs@.
module Acceptance11Spec (spec) where

import qualified Data.ByteString as BS
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
import Foreign.C.Types (CFloat (..), CInt (..))
import Foreign.Marshal.Array (peekArray, withArray)
import GHC.Float (float2Double)
import Magic.FFI
  ( pm_advance
  , pm_depth_order
  , pm_free
  , pm_max_particles
  , pm_project
  , pmMaxParticles
  , pmOk
  , pmPlaneSideXY
  , pmPlaneTopXZ
  )
import Magic.Interface
  ( ActiveSpell
  , DeltaTime (..)
  , FrameInput (..)
  , ParticleBuffer (pbCount, pbPosX, pbPosY, pbPosZ)
  , RenderBatch (..)
  , advanceSpell
  , batches
  , observeSpell
  )
import Magic.Particle.Buffer (fromParticles)
import Magic.Projection (V2 (..), ViewPlane (..), depthOrder, orthographic)
import Magic.Types (V3 (..))
import Test.Hspec

-- | The 0009 cadence: 60Hz with dropped frames and hitches.
cadence :: [Float]
cadence = take 120 (cycle [1 / 60, 1 / 60, 1 / 60, 1 / 30, 0.008, 0.05])

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

planes :: [(String, ViewPlane, CInt)]
planes =
  [ ("SideXY", SideXY, pmPlaneSideXY)
  , ("TopXZ", TopXZ, pmPlaneTopXZ)
  ]

-- | What one frame's projection looks like, on either side of the
-- boundary: the plane coordinates, the depths, and the painter's order.
data Projected = Projected
  { pjU :: [Float]
  , pjV :: [Float]
  , pjDepth :: [Float]
  , pjOrder :: [Int]
  }
  deriving (Eq, Show)

spec :: Spec
spec = describe "host integration surface, end to end (func-spec 0011 §7 S6)" $ do
  it "projects identically on both sides of the C ABI, for every shipped example" $
    mapM_
      (\(name, plane, code) -> mapM_ (pathsAgree plane code name) examples)
      planes

  it "actually projects something (the law would be vacuous otherwise)" $ do
    bytes <- spellBytes "ring-fire"
    frames <- ffiRun pmPlaneSideXY bytes
    maximum (map (length . pjU) frames) `shouldSatisfy` (> 100)
    -- a real permutation, not the identity: the particles are spread in depth
    any (\f -> pjOrder f /= [0 .. length (pjOrder f) - 1]) frames `shouldBe` True

  it "answers the cap query a host would have sized those buffers from" $ do
    queried <- pm_max_particles
    queried `shouldBe` pmMaxParticles
    -- and the observe path really does fit inside what it promises
    bytes <- spellBytes "grand-sigil"
    handle <- castOk bytes testCtx
    mapM_ (pm_advance handle . CFloat) (take 30 cadence)
    obs <- observeRaw handle (fromIntegral queried) 8
    pm_free handle
    obCode obs `shouldSatisfy` (>= 0)

-- | The law, for one plane and one example.
pathsAgree :: ViewPlane -> CInt -> String -> String -> Expectation
pathsAgree plane code planeName name = do
  bytes <- spellBytes name
  actual <- ffiRun code bytes
  let expected = referenceRun plane bytes
  case [i | (i, x, y) <- zip3 [0 :: Int ..] actual expected, x /= y] of
    [] -> length actual `shouldBe` length expected
    (i : _) ->
      expectationFailure
        ( name
            ++ " ("
            ++ planeName
            ++ "): frame "
            ++ show i
            ++ " differs across the boundary\n  FFI:       "
            ++ show (actual !! i)
            ++ "\n  reference: "
            ++ show (expected !! i)
        )

-- | Drive the whole cadence through the C ABI: observe into six columns,
-- then project those columns — exactly what a C or Unity host does.
ffiRun :: CInt -> BS.ByteString -> IO [Projected]
ffiRun plane bytes = do
  handle <- castOk bytes testCtx
  frames <- traverse (frameOf handle) cadence
  pm_free handle
  pure frames
  where
    frameOf handle dt = do
      pm_advance handle (CFloat dt)
      obs <- observeRaw handle (fromIntegral pmMaxParticles) 8
      let n = fromIntegral (obCode obs)
          total = sum [c | (_, c, _, _) <- batchTuples n obs]
      projectColumns
        plane
        (take total (obPosX obs))
        (take total (obPosY obs))
        (take total (obPosZ obs))

-- | The host half of the frame: hand the freshly observed columns
-- straight back to the library's projection entry points.
projectColumns :: CInt -> [Float] -> [Float] -> [Float] -> IO Projected
projectColumns plane xs ys zs =
  withArray (map CFloat xs) $ \px ->
    withArray (map CFloat ys) $ \py ->
      withArray (map CFloat zs) $ \pz ->
        withArray (replicate n zeroF) $ \outU ->
          withArray (replicate n zeroF) $ \outV ->
            withArray (replicate n zeroF) $ \outDepth ->
              withArray (replicate n (0 :: CInt)) $ \outOrder -> do
                projected <- pm_project plane px py pz count outU outV outDepth
                ordered <- pm_depth_order plane px py pz count outOrder
                if projected /= pmOk || ordered /= pmOk
                  then error ("projection entry point refused a real frame: " ++ show (projected, ordered))
                  else
                    Projected
                      <$> floats outU
                      <*> floats outV
                      <*> floats outDepth
                      <*> (map fromIntegral <$> peekArray n outOrder)
  where
    n = length xs
    count = fromIntegral n
    zeroF = CFloat 0
    floats p = map (\(CFloat f) -> f) <$> peekArray n p

-- | The same cadence through 'Magic.Interface' and 'Magic.Projection'.
referenceRun :: ViewPlane -> BS.ByteString -> [Projected]
referenceRun plane bytes =
  map frameOf (drop 1 (scanl advance (referenceSpell bytes testCtx) cadence))
  where
    advance spell dt = advanceSpell (FrameInput (DeltaTime (float2Double dt))) spell
    frameOf = projectSpell plane

-- | Positions of every batch, concatenated in @pm_observe@'s order.
positionsOf :: ActiveSpell -> [V3]
positionsOf spell =
  [ V3 (pbPosX pb U.! i) (pbPosY pb U.! i) (pbPosZ pb U.! i)
  | b <- batches (observeSpell spell)
  , let pb = rbParticles b
  , i <- [0 .. pbCount pb - 1]
  ]

projectSpell :: ViewPlane -> ActiveSpell -> Projected
projectSpell plane spell =
  Projected
    { pjU = [u | (V2 u _, _) <- projected]
    , pjV = [v | (V2 _ v, _) <- projected]
    , pjDepth = [d | (_, d) <- projected]
    , pjOrder = U.toList (depthOrder plane buffer)
    }
  where
    ps = positionsOf spell
    projected = map (orthographic plane) ps
    buffer = fromParticles [(p, 1, 1, 0 :: Word32) | p <- ps]
