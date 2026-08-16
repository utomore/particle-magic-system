-- | S1 (func-spec 0014 §7): the @magic-validate@ CLI.
--
-- The tool's whole surface is 'validateBytes' and 'renderReport' — the IO
-- shell around them reads files and calls 'exitWith', which is not worth
-- a test. So this is where the delivered contract lives:
--
--   * the ten shipped examples all pass, which is the completion
--     condition §1.1 states;
--   * each way a file can be wrong produces the message an author needs,
--     with the position 'Magic.Codec' already computes;
--   * @--stats@ agrees with 'budgetPlanOf' — the tool reports the
--     compiler's numbers, it does not recompute them;
--   * the line format is frozen (§9), so it is asserted character by
--     character rather than by eyeball.
module ValidateSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sort)
import qualified Data.Vector.Unboxed as U
import System.Directory (listDirectory)
import Test.Hspec

import Magic.Codec (loadCircle)
import Magic.Interface
  ( CastRequest (..)
  , ParticleBudget (..)
  , Seconds (..)
  , budgetPlanOf
  , castSpell
  , emittersOf
  , maxSpellParticles
  )
import Validate
  ( Options (..)
  , Report (..)
  , Stats (..)
  , defaultContext
  , exitCodeFor
  , failureCount
  , parseArgs
  , renderReport
  , validateBytes
  )

spellDir :: FilePath
spellDir = "assets/spells"

-- | Every shipped example, in the order the tool would walk them.
examplePaths :: IO [FilePath]
examplePaths = do
  entries <- listDirectory spellDir
  pure [spellDir ++ "/" ++ e | e <- sort entries, ".json" `isSuffixOf` e]

reportFor :: FilePath -> IO Report
reportFor path = validateBytes path <$> BS.readFile path

-- | A file that is not JSON at all: the brace closes an array.
brokenSyntax :: BS.ByteString
brokenSyntax =
  BSC.pack $
    unlines
      [ "{"
      , "  \"version\": 1,"
      , "  \"name\": \"oops\","
      , "  \"circle\": {"
      , "    \"outer\": ["
      , "  }"
      , "}"
      ]

-- | Well-formed JSON, unknown rune tag.
unknownRune :: BS.ByteString
unknownRune =
  BSC.pack "{\"version\":1,\"name\":\"x\",\"circle\":{\"outer\":[{\"rune\":\"wobble\"}]}}"

-- | Well-formed and loadable, but uncastable: power 100 asks for
-- 25600 particles against a 4096 cap.
overBudget :: BS.ByteString
overBudget =
  BSC.pack
    "{\"version\":1,\"name\":\"x\",\"circle\":{\"core\":{\"center\":{\"element\":\"fire\",\"power\":100}}}}"

-- | A version this build does not read.
wrongVersion :: BS.ByteString
wrongVersion = BSC.pack "{\"version\":2,\"name\":\"x\",\"circle\":{}}"

spec :: Spec
spec = do
  describe "the shipped examples (func-spec 0014 §1.1)" $ do
    it "all shipped examples load, compile and cast" $ do
      paths <- examplePaths
      -- 10 at func-spec 0014's delivery; soft-bloom.json joins in 0015,
      -- lattice-seal.json in 0016, twin-lance.json in 0025.
      length paths `shouldBe` 13
      reports <- mapM reportFor paths
      [repPath r | r <- reports, isFail r] `shouldBe` []
      exitCodeFor reports `shouldBe` 0

    it "reports OK on one line each, path included, nothing else" $ do
      paths <- examplePaths
      reports <- mapM reportFor paths
      concatMap (renderReport False) reports
        `shouldBe` unlines ["OK " ++ p | p <- paths]

  describe "a broken file says what is broken (§1.1)" $ do
    it "malformed JSON carries the line and column Magic.Codec computes" $ do
      let r = validateBytes "syntax.json" brokenSyntax
      firstLine r `shouldBe` "FAIL syntax.json"
      detail r `shouldSatisfy` ("spell JSON error:" `isInfixOf`)
      detail r `shouldSatisfy` ("line 6, column 3" `isInfixOf`)

    it "an unknown rune tag lists the tags that are legal there" $ do
      let r = validateBytes "rune.json" unknownRune
      firstLine r `shouldBe` "FAIL rune.json"
      detail r `shouldSatisfy` ("$.circle.outer[0]" `isInfixOf`)
      detail r `shouldSatisfy` ("shape, radiate, range" `isInfixOf`)

    it "a wrong schema version is a failure, not a crash" $ do
      let r = validateBytes "v2.json" wrongVersion
      firstLine r `shouldBe` "FAIL v2.json"
      detail r `shouldSatisfy` ("version 2" `isInfixOf`)

    it "loading is not casting: an over-budget circle passes the codec and fails the cast" $ do
      -- The point of the second gate. The codec is happy with it...
      loadCircle overBudget `shouldSatisfy` isRight
      -- ...and the tool still refuses it, in the author's vocabulary.
      let r = validateBytes "huge.json" overBudget
      firstLine r `shouldBe` "FAIL huge.json"
      detail r `shouldSatisfy` ("25600" `isInfixOf`)
      detail r `shouldSatisfy` (show maxSpellParticles `isInfixOf`)
      detail r `shouldSatisfy` ("power" `isInfixOf`)

    it "counts failures for the exit code" $ do
      let reports =
            [ validateBytes "a" brokenSyntax
            , validateBytes "b" overBudget
            , validateBytes "c" unknownRune
            ]
      failureCount reports `shouldBe` 3
      exitCodeFor reports `shouldBe` 3

  describe "--stats reports the compiler's numbers, not its own (§1.2)" $ do
    it "budget, per-emitter split and emitter count all come from the cast" $ do
      paths <- examplePaths
      mapM_ checkAgainstCast paths

    it "the cap is maxSpellParticles" $ do
      Right st <- repResult <$> reportFor (spellDir ++ "/ring-fire.json")
      stCap st `shouldBe` maxSpellParticles

    it "recovers the lifetime the compiler computed" $ do
      -- delay 0 + duration 4 + lifetime 1.5, straight off the file. All
      -- three are exact in binary, so the probe must land on the nose.
      Right st <- repResult <$> reportFor (spellDir ++ "/converge-flame.json")
      stLifetime st `shouldBe` Seconds 5.5
      -- With phases: the bridge shift (0.3) and the whole prelude
      -- (draw 1.2 + converge 0.6) both delay casting -> 2.1 + 4 + 2.
      -- None of those three is exact in binary, so this one is compared
      -- to a tolerance: what the probe reproduces is the compiler's
      -- arithmetic, not decimal arithmetic.
      Right sigil <- repResult <$> reportFor (spellDir ++ "/grand-sigil.json")
      let Seconds got = stLifetime sigil
      abs (got - 8.1) `shouldSatisfy` (< 1e-9)

    it "echoes the declared phases, and says so when there are none" $ do
      Right sigil <- repResult <$> reportFor (spellDir ++ "/grand-sigil.json")
      stPhases sigil `shouldBe` Just (Seconds 1.2, Seconds 0.6)
      Right flame <- repResult <$> reportFor (spellDir ++ "/converge-flame.json")
      stPhases flame `shouldBe` Nothing

    it "counts the circle's force fields" $ do
      Right well <- repResult <$> reportFor (spellDir ++ "/gravity-well.json")
      stFields well `shouldBe` 3
      Right flame <- repResult <$> reportFor (spellDir ++ "/converge-flame.json")
      stFields flame `shouldBe` 0

  describe "the frozen line format (func-spec 0014 §2, §9)" $ do
    it "every record starts with OK or FAIL and the path, one line" $ do
      paths <- examplePaths
      reports <- mapM reportFor paths
      let rendered = concatMap (renderReport True) reports
          heads = [l | l <- lines rendered, not ("  " `isPrefixOf` l)]
      heads `shouldBe` ["OK " ++ p | p <- paths]

    it "every detail line is indented by exactly two spaces" $ do
      let rendered = renderReport True (validateBytes "syntax.json" brokenSyntax)
      drop 1 (lines rendered) `shouldSatisfy` all isDetail

    it "--stats adds six labelled lines under a passing file, and nothing without it" $ do
      r <- reportFor (spellDir ++ "/gravity-well.json")
      let bare = lines (renderReport False r)
          full = lines (renderReport True r)
      length bare `shouldBe` 1
      length full `shouldBe` 7
      map (takeWhile (/= ' ') . drop 2) (drop 1 full)
        `shouldBe` ["budget", "emitters", "lifetime", "phases", "fields", "extent"]

    it "a record always ends in a newline, so runs concatenate" $ do
      r <- reportFor (spellDir ++ "/empty.json")
      last (renderReport True r) `shouldBe` '\n'
      last (renderReport False r) `shouldBe` '\n'

  describe "the command line (frozen, §9)" $ do
    it "takes paths in the order given" $
      parseArgs ["a.json", "b.json"]
        `shouldBe` Right (Options {optStats = False, optPaths = ["a.json", "b.json"]})

    it "accepts --stats anywhere" $ do
      parseArgs ["--stats", "a"] `shouldBe` Right (Options True ["a"])
      parseArgs ["a", "--stats"] `shouldBe` Right (Options True ["a"])

    it "refuses to guess when given nothing to check" $
      parseArgs [] `shouldSatisfy` isLeft

    it "rejects an unknown option instead of treating it as a path" $
      parseArgs ["--verbose", "a"] `shouldSatisfy` isLeft

-- | The tool's numbers must BE the cast's numbers.
checkAgainstCast :: FilePath -> Expectation
checkAgainstCast path = do
  bytes <- BS.readFile path
  circle <- either (fail . show) pure (loadCircle bytes)
  spell <- either (fail . show) pure (castSpell (CastRequest circle defaultContext))
  Right st <- pure (repResult (validateBytes path bytes))
  stBudget st `shouldBe` budgetTotal (budgetPlanOf spell)
  stPerEmitter st `shouldBe` U.toList (budgetPerEmitter (budgetPlanOf spell))
  stEmitters st `shouldBe` length (emittersOf spell)
  sum (stPerEmitter st) `shouldBe` stBudget st

firstLine :: Report -> String
firstLine r = case lines (renderReport True r) of
  (l : _) -> l
  [] -> ""

detail :: Report -> String
detail = unlines . drop 1 . lines . renderReport True

-- | The tool's own indentation. A codec error may wrap onto several
-- lines and indent further inside itself; what is asserted here is that
-- every line after the first is offset from the record head, so a script
-- can tell records apart by column 1 alone.
isDetail :: String -> Bool
isDetail = isPrefixOf "  "

isFail :: Report -> Bool
isFail = either (const True) (const False) . repResult

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
