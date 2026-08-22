-- | T6 (magic-semantics F002): C3.2's opt-in widening.
--
-- 'Magic.Compile.emitterBounds' and 'Magic.Space.emitterBox' /
-- 'Magic.Space.spellBounds' / 'Magic.Space.spellBox' have their function
-- bodies untouched by this round (the feature doc's §5) — what changes is
-- only that 'Magic.Compile.compile' hands them more emitters, spread
-- along the normal, when @circleVolume@ is on. Three claims, over
-- @assets/spells/stacked-sigil.json@:
--
--   * every formation 'Magic.Compile.EmitterSpec' still gets a /cube/ out
--     of 'Magic.Compile.emitterBounds' — same radius on all three axes,
--     the shape law 'test/SpaceBoundsSpec.hs' already states for every
--     shipped example (stacked-sigil included, since it walks the whole
--     asset directory);
--   * the spell-level envelope ('Magic.Space.spellBounds' /
--     'Magic.Space.spellBox') is never smaller with the stack on than
--     with it off, on the very same circle — union over more,
--     farther-apart boxes cannot shrink;
--   * every sampled position still lies inside its own emitter's box —
--     the containment law, restated for the stacked case specifically
--     rather than only inherited from the generic property test.
module SigilVolumeBoundsSpec (spec) where

import qualified Data.Vector as V
import Magic.Circle (Circle (..))
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , compile
  , emitterBounds
  )
import Magic.Particle.Analytic (aliveRanges, particleAge, particlePosition)
import Magic.Space
  ( OrientedBox (..)
  , boxToAABB
  , emitterBox
  , spellBounds
  , spellBox
  )
import Magic.Types (Seconds (..), Time (..), V3 (..), dot)
import SpaceExamples (loadExample, testCtx)
import Test.Hspec

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

aabbVolume :: (V3, V3) -> Float
aabbVolume (V3 ax ay az, V3 bx by bz) = (bx - ax) * (by - ay) * (bz - az)

inside :: OrientedBox -> V3 -> Bool
inside box p =
  onAxis (obAxisU box) (obHalfU box)
    && onAxis (obAxisV box) (obHalfV box)
    && onAxis (obAxisN box) (obHalfN box)
  where
    d = p - obCenter box
    onAxis axis half = abs (dot d axis) <= half + slack half
    slack half = 1e-4 * (1 + abs half)

positionsAt :: EmitterSpec -> Time -> [V3]
positionsAt em t =
  [ particlePosition testCtx t em i age
  | (lo, hi) <- aliveRanges (emSpawn em) (emCount em) t
  , i <- [lo .. hi - 1]
  , Just age <- [particleAge (emSpawn em) (emCount em) i t]
  ]

horizon :: Seconds
horizon = Seconds 2

spec :: Spec
spec = describe "C3.2's opt-in widening (magic-semantics F002 T6)" $ do
  circle <- runIO (loadExample "stacked-sigil.json")
  let stacked = compiledOf circle
      flat = compiledOf circle {circleVolume = Nothing}

  it "still stacks: the loaded example really has more than one formation emitter per stroke" $
    V.length (spellEmitters stacked) `shouldSatisfy` (> V.length (spellEmitters flat))

  describe "every emitter still gets a cube out of emitterBounds" $
    it "same radius on all three axes, for every formation emitter" $
      mapM_
        ( \em -> do
            let (V3 ax ay az, V3 bx by bz) = emitterBounds testCtx horizon em
                ds = [bx - ax, by - ay, bz - az]
                spread = maximum ds - minimum ds
            spread `shouldSatisfy` (<= 1e-5 * (1 + maximum ds))
        )
        (V.toList (spellEmitters stacked))

  describe "the spell-level envelope only grows when the stack turns on" $ do
    it "spellBounds: the stacked AABB is never smaller than the flat one" $ do
      let (loS, hiS) = spellBounds testCtx horizon stacked
          (loF, hiF) = spellBounds testCtx horizon flat
      aabbVolume (loS, hiS) `shouldSatisfy` (>= aabbVolume (loF, hiF) * (1 - 1e-6))

    it "spellBox: same story for the fitted oriented box" $ do
      let boxS = spellBox testCtx horizon stacked
          boxF = spellBox testCtx horizon flat
      aabbVolume (boxToAABB boxS) `shouldSatisfy` (>= aabbVolume (boxToAABB boxF) * (1 - 1e-6))

  describe "containment still holds on the stacked spell" $
    it "every alive particle of every formation emitter lies in its own emitterBox" $
      mapM_
        ( \frame -> do
            let t = fromIntegral (frame :: Int) / 60
            mapM_
              ( \em ->
                  filter (not . inside (emitterBox testCtx (Seconds t) em)) (positionsAt em (Time t))
                    `shouldBe` []
              )
              (V.toList (spellEmitters stacked))
        )
        [0, 15 .. 180]
