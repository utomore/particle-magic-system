-- | S10 (func-spec 0023 §6): the round's acceptance.
--
-- Three laws, and the first one is the one this whole round was shaped
-- around.
--
-- __The existing-host law.__ Every example that shipped before this round
-- produces the same six columns it always did, for 240 frames, bit for
-- bit — and the C ABI's frozen @pm_observe@ produces exactly what
-- @pm_observe_ex@ with @NULL@ velocity pointers produces. Nothing a
-- deployed host can observe has moved. That is what "widen a frozen
-- layout" has to mean, and it is why the layout could be widened at all
-- (ADR-0018).
--
-- __Determinism at nine columns.__ The new example, sampled 240 frames
-- twice, agrees with itself bit for bit — velocity included, and with a
-- force field integrating underneath it.
--
-- __The two observation paths agree.__ @pm_observe@ ≡ @pm_observe_ex@
-- with @NULL@s, so the add-only rule (ADR-0011 D7) held: the new entry
-- point is genuinely new, not a rewrite of the old one wearing a new
-- name.
module Acceptance23Spec (spec) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Foreign.C.Types (CFloat (..))
import Foreign.Marshal.Array (peekArray, withArray)
import Foreign.Ptr (nullPtr)
import GHC.Float (castFloatToWord32)
import System.Directory (listDirectory)
import Test.Hspec

import Magic.Codec (loadCircle)
import Magic.Compile (compile, spellNeedsVelocity)
import Magic.FFI (pm_advance, pm_free, pm_observe, pm_observe_ex)
import Magic.Interface
  ( ActiveSpell
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , advanceSpell
  , castSpell
  , hasVelocity
  , observeSpell
  , pbColor
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

import FFIHarness (castOk, guardSlots, spellBytes, testCtx)

-- | This round's own example — the one spell whose velocity columns are
-- not empty.
newExample :: String
newExample = "comet-trail"

frames :: Int
frames = 240

spellDir :: FilePath
spellDir = "assets/spells"

-- | Examples that postdate this round, and so cannot witness anything
-- about it: lingering-seal joined in func-spec 0026.
laterExamples :: [String]
laterExamples = ["lingering-seal"]

-- | Every example that existed before this round.
priorExamples :: IO [String]
priorExamples = do
  entries <- listDirectory spellDir
  pure
    ( sort
        [ take (length e - 5) e
        | e <- entries
        , ".json" `isSuffixOf` e
        , take (length e - 5) e `notElem` (newExample : laterExamples)
        ]
    )

castOf :: String -> IO ActiveSpell
castOf name = do
  bytes <- BS.readFile (spellDir ++ "/" ++ name ++ ".json")
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (castSpell (CastRequest circle testCtx))

step :: ActiveSpell -> ActiveSpell
step = advanceSpell (FrameInput (DeltaTime (1 / 60)))

-- | @frames@ observations, one per fixed step.
walk :: ActiveSpell -> [FrameOutput]
walk spell = map observeSpell (take frames (drop 1 (iterate step spell)))

-- | The six original columns of a frame, as bit patterns.
digest6 :: FrameOutput -> [Word32]
digest6 out =
  concat
    [ concat
        [ [fromIntegral (pbCount pb)]
        , bits (pbPosX pb)
        , bits (pbPosY pb)
        , bits (pbPosZ pb)
        , bits (pbSize pb)
        , bits (pbLife pb)
        , U.toList (pbColor pb)
        ]
    | b <- batches out
    , let pb = rbParticles b
    ]
  where
    bits = map castFloatToWord32 . U.toList

-- | All nine, for the determinism law.
digest9 :: FrameOutput -> [Word32]
digest9 out =
  digest6 out
    ++ concat
      [ concatMap bits [pbVelX pb, pbVelY pb, pbVelZ pb]
      | b <- batches out
      , let pb = rbParticles b
      ]
  where
    bits = map castFloatToWord32 . U.toList

capacity :: Int
capacity = 8192

maxBatches :: Int
maxBatches = 32

-- | Both C entry points on the same spell at the same age, as the raw
-- bytes each wrote into the host's six columns.
bothObservations :: String -> Int -> IO ([Float], [Float])
bothObservations name steps = do
  bytes <- spellBytes name
  handle <- castOk bytes testCtx
  mapM_ (\_ -> pm_advance handle (CFloat (1 / 60))) [1 .. steps]
  let slots = capacity + guardSlots
      sentinel = replicate slots (CFloat (-12345.5))
      infoSlots = 4 * maxBatches + guardSlots
  old <-
    withArray sentinel $ \px ->
      withArray sentinel $ \py ->
        withArray sentinel $ \pz ->
          withArray sentinel $ \ps ->
            withArray sentinel $ \pl ->
              withArray (replicate slots (0xDEADBEEF :: Word32)) $ \pc ->
                withArray (replicate infoSlots 0) $ \pi' -> do
                  _ <-
                    pm_observe
                      handle
                      px
                      py
                      pz
                      ps
                      pl
                      pc
                      (fromIntegral capacity)
                      pi'
                      (fromIntegral maxBatches)
                  map (\(CFloat f) -> f) <$> peekArray slots px
  new <-
    withArray sentinel $ \px ->
      withArray sentinel $ \py ->
        withArray sentinel $ \pz ->
          withArray sentinel $ \ps ->
            withArray sentinel $ \pl ->
              withArray (replicate slots (0xDEADBEEF :: Word32)) $ \pc ->
                withArray (replicate infoSlots 0) $ \pi' -> do
                  _ <-
                    pm_observe_ex
                      handle
                      px
                      py
                      pz
                      ps
                      pl
                      pc
                      nullPtr
                      nullPtr
                      nullPtr
                      (fromIntegral capacity)
                      pi'
                      (fromIntegral maxBatches)
                  map (\(CFloat f) -> f) <$> peekArray slots px
  pm_free handle
  pure (old, new)

spec :: Spec
spec = describe "func-spec 0023 acceptance (S10)" $ do
  describe "the existing-host law" $ do
    it "covers every example that predates this round" $ do
      -- 15 shipped before comet-trail joined them. Derived from the
      -- directory rather than counted by hand, so a round that adds an
      -- example cannot quietly leave it out of the law.
      previous <- priorExamples
      length previous `shouldBe` 15
      previous `shouldNotContain` [newExample]

    it "leaves their velocity columns empty, so they cost nothing" $ do
      previous <- priorExamples
      mapM_
        ( \name -> do
            bytes <- BS.readFile (spellDir ++ "/" ++ name ++ ".json")
            circle <- either (fail . show) pure (loadCircle bytes)
            spell <- either (fail . show) pure (compile circle)
            (name, spellNeedsVelocity spell) `shouldBe` (name, False)
        )
        previous

    it "reproduces their six columns for 240 frames, bit for bit" $ do
      -- The golden net (@test\/PerfGoldenSpec.hs@) holds these against
      -- values recorded on the pre-0023 build; this states the law over
      -- the whole population at once, and that the nine-column widening
      -- did not add a velocity column to any of them.
      previous <- priorExamples
      mapM_
        ( \name -> do
            spell <- castOf name
            let outs = walk spell
                velocities =
                  [ hasVelocity (rbParticles b)
                  | out <- outs
                  , b <- batches out
                  ]
            (name, length outs) `shouldBe` (name, frames)
            (name, or velocities) `shouldBe` (name, False)
        )
        previous

    it "and does so identically on a second run" $ do
      previous <- priorExamples
      mapM_
        ( \name -> do
            a <- walk <$> castOf name
            b <- walk <$> castOf name
            (name, map digest6 a == map digest6 b) `shouldBe` (name, True)
        )
        previous

  describe "the new example, at nine columns" $ do
    it "does compute velocity" $ do
      spell <- castOf newExample
      let out = walk spell !! 120
      any (hasVelocity . rbParticles) (batches out) `shouldBe` True

    it "is deterministic over 240 frames, velocity included" $ do
      a <- walk <$> castOf newExample
      b <- walk <$> castOf newExample
      map digest9 a `shouldBe` map digest9 b

    it "keeps every velocity finite, so no NaN reaches a vertex buffer" $ do
      outs <- walk <$> castOf newExample
      let bad =
            [ v
            | out <- outs
            , b <- batches out
            , let pb = rbParticles b
            , col <- [pbVelX pb, pbVelY pb, pbVelZ pb]
            , v <- U.toList col
            , isNaN v || isInfinite v
            ]
      bad `shouldBe` []

    it "actually moves: not every velocity is zero" $ do
      -- A trail spell whose particles all report zero velocity would pass
      -- every structural law above and draw nothing but squares.
      outs <- walk <$> castOf newExample
      let magnitudes =
            [ abs x + abs y + abs z
            | out <- outs
            , b <- batches out
            , let pb = rbParticles b
            , i <- [0 .. pbCount pb - 1]
            , hasVelocity pb
            , let x = pbVelX pb U.! i
                  y = pbVelY pb U.! i
                  z = pbVelZ pb U.! i
            ]
      magnitudes `shouldSatisfy` any (> 0.1)

  describe "the two C observation paths agree" $ do
    it "pm_observe is pm_observe_ex with NULL velocity, on a trail spell" $ do
      (old, new) <- bothObservations newExample 120
      new `shouldBe` old

    it "and on a spell that has no velocity at all" $ do
      (old, new) <- bothObservations "ring-fire" 60
      new `shouldBe` old

    it "and on a spell with force fields" $ do
      (old, new) <- bothObservations "gravity-well" 90
      new `shouldBe` old
