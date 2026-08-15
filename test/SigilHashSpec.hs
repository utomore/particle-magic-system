{-# LANGUAGE ScopedTypeVariables #-}

-- | S1 (func-spec 0016 §7): 'hashCircle' — the structural digest every
-- other part of the round is derived from.
--
-- Four claims, in the order they matter:
--
--   1. it is a function of the circle alone (determinism), and survives a
--      @saveCircle@ / @loadCircle@ roundtrip unchanged — the digest picks
--      a spell's looks, so a spell must not change appearance by being
--      written to disk and read back;
--   2. it is sensitive to /every/ leaf of the ADT, right down to an
--      'Expr' literal buried inside a formula rune (one witness per leaf
--      kind);
--   3. distinct circles get distinct digests across a generated corpus
--      (no collisions);
--   4. @emptyCircle@'s digest is a pinned sentinel — the tripwire for
--      ADR-0014's "the digest is a contract".
module SigilHashSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (nub)
import Data.Word (Word64)
import Magic.Circle
  ( Circle (..)
  , Core (..)
  , Nodes (..)
  , PhaseConfig (..)
  , TwoOf (..)
  , emptyCircle
  )
import Magic.Codec (loadCircle, saveCircle)
import Magic.Expr (Expr (..), ExprV3 (..), Var (..))
import Magic.Rune
  ( BillboardShape (..)
  , BridgeRune (..)
  , Element (..)
  , Envelope (..)
  , EssenceRune (..)
  , FaceShape (..)
  , ForceField (..)
  , InnerRune (..)
  , NodeRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  , Trajectory (..)
  )
import Magic.Sigil (hashCircle)
import Magic.Types (Seconds (..), V2 (..), V3 (..))
import SigilGen (genAnyCircle)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (witnesses)

-- | @emptyCircle@'s digest. Frozen by ADR-0014: this number changing
-- means every spell in existence draws a different sigil.
emptyDigest :: Word64
emptyDigest = 11072995449257717738

-- | A circle with a formula rune, so the 'Expr'-shaped leaves are on the
-- table for the witness cases.
formulaCircle :: Circle
formulaCircle =
  emptyCircle
    { innerRings = TwoOf (Just (FormulaRune (ExprV3 (Lit 1) (Lit 2) (Lit 3)))) Nothing
    }

-- | Every "change exactly this leaf" witness: a label, and the two
-- circles that must not share a digest.
witnesses :: [(String, Circle, Circle)]
witnesses =
  [ ( "outer ring A occupancy"
    , emptyCircle
    , emptyCircle {outerRings = TwoOf (Just (RadiateRune AlongNormal)) Nothing}
    )
  , ( "outer ring A vs B (position, not just presence)"
    , emptyCircle {outerRings = TwoOf (Just (RadiateRune AlongNormal)) Nothing}
    , emptyCircle {outerRings = TwoOf Nothing (Just (RadiateRune AlongNormal))}
    )
  , ( "RadiationMode"
    , emptyCircle {outerRings = TwoOf (Just (RadiateRune AlongNormal)) Nothing}
    , emptyCircle {outerRings = TwoOf (Just (RadiateRune RadialOutward)) Nothing}
    )
  , ( "FaceShape constructor"
    , emptyCircle {outerRings = TwoOf (Just (ShapeRune (Diamond 1))) Nothing}
    , emptyCircle {outerRings = TwoOf (Just (ShapeRune (HollowSquare 1))) Nothing}
    )
  , ( "FaceShape Double payload"
    , emptyCircle {outerRings = TwoOf (Just (ShapeRune (Ring 1 2))) Nothing}
    , emptyCircle {outerRings = TwoOf (Just (ShapeRune (Ring 1 2.0000001))) Nothing}
    )
  , ( "FaceShape Float payload (Rect)"
    , emptyCircle {outerRings = TwoOf (Just (ShapeRune (Rect (V2 1 2)))) Nothing}
    , emptyCircle {outerRings = TwoOf (Just (ShapeRune (Rect (V2 1 2.0001)))) Nothing}
    )
  , ( "BillboardShape (StyleRune)"
    , emptyCircle {outerRings = TwoOf (Just (StyleRune BillboardSquare)) Nothing}
    , emptyCircle {outerRings = TwoOf (Just (StyleRune BillboardRing)) Nothing}
    )
  , ( "BridgeRune constructor"
    , emptyCircle {interLayer = Just (PhaseRune (Seconds 1))}
    , emptyCircle {interLayer = Just (ConvergeRune (Lit 1))}
    )
  , ( "BridgeRune Seconds payload"
    , emptyCircle {interLayer = Just (PhaseRune (Seconds 1))}
    , emptyCircle {interLayer = Just (PhaseRune (Seconds 1.0000000001))}
    )
  , ( "InnerRune constructor"
    , emptyCircle {innerRings = TwoOf (Just (TrajectoryRune (Forward 1))) Nothing}
    , emptyCircle {innerRings = TwoOf (Just (TimingRune (Envelope (Seconds 0) (Seconds 1) (Seconds 1)))) Nothing}
    )
  , ( "Trajectory payload"
    , emptyCircle {innerRings = TwoOf (Just (TrajectoryRune (Spiral 1 2 3))) Nothing}
    , emptyCircle {innerRings = TwoOf (Just (TrajectoryRune (Spiral 1 2 3.5))) Nothing}
    )
  , ( "Envelope field"
    , emptyCircle {innerRings = TwoOf (Just (TimingRune (Envelope (Seconds 0) (Seconds 1) (Seconds 1)))) Nothing}
    , emptyCircle {innerRings = TwoOf (Just (TimingRune (Envelope (Seconds 0) (Seconds 1) (Seconds 2)))) Nothing}
    )
  , ( "Expr Lit buried in a formula rune"
    , formulaCircle
    , emptyCircle {innerRings = TwoOf (Just (FormulaRune (ExprV3 (Lit 1) (Lit 2) (Lit 4)))) Nothing}
    )
  , ( "Expr shape (Lit vs Var)"
    , formulaCircle
    , emptyCircle {innerRings = TwoOf (Just (FormulaRune (ExprV3 (Lit 1) (Lit 2) (Var VarT)))) Nothing}
    )
  , ( "Expr Chan channel number"
    , emptyCircle {interLayer = Just (ConvergeRune (Chan 0))}
    , emptyCircle {interLayer = Just (ConvergeRune (Chan 1))}
    )
  , ( "essence element"
    , emptyCircle {core = Core (Just (EssenceRune Fire 1)) emptyNodes}
    , emptyCircle {core = Core (Just (EssenceRune Water 1)) emptyNodes}
    )
  , ( "essence power"
    , emptyCircle {core = Core (Just (EssenceRune Fire 1)) emptyNodes}
    , emptyCircle {core = Core (Just (EssenceRune Fire 1.5)) emptyNodes}
    )
  , ( "node occupancy (north)"
    , emptyCircle
    , emptyCircle {core = Core Nothing (Nodes (Just (DirBias 1)) Nothing Nothing Nothing)}
    )
  , ( "node position (north vs south)"
    , emptyCircle {core = Core Nothing (Nodes (Just (DirBias 1)) Nothing Nothing Nothing)}
    , emptyCircle {core = Core Nothing (Nodes Nothing (Just (DirBias 1)) Nothing Nothing)}
    )
  , ( "node bias payload"
    , emptyCircle {core = Core Nothing (Nodes (Just (DirBias 1)) Nothing Nothing Nothing)}
    , emptyCircle {core = Core Nothing (Nodes (Just (DirBias 1.25)) Nothing Nothing Nothing)}
    )
  , ( "phases presence"
    , emptyCircle
    , emptyCircle {circlePhases = Just (PhaseConfig (Seconds 1) (Seconds 0.5))}
    )
  , ( "phases payload"
    , emptyCircle {circlePhases = Just (PhaseConfig (Seconds 1) (Seconds 0.5))}
    , emptyCircle {circlePhases = Just (PhaseConfig (Seconds 1) (Seconds 0.6))}
    )
  ]

-- | The other side of the coin: force fields are deliberately outside the
-- digest, so spec 0007's law (fields change nothing else the interpreter
-- produces) survives this round intact. A gravity well must not silently
-- redraw a spell's sigil.
fieldVariants :: [Circle]
fieldVariants =
  [ emptyCircle
  , emptyCircle {circleFields = [Gravity (V3 0 (-9) 0)]}
  , emptyCircle {circleFields = [PointAttractor (V3 0 (-9) 0) 1 1]}
  , emptyCircle {circleFields = [Vortex (V3 0 0 0) (V3 0 1 0) 1 0.5]}
  , emptyCircle {circleFields = [Gravity (V3 0 (-9) 0), Gravity (V3 0 1 0)]}
  ]

emptyNodes :: Nodes (Maybe NodeRune)
emptyNodes = Nodes Nothing Nothing Nothing Nothing

shippedExamples :: [String]
shippedExamples =
  [ "bare-sigil"
  , "converge-flame"
  , "empty"
  , "grand-sigil"
  , "gravity-well"
  , "lattice-seal"
  , "lissajous"
  , "pulse-ring"
  , "ring-fire"
  , "soft-bloom"
  , "spiral-spark"
  , "square-burst"
  ]

spec :: Spec
spec = describe "hashCircle: the structural digest (func-spec 0016 S1)" $ do
  it "is deterministic for a fixed circle" $
    hashCircle emptyCircle `shouldBe` hashCircle emptyCircle

  prop "is deterministic for any circle" $
    forAll genAnyCircle $ \c -> hashCircle c === hashCircle c

  prop "survives a saveCircle / loadCircle roundtrip unchanged" $
    forAll genAnyCircle $ \c ->
      case loadCircle (saveCircle c) of
        Left err -> counterexample (show err) False
        Right c' -> hashCircle c' === hashCircle c

  describe "every ADT leaf is witnessed: changing it changes the digest" $
    mapM_
      ( \(label, a, b) ->
          it label (hashCircle a `shouldNotBe` hashCircle b)
      )
      witnesses

  it "covers every leaf kind the circle's meaning is made of" $
    length witnesses `shouldSatisfy` (>= 21)

  it "force fields are outside the digest (spec 0007's law survives)" $
    map hashCircle fieldVariants `shouldBe` replicate (length fieldVariants) (hashCircle emptyCircle)

  it "every shipped example keeps its digest across a save/load roundtrip" $
    mapM_
      ( \name -> do
          bytes <- BS.readFile ("assets/spells/" ++ name ++ ".json")
          circle <- either (fail . show) pure (loadCircle bytes)
          reloaded <- either (fail . show) pure (loadCircle (saveCircle circle))
          hashCircle reloaded `shouldBe` hashCircle circle
      )
      shippedExamples

  prop "distinct circles get distinct digests (no collisions in the corpus)" $
    forAll (vectorOf 24 genAnyCircle) $ \cs ->
      let distinct = nub cs
       in length (nub (map hashCircle distinct)) === length distinct

  it "emptyCircle's digest is the pinned sentinel (ADR-0014: the digest is a contract)" $
    hashCircle emptyCircle `shouldBe` emptyDigest
