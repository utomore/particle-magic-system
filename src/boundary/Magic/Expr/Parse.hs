{-# LANGUAGE OverloadedStrings #-}

-- | Text syntax for the Expr language (func-spec 0003 §4.4) — frozen
-- contract once delivered: lexicon, precedence table and the gate rules.
--
-- The parse layer is the gatekeeper (§2): node-count budget, unknown
-- names, arity errors and non-literal @chan@ arguments are all rejected
-- here, so the core never needs defensive checks. Errors carry
-- line/column positions ('renderExprParseError' uses megaparsec's
-- 'errorBundlePretty'); unknown-name errors list the legal names.
--
-- 'renderExpr' is the inverse direction, printing with minimal
-- parentheses; its contract is the roundtrip property
-- @parseExpr (renderExpr e) == Right e@ for every parser-producible AST
-- (i.e. literals are finite and non-negative — the grammar has no
-- negative/NaN/Infinity literals; a negative constant parses as 'Neg').
module Magic.Expr.Parse
  ( -- * Parsing
    parseExpr
  , ExprParseError
  , renderExprParseError
  , maxExprNodes

    -- * Rendering
  , renderExpr
  ) where

import Control.Monad.Combinators.Expr (Operator (..), makeExprParser)
import Data.Char (isAlphaNum)
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as T
import Magic.Expr
import Text.Megaparsec
import Text.Megaparsec.Char (letterChar, space1)
import Text.Megaparsec.Char.Lexer qualified as L

-- | AST node-count budget enforced at parse time (§4.4). The semantics of
-- the gate is frozen; the value may be raised by a later spec.
maxExprNodes :: Int
maxExprNodes = 512

-- The parser ------------------------------------------------------------------

-- | Domain-specific parse failures (beyond plain syntax errors).
data ExprCustomError
  = -- | Name, then the legal names for that position.
    UnknownName Text [Text]
  | -- | Function, expected arity, actual arity.
    ArityMismatch Text Int Int
  | -- | Node count, budget.
    TooManyNodes Int Int
  deriving (Eq, Ord, Show)

instance ShowErrorComponent ExprCustomError where
  showErrorComponent err = case err of
    UnknownName name legal ->
      "unknown name '"
        <> T.unpack name
        <> "'; legal names are: "
        <> intercalate ", " (map T.unpack legal)
    ArityMismatch name expected got ->
      "'"
        <> T.unpack name
        <> "' expects "
        <> show expected
        <> (if expected == 1 then " argument" else " arguments")
        <> ", got "
        <> show got
    TooManyNodes size budget ->
      "formula too large: "
        <> show size
        <> " AST nodes exceeds the limit of "
        <> show budget

type Parser = Parsec ExprCustomError Text

-- | Wrapped megaparsec error bundle; render with 'renderExprParseError'.
newtype ExprParseError = ExprParseError (ParseErrorBundle Text ExprCustomError)
  deriving (Eq, Show)

-- | Human-readable error with line/column position.
renderExprParseError :: ExprParseError -> String
renderExprParseError (ExprParseError bundle) = errorBundlePretty bundle

-- | Parse a formula (§4.4 grammar). All gates are applied here; a 'Right'
-- result is a well-formed 'Expr' of at most 'maxExprNodes' nodes.
parseExpr :: Text -> Either ExprParseError Expr
parseExpr input = case runParser pTop "<expr>" input of
  Left bundle -> Left (ExprParseError bundle)
  Right e -> Right e

pTop :: Parser Expr
pTop = do
  sc
  e <- pExpr
  eof
  let size = exprSize e
  if size > maxExprNodes
    then failAt 0 (TooManyNodes size maxExprNodes)
    else pure e

-- | Fail with a custom error reported at a recorded offset (so the
-- position points at the offending name, not wherever parsing stopped).
failAt :: Int -> ExprCustomError -> Parser a
failAt o = region (setErrorOffset o) . customFailure

sc :: Parser ()
sc = L.space space1 empty empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: Text -> Parser Text
symbol = L.symbol sc

pExpr :: Parser Expr
pExpr = makeExprParser pAtom operatorTable

-- Precedence, high to low (§4.4): atoms; @^@ right-associative; unary
-- @-@; @*@ @/@ left; @+@ @-@ left. @2^-3@ is a syntax error by
-- construction: the exponent operand sits above the prefix level.
operatorTable :: [[Operator Parser Expr]]
operatorTable =
  [ [InfixR (Bin Pow <$ symbol "^")]
  , [Prefix (Neg <$ symbol "-")]
  , [InfixL (Bin Mul <$ symbol "*"), InfixL (Bin Div <$ symbol "/")]
  , [InfixL (Bin Add <$ symbol "+"), InfixL (Bin Sub <$ symbol "-")]
  ]

pAtom :: Parser Expr
pAtom = (pNumber <|> pParens <|> pNameOrCall) <?> "expression"

pParens :: Parser Expr
pParens = between (symbol "(") (symbol ")") pExpr

-- | Decimal integer or decimal fraction, optional @e@ exponent; no
-- leading dot, no sign (negation is the 'Neg' operator).
pNumber :: Parser Expr
pNumber = Lit <$> lexeme (try L.float <|> (fromIntegral <$> (L.decimal :: Parser Integer))) <?> "number"

pIdent :: Parser Text
pIdent = lexeme $ do
  c <- letterChar
  rest <- takeWhileP Nothing (\ch -> isAlphaNum ch || ch == '_')
  pure (T.cons c rest)

variables :: [(Text, Expr)]
variables =
  [ ("t", Var VarT)
  , ("life", Var VarLife)
  , ("pindex", Var VarPIndex)
  , ("pi", Lit pi)
  ]

data FunSig = F1 !Fun1 | F2 !Fun2 | F3 !Fun3

sigArity :: FunSig -> Int
sigArity sig = case sig of
  F1 _ -> 1
  F2 _ -> 2
  F3 _ -> 3

functions :: [(Text, FunSig)]
functions =
  [ ("sin", F1 FSin)
  , ("cos", F1 FCos)
  , ("abs", F1 FAbs)
  , ("sqrt", F1 FSqrt)
  , ("floor", F1 FFloor)
  , ("sign", F1 FSign)
  , ("min", F2 FMin)
  , ("max", F2 FMax)
  , ("clamp", F3 FClamp)
  ]

pNameOrCall :: Parser Expr
pNameOrCall = do
  o <- getOffset
  name <- pIdent
  open <- optional (symbol "(")
  case open of
    Nothing -> case lookup name variables of
      Just e -> pure e
      Nothing -> failAt o (UnknownName name (map fst variables))
    Just _
      | name == "chan" -> do
          n <- lexeme L.decimal <?> "non-negative integer literal (chan channel index)"
          _ <- symbol ")"
          if n > toInteger (maxBound :: Int)
            then fail "chan channel index out of range"
            else pure (Chan (fromInteger n))
      | otherwise -> case lookup name functions of
          Nothing -> failAt o (UnknownName name ("chan" : map fst functions))
          Just sig -> do
            args <- pExpr `sepBy1` symbol ","
            _ <- symbol ")"
            case (sig, args) of
              (F1 f, [a]) -> pure (Fun1 f a)
              (F2 f, [a, b]) -> pure (Fun2 f a b)
              (F3 f, [a, b, c]) -> pure (Fun3 f a b c)
              _ -> failAt o (ArityMismatch name (sigArity sig) (length args))

-- The renderer ----------------------------------------------------------------

-- | Print with minimal parentheses, guided by the §4.4 precedence table.
-- Contract: @parseExpr (renderExpr e) == Right e@ for every
-- parser-producible AST (roundtrip property, §8 T3).
renderExpr :: Expr -> Text
renderExpr e0 = T.pack (go addP e0)
  where
    -- go c e: render e in a context that admits precedence >= c bare.
    go c e =
      let (p, s) = piece e
       in if p < c then "(" <> s <> ")" else s

    piece e = case e of
      Lit x -> (atomP, show x)
      Var VarT -> (atomP, "t")
      Var VarLife -> (atomP, "life")
      Var VarPIndex -> (atomP, "pindex")
      Chan n -> (atomP, "chan(" <> show n <> ")")
      Neg a -> (negP, "-" <> go (negP + 1) a)
      Bin Pow a b -> (powP, go (powP + 1) a <> "^" <> go powP b)
      Bin Mul a b -> (mulP, go mulP a <> "*" <> go (mulP + 1) b)
      Bin Div a b -> (mulP, go mulP a <> "/" <> go (mulP + 1) b)
      Bin Add a b -> (addP, go addP a <> " + " <> go (addP + 1) b)
      Bin Sub a b -> (addP, go addP a <> " - " <> go (addP + 1) b)
      Fun1 f a -> (atomP, fun1Name f <> "(" <> go addP a <> ")")
      Fun2 f a b -> (atomP, fun2Name f <> "(" <> go addP a <> ", " <> go addP b <> ")")
      Fun3 f a b c ->
        ( atomP
        , fun3Name f <> "(" <> go addP a <> ", " <> go addP b <> ", " <> go addP c <> ")"
        )

    addP, mulP, negP, powP, atomP :: Int
    addP = 0
    mulP = 1
    negP = 2
    powP = 3
    atomP = 4

    fun1Name f = case f of
      FSin -> "sin"
      FCos -> "cos"
      FAbs -> "abs"
      FSqrt -> "sqrt"
      FFloor -> "floor"
      FSign -> "sign"
    fun2Name f = case f of
      FMin -> "min"
      FMax -> "max"
    fun3Name FClamp = "clamp"
