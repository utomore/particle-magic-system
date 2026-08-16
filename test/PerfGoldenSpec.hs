-- | S1 (func-spec 0010 §7): the regression net every other step of this
-- round is performed inside.
--
-- The whole spec is a rewrite of the hot path that must not move a single
-- bit of output. That claim is only worth something if it is checked
-- against output captured /before/ the rewrite, so this module comes
-- first: it walks every shipped example for 240 frames and compares each
-- frame's particle count and a digest of all six SoA columns against
-- @test\/golden\/perf-0010\/*.txt@, which was generated from the
-- pre-refactor build and committed.
--
-- The digest is FNV-1a over the raw bit patterns of the columns
-- (positions, size, life, color) — one flipped mantissa bit anywhere in
-- any frame changes it. It is implemented here rather than pulled from a
-- package because the test suite's dependency list is part of the
-- architecture's discipline, not a convenience.
--
-- Priming: when a golden file is absent the frames are written out and
-- the example is reported @pending@ instead of passing silently. That is
-- how the baseline was produced (run once on the pre-refactor build, then
-- commit); from then on the files exist and every run is a comparison.
--
-- Scope (func-spec 0019 S2, ADR-0016): the digest is compared only on the
-- platform the goldens were recorded on. Elsewhere the per-frame particle
-- counts — which this file's own golden lines already carry, and which
-- measured identical on Linux — are compared instead. See
-- "GoldenPlatform" for why.
module PerfGoldenSpec (spec) where

import qualified Data.ByteString as BS
import Data.Bits (shiftR, xor, (.&.))
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word64)
import GHC.Float (castFloatToWord32)
import GoldenPlatform (platformScopeNote, referencePlatform)
import Magic.Codec (loadCircle)
import Magic.Interface
  ( ActiveSpell
  , CastContext (..)
  , CastRequest (..)
  , DeltaTime (..)
  , FrameInput (..)
  , FrameOutput (..)
  , ParticleBuffer (..)
  , RenderBatch (..)
  , Seed (..)
  , V3 (..)
  , advanceSpell
  , batches
  , castSpell
  , observeSpell
  )
import Data.List (isSuffixOf, sort)
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import Test.Hspec

-- | Every shipped example, so no spell shape (fieldless, phased, formula
-- trajectory, force field, empty) escapes the net.
examples :: [String]
examples =
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
  , -- Func-spec 0021's own two. Their baselines are necessarily recorded
    -- on the post-0021 build (they did not exist before it), so they are
    -- the net a later round inherits, not evidence about this one — the
    -- twelve above are that.
    "wuxing-seal"
  , "yin-yang"
  ]

-- | 4 seconds at 60 Hz: past the spawn window of every example, so the
-- ramp-up, the steady state and the die-out are all covered.
frameCount :: Int
frameCount = 240

dt :: FrameInput
dt = FrameInput (DeltaTime (1 / 60))

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 2026}

goldenDir :: FilePath
goldenDir = "test/golden/perf-0010"

goldenPath :: String -> FilePath
goldenPath name = goldenDir ++ "/" ++ name ++ ".txt"

spellDir :: FilePath
spellDir = "assets/spells"

spellPath :: String -> FilePath
spellPath name = spellDir ++ "/" ++ name ++ ".json"

-- | Every @*.json@ under 'spellDir', extension stripped, sorted.
shippedSpellNames :: IO [String]
shippedSpellNames = do
  entries <- listDirectory spellDir
  pure (sort [dropExtension e | e <- entries, ".json" `isSuffixOf` e])
  where
    dropExtension e = take (length e - length (".json" :: String)) e

-- | @(particle count, column digest)@ of one observed frame.
type Frame = (Int, Word64)

castOf :: String -> IO ActiveSpell
castOf name = do
  bytes <- BS.readFile (spellPath name)
  circle <- either (fail . show) pure (loadCircle bytes)
  either (fail . show) pure (castSpell (CastRequest circle ctx))

-- | Advance-then-observe, 'frameCount' times — exactly the loop a host
-- runs, and exactly the pair of entry points this spec's §0.1 obliges to
-- stay bit-identical.
walk :: ActiveSpell -> [Frame]
walk spell0 = go frameCount spell0
  where
    go 0 _ = []
    go n s =
      let s' = advanceSpell dt s
       in digestOf (observeSpell s') : go (n - 1 :: Int) s'

digestOf :: FrameOutput -> Frame
digestOf out = (total, fnv1a (concatMap columns buffers))
  where
    buffers = map rbParticles (batches out)
    total = sum (map pbCount buffers)
    columns pb =
      concat
        [ map castFloatToWord32 (U.toList (pbPosX pb))
        , map castFloatToWord32 (U.toList (pbPosY pb))
        , map castFloatToWord32 (U.toList (pbPosZ pb))
        , map castFloatToWord32 (U.toList (pbSize pb))
        , map castFloatToWord32 (U.toList (pbLife pb))
        , U.toList (pbColor pb)
        ]

-- | FNV-1a (64 bit) over the little-endian bytes of each word.
fnv1a :: [Word32] -> Word64
fnv1a = foldl' word 0xcbf29ce484222325
  where
    word h w = foldl' byte h [(w `shiftR` s) .&. 0xFF | s <- [0, 8, 16, 24]]
    byte h b = (h `xor` fromIntegral b) * 0x100000001b3

render :: [Frame] -> String
render frames = unlines [show n ++ " " ++ show h | (n, h) <- frames]

parse :: String -> [Frame]
parse = map frame . lines
  where
    frame line = case words line of
      [n, h] -> (read n, read h)
      _ -> error ("malformed golden line: " ++ show line)

spec :: Spec
spec = describe "pre-refactor golden net (func-spec 0010 §7 S1)" $ do
  mapM_ goldenExample examples

  -- Derived from the asset directory rather than counted by hand
  -- (func-spec 0021): a round that ships a new example must either put it
  -- in the net or say why, instead of quietly leaving it uncovered — which
  -- is how 'soft-bloom' and 'lattice-seal' went three rounds without a
  -- golden. Their baselines were recorded on the pre-0021 build, so the
  -- net they join is a real one.
  it "covers every shipped example spell" $ do
    shipped <- shippedSpellNames
    examples `shouldBe` shipped

goldenExample :: String -> Spec
goldenExample name = it (name ++ " renders the golden frames, " ++ law) $ do
  actual <- walk <$> castOf name
  let path = goldenPath name
  exists <- doesFileExist path
  if not exists
    then
      if referencePlatform
        then do
          createDirectoryIfMissing True goldenDir
          writeFile path (render actual)
          pendingWith ("golden primed at " ++ path ++ " — commit it and re-run")
        else
          -- Priming off the reference platform would bake this machine's
          -- libm into the baseline, and every later Windows run would
          -- read it as a regression.
          expectationFailure
            ("golden missing at " ++ path ++ ", and it may not be primed here: " ++ platformScopeNote)
    else do
      expected <- parse <$> readFile path
      length actual `shouldBe` length expected
      let diffs = [i | (i, a, e) <- zip3 [0 :: Int ..] actual expected, compared a /= compared e]
      case diffs of
        [] -> pure ()
        (i : _) ->
          expectationFailure
            ( name
                ++ ": "
                ++ show (length diffs)
                ++ " frame(s) differ ("
                ++ law
                ++ "), first at "
                ++ show i
                ++ "\n  golden: "
                ++ show (expected !! i)
                ++ "\n  actual: "
                ++ show (actual !! i)
            )
  where
    -- ADR-0016: the digest is the same-platform half of the law, the
    -- particle count the platform-free half.
    compared :: Frame -> Frame
    compared frame@(n, _)
      | referencePlatform = frame
      | otherwise = (n, 0)

    law
      | referencePlatform = "bit for bit"
      | otherwise = "particle counts only, off the reference platform"
