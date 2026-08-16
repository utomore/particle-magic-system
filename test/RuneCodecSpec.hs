{-# LANGUAGE OverloadedStrings #-}

-- | T-S2 (func-spec 0004 §8): the four Expr rune JSON tags — decode
-- judgments for each §4.6 document shape, the roundtrip property over
-- circles carrying Expr runes (reusing spec 0003's 'ExprGen'), bad
-- formulas rejected with JSON path + parse position, slot misplacement,
-- and byte-for-byte backward compatibility with the 0002 assets.
module RuneCodecSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (isInfixOf)
import ExprGen (genExpr)
import Magic.Circle (Circle (..), Core (..), Nodes (..), TwoOf (..), emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, saveCircle)
import Magic.Expr (BinOp (..), Expr (..), ExprV3 (..), Fun1 (..), Var (..))
import Magic.Rune
  ( BridgeRune (..)
  , Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Types (Seconds (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- Generators -----------------------------------------------------------------

-- | Codec-valid Expr payloads: parser-producible ASTs from spec 0003's
-- generator, kept small (the roundtrip property is about the wiring, the
-- language roundtrip itself is 0003 T3).
genPayload :: Gen Expr
genPayload = sized (\n -> genExpr (min 24 (max 1 n)))

genExprV3 :: Gen ExprV3
genExprV3 = ExprV3 <$> genPayload <*> genPayload <*> genPayload

genOuter :: Gen OuterRune
genOuter =
  oneof
    [ ShapeRune . Diamond <$> choose (0.1, 5)
    , RadiateRune <$> elements [AlongNormal, RadialOutward]
    , RangeRune <$> genPayload
    ]

genBridge :: Gen BridgeRune
genBridge =
  oneof
    [ PhaseRune . Seconds <$> choose (0, 5)
    , ConvergeRune <$> genPayload
    , AmplifyRune <$> genPayload
    ]

genInner :: Gen InnerRune
genInner =
  oneof
    [ TrajectoryRune . Forward <$> choose (-10, 10)
    , TimingRune . (\l -> Envelope (Seconds 0) (Seconds 4) (Seconds l)) <$> choose (0.5, 4)
    , FormulaRune <$> genExprV3
    ]

-- | Circles biased toward Expr runes in every slot that accepts one.
newtype ExprCircle = ExprCircle Circle
  deriving (Show)

instance Arbitrary ExprCircle where
  arbitrary = do
    outer <- TwoOf <$> genMaybe genOuter <*> genMaybe genOuter
    bridge <- genMaybe genBridge
    inner <- TwoOf <$> genMaybe genInner <*> genMaybe genInner
    center <- genMaybe (EssenceRune <$> elements [Neutral, Fire] <*> choose (0.1, 4))
    pure . ExprCircle $
      Circle
        { outerRings = outer
        , interLayer = bridge
        , innerRings = inner
        , core = Core center (Nodes Nothing Nothing Nothing Nothing)
        , circlePhases = Nothing
        , circleFields = []
        , circleAnchors = Nothing
        }
    where
      genMaybe g = oneof [pure Nothing, Just <$> g]

-- Helpers --------------------------------------------------------------------

shouldFailContaining :: BS.ByteString -> [String] -> Expectation
shouldFailContaining doc fragments = case loadCircle doc of
  Left (JsonError msg) ->
    mapM_ (\frag -> msg `shouldSatisfy` (frag `isInfixOf`)) fragments
  other -> expectationFailure ("expected JsonError, got: " ++ show other)

inInner :: BS.ByteString -> BS.ByteString
inInner runeDoc =
  "{\"version\":1,\"circle\":{\"inner\":[" <> runeDoc <> "]}}"

spec :: Spec
spec = describe "Expr rune JSON tags (spec 0004 S2)" $ do
  describe "the four §4.6 tags decode" $ do
    it "outer \"range\" → RangeRune" $
      loadCircle
        "{\"version\":1,\"circle\":{\"outer\":[{\"rune\":\"range\",\"expr\":\"1 + t*0.5\"}]}}"
        `shouldBe` Right
          emptyCircle
            { outerRings =
                TwoOf
                  (Just (RangeRune (Bin Add (Lit 1) (Bin Mul (Var VarT) (Lit 0.5)))))
                  Nothing
            }

    it "bridge \"converge\" → ConvergeRune" $
      loadCircle
        "{\"version\":1,\"circle\":{\"bridge\":{\"rune\":\"converge\",\"expr\":\"1 - life\"}}}"
        `shouldBe` Right
          emptyCircle {interLayer = Just (ConvergeRune (Bin Sub (Lit 1) (Var VarLife)))}

    it "bridge \"amplify\" → AmplifyRune" $
      loadCircle
        "{\"version\":1,\"circle\":{\"bridge\":{\"rune\":\"amplify\",\"expr\":\"2\"}}}"
        `shouldBe` Right emptyCircle {interLayer = Just (AmplifyRune (Lit 2))}

    it "inner \"formula\" → FormulaRune with three components" $
      loadCircle
        (inInner "{\"rune\":\"formula\",\"x\":\"sin(t*3)*0.6\",\"y\":\"pindex\",\"z\":\"chan(2)\"}")
        `shouldBe` Right
          emptyCircle
            { innerRings =
                TwoOf
                  ( Just
                      ( FormulaRune
                          ( ExprV3
                              (Bin Mul (Fun1 FSin (Bin Mul (Var VarT) (Lit 3))) (Lit 0.6))
                              (Var VarPIndex)
                              (Chan 2)
                          )
                      )
                  )
                  Nothing
            }

  prop "roundtrips circles with Expr runes: loadCircle . saveCircle == Right" $
    \(ExprCircle c) -> loadCircle (saveCircle c) === Right c

  describe "bad formulas are load errors with JSON path + parse position" $ do
    it "syntax error" $
      shouldFailContaining
        (inInner "{\"rune\":\"formula\",\"x\":\"sin(t\",\"y\":\"0\",\"z\":\"0\"}")
        ["$.circle.inner[0].x", ":1:"]

    it "unknown identifier" $
      shouldFailContaining
        "{\"version\":1,\"circle\":{\"bridge\":{\"rune\":\"converge\",\"expr\":\"1 - lfie\"}}}"
        ["$.circle.bridge.expr", ":1:5", "lfie", "legal names"]

    it "chan with a non-literal argument" $
      shouldFailContaining
        "{\"version\":1,\"circle\":{\"outer\":[null,{\"rune\":\"range\",\"expr\":\"chan(t)\"}]}}"
        ["$.circle.outer[1].expr", ":1:", "integer literal"]

    it "over the 512-node budget" $ do
      -- 300 literals joined by 299 additions = 599 nodes > 512.
      let big = BS.intercalate "+" (replicate 300 "1")
      shouldFailContaining
        (inInner ("{\"rune\":\"formula\",\"x\":\"" <> big <> "\",\"y\":\"0\",\"z\":\"0\"}"))
        ["$.circle.inner[0].x", "formula too large", "512"]

  it "misplaced tag: \"range\" in the inner ring lists that slot's valid tags" $
    shouldFailContaining
      (inInner "{\"rune\":\"range\",\"expr\":\"1\"}")
      ["$.circle.inner[0]", "range", "trajectory, timing, formula"]

  it "misplaced tag: \"formula\" in the bridge slot" $
    shouldFailContaining
      "{\"version\":1,\"circle\":{\"bridge\":{\"rune\":\"formula\",\"x\":\"0\",\"y\":\"0\",\"z\":\"0\"}}}"
      ["$.circle.bridge", "formula", "phase, converge, amplify"]

  describe "0002 documents load byte-for-byte unchanged" $ do
    let assets =
          [ ("assets/spells/empty.json", \c -> c == emptyCircle)
          , ("assets/spells/ring-fire.json", pure True)
          , ("assets/spells/square-burst.json", pure True)
          , ("assets/spells/spiral-spark.json", pure True)
          ]
    mapM_
      ( \(path, check) ->
          it (path ++ " still loads") $ do
            bytes <- BS.readFile path
            case loadCircle bytes of
              Right c -> c `shouldSatisfy` check
              Left err -> expectationFailure (show err)
      )
      assets

    it "circles without Expr runes decode with no Expr payloads anywhere" $ do
      bytes <- BS.readFile "assets/spells/ring-fire.json"
      case loadCircle bytes of
        Right c -> do
          let TwoOf oa ob = outerRings c
              TwoOf ia ib = innerRings c
              outerIsExpr r = case r of RangeRune _ -> True; _ -> False
              innerIsExpr r = case r of FormulaRune _ -> True; _ -> False
              bridgeIsExpr r = case r of PhaseRune _ -> False; _ -> True
          any outerIsExpr ([oa, ob] >>= maybe [] pure) `shouldBe` False
          any innerIsExpr ([ia, ib] >>= maybe [] pure) `shouldBe` False
          maybe False bridgeIsExpr (interLayer c) `shouldBe` False
        Left err -> expectationFailure (show err)
