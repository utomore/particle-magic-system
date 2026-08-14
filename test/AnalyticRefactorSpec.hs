-- | S1 (func-spec 0007 §8): the consistency law of the additive Analytic
-- refactor. @sample@ is the definition of both the row order and the
-- per-particle position; 'aliveSlots' and 'particlePosition' are the
-- exported halves the force-field layer builds on (spec 0007 §4.4), so
-- the only thing that can go wrong is the two drifting apart.
--
-- The property states they cannot: for every shipped asset and every
-- sample time, 'aliveSlots' enumerates exactly the buffer's rows in
-- order, and re-deriving each row's position through 'particlePosition'
-- reproduces the buffer's coordinates bit-for-bit.
--
-- The other half of the proof obligation ("@sample@ is unchanged") is
-- carried by the pre-existing SampleSpec / SampleExprSpec / PhaseSampleSpec
-- / Acceptance suites, which are asserted verbatim, plus the pre-0007
-- frame digests in "FieldPlumbingSpec".
module AnalyticRefactorSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Magic.Circle (Circle (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , compile
  )
import Magic.Particle.Analytic (aliveSlots, particleAge, particlePosition, sample)
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Rune (OuterRune (..), RadiationMode (..))
import Magic.Types
  ( CastContext (..)
  , Seconds (..)
  , Seed (..)
  , Time (..)
  , V3 (..)
  )
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (choose, forAll)

allAssets :: [FilePath]
allAssets =
  [ "assets/spells/bare-sigil.json"
  , "assets/spells/converge-flame.json"
  , "assets/spells/empty.json"
  , "assets/spells/grand-sigil.json"
  , "assets/spells/lissajous.json"
  , "assets/spells/pulse-ring.json"
  , "assets/spells/ring-fire.json"
  , "assets/spells/spiral-spark.json"
  , "assets/spells/square-burst.json"
  ]

loadCompiled :: FilePath -> IO CompiledSpell
loadCompiled path = do
  bytes <- BS.readFile path
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (compile circle)

-- | A radial-outward, phased circle: exercises the RadialOutward axis
-- branch and multi-emitter (formation) row ordering, neither of which the
-- asset set covers together.
radialPhased :: Circle
radialPhased =
  emptyCircle
    { outerRings = TwoOf Nothing (Just (RadiateRune RadialOutward))
    , circlePhases = Just (PhaseConfig (Seconds 1.0) (Seconds 0.5))
    }

ctxA :: CastContext
ctxA = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 7}

ctxB :: CastContext
ctxB = CastContext {casterPos = V3 (-1.5) 2 0.25, casterFacing = V3 0.3 0.1 (-1), seed = Seed 20260807}

-- | Rebuild the buffer's positions from the exported halves alone.
rebuilt :: CompiledSpell -> CastContext -> Time -> [V3]
rebuilt spell ctx t =
  [ particlePosition ctx t em i age
  | (e, i) <- aliveSlots spell t
  , let em = spellEmitters spell V.! e
  , Just age <- [particleAge (emSpawn em) (emCount em) i t]
  ]

sampled :: CompiledSpell -> CastContext -> Time -> [V3]
sampled spell ctx t =
  let buf = sample spell ctx t
   in [V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) | j <- [0 .. pbCount buf - 1]]

spec :: Spec
spec = describe "Analytic additive refactor: the consistency law (spec 0007 S1)" $ do
  spells <- runIO $ do
    fromAssets <- mapM loadCompiled allAssets
    radial <- either (fail . show) pure (compile radialPhased)
    pure (zip allAssets fromAssets ++ [("<radial-outward + phases>", radial)])

  mapM_ (checkSpell ctxA) spells
  mapM_ (checkSpell ctxB) spells

checkSpell :: CastContext -> (FilePath, CompiledSpell) -> Spec
checkSpell ctx (label, spell) = describe (label ++ " (seed " ++ show sd ++ ")") $ do
  let Seconds lifetime = spellLifetime spell
      times = choose (-0.5, lifetime + 0.5)

  prop "aliveSlots enumerates exactly the buffer's rows, in order" $
    forAll times $ \t ->
      length (aliveSlots spell (Time t)) == pbCount (sample spell ctx (Time t))

  prop "particlePosition over aliveSlots reproduces the buffer bit-for-bit" $
    forAll times $ \t ->
      rebuilt spell ctx (Time t) == sampled spell ctx (Time t)

  prop "the law also holds at exact frame times of a fixed 60 Hz walk" $
    forAll (choose (0, 600 :: Int)) $ \n ->
      let t = Time (fromIntegral n / 60)
       in rebuilt spell ctx t == sampled spell ctx t

  it "aliveSlots is empty before the cast, matching sample's empty buffer" $ do
    aliveSlots spell (Time (-0.001)) `shouldBe` []
    pbCount (sample spell ctx (Time (-0.001))) `shouldBe` 0

  it "every alive slot is a valid (emitter, index) pair" $ do
    let slots = aliveSlots spell (Time (lifetime / 2))
        valid (e, i) =
          e >= 0
            && e < V.length (spellEmitters spell)
            && i >= 0
            && i < emCount (spellEmitters spell V.! e)
    slots `shouldSatisfy` all valid
  where
    sd = case seed ctx of Seed s -> s
