-- | S4 (func-spec 0011 §7): the C# reference binding cannot drift from
-- the header.
--
-- Third use of the same trick: @BoundarySpec@ parses the cabal file,
-- @FFIContractSpec@ parses the header against the @foreign export@ list
-- and the @.def@ file, and this spec parses
-- @bindings\/csharp\/ParticleMagic.cs@. Nothing else can — the binding is
-- not compiled by this project (no .NET toolchain in the loop), so
-- without a text check a new entry point would ship with a binding that
-- silently lacks it, and a changed constant would ship with a binding
-- that silently lies about it.
--
-- The two assertions are set-equalities in /both/ directions, which is
-- what makes them catch additions rather than only deletions: every
-- header function has a @DllImport@ and vice versa, every header
-- @#define@ has a @public const int@ naming it in a trailing comment, and
-- the values agree.
module BindingContractSpec (spec) where

import Data.Char (isAlphaNum, isSpace)
import Data.List (sort)
import FFIContractSpec (headerDefines, headerFunctions, readUtf8)
import Test.Hspec

bindingFile :: FilePath
bindingFile = "bindings/csharp/ParticleMagic.cs"

spec :: Spec
spec = describe "C# reference binding (func-spec 0011 §7 S4)" $ do
  it "declares exactly the header's entry points, no more and no fewer" $ do
    declared <- headerFunctions
    imported <- externNames
    sort imported `shouldBe` sort declared

  it "attaches a DllImport to every extern (a missing one is a runtime crash)" $ do
    source <- readUtf8 bindingFile
    imported <- externNames
    length (filter ("[DllImport" `isInfixOf'`) (lines source)) `shouldBe` length imported

  it "mirrors every header constant, by name and by value" $ do
    defines <- headerDefines
    constants <- csharpConstants
    -- Both directions: a new #define with no C# counterpart fails here,
    -- as does a C# constant naming a macro that no longer exists.
    sort (map fst constants) `shouldBe` sort (map fst defines)
    mapM_
      (\(macro, value) -> lookup macro constants `shouldBe` Just value)
      defines

  it "pins the library name the host loads" $ do
    source <- readUtf8 bindingFile
    source `shouldSatisfy` isInfixOf' "\"particle-magic-ffi\""

-- Parsers --------------------------------------------------------------------

-- | The name in each @public static extern <type> name(@ declaration.
externNames :: IO [String]
externNames = do
  source <- readUtf8 bindingFile
  pure [name | l <- lines source, Just name <- [externName l]]
  where
    externName l
      | not ("static extern" `isInfixOf'` l) = Nothing
      | otherwise = case break (== '(') l of
          (_, "") -> Nothing
          (lhs, _) -> case reverse (takeWhile isIdentChar (reverse (trim lhs))) of
            "" -> Nothing
            name -> Just name

-- | @public const int Name = Value;   // PM_MACRO ...@ lines, keyed by the
-- macro the trailing comment names. Keying on the comment rather than on
-- a table kept in this file means the binding states its own claim, and
-- this spec only checks it.
csharpConstants :: IO [(String, Int)]
csharpConstants = do
  source <- readUtf8 bindingFile
  pure [pair | l <- lines source, Just pair <- [constant (trim l)]]
  where
    constant l = case words l of
      ("public" : "const" : "int" : _name : "=" : rest) -> do
        value <- readInt (takeWhile (/= ';') (unwords rest))
        macro <- macroOf (drop 1 (dropWhile (/= '/') l))
        pure (macro, value)
      _ -> Nothing
    macroOf comment = case words (dropWhile (== '/') comment) of
      (m : _) -> Just (takeWhile isIdentChar m)
      [] -> Nothing
    readInt raw = case reads (trim raw) of
      [(n, "")] -> Just n
      _ -> Nothing

isIdentChar :: Char -> Bool
isIdentChar c = isAlphaNum c || c == '_'

isInfixOf' :: String -> String -> Bool
isInfixOf' needle haystack = any (needle `prefixes`) (tails' haystack)
  where
    prefixes [] _ = True
    prefixes _ [] = False
    prefixes (a : as) (b : bs) = a == b && prefixes as bs
    tails' [] = [[]]
    tails' xs@(_ : rest) = xs : tails' rest

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
