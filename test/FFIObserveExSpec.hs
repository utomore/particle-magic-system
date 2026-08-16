-- | S4 (func-spec 0023 §6): @pm_observe_ex@, the nine-column copy-out.
--
-- The entry point exists because the frozen six-column signature had
-- nowhere to put velocity, and ADR-0011 D7's answer to that is "add a new
-- function, do not touch the old one". So the sharpest assertion in this
-- file is a negative one: with the three velocity pointers @NULL@, the new
-- entry point writes exactly what the old one writes, every byte of every
-- column and every guard slot included. If that holds, no deployed host
-- can tell this round happened.
--
-- Exercised in process, like every other func-spec 0009 descendant: the
-- foreign exports are ordinary Haskell functions, so the test allocates
-- real @Ptr@s and calls them as a C host would.
module FFIObserveExSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Foreign.C.Types (CFloat (..), CInt (..))
import Foreign.Marshal.Array (peekArray, withArray)
import Foreign.Ptr (nullPtr)
import Foreign.StablePtr (StablePtr)
import GHC.Float (float2Double)
import Magic.FFI
  ( SpellCell
  , pm_advance
  , pm_free
  , pm_observe
  , pm_observe_ex
  , pmErrCapacity
  )
import Magic.Interface
  ( ActiveSpell
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , advanceSpell
  , observeSpell
  , pbCount
  , pbVelX
  , pbVelY
  , pbVelZ
  )
import Test.Hspec

import FFIHarness
  ( Observed (..)
  , castOk
  , floatSentinel
  , guardSlots
  , intSentinel
  , observeRaw
  , referenceSpell
  , spellBytes
  , testCtx
  , wordSentinel
  )

-- | Everything @pm_observe_ex@ wrote — the six of 'Observed' plus the
-- three velocity columns, guard region included.
data ObservedEx = ObservedEx
  { oxCode :: CInt
  , oxPosX :: [Float]
  , oxPosY :: [Float]
  , oxPosZ :: [Float]
  , oxSize :: [Float]
  , oxLife :: [Float]
  , oxColor :: [Word32]
  , oxVelX :: [Float]
  , oxVelY :: [Float]
  , oxVelZ :: [Float]
  , oxInfo :: [CInt]
  }
  deriving (Eq, Show)

-- | The six columns of an 'ObservedEx', shaped like an 'Observed' so the
-- two entry points can be compared as values.
sixOf :: ObservedEx -> Observed
sixOf ox =
  Observed
    { obCode = oxCode ox
    , obPosX = oxPosX ox
    , obPosY = oxPosY ox
    , obPosZ = oxPosZ ox
    , obSize = oxSize ox
    , obLife = oxLife ox
    , obColor = oxColor ox
    , obInfo = oxInfo ox
    }

-- | Call @pm_observe_ex@ with the given host capacities. @wantVelocity@
-- chooses between passing three real arrays and passing @NULL@ — the two
-- shapes the contract promises.
observeExRaw :: StablePtr SpellCell -> Bool -> Int -> Int -> IO ObservedEx
observeExRaw handle wantVelocity capacity maxBatches = do
  let slots = max 0 capacity + guardSlots
      infoSlots = 4 * max 0 maxBatches + guardSlots
      sentinels = replicate slots (CFloat floatSentinel)
  withArray sentinels $ \px ->
    withArray sentinels $ \py ->
      withArray sentinels $ \pz ->
        withArray sentinels $ \psize ->
          withArray sentinels $ \plife ->
            withArray (replicate slots wordSentinel) $ \pcolor ->
              withArray sentinels $ \pvx ->
                withArray sentinels $ \pvy ->
                  withArray sentinels $ \pvz ->
                    withArray (replicate infoSlots intSentinel) $ \pinfo -> do
                      let (vx, vy, vz)
                            | wantVelocity = (pvx, pvy, pvz)
                            | otherwise = (nullPtr, nullPtr, nullPtr)
                      code <-
                        pm_observe_ex
                          handle
                          px
                          py
                          pz
                          psize
                          plife
                          pcolor
                          vx
                          vy
                          vz
                          (fromIntegral capacity)
                          pinfo
                          (fromIntegral maxBatches)
                      let floats p = map (\(CFloat f) -> f) <$> peekArray slots p
                      ObservedEx code
                        <$> floats px
                        <*> floats py
                        <*> floats pz
                        <*> floats psize
                        <*> floats plife
                        <*> peekArray slots pcolor
                        <*> floats pvx
                        <*> floats pvy
                        <*> floats pvz
                        <*> peekArray infoSlots pinfo

capacity :: Int
capacity = 4096

maxBatches :: Int
maxBatches = 16

-- | Cast a shipped spell through the C ABI and advance it a few frames, so
-- there are live particles (and, for a field spell, an integrated field
-- state) to observe.
withSpell :: String -> Int -> (StablePtr SpellCell -> IO a) -> IO a
withSpell name frames k = do
  bytes <- spellBytes name
  handle <- castOk bytes testCtx
  mapM_ (\_ -> pm_advance handle (CFloat (1 / 60))) [1 .. frames :: Int]
  result <- k handle
  pm_free handle
  pure result

-- | The reference spell advanced the same number of frames, through the
-- same @float@ widening the C ABI performs.
advanceN :: Int -> ActiveSpell -> ActiveSpell
advanceN n spell = iterate step spell !! n
  where
    step = advanceSpell (FrameInput (DeltaTime (float2Double (1 / 60))))

spec :: Spec
spec = describe "pm_observe_ex (func-spec 0023 §6 S4)" $ do
  describe "the add-only promise" $ do
    it "with NULL velocity pointers, is pm_observe byte for byte" $
      mapM_
        ( \name -> withSpell name 40 $ \handle -> do
            old <- observeRaw handle capacity maxBatches
            new <- observeExRaw handle False capacity maxBatches
            sixOf new `shouldBe` old
        )
        ["ring-fire", "gravity-well", "comet-trail"]

    it "is pm_observe even for a spell that does have velocity" $
      -- The case worth naming: comet-trail computes velocity, and a host
      -- that never asked for it must still see the pre-0023 picture.
      withSpell "comet-trail" 60 $ \handle -> do
        old <- observeRaw handle capacity maxBatches
        new <- observeExRaw handle False capacity maxBatches
        sixOf new `shouldBe` old

    it "leaves the velocity arrays untouched when the pointers are NULL" $
      withSpell "comet-trail" 60 $ \handle -> do
        ox <- observeExRaw handle False capacity maxBatches
        -- The arrays were allocated and sentinel-filled either way; NULL
        -- means the library never saw them.
        oxVelX ox `shouldSatisfy` all (== floatSentinel)
        oxVelY ox `shouldSatisfy` all (== floatSentinel)
        oxVelZ ox `shouldSatisfy` all (== floatSentinel)

  describe "the nine columns agree with the Haskell path" $ do
    it "writes observeSpell's velocity, row for row" $ do
      bytes <- spellBytes "comet-trail"
      let reference = advanceN 60 (referenceSpell bytes testCtx)
          expected = velocityRowsOf (observeSpell reference)
      withSpell "comet-trail" 60 $ \handle -> do
        ox <- observeExRaw handle True capacity maxBatches
        let n = length expected
        take n (oxVelX ox) `shouldBe` map (\(x, _, _) -> x) expected
        take n (oxVelY ox) `shouldBe` map (\(_, y, _) -> y) expected
        take n (oxVelZ ox) `shouldBe` map (\(_, _, z) -> z) expected

    it "never writes past the promised range" $
      withSpell "comet-trail" 60 $ \handle -> do
        ox <- observeExRaw handle True capacity maxBatches
        let total = totalOf ox
        drop total (oxVelX ox) `shouldSatisfy` all (== floatSentinel)
        drop total (oxVelY ox) `shouldSatisfy` all (== floatSentinel)
        drop total (oxVelZ ox) `shouldSatisfy` all (== floatSentinel)

  describe "a spell with no trail, asked for velocity anyway" $
    it "fills zeros rather than reporting an error" $
      -- Whether a spell trails is the spell's business; a host should not
      -- have to change the shape of its call because the player loaded a
      -- different circle.
      withSpell "ring-fire" 40 $ \handle -> do
        ox <- observeExRaw handle True capacity maxBatches
        let total = totalOf ox
        oxCode ox `shouldSatisfy` (>= 0)
        total `shouldSatisfy` (> 0)
        take total (oxVelX ox) `shouldSatisfy` all (== 0)
        take total (oxVelY ox) `shouldSatisfy` all (== 0)
        take total (oxVelZ ox) `shouldSatisfy` all (== 0)
        -- and still nothing past the range
        drop total (oxVelX ox) `shouldSatisfy` all (== floatSentinel)

  describe "the all-or-nothing error path is the same one" $ do
    it "reports PM_ERR_CAPACITY when the particles do not fit" $
      withSpell "comet-trail" 60 $ \handle -> do
        ox <- observeExRaw handle True 1 maxBatches
        oxCode ox `shouldBe` pmErrCapacity

    it "writes nothing at all on that path, velocity included" $
      withSpell "comet-trail" 60 $ \handle -> do
        ox <- observeExRaw handle True 1 maxBatches
        oxPosX ox `shouldSatisfy` all (== floatSentinel)
        oxVelX ox `shouldSatisfy` all (== floatSentinel)
        oxVelY ox `shouldSatisfy` all (== floatSentinel)
        oxVelZ ox `shouldSatisfy` all (== floatSentinel)
        oxColor ox `shouldSatisfy` all (== wordSentinel)
        oxInfo ox `shouldSatisfy` all (== intSentinel)

    it "reports it when the batches do not fit either" $
      withSpell "comet-trail" 60 $ \handle -> do
        ox <- observeExRaw handle True capacity 0
        oxCode ox `shouldBe` pmErrCapacity
        oxVelX ox `shouldSatisfy` all (== floatSentinel)

-- | Total particles the batch descriptors account for.
totalOf :: ObservedEx -> Int
totalOf ox
  | oxCode ox <= 0 = 0
  | otherwise =
      sum
        [ fromIntegral (oxInfo ox !! (4 * i + 1))
        | i <- [0 .. fromIntegral (oxCode ox) - 1]
        ]

-- | The velocity of every particle of every batch, in batch order.
velocityRowsOf :: FrameOutput -> [(Float, Float, Float)]
velocityRowsOf out =
  [ (at pbVelX, at pbVelY, at pbVelZ)
  | b <- batches out
  , let pb = rbParticles b
  , i <- [0 .. pbCount pb - 1]
  , let at f = if U.null (f pb) then 0 else f pb U.! i
  ]
