-- | @magic-validate@ (func-spec 0014 S1): tell a spell author what is
-- wrong with a file, in the same words the demo's HUD would use.
--
-- Deliberately thin. Argument parsing, the verdicts and every character
-- of the output come from 'Validate'; this module reads files, prints and
-- exits, and there is nothing here worth a test that the pure half does
-- not already cover.
module Main (main) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitSuccess, exitWith)
import System.IO (hPutStr, hPutStrLn, stderr)
import System.IO.Error (catchIOError)

import Validate
  ( Options (..)
  , Report (..)
  , exitCodeFor
  , failureCount
  , parseArgs
  , renderReport
  , usage
  , validateBytes
  )

main :: IO ()
main = do
  args <- getArgs
  case parseArgs args of
    Left message -> do
      hPutStrLn stderr message
      hPutStr stderr usage
      exitWith (ExitFailure 64)
    Right opts -> do
      files <- concat <$> mapM expand (optPaths opts)
      reports <- mapM checkFile files
      putStr (concatMap (renderReport (optStats opts)) reports)
      hPutStrLn stderr (summary reports)
      case exitCodeFor reports of
        0 -> exitSuccess
        n -> exitWith (ExitFailure n)

-- | A directory contributes its @*.json@ files, sorted — the same rule
-- (and the same order) the demo scans @assets\/spells@ with, so
-- validating a directory covers exactly what the demo would cycle
-- through. Anything else is passed along as a single file, including
-- paths that do not exist: those are a verdict, not a crash.
expand :: FilePath -> IO [FilePath]
expand path = do
  isDir <- doesDirectoryExist path
  if not isDir
    then pure [path]
    else do
      entries <- listDirectory path
      pure [path ++ "/" ++ e | e <- sort entries, ".json" `isSuffixOf` e]

checkFile :: FilePath -> IO Report
checkFile path = do
  there <- doesFileExist path
  if not there
    then pure (Report path (Left ("no such file: " ++ path)))
    else do
      readResult <-
        (Right <$> BS.readFile path) `catchIOError` (pure . Left . show)
      pure $ case readResult of
        Left err -> Report path (Left err)
        Right bytes -> validateBytes path bytes

-- | On stderr, so stdout stays exactly the per-file records the frozen
-- format promises and a script can pipe it straight into @grep@.
summary :: [Report] -> String
summary reports =
  show (length reports)
    ++ " file(s), "
    ++ show (failureCount reports)
    ++ " failed"
