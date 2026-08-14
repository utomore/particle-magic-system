-- | S8 (func-spec 0007 §8): the two end-to-end hazards ADR-0010 was
-- written to rule out, checked through the real pipeline (compile ->
-- sample -> field integration -> overlay) rather than on the state
-- machine in isolation.
--
--   * /No teleport/ (D3): particles respawn cyclically on their envelope,
--     and the buffer row they occupy moves under them. On the step a
--     particle is (re)born its rendered position must be exactly its
--     analytic position — no leftover displacement from the previous
--     tenant of that slot, and no head start from its own first step.
--
--   * /Row alignment/ (D2): the displacement added to buffer row @j@ must
--     be the displacement of the slot that actually produced row @j@. The
--     assertion recomputes the whole field state independently, through
--     the exported core functions, and compares row by row.
module FieldRebirthSpec (spec) where

import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Compile (CompiledSpell (..), EmitterSpec (..), Phase (..), compile)
import Magic.Interface
  ( CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , observeSpell
  )
import Magic.Particle.Analytic (aliveSlots, particleAge, particlePosition, sample)
import Magic.Particle.Field (FieldState, displacementsInOrder, emptyFieldState, step)
import Magic.Rune (Envelope (..), ForceField (..), InnerRune (..))
import Magic.Types (norm)
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 8080}

fields :: [ForceField]
fields = [Gravity (V3 0 (-12) 0), PointAttractor (V3 0.5 0 2) 9 0.35]

-- | Short-lived particles (0.25 s) inside a long spawn window: every slot
-- is reborn a dozen times over the walk, which is what makes the
-- no-teleport law bite.
churningCircle :: Circle
churningCircle =
  emptyCircle
    { innerRings =
        TwoOf (Just (TimingRune (Envelope (Seconds 0) (Seconds 3) (Seconds 0.25)))) Nothing
    , circleFields = fields
    }

-- | Same, with formation emitters in the mix, so the row alignment has to
-- cope with several emitters and a field-exempt phase at once.
churningPhased :: Circle
churningPhased =
  churningCircle {circlePhases = Just (PhaseConfig (Seconds 0.8) (Seconds 0.4))}

dt :: Double
dt = 0.02

steps :: Int
steps = 150

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

positionsOf :: ParticleBuffer -> [V3]
positionsOf buf =
  [V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) | j <- [0 .. pbCount buf - 1]]

-- | The observed (field-displaced) buffer at every step of the walk.
observedFrames :: Circle -> [ParticleBuffer]
observedFrames circle = case castSpell CastRequest {circleOf = circle, ctxOf = ctx} of
  Left err -> error (show err)
  Right spell0 -> go spell0 steps
  where
    go _ 0 = []
    go s n =
      let s' = advanceSpell (FrameInput (DeltaTime dt)) s
       in firstBuffer (observeSpell s') : go s' (n - 1)

firstBuffer :: FrameOutput -> ParticleBuffer
firstBuffer out = case batches out of
  (batch : _) -> rbParticles batch
  [] -> error "observeSpell produced no render batch"

-- | The clock values the walk visits, accumulated exactly as
-- 'advanceSpell' accumulates them.
walkTimes :: [Time]
walkTimes = map Time (drop 1 (scanl (+) 0 (replicate steps dt)))

-- Independent recomputation ---------------------------------------------------

-- | This step's (age, base position) per slot — the same contract
-- 'Magic.Interface' feeds the field layer, rebuilt here from the exported
-- core functions only.
inputsAt :: CompiledSpell -> Time -> V.Vector (V.Vector (Maybe (Double, V3)))
inputsAt spell t = V.map emitterInputs (spellEmitters spell)
  where
    emitterInputs em
      | emPhase em /= Casting = V.replicate (emCount em) Nothing
      | otherwise = V.generate (emCount em) $ \i ->
          case particleAge (emSpawn em) (emCount em) i t of
            Nothing -> Nothing
            Just age -> Just (age, particlePosition ctx t em i age)

-- | The field state after each step of the walk.
referenceStates :: CompiledSpell -> [FieldState]
referenceStates spell =
  drop 1 (scanl advance (emptyFieldState (map emCount (V.toList (spellEmitters spell)))) walkTimes)
  where
    advance st t = step (spellFields spell) (DeltaTime dt) (inputsAt spell t) st

-- | Analytic positions at each step.
referencePositions :: CompiledSpell -> [[V3]]
referencePositions spell = [positionsOf (sample spell ctx t) | t <- walkTimes]

-- | Ages per slot at each step, plus the previous step's ages — enough to
-- classify a slot as (re)born on that step by exactly the rule
-- 'Magic.Particle.Field.stepSlot' uses.
births :: CompiledSpell -> [[(Int, Int)]]
births spell = zipWith born (Nothing : map Just walkTimes) walkTimes
  where
    born mPrev t =
      [ (e, i)
      | (e, em) <- zip [0 ..] (V.toList (spellEmitters spell))
      , emPhase em == Casting
      , i <- [0 .. emCount em - 1]
      , Just age <- [particleAge (emSpawn em) (emCount em) i t]
      , case mPrev >>= particleAge (emSpawn em) (emCount em) i of
          Nothing -> True
          Just prevAge -> age < prevAge
      ]

spec :: Spec
spec = describe "rebirth and row alignment, end to end (spec 0007 S8)" $ do
  mapM_ noTeleport [("plain discharge", churningCircle), ("with formation", churningPhased)]
  mapM_ rowAlignment [("plain discharge", churningCircle), ("with formation", churningPhased)]

noTeleport :: (String, Circle) -> Spec
noTeleport (label, circle) = describe ("no teleport on (re)birth: " ++ label) $ do
  let spell = compiledOf circle
      frames = observedFrames circle
      analytic = referencePositions spell
      slotLists = [aliveSlots spell t | t <- walkTimes]
      bornLists = births spell

  it "the fixture really does churn (many rebirths across the walk)" $ do
    let laterBirths = concat (drop 2 bornLists)
    length laterBirths `shouldSatisfy` (> 50)

  it "every (re)born particle renders exactly at its analytic position" $ do
    let offenders =
          [ (n, slot, o, a)
          | (n, buf, as, slots, born) <- zip5 [0 :: Int ..] frames analytic slotLists bornLists
          , let observedRow = positionsOf buf
          , (slot, o, a) <- zip3 slots observedRow as
          , slot `elem` born
          ]
        wrong = [x | x@(_, _, o, a) <- offenders, o /= a]
    length offenders `shouldSatisfy` (> 50)
    wrong `shouldBe` []

  it "particles that are NOT newly born do get displaced (the law is not vacuous)" $ do
    let moved =
          [ norm (o - a)
          | (buf, as, slots, born) <- zip4 (drop 60 frames) (drop 60 analytic) (drop 60 slotLists) (drop 60 bornLists)
          , (slot, o, a) <- zip3 slots (positionsOf buf) as
          , slot `notElem` born
          ]
    maximum (0 : moved) `shouldSatisfy` (> 0.01)

rowAlignment :: (String, Circle) -> Spec
rowAlignment (label, circle) = describe ("row alignment: " ++ label) $ do
  let spell = compiledOf circle
      frames = observedFrames circle
      analytic = referencePositions spell
      states = referenceStates spell
      slotLists = [aliveSlots spell t | t <- walkTimes]

  it "the overlay never changes the row count" $
    map pbCount frames `shouldBe` map length analytic

  it "every row's displacement is that row's own slot's displacement" $ do
    let mismatches =
          [ (n, expected, actual)
          | (n, buf, as, slots, st) <- zip5 [0 :: Int ..] frames analytic slotLists states
          , let expected = zipWith (+) as (displacementsInOrder st slots)
          , let actual = positionsOf buf
          , expected /= actual
          ]
    mismatches `shouldBe` []

  it "the independent recomputation is not trivially zero" $ do
    let total = sum [norm d | (st, slots) <- zip states slotLists, d <- displacementsInOrder st slots]
    total `shouldSatisfy` (> 1)

zip4 :: [a] -> [b] -> [c] -> [d] -> [(a, b, c, d)]
zip4 (a : as) (b : bs) (c : cs) (d : ds) = (a, b, c, d) : zip4 as bs cs ds
zip4 _ _ _ _ = []

zip5 :: [a] -> [b] -> [c] -> [d] -> [e] -> [(a, b, c, d, e)]
zip5 (a : as) (b : bs) (c : cs) (d : ds) (e : es) = (a, b, c, d, e) : zip5 as bs cs ds es
zip5 _ _ _ _ _ = []
