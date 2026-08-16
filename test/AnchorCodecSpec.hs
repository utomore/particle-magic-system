-- | S3 (func-spec 0025 §6): the @"anchors"@ key.
--
-- Third circle-level opt-in property after @phases@ and @fields@, and the
-- fourth time this repo states the same compatibility law: a missing key
-- and @null@ both mean "no key", and every file written before the key
-- existed decodes to exactly what it decoded to before.
--
-- The one shape that is /not/ a synonym for absence is the empty array.
-- @[]@ could mean "no activation point" or "the default one" and neither
-- is guessable from the file, so the codec refuses it — which is a claim
-- worth a test precisely because it is a deliberate asymmetry.
module AnchorCodecSpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString.Char8 as BSC
import Data.List (isInfixOf)
import Magic.Circle (Circle (..), emptyCircle)
import Magic.Codec (LoadError (..), loadCircle, saveCircle)
import Magic.Rune (Anchor (..))
import Magic.Types (V3 (..))
import SpaceExamples (exampleCircles, loadExample)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | A spell file with the given @circle@ body.
fileWith :: String -> BSC.ByteString
fileWith body = BSC.pack ("{\"version\":1,\"circle\":{" ++ body ++ "}}")

loadBody :: String -> Either LoadError Circle
loadBody = loadCircle . fileWith

anchorsJson :: String
anchorsJson =
  "\"anchors\":[{\"offset\":[0.6,0,0],\"normal\":[0,0,1]},\
  \{\"offset\":[-0.6,0,0],\"normal\":[0,0,1]}]"

twoAnchors :: [Anchor]
twoAnchors =
  [ Anchor (V3 0.6 0 0) (V3 0 0 1)
  , Anchor (V3 (-0.6) 0 0) (V3 0 0 1)
  ]

errorText :: Either LoadError Circle -> String
errorText result = case result of
  Left (JsonError msg) -> msg
  Left other -> show other
  Right _ -> "<decoded successfully>"

newtype AnchorList = AnchorList [Anchor]
  deriving (Show)

instance Arbitrary AnchorList where
  arbitrary = do
    n <- choose (1, 16)
    AnchorList <$> vectorOf n anchor
  shrink (AnchorList as) = [AnchorList as' | as' <- shrinkList (const []) as, not (null as')]

-- | Offsets are free; normals must be non-zero, so one component is
-- pinned away from zero.
anchor :: Gen Anchor
anchor = Anchor <$> vec <*> nonZeroVec
  where
    vec = V3 <$> coord <*> coord <*> coord
    nonZeroVec = do
      V3 x y _ <- vec
      z <- elements [-1, 1] :: Gen Float
      pure (V3 x y z)
    -- Eighths: exact in binary, so the round trip is about the codec and
    -- not about float printing.
    coord = (\v -> fromIntegral v / 8) <$> (choose (-40, 40) :: Gen Int)

spec :: Spec
spec = describe "the \"anchors\" key (func-spec 0025 S3)" $ do
  describe "the three spellings, and which of them is an error" $ do
    it "a missing key means the default single activation point" $
      fmap circleAnchors (loadBody "") `shouldBe` Right Nothing

    it "an explicit null means the same thing" $
      fmap circleAnchors (loadBody "\"anchors\":null") `shouldBe` Right Nothing

    it "an empty array is an error, not a third spelling of absence" $ do
      let result = loadBody "\"anchors\":[]"
      result `shouldSatisfy` isLeft'
      errorText result `shouldSatisfy` isInfixOf "at least one activation point"
      errorText result `shouldSatisfy` isInfixOf "anchors"

    it "a populated array decodes to the points it names" $
      fmap circleAnchors (loadBody anchorsJson) `shouldBe` Right (Just twoAnchors)

  describe "validation, at the boundary as always" $ do
    it "rejects a zero normal, naming the key path" $ do
      let result = loadBody "\"anchors\":[{\"offset\":[0,0,0],\"normal\":[0,0,0]}]"
      result `shouldSatisfy` isLeft'
      errorText result `shouldSatisfy` isInfixOf "normal must be a non-zero vector"
      errorText result `shouldSatisfy` isInfixOf "anchors"

    it "rejects more than 16 activation points, naming the cap" $ do
      let one = "{\"offset\":[0,0,0],\"normal\":[0,0,1]}"
          seventeen = "\"anchors\":[" ++ intercalate' (replicate 17 one) ++ "]"
          result = loadBody seventeen
      result `shouldSatisfy` isLeft'
      errorText result `shouldSatisfy` isInfixOf "too many activation points"
      errorText result `shouldSatisfy` isInfixOf "the cap is 16"

    it "accepts exactly 16" $ do
      let one = "{\"offset\":[0,0,0],\"normal\":[0,0,1]}"
          sixteen = "\"anchors\":[" ++ intercalate' (replicate 16 one) ++ "]"
      fmap (fmap length . circleAnchors) (loadBody sixteen) `shouldBe` Right (Just 16)

    it "rejects a non-array" $
      loadBody "\"anchors\":42" `shouldSatisfy` isLeft'

    it "rejects an offset that is not three numbers" $
      loadBody "\"anchors\":[{\"offset\":[0,0],\"normal\":[0,0,1]}]" `shouldSatisfy` isLeft'

  describe "the round trip" $ do
    prop "saveCircle then loadCircle is the identity, for any anchor list" $
      \(AnchorList as) ->
        let circle = emptyCircle {circleAnchors = Just as}
         in loadCircle (saveCircle circle) === Right circle

    it "and for the absent case, which must encode as null" $ do
      loadCircle (saveCircle emptyCircle) `shouldBe` Right emptyCircle
      BSC.unpack (saveCircle emptyCircle) `shouldSatisfy` isInfixOf "\"anchors\":null"

  -- The opt-in law's data half: no shipped file has the key, so no
  -- shipped file changes meaning. (Its behavioural half — that the
  -- compiled output is bit-for-bit identical — is MultiAnchorSpec.)
  it "leaves every pre-0025 example without activation points" $ do
    circles <- exampleCircles
    forM_ [c | c@(name, _) <- circles, name /= "twin-lance.json"] $ \(name, circle) ->
      (name, circleAnchors circle) `shouldBe` (name, Nothing)

  it "and twin-lance.json, the one file that opts in, has two" $ do
    circle <- loadExample "twin-lance.json"
    fmap length (circleAnchors circle) `shouldBe` Just 2

isLeft' :: Either a b -> Bool
isLeft' = either (const True) (const False)

intercalate' :: [String] -> String
intercalate' [] = ""
intercalate' [x] = x
intercalate' (x : xs) = x ++ "," ++ intercalate' xs
