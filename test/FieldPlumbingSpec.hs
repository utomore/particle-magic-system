-- | S6 (func-spec 0007 §8): the composition point — 'Magic.Interface'
-- wiring the field layer into @advanceSpell@ / @observeSpell@ without
-- either signature moving.
--
-- The headline assertion is the ADR-0010 D9 compatibility law: every
-- spell file that shipped before spec 0007 must render /bit-for-bit/ what
-- it rendered before. The frame digests below were captured from the
-- pre-0007 build (the same 80-step walk, run against the code as it stood
-- at commit "Implement func-spec 0006"), so this spec fails the moment a
-- fieldless spell's pixels move by one ULP.
--
-- Scope (func-spec 0019 S2, ADR-0016): "one ULP" is exactly the size of
-- the disagreement between two platforms' libm, so this baseline is
-- asserted on the platform it was captured on and reported pending
-- elsewhere. See "GoldenPlatform".
module FieldPlumbingSpec (spec) where

import Data.Bits (shiftR, xor)
import qualified Data.ByteString as BS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word64)
import GHC.Float (castFloatToWord32)
import GoldenPlatform (platformScopeNote, referencePlatform)
import Magic.Circle (Circle (..), PhaseConfig (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile (CompiledSpell (..), EmitterSpec (..), Phase (..), compile)
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
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
import Magic.Particle.Analytic (aliveSlots, sample)
import Magic.Particle.Buffer (bufferInvariant)
import Magic.Rune (ForceField (..))
import Magic.Types (norm)
import Test.Hspec

-- The pre-0007 baseline ------------------------------------------------------

-- | Digest of every frame of an 80-step, 0.1s walk — sensitive to a
-- single bit of every position, size, life fraction and color, and to the
-- particle count of every frame.
preFieldDigests :: [(FilePath, Word64)]
preFieldDigests =
  [ -- The two phased examples were re-captured at func-spec 0016 (the
    -- sigil's geometry changed) and again at 0017 (the sigil now holds
    -- until 'ppEnd' instead of collapsing at castStart) — see ADR-0015
    -- for the scope of that waiver. What this law still guards for them,
    -- unchanged and load-bearing, is the /field/ side of the claim: a
    -- fieldless spell runs through the same arithmetic it always did,
    -- and @test\/PersistWiringSpec.hs@ now checks the harder half —
    -- formation rows stay exactly undisplaced even while the field layer
    -- is bending the casting rows right next to them.
    ("assets/spells/bare-sigil.json", 16740094377505200858)
  , ("assets/spells/converge-flame.json", 16464387485720134342)
  , ("assets/spells/empty.json", 3634073563866035966)
  , ("assets/spells/grand-sigil.json", 18167520682498334567)
  , ("assets/spells/lissajous.json", 17185893384502476165)
  , ("assets/spells/pulse-ring.json", 9492385642234227627)
  , ("assets/spells/ring-fire.json", 10271734941662667557)
  , ("assets/spells/spiral-spark.json", 15289861400770235719)
  , ("assets/spells/square-burst.json", 3647392317481592648)
  ]

baselineCtx :: CastContext
baselineCtx =
  CastContext {casterPos = V3 0.25 (-0.5) 1.0, casterFacing = V3 0 1 0, seed = Seed 4242}

mix :: Word64 -> Word64 -> Word64
mix h w =
  let a = (h `xor` w) * 0x100000001B3
   in a `xor` (a `shiftR` 29)

digestBuffer :: Word64 -> ParticleBuffer -> Word64
digestBuffer h0 buf =
  let h1 = mix h0 (fromIntegral (pbCount buf))
      floats = [pbPosX buf, pbPosY buf, pbPosZ buf, pbSize buf, pbLife buf]
      hf = foldl (U.foldl' (\h x -> mix h (fromIntegral (castFloatToWord32 x)))) h1 floats
   in U.foldl' (\h c -> mix h (fromIntegral (c :: Word32))) hf (pbColor buf)

walkDigest :: Circle -> Word64
walkDigest circle =
  case castSpell CastRequest {circleOf = circle, ctxOf = baselineCtx} of
    Left err -> error (show err)
    Right spell -> go 0xcbf29ce484222325 spell (80 :: Int)
  where
    go h _ 0 = h
    go h s n =
      let s' = advanceSpell (FrameInput (DeltaTime 0.1)) s
          bufs = map rbParticles (batches (observeSpell s'))
       in go (foldl digestBuffer h bufs) s' (n - 1)

-- Fixtures --------------------------------------------------------------------

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 31337}

strongFields :: [ForceField]
strongFields = [Gravity (V3 0 (-9) 0), PointAttractor (V3 0 0 3) 8 0.5]

-- | Phases + fields: the ADR-0010 D6 fixture. The formation emitters draw
-- the circle while the casting emitter has not started, so a whole phase
-- window renders with the field layer switched off per emitter.
phasedCircle :: Circle
phasedCircle =
  emptyCircle
    { circlePhases = Just (PhaseConfig (Seconds 1.2) (Seconds 0.6))
    , circleFields = strongFields
    }

-- | Positions of the observed (field-displaced) buffer.
observedAt :: Circle -> Int -> Double -> [V3]
observedAt circle steps dt = positionsOf (bufferAfter circle steps dt)

bufferAfter :: Circle -> Int -> Double -> ParticleBuffer
bufferAfter circle steps dt =
  case castSpell CastRequest {circleOf = circle, ctxOf = ctx} of
    Left err -> error (show err)
    Right spell -> case batches (observeSpell (walk spell steps dt)) of
      (batch : _) -> rbParticles batch
      [] -> error "observeSpell produced no render batch"

walk :: ActiveSpell -> Int -> Double -> ActiveSpell
walk spell steps dt = foldl (\s _ -> advanceSpell (FrameInput (DeltaTime dt)) s) spell [1 .. steps]

-- | The time @walk@ reaches — accumulated the same way 'advanceSpell'
-- accumulates it, so the analytic comparison is bit-exact.
timeAfter :: Int -> Double -> Time
timeAfter steps dt = Time (foldl (\acc _ -> acc + dt) 0 [1 .. steps])

positionsOf :: ParticleBuffer -> [V3]
positionsOf buf =
  [V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j) | j <- [0 .. pbCount buf - 1]]

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

-- | The undisplaced analytic positions at the same instant.
analyticAt :: Circle -> Int -> Double -> [V3]
analyticAt circle steps dt =
  positionsOf (sample (compiledOf circle) ctx (timeAfter steps dt))

spec :: Spec
spec = describe "Magic.Interface force-field plumbing (spec 0007 S6)" $ do
  describe "the zero-field compatibility law (ADR-0010 D9)" $
    mapM_ compatibilityCase preFieldDigests

  describe "a fresh cast starts undisplaced (ADR-0010 D8)" $ do
    it "observing before any advance gives exactly the analytic sample" $
      observedAt fieldCircle 0 0.05 `shouldBe` analyticAt fieldCircle 0 0.05

    it "the first fixed step is still undisplaced: particles are born at rest (D3)" $
      observedAt fieldCircle 1 0.05 `shouldBe` analyticAt fieldCircle 1 0.05

  describe "the fields actually bend the particles" $ do
    it "positions diverge from the analytic layer once integration has run" $ do
      let observed = observedAt fieldCircle 40 0.05
          analytic = analyticAt fieldCircle 40 0.05
      length observed `shouldBe` length analytic
      observed `shouldNotBe` analytic
      maximum (zipWith (\a b -> norm (a - b)) observed analytic) `shouldSatisfy` (> 0.05)

    it "gravity drags the particle cloud downwards (net displacement is -y)" $ do
      let observed = observedAt gravityCircle 40 0.05
          analytic = analyticAt gravityCircle 40 0.05
          drops = zipWith (\(V3 _ oy _) (V3 _ ay _) -> oy - ay) observed analytic
      drops `shouldSatisfy` all (<= 0)
      minimum drops `shouldSatisfy` (< -0.05)

    it "the displaced buffer still satisfies the buffer invariant" $
      bufferAfter fieldCircle 40 0.05 `shouldSatisfy` bufferInvariant

    it "row count, sizes, lives and colors are untouched by the overlay" $ do
      let displaced = bufferAfter fieldCircle 40 0.05
          plain = sample (compiledOf fieldCircle) ctx (timeAfter 40 0.05)
      pbCount displaced `shouldBe` pbCount plain
      pbSize displaced `shouldBe` pbSize plain
      pbLife displaced `shouldBe` pbLife plain
      pbColor displaced `shouldBe` pbColor plain

  describe "only casting particles feel the fields (ADR-0010 D6)" $ do
    it "during the drawing window every formation row is exactly undisplaced" $
      mapM_ (assertFormationRigid 6) [1 .. 5 :: Int]

    it "the drawing window really does contain formation particles" $ do
      let spell = compiledOf phasedCircle
          slots = aliveSlots spell (timeAfter 12 0.1)
          phaseOf (e, _) = emPhase (spellEmitters spell V.! e)
      slots `shouldNotBe` []
      map phaseOf slots `shouldSatisfy` any (== Drawing)

    it "once casting starts, the casting rows do move" $ do
      let observed = observedAt phasedCircle 40 0.1
          analytic = analyticAt phasedCircle 40 0.1
      observed `shouldNotBe` analytic

-- | Every row alive at @steps@ whose emitter is not a casting emitter
-- must carry zero displacement, i.e. equal its analytic position exactly.
assertFormationRigid :: Int -> Int -> Expectation
assertFormationRigid perStep k = do
  let steps = perStep * k
      spell = compiledOf phasedCircle
      slots = aliveSlots spell (timeAfter steps 0.1)
      observed = observedAt phasedCircle steps 0.1
      analytic = analyticAt phasedCircle steps 0.1
      isFormation (e, _) = emPhase (spellEmitters spell V.! e) /= Casting
      rigid = [(o, a) | (slot, o, a) <- zip3 slots observed analytic, isFormation slot]
  length observed `shouldBe` length slots
  map fst rigid `shouldBe` map snd rigid

fieldCircle :: Circle
fieldCircle = emptyCircle {circleFields = strongFields}

gravityCircle :: Circle
gravityCircle = emptyCircle {circleFields = [Gravity (V3 0 (-9) 0)]}

compatibilityCase :: (FilePath, Word64) -> Spec
compatibilityCase (path, expected) =
  it (path ++ " renders bit-for-bit what it did before spec 0007") $ do
    bytes <- BS.readFile path
    circle <- either (fail . show) pure (loadCircle bytes)
    -- The fieldless precondition is the half of this law that holds
    -- everywhere, so it is asserted before the scope check.
    circleFields circle `shouldBe` []
    if referencePlatform
      then walkDigest circle `shouldBe` expected
      else
        -- Unlike the two golden nets, this baseline is a single digest
        -- over the whole 80-step walk: there is no per-frame structure
        -- recorded beside it to fall back on, and re-recording it on a
        -- second platform would only assert that this machine agrees
        -- with itself. ADR-0016 scopes it rather than weakening it.
        pendingWith platformScopeNote
