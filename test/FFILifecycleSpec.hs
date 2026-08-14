-- | S1 (func-spec 0009 §8): the handle lifecycle across the C ABI.
--
-- The claim under test is the one the whole spec rests on: a handle is
-- nothing but a cell holding an 'Magic.Interface.ActiveSpell', so every
-- observer reachable from C agrees, bit for bit, with the same observer
-- called on the Haskell side. Everything here goes through real CStrings
-- and Ptrs (see "FFIHarness").
module FFILifecycleSpec (spec) where

import FFIHarness
  ( castCode
  , castOk
  , referenceStates
  , spellBytes
  , testCtx
  )
import Foreign.C.Types (CDouble (..), CFloat (..))
import Foreign.Ptr (nullPtr)
import Foreign.StablePtr (StablePtr, castStablePtrToPtr)
import Magic.FFI
  ( SpellCell
  , isNullSpell
  , nullSpell
  , pm_abi_version
  , pm_advance
  , pm_age
  , pm_free
  , pm_is_finished
  , pmAbiVersion
  , pmOk
  )
import Magic.Interface (Time (..), isFinished, spellAge)
import Test.Hspec

-- | 90 frames at 60Hz plus a few irregular ones — a host's real cadence,
-- and enough accumulated rounding that a sloppy @float@\/@double@ crossing
-- would show up.
steadyFrames :: [Float]
steadyFrames = replicate 90 (1 / 60) ++ [0.033, 0.008, 0.25]

-- | Long enough to outlive any shipped example, so 'pm_is_finished' is
-- observed on both sides of the transition.
jumpFrames :: [Float]
jumpFrames = replicate 40 0.5

spec :: Spec
spec = describe "C ABI handle lifecycle (func-spec 0009 §8 S1)" $ do
  it "reports the ABI version the header was written against" $ do
    v <- pm_abi_version
    v `shouldBe` pmAbiVersion
    v `shouldBe` 1

  it "casts a shipped example into a non-NULL handle" $ do
    bytes <- spellBytes "ring-fire"
    handle <- castOk bytes testCtx
    isNullSpell handle `shouldBe` False
    pm_free handle

  it "pm_cast_ex answers PM_OK on the happy path" $ do
    bytes <- spellBytes "spiral-spark"
    code <- castCode bytes testCtx
    code `shouldBe` pmOk

  it "pm_age tracks spellAge bit for bit over a frame sequence" $ do
    bytes <- spellBytes "ring-fire"
    handle <- castOk bytes testCtx
    ages <- traverse (advanceThen handle pm_age) steadyFrames
    let expected = [t | spell <- referenceStates bytes steadyFrames, let Time t = spellAge spell]
    map (\(CDouble d) -> d) ages `shouldBe` expected
    pm_free handle

  it "pm_is_finished tracks isFinished over the spell's whole life" $ do
    bytes <- spellBytes "ring-fire"
    handle <- castOk bytes testCtx
    flags <- traverse (advanceThen handle pm_is_finished) jumpFrames
    let expected = map isFinished (referenceStates bytes jumpFrames)
    map (/= 0) flags `shouldBe` expected
    -- the sequence must actually cross the boundary, or this proves nothing
    expected `shouldSatisfy` (\fs -> or fs && not (and fs))
    pm_free handle

  it "starts at age 0, and advancing by 0 keeps it there" $ do
    bytes <- spellBytes "empty"
    handle <- castOk bytes testCtx
    CDouble age0 <- pm_age handle
    age0 `shouldBe` 0
    pm_advance handle 0
    CDouble age1 <- pm_age handle
    age1 `shouldBe` 0
    pm_free handle

  it "tolerates the NULL handle on every observer and on free" $ do
    castStablePtrToPtr nullSpell `shouldBe` nullPtr
    pm_advance nullSpell 0.016
    finished <- pm_is_finished nullSpell
    finished `shouldBe` 1
    CDouble age <- pm_age nullSpell
    age `shouldBe` 0
    pm_free nullSpell
    pm_free nullSpell

  it "keeps two handles cast from the same JSON independent" $ do
    bytes <- spellBytes "converge-flame"
    a <- castOk bytes testCtx
    b <- castOk bytes testCtx
    pm_advance a 0.5
    CDouble ageA <- pm_age a
    CDouble ageB <- pm_age b
    ageA `shouldBe` 0.5
    ageB `shouldBe` 0
    pm_free a
    pm_free b

  it "advances every shipped example in step with the reference clock" $
    mapM_ agesMatch exampleSpells

-- | Every example that ships with the demo — the FFI shell must not have
-- opinions about which circles it accepts.
exampleSpells :: [String]
exampleSpells =
  [ "empty"
  , "bare-sigil"
  , "ring-fire"
  , "spiral-spark"
  , "pulse-ring"
  , "lissajous"
  , "square-burst"
  , "grand-sigil"
  , "converge-flame"
  ]

agesMatch :: String -> IO ()
agesMatch name = do
  bytes <- spellBytes name
  handle <- castOk bytes testCtx
  ages <- traverse (advanceThen handle pm_age) shortFrames
  let expected = [t | spell <- referenceStates bytes shortFrames, let Time t = spellAge spell]
  map (\(CDouble d) -> d) ages `shouldBe` expected
  pm_free handle

shortFrames :: [Float]
shortFrames = replicate 12 (1 / 60)

-- | Advance by @dt@, then read the observer under test — the order a host
-- loop uses.
advanceThen :: StablePtr SpellCell -> (StablePtr SpellCell -> IO a) -> Float -> IO a
advanceThen handle observer dt = do
  pm_advance handle (CFloat dt)
  observer handle
