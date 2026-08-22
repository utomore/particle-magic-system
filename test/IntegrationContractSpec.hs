-- | G-B001: the integration guide must agree with the frozen contract.
--
-- @docs\/integration.md@ is the only integration authority a non-Haskell
-- host has (system.md, "three consumption modes"). The header is the
-- contract; the guide is the description of it. Every other pair in this
-- project's documentation net has a test asserting the two are equal --
-- examples and bindings against the header ("BindingContractSpec"),
-- shipped keys against the authoring manual ("SchemaDocSpec"), error codes
-- against §4.3 ("ExampleLoopSpec" T10) -- and the guide-against-header
-- square was the one left empty. Two things drifted through it:
--
--   * the six-to-nine column widening (ADR-0018) changed the header,
--     'Magic.Interface' and the C# binding, each because a test made it,
--     and left the guide at six columns: @pm_observe_ex@ and
--     @PM_SHAPE_TRAIL@ appeared nowhere in it;
--   * ADR-0016 D4 scoped cross-platform determinism down to /structure/
--     plus a couple of ulp, and the header and @docs\/release.md@ were
--     both rewritten; the guide kept promising a host bit-identical output
--     "on a different platform" too.
--
-- The second one is the reason this spec asserts structure rather than
-- sentences (same discipline as "DocContradictionSpec"). A word list
-- cannot say what went wrong there: every individual word in that sentence
-- was fine, and the defect was that a claim appeared without its bound. So
-- the rule is a shape -- /any/ paragraph that talks about bit-exactness
-- and platforms at once must also carry the tolerance -- and it holds no
-- matter how the sentence is phrased or where in the guide it moves to.
--
-- The vacuity guard on that rule is the other half of it: at least one
-- paragraph must state the cross-platform scope. Deleting the offending
-- sentence would satisfy a ban; it would not satisfy this, because a guide
-- that says nothing about cross-platform determinism is the same trap one
-- indirection further away.
--
-- Header parsing is imported, not copied: "FFIContractSpec" owns those
-- parsers so a second copy cannot go stale (the reason "ExampleLoopSpec"
-- imports them too). File reading is deliberately local, as in the sibling
-- doc specs.
module IntegrationContractSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import FFIContractSpec (headerDefines, headerFunctions)
import Test.Hspec

guidePath, releasePath, headerPath :: FilePath
guidePath = "docs/integration.md"
releasePath = "docs/release.md"
headerPath = "include/particle_magic.h"

spec :: Spec
spec = describe "integration guide agrees with the frozen contract (G-B001)" $ do
  -- T1a. A host that cannot find an entry point in the guide has to read
  -- the header to discover it exists at all -- which is how pm_observe_ex,
  -- and with it the only route to the velocity columns, stayed invisible
  -- through a whole release.
  it "documents every pm_* entry point the header declares" $ do
    entries <- filter ("pm_" `isPrefixOf`) <$> headerFunctions
    guide <- readDoc guidePath
    -- Vacuity guard: a parser that suddenly returned nothing would make
    -- the fold below assert nothing at all.
    length entries `shouldSatisfy` (>= 30)
    mapM_ (want guide) entries

  -- T1b. Scoped to §2.2 rather than the whole file on purpose. This table
  -- is what a host writes its switch against; a code mentioned in some
  -- other section's prose does not help the person reading the table, and
  -- would let exactly the PM_SHAPE_TRAIL gap pass.
  it "lists every PM_SHAPE_* and PM_BLEND_* the header defines, with its value, in §2.2's batch table" $ do
    defines <- headerDefines
    section <- mdSection "### 2.2" <$> readDoc guidePath
    let codes =
          [ name ++ "(" ++ show value ++ ")"
          | (name, value) <- defines
          , "PM_SHAPE_" `isPrefixOf` name || "PM_BLEND_" `isPrefixOf` name
          ]
    null section `shouldBe` False
    length codes `shouldSatisfy` (>= 7)
    mapM_ (want (normalize section)) codes

  -- T1c. The structural rule. Note it is not a ban on the words: §2.4 and
  -- §7 may say 逐位元 as often as they like, because they are talking
  -- about the two consumption paths agreeing on one machine, which is
  -- true. The rule only binds a paragraph that brings platforms into it.
  it "never claims bit-exactness across platforms without stating the tolerance" $ do
    paragraphs <- paragraphsOf <$> readDoc guidePath
    let crossPlatform =
          [ p
          | p <- map normalize paragraphs
          , "逐位元" `isInfixOf` p
          , "跨平台" `isInfixOf` p || "不同平台" `isInfixOf` p
          ]
        bounded p = "ulp" `isInfixOf` p || "結構" `isInfixOf` p
    -- Positive anchor: the guide must state the scope somewhere. Deleting
    -- the sentence is not a fix.
    length crossPlatform `shouldSatisfy` (>= 1)
    filter (not . bounded) crossPlatform `shouldBe` []

  -- T1d. The tripwire for the other direction. When P7 lands ADR-024 and
  -- cross-platform output really does become bit-identical, the tolerance
  -- leaves the header and the release policy -- and this failing is the
  -- reminder that the guide is the third copy and has to move with them.
  it "states the same scope the header and the release policy state" $ do
    header <- readDoc headerPath
    release <- readDoc releasePath
    want header "ulp"
    want release "ulp"

-- ------------------------------------------------------------ assertions

-- | Phrase the expectation so a failure names the missing needle rather
-- than printing @False /= True@ (the sibling doc specs' convention).
want :: String -> String -> Expectation
want haystack needle = (needle, needle `isInfixOf` haystack) `shouldBe` (needle, True)

-- ------------------------------------------------------------ text

-- | The tree is CRLF; strip it here so blank-line splitting and infix
-- matching both see the text a reader sees.
readDoc :: FilePath -> IO String
readDoc path = filter (/= '\r') . T.unpack . TE.decodeUtf8 <$> BS.readFile path

-- | Markdown emphasis and code spans dropped, whitespace squeezed out.
--
-- Two reasons, both learned from "DocContradictionSpec": a needle should
-- not stop matching because someone bolded half of it, and the batch
-- table writes its codes as @`PM_SHAPE_SQUARE`(0)@ -- backtick, then the
-- value outside the span -- so the name and its number are only adjacent
-- once the punctuation is gone.
--
-- Underscore is deliberately NOT in the set even though markdown treats it
-- as emphasis: every name this spec looks for is a C identifier full of
-- them, and stripping it turns @PM_BLEND_ALPHA@ into a needle that can
-- never match. Measured, not guessed -- it is what the first run of this
-- spec failed on.
normalize :: String -> String
normalize = filter (`notElem` (" \t*`" :: String))

-- | Blank-line separated blocks. Table rows are their own paragraph only
-- when blank lines separate them, which is what we want: a table is one
-- block and a prose paragraph is another, so a claim and its tolerance
-- have to sit together to count.
paragraphsOf :: String -> [String]
paragraphsOf = go . lines
  where
    go [] = []
    go ls =
      let (block, rest) = break (all (== ' ')) (dropWhile (all (== ' ')) ls)
       in if null block then go' rest else unlines block : go' rest
    go' rest = if null rest then [] else go rest

-- | A markdown section: the heading line and everything up to the next
-- heading of the same depth or shallower.
mdSection :: String -> String -> String
mdSection marker doc =
  case dropWhile (not . (marker `isPrefixOf`)) (lines doc) of
    [] -> ""
    (h : rest) -> unlines (h : takeWhile (not . isHeading) rest)
  where
    depth = length (takeWhile (== '#') marker)
    isHeading l =
      let hashes = length (takeWhile (== '#') l)
       in hashes > 0 && hashes <= depth && " " `isPrefixOf` drop hashes l
