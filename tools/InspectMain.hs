-- | @magic-inspect@ (func-spec 0024 S2): print what a spell file adds up
-- to, without opening a window.
--
-- Thin, like the other two tool shells: 'Inspect' decides every character
-- and this module reads files, prints and exits. The exit code follows
-- @magic-validate@'s convention — the number of files that could not be
-- reported on — so the three tools can be chained in one CI script without
-- anybody having to remember which is which.
module Main (main) where

import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitSuccess, exitWith)
import System.IO (hPutStr, hPutStrLn, stderr)
import System.IO.Error (catchIOError)

import Inspect (inspectReport, renderCompileErrorForInspect)
import Magic.Codec (loadCircle, renderLoadError)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> bail "magic-inspect: no files or directories given"
    _ | any isFlag args -> bail ("magic-inspect: unexpected argument " ++ show (head' (filter isFlag args)))
    paths -> do
      files <- concat <$> mapM expand paths
      results <- mapM report files
      exitWith' (length (filter not results))
  where
    isFlag a = case a of
      ('-' : _) -> True
      _ -> False
    head' xs = case xs of
      (x : _) -> x
      [] -> ""

bail :: String -> IO ()
bail message = do
  hPutStrLn stderr message
  hPutStr stderr usage
  exitWith (ExitFailure 64)

exitWith' :: Int -> IO ()
exitWith' failures = case failures of
  0 -> exitSuccess
  n -> exitWith (ExitFailure (min 125 n))

usage :: String
usage =
  unlines
    [ "usage: magic-inspect PATH..."
    , ""
    , "  PATH   a spell file, or a directory whose *.json files are all reported on"
    , ""
    , "Prints the structure report for each file: budget, timeline, emitters, batches."
    , "Exit code is the number of files that could not be reported on (0 = all good,"
    , "64 = bad usage). For a pass/fail verdict on a file, use magic-validate."
    ]

-- | Same expansion rule as @magic-validate@ and the demo's spell scan:
-- a directory contributes its @*.json@ files, sorted.
expand :: FilePath -> IO [FilePath]
expand path = do
  isDir <- doesDirectoryExist path
  if not isDir
    then pure [path]
    else do
      entries <- listDirectory path
      pure [path ++ "/" ++ e | e <- sort entries, ".json" `isSuffixOf` e]

-- | 'True' when the file was reported on. Failures go to stderr so stdout
-- stays reports and nothing else.
report :: FilePath -> IO Bool
report path = do
  there <- doesFileExist path
  if not there
    then complain ("no such file: " ++ path)
    else do
      readResult <- (Right <$> BS.readFile path) `catchIOError` (pure . Left . show)
      case readResult of
        Left err -> complain (path ++ ": " ++ err)
        Right bytes -> case loadCircle bytes of
          Left err -> complain (path ++ ": " ++ renderLoadError err)
          Right circle -> case inspectReport circle of
            Left err -> complain (path ++ ": " ++ renderCompileErrorForInspect err)
            Right ls -> do
              putStr (unlines (("# " ++ path) : "" : ls))
              pure True
  where
    complain message = do
      hPutStrLn stderr message
      pure False
