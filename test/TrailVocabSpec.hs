-- | S3 (func-spec 0023 §6): @BillboardTrail@, its wire code and its
-- @"trail"@ style name.
--
-- The shape vocabulary's extension rule (ADR-0013, func-spec 0015 S3) is
-- that a new shape /appends/: it takes the next wire code and it moves
-- nobody. Both halves are asserted, because only the first one would fail
-- loudly on its own — a shape slipped into the middle of the declaration
-- order compiles fine and silently renders every deployed host's batches
-- as the wrong thing.
--
-- The end-to-end direction matters as much as the codec: a player writes
-- @"trail"@ in JSON and what must come out the far end is a batch whose
-- shape is @BillboardTrail@ /and/ a spell that has switched velocity on.
-- That second consequence is the one no type checks.
module TrailVocabSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Vector as V
import Magic.Codec (loadCircle, saveCircle)
import Magic.Compile
  ( Appearance (appShape)
  , BillboardShape (..)
  , CompiledSpell (..)
  , EmitterSpec (emAppearance, emPhase)
  , Phase (Casting)
  , compile
  , spellNeedsVelocity
  )
import Magic.Interface
  ( CastRequest (..)
  , CastContext (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , castSpell
  , observeSpell
  )
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 4242}

-- | A minimal circle carrying one outer-ring style rune. Pure ASCII, so
-- 'BS8.pack' is an exact encoding here.
circleJson :: String -> BS.ByteString
circleJson billboard =
  BS8.pack $
    "{\"version\":1,\"name\":\"t\",\"circle\":{"
      ++ "\"outer\":[{\"rune\":\"shape\",\"shape\":{\"kind\":\"ring\",\"rInner\":0.5,\"rOuter\":1.0}},"
      ++ "{\"rune\":\"style\",\"billboard\":\""
      ++ billboard
      ++ "\"}],"
      ++ "\"inner\":[{\"rune\":\"trajectory\",\"kind\":\"forward\",\"speed\":3.0},"
      ++ "{\"rune\":\"timing\",\"delay\":0.0,\"duration\":3.0,\"lifetime\":1.5}],"
      ++ "\"core\":{\"center\":{\"element\":\"fire\",\"power\":1.0}}}}"

spec :: Spec
spec = describe "BillboardTrail vocabulary (func-spec 0023 §6 S3)" $ do
  describe "wire codes" $ do
    it "gives the trail wire code 4" $
      fromEnum BillboardTrail `shouldBe` 4

    it "leaves the four existing codes exactly where they were" $ do
      -- The append rule's real content. A shape inserted in the middle
      -- would break here rather than in a host's renderer.
      fromEnum BillboardSquare `shouldBe` 0
      fromEnum BillboardSoftDot `shouldBe` 1
      fromEnum BillboardRing `shouldBe` 2
      fromEnum BillboardSpark `shouldBe` 3

    it "makes the trail the last shape, so the next one appends too" $ do
      (maxBound :: BillboardShape) `shouldBe` BillboardTrail
      ([minBound .. maxBound] :: [BillboardShape])
        `shouldBe` [ BillboardSquare
                   , BillboardSoftDot
                   , BillboardRing
                   , BillboardSpark
                   , BillboardTrail
                   ]

  describe "the \"trail\" style name" $ do
    it "round-trips through the codec" $ do
      circle <- either (fail . show) pure (loadCircle (circleJson "trail"))
      reloaded <- either (fail . show) pure (loadCircle (saveCircle circle))
      reloaded `shouldBe` circle

    it "survives a save/load cycle as the same compiled shape" $ do
      circle <- either (fail . show) pure (loadCircle (circleJson "trail"))
      spell <- either (fail . show) pure (compile circle)
      reloaded <- either (fail . show) pure (loadCircle (saveCircle circle))
      spell' <- either (fail . show) pure (compile reloaded)
      map castingShape (emittersOf spell') `shouldBe` map castingShape (emittersOf spell)

    it "names itself among the valid billboards when a name is wrong" $ do
      case loadCircle (circleJson "streak") of
        Right _ -> expectationFailure "an unknown billboard name should not load"
        Left err -> show err `shouldContain` "trail"

  describe "end to end: the rune reaches the batch and switches velocity on" $ do
    it "compiles the casting emitter to BillboardTrail" $ do
      circle <- either (fail . show) pure (loadCircle (circleJson "trail"))
      spell <- either (fail . show) pure (compile circle)
      castingShapes spell `shouldSatisfy` all (== BillboardTrail)
      castingShapes spell `shouldSatisfy` (not . null)

    it "switches the spell's velocity computation on" $ do
      circle <- either (fail . show) pure (loadCircle (circleJson "trail"))
      spell <- either (fail . show) pure (compile circle)
      spellNeedsVelocity spell `shouldBe` True

    it "leaves it off for every other style name" $
      mapM_
        ( \name -> do
            circle <- either (fail . show) pure (loadCircle (circleJson name))
            spell <- either (fail . show) pure (compile circle)
            spellNeedsVelocity spell `shouldBe` False
        )
        ["square", "soft-dot", "ring", "spark"]

    it "reaches the host as a batch tagged BillboardTrail" $ do
      circle <- either (fail . show) pure (loadCircle (circleJson "trail"))
      spell <- either (fail . show) pure (castSpell (CastRequest circle ctx))
      let shapes = map rbShape (batches (observeSpell spell))
      shapes `shouldSatisfy` elem BillboardTrail

    it "still leaves the formation emitters as hard squares" $ do
      -- Func-spec 0015's rule, unchanged: a drawn circle stays crisp, and
      -- the style rune is about the main effect only. Also why a trail
      -- spell's formation particles have nothing to trail along.
      circle <- either (fail . show) pure (loadCircle (circleJson "trail"))
      spell <- either (fail . show) pure (compile circle)
      let formation =
            [ appShape (emAppearance em)
            | em <- V.toList (spellEmitters spell)
            , emPhase em /= Casting
            ]
      formation `shouldSatisfy` all (== BillboardSquare)

emittersOf :: CompiledSpell -> [EmitterSpec]
emittersOf = V.toList . spellEmitters

castingShape :: EmitterSpec -> BillboardShape
castingShape = appShape . emAppearance

castingShapes :: CompiledSpell -> [BillboardShape]
castingShapes spell =
  [ appShape (emAppearance em)
  | em <- V.toList (spellEmitters spell)
  , emPhase em == Casting
  ]
