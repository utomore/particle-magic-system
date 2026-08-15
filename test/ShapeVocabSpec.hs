-- | S2 (func-spec 0015 §7): the shape vocabulary itself — 'StyleRune' in
-- the outer ring reaches 'rbShape' end to end, the @"style"@ JSON tag
-- round-trips through the codec with its four billboard names, an unknown
-- name is a located load error, formation emitters never take the style,
-- and — the opt-in law — every shipped example still observes exactly as
-- it did before this spec existed.
module ShapeVocabSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.List (isInfixOf)
import qualified Data.Vector as V
import Magic.Circle (Circle (..), PhaseConfig (..), TwoOf (..), emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, saveCircle)
import Magic.Compile
  ( Appearance (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Phase (..)
  , compile
  )
import Magic.Interface
  ( ActiveSpell
  , BillboardShape (..)
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , castSpell
  , observeSpell
  )
import Magic.Rune (OuterRune (..))
import Magic.Types (Seconds (..))
import Test.Hspec

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

castOf :: Circle -> ActiveSpell
castOf c = either (error . show) id (castSpell (CastRequest c ctx))

observeAt :: Circle -> Double -> FrameOutput
observeAt c t = observeSpell (advanceSpell (FrameInput (DeltaTime t)) (castOf c))

styled :: BillboardShape -> Circle
styled shape = emptyCircle {outerRings = TwoOf Nothing (Just (StyleRune shape))}

names :: [(BillboardShape, String)]
names =
  [ (BillboardSquare, "square")
  , (BillboardSoftDot, "soft-dot")
  , (BillboardRing, "ring")
  , (BillboardSpark, "spark")
  ]

styleJson :: String -> BS.ByteString
styleJson name =
  BSC.pack $
    "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"style\",\"billboard\":\""
      ++ name
      ++ "\"}]}}"

examples :: [String]
examples =
  [ "bare-sigil"
  , "converge-flame"
  , "empty"
  , "grand-sigil"
  , "gravity-well"
  , "lissajous"
  , "pulse-ring"
  , "ring-fire"
  , "spiral-spark"
  , "square-burst"
  ]

spec :: Spec
spec = describe "billboard shape vocabulary (func-spec 0015 S2)" $ do
  it "a StyleRune reaches rbShape end to end, for every shape" $ do
    let shapeAt s = map rbShape (batches (observeAt (styled s) 1))
    mapM_ (\(s, _) -> shapeAt s `shouldBe` [s]) names

  it "layer B's StyleRune overrides layer A's (the ring override rule)" $ do
    let c =
          emptyCircle
            { outerRings =
                TwoOf (Just (StyleRune BillboardRing)) (Just (StyleRune BillboardSpark))
            }
    map rbShape (batches (observeAt c 1)) `shouldBe` [BillboardSpark]

  it "the style rune round-trips through saveCircle . loadCircle, all four names" $
    mapM_
      (\(s, _) -> loadCircle (saveCircle (styled s)) `shouldBe` Right (styled s))
      names

  it "parses the spec's literal JSON shape for each billboard name" $
    mapM_
      ( \(s, name) ->
          loadCircle (styleJson name)
            `shouldBe` Right (emptyCircle {outerRings = TwoOf (Just (StyleRune s)) Nothing})
      )
      names

  it "an unknown billboard name is a located load error listing the valid names" $
    case loadCircle (styleJson "blob") of
      Right c -> expectationFailure ("loaded: " ++ show c)
      Left (UnsupportedVersion v) -> expectationFailure ("version error: " ++ show v)
      Left (JsonError msg) -> do
        msg `shouldSatisfy` isInfixOf "unknown billboard \"blob\""
        msg `shouldSatisfy` isInfixOf "square, soft-dot, ring, spark"
        -- aeson's path pins the failing slot for the author.
        msg `shouldSatisfy` isInfixOf "$.circle.outer[0]"

  it "formation emitters ignore the style: a drawn circle stays square" $ do
    let c =
          (styled BillboardSoftDot)
            { circlePhases = Just (PhaseConfig (Seconds 0.8) (Seconds 0.4))
            }
        compiled = either (error . show) id (compile c)
        ems = V.toList (spellEmitters compiled)
    [appShape (emAppearance em) | em <- ems, emPhase em == Drawing]
      `shouldSatisfy` all (== BillboardSquare)
    [appShape (emAppearance em) | em <- ems, emPhase em == Casting]
      `shouldBe` [BillboardSoftDot]

  it "opt-in law: every shipped example still observes as one square batch" $
    mapM_
      ( \name -> do
          bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
          circle <- either (fail . show) pure (loadCircle bytes)
          let spell = castOf circle
              at t = observeSpell (advanceSpell (FrameInput (DeltaTime t)) spell)
          mapM_
            ( \t -> do
                let FrameOutput bs = at t
                length bs `shouldBe` 1
                map rbShape bs `shouldBe` [BillboardSquare]
            )
            [0, 0.5, 1.5, 3, 6]
      )
      examples
