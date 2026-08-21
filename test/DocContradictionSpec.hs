-- | host-runtime B001: the integration guide must not contradict itself.
--
-- @docs\/integration.md@ says the same thing in several places on purpose --
-- a Unity host reads §5, a C host reads §4, and neither reads the other --
-- so a contract that changes has to change in every copy. Host-runtime
-- stage one changed two of them. F004 replaced "one handle is owned by one
-- thread" with the two lists in §4.4.2, and F003 replaced "the RTS cannot
-- be restarted, so the process dies" with a one-way door that answers
-- @PM_ERR_STATE@. Three copies stayed behind: §4.6's scene table, §6's
-- language-agnostic rules, and §8's honest-limitations table -- so the
-- guide taught a host the retired rule and the current one at once,
-- depending on which section it opened.
--
-- A guard for exactly this already existed (@FFIContractSpec@ F004 T6) and
-- was green through all three, because it compared whole literal
-- sentences: the surviving text read 「一個 handle 一個執行緒」 (no 「屬於」)
-- and 「庫內仍然無鎖」 (an extra 「仍然」), and two characters were enough to
-- walk past it. A guard that is present but does not guard is worse than
-- none, because the next round reads it as settled.
--
-- So this spec does not compare sentences. It
--
--   1. normalises the text first -- whitespace (the tree is CRLF) and
--      Markdown emphasis dropped -- so hedging adverbs and dropped
--      particles change a sentence's length but not the fragment being
--      matched;
--   2. bans short /semantic fragments/ rather than sentences, so every
--      phrasing of one retired claim collapses onto one needle;
--   3. asserts /structure/ where a word list cannot reach: every 「無鎖」
--      must be the one §4.4.2 licenses (每幀路徑無鎖, not 庫內無鎖), and
--      every §8 row about shutdown or threads must carry the promise §4.4
--      makes rather than the ban it retired;
--   4. pins §4.4 and §4.4.2 as the /positive/ anchors, so the cheap way to
--      make this spec green -- delete the authoritative paragraphs -- is
--      itself red.
--
-- Exactly two sections are exempt from (2): §4.4 and §4.4.2 themselves,
-- which name the retired claims in order to retire them (「以前這裡只寫
-- 『handle 歸單一執行緒所有』一句」). That exemption is the rule stated
-- precisely rather than a hole in it -- one place in the guide may quote a
-- retired contract, and it is the place that replaces it; every other
-- section is a copy, and a copy that still carries the old claim is the
-- defect. The exempt sections do not go unguarded: (4) holds them to the
-- replacement.
--
-- Deliberately self-contained in its file reading (same discipline as
-- "ReleaseDocSpec", "CIWorkflowSpec" and "ExampleLoopSpec"). What it does
-- export is the vocabulary and the outside-the-authority view of the
-- guide, because @FFIContractSpec@ F004 T6 asserts the same absence from
-- the same file, and a second copy of the vocabulary is precisely how the
-- first one went stale.
module DocContradictionSpec
  ( spec

    -- * Shared with "FFIContractSpec" (F004 T6)
  , normalizeDoc
  , retiredClaims
  , guideOutsideAuthority
  ) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

integrationPath :: FilePath
integrationPath = "docs/integration.md"

readUtf8 :: FilePath -> IO String
readUtf8 path = T.unpack . TE.decodeUtf8 <$> BS.readFile path

-- | Everything that can be varied without changing what a sentence claims,
-- removed: every kind of whitespace (ASCII, the ideographic space, and the
-- carriage returns this tree carries on Windows) plus Markdown's @*@ and
-- @`@. What survives is the claim itself, which is what the needles below
-- are written against -- @「一個 handle 一個執行緒」@ and
-- @「一個 **handle** 屬於一個執行緒」@ both end up containing @一個執行緒@.
--
-- Underscore is deliberately /not/ stripped even though Markdown emphasises
-- with it, because every C symbol this guide names has one in the middle
-- (@pm_shutdown@, @PM_ERR_STATE@) and the cross-section checks below match
-- on exactly those. This guide emphasises with @*@ throughout; the trade is
-- one-sided.
normalizeDoc :: String -> String
normalizeDoc = filter keep
  where
    keep c = not (isSpace c) && c `notElem` ("*`" :: String)

-- | Claims host-runtime stage one retired, each as the shortest fragment
-- that survives every rephrasing of it, paired with what it used to say.
-- The pair is what gets asserted, so a failure names the claim instead of
-- printing @False /= True@.
--
-- These are fragments, not sentences, on purpose: a sentence is a spelling
-- and can be respelled, but 「一個執行緒」 is the ownership rule itself.
-- The counter for threads elsewhere in this guide is 條 (「那條執行緒」,
-- 「另一條執行緒」), so 「一個執行緒」 has no innocent reading here.
retiredClaims :: [(String, String)]
retiredClaims =
  [ ( "一個執行緒"
    , "F004 §4.4.2 retired handle-per-thread ownership \
      \(一個 handle 一個執行緒 / 一個 scene 一個執行緒 / 一個 handle 屬於一個執行緒)"
    )
  , ( "單一執行緒"
    , "F004 §4.4.2 retired the same claim in its older wording (handle 歸單一執行緒所有)"
    )
  , ( "執行緒所有"
    , "F004 §4.4.2 retired the same claim, word order reversed"
    )
  , ( "不可重啟"
    , "F003 §4.4 retired 「RTS 不可重啟」: shutdown is a one-way door that answers PM_ERR_STATE, \
      \it no longer kills the host process"
    )
  , ( "不能再pm_init"
    , "F003 §4.4 retired 「pm_shutdown() 之後不能再 pm_init()」: pm_init() is a no-op and \
      \pm_init_ex() answers PM_ERR_STATE"
    )
  ]

-- | The headings that open the two sections allowed to name a retired
-- claim, because they are the ones that retired it.
authorityHeadings :: [String]
authorityHeadings = ["### 4.4 ", "### 4.4.2"]

-- | Where the section opened by the first heading with this prefix starts
-- and how many lines it runs for, ending at the next heading of the same
-- or shallower level. @(0, 0)@ when the heading is not there at all.
sectionSpan :: String -> [String] -> (Int, Int)
sectionSpan prefix ls =
  case break (prefix `isPrefixOf`) ls of
    (_, []) -> (0, 0)
    (before, heading : rest) ->
      (length before, 1 + length (takeWhile (not . closesAt (headingLevel heading)) rest))
  where
    headingLevel = length . takeWhile (== '#')
    closesAt level l = let n = headingLevel l in n > 0 && n <= level

-- | The lines of that section.
sectionOf :: String -> [String] -> [String]
sectionOf prefix ls = let (start, len) = sectionSpan prefix ls in take len (drop start ls)

-- | Everything but those line ranges. Index-based rather than
-- set-of-lines, because a table row is not a unique string.
withoutSpans :: [(Int, Int)] -> [String] -> [String]
withoutSpans spans ls =
  [ l
  | (i, l) <- zip [0 :: Int ..] ls
  , not (any (\(start, len) -> i >= start && i < start + len) spans)
  ]

-- | The normalised guide with the two authority sections cut out: every
-- copy of a contract, and none of the two originals. This is the text the
-- retired claims must not appear in.
guideOutsideAuthority :: IO String
guideOutsideAuthority = do
  ls <- lines <$> readUtf8 integrationPath
  pure (normalizeDoc (unlines (withoutSpans (map (`sectionSpan` ls) authorityHeadings) ls)))

-- | The table rows of a section: everything a limitation table states is
-- stated in one, so a row is the unit a cross-check has to reason about.
tableRows :: [String] -> [String]
tableRows = filter (("|" `isPrefixOf`) . dropWhile isSpace)

-- | Every four characters that immediately precede an occurrence of the
-- needle. One left-to-right pass, because @inits@ over a 40k-character
-- document is not a thing to do to a test suite.
contextsBefore :: String -> String -> [String]
contextsBefore needle = go ""
  where
    width = length ("每幀路徑" :: String)
    go _ [] = []
    go seen s@(c : cs)
      | needle `isPrefixOf` s = reverse (take width seen) : go (c : seen) cs
      | otherwise = go (c : seen) cs

spec :: Spec
spec = describe "docs/integration.md agrees with itself (host-runtime B001)" $ do
  -- T1. The fragment ban, against every section except the two that own
  -- these contracts -- §4.6's table, §6's rule list and §8's row were three
  -- different sentences carrying two claims, and this is one assertion.
  it "carries no claim host-runtime stage one retired, in any phrasing" $ do
    ls <- lines <$> readUtf8 integrationPath
    -- The exemption has to be earned by existing: a renamed heading must
    -- not silently widen it.
    mapM_
      (\h -> (h, snd (sectionSpan h ls)) `shouldSatisfy` ((> 0) . snd))
      authorityHeadings
    doc <- guideOutsideAuthority
    mapM_
      (\claim -> (claim, fst claim `isInfixOf` doc) `shouldBe` (claim, False))
      retiredClaims

  -- T1. The structural half of the same defect: 「庫內無鎖」 is not a word
  -- that can be banned (「無鎖」 is exactly what §4.4.2 promises) -- what is
  -- wrong about it is the scope. C2.2 licenses one scope and one only, so
  -- assert the qualifier instead of the claim: 庫內無鎖, 庫內仍然無鎖 and
  -- 庫內部無鎖 all fail this without any of them being enumerated.
  it "scopes every lock-free claim to the per-frame path, never to the library" $ do
    doc <- normalizeDoc <$> readUtf8 integrationPath
    let contexts = contextsBefore "無鎖" doc
    -- Not vacuous: the promise has to be in the guide to be scoped.
    length contexts `shouldSatisfy` (>= 1)
    contexts `shouldBe` replicate (length contexts) "每幀路徑"

  -- T1. §8 is a summary of contracts stated in full elsewhere, which is
  -- what makes it the copy that goes stale silently: nothing in it is
  -- wrong on its own terms, it is only out of step with §4.4. So the
  -- assertion is the relation, not the wording -- a row may say whatever
  -- it likes about shutdown as long as it names the code that replaced the
  -- crash, and whatever it likes about threads as long as it carries the
  -- guarantee rather than a prohibition.
  it "keeps §8's limitation table in step with §4.4's runtime contract" $ do
    ls <- lines <$> readUtf8 integrationPath
    let rows = tableRows (sectionOf "## 8." ls)
        shutdownRows = filter (("pm_shutdown" `isInfixOf`) . normalizeDoc) rows
        threadRows = filter (("執行緒" `isInfixOf`) . normalizeDoc) rows
    -- Deleting the row is not a way to pass this.
    length shutdownRows `shouldSatisfy` (>= 1)
    mapM_
      (\r -> (r, "PM_ERR_STATE" `isInfixOf` normalizeDoc r) `shouldBe` (r, True))
      shutdownRows
    mapM_
      ( \r ->
          let n = normalizeDoc r
           in (r, "不丟更新" `isInfixOf` n || "4.4.2" `isInfixOf` n) `shouldBe` (r, True)
      )
      threadRows

  -- T1. The positive anchors. Every assertion above is an absence, and the
  -- cheapest way to satisfy an absence is to delete the paragraph that
  -- states the truth. These two sections are where §4.6, §6 and §8 point,
  -- so they are the ones that have to still say it.
  it "keeps §4.4 and §4.4.2 as the source both of the retired claims' answers" $ do
    ls <- lines <$> readUtf8 integrationPath
    let lifecycle = normalizeDoc (unlines (sectionOf "### 4.4 " ls))
        threads = normalizeDoc (unlines (sectionOf "### 4.4.2" ls))
    mapM_
      (\n -> (n, n `isInfixOf` lifecycle) `shouldBe` (n, True))
      ["單向門", "PM_ERR_STATE", "不再殺掉"]
    mapM_
      (\n -> (n, n `isInfixOf` threads) `shouldBe` (n, True))
      ["不丟更新", "每幀路徑不取任何鎖", "永遠不會自己開OS執行緒", "不保證"]
