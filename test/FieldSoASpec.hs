-- | S4 (func-spec 0010 §7): the force-field state as unboxed columns.
--
-- Spec 0007 §4.7 left 'Magic.Particle.Field.FieldState''s representation
-- explicitly unfrozen so that a performance round could flatten it. What
-- it did /not/ leave open is the behaviour: 'stepSlot' is still the
-- written-down definition of one slot's transition (ADR-0010 D1/D3), and
-- 'stepColumns' has to be that definition applied slot by slot — bit for
-- bit, not approximately.
--
-- So this module drives both through the same randomly generated
-- scenarios (deaths, rebirths, continuations, several emitters, several
-- fields) and compares slot by slot at every step; then it takes the one
-- shipped example that actually has fields, @gravity-well@, and checks the
-- rendered buffer of a 240-frame flight equals the analytic sample plus
-- the displacements an independent boxed recomputation produces.
module FieldSoASpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Codec (loadCircle)
import Magic.Compile (CompiledSpell (..), EmitterSpec (..), Phase (..), compile)
import Magic.Interface
  ( CastContext (..)
  , CastRequest (..)
  , Circle
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , batches
  , castSpell
  , observeSpell
  )
import Magic.Particle.Analytic (aliveSlots, particleAge, particlePosition, sample)
import Magic.Particle.Field
  ( FieldState (..)
  , SlotState (..)
  , displacementsInOrder
  , emptyFieldState
  , fieldInputsOf
  , quiescent
  , slotAt
  , stepColumns
  , stepSlot
  )
import Magic.Rune (ForceField (..))
import Magic.Types (norm)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (sample)

-- The 0007 reference: the boxed nest, one 'stepSlot' per slot -----------------

type Boxed = V.Vector (V.Vector (Maybe (Double, SlotState)))

emptyBoxed :: [Int] -> Boxed
emptyBoxed counts = V.fromList [V.replicate k Nothing | k <- counts]

referenceStep :: [ForceField] -> DeltaTime -> V.Vector (V.Vector (Maybe (Double, V3))) -> Boxed -> Boxed
referenceStep fields dt inputs previous = V.imap emitter inputs
  where
    emitter e row = V.imap (\i now -> stepSlot fields dt now (priorOf e i)) row
    priorOf e i = case previous V.!? e of
      Nothing -> Nothing
      Just row -> case row V.!? i of
        Nothing -> Nothing
        Just slot -> slot

-- Scenario generation ---------------------------------------------------------

-- | One randomly shaped cast: a slot layout, some fields, a step size and
-- a sequence of per-slot @(age, base position)@ frames that includes
-- deaths, rebirths and plain continuations.
data Scenario = Scenario
  { scCounts :: [Int]
  , scFields :: [ForceField]
  , scDt :: Double
  , scFrames :: [V.Vector (V.Vector (Maybe (Double, V3)))]
  }

instance Show Scenario where
  show sc =
    "Scenario "
      ++ show (scCounts sc)
      ++ " fields="
      ++ show (length (scFields sc))
      ++ " dt="
      ++ show (scDt sc)
      ++ " frames="
      ++ show (length (scFrames sc))

genField :: Gen ForceField
genField =
  oneof
    [ Gravity <$> genV3
    , PointAttractor <$> genV3 <*> choose (-20, 20) <*> choose (0.05, 2)
    , Vortex <$> genV3 <*> pure (V3 0 1 0) <*> choose (-15, 15) <*> choose (0, 3)
    ]

genV3 :: Gen V3
genV3 = V3 <$> choose (-5, 5) <*> choose (-5, 5) <*> choose (-5, 5)

instance Arbitrary Scenario where
  arbitrary = do
    counts <- listOf1 (choose (1, 5))
    fields <- frequency [(1, pure []), (5, listOf1 genField)]
    dt <- choose (0.005, 0.2)
    frameN <- choose (1, 14)
    -- One life pattern per slot: how often it dies and when it respawns.
    let slotTotal = sum counts
    phases <- vectorOf slotTotal (choose (0, 6 :: Int))
    positions <- vectorOf (max 1 slotTotal) genV3
    let frames = [frameAt dt phases positions counts k | k <- [1 .. frameN]]
    pure (Scenario counts fields dt frames)

-- | Slot @j@ at step @k@: dead every seventh step of its own phase, and
-- its age walks 0, dt, 2·dt, … before restarting — so the sequence
-- exercises birth, continuation, death and rebirth in every run.
frameAt :: Double -> [Int] -> [V3] -> [Int] -> Int -> V.Vector (V.Vector (Maybe (Double, V3)))
frameAt dt phases positions counts k =
  V.fromList [V.fromList [slot (base + i) | i <- [0 .. n - 1]] | (base, n) <- zip offsets counts]
  where
    offsets = scanl (+) 0 counts
    slot j =
      let p = cycleAt phases j
          m = (k + p) `mod` 7
       in if m == 0
            then Nothing
            else Just (fromIntegral m * dt, cycleAt positions (j + k))
    cycleAt xs j = case xs of
      [] -> error "FieldSoASpec: empty cycle"
      _ -> xs !! (j `mod` length xs)

-- Fixtures --------------------------------------------------------------------

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

{-# NOINLINE gravityWell #-}
gravityWell :: CompiledSpell
gravityWell = unsafePerformIO $ do
  bytes <- BS.readFile "assets/spells/gravity-well.json"
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (compile circle)

dtWalk :: Double
dtWalk = 1 / 60

walkTimes :: [Time]
walkTimes = map Time (drop 1 (scanl (+) 0 (replicate 240 dtWalk)))

-- | The inputs 'Magic.Interface' feeds the field layer, rebuilt from the
-- exported core functions only (ADR-0010 D6: casting emitters only).
inputsAt :: CompiledSpell -> Time -> V.Vector (V.Vector (Maybe (Double, V3)))
inputsAt spell t = V.map emitterInputs (spellEmitters spell)
  where
    emitterInputs em
      | emPhase em /= Casting = V.replicate (emCount em) Nothing
      | otherwise = V.generate (emCount em) $ \i ->
          case particleAge (emSpawn em) (emCount em) i t of
            Nothing -> Nothing
            Just age -> Just (age, particlePosition ctx t em i age)

-- | Positions of the observed buffer, frame by frame, through the real
-- public path.
observedFrames :: [[V3]]
observedFrames =
  case castSpell CastRequest {circleOf = gravityWellCircle, ctxOf = ctx} of
    Left err -> error (show err)
    Right spell0 -> go spell0 (length walkTimes)
  where
    go _ 0 = []
    go s n =
      let s' = advanceSpell (FrameInput (DeltaTime dtWalk)) s
       in positionsOf (firstBuffer (observeSpell s')) : go s' (n - 1 :: Int)
    positionsOf buf =
      [V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) | j <- [0 .. pbCount buf - 1]]
    firstBuffer out = case batches out of
      (b : _) -> rbParticles b
      [] -> error "observeSpell produced no render batch"

{-# NOINLINE gravityWellCircle #-}
gravityWellCircle :: Circle
gravityWellCircle = unsafePerformIO $ do
  bytes <- BS.readFile "assets/spells/gravity-well.json"
  either (fail . show) pure (loadCircle bytes)

spec :: Spec
spec = describe "FieldState as unboxed columns (func-spec 0010 §7 S4)" $ do
  describe "stepColumns ≡ stepSlot, slot by slot, step by step" $ do
    prop "over randomly generated lives (birth, continuation, death, rebirth)" $
      \sc -> runsAgree sc

    prop "including the fieldless case, where every displacement stays exactly zero" $
      \sc ->
        let sc' = sc {scFields = []}
            final = runColumns sc'
         in conjoin
              [ property (runsAgree sc')
              , counterexample "displacement not exactly zero" $
                  property (U.all (== 0) (dispAll final))
              ]

  describe "the D3 birth rule survives flattening" $ do
    let counts = [1]
        fields = [Gravity (V3 0 (-9.8) 0)]
        dt = DeltaTime 0.1
        alive a = V.fromList [V.fromList [Just (a, V3 0 0 0)]]
        dead = V.fromList [V.fromList [Nothing]]
        stepB inp st = stepColumns fields dt (fieldInputsOf inp) st

    it "a slot's first step is quiescent (no head start)" $ do
      let st1 = stepB (alive 0.1) (emptyFieldState counts)
      slotAt st1 0 0 `shouldBe` Just (0.1, quiescent)

    it "an age that goes backwards wipes the history" $ do
      let st = foldl (\s a -> stepB (alive a) s) (emptyFieldState counts) [0.1, 0.2, 0.3]
          reborn = stepB (alive 0.05) st
      slotAt st 0 0 `shouldNotBe` Just (0.3, quiescent)
      slotAt reborn 0 0 `shouldBe` Just (0.05, quiescent)

    it "a dead slot keeps no state, and comes back clean" $ do
      let st = foldl (\s a -> stepB (alive a) s) (emptyFieldState counts) [0.1, 0.2, 0.3]
          gone = stepB dead st
          back = stepB (alive 0.1) gone
      slotAt gone 0 0 `shouldBe` Nothing
      slotAt back 0 0 `shouldBe` Just (0.1, quiescent)

    it "an unknown slot reads as no state, not as a neighbour's" $ do
      let st = stepB (alive 0.1) (emptyFieldState counts)
      slotAt st 0 1 `shouldBe` Nothing
      slotAt st 5 0 `shouldBe` Nothing

  describe "gravity-well, end to end through the public path" $ do
    let observed = observedFrames
        reference = referenceFrames

    it "renders analytic sample + independently integrated displacement, bit for bit" $
      case [k | (k, a, b) <- zip3 [0 :: Int ..] observed reference, a /= b] of
        [] -> length observed `shouldBe` length reference
        (k : _) ->
          expectationFailure
            ( "frame "
                ++ show k
                ++ " differs\n  observed:  "
                ++ show (take 4 (observed !! k))
                ++ "\n  reference: "
                ++ show (take 4 (reference !! k))
            )

    it "the fixture really is displaced (the law is not vacuous)" $ do
      let analytic = [analyticPositions t | t <- walkTimes]
          drift = maximum (0 : concat (zipWith (zipWith (\o a -> norm (o - a))) observed analytic))
      drift `shouldSatisfy` (> 0.05)

-- | The 0007 reference chain: boxed states, one 'stepSlot' per slot,
-- displacements looked up in buffer-row order and added to the analytic
-- sample.
referenceFrames :: [[V3]]
referenceFrames = zipWith frame walkTimes states
  where
    counts = map emCount (V.toList (spellEmitters gravityWell))
    states =
      drop 1 (scanl advance (emptyFieldState counts) walkTimes)
    advance st t =
      stepColumns (spellFields gravityWell) (DeltaTime dtWalk) (fieldInputsOf (inputsAt gravityWell t)) st
    frame t st =
      zipWith (+) (analyticPositions t) (displacementsInOrder st (aliveSlots gravityWell t))

analyticPositions :: Time -> [V3]
analyticPositions t =
  let buf = sample gravityWell ctx t
   in [V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) | j <- [0 .. pbCount buf - 1]]

-- Scenario runners ------------------------------------------------------------

runColumns :: Scenario -> FieldState
runColumns sc =
  foldl
    (\st inp -> stepColumns (scFields sc) (DeltaTime (scDt sc)) (fieldInputsOf inp) st)
    (emptyFieldState (scCounts sc))
    (scFrames sc)

-- | Fold both implementations in lockstep and compare every slot at every
-- step, not just the final state.
runsAgree :: Scenario -> Property
runsAgree sc = conjoin (go (emptyFieldState (scCounts sc)) (emptyBoxed (scCounts sc)) (zip [0 :: Int ..] (scFrames sc)))
  where
    fields = scFields sc
    dt = DeltaTime (scDt sc)
    slots = [(e, i) | (e, n) <- zip [0 ..] (scCounts sc), i <- [0 .. n - 1]]
    go _ _ [] = []
    go st boxed ((k, inp) : rest) =
      let st' = stepColumns fields dt (fieldInputsOf inp) st
          boxed' = referenceStep fields dt inp boxed
          checks =
            [ counterexample ("step " ++ show k ++ ", slot " ++ show (e, i)) $
                slotAt st' e i === (boxed' V.! e V.! i)
            | (e, i) <- slots
            ]
       in checks ++ go st' boxed' rest

dispAll :: FieldState -> U.Vector Float
dispAll st = U.concat [fsDispX st, fsDispY st, fsDispZ st]
