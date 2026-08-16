-- | @magic-schema@ (func-spec 0024 S1): hand an external tool chain the
-- machine-readable shape of a spell file.
--
-- Deliberately thin, for the same reason @magic-validate@'s shell is: the
-- document, the command line and every character of the output come from
-- 'Schema', which is pure and tested. This module reads a file, writes
-- bytes and exits.
--
-- Two modes and they are the golden pattern, not two features:
-- @magic-schema@ prints the schema, @magic-schema --check@ asserts that
-- the committed @docs\/spell.schema.json@ still is that schema. The
-- committed file is the one an editor or a CI step points at, so it has to
-- be a file; @--check@ is what stops it drifting from the generator.
module Main (main) where

import qualified Data.ByteString as BS
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitSuccess, exitWith)
import System.IO (hPutStr, hPutStrLn, hSetBinaryMode, stderr, stdout)

import Schema
  ( SchemaOptions (..)
  , generateSchema
  , normalizeNewlines
  , parseSchemaArgs
  , schemaUsage
  )

main :: IO ()
main = do
  args <- getArgs
  case parseSchemaArgs args of
    Left message -> do
      hPutStrLn stderr message
      hPutStr stderr schemaUsage
      exitWith (ExitFailure 64)
    Right SchemaPrint -> do
      -- Binary mode so the LF the generator emits reaches the pipe as an
      -- LF on Windows too: a redirect of this stream is meant to produce
      -- the very bytes '--check' compares against.
      hSetBinaryMode stdout True
      BS.hPut stdout generateSchema
      exitSuccess
    Right (SchemaCheck path) -> do
      there <- doesFileExist path
      if not there
        then do
          hPutStrLn stderr ("magic-schema: no such file: " ++ path)
          hPutStrLn stderr "  run 'magic-schema > <path>' to create it"
          exitWith (ExitFailure 1)
        else do
          onDisk <- BS.readFile path
          if normalizeNewlines onDisk == normalizeNewlines generateSchema
            then do
              hPutStrLn stderr (path ++ " is up to date")
              exitSuccess
            else do
              hPutStrLn stderr (path ++ " differs from the generated schema")
              hPutStrLn stderr ("  regenerate with: magic-schema > " ++ path)
              exitWith (ExitFailure 1)
