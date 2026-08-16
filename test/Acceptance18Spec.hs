-- | S6 (func-spec 0018 §7): the acceptance run for the scene-on-C-ABI
-- round — the /scene equivalence law/.
--
-- Func-spec 0009 stated the single-spell version of this as ADR-0011 D8
-- and made it a fact in "Acceptance9Spec": for the same inputs, the C
-- path and the 'Magic.Interface' path produce bit-identical output. This
-- spec states the scene version, and it needs a stronger generator,
-- because a scene has /history/: a cast may be refused, a dismissal may
-- name a stale id, and a finished spell releases quota. Order matters
-- here in a way it never did for one spell.
--
-- So the law is checked over generated interleavings of the four
-- operations, on a scene whose cap is deliberately tight enough that
-- quota refusals actually happen, with every step compared on all four
-- observables at once: the six columns, the batch descriptors, the
-- admission verdict, and the quota ledger. If the FFI shell ever knew
-- one thing the pure layer does not — a cast it admitted differently, a
-- batch it re-ordered, a quota it kept its own count of — one of those
-- four disagrees on the step it happened.
module Acceptance18Spec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import FFIHarness (spellBytes, testCtx)
import FFISceneCastSpec (mismatch)
import FFISceneSpec
  ( CastOutcome (..)
  , exampleBudget
  , sceneBudgetOf
  , sceneCast
  , sceneCastMany
  , sceneIds
  , sceneObserve
  , withSceneHandle
  )
import Foreign.C.Types (CFloat (..), CInt)
import Foreign.StablePtr (StablePtr)
import GHC.Float (float2Double)
import Magic.Codec (loadCircle)
import Magic.FFI
  ( SceneCell
  , pm_scene_advance
  , pm_scene_count
  , pm_scene_dismiss
  , pmErrBudget
  , pmErrJson
  , pmErrQuota
  , pmOk
  )
import Magic.Interface
  ( CastRequest (..)
  , Circle
  , DeltaTime (..)
  , FrameInput (..)
  )
import Magic.Scene
  ( CastRefusal (..)
  , Scene
  , SceneConfig (..)
  , SpellId (..)
  , advanceScene
  , castInto
  , castManyInto
  , dismiss
  , newScene
  , sceneBudget
  , sceneSpells
  )
import Test.Hspec
import Test.QuickCheck

-- | The material: shipped examples, plus one circle that decodes and then
-- fails to compile, so 'CompileFailed' is in the generated mix alongside
-- 'QuotaExceeded'.
fixtureNames :: [String]
fixtureNames = ["ring-fire", "spiral-spark", "pulse-ring", "empty", "square-burst"]

overBudget :: BS.ByteString
overBudget =
  BS8.pack
    "{ \"version\": 1, \"circle\": { \"core\": { \"center\": { \"element\": \"fire\", \"power\": 80.0 } } } }"

-- | One host call.
data Op
  = Cast Int
  | CastMany [Int]
  | Dismiss Int
  | Advance Float
  deriving (Eq, Show)

-- | Mostly frames, with casts and dismissals sprinkled through — the
-- shape a real host produces, and the shape that makes quota release
-- observable (a spell has to be allowed to end).
instance Arbitrary Op where
  arbitrary =
    frequency
      [ (3, Cast <$> choose (0, 5))
      , (1, CastMany <$> resize 3 (listOf (choose (0, 4))))
      , (2, Dismiss <$> choose (-1, 6))
      , (10, Advance <$> elements [1 / 60, 1 / 30, 0.008, 0.05, 0.25])
      ]
  shrink (CastMany is) = map CastMany (shrink is)
  shrink _ = []

spec :: Spec
spec = describe "scene equivalence across the C ABI (func-spec 0018 §7 S6)" $ do
  fixtures <- runIO loadFixtures
  -- Room for two of the first example and no more: tight enough that the
  -- generated histories hit the quota constantly, wide enough that a
  -- second spell can still get in once the first ends.
  let ringFire = fixtures !! 0
      cap = 2 * exampleBudget ringFire

  it "matches the Haskell path step for step, over generated histories" $
    withNumTests 50 $
      forAll (vectorOf 120 arbitrary) $ \ops ->
        ioProperty (asProperty <$> runBoth fixtures cap ops)

  it "matches over a hand-built history that exercises every branch" $ do
    -- Not a substitute for the property: this one is here so the four
    -- interesting events are known to occur, rather than merely likely.
    let ops =
          [ Cast 0 -- admitted
          , Cast 0 -- admitted, filling the cap
          , Cast 1 -- refused: no quota left
          , Cast 5 -- refused: does not compile at all
          , Dismiss 0 -- the first one goes early
          , Cast 1 -- now there is room again
          , CastMany [2, 3] -- a composition under the same quota
          , Dismiss 99 -- a stale id: no-op
          ]
            ++ replicate 100 (Advance 0.05) -- ... and everything ends
    result <- runBoth fixtures cap ops
    result `shouldBe` Right ()

  it "is not vacuous: the history really refuses, releases and empties" $
    withSceneHandle cap $ \sc -> do
      a <- sceneCast sc ringFire testCtx
      b <- sceneCast sc ringFire testCtx
      refused <- sceneCast sc (fixtures !! 1) testCtx
      map coCode [a, b] `shouldBe` [pmOk, pmOk]
      coCode refused `shouldBe` pmErrQuota
      compileFail <- sceneCast sc (fixtures !! 5) testCtx
      coCode compileFail `shouldBe` pmErrBudget
      mapM_ (\_ -> pm_scene_advance sc (CFloat 0.25)) [1 :: Int .. 200]
      pm_scene_count sc `shouldReturn` 0
      reopened <- sceneCast sc (fixtures !! 1) testCtx
      coCode reopened `shouldBe` pmOk

  it "replays: the same history twice gives the same answer" $ do
    let ops = [Cast 0, Advance 0.1, Cast 1, Advance 0.05, Dismiss 0, Advance 0.2]
        cap' = 4 * exampleBudget ringFire
    first <- traceOf fixtures cap' ops
    second <- traceOf fixtures cap' ops
    first `shouldBe` second

-- Running both paths ----------------------------------------------------------

-- | A divergence becomes a QuickCheck counterexample carrying the step
-- that caused it, rather than an exception with no history attached.
asProperty :: Either String () -> Property
asProperty = either (\why -> counterexample why False) (const (property True))

loadFixtures :: IO [BS.ByteString]
loadFixtures = do
  shipped <- traverse spellBytes fixtureNames
  pure (shipped ++ [overBudget])

-- | Apply @ops@ to a C scene and to a 'Scene' at the same time, comparing
-- everything observable after every single step. @Right ()@ means the two
-- never diverged.
runBoth :: [BS.ByteString] -> Int -> [Op] -> IO (Either String ())
runBoth fixtures cap ops =
  withSceneHandle cap $ \sc -> go sc (newScene (SceneConfig cap)) (zip [0 :: Int ..] ops)
  where
    go _ _ [] = pure (Right ())
    go sc scene ((i, op) : rest) = do
      stepped <- step fixtures sc scene op
      case stepped of
        Left why -> pure (Left ("step " ++ show i ++ " (" ++ show op ++ "): " ++ why))
        Right scene' -> do
          agreed <- agree sc scene'
          case agreed of
            Left why -> pure (Left ("after step " ++ show i ++ " (" ++ show op ++ "): " ++ why))
            Right () -> go sc scene' rest

-- | One operation on both sides, with the /verdict/ compared where the
-- operation has one.
step :: [BS.ByteString] -> StablePtr SceneCell -> Scene -> Op -> IO (Either String Scene)
step fixtures sc scene op = case op of
  Advance dt -> do
    pm_scene_advance sc (CFloat dt)
    pure (Right (advanceScene (FrameInput (DeltaTime (float2Double dt))) scene))
  Dismiss sid -> do
    pm_scene_dismiss sc (fromIntegral sid)
    pure (Right (dismiss (SpellId sid) scene))
  Cast i -> do
    let bytes = fixtures !! i
    outcome <- sceneCast sc bytes testCtx
    case circleOf' bytes of
      Nothing -> pure (verdictJson outcome scene)
      Just circle ->
        pure (verdict outcome scene (castInto CastRequest {circleOf = circle, ctxOf = testCtx} scene))
  CastMany is -> do
    let chunks = map (fixtures !!) is
    outcome <- sceneCastMany sc chunks testCtx
    case traverse circleOf' chunks of
      Nothing -> pure (verdictJson outcome scene)
      Just circles -> pure (verdict outcome scene (castManyInto circles testCtx scene))

-- | The admission verdicts have to agree in /classification/, and on the
-- happy path in the id as well.
verdict
  :: CastOutcome
  -> Scene
  -> Either CastRefusal (SpellId, Scene)
  -> Either String Scene
verdict outcome scene reference = case reference of
  Right (SpellId sid, scene')
    | coCode outcome /= pmOk -> Left ("admitted in Haskell, " ++ show (coCode outcome) ++ " in C")
    | coId outcome /= fromIntegral sid -> Left ("id " ++ show (coId outcome) ++ " vs " ++ show sid)
    | otherwise -> Right scene'
  Left refusal
    | coCode outcome /= expected -> Left (show refusal ++ " became " ++ show (coCode outcome))
    -- A refusal must leave the caller's own scene, unchanged.
    | otherwise -> Right scene
    where
      expected = case refusal of
        CompileFailed _ -> pmErrBudget
        QuotaExceeded _ _ -> pmErrQuota

verdictJson :: CastOutcome -> Scene -> Either String Scene
verdictJson outcome scene
  | coCode outcome /= pmErrJson = Left ("bad JSON became " ++ show (coCode outcome))
  | otherwise = Right scene

circleOf' :: BS.ByteString -> Maybe Circle
circleOf' = either (const Nothing) Just . loadCircle

-- | The four observables, after a step.
agree :: StablePtr SceneCell -> Scene -> IO (Either String ())
agree sc scene = do
  n <- pm_scene_count sc
  let ids = sceneSpells scene
      (used, cap) = sceneBudget scene
  (_, listed) <- sceneIds sc (length ids)
  budget <- sceneBudgetOf sc
  obs <- sceneObserve sc (max 1 (abs cap)) 64
  pure $
    check
      [ ("count", fromIntegral n /= length ids, show n ++ " vs " ++ show (length ids))
      ,
        ( "spells"
        , take (length ids) listed /= [fromIntegral s | SpellId s <- ids]
        , show (take (length ids) listed) ++ " vs " ++ show ids
        )
      ,
        ( "budget"
        , budget /= (pmOk, fromIntegral used, fromIntegral cap)
        , show budget ++ " vs " ++ show (used, cap)
        )
      ]
      (mismatch obs scene)

check :: [(String, Bool, String)] -> Maybe String -> Either String ()
check cs observed =
  case [what ++ ": " ++ detail | (what, differs, detail) <- cs, differs] of
    (why : _) -> Left why
    [] -> maybe (Right ()) Left observed

-- | The whole run reduced to a comparable trace, for the replay check.
traceOf :: [BS.ByteString] -> Int -> [Op] -> IO [(CInt, [CInt], (CInt, CInt, CInt))]
traceOf fixtures cap ops =
  withSceneHandle cap $ \sc ->
    traverse (\op -> apply sc op >> snapshot sc) ops
  where
    apply sc op = case op of
      Advance dt -> pm_scene_advance sc (CFloat dt)
      Dismiss sid -> pm_scene_dismiss sc (fromIntegral sid)
      Cast i -> () <$ sceneCast sc (fixtures !! i) testCtx
      CastMany is -> () <$ sceneCastMany sc (map (fixtures !!) is) testCtx
    snapshot sc = do
      n <- pm_scene_count sc
      (_, ids) <- sceneIds sc (fromIntegral n)
      budget <- sceneBudgetOf sc
      pure (n, take (fromIntegral n) ids, budget)
