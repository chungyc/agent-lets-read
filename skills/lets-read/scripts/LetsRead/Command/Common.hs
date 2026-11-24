{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : LetsRead.Command.Common
-- Description : Shared helpers for lets-read CLI command modules
--
-- Provides CLI usage text, safe file cleanup, subagent response file and
-- transcript polling, and shared session state accessors used across multiple
-- @lets-read@ subcommands.
module LetsRead.Command.Common
  ( usage
  , removeFileIfExists
  , readNonEmptyFileIfExists
  , firstNonEmptyFile
  , resolveOptionalResponse
  , resolveRequiredResponse
  , resolveCommentaryOrResponse
  , resolveCommentaryOrResponseWithRaw
  , readOptionalMemoryFile
  , currentChunkMetaTuple
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, catch)
import Control.Monad (unless, when)
import Data.Text (Text)
import qualified Data.Text as T
import LetsRead.Memory (parseCombinedResponse)
import LetsRead.Types
  ( ChunkMeta (..)
  , ParsedChunkSummaries
  , SessionState (..)
  , emptyParsedChunkSummaries
  , readTextFileSafe
  )
import LetsRead.Verification (extractSubagentLogResponse)
import System.Directory (doesFileExist, removeFile)
import System.Exit (die)

-- | Full CLI usage and command synopsis printed on @--help@ or argument errors.
usage :: String
usage =
  unlines
    [ "Usage: lets-read <command> [options]"
    , ""
    , "Commands:"
    , "  init <source> --session <dir> [--max-words <n>] [--title <str>] [--persona <str>] [--overwrite]"
    , "  next --session <dir> [--force]"
    , "  script --session <dir> [--response-file <path>] [--subagent-log <path>]"
    , "  research --session <dir> [--response-file <path>] [--subagent-log <path>]"
    , "  record --session <dir> [--response-file <path>] [--subagent-log <path>] [--commentary-file <path>] [--memory-file <path>]"
    , "  judge --session <dir> [--response-file <path>] [--subagent-log <path>] [--fact-check-response-file <path>] [--fact-check-log <path>] [--critic-response-file <path>] [--critic-log <path>] [--topic-response-file <path>] [--topic-log <path>]"
    , "  discuss-prompt --session <dir> [--user-message <str>] [--user-file <path>]"
    , "  discuss --session <dir> [--response-file <path>] [--subagent-log <path>] [--commentary-file <path>] [--user-message <str>] [--user-file <path>] [--memory-file <path>]"
    , "  status --session <dir>"
    ]

-- | Remove a file if it exists on disk, ignoring any 'IOException' (such as
-- concurrent removal).
removeFileIfExists :: FilePath -> IO ()
removeFileIfExists p = do
  exists <- doesFileExist p
  when exists (removeFile p `catch` (\(_ :: IOException) -> pure ()))

-- | Read a UTF-8 text file if it exists and contains non-whitespace characters;
-- returns 'Nothing' if the file does not exist or is blank.
readNonEmptyFileIfExists :: FilePath -> IO (Maybe Text)
readNonEmptyFileIfExists p = do
  exists <- doesFileExist p
  if not exists
    then pure Nothing
    else do
      raw <- readTextFileSafe p
      if T.null (T.strip raw)
        then pure Nothing
        else pure (Just raw)

-- | Return the contents of the first existing, non-empty file in the given list.
firstNonEmptyFile :: [FilePath] -> IO (Maybe Text)
firstNonEmptyFile [] = pure Nothing
firstNonEmptyFile (p : ps) = do
  mTxt <- readNonEmptyFileIfExists p
  case mTxt of
    Just t -> pure (Just t)
    Nothing -> firstNonEmptyFile ps

-- | Resolve an optional subagent response from an explicit @--*-response-file@,
-- a list of default response file paths in the session directory, or a fallback
-- subagent transcript log (polling up to 20 seconds for async flush).
resolveOptionalResponse ::
  -- | Explicit response file path, if passed on the CLI.
  Maybe FilePath ->
  -- | Default response file paths in the session directory to check first.
  [FilePath] ->
  -- | Optional subagent transcript log path or conversation ID for fallback extraction.
  Maybe FilePath ->
  -- | Human-readable subagent label for error reporting.
  String ->
  IO (Maybe Text)
resolveOptionalResponse mExplicit defaultFiles mLog label =
  case mExplicit of
    Just respPath -> do
      exists <- doesFileExist respPath
      unless exists $ die ("Error: " ++ label ++ " response file not found: " ++ respPath)
      raw <- readTextFileSafe respPath
      pure (Just raw)
    Nothing -> poll 80
  where
    tryOnce = do
      mDef <- firstNonEmptyFile defaultFiles
      case mDef of
        Just raw -> pure (Just raw)
        Nothing ->
          case mLog of
            Just logPath -> extractSubagentLogResponse logPath
            Nothing -> pure Nothing
    poll :: Int -> IO (Maybe Text)
    poll retriesLeft = do
      mRes <- tryOnce
      case mRes of
        Just raw -> pure (Just raw)
        Nothing
          | retriesLeft <= 0 -> pure Nothing
          | otherwise -> do
              threadDelay 250000
              poll (retriesLeft - 1)

-- | Like 'resolveOptionalResponse', but terminates with the given error message
-- if no response can be resolved.
resolveRequiredResponse ::
  -- | Explicit response file path, if passed on the CLI.
  Maybe FilePath ->
  -- | Default response file paths in the session directory to check first.
  [FilePath] ->
  -- | Optional subagent transcript log path or conversation ID for fallback extraction.
  Maybe FilePath ->
  -- | Human-readable subagent label for missing-file error reporting.
  String ->
  -- | Fatal error message when no response is found after polling.
  String ->
  IO Text
resolveRequiredResponse mExplicit defaultFiles mLog label errMsg = do
  mRes <- resolveOptionalResponse mExplicit defaultFiles mLog label
  case mRes of
    Just raw -> pure raw
    Nothing -> die errMsg

-- | Resolve and parse a structured reader response (or plain commentary file)
-- into @(mUserQuestion, commentaryText, parsedChunkSummaries, mPredictionUpdates, mUpdatedMemory)@.
resolveCommentaryOrResponse ::
  -- | Explicit @--response-file@ path.
  Maybe FilePath ->
  -- | Explicit @--commentary-file@ path (plain commentary without delimiter sections).
  Maybe FilePath ->
  -- | Default response file paths in the session directory.
  [FilePath] ->
  -- | Optional @--subagent-log@ path or conversation ID.
  Maybe FilePath ->
  -- | Subagent label for error messages.
  String ->
  -- | Error message if no response source is available.
  String ->
  IO (Maybe Text, Text, ParsedChunkSummaries, Maybe Text, Maybe Text)
resolveCommentaryOrResponse mRespFile mCommFile defaultFiles mLog label errMsg = do
  (_, mUser, comm, sums, mPreds, mMem) <-
    resolveCommentaryOrResponseWithRaw mRespFile mCommFile defaultFiles mLog label errMsg
  pure (mUser, comm, sums, mPreds, mMem)

-- | Like 'resolveCommentaryOrResponse', also returning the raw unparsed response
-- text so callers can inspect structured @<!-- TOOLS: ... -->@ metadata before
-- cleanup.
resolveCommentaryOrResponseWithRaw ::
  Maybe FilePath ->
  Maybe FilePath ->
  [FilePath] ->
  Maybe FilePath ->
  String ->
  String ->
  IO (Text, Maybe Text, Text, ParsedChunkSummaries, Maybe Text, Maybe Text)
resolveCommentaryOrResponseWithRaw mRespFile mCommFile defaultFiles mLog label errMsg =
  case (mRespFile, mCommFile) of
    (Nothing, Just commPath) -> do
      exists <- doesFileExist commPath
      unless exists $ die ("Error: Commentary file not found: " ++ commPath)
      raw <- readTextFileSafe commPath
      pure (raw, Nothing, T.strip raw, emptyParsedChunkSummaries, Nothing, Nothing)
    _ -> do
      raw <- resolveRequiredResponse mRespFile defaultFiles mLog label errMsg
      let (mUser, comm, sums, mPreds, mMem) = parseCombinedResponse raw
      pure (raw, mUser, comm, sums, mPreds, mMem)

-- | Read and strip an optional @--memory-file@ override, failing if the
-- specified path does not exist and returning 'Nothing' if omitted or blank.
readOptionalMemoryFile :: Maybe FilePath -> IO (Maybe Text)
readOptionalMemoryFile Nothing = pure Nothing
readOptionalMemoryFile (Just memPath) = do
  exists <- doesFileExist memPath
  unless exists $ die ("Error: Memory file not found: " ++ memPath)
  txt <- readTextFileSafe memPath
  let stripped = T.strip txt
  pure (if T.null stripped then Nothing else Just stripped)

-- | Extract @(chapterNumber, chapterTitle, partInChapter, partsInChapter)@ from
-- the currently unlocked chunk metadata in 'SessionState', with a safe fallback.
currentChunkMetaTuple :: SessionState -> (Int, Text, Int, Int)
currentChunkMetaTuple st =
  case stCurrentMeta st of
    Just m -> (metaChapterNumber m, metaChapterTitle m, metaPartInChapter m, metaPartsInChapter m)
    Nothing -> (1, "Chapter ?", 1, 1)
