-- | S6 (func-spec 0006 §8): regression guard for the compatibility law
-- (§1) — independent of any new machinery's correctness, it just states
-- the structural facts about the 7 real pre-0006 asset files: they load,
-- carry @circlePhases = Nothing@, compile to exactly one emitter with a
-- degenerate 'PhasePlan', and their sampling windows are unchanged.
module BackCompatSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Vector as V
import Magic.Circle (Circle (..))
import Magic.Codec (loadCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , Envelope (..)
  , PhasePlan (..)
  , compile
  )
import Magic.Particle.Analytic (sample)
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Types (CastContext (..), Seconds (..), Seed (..), Time (..), V3 (..))
import Test.Hspec

-- | The 7 spell files that predate spec 0006 — none carries a "phases"
-- key.
legacyAssets :: [FilePath]
legacyAssets =
  [ "assets/spells/empty.json"
  , "assets/spells/converge-flame.json"
  , "assets/spells/lissajous.json"
  , "assets/spells/pulse-ring.json"
  , "assets/spells/ring-fire.json"
  , "assets/spells/spiral-spark.json"
  , "assets/spells/square-burst.json"
  ]

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 1}

spec :: Spec
spec = describe "compatibility law regression: the 7 pre-0006 assets (spec 0006 S6)" $
  mapM_ checkAsset legacyAssets

checkAsset :: FilePath -> Spec
checkAsset path = describe path $ do
  it "loads successfully with circlePhases = Nothing" $ do
    bytes <- BS.readFile path
    case loadCircle bytes of
      Right circle -> circlePhases circle `shouldBe` Nothing
      Left err -> expectationFailure (show err)

  it "compiles to exactly one emitter with a degenerate PhasePlan, spellLifetime = 0004 formula" $ do
    bytes <- BS.readFile path
    circle <- either (fail . show) pure (loadCircle bytes)
    case compile circle of
      Right spell -> do
        V.length (spellEmitters spell) `shouldBe` 1
        let plan = spellPhases spell
            em = V.head (spellEmitters spell)
            Seconds delay = envDelay (emSpawn em)
            Seconds duration = envDuration (emSpawn em)
            Seconds lifetime = envLifetime (emSpawn em)
        ppDrawEnd plan `shouldBe` Seconds 0
        ppConvergeEnd plan `shouldBe` Seconds 0
        ppEnd plan `shouldBe` spellLifetime spell
        spellLifetime spell `shouldBe` Seconds (delay + duration + lifetime)
      Left err -> expectationFailure (show err)

  it "the non-empty sampling window is unchanged: empty before start and after lifetime, non-empty mid-window" $ do
    bytes <- BS.readFile path
    circle <- either (fail . show) pure (loadCircle bytes)
    spell <- either (fail . show) pure (compile circle)
    let em = V.head (spellEmitters spell)
        Seconds delay = envDelay (emSpawn em)
        Seconds duration = envDuration (emSpawn em)
        Seconds lifetime = spellLifetime spell
        midWindow = delay + duration / 2
    pbCount (sample spell ctx (Time (-0.5))) `shouldBe` 0
    pbCount (sample spell ctx (Time (lifetime + 0.5))) `shouldBe` 0
    pbCount (sample spell ctx (Time midWindow)) `shouldSatisfy` (> 0)
