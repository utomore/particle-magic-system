{-# LANGUAGE OverloadedStrings #-}

-- | S2 (func-spec 0024 §6): @magic-inspect@'s report.
--
-- The tool adds no analysis (func-spec 0024 §1-3), so there is nothing
-- here about /whether/ a number is right — 'BudgetPlanSpec',
-- 'CapacitySpec' and 'SpaceBoundsSpec' already own those. What is tested
-- is the join: that the report prints the number the query returns, that
-- it prints one row per emitter, that a spell which does not compile
-- produces no report at all, and that the layout scripts will grep is the
-- layout that ships.
module InspectSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isDigit, isSpace)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Inspect (inspectReport, sectionHeaders)
import Magic.Circle (Circle (..))
import Magic.Codec (loadCircle)
import Magic.Interface
  ( ActiveSpell
  , CastRequest (..)
  , CompileError (BudgetExceeded)
  , ParticleBudget (budgetTotal)
  , budgetPlanOf
  , castSpell
  , emittersOf
  )
import System.Directory (listDirectory)
import Test.Hspec
import Validate (defaultContext)

spellDir :: FilePath
spellDir = "assets/spells"

examplePaths :: IO [FilePath]
examplePaths = do
  entries <- listDirectory spellDir
  pure [spellDir ++ "/" ++ e | e <- sort entries, ".json" `isSuffixOf` e]

loadExample :: FilePath -> IO Circle
loadExample path = do
  bytes <- BS.readFile path
  case loadCircle bytes of
    Right circle -> pure circle
    Left err -> fail (path ++ ": " ++ show err)

everyExample :: IO [Circle]
everyExample = mapM loadExample =<< examplePaths

-- | The report, or a test failure. Every example in @assets\/spells@
-- compiles (@Acceptance14Spec@ says so), so a 'Left' here is a bug in this
-- suite's fixtures rather than a case to handle.
reportOf :: Circle -> [String]
reportOf circle = case inspectReport circle of
  Right ls -> ls
  Left err -> error ("inspectReport failed on a shipped example: " ++ show err)

castOf :: Circle -> ActiveSpell
castOf circle = case castSpell (CastRequest circle defaultContext) of
  Right spell -> spell
  Left err -> error ("castSpell failed on a shipped example: " ++ show err)

grandSigil :: IO Circle
grandSigil = loadExample (spellDir ++ "/grand-sigil.json")

-- | A circle the compiler refuses: 256 x 400 particles is well past the
-- 16384 cap. Well-formed JSON, so it gets all the way to 'castSpell' —
-- which is the only interesting failure for this module.
overBudget :: Circle
overBudget =
  case loadCircle "{\"version\":1,\"circle\":{\"core\":{\"center\":{\"element\":\"fire\",\"power\":400}}}}" of
    Right circle -> circle
    Left err -> error ("over-budget fixture does not load: " ++ show err)

spec :: Spec
spec = describe "magic-inspect's report (func-spec 0024 S2)" $ do
  it "is a pure function: the same circle reports the same lines, twice" $ do
    circles <- everyExample
    -- Value equality on the whole report, for every shipped example. A
    -- report that reached for a clock, a locale or an environment
    -- variable would have to be caught here, since nothing downstream
    -- would notice.
    length circles `shouldSatisfy` (>= 16)
    map inspectReport circles `shouldBe` map inspectReport circles

  it "prints the budget the query returns" $ do
    circles <- everyExample
    [firstNumberOn "budget" (reportOf c) | c <- circles]
      `shouldBe` [Just (budgetTotal (budgetPlanOf (castOf c))) | c <- circles]

  it "prints one emitter row per compiled emitter" $ do
    circles <- everyExample
    [length (sectionBody "emitters" (reportOf c)) - 1 | c <- circles]
      `shouldBe` [length (emittersOf (castOf c)) | c <- circles]

  it "and the emitter count it prints agrees with the rows it prints" $ do
    circles <- everyExample
    [firstNumberOn "emitters" (reportOf c) | c <- circles]
      `shouldBe` [Just (length (sectionBody "emitters" (reportOf c)) - 1) | c <- circles]

  it "returns Left, not a partial report, when the circle does not compile" $
    case inspectReport overBudget of
      Left (BudgetExceeded wanted cap) -> do
        wanted `shouldSatisfy` (> cap)
        cap `shouldBe` 16384
      Right ls ->
        expectationFailure ("expected a compile failure, got " ++ show (length ls) ++ " lines")

  describe "the layout is the contract (func-spec 0014 §9.3's convention)" $ do
    it "has every section, in order, at column 0" $ do
      ls <- reportOf <$> grandSigil
      [l | l <- ls, not (null l), not (" " `isPrefixOf` l)] `shouldBe` sectionHeaders

    it "indents every body line by exactly two spaces" $ do
      ls <- reportOf <$> grandSigil
      [l | l <- ls, " " `isPrefixOf` l, takeWhile isSpace l /= "  "] `shouldBe` []

    it "names every summary field a script would grep for" $ do
      ls <- reportOf <$> grandSigil
      map firstWord (sectionBody "spell" ls)
        `shouldBe` [ "budget"
                   , "emitters"
                   , "lifetime"
                   , "extent"
                   , "phases"
                   , "fields"
                   , "anchors"
                   , "style"
                   ]

    it "and the emitter table has its column header" $ do
      ls <- reportOf <$> grandSigil
      take 1 (sectionBody "emitters" ls) `shouldBe` ["  idx  particles  extent"]

    it "and the batch table has its own" $ do
      ls <- reportOf <$> grandSigil
      take 1 (sectionBody "batches" ls) `shouldBe` ["  idx  blend      billboard"]

  it "reports a spell without phases as a two-stage timeline" $ do
    ls <- reportOf <$> loadExample (spellDir ++ "/empty.json")
    concatMap (drop 1 . words) (sectionBody "timeline" ls) `shouldBe` ["casting", "over"]

  it "and a spell with phases as a four-stage one" $ do
    ls <- reportOf <$> grandSigil
    concatMap (drop 1 . words) (sectionBody "timeline" ls)
      `shouldBe` ["draw", "converge", "casting", "over"]

  -- Func-spec 0026 T7. A lingering sigil moves the closing landmark and
  -- nothing else, so the tool that reports the landmarks has to show it:
  -- the "over" row is the spell body's end plus the linger, while the
  -- three rows above it are where they would be without a sigil key. The
  -- summary block is untouched by that round (its field list, frozen
  -- above, still reads budget…style), so this is where an author sees it.
  it "shows a lingering sigil in the closing landmark, and only there" $ do
    lingering <- loadExample (spellDir ++ "/lingering-seal.json")
    let ls = reportOf lingering
        without = reportOf lingering {circleSigil = Nothing}
        stages = sectionBody "timeline" ls
        landmark what rows =
          case [l | l <- rows, drop 1 (words l) == [what]] of
            (l : _) -> Just (takeWhile (/= 's') (firstWord l))
            [] -> Nothing
    concatMap (drop 1 . words) stages `shouldBe` ["draw", "converge", "casting", "over"]
    -- The spell body ends at 5.300s; the file asks for 2.5 more.
    landmark "over" without `shouldBe` Just "5.300"
    landmark "over" stages `shouldBe` Just "7.800"
    mapM_
      (\what -> landmark what stages `shouldBe` landmark what (sectionBody "timeline" without))
      ["draw", "converge", "casting"]

-- Reading the report back ------------------------------------------------------

-- | The indented lines under a section header, up to the blank line that
-- ends it.
sectionBody :: String -> [String] -> [String]
sectionBody name ls = takeWhile (not . null) (drop 1 (dropWhile (/= name) ls))

firstWord :: String -> String
firstWord = takeWhile (not . isSpace) . dropWhile isSpace

-- | The first run of digits on the summary line with this name.
firstNumberOn :: String -> [String] -> Maybe Int
firstNumberOn name ls =
  case [l | l <- sectionBody "spell" ls, firstWord l == name] of
    (l : _) -> case dropWhile (not . isDigit) l of
      [] -> Nothing
      digits -> Just (read (takeWhile isDigit digits))
    [] -> Nothing
