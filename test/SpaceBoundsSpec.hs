-- | S1 (func-spec 0025 §6): the fitted oriented box, and the promise that
-- the frozen box it sits next to did not move.
--
-- Two claims, and they pull in opposite directions on purpose:
--
--   * __containment__ — every position the sampler can produce lies
--     inside 'emitterBox'. Under-estimating is the failure that matters:
--     a host would miss a collision, and nothing would crash to say so.
--   * __tightness__ — the box's world AABB is no larger than
--     'Magic.Compile.emitterBounds'' cube, and for a spell that travels
--     along its normal it is dramatically smaller. Without this the round
--     delivered nothing.
--
-- And the third, which is what makes the other two safe to make:
-- 'Magic.Compile.emitterBounds' is bit-for-bit what it was, checked
-- against numbers captured from the pre-0025 build (func-spec 0025 §2.3).
module SpaceBoundsSpec (spec) where

import Control.Monad (forM_)
import qualified Data.Vector as V
import Magic.Circle (Circle (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( CompiledSpell (..)
  , EmitterSpec (..)
  , compile
  , emitterBounds
  )
import Magic.Particle.Analytic (aliveRanges, particleAge, particlePosition)
import Magic.Rune
  ( Envelope (..)
  , FaceShape (..)
  , InnerRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Space
  ( OrientedBox (..)
  , boxToAABB
  , emitterBox
  , spellBounds
  , spellBox
  )
import Magic.Types (CastContext (..), Seconds (..), Time (..), V3 (..), dot, norm)
import SpaceExamples (exampleSpells, loadExample, testCtx)
import System.Directory (doesFileExist)
import System.IO (IOMode (ReadMode), hClose, hGetContents, hSetEncoding, openFile, utf8)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

goldenFile :: FilePath
goldenFile = "test/golden/emitter-bounds-0025.txt"

-- | The horizons the golden was captured at.
goldenHorizons :: [Double]
goldenHorizons = [0, 0.5, 2.0, 9.0]

-- | Slack for the containment check: the bound is derived exactly, but it
-- and the sampler reach the same number by different orders of
-- operations, so the last few bits legitimately disagree. Scaled by the
-- extent, since a box 12 units across cannot be checked to 1e-7 absolute.
slack :: Float -> Float
slack half = 1e-4 * (1 + abs half)

inside :: OrientedBox -> V3 -> Bool
inside box p =
  onAxis (obAxisU box) (obHalfU box)
    && onAxis (obAxisV box) (obHalfV box)
    && onAxis (obAxisN box) (obHalfN box)
  where
    d = p - obCenter box
    onAxis axis half = abs (dot d axis) <= half + slack half

-- | Every alive particle of one emitter at one instant.
positionsAt :: CastContext -> EmitterSpec -> Time -> [V3]
positionsAt ctx em t =
  [ particlePosition ctx t em i age
  | (lo, hi) <- aliveRanges (emSpawn em) (emCount em) t
  , i <- [lo .. hi - 1]
  , Just age <- [particleAge (emSpawn em) (emCount em) i t]
  ]

aabbVolume :: (V3, V3) -> Float
aabbVolume (V3 ax ay az, V3 bx by bz) = (bx - ax) * (by - ay) * (bz - az)

finiteVolume :: Float -> Bool
finiteVolume v = not (isNaN v) && not (isInfinite v)

-- | A beam: it flies 8 units along its normal and spreads barely at all
-- sideways. The cube 'emitterBounds' draws around it is the motivating
-- example of func-spec 0025 §1.
beam :: CompiledSpell
beam =
  either (error . show) id $
    compile
      emptyCircle
        { innerRings = TwoOf (Just (TrajectoryRune (Forward 8))) Nothing
        }

spec :: Spec
spec = describe "fitted oriented boxes (func-spec 0025 S1)" $ do
  describe "the containment law: nothing samples outside the box" $ do
    prop "every alive particle of every example emitter, at any instant" $
      forAll (choose (0, 10)) $ \t -> ioProperty $ do
        spells <- exampleSpells
        pure $
          conjoin
            [ counterexample (name ++ " emitter " ++ show e ++ " at t = " ++ show t) $
                property (all (inside box) (positionsAt testCtx em (Time t)))
            | (name, spell) <- spells
            , (e, em) <- zip [0 :: Int ..] (V.toList (spellEmitters spell))
            , let box = emitterBox testCtx (Seconds t) em
            ]

    it "holds for the beam at every frame of its life" $ do
      let ems = V.toList (spellEmitters beam)
      forM_ [0, 1 .. 600 :: Int] $ \frame -> do
        let t = fromIntegral frame / 60
        forM_ ems $ \em ->
          filter (not . inside (emitterBox testCtx (Seconds t) em)) (positionsAt testCtx em (Time t))
            `shouldBe` []

  describe "the axes are a face coordinate system" $
    it "three unit vectors, mutually orthogonal, for every example emitter" $ do
      spells <- exampleSpells
      forM_ spells $ \(name, spell) ->
        forM_ (zip [0 :: Int ..] (V.toList (spellEmitters spell))) $ \(e, em) -> do
          let box = emitterBox testCtx (Seconds 2) em
              label = name ++ " emitter " ++ show e
              near a b = abs (a - b) < 1e-5
          (label, norm (obAxisU box)) `shouldSatisfy` (near 1 . snd)
          (label, norm (obAxisV box)) `shouldSatisfy` (near 1 . snd)
          (label, norm (obAxisN box)) `shouldSatisfy` (near 1 . snd)
          (label, dot (obAxisU box) (obAxisV box)) `shouldSatisfy` (near 0 . snd)
          (label, dot (obAxisU box) (obAxisN box)) `shouldSatisfy` (near 0 . snd)
          (label, dot (obAxisV box) (obAxisN box)) `shouldSatisfy` (near 0 . snd)

  -- The freeze witness (func-spec 0025 §2.3). The golden was generated on
  -- the pre-0025 build and committed, exactly as test/golden/perf-0010/*
  -- was: "frozen" here means the NUMBERS do not move, not merely that the
  -- meaning survives. A host may already be sizing an LOD decision on
  -- them.
  describe "emitterBounds is bit-for-bit what it was" $
    it "reproduces every value the pre-0025 build produced" $ do
      exists <- doesFileExist goldenFile
      exists `shouldBe` True
      recorded <- lines <$> readUtf8 goldenFile
      -- twin-lance.json is this round's own example, so it has no
      -- pre-0025 value to be frozen against; every file that existed
      -- before does.
      --
      -- wuxing-seal.json and yin-yang.json arrived on the parallel
      -- func-spec 0021 line and their rows were appended when the two
      -- rounds were integrated. That is still a pre-0025 witness: 0025's
      -- only behavioural edit to 'compile' is the anchors branch, and a
      -- circle without "anchors" takes the same single-emitter path it
      -- always did — the 172 rows recorded before the merge are
      -- bit-identical after it, which is what these two rows lean on.
      --
      -- comet-trail.json is func-spec 0023's own example and is excluded
      -- for the same reason twin-lance.json is: a spell that did not
      -- exist on the pre-0025 build has no pre-0025 value to be frozen
      -- against. 0023 does not touch 'emitterBounds' at all — velocity is
      -- a new column, not a new position — so every row below is
      -- unaffected by it.
      spells <-
        filter ((`notElem` ["twin-lance.json", "comet-trail.json"]) . fst) <$> exampleSpells
      let produced =
            [ unwords
                ( [name, show e, show h]
                    ++ concat [[show x, show y, show z] | V3 x y z <- [lo, hi]]
                )
            | (name, spell) <- spells
            , (e, em) <- zip [0 :: Int ..] (V.toList (spellEmitters spell))
            , h <- goldenHorizons
            , let (lo, hi) = emitterBounds testCtx (Seconds h) em
            ]
      length recorded `shouldSatisfy` (> 100)
      produced `shouldBe` recorded

  it "still returns a cube: the same radius on all three axes" $ do
    -- The shape law behind the freeze. Tightening emitterBounds in place
    -- would be mathematically legal and is exactly what §2.3 forbids;
    -- this is the assertion that would break if someone tried. The widths
    -- are compared with a relative tolerance rather than exactly: the
    -- radius is one number, but @anchor ± radius@ rounds differently on
    -- each axis when the anchor's components differ.
    spells <- exampleSpells
    forM_ spells $ \(name, spell) ->
      forM_ (zip [0 :: Int ..] (V.toList (spellEmitters spell))) $ \(e, em) -> do
        let (V3 ax ay az, V3 bx by bz) = emitterBounds testCtx (Seconds 2) em
            label = name ++ " emitter " ++ show e
            ds = [bx - ax, by - ay, bz - az]
            spread = maximum ds - minimum ds
        (label, spread <= 1e-5 * (1 + maximum ds)) `shouldBe` (label, True)

  describe "the tightness the round is for" $ do
    it "is never larger than the frozen cube, for any example emitter" $ do
      spells <- exampleSpells
      forM_ spells $ \(name, spell) ->
        forM_ (zip [0 :: Int ..] (V.toList (spellEmitters spell))) $ \(e, em) -> do
          let fitted = aabbVolume (boxToAABB (emitterBox testCtx (Seconds 2) em))
              frozen = aabbVolume (emitterBounds testCtx (Seconds 2) em)
              label = name ++ " emitter " ++ show e
          if finiteVolume fitted && finiteVolume frozen
            then (label, fitted) `shouldSatisfy` ((<= frozen * 1.000001) . snd)
            else pure ()

    it "shrinks a straight beam by more than an order of magnitude" $ do
      let em = V.head (spellEmitters beam)
          fitted = aabbVolume (boxToAABB (emitterBox testCtx (Seconds 2) em))
          frozen = aabbVolume (emitterBounds testCtx (Seconds 2) em)
      -- 8 units of travel is charged to the normal axis only; the two
      -- in-plane axes keep just the drift spread.
      fitted `shouldSatisfy` (< frozen / 10)

  describe "the spell-level union" $ do
    it "spellBox contains every emitterBox's corners" $ do
      spells <- exampleSpells
      forM_ spells $ \(name, spell) -> do
        let whole = spellBox testCtx (Seconds 2) spell
        forM_ (zip [0 :: Int ..] (V.toList (spellEmitters spell))) $ \(e, em) -> do
          let part = emitterBox testCtx (Seconds 2) em
              label = name ++ " emitter " ++ show e
          if finiteVolume (aabbVolume (boxToAABB part))
            then
              filter (not . inside whole) (corners part) `shouldSatisfy` (\bad -> (label, bad) == (label, []))
            else pure ()

    it "spellBounds contains every emitter's own AABB" $ do
      spells <- exampleSpells
      forM_ spells $ \(name, spell) -> do
        let (lo, hi) = spellBounds testCtx (Seconds 2) spell
        forM_ (zip [0 :: Int ..] (V.toList (spellEmitters spell))) $ \(e, em) -> do
          let (elo, ehi) = boxToAABB (emitterBox testCtx (Seconds 2) em)
              label = name ++ " emitter " ++ show e
          (label, leq lo elo) `shouldBe` (label, True)
          (label, leq ehi hi) `shouldBe` (label, True)

    it "an emitterless spell is a point at the caster" $ do
      let box = spellBox testCtx (Seconds 2) mempty
      obCenter box `shouldBe` casterPos testCtx
      (obHalfU box, obHalfV box, obHalfN box) `shouldBe` (0, 0, 0)
      spellBounds testCtx (Seconds 2) mempty
        `shouldBe` (casterPos testCtx, casterPos testCtx)

  it "a wider horizon never shrinks a box (why the lifetime box contains today's)" $ do
    spells <- exampleSpells
    forM_ spells $ \(name, spell) ->
      forM_ (zip [0 :: Int ..] (V.toList (spellEmitters spell))) $ \(e, em) -> do
        let small = emitterBox testCtx (Seconds 1) em
            big = emitterBox testCtx (Seconds 6) em
            label = name ++ " emitter " ++ show e
        (label, obHalfU small <= obHalfU big) `shouldBe` (label, True)
        (label, obHalfV small <= obHalfV big) `shouldBe` (label, True)
        (label, obHalfN small <= obHalfN big) `shouldBe` (label, True)

  it "a radial spell is bounded on all three axes, not only in plane" $ do
    -- RadialOutward travels along an in-plane direction that varies per
    -- particle, so the split cannot charge travel to the normal alone.
    let radial =
          either (error . show) id $
            compile
              emptyCircle
                { outerRings =
                    TwoOf
                      (Just (ShapeRune (Ring 0.5 1.0)))
                      (Just (RadiateRune RadialOutward))
                , innerRings =
                    TwoOf
                      (Just (TrajectoryRune (Forward 4)))
                      (Just (TimingRune (Envelope (Seconds 0) (Seconds 4) (Seconds 1))))
                }
        em = V.head (spellEmitters radial)
    forM_ [0, 1 .. 300 :: Int] $ \frame -> do
      let t = fromIntegral frame / 60
      filter (not . inside (emitterBox testCtx (Seconds t) em)) (positionsAt testCtx em (Time t))
        `shouldBe` []

  it "a converging spell is bounded too (the modulation cannot escape)" $ do
    -- converge-flame.json: the shipped @1 - life@ curve pulls particles
    -- towards the travel axis, which is the one term of the position
    -- formula the per-axis split has to widen for rather than narrow.
    circle <- loadExample "converge-flame.json"
    let converging = either (error . show) id (compile circle)
    forM_ (V.toList (spellEmitters converging)) $ \em ->
      forM_ [0, 1 .. 300 :: Int] $ \frame -> do
        let t = fromIntegral frame / 60
        filter (not . inside (emitterBox testCtx (Seconds t) em)) (positionsAt testCtx em (Time t))
          `shouldBe` []

corners :: OrientedBox -> [V3]
corners box =
  [ obCenter box + su + sv + sn
  | su <- [scaleBy (obHalfU box) (obAxisU box), scaleBy (negate (obHalfU box)) (obAxisU box)]
  , sv <- [scaleBy (obHalfV box) (obAxisV box), scaleBy (negate (obHalfV box)) (obAxisV box)]
  , sn <- [scaleBy (obHalfN box) (obAxisN box), scaleBy (negate (obHalfN box)) (obAxisN box)]
  ]
  where
    scaleBy s (V3 x y z) = V3 (s * x) (s * y) (s * z)

leq :: V3 -> V3 -> Bool
leq (V3 ax ay az) (V3 bx by bz) = ax <= bx + 1e-4 && ay <= by + 1e-4 && az <= bz + 1e-4

-- | Read as UTF-8 regardless of the machine's code page, as
-- "FFIContractSpec" does.
readUtf8 :: FilePath -> IO String
readUtf8 path = do
  h <- openFile path ReadMode
  hSetEncoding h utf8
  contents <- hGetContents h
  length contents `seq` pure ()
  hClose h
  pure contents

