-- | T4 (func-spec 0026): @hold@ — draw, then freeze.
--
-- The implementation is one branch on a colour ramp, and the reason that
-- is enough is a claim about everything /else/ a formation particle
-- depends on: nothing in its position reads its age. The spin runs off
-- the cast clock (ADR-0020), the trajectory is @Forward 0@, spread and
-- drift are zero, and there is neither a range curve nor a convergence
-- one. So the @formLife@ rebirth cycle's only observable is the fade, and
-- flattening the fade makes the cycle unobservable.
--
-- Two halves, and both are needed:
--
--   * the /colour/ half — with @hold@ on, every live formation row
--     carries the same colour at every instant, so a particle that has
--     just been reborn is indistinguishable from one about to die. With
--     @hold@ off the same measurement finds several colours at once,
--     which is exactly the pulsing func-spec 0017 left behind;
--   * the /position/ half — the same circle sampled with @hold@ on and
--     off agrees on every position, bit for bit, at every instant. Were
--     any age-dependent term hiding in the position, the colour half
--     would still pass and the sigil would still not be frozen.
module SigilHoldSpec (spec) where

import Data.List (nub)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Circle (Circle (..), Core (..), Nodes (..), PhaseConfig (..), SigilTiming (..), emptyCircle)
import Magic.Compile
  ( Appearance (..)
  , ColorRamp (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Phase (..)
  , compile
  )
import Magic.Particle.Analytic (aliveSlots, particleAge, particlePosition, sample)
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Rune (Element (..), EssenceRune (..), NodeRune (..))
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..))
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0.25 (-0.5) 1.0, casterFacing = V3 0 1 0, seed = Seed 4242}

-- | Phases and a node, so both stroke and node emitters are in play.
base :: Circle
base =
  emptyCircle
    { circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))
    , core =
        Core
          (Just (EssenceRune Fire 1.0))
          (Nodes (Just (DirBias 0.2)) Nothing Nothing Nothing)
    }

withHold :: Bool -> Circle -> Circle
withHold hold c = c {circleSigil = Just (SigilTiming (Seconds 0) hold)}

compiled :: Circle -> CompiledSpell
compiled = either (error . show) id . compile

-- | One draw-and-rebirth cycle for 'base': @min 0.6 (castStart / 2)@ with
-- @castStart = 1.8@.
formLife :: Double
formLife = 0.6

isFormation :: CompiledSpell -> Int -> Bool
isFormation spell e = emPhase (spellEmitters spell V.! e) /= Casting

formationEmitters :: CompiledSpell -> [EmitterSpec]
formationEmitters spell =
  [em | em <- V.toList (spellEmitters spell), emPhase em /= Casting]

castingEmitters :: CompiledSpell -> [EmitterSpec]
castingEmitters spell =
  [em | em <- V.toList (spellEmitters spell), emPhase em == Casting]

-- | The colour of every live formation row at @t@, read off the sampled
-- buffer. 'aliveSlots' is the row order 'sample' fills in, so zipping the
-- two is how a consumer would attribute a row to an emitter.
formationColors :: CompiledSpell -> Double -> [Word32]
formationColors spell t =
  [ pbColor buf U.! row
  | (row, (e, _)) <- zip [0 ..] (aliveSlots spell (Time t))
  , isFormation spell e
  ]
  where
    buf = sample spell ctx (Time t)

-- | @(emitter, index, position)@ of every live particle at @t@.
livePositions :: CompiledSpell -> Double -> [(Int, Int, V3)]
livePositions spell t =
  [ (e, i, particlePosition ctx (Time t) em i age)
  | (e, i) <- aliveSlots spell (Time t)
  , let em = spellEmitters spell V.! e
  , Just age <- [particleAge (emSpawn em) (emCount em) i (Time t)]
  ]

-- | How many formation particles are alive at @t@.
formationAlive :: CompiledSpell -> Double -> Int
formationAlive spell t =
  length [() | (e, _) <- aliveSlots spell (Time t), isFormation spell e]

-- | Instants spread over the whole cast, so no phase escapes the net.
instants :: [Double]
instants = [0.02, 0.12 .. 5.0]

-- | Instants either side of the first two rebirth boundaries, where the
-- pulsing used to be at its most visible.
boundaryInstants :: [Double]
boundaryInstants =
  [ formLife - 0.02
  , formLife + 0.02
  , 2 * formLife - 0.02
  , 2 * formLife + 0.02
  ]

spec :: Spec
spec = describe "hold, the frozen sigil (func-spec 0026 T4)" $ do
  describe "the ramp" $ do
    it "is flat with hold on: start and end are the same colour" $
      map (emAppearance) (formationEmitters (compiled (withHold True base)))
        `shouldSatisfy` all (\a -> let ColorRamp s e = appColor a in s == e)

    it "still fades with hold off, exactly as func-spec 0017 left it" $
      map emAppearance (formationEmitters (compiled base))
        `shouldSatisfy` all (\a -> let ColorRamp s e = appColor a in s /= e)

    it "and it is flattened to the start colour, not to a new one" $ do
      let startsOf spell =
            [s | a <- map emAppearance (formationEmitters spell), let ColorRamp s _ = appColor a]
      startsOf (compiled (withHold True base)) `shouldBe` startsOf (compiled base)

  describe "what hold does not touch" $ do
    it "the casting emitters, whole and entire" $
      castingEmitters (compiled (withHold True base)) `shouldBe` castingEmitters (compiled base)

    it "the formation envelopes: hold is a look, not a schedule" $
      map emSpawn (formationEmitters (compiled (withHold True base)))
        `shouldBe` map emSpawn (formationEmitters (compiled base))

    it "and every appearance field except the ramp" $ do
      let rest a = (appSize a, appBlend a, appAmplify a, appShape a)
      map (rest . emAppearance) (formationEmitters (compiled (withHold True base)))
        `shouldBe` map (rest . emAppearance) (formationEmitters (compiled base))

    it "so hold off compiles to exactly the circle without a sigil key" $
      compiled (withHold False base) `shouldBe` compiled base

  describe "the sigil is still drawn one point at a time" $
    it "the live formation count only grows through the first formLife" $ do
      let spell = compiled (withHold True base)
          counts = [formationAlive spell t | t <- [0.02, 0.06 .. formLife - 0.02]]
      counts `shouldSatisfy` (\cs -> and (zipWith (<=) cs (drop 1 cs)))
      -- Not vacuous: index order is drawing order, so it really does fill in.
      (minimum counts < maximum counts) `shouldBe` True

  describe "the colour half: the rebirth cycle becomes unobservable" $ do
    it "every live formation row carries one and the same colour, at every instant" $
      mapM_
        ( \t ->
            (t, nub (formationColors (compiled (withHold True base)) t))
              `shouldSatisfy` ((<= 1) . length . snd)
        )
        instants

    it "and that colour does not change across a rebirth boundary" $ do
      let spell = compiled (withHold True base)
          seen = concatMap (nub . formationColors spell) boundaryInstants
      nub seen `shouldSatisfy` ((== 1) . length)

    it "whereas without hold the same measurement finds a spread of colours" $ do
      -- The counterfactual, so the assertion above is about hold and not
      -- about the fixture happening to be uniform.
      let spell = compiled base
          spreads = [length (nub (formationColors spell t)) | t <- boundaryInstants]
      spreads `shouldSatisfy` any (> 1)

  describe "the position half: nothing in a formation position reads age" $
    it "positions are bit-for-bit identical with hold on and off, at every instant" $ do
      let onSpell = compiled (withHold True base)
          offSpell = compiled base
      mapM_
        (\t -> (t, livePositions onSpell t) `shouldBe` (t, livePositions offSpell t))
        instants
