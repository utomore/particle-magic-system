-- | S1 (func-spec 0023 §6): the nine-column buffer and its opt-in
-- invariant.
--
-- Two things are being guarded here, and only one of them is the new
-- code. The other is @test\/BufferSpec.hs@, which is /not/ touched by this
-- round and still passes: that is the witness that the six original
-- columns kept their names, types, order and meaning — the promise
-- ADR-0018 makes about widening a frozen layout.
--
-- What this file adds is the clause that makes "opt-in" mean something.
-- A velocity column is either absent or complete, and the three move
-- together; a buffer half-way between the two states is what every
-- consumer downstream would have to defend against, and the invariant is
-- how it is made unrepresentable instead.
module BufferVelocitySpec (spec) where

import Control.Monad (forM_)
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import Magic.Particle.Buffer
  ( ParticleBuffer (..)
  , bufferInvariant
  , buildBuffer
  , buildBufferWithVelocity
  , emptyBuffer
  , fromParticles
  , hasVelocity
  )
import Magic.Types (V3 (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | A row's worth of made-up particle data.
type Row = (V3, Float, Float, Word32, V3)

genRow :: Gen Row
genRow = do
  let f = realToFrac <$> choose (-1000 :: Double, 1000)
  pos <- V3 <$> f <*> f <*> f
  vel <- V3 <$> f <*> f <*> f
  size <- f
  life <- f
  color <- fromIntegral <$> (arbitrarySizedNatural :: Gen Int)
  pure (pos, size, life, color, vel)

-- | The nine-column build of a row list.
withVelocity :: [Row] -> ParticleBuffer
withVelocity rows = buildBufferWithVelocity (length rows) $ \write writeVel ->
  forM_ (zip [0 ..] rows) $ \(i, (p, s, l, c, v)) -> do
    write i p s l c
    writeVel i v

-- | The same rows through the six-column build.
withoutVelocity :: [Row] -> ParticleBuffer
withoutVelocity rows = buildBuffer (length rows) $ \write ->
  forM_ (zip [0 ..] rows) $ \(i, (p, s, l, c, _)) -> write i p s l c

spec :: Spec
spec = describe "ParticleBuffer velocity columns (func-spec 0023 S1)" $ do
  describe "the opt-in invariant" $ do
    prop "holds for every nine-column build, at any row count" $
      forAll (listOf genRow) $ \rows ->
        let pb = withVelocity rows
         in bufferInvariant pb
              .&&. pbCount pb === length rows
              .&&. map U.length [pbVelX pb, pbVelY pb, pbVelZ pb]
              === replicate 3 (length rows)

    prop "holds for every six-column build, with the velocities absent" $
      forAll (listOf genRow) $ \rows ->
        let pb = withoutVelocity rows
         in bufferInvariant pb
              .&&. map U.length [pbVelX pb, pbVelY pb, pbVelZ pb] === [0, 0, 0]

    -- The clause exists to /reject/ something, so something has to be
    -- rejected. These shapes cannot be built through the module's own
    -- constructors, which is the point: the invariant is what a consumer
    -- may assume, and here it is shown refusing the states it forbids.
    it "rejects a half-filled velocity column" $ do
      let base = withoutVelocity (replicate 3 sampleRow)
          three = U.replicate 3 (1 :: Float)
          two = U.replicate 2 (1 :: Float)
      base {pbVelX = three, pbVelY = three, pbVelZ = two}
        `shouldNotSatisfy` bufferInvariant
      base {pbVelX = three, pbVelY = U.empty, pbVelZ = U.empty}
        `shouldNotSatisfy` bufferInvariant
      -- Three velocity columns that agree with each other but not with
      -- the six: the mistake a host marshalling two frames into one call
      -- would actually make.
      base {pbVelX = two, pbVelY = two, pbVelZ = two}
        `shouldNotSatisfy` bufferInvariant

    it "accepts the two states it allows" $ do
      let base = withoutVelocity (replicate 3 sampleRow)
          three = U.replicate 3 (1 :: Float)
      base `shouldSatisfy` bufferInvariant
      base {pbVelX = three, pbVelY = three, pbVelZ = three}
        `shouldSatisfy` bufferInvariant

  describe "the six-column construction paths leave the velocities empty" $ do
    it "emptyBuffer" $ do
      emptyBuffer `shouldSatisfy` bufferInvariant
      emptyBuffer `shouldNotSatisfy` hasVelocity

    prop "buildBuffer" $
      forAll (listOf genRow) $ \rows ->
        not (hasVelocity (withoutVelocity rows))

    prop "fromParticles" $
      forAll (listOf genRow) $ \rows ->
        let pb = fromParticles [(p, s, l, c) | (p, s, l, c, _) <- rows]
         in not (hasVelocity pb) .&&. property (bufferInvariant pb)

  describe "hasVelocity" $ do
    prop "answers True for a nine-column build with rows, False otherwise" $
      forAll (listOf1 genRow) $ \rows ->
        hasVelocity (withVelocity rows)
          .&&. not (hasVelocity (withoutVelocity rows))

    it "answers False for an empty buffer either way" $ do
      -- Zero rows is the one case where the two builds coincide, and
      -- 'False' is the answer that puts a consumer on the six-column path
      -- it would take for an empty six-column buffer.
      withVelocity [] `shouldNotSatisfy` hasVelocity
      withoutVelocity [] `shouldNotSatisfy` hasVelocity

  describe "widening changed nothing about the six" $ do
    -- The nine-column build writes the same six columns the six-column
    -- build does, for the same rows. Stated here rather than assumed,
    -- because it is what lets the sampler pick a path per spell without
    -- the picture changing in anything but the velocity.
    prop "the six columns agree between the two builds" $
      forAll (listOf genRow) $ \rows ->
        let a = withVelocity rows
            b = withoutVelocity rows
         in (pbPosX a, pbPosY a, pbPosZ a, pbSize a, pbLife a, pbColor a, pbCount a)
              === (pbPosX b, pbPosY b, pbPosZ b, pbSize b, pbLife b, pbColor b, pbCount b)

    prop "the velocity columns are exactly what was written" $
      forAll (listOf genRow) $ \rows ->
        let pb = withVelocity rows
         in U.toList (pbVelX pb) === [x | (_, _, _, _, V3 x _ _) <- rows]
              .&&. U.toList (pbVelY pb) === [y | (_, _, _, _, V3 _ y _) <- rows]
              .&&. U.toList (pbVelZ pb) === [z | (_, _, _, _, V3 _ _ z) <- rows]

    it "leaves unwritten rows at zero velocity, not at whatever was there" $ do
      -- Determinism must not depend on a caller getting its own count
      -- right (the same rule 'buildBuffer' follows for the other six).
      let pb = buildBufferWithVelocity 4 $ \write writeVel -> do
            write 0 (V3 1 2 3) 1 0 0xFF0000FF
            writeVel 0 (V3 9 9 9)
      pb `shouldSatisfy` bufferInvariant
      U.toList (pbVelX pb) `shouldBe` [9, 0, 0, 0]
      U.toList (pbVelY pb) `shouldBe` [9, 0, 0, 0]
      U.toList (pbVelZ pb) `shouldBe` [9, 0, 0, 0]

sampleRow :: Row
sampleRow = (V3 1 2 3, 0.5, 0.25, 0xFF8000FF, V3 4 5 6)
