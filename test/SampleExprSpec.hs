-- | T-S3 (func-spec 0004 §8): the sampler's Expr wiring — the layered
-- time frame of §4.4 and the three modulation insertion points plus the
-- formula trajectory of §4.5.
--
-- The centerpiece is the t-is-age mechanical proof: two births at
-- different cast times but the same age produce the same formula
-- displacement, pinned by comparing whole buffers one lifetime apart.
module SampleExprSpec (spec) where

import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import ExprGen (genExpr)
import Magic.Circle (Circle (..), TwoOf (..), emptyCircle)
import Magic.Compile
  ( Appearance (..)
  , CompiledSpell (..)
  , EmitterSpec (..)
  , compile
  )
import Magic.Expr
  ( BinOp (..)
  , Expr (..)
  , ExprEnv (..)
  , ExprV3 (..)
  , Fun1 (..)
  , Var (..)
  , evalFinite
  , evalFiniteV3
  )
import Magic.Particle.Analytic (particleAge, sample, sampleShape)
import Magic.Particle.Buffer (ParticleBuffer (..))
import Magic.Rune
  ( BridgeRune (..)
  , FaceShape (..)
  , InnerRune (..)
  , OuterRune (..)
  , RadiationMode (..)
  )
import Magic.Types
  ( CastContext (..)
  , Seed (..)
  , Time (..)
  , V2 (..)
  , V3 (..)
  , basisFromNormal
  , dot
  , normalize
  , vscale
  )
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (sample)

ctx :: CastContext
ctx = CastContext {casterPos = V3 0 0 0, casterFacing = V3 0 1 0, seed = Seed 7}

compiled :: Circle -> CompiledSpell
compiled c = either (error . show) id (compile c)

-- | The world-space face basis this test context produces (anchor at the
-- caster, face normal = facing; same derivation as the sampler).
faceFrame :: (V3, V3, V3)
faceFrame =
  let n = normalize (casterFacing ctx)
      (u, w) = basisFromNormal n
   in (u, w, n)

positionAt :: ParticleBuffer -> Int -> V3
positionAt buf j = V3 (pbPosX buf U.! j) (pbPosY buf U.! j) (pbPosZ buf U.! j)

-- | Indices of alive particles at @t@ (the sampler packs them in index
-- order), each with its age.
aliveAt :: CompiledSpell -> Time -> [(Int, Double)]
aliveAt spell t =
  let em = V.head (spellEmitters spell)
   in [ (i, age)
      | i <- [0 .. emCount em - 1]
      , Just age <- [particleAge (emSpawn em) (emCount em) i t]
      ]

closeTo :: Float -> Float -> Bool
closeTo a b = abs (a - b) <= 1e-3 * max 1 (abs b)

v3Close :: V3 -> V3 -> Bool
v3Close (V3 ax ay az) (V3 bx by bz) = closeTo ax bx && closeTo ay by && closeTo az bz

-- Circles ---------------------------------------------------------------------

ringShape :: FaceShape
ringShape = Ring 1 2

formulaCircle :: ExprV3 -> Circle
formulaCircle v3 =
  emptyCircle
    { outerRings = TwoOf (Just (ShapeRune ringShape)) Nothing
    , innerRings = TwoOf (Just (FormulaRune v3)) Nothing
    }

lissajous :: ExprV3
lissajous =
  ExprV3
    (Bin Mul (Fun1 FSin (Bin Mul (Var VarT) (Lit 3))) (Lit 0.6))
    (Bin Mul (Fun1 FSin (Bin Mul (Var VarT) (Lit 2))) (Lit 0.6))
    (Bin Mul (Var VarT) (Lit 2))

spec :: Spec
spec = describe "sampler Expr wiring (spec 0004 S3)" $ do
  describe "formula trajectory (§4.5 point 4)" $ do
    it "positions == spawn + evalFiniteV3 assembled in the travel frame (judgment)" $
      formulaPositionsMatch lissajous (Time 1.3)

    prop "positions == hand assembly for arbitrary formulas and times" $
      forAll ((,) <$> genV3 <*> choose (0.05, 5.9)) $ \(v3, t) ->
        formulaPositionsMatchP v3 (Time t)

    it "t = age, mechanically: buffers one lifetime apart are identical" $ do
      -- Every alive particle at 2.5s is alive at 4.5s one respawn later,
      -- with the same age. Since the formula reads t = age (not cast
      -- time), the whole buffers match bit for bit; sin(t·3) at cast
      -- times 2.5 vs 4.5 would differ wildly.
      let spell = compiled (formulaCircle lissajous)
      sample spell ctx (Time 2.5) `shouldBe` sample spell ctx (Time 4.5)
      -- Sanity: the spell is actually emitting at both instants.
      pbCount (sample spell ctx (Time 2.5)) `shouldSatisfy` (> 0)

    it "formula under RadialOutward travels along each particle's own ray" $ do
      let v3 = ExprV3 (Lit 0) (Lit 0) (Bin Mul (Var VarT) (Lit 2))
          c =
            (formulaCircle v3)
              { outerRings =
                  TwoOf (Just (ShapeRune ringShape)) (Just (RadiateRune RadialOutward))
              }
          spell = compiled c
          t = Time 1.1
          buf = sample spell ctx t
          (u, w, _) = faceFrame
          expected (i, age) =
            let V2 sx sy = sampleShape ringShape i 0
                spawnW = casterPos ctx + vscale sx u + vscale sy w
                axis = normalize (vscale sx u + vscale sy w)
                ageF = realToFrac age :: Float
             in spawnW + vscale (2 * ageF) axis
      pbCount buf `shouldSatisfy` (> 0)
      sequence_
        [ positionAt buf j `shouldSatisfy` v3Close (expected ia)
        | (j, ia) <- zip [0 ..] (aliveAt spell t)
        ]

  describe "converge (§4.5 point 2)" $ do
    it "Lit 0 pins particles to the travel axis (lateral component ~ 0)" $ do
      let c =
            emptyCircle
              { outerRings = TwoOf (Just (ShapeRune ringShape)) Nothing
              , interLayer = Just (ConvergeRune (Lit 0))
              }
          spell = compiled c
          buf = sample spell ctx (Time 1.2)
          (u, w, _) = faceFrame
      pbCount buf `shouldSatisfy` (> 0)
      sequence_
        [ do
            let rel = positionAt buf j - casterPos ctx
            abs (dot rel u) `shouldSatisfy` (< 1e-3)
            abs (dot rel w) `shouldSatisfy` (< 1e-3)
        | j <- [0 .. pbCount buf - 1]
        ]

    it "Lit 1 is bit-for-bit the unmodulated spell" $ do
      let base =
            emptyCircle {outerRings = TwoOf (Just (ShapeRune ringShape)) Nothing}
          modded = base {interLayer = Just (ConvergeRune (Lit 1))}
      sample (compiled modded) ctx (Time 1.2)
        `shouldBe` sample (compiled base) ctx (Time 1.2)

    it "reads whole-spell time: k = t/4 spreads with cast time, not age" $ do
      -- At cast time t the lateral offset is scaled by exactly t/4 for
      -- every particle regardless of its age — only a cast-time env does
      -- that.
      let c =
            emptyCircle
              { outerRings = TwoOf (Just (ShapeRune ringShape)) Nothing
              , interLayer = Just (ConvergeRune (Bin Div (Var VarT) (Lit 4)))
              }
          spell = compiled c
          t = 1.6 :: Double
          buf = sample spell ctx (Time t)
          (u, w, _) = faceFrame
          kc = realToFrac t / 4 :: Float
          expected (i, _age) =
            let V2 sx sy = sampleShape ringShape i 0
             in (kc * sx, kc * sy)
      sequence_
        [ do
            let rel = positionAt buf j - casterPos ctx
                (ex, ey) = expected ia
            dot rel u `shouldSatisfy` closeTo ex
            dot rel w `shouldSatisfy` closeTo ey
        | (j, ia) <- zip [0 ..] (aliveAt spell (Time t))
        ]

  describe "amplify (§4.5 point 3)" $ do
    it "sizes == appSize × max 0 k, negative curves clamp to 0" $ do
      let sized k =
            emptyCircle {interLayer = Just (AmplifyRune k)}
          sizesWith k = U.toList (pbSize (sample (compiled (sized k)) ctx (Time 1)))
      sizesWith (Lit 2) `shouldSatisfy` all (== 0.05 * 2)
      sizesWith (Neg (Lit 1)) `shouldSatisfy` all (== 0)

    it "reads whole-spell time: 1 + sin(t·3)·0.5 at the cast clock" $ do
      let curve =
            Bin
              Add
              (Lit 1)
              (Bin Mul (Fun1 FSin (Bin Mul (Var VarT) (Lit 3))) (Lit 0.5))
          c = emptyCircle {interLayer = Just (AmplifyRune curve)}
          spell = compiled c
          t = 2.2 :: Double
          buf = sample spell ctx (Time t)
          em = V.head (spellEmitters spell)
          -- The curve only reads t, so one env stands for every particle.
          env = ExprEnv {envT = realToFrac t, envLife = 0, envPIndex = 0, envSeed = seed ctx}
          expected = appSize (emAppearance em) * max 0 (evalFinite curve env)
      pbCount buf `shouldSatisfy` (> 0)
      U.toList (pbSize buf) `shouldSatisfy` all (== expected)

  describe "range (§4.5 point 1)" $ do
    it "Lit 2 doubles the ring's spawn radii" $ do
      let c =
            emptyCircle
              { outerRings =
                  TwoOf (Just (ShapeRune ringShape)) (Just (RangeRune (Lit 2)))
              }
          buf = sample (compiled c) ctx (Time 1)
          (u, w, _) = faceFrame
          radii =
            [ sqrt (sx * sx + sy * sy)
            | j <- [0 .. pbCount buf - 1]
            , let rel = positionAt buf j - casterPos ctx
                  sx = dot rel u
                  sy = dot rel w
            ]
      pbCount buf `shouldSatisfy` (> 0)
      radii `shouldSatisfy` all (\r -> r >= 2 - 1e-3 && r <= 4 + 1e-3)

    it "t = birth time, frozen: the spawn offset never drifts after birth" $ do
      -- range = t: the scale is the particle's birth time. Between two
      -- frames of the same generation the face-plane offset must not
      -- move (the default Forward trajectory travels along the normal).
      let c =
            emptyCircle
              { outerRings =
                  TwoOf (Just (ShapeRune ringShape)) (Just (RangeRune (Var VarT)))
              }
          spell = compiled c
          t1 = Time 1.0
          t2 = Time 1.4
          buf1 = sample spell ctx t1
          buf2 = sample spell ctx t2
          (u, w, _) = faceFrame
          slotOf t = zip (map fst (aliveAt spell t)) [0 ..]
          proj buf j =
            let rel = positionAt buf j - casterPos ctx
             in (dot rel u, dot rel w)
      sequence_
        [ do
            let (x1, y1) = proj buf1 j1
                (x2, y2) = proj buf2 j2
            x2 `shouldSatisfy` closeTo x1
            y2 `shouldSatisfy` closeTo y1
        | (i, j1) <- slotOf t1
        , Just j2 <- [lookup i (slotOf t2)]
        ]
      -- And the scale really is the birth time: radii vary across
      -- particles instead of sitting in the unscaled [1, 2] band.
      let radii1 = [sqrt (x * x + y * y) | (_, j) <- slotOf t1, let (x, y) = proj buf1 j]
      radii1 `shouldSatisfy` any (\r -> r < 1 - 1e-3 || r > 2 + 1e-3)

  prop "determinism: same (Circle, CastContext, t) twice is bit-for-bit equal" $
    forAll (choose (0 :: Double, 9)) $ \t ->
      let c =
            (formulaCircle lissajous)
              { interLayer = Just (AmplifyRune (Bin Add (Lit 1) (Var VarLife)))
              }
          spell = compiled c
       in sample spell ctx (Time t) == sample spell ctx (Time t)

-- Hand assembly of the formula path (AlongNormal) ------------------------------

genV3 :: Gen ExprV3
genV3 =
  let g = genExpr 12
   in ExprV3 <$> g <*> g <*> g

formulaPositionsMatch :: ExprV3 -> Time -> Expectation
formulaPositionsMatch v3 t = do
  let (buf, pairs) = formulaActualExpected v3 t
  pbCount buf `shouldSatisfy` (> 0)
  length pairs `shouldBe` pbCount buf
  sequence_ [got `shouldSatisfy` v3Close expect | (got, expect) <- pairs]

formulaPositionsMatchP :: ExprV3 -> Time -> Property
formulaPositionsMatchP v3 t =
  let (buf, pairs) = formulaActualExpected v3 t
   in counterexample (show (pbCount buf, take 3 pairs)) $
        length pairs == pbCount buf && all (uncurry (flip v3Close)) pairs

-- | Sample the formula circle and pair every packed particle position
-- with the §4.5 hand assembly: spawn point on the (unscaled) ring +
-- x·b_x + y·b_y + z·d evaluated at t = age with life = age/lifetime.
formulaActualExpected :: ExprV3 -> Time -> (ParticleBuffer, [(V3, V3)])
formulaActualExpected v3 t =
  let circle = formulaCircle v3
      spell = compiled circle
      buf = sample spell ctx t
      (u, w, n) = faceFrame
      (au, aw) = basisFromNormal n
      expected (i, age) =
        let V2 sx sy = sampleShape ringShape i 0
            spawnW = casterPos ctx + vscale sx u + vscale sy w
            ageF = realToFrac age :: Float
            env =
              ExprEnv
                { envT = ageF
                , -- Mirrors the sampler: life computed in Double, then
                  -- narrowed (the default 2s particle lifetime).
                  envLife = realToFrac (age / 2)
                , envPIndex = i
                , envSeed = seed ctx
                }
            V3 fx fy fz = evalFiniteV3 v3 env
         in spawnW + vscale fx au + vscale fy aw + vscale fz n
      pairs =
        [ (positionAt buf j, expected ia)
        | (j, ia) <- zip [0 ..] (aliveAt spell t)
        ]
   in (buf, pairs)
