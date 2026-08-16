-- | S2 (func-spec 0016 §7): the stroke vocabulary.
--
-- The headline is the /index order is draw order/ law: on a fixed
-- symmetric arm, the curve parameter is strictly increasing in
-- @i \`div\` symmetry@. That is what turns spec 0002's frozen birth
-- schedule (@envDelay + (i\/n)·envLifetime@) into a sigil that draws
-- itself, with no scheduling machinery added anywhere.
--
-- Then the per-kind obligations: arms are an exact rotation of each
-- other, every sample stays inside 'strokeRadius', a @{n\/k}@ polygram
-- traces exactly the regular @n@-gon's vertices, a glyph covers exactly
-- the segments its mask names, and zero jitter samples bit-for-bit.
module SigilStrokeSpec (spec) where

import Data.Bits (popCount, testBit, (.&.))
import Data.Word (Word16)
import Magic.Sigil
  ( SigilSpin (..)
  , SigilStroke (..)
  , StrokeKind (..)
  , sampleStroke
  , staticSpin
  , strokeParam
  , strokeRadius
  )
import Magic.Types (V2 (..))
import SigilGen (allKindsOf, genSpin, genStroke, genStrokeOfKind)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding ((.&.))

magV2 :: V2 -> Float
magV2 (V2 x y) = sqrt (x * x + y * y)

finiteV2 :: V2 -> Bool
finiteV2 (V2 x y) = ok x && ok y
  where
    ok v = not (isNaN v || isInfinite v)

-- | Indices of one arm, in order.
armIndices :: SigilStroke -> Int -> [Int]
armIndices sk arm = [arm, arm + sym .. skCount sk - 1]
  where
    sym = max 1 (skSymmetry sk)

rotate :: Float -> V2 -> V2
rotate th (V2 x y) = V2 (x * cos th - y * sin th) (x * sin th + y * cos th)

-- | A stroke of the given kind with jitter switched off — the frame every
-- geometric claim is made in (jitter is a wobble on top, bounded by
-- 'strokeRadius' and nothing else).
crisp :: Int -> StrokeKind -> Int -> SigilStroke
crisp sym kind steps =
  SigilStroke
    { skKind = kind
    , skRadius = 1.2
    , skSymmetry = sym
    , skPhase = 0.3
    , skJitter = 0
    , skCount = steps * sym
    , skSpin = staticSpin
    }

spec :: Spec
spec = describe "sigil strokes (func-spec 0016 S2)" $ do
  describe "index order is draw order" $ do
    prop "the curve parameter is strictly increasing along a fixed arm" $
      forAll genStroke $ \sk ->
        let sym = max 1 (skSymmetry sk)
         in conjoin
              [ let params = map (strokeParam sk) (armIndices sk arm)
                 in counterexample (show params) (strictlyIncreasing params)
              | arm <- [0 .. sym - 1]
              ]

    it "holds for every kind at every symmetry order 1..9" $
      sequence_
        [ let sk = crisp sym kind 12
              params = map (strokeParam sk) (armIndices sk arm)
           in strictlyIncreasing params `shouldBe` True
        | sym <- [1 .. 9]
        , kind <- allKindsOf sym
        , arm <- [0 .. sym - 1]
        ]

    it "spans the whole curve: the first sample is at 0 and the last at 1" $
      sequence_
        [ let sk = crisp sym kind 12
              params = map (strokeParam sk) (armIndices sk 0)
           in (head params, last params) `shouldBe` (0, 1)
        | sym <- [1 .. 4]
        , kind <- allKindsOf sym
        ]

  describe "symmetric arms" $
    it "arm k is arm 0 rotated by 2*pi*k/sym (all kinds)" $
      sequence_
        [ let sk = crisp sym kind 9
              th = 2 * pi * fromIntegral arm / fromIntegral sym
              base = map (sampleStroke sk) (armIndices sk 0)
              other = map (sampleStroke sk) (armIndices sk arm)
              turned = map (rotate th) base
           in sequence_
                [ magV2 (a - b) `shouldSatisfy` (< 1e-5)
                | (a, b) <- zip turned other
                ]
        | sym <- [2 .. 6]
        , kind <- allKindsOf sym
        , arm <- [1 .. sym - 1]
        ]

  describe "the conservative radius bound" $ do
    prop "|p| <= strokeRadius for every index of any stroke" $
      forAll genStroke $ \sk ->
        conjoin
          [ let p = sampleStroke sk i
             in counterexample (show (i, p, strokeRadius sk)) $
                  magV2 p <= strokeRadius sk + 1e-6
          | i <- [0 .. skCount sk - 1]
          ]

    prop "every component is finite" $
      forAll genStroke $ \sk ->
        property (all (finiteV2 . sampleStroke sk) [0 .. skCount sk - 1])

  describe "Polygram {n/k}" $ do
    it "traces exactly the regular n-gon's vertices" $
      sequence_
        [ do
            let sk = crisp 1 (Polygram n k) (4 * n + 1)
                pts = map (sampleStroke sk) [0 .. skCount sk - 1]
                -- s = q/n lands on index 4q of the single arm.
                corners = [pts !! (4 * q) | q <- [0 .. n - 1]]
                expected =
                  [ V2
                    (1.2 * cos (0.3 + 2 * pi * fromIntegral t / fromIntegral n))
                    (1.2 * sin (0.3 + 2 * pi * fromIntegral t / fromIntegral n))
                  | t <- [0 .. n - 1 :: Int]
                  ]
            -- n distinct points, each one an n-gon vertex: set equality.
            length (nubBy1e4 corners) `shouldBe` n
            length (matched corners expected) `shouldBe` n
        | n <- [5, 7, 8, 9]
        , k <- [1 .. n - 1]
        ]

    it "a k sharing a factor with n still traces every vertex (fallback to 1)" $
      let n = 8 :: Int
          sk = crisp 1 (Polygram n 4) (4 * n + 1)
          pts = map (sampleStroke sk) [0 .. skCount sk - 1]
          corners = [pts !! (4 * q) | q <- [0 .. n - 1]]
       in length (nubBy1e4 corners) `shouldBe` n

  describe "GlyphBand" $ do
    it "covers exactly the segments its mask names" $
      sequence_
        [ occupiedSegments mask `shouldBe` setBitsOf mask
        | mask <- [0x0001, 0x0A5B, 0x0FFF, 0x0800, 0x0249]
        ]

    it "the number of covered segments is popCount of the mask" $
      sequence_
        [ length (occupiedSegments mask) `shouldBe` popCount (mask .&. 0x0FFF)
        | mask <- [0x0001, 0x0A5B, 0x0FFF, 0x0800, 0x0249]
        ]

    it "an empty mask still draws one segment (total, never blank)" $
      length (occupiedSegments 0x0000) `shouldBe` 1

  describe "reproducibility" $ do
    prop "jitter = 0 samples bit for bit" $
      forAll (chooseInt (1, 6)) $ \sym ->
        forAll (elements (allKindsOf sym)) $ \kind ->
          forAll (genStrokeOfKind sym kind) $ \sk0 ->
            let sk = sk0 {skJitter = 0}
             in map (sampleStroke sk) [0 .. skCount sk - 1]
                  === map (sampleStroke sk) [0 .. skCount sk - 1]

    prop "jitter is deterministic too (same stroke, same points)" $
      forAll genStroke $ \sk ->
        map (sampleStroke sk) [0 .. skCount sk - 1]
          === map (sampleStroke sk) [0 .. skCount sk - 1]

    -- Func-spec 0020 §2.1: the time term multiplies the sample, it does
    -- not change how the sample is taken. So every claim above is stated
    -- about a function 'skSpin' cannot reach — which is exactly why the
    -- six closed forms did not have to be reopened to make the sigil turn.
    prop "sampleStroke ignores skSpin entirely (0016 and 0020 are orthogonal)" $
      forAll genStroke $ \sk ->
        forAll genSpin $ \sp ->
          let points s = map (sampleStroke sk {skSpin = s}) [0 .. skCount sk - 1]
           in points sp === points staticSpin

    prop "so do strokeParam and strokeRadius" $
      forAll genStroke $ \sk ->
        forAll genSpin $ \sp ->
          let spun = sk {skSpin = sp}
           in strokeRadius spun === strokeRadius sk
                .&&. map (strokeParam spun) [0 .. skCount sk - 1]
                  === map (strokeParam sk) [0 .. skCount sk - 1]

    it "jitter actually moves the points off the crisp curve" $
      let plain = crisp 1 (ArcRing 1) 32
          wobbly = plain {skJitter = 0.05}
          ps = map (sampleStroke plain) [0 .. skCount plain - 1]
          qs = map (sampleStroke wobbly) [0 .. skCount wobbly - 1]
       in maximum (zipWith (\a b -> magV2 (a - b)) ps qs) `shouldSatisfy` (> 1e-4)

strictlyIncreasing :: [Float] -> Bool
strictlyIncreasing xs = and (zipWith (<) xs (drop 1 xs))

matched :: [V2] -> [V2] -> [V2]
matched corners expected =
  [c | c <- corners, any (\e -> magV2 (c - e) < 1e-4) expected]

nubBy1e4 :: [V2] -> [V2]
nubBy1e4 = foldl step []
  where
    step acc p
      | any (\q -> magV2 (p - q) < 1e-4) acc = acc
      | otherwise = acc ++ [p]

-- | Which of the 12 lattice segments the glyph's samples actually lie on,
-- recovered from the sampled points by undoing the placement.
occupiedSegments :: Word16 -> [Int]
occupiedSegments mask =
  [ seg
  | seg <- [0 .. 11]
  , any (onSegment seg) locals
  ]
  where
    sk = crisp 1 (GlyphBand mask) 96
    r = skRadius sk
    base = skPhase sk
    h = 0.22 * r
    dir = V2 (cos base) (sin base)
    tanv = V2 (negate (sin base)) (cos base)
    center = V2 (r * cos base) (r * sin base)
    locals =
      [ let d = sampleStroke sk i - center
         in V2 (dotV d tanv / h) (dotV d dir / h)
      | i <- [0 .. skCount sk - 1]
      ]
    dotV (V2 ax ay) (V2 bx by) = ax * bx + ay * by
    -- The 12 candidate segments share endpoints, so a point sitting on
    -- one of them is within zero distance of up to three others. Only an
    -- /interior/ hit counts as covering a segment.
    onSegment seg p = case nearestOn p (segmentOf seg) of
      (dist, t) -> dist < 1e-4 && t > 0.05 && t < 0.95

segmentOf :: Int -> (V2, V2)
segmentOf idx
  | idx < 6 =
      let row = fromIntegral (idx `div` 2) - 1
          left = fromIntegral (idx `mod` 2) - 1
       in (V2 left row, V2 (left + 1) row)
  | otherwise =
      let k = idx - 6
          col = fromIntegral (k `div` 2) - 1
          bottom = fromIntegral (k `mod` 2) - 1
       in (V2 col bottom, V2 col (bottom + 1))

-- | Distance from a point to a segment, and where along it the closest
-- approach lies (0 = start, 1 = end), in the lattice's own coordinates.
nearestOn :: V2 -> (V2, V2) -> (Float, Float)
nearestOn p (a, b) = (magV2 (p - proj), t)
  where
    ab = b - a
    ap = p - a
    denom = dotV ab ab
    t = if denom == 0 then 0 else max 0 (min 1 (dotV ap ab / denom))
    V2 abx aby = ab
    proj = a + V2 (t * abx) (t * aby)
    dotV (V2 ax ay) (V2 bx by) = ax * bx + ay * by

setBitsOf :: Word16 -> [Int]
setBitsOf mask = [b | b <- [0 .. 11], testBit (mask .&. 0x0FFF) b]
