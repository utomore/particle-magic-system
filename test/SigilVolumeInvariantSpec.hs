-- | T4 (magic-semantics F002): the two things this round promised not to
-- move.
--
--   * __The digest.__ 'Magic.Sigil.hashCircle' decides what a circle
--     /looks like as a flat figure/, and ADR-0014 D3 froze it: F002
--     changes how much space a circle occupies, not that figure, so
--     'circleVolume' rides alongside the fold exactly as 'circleFields'
--     and 'Magic.Circle.circleSigil' do — carried, never folded.
--
--   * __Zero ripple.__ Every circle written before this round has
--     @circleVolume = Nothing@, and 'Nothing' is the /only/ way to reach
--     @stackDepth == 1@ ('Just' 'Magic.Circle.SigilVolume' always derives
--     a depth of at least 2) — so the zero-ripple law can only be, and
--     only needs to be, proved for the 'Nothing' branch. It is proved
--     structurally rather than by re-recording a golden: every shipped
--     example's formation stroke and shape emitters sit at the plain
--     origin anchor with their plan's own untouched particle count,
--     which is exactly what the pre-F002 'formationEmittersFor' produced
--     for every one of them.
module SigilVolumeInvariantSpec (spec) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import qualified Data.Vector as V
import Data.Maybe (isJust)
import Magic.Circle (Circle (..), SigilVolume (..), emptyCircle)
import Magic.Codec (loadCircle)
import Magic.Compile
  ( Anchor (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , Motion (..)
  , Phase (..)
  , SpawnPattern (..)
  , compile
  )
import Magic.Sigil (SigilPlan (..), SigilStroke (..), hashCircle, sigilPlan)
import Magic.Types (V3 (..))
import SigilGen (genAnyCircle)
import System.Directory (listDirectory)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

spellDir :: FilePath
spellDir = "assets/spells"

-- | Timings/... no, volumes: the two values a circle-level property this
-- shape can take, chosen to reach both a digest could conceivably notice.
volumes :: [Maybe SigilVolume]
volumes = [Nothing, Just SigilVolume]

circleFile :: String -> IO Circle
circleFile name = do
  bytes <- BS.readFile (spellDir ++ "/" ++ name ++ ".json")
  either (fail . show) pure (loadCircle bytes)

-- | Every shipped example whose circle has @circlePhases@, and therefore
-- formation emitters for this round to have disturbed.
phasedExamples :: IO [String]
phasedExamples = do
  entries <- listDirectory spellDir
  let names = sort [take (length e - 5) e | e <- entries, ".json" `isSuffixOf` e]
  circles <- mapM circleFile names
  pure [n | (n, c) <- zip names circles, isJust (circlePhases c)]

-- | Only the examples whose @circleVolume@ is actually 'Nothing' — every
-- shipped spell except this round's own 'stacked-sigil.json'. The
-- zero-ripple law is a statement about /this/ population; 'stacked-sigil'
-- is F002's own witness that the other branch does something, not a
-- counterexample to this one.
flatPhasedExamples :: IO [String]
flatPhasedExamples = do
  names <- phasedExamples
  circles <- mapM circleFile names
  pure [n | (n, c) <- zip names circles, circleVolume c == Nothing]

compiledOf :: Circle -> CompiledSpell
compiledOf = either (error . show) id . compile

formationEmitters :: CompiledSpell -> [EmitterSpec]
formationEmitters spell = [em | em <- V.toList (spellEmitters spell), emPhase em /= Casting]

strokeGroup :: CompiledSpell -> SigilStroke -> [EmitterSpec]
strokeGroup spell sk =
  [em | em <- formationEmitters spell, motSpawn (emMotion em) == SpawnOnStroke sk]

shapeGroup :: CompiledSpell -> (FaceShapeKey) -> [EmitterSpec]
shapeGroup spell key =
  [em | em <- formationEmitters spell, sameShape (motSpawn (emMotion em))]
  where
    sameShape (SpawnOnShape s) = shapeKeyOf s == key
    sameShape _ = False

-- | 'Magic.Rune.FaceShape' has no 'Ord', and we only need to tell shapes
-- apart, not sort them — so this is 'show', not a real key. Two distinct
-- shapes in one plan always render distinct strings (constructor names
-- alone differ, or the fields do), which is all a lookup here needs.
type FaceShapeKey = String

shapeKeyOf :: (Show a) => a -> FaceShapeKey
shapeKeyOf = show

spec :: Spec
spec = describe "what magic-semantics F002 promised not to move (T4)" $ do
  describe "the digest is untouched (ADR-0014 D3)" $ do
    it "hashCircle ignores circleVolume, on the empty circle" $
      mapM_
        (\v -> hashCircle (emptyCircle {circleVolume = v}) `shouldBe` hashCircle emptyCircle)
        volumes

    it "and on every shipped example" $ do
      entries <- listDirectory spellDir
      let names = sort [take (length e - 5) e | e <- entries, ".json" `isSuffixOf` e]
      names `shouldSatisfy` ((>= 17) . length)
      mapM_
        ( \name -> do
            c <- circleFile name
            mapM_
              ( \v ->
                  (name, hashCircle (c {circleVolume = v}))
                    `shouldBe` (name, hashCircle (c {circleVolume = Nothing}))
              )
              volumes
        )
        names

    prop "...and on any circle at all" $
      forAll genAnyCircle $ \c ->
        conjoin
          [hashCircle (c {circleVolume = v}) === hashCircle c | v <- volumes]

  describe "zero ripple: circleVolume = Nothing is the only depth-1 path" $ do
    it "every flat shipped example's strokes sit at the plain origin anchor" $ do
      names <- flatPhasedExamples
      -- 9 shipped examples carry a real "phases" key; stacked-sigil.json
      -- is the tenth but is excluded (its circleVolume is Just), leaving
      -- 8 for the zero-ripple law to be stated over.
      names `shouldSatisfy` ((>= 8) . length)
      mapM_
        ( \name -> do
            c <- circleFile name
            let spell = compiledOf c
                plan = sigilPlan c
            mapM_
              ( \sk -> case strokeGroup spell sk of
                  [em] -> do
                    (name, anchorOffset (emAnchor em)) `shouldBe` (name, V3 0 0 0)
                    (name, anchorNormal (emAnchor em)) `shouldBe` (name, V3 0 0 1)
                    (name, emCount em) `shouldBe` (name, skCount sk)
                  other ->
                    expectationFailure
                      (name ++ ": expected exactly one emitter per stroke, got " ++ show (length other))
              )
              (V.toList (spStrokes plan))
        )
        names

    it "and its shape previews too, when it has any" $ do
      names <- flatPhasedExamples
      mapM_
        ( \name -> do
            c <- circleFile name
            let spell = compiledOf c
                plan = sigilPlan c
            mapM_
              ( \(shape, cnt) -> case shapeGroup spell (shapeKeyOf shape) of
                  [em] -> do
                    (name, anchorOffset (emAnchor em)) `shouldBe` (name, V3 0 0 0)
                    (name, emCount em) `shouldBe` (name, cnt)
                  other ->
                    expectationFailure
                      (name ++ ": expected exactly one emitter per shape, got " ++ show (length other))
              )
              (V.toList (spShapes plan))
        )
        names

    prop "and holds for any circle at all, not only the shipped ones" $
      forAll genAnyCircle $ \c ->
        let spell = compiledOf c
            plan = sigilPlan c
            -- 'Magic.Sigil.sigilPlan' is a pure function of the circle's
            -- structure alone — it hands back a plan whether or not
            -- 'circlePhases' is set. 'Magic.Compile.compile' only turns
            -- that plan into formation emitters when @circlePhases@ is
            -- 'Just' (spec 0006's "no phases, no formation geometry"), so
            -- the expected group size for a stroke is 1 with phases and 0
            -- without — never vacuously true either way.
            expectedGroupSize = if isJust (circlePhases c) then 1 else 0
            checkStroke sk = counterexample ("stroke " ++ show sk) $ case strokeGroup spell sk of
              [] | expectedGroupSize == 0 -> property True
              [em]
                | expectedGroupSize == 1 ->
                    conjoin
                      [ anchorOffset (emAnchor em) === V3 0 0 0
                      , anchorNormal (emAnchor em) === V3 0 0 1
                      , emCount em === skCount sk
                      ]
              other ->
                counterexample
                  ( "expected "
                      ++ show expectedGroupSize
                      ++ " emitter(s), got "
                      ++ show (length other)
                  )
                  (property False)
         in conjoin (map checkStroke (V.toList (spStrokes plan)))

  describe "the golden net still covers the population this law is over" $
    it "every flat phased example has a golden, so the zero-ripple claim is not vacuous" $ do
      names <- flatPhasedExamples
      goldens <- listDirectory "test/golden/perf-0010"
      let netted = sort [take (length g - 4) g | g <- goldens, ".txt" `isSuffixOf` g]
      [n | n <- names, n `notElem` netted] `shouldBe` []
