-- | T3 (func-spec 0001 §8): ParticleBuffer SoA invariant.
module BufferSpec (spec) where

import qualified Data.Vector.Unboxed as U
import Magic.Particle.Buffer
  ( ParticleBuffer (..)
  , bufferInvariant
  , emptyBuffer
  , fromParticles
  )
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

genParticle :: Gen (V3, Float, Float, Word)
genParticle = do
  let f = realToFrac <$> choose (-1000 :: Double, 1000)
  pos <- V3 <$> f <*> f <*> f
  size <- f
  life <- f
  color <- arbitrarySizedNatural
  pure (pos, size, life, color)

spec :: Spec
spec = describe "Magic.Particle.Buffer" $ do
  it "emptyBuffer has count 0 and satisfies the invariant" $ do
    pbCount emptyBuffer `shouldBe` 0
    emptyBuffer `shouldSatisfy` bufferInvariant

  prop "any legally constructed buffer keeps all six vectors at length pbCount" $
    forAll (listOf genParticle) $ \ps ->
      let buffer = fromParticles [(p, s, l, fromIntegral c) | (p, s, l, c) <- ps]
       in bufferInvariant buffer && pbCount buffer == length ps

  prop "fromParticles preserves the particle data columnwise" $
    forAll (listOf genParticle) $ \ps ->
      let buffer = fromParticles [(p, s, l, fromIntegral c) | (p, s, l, c) <- ps]
       in U.toList (pbPosX buffer) == [x | (V3 x _ _, _, _, _) <- ps]
            && U.toList (pbSize buffer) == [s | (_, s, _, _) <- ps]
            && U.toList (pbLife buffer) == [l | (_, _, l, _) <- ps]
