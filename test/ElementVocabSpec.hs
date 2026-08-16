-- | S1 (func-spec 0021 §7): the element vocabulary, four to nine.
--
-- Two things are being asserted here, and only one of them is about the
-- new elements.
--
-- The first is the __append-only law__ (§2.4). 'Element' derives 'Enum',
-- and 'Magic.Sigil.hashCircle' feeds that ordinal into the digest that
-- decides what a spell's sigil looks like — so inserting a constructor
-- between the existing four would silently redraw every spell already
-- written, the ADR-0014 hazard. The law cannot be stated as a type, so it
-- is stated here: the first four ordinals are pinned by name.
--
-- The second is that the five new rows are actually distinct material —
-- distinct ramps, and a blend column split across both modes, since a
-- table where every new element blended the same way would leave
-- func-spec 0015 §8-5's ledger exactly where it was.
module ElementVocabSpec (spec) where

import Data.Bits (shiftR, (.&.))
import Data.List (nub)
import Data.Word (Word32)
import Magic.Compile
  ( Appearance (..)
  , BillboardShape (..)
  , BlendMode (..)
  , ColorRamp (..)
  , elementAppearance
  )
import Magic.Rune (Element (..))
import Test.Hspec

allElements :: [Element]
allElements = [minBound .. maxBound]

newElements :: [Element]
newElements = [Metal, Wood, Earth, Yin, Yang]

rampOf :: Element -> ColorRamp
rampOf = appColor . elementAppearance

blendOf :: Element -> BlendMode
blendOf = appBlend . elementAppearance

alphaOf :: Word32 -> Word32
alphaOf c = c .&. 0xFF

spec :: Spec
spec = describe "element vocabulary, 4 -> 9 (func-spec 0021 S1)" $ do
  describe "the append-only law (§2.4): declaration order is wire code" $ do
    it "keeps the original four at ordinals 0..3, by name" $
      take 4 allElements `shouldBe` [Neutral, Fire, Water, Lightning]

    it "appends the five new ones after them, in the declared order" $
      drop 4 allElements `shouldBe` newElements

    it "has exactly nine elements and no duplicates" $ do
      length allElements `shouldBe` 9
      nub allElements `shouldBe` allElements

    it "pins the ordinals the circle digest reads" $
      map fromEnum allElements `shouldBe` [0 .. 8]

  describe "the existing four are untouched" $ do
    it "Neutral is still the 0001 plain discharge, field for field" $
      elementAppearance Neutral
        `shouldBe` Appearance
          (ColorRamp 0xFFFFFFFF 0xFFFFFFFF)
          0.05
          BlendAlpha
          Nothing
          BillboardSquare

    it "Fire, Water and Lightning keep their ramps and blends" $ do
      rampOf Fire `shouldBe` ColorRamp 0xFFD966FF 0xE6390000
      rampOf Water `shouldBe` ColorRamp 0x66CCFFFF 0x1A4DCC33
      rampOf Lightning `shouldBe` ColorRamp 0xFFFFCCFF 0x8033FF66
      map blendOf [Fire, Water, Lightning]
        `shouldBe` [BlendAdditive, BlendAlpha, BlendAdditive]

  describe "the five new rows are real material" $ do
    it "gives all nine elements distinct colour ramps" $ do
      let ramps = map rampOf allElements
      nub ramps `shouldBe` ramps

    it "leaves every other appearance field at the table's defaults" $
      mapM_
        ( \e -> do
            appSize (elementAppearance e) `shouldBe` 0.05
            appAmplify (elementAppearance e) `shouldBe` Nothing
            appShape (elementAppearance e) `shouldBe` BillboardSquare
        )
        newElements

    -- The point of the whole round, as far as func-spec 0015 §8-5 is
    -- concerned: without both modes present among the new elements, a
    -- composition of two of them would still render as one batch.
    it "puts at least one new element in each blend mode" $ do
      map blendOf newElements `shouldContain` [BlendAlpha]
      map blendOf newElements `shouldContain` [BlendAdditive]

    it "splits the nine 5 alpha / 4 additive (§2.1)" $ do
      length (filter ((== BlendAlpha) . blendOf) allElements) `shouldBe` 5
      length (filter ((== BlendAdditive) . blendOf) allElements) `shouldBe` 4

    -- Neutral is deliberately exempt: it is the plain discharge and has
    -- to stay solid white end to end (the 0001 law asserted above).
    it "fades every new element out over its life" $
      mapM_
        ( \e ->
            let ColorRamp start end = rampOf e
             in (e, alphaOf end) `shouldSatisfy` ((< alphaOf start) . snd)
        )
        newElements

    it "starts every new element fully opaque, so the fade has somewhere to go" $
      mapM_
        ( \e ->
            let ColorRamp start _ = rampOf e
             in (e, alphaOf start) `shouldBe` (e, 0xFF)
        )
        newElements

    it "gives 陰 a darker start than 陽 — the pair reads as opposites" $ do
      let luma c =
            ((c `shiftR` 24) .&. 0xFF)
              + ((c `shiftR` 16) .&. 0xFF)
              + ((c `shiftR` 8) .&. 0xFF)
          ColorRamp yinStart _ = rampOf Yin
          ColorRamp yangStart _ = rampOf Yang
      luma yinStart `shouldSatisfy` (< luma yangStart)
