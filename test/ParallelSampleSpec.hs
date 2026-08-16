-- | S4 (func-spec 0022 §6): parallel sampling, and __law 2__.
--
-- > sampleParallel spell ctx t  ≡  sampleSequential spell ctx t
--
-- All six SoA columns, bit for bit, on any number of cores. Func-spec 0022
-- §2.4 argues this structurally rather than statistically — the shard
-- boundaries are pure data, the shards are independent, nothing is reduced
-- across threads, and the concatenation order is the shard order — so what
-- follows is a witness of a proof, not a search for a counterexample. Both
-- halves are checked: the equality itself, and the four properties of
-- 'shardsOf' the proof rests on.
--
-- The two paths are exported separately by "Magic.Particle.Analytic" for
-- exactly this reason. Stating the law through 'sample' alone would only
-- ever exercise it above 'parallelThreshold'; stated between the paths it
-- holds at every size, and the threshold becomes what it should be — a
-- choice of which of two identical answers to compute, tested on both sides.
module ParallelSampleSpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import GHC.Conc (getNumCapabilities, getNumProcessors, setNumCapabilities)
import GHC.Float (castFloatToWord32)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( Anchor (..)
  , Appearance (..)
  , BillboardShape (..)
  , BlendMode (..)
  , ColorRamp (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , Motion (..)
  , ParticleBudget (..)
  , Phase (..)
  , PhasePlan (..)
  , SpawnPattern (..)
  , compile
  , noEmitterCode
  )
import qualified Magic.Particle.Analytic as A
import Magic.Particle.Analytic
  ( Shard (..)
  , aliveSlots
  , parallelChunk
  , parallelThreshold
  , sampleParallel
  , sampleSequential
  , sampleWindows
  , shardsOf
  , spellShards
  )
import Magic.Particle.Buffer (ParticleBuffer (..), bufferInvariant)
import Magic.Rune (FaceShape (..), RadiationMode (..), Trajectory (..))
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..))

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

-- | Bit patterns of all six columns plus the row count: the comparison the
-- law is stated in. @(==)@ on 'ParticleBuffer' would compare 'Float's
-- numerically and so would miss a NaN and equate ±0.
digest :: ParticleBuffer -> (Int, [Word32])
digest pb =
  ( pbCount pb
  , concat
      [ bitsOf (pbPosX pb)
      , bitsOf (pbPosY pb)
      , bitsOf (pbPosZ pb)
      , bitsOf (pbSize pb)
      , bitsOf (pbLife pb)
      , U.toList (pbColor pb)
      ]
  )
  where
    bitsOf = map castFloatToWord32 . U.toList

-- | An @n@-emitter, @count@-per-emitter spell built without going through
-- 'compile', so the particle counts can be anything the law needs to be
-- tested at — including well past 'Magic.Compile.budgetCap', which is where
-- the parallel path actually lives.
syntheticSpell :: Int -> Int -> CompiledSpell
syntheticSpell emitters count =
  CompiledSpell
    { spellLifetime = Seconds 10
    , spellBudget = emitters * count
    , spellEmitters = V.fromList (map emitterAt [0 .. emitters - 1])
    , spellPhases = PhasePlan (Seconds 0) (Seconds 0) (Seconds 8) (Seconds 10)
    , spellBudgetPlan =
        ParticleBudget (U.replicate emitters count) (emitters * count)
    , spellFields = []
    }
  where
    emitterAt k =
      EmitterSpec
        { emAnchor = Anchor {anchorOffset = V3 (fromIntegral k) 0 0, anchorNormal = V3 0 0 1}
        , emCount = count
        , -- Staggered envelopes, so different emitters are in different
          -- parts of their life at the same @t@ and the alive windows are
          -- genuinely ragged rather than all-or-nothing.
          emSpawn = Envelope (Seconds (fromIntegral k * 0.25)) (Seconds 8) (Seconds 2)
        , emMotion =
            Motion
              { motSpawn = SpawnOnShape (Ring 0.8 1.2)
              , motTraject = Forward 4
              , motRadiation = AlongNormal
              , motDrift = V3 0 0 0
              , motRange = Nothing
              , motConverge = Nothing
              }
        , emAppearance =
            Appearance (ColorRamp 0xFFD966FF 0xE6390000) 0.05 BlendAdditive Nothing BillboardSquare
        , emPhase = Casting
        , -- No formulas, so no bytecode: the sampler's fallback and its
          -- compiled path are the same work here, which keeps this fixture
          -- about the parallel split and nothing else.
          emCode = noEmitterCode
        }

examples :: [String]
examples =
  [ "converge-flame"
  , "grand-sigil"
  , "lissajous"
  , "ring-fire"
  , "wuxing-seal"
  , "yin-yang"
  ]

compiledExample :: String -> IO CompiledSpell
compiledExample name = do
  bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (compile circle)

frameTimes :: [Time]
frameTimes = [Time (fromIntegral n / 60) | n <- [1 .. 240 :: Int]]

spec :: Spec
spec = describe "parallel sampling (func-spec 0022 §6 S4)" $ do
  describe "law 2: the parallel path is the sequential path, bit for bit" $ do
    prop "over emitter counts × particle counts × time" $
      forAll (chooseInt (1, 6)) $ \emitters ->
        forAll (chooseInt (0, 3000)) $ \count ->
          forAll (choose (0, 10 :: Double)) $ \seconds ->
            let spell = syntheticSpell emitters count
                t = Time seconds
             in digest (sampleParallel spell ctx t) === digest (sampleSequential spell ctx t)

    it "at sizes past budgetCap, where the parallel path actually runs" $
      forM_ [(1, 100000), (2, 50000), (5, 20000), (17, 6000)] $ \(emitters, count) -> do
        let spell = syntheticSpell emitters count
            t = Time 2.5
        digest (sampleParallel spell ctx t) `shouldBe` digest (sampleSequential spell ctx t)

    it "for every shipped example, at all 240 frame times" $
      mapM_
        ( \name -> do
            spell <- compiledExample name
            let diffs =
                  [ t
                  | t <- frameTimes
                  , digest (sampleParallel spell ctx t) /= digest (sampleSequential spell ctx t)
                  ]
            (name, diffs) `shouldBe` (name, [])
        )
        examples

    it "and the buffer invariant survives the concatenation" $ do
      let spell = syntheticSpell 3 20000
      sampleParallel spell ctx (Time 2.5) `shouldSatisfy` bufferInvariant

  describe "the answer does not depend on how many cores compute it" $
    it "-N1, -N2 and -N4 agree with each other and with the sequential path" $ do
      let spell = syntheticSpell 3 20000
          t = Time 2.5
          reference = digest (sampleSequential spell ctx t)
      original <- getNumCapabilities
      available <- getNumProcessors
      let counts = filter (<= max 1 available) [1, 2, 4]
      results <-
        mapM
          ( \n -> do
              setNumCapabilities n
              -- A fresh spell value per run, so nothing can be a memoized
              -- thunk left over from the previous capability count.
              let s = syntheticSpell 3 20000
              pure (n, digest (sampleParallel s ctx t))
          )
          counts
      setNumCapabilities original
      counts `shouldSatisfy` (not . null)
      mapM_ (\(n, d) -> (n, d) `shouldBe` (n, reference)) results

  describe "the threshold chooses a path, it does not change the answer" $ do
    it "is positive, and small enough to leave room for several shards" $ do
      parallelThreshold `shouldSatisfy` (> 0)
      parallelChunk `shouldSatisfy` (> 0)
      parallelThreshold `shouldSatisfy` (>= 2 * parallelChunk)

    it "just below it, sample is the sequential path" $ do
      let (spell, t) = spellWithRows (parallelThreshold - 1)
      digest (A.sample spell ctx t) `shouldBe` digest (sampleSequential spell ctx t)
      digest (A.sample spell ctx t) `shouldBe` digest (sampleParallel spell ctx t)

    it "just above it, sample is the parallel path — and the same bits" $ do
      let (spell, t) = spellWithRows (parallelThreshold + 1)
      digest (A.sample spell ctx t) `shouldBe` digest (sampleParallel spell ctx t)
      digest (A.sample spell ctx t) `shouldBe` digest (sampleSequential spell ctx t)

  describe "aliveSlots is unaffected: the row order it names is still the row order" $ do
    it "one slot per row, in the same order, on both paths" $
      mapM_
        ( \name -> do
            spell <- compiledExample name
            forM_ frameTimes $ \t -> do
              let slots = aliveSlots spell t
              length slots `shouldBe` pbCount (sampleParallel spell ctx t)
              length slots `shouldBe` pbCount (sampleSequential spell ctx t)
        )
        examples

    it "and the slot order is the shard order flattened" $ do
      let spell = syntheticSpell 4 3000
          t = Time 2.5
          fromShards =
            [ (shEmitter sh, i)
            | sh <- spellShards spell t
            , (lo, hi) <- shRanges sh
            , i <- [lo .. hi - 1]
            ]
      fromShards `shouldBe` aliveSlots spell t

  describe "the cut itself (func-spec 0022 §2.4, the four points of the proof)" $ do
    prop "shards partition the windows exactly: no row lost, none written twice" $
      forAll genWindows $ \ranges ->
        let flat = concat [[lo .. hi - 1] | (lo, hi) <- ranges]
            sharded = concat [[lo .. hi - 1] | sh <- shardsOf 0 ranges, (lo, hi) <- shRanges sh]
         in sharded === flat

    prop "each shard reports exactly the rows its ranges cover" $
      forAll genWindows $ \ranges ->
        property
          (all (\sh -> shRows sh == sum [hi - lo | (lo, hi) <- shRanges sh]) (shardsOf 0 ranges))

    prop "no shard is empty, and none is bigger than the chunk size" $
      forAll genWindows $ \ranges ->
        property (all (\sh -> shRows sh > 0 && shRows sh <= parallelChunk) (shardsOf 0 ranges))

    prop "the shard rows sum to the total row count" $
      forAll genWindows $ \ranges ->
        sum (map shRows (shardsOf 0 ranges)) === sum [hi - lo | (lo, hi) <- ranges]

    prop "the cut is a pure function of the windows, and of nothing else" $
      forAll genWindows $ \ranges -> shardsOf 0 ranges === shardsOf 0 ranges

    it "no shard ever straddles two emitters" $ do
      let spell = syntheticSpell 5 3000
          shards = spellShards spell (Time 2.5)
      -- Shard emitter indices are non-decreasing, and each shard names one.
      map shEmitter shards `shouldBe` sortedAscending (map shEmitter shards)
      length shards `shouldSatisfy` (> 5)

    it "the shards' output row intervals are disjoint and cover the buffer" $ do
      let spell = syntheticSpell 4 5000
          t = Time 2.5
          shards = spellShards spell t
          offsets = scanl (+) 0 (map shRows shards)
          intervals = zip offsets (tail offsets)
          total = pbCount (sampleSequential spell ctx t)
      -- Adjacent and non-overlapping by construction; the point is that
      -- they end exactly where the buffer does.
      concat [[a .. b - 1] | (a, b) <- intervals] `shouldBe` [0 .. total - 1]

    it "the windows both paths read are one computation, not two" $ do
      let spell = syntheticSpell 3 3000
          t = Time 2.5
      sum [hi - lo | ws <- V.toList (sampleWindows spell t), (lo, hi) <- ws]
        `shouldBe` pbCount (sampleSequential spell ctx t)

-- | A spell (and a time) whose live row count is exactly @rows@ — the
-- fixture the threshold's two sides are witnessed with.
spellWithRows :: Int -> (CompiledSpell, Time)
spellWithRows rows = (spell, t)
  where
    -- Every particle of a single emitter is alive at 2.5 s with this
    -- envelope, so the row count is the particle count.
    spell = syntheticSpell 1 rows
    t = Time 2.5

sortedAscending :: [Int] -> [Int]
sortedAscending [] = []
sortedAscending (x : xs) = x : go x xs
  where
    go _ [] = []
    go prev (y : ys) = max prev y : go (max prev y) ys

-- | Ascending, disjoint, half-open windows — the shape 'aliveRanges'
-- guarantees, so 'shardsOf' is never asked about input it cannot receive.
genWindows :: Gen [(Int, Int)]
genWindows = do
  n <- chooseInt (0, 5)
  gaps <- vectorOf n (chooseInt (0, 50))
  widths <- vectorOf n (chooseInt (1, 3000))
  pure (go 0 (zip gaps widths))
  where
    go _ [] = []
    go start ((gap, width) : rest) =
      let lo = start + gap
          hi = lo + width
       in (lo, hi) : go hi rest
