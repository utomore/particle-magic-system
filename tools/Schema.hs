{-# LANGUAGE OverloadedStrings #-}

-- | The pure half of @magic-schema@ (func-spec 0024 S1): the machine-readable
-- shape of a spell file, plus the small validator the guards are written
-- against.
--
-- Two things live here and they point in opposite directions.
--
-- 'generateSchema' /writes/ a JSON Schema draft-07 document describing
-- @assets\/spells\/*.json@. It is a hand-written declaration table, not a
-- derivation from the Haskell types — func-spec 0024 §7-5 records why:
-- a Generic\/TH derivation would make "somebody added a constructor and
-- forgot the schema" silently correct, and the whole value of this round
-- is that it is loudly red instead.
--
-- 'validateJson' /reads/ one back and checks a document against it. It
-- implements the subset of draft-07 that 'generateSchema' actually emits
-- ('supportedKeywords') and nothing more, which is only safe because
-- 'keywordsUsedBy' lets a test assert the two sets line up — a validator
-- that silently ignored an unknown keyword would turn "every example
-- passes" into a sentence about nothing.
--
-- __Frozen__ (func-spec 0024 §9): the generated document's content and
-- the rule that produces it. The bytes are committed as
-- @docs\/spell.schema.json@ so an editor or a CI step can reference the
-- file directly; @magic-schema --check@ compares the two, golden-style.
--
-- __What the schema does not say.__ It describes /shape/: which keys
-- exist, what type each holds, which tags are legal, and the per-field
-- bounds. Cross-field rules (@rInner < rOuter@, @inner < outer@) and the
-- particle budget are not expressible here and stay where they already
-- are, in "Magic.Codec" and the compiler. A file this schema accepts is
-- therefore well-shaped, not necessarily castable — which is exactly the
-- division of labour @magic-validate@ exists for.
module Schema
  ( -- * The generator
    generateSchema

    -- * What the schema says, as data (the middle term of the three-way law)
  , schemaEnumValues
  , keywordsUsedBy
  , refTargets

    -- * The validating subset of draft-07
  , validateJson
  , supportedKeywords

    -- * Command line
  , SchemaOptions (..)
  , parseSchemaArgs
  , schemaUsage
  , normalizeNewlines
  ) where

import Data.Aeson (Value (Array, Bool, Null, Number, Object, String))
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isControl, ord)
import Data.Foldable (toList)
import Data.List (intercalate, nub, sort)
import qualified Data.Text as T
import Numeric (showHex)

-- The document tree --------------------------------------------------------

-- | A JSON value with a /declared/ key order.
--
-- aeson's 'Object' is a hash map, so encoding through it would put the
-- keys in whatever order the hashing happens to produce — fine for a wire
-- format, useless for a file that is committed, diffed and read by people.
-- This tiny tree exists for that one reason: @"$schema"@ comes first
-- because it comes first in every schema anyone has ever read.
data J
  = JNull
  | JBool !Bool
  | JInt !Int
  | JNum !Double
  | JStr String
  | JArr [J]
  | JObj [(String, J)]
  deriving (Eq, Show)

-- | The whole document, as bytes, newline-terminated.
generateSchema :: BS.ByteString
generateSchema = BSC.pack (render 0 schemaTree ++ "\n")

render :: Int -> J -> String
render ind j = case j of
  JNull -> "null"
  JBool b -> if b then "true" else "false"
  JInt n -> show n
  JNum d -> show d
  JStr s -> quote s
  JArr [] -> "[]"
  JArr xs
    -- Scalars stay on one line: @"required": ["rune", "shape"]@ and a
    -- nine-element element list read better than nine lines would.
    | all isScalar xs -> "[" ++ intercalate ", " (map (render ind) xs) ++ "]"
    | otherwise ->
        "[\n"
          ++ intercalate ",\n" [pad (ind + 1) ++ render (ind + 1) x | x <- xs]
          ++ "\n"
          ++ pad ind
          ++ "]"
  JObj [] -> "{}"
  JObj kvs ->
    "{\n"
      ++ intercalate
        ",\n"
        [pad (ind + 1) ++ quote k ++ ": " ++ render (ind + 1) v | (k, v) <- kvs]
      ++ "\n"
      ++ pad ind
      ++ "}"
  where
    pad n = replicate (n * 2) ' '
    isScalar x = case x of
      JObj _ -> False
      JArr _ -> False
      _ -> True

quote :: String -> String
quote s = '"' : concatMap esc s ++ "\""
  where
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _
        | isControl c -> "\\u" ++ pad4 (showHex (ord c) "")
        | otherwise -> [c]
    pad4 h = replicate (4 - length h) '0' ++ h

-- The schema ---------------------------------------------------------------

draft07 :: String
draft07 = "http://json-schema.org/draft-07/schema#"

schemaTree :: J
schemaTree =
  JObj
    [ ("$schema", JStr draft07)
    , ("$id", JStr "https://raw.githubusercontent.com/utomore/particle-magic-system/main/docs/spell.schema.json")
    , ("title", JStr "particle-magic spell file (schema v1)")
    , ("description", JStr "A magic circle, as JSON. Every slot is optional: a missing key, null, and a null array element all mean 'empty slot'. Author's handbook: docs/spell-schema.md. This document describes shape only -- cross-field rules (rInner < rOuter) and the particle budget are checked by magic-validate, not here.")
    , ("type", JStr "object")
    , ("required", JArr [JStr "version", JStr "circle"])
    , ("properties", JObj
        [ ("version", JObj
            [ ("description", JStr "Schema version. This build reads version 1 and nothing else.")
            , ("const", JInt 1)
            ])
        , ("name", JObj
            [ ("description", JStr "A name for humans; the system never reads it.")
            , ("type", JStr "string")
            ])
        , ("circle", ref "circle")
        ])
    , ("definitions", JObj definitions)
    ]

definitions :: [(String, J)]
definitions =
  [ ("circle", circleDef)
  , ("outerRing", ringDef "outerRune" "Outer ring: presentation. Index 0 is the inner layer, index 1 the outer one; same-kind runes at index 1 override index 0.")
  , ("outerRune", outerRuneDef)
  , ("faceShape", faceShapeDef)
  , ("innerRing", ringDef "innerRune" "Inner ring: behaviour. Index 0 is the inner layer, index 1 the outer one; same-kind runes at index 1 override index 0.")
  , ("innerRune", innerRuneDef)
  , ("bridgeRune", bridgeRuneDef)
  , ("core", coreDef)
  , ("nodes", nodesDef)
  , ("essence", essenceDef)
  , ("nodeRune", nodeRuneDef)
  , ("phases", phasesDef)
  , ("fieldArray", fieldArrayDef)
  , ("forceField", forceFieldDef)
  , ("anchorArray", anchorArrayDef)
  , ("anchor", anchorDef)
  , ("vec3", vec3Def)
  , ("formula", formulaDef)
  ]

circleDef :: J
circleDef =
  JObj
    [ ("description", JStr "The circle itself. '\"circle\": {}' is the smallest legal spell (see assets/spells/empty.json).")
    , ("type", JStr "object")
    , ("properties", JObj
        [ ("outer", nullable (ref "outerRing"))
        , ("bridge", nullable (ref "bridgeRune"))
        , ("inner", nullable (ref "innerRing"))
        , ("core", nullable (ref "core"))
        , ("phases", nullable (ref "phases"))
        , ("fields", nullable (ref "fieldArray"))
        , ("anchors", nullable (ref "anchorArray"))
        ])
    ]

ringDef :: String -> String -> J
ringDef item note =
  JObj
    [ ("description", JStr note)
    , ("type", JStr "array")
    , ("items", nullable (ref item))
    , ("maxItems", JInt 2)
    ]

outerRuneDef :: J
outerRuneDef =
  JObj
    [ ("description", JStr "Presentation: where particles are born and which way they leave.")
    , ("type", JStr "object")
    , ("required", JArr [JStr "rune"])
    , ("oneOf", JArr
        [ variant "rune" "shape"
            [("shape", ref "faceShape")]
        , variant "rune" "radiate"
            [("mode", enumOf
                "Reference direction the trajectory travels along. The last three read the particle's spawn offset, so they need a 'shape' rune to be visible."
                ["along-normal", "radial-outward", "radial-inward", "tangential-swirl"])]
        , variant "rune" "range"
            [("expr", ref "formula")]
        , variant "rune" "style"
            [("billboard", enumOf
                "Billboard form of the casting particles. Formation particles stay hard squares so the drawn circle keeps its edges."
                ["square", "soft-dot", "ring", "spark", "trail"])]
        ])
    ]

faceShapeDef :: J
faceShapeDef =
  JObj
    [ ("description", JStr "The drawn 2D face particles are born on. Without one they spawn in a scatter around the circle's centre.")
    , ("type", JStr "object")
    , ("required", JArr [JStr "kind"])
    , ("oneOf", JArr
        [ variant "kind" "hollow-square" [("size", positive)]
        , variant "kind" "rect" [("w", positive), ("h", positive)]
        , variant "kind" "ring" [("rInner", positive), ("rOuter", positive)]
        , variant "kind" "diamond" [("size", positive)]
        , variant "kind" "polygon" [("sides", intFrom 3), ("radius", positive)]
        , variant "kind" "star" [("points", intFrom 2), ("outer", positive), ("inner", nonNegative)]
        , variant "kind" "cross" [("length", positive), ("width", positive)]
        , variant "kind" "sector" [("inner", nonNegative), ("outer", positive), ("sweep", sweep)]
        ])
    ]

innerRuneDef :: J
innerRuneDef =
  JObj
    [ ("description", JStr "Behaviour: how a particle moves and how long it lives.")
    , ("type", JStr "object")
    , ("required", JArr [JStr "rune"])
    , ("oneOf", JArr
        [ trajectoryVariant
        , variant "rune" "timing"
            [("delay", nonNegative), ("duration", nonNegative), ("lifetime", positive)]
        , variant "rune" "formula"
            [("x", ref "formula"), ("y", ref "formula"), ("z", ref "formula")]
        ])
    ]

-- | The one two-level tag in the schema: @rune@ picks @trajectory@, then
-- @kind@ picks which of the seven. Written as a @oneOf@ nested inside a
-- @oneOf@ branch rather than flattened into 21 branches, because the
-- flattening would have to be regenerated every time either list grows.
trajectoryVariant :: J
trajectoryVariant =
  JObj
    [ ("required", JArr [JStr "rune", JStr "kind"])
    , ("properties", JObj [("rune", constOf "trajectory")])
    , ("oneOf", JArr
        [ variant "kind" "forward" [("speed", number)]
        , variant "kind" "spiral" [("speed", number), ("radius", positive), ("freq", number)]
        , variant "kind" "orbit" [("radius", positive), ("freq", number)]
        , variant "kind" "wave" [("speed", number), ("amplitude", number), ("freq", nonNegative)]
        , variant "kind" "ballistic" [("speed", number), ("gravity", number)]
        , variant "kind" "pulse" [("speed", number), ("freq", nonNegative)]
        , variant "kind" "zigzag" [("speed", number), ("amplitude", number), ("freq", nonNegative)]
        ])
    ]

bridgeRuneDef :: J
bridgeRuneDef =
  JObj
    [ ("description", JStr "Modulation: bends the inner ring's behaviour once more before presentation.")
    , ("type", JStr "object")
    , ("required", JArr [JStr "rune"])
    , ("oneOf", JArr
        [ variant "rune" "phase" [("shift", nonNegative)]
        , variant "rune" "converge" [("expr", ref "formula")]
        , variant "rune" "amplify" [("expr", ref "formula")]
        ])
    ]

coreDef :: J
coreDef =
  JObj
    [ ("description", JStr "Essence: what kind of magic this is.")
    , ("type", JStr "object")
    , ("properties", JObj
        [ ("center", nullable (ref "essence"))
        , ("nodes", nullable (ref "nodes"))
        ])
    ]

nodesDef :: J
nodesDef =
  JObj
    [ ("description", JStr "The four directional node slots. north = face up, east = face right.")
    , ("type", JStr "object")
    , ("properties", JObj
        [ (dir, nullable (ref "nodeRune")) | dir <- ["north", "south", "east", "west"]
        ])
    ]

essenceDef :: J
essenceDef =
  JObj
    [ ("type", JStr "object")
    , ("required", JArr [JStr "element", JStr "power"])
    , ("properties", JObj
        [ ("element", enumOf
            "Element: decides the colour ramp and the blend mode. One circle has one element, so one blend mode."
            ["neutral", "fire", "water", "lightning", "metal", "wood", "earth", "yin", "yang"])
        , ("power", JObj
            [ ("description", JStr "Particle count = round(256 * power), floor 1. Too large and the compile fails on the budget cap.")
            , ("type", JStr "number")
            , ("exclusiveMinimum", JInt 0)
            ])
        ])
    ]

nodeRuneDef :: J
nodeRuneDef =
  JObj
    [ ("type", JStr "object")
    , ("required", JArr [JStr "rune"])
    , ("oneOf", JArr
        [ variant "rune" "dir-bias" [("strength", number)]
        ])
    ]

phasesDef :: J
phasesDef =
  JObj
    [ ("description", JStr "Lifecycle staging: draw the circle, hold, then cast. Omitting it casts at once.")
    , ("type", JStr "object")
    , ("required", JArr [JStr "draw", JStr "converge"])
    , ("properties", JObj
        [ ("draw", positive)
        , ("converge", nonNegative)
        ])
    ]

fieldArrayDef :: J
fieldArrayDef =
  JObj
    [ ("description", JStr "Force fields: a displacement layer over the analytic trajectories. They act on the casting particles only -- the drawn circle stays put.")
    , ("type", JStr "array")
    , ("items", ref "forceField")
    ]

forceFieldDef :: J
forceFieldDef =
  JObj
    [ ("type", JStr "object")
    , ("required", JArr [JStr "kind"])
    , ("oneOf", JArr
        [ variant "kind" "gravity" [("accel", ref "vec3")]
        , variant "kind" "attractor"
            [("center", ref "vec3"), ("strength", number), ("softening", positive)]
        , variant "kind" "vortex"
            [("center", ref "vec3"), ("axis", ref "vec3"), ("strength", number), ("falloff", nonNegative)]
        , variant "kind" "wind"
            [("dir", ref "vec3"), ("strength", number), ("turbulence", nonNegative)]
        , variant "kind" "turbulence" [("strength", number), ("scale", positive)]
        , variant "kind" "spring" [("center", ref "vec3"), ("k", positive)]
        ])
    ]

anchorArrayDef :: J
anchorArrayDef =
  JObj
    [ ("description", JStr "Activation points. Omit the key (or write null) for the single default one; an empty array is an error, and 16 is the cap. Particles are shared out between the points, never multiplied by them.")
    , ("type", JStr "array")
    , ("items", ref "anchor")
    , ("minItems", JInt 1)
    , ("maxItems", JInt 16)
    ]

anchorDef :: J
anchorDef =
  JObj
    [ ("type", JStr "object")
    , ("required", JArr [JStr "offset", JStr "normal"])
    , ("properties", JObj
        [ ("offset", ref "vec3")
        , ("normal", ref "vec3")
        ])
    ]

vec3Def :: J
vec3Def =
  JObj
    [ ("description", JStr "Three numbers, [x, y, z], in the caster's frame: x = right, y = up, z = straight ahead.")
    , ("type", JStr "array")
    , ("items", JObj [("type", JStr "number")])
    , ("minItems", JInt 3)
    , ("maxItems", JInt 3)
    ]

formulaDef :: J
formulaDef =
  JObj
    [ ("description", JStr "A one-line formula. Names: t, life, pindex, pi. Functions: sin cos abs sqrt floor sign min max clamp, and chan(N) for per-particle randomness. At most 512 syntax-tree nodes. Parsed at load time -- a syntax error names its line and column.")
    , ("type", JStr "string")
    ]

-- Schema fragments ---------------------------------------------------------

ref :: String -> J
ref name = JObj [("$ref", JStr ("#/definitions/" ++ name))]

-- | An empty slot spells itself three ways (missing key, @null@, @null@
-- array element) and the codec treats all three alike; the first is the
-- absence of the property, the other two are this.
nullable :: J -> J
nullable j = JObj [("anyOf", JArr [JObj [("type", JStr "null")], j])]

-- | One branch of a tagged union: the discriminator pinned to a literal,
-- and every key that tag makes mandatory. All of them are mandatory
-- because "Magic.Codec" reads them with @.:@ rather than @.:?@ — the
-- schema is describing the decoder, not an aspiration.
variant :: String -> String -> [(String, J)] -> J
variant disc tag props =
  JObj
    [ ("required", JArr (map JStr (disc : map fst props)))
    , ("properties", JObj ((disc, constOf tag) : props))
    ]

constOf :: String -> J
constOf tag = JObj [("const", JStr tag)]

enumOf :: String -> [String] -> J
enumOf note values =
  JObj
    [ ("description", JStr note)
    , ("type", JStr "string")
    , ("enum", JArr (map JStr values))
    ]

number :: J
number = JObj [("type", JStr "number")]

positive :: J
positive = JObj [("type", JStr "number"), ("exclusiveMinimum", JInt 0)]

nonNegative :: J
nonNegative = JObj [("type", JStr "number"), ("minimum", JInt 0)]

intFrom :: Int -> J
intFrom lo = JObj [("type", JStr "integer"), ("minimum", JInt lo)]

-- | A sector's opening angle: more than nothing, at most a full turn.
sweep :: J
sweep =
  JObj
    [ ("type", JStr "number")
    , ("exclusiveMinimum", JInt 0)
    , ("maximum", JNum (2 * pi))
    ]

-- Reading the schema back --------------------------------------------------

-- | Every string a @const@ or @enum@ in the schema pins, deduplicated and
-- sorted.
--
-- This is the middle term of the three-way consistency law (func-spec 0024
-- §2.1): it equals the set of quoted vocabulary in
-- @docs\/spell-schema.md@, which func-spec 0014's guard already ties to the
-- shipped examples, which "Magic.Codec"'s roundtrip ties to the tags the
-- decoder accepts. Add a tag anywhere and the missing two ends go red.
--
-- Numbers are skipped on purpose: @"version": {"const": 1}@ is a value,
-- not vocabulary.
schemaEnumValues :: Value -> [String]
schemaEnumValues = nub . sort . walk
  where
    walk v = case v of
      Object o -> here o ++ concatMap walk (subSchemas o)
      _ -> []

    here o =
      [T.unpack t | Just (String t) <- [KM.lookup "const" o]]
        ++ [ T.unpack t
           | Just (Array vs) <- [KM.lookup "enum" o]
           , String t <- toList vs
           ]

-- | Every keyword the schema uses, in schema position — so the names
-- inside @properties@ and @definitions@ (which are author-facing keys, not
-- keywords) are excluded.
keywordsUsedBy :: Value -> [String]
keywordsUsedBy = nub . sort . walk
  where
    walk v = case v of
      Object o -> map AK.toString (KM.keys o) ++ concatMap walk (subSchemas o)
      _ -> []

-- | Every @#\/definitions\/NAME@ the schema points at.
refTargets :: Value -> [String]
refTargets = nub . sort . walk
  where
    walk v = case v of
      Object o ->
        [ T.unpack name
        | Just (String t) <- [KM.lookup "$ref" o]
        , Just name <- [T.stripPrefix prefix t]
        ]
          ++ concatMap walk (subSchemas o)
      _ -> []
    prefix = "#/definitions/"

-- | The schemas nested inside one schema object, at the places draft-07
-- says a schema may appear. Shared by the three walkers above and by the
-- validator, so none of them can wander into a place the others do not.
subSchemas :: KM.KeyMap Value -> [Value]
subSchemas o = concatMap sub (KM.toList o)
  where
    sub (k, v) = case (AK.toString k, v) of
      ("properties", Object p) -> KM.elems p
      ("definitions", Object d) -> KM.elems d
      ("items", s) -> [s]
      (branch, Array ss)
        | branch `elem` ["anyOf", "oneOf", "allOf"] -> toList ss
      _ -> []

-- The validator ------------------------------------------------------------

-- | The draft-07 keywords 'validateJson' understands. Anything outside
-- this list would be silently ignored, so @test\/JsonSchemaSpec.hs@
-- asserts that 'keywordsUsedBy' 'generateSchema' stays inside it.
--
-- The four annotations at the end are carried deliberately: they say
-- nothing about validity, and listing them here is what lets the guard be
-- an equality rather than a subset with an excuse.
supportedKeywords :: [String]
supportedKeywords =
  [ "$ref"
  , "allOf"
  , "anyOf"
  , "const"
  , "enum"
  , "exclusiveMaximum"
  , "exclusiveMinimum"
  , "items"
  , "maxItems"
  , "maximum"
  , "minItems"
  , "minimum"
  , "oneOf"
  , "properties"
  , "required"
  , "type"
  , -- annotations, ignored when validating
    "$id"
  , "$schema"
  , "definitions"
  , "description"
  , "title"
  ]

-- | @validateJson schema document@ — every way the document fails the
-- schema, as sentences an author can act on. @[]@ means it passed.
--
-- Only the subset in 'supportedKeywords' is implemented, and a @$ref@'s
-- siblings are ignored exactly as draft-07 says (the generated schema
-- never writes any, which @JsonSchemaSpec@ also checks).
validateJson :: Value -> Value -> [String]
validateJson root document = check "$" root document
  where
    check path schema value = case deref schema of
      Just (Object o) -> concatMap (applyKeyword path value) (KM.toList o)
      Just _ -> [path ++ ": schema is not an object"]
      Nothing -> [path ++ ": unresolvable $ref"]

    -- A schema, with a leading @$ref@ followed to its definition.
    -- draft-07 says a @$ref@'s siblings are ignored, and the generator
    -- never writes any (@JsonSchemaSpec@ checks), so following it whole
    -- is the same thing as merging it.
    deref schema = case schema of
      Object o | Just (String target) <- KM.lookup "$ref" o ->
        maybe Nothing deref (resolve target)
      _ -> Just schema

    resolve target = case T.stripPrefix "#/definitions/" target of
      Nothing -> Nothing
      Just name -> case root of
        Object o | Just (Object defs) <- KM.lookup "definitions" o ->
          KM.lookup (AK.fromText name) defs
        _ -> Nothing

    applyKeyword path value (key, spec) = case AK.toString key of
      "type" -> typeCheck path spec value
      "const"
        | value == spec -> []
        | otherwise -> [path ++ ": expected " ++ shortly spec ++ ", got " ++ shortly value]
      "enum" -> case spec of
        Array vs
          | value `elem` toList vs -> []
          | otherwise ->
              [ path
                  ++ ": "
                  ++ shortly value
                  ++ " is not one of "
                  ++ intercalate ", " (map shortly (toList vs))
              ]
        _ -> [path ++ ": 'enum' must be an array"]
      "required" -> case (spec, value) of
        (Array names, Object inst) ->
          [ path ++ ": missing required key " ++ T.unpack n
          | String n <- toList names
          , not (KM.member (AK.fromText n) inst)
          ]
        _ -> []
      "properties" -> case (spec, value) of
        (Object props, Object inst) ->
          concat
            [ check (path ++ "." ++ AK.toString k) sub v
            | (k, sub) <- KM.toList props
            , Just v <- [KM.lookup k inst]
            ]
        _ -> []
      "items" -> case value of
        Array items ->
          concat [check (path ++ "[" ++ show i ++ "]") spec v | (i, v) <- zip [0 :: Int ..] (toList items)]
        _ -> []
      "minItems" -> lengthCheck path spec value (<) "at least"
      "maxItems" -> lengthCheck path spec value (>) "at most"
      "minimum" -> boundCheck path spec value (<) ">="
      "maximum" -> boundCheck path spec value (>) "<="
      "exclusiveMinimum" -> boundCheck path spec value (<=) ">"
      "exclusiveMaximum" -> boundCheck path spec value (>=) "<"
      "anyOf" -> branchCheck path spec value (>= 1) "at least one"
      "oneOf" -> branchCheck path spec value (== 1) "exactly one"
      "allOf" -> case spec of
        Array branches -> concatMap (\b -> check path b value) (toList branches)
        _ -> [path ++ ": 'allOf' must be an array"]
      -- Annotations and the definitions block: nothing to check.
      _ -> []

    typeCheck path spec value = case spec of
      String t -> ofTypes path [t] value
      Array ts -> ofTypes path [t | String t <- toList ts] value
      _ -> [path ++ ": 'type' must be a string or an array of strings"]

    ofTypes path names value
      | any (`isOfType` value) names = []
      | otherwise =
          [ path
              ++ ": expected "
              ++ intercalate " or " (map T.unpack names)
              ++ ", got "
              ++ typeName value
          ]

    lengthCheck path spec value bad word = case (spec, value) of
      (Number n, Array items)
        | length (toList items) `bad` round n ->
            [ path
                ++ ": expected "
                ++ word
                ++ " "
                ++ plural (round n) "element"
                ++ ", got "
                ++ show (length (toList items))
            ]
      _ -> []

    plural n noun = show (n :: Int) ++ " " ++ noun ++ (if n == 1 then "" else "s")

    boundCheck path spec value bad word = case (spec, value) of
      (Number limit, Number actual)
        | actual `bad` limit ->
            [path ++ ": expected " ++ word ++ " " ++ shortly spec ++ ", got " ++ shortly value]
      _ -> []

    branchCheck path spec value ok word = case spec of
      Array items ->
        let branches = toList items
            passing = length [() | b <- branches, null (check path b value)]
         in if ok passing
              then []
              else case filter (applies value) branches of
                -- Nothing even claimed the document. For a tagged union
                -- that is the interesting case and it has an exact
                -- diagnosis: the tag is wrong. Saying which tags exist is
                -- the same courtesy 'Magic.Codec' pays ("valid tags here:
                -- ..."), and an author who reads it needs nothing else.
                [] -> [path ++ ": " ++ tagAdvice branches value]
                -- Otherwise the tag was right and the contents were not,
                -- so the claiming branch's complaints are the whole
                -- story; the others would only repeat that this is not a
                -- 'radiate' rune, which the author already knows.
                claimants ->
                  concat [check path b value | b <- claimants]
                    ++ [ path ++ ": expected " ++ word ++ " of " ++ show (length branches) ++ " alternatives to match, " ++ show passing ++ " did"
                       | length claimants > 1 || passing > 0
                       ]
      _ -> [path ++ ": expected an array of alternatives"]

    -- Does this branch claim the document at all? Two structural
    -- questions, no message parsing: does its declared 'type' admit the
    -- document, and does every property it pins with a 'const' hold that
    -- exact value? For a tagged union that is true of exactly one branch,
    -- and for the nullable-slot pattern it is what tells "this is not
    -- null" apart from "this rune is malformed".
    applies value branch = case deref branch of
      Just (Object o) -> typeAdmits o && constsHold o
      _ -> False
      where
        typeAdmits o = case KM.lookup "type" o of
          Just t -> null (typeCheck "" t value)
          Nothing -> True
        constsHold o = case (KM.lookup "properties" o, value) of
          (Just (Object props), Object inst) ->
            and
              [ KM.lookup k inst == Just pinned
              | (k, Object p) <- KM.toList props
              , Just pinned <- [KM.lookup "const" p]
              ]
          _ -> True

    -- The discriminator these branches are keyed on, and what it may be.
    -- A key counts only if /every/ branch pins it, which is what makes
    -- "one of these" a true statement rather than a guess.
    tagAdvice branches value = case discriminator branches of
      Just (key, allowed) ->
        show key
          ++ " must be one of "
          ++ intercalate ", " (map shortly allowed)
          ++ ( case value of
                 Object inst -> case KM.lookup (AK.fromString key) inst of
                   Just actual -> " (got " ++ shortly actual ++ ")"
                   Nothing -> " (the key is missing)"
                 _ -> ""
             )
      Nothing -> "no alternative matched"

    discriminator branches = case mapM pinnedOf branches of
      Just (first_ : rest) ->
        case [k | (k, _) <- first_, all (any ((== k) . fst)) rest] of
          (key : _) ->
            Just (key, [v | pins <- first_ : rest, (k, v) <- pins, k == key])
          [] -> Nothing
      _ -> Nothing

    pinnedOf branch = case deref branch of
      Just (Object o) | Just (Object props) <- KM.lookup "properties" o ->
        Just
          [ (AK.toString k, pinned)
          | (k, Object p) <- KM.toList props
          , Just pinned <- [KM.lookup "const" p]
          ]
      _ -> Nothing

isOfType :: T.Text -> Value -> Bool
isOfType name value = case (name, value) of
  ("object", Object _) -> True
  ("array", Array _) -> True
  ("string", String _) -> True
  ("boolean", Bool _) -> True
  ("null", Null) -> True
  ("number", Number _) -> True
  ("integer", Number n) ->
    let d = realToFrac n :: Double in d == fromIntegral (round d :: Integer)
  _ -> False

typeName :: Value -> String
typeName value = case value of
  Object _ -> "object"
  Array _ -> "array"
  String _ -> "string"
  Number _ -> "number"
  Bool _ -> "boolean"
  Null -> "null"

-- | A value, short enough to sit inside an error sentence.
shortly :: Value -> String
shortly value = case value of
  String t -> show (T.unpack t)
  Number n ->
    let d = realToFrac n :: Double
     in if d == fromIntegral (round d :: Integer) then show (round d :: Integer) else show d
  Bool b -> if b then "true" else "false"
  Null -> "null"
  Object _ -> "an object"
  Array _ -> "an array"

-- Command line -------------------------------------------------------------

-- | What @magic-schema@ was asked to do.
data SchemaOptions
  = -- | Print the schema on stdout.
    SchemaPrint
  | -- | Compare the schema with a file on disk; a difference is exit 1.
    SchemaCheck FilePath
  deriving (Eq, Show)

-- | Parse the command line. 'Left' is the message to print before the
-- usage text.
--
-- @--check@ defaults its path, unlike @magic-validate@'s: there is exactly
-- one file in this repository that is supposed to be the schema, and
-- naming it on every invocation would only be a way to get it wrong.
parseSchemaArgs :: [String] -> Either String SchemaOptions
parseSchemaArgs args = case args of
  [] -> Right SchemaPrint
  ["--check"] -> Right (SchemaCheck defaultSchemaPath)
  ["--check", path] -> Right (SchemaCheck path)
  ("--help" : _) -> Left "magic-schema: help requested"
  ("-h" : _) -> Left "magic-schema: help requested"
  (a : _) -> Left ("magic-schema: unexpected argument " ++ show a)

defaultSchemaPath :: FilePath
defaultSchemaPath = "docs/spell.schema.json"

schemaUsage :: String
schemaUsage =
  unlines
    [ "usage: magic-schema [--check [PATH]]"
    , ""
    , "  (no arguments)   print the JSON Schema (draft-07) on stdout"
    , "  --check [PATH]   compare it with PATH (default " ++ defaultSchemaPath ++ ")"
    , ""
    , "Exit code is 0 when they agree, 1 when they differ, 64 for bad usage."
    ]

-- | Drop carriage returns before comparing.
--
-- The committed schema is a text file and this repository is developed on
-- Windows with @core.autocrlf=true@, so the working-tree copy has CRLF
-- endings while 'generateSchema' emits LF. Comparing the bytes raw would
-- make @--check@ fail on every developer machine and pass in CI, which is
-- the worst of both. The content is what is frozen; the line terminator
-- is the checkout's business.
normalizeNewlines :: BS.ByteString -> BS.ByteString
normalizeNewlines = BSC.filter (/= '\r')
