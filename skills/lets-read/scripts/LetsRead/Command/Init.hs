{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : LetsRead.Command.Init
-- Description : Handler and CLI parser for the 'init' subcommand
--
-- Ingests a story source file (@.txt@, @.md@, @.html@, or @.epub@), splits it
-- into chapter/part chunks, obfuscates and writes the chunk vault (@.vault.bin@),
-- initializes the session directory hierarchy and @.state.bin@, and writes the
-- initial @memory.md@ and @lets_read_log.md@ files.
module LetsRead.Command.Init
  ( InitOptions (..)
  , parseInitArgs
  , cmdInit
  ) where

import Control.Monad (unless, when)
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (buildChunksFromSource)
import LetsRead.Command.Common (usage)
import LetsRead.Memory (defaultCuratedMemory, syncMemoryAndArchives)
import LetsRead.Prompts (resolvePersonaPresetIO)
import LetsRead.Types
  ( Chunk (..)
  , SessionState (..)
  , jsonInt
  , jsonObject
  , jsonStr
  , orchestratorRuleText
  , saveState
  , saveVault
  , wrapMarkdownParagraph
  )
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  )
import System.Exit (die)
import System.FilePath ((</>))

-- | Command-line options for @lets-read init@.
data InitOptions = InitOptions
  { initSource :: FilePath
  -- ^ Path to the input story file (@.txt@, @.md@, @.html@, or @.epub@).
  , initSession :: FilePath
  -- ^ Target session directory where vault, state, and logs will be stored.
  , initMaxWords :: Int
  -- ^ Target maximum words per chunk (default: 1500, must be > 50).
  , initTitle :: Maybe Text
  -- ^ Optional story title override (defaults to title inferred from source).
  , initPersona :: Maybe Text
  -- ^ Optional reader persona name or custom description.
  , initOverwrite :: Bool
  -- ^ Whether to overwrite existing @memory.md@ and @lets_read_log.md@ files.
  }

-- | Parse CLI arguments for the @init@ subcommand.
parseInitArgs :: [String] -> IO InitOptions
parseInitArgs = go (InitOptions "" "" 1500 Nothing Nothing False)
  where
    go opts []
      | null (initSource opts) = die ("Error: Missing <source> path.\n\n" ++ usage)
      | null (initSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {initSession = v} rest
    go opts ("--max-words" : v : rest) =
      case reads v of
        [(n, "")] | n > 50 -> go opts {initMaxWords = n} rest
        _ -> die ("Error: Invalid --max-words value: " ++ v)
    go opts ("--title" : v : rest) = go opts {initTitle = Just (T.pack v)} rest
    go opts ("--persona" : v : rest) = go opts {initPersona = Just (T.pack v)} rest
    go opts ("--overwrite" : rest) = go opts {initOverwrite = True} rest
    go opts (arg : rest)
      | "-" `isPrefixOf` arg = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)
      | null (initSource opts) = go opts {initSource = arg} rest
      | otherwise = die ("Error: Unexpected argument: " ++ arg ++ "\n\n" ++ usage)

-- | Execute the @init@ subcommand: chunk the source text, populate the session
-- directory structure, save the obfuscated vault and initial state, and emit
-- a JSON summary to stdout.
cmdInit :: InitOptions -> IO ()
cmdInit opts = do
  srcExists <- doesFileExist (initSource opts)
  unless srcExists $
    die ("Error: Source file not found: " ++ initSource opts)

  createDirectoryIfMissing True (initSession opts)
  sessionDir <- canonicalizePath (initSession opts)
  let entriesDir = sessionDir </> "entries"
      chunksDir = sessionDir </> "chunks"
      archiveDir = sessionDir </> "archive"
      predictionsDir = sessionDir </> "predictions"
  createDirectoryIfMissing True (entriesDir </> "archive" </> "chronology")
  createDirectoryIfMissing True (entriesDir </> "archive" </> "topics")
  createDirectoryIfMissing True (chunksDir </> "archive" </> "chronology")
  createDirectoryIfMissing True (chunksDir </> "archive" </> "topics")
  createDirectoryIfMissing True (archiveDir </> "memory")
  createDirectoryIfMissing True (predictionsDir </> "archive" </> "chronology")
  createDirectoryIfMissing True (predictionsDir </> "archive" </> "topics")

  (bookTitle, chunks) <- buildChunksFromSource (initSource opts) (initMaxWords opts) (initTitle opts)
  persona <- resolvePersonaPresetIO (initPersona opts)

  let totalChunks = length chunks
      totalChapters = max 1 (maximum (map chapterNumber chunks))
      totalWords = sum (map wordCount chunks)

  saveVault (sessionDir </> ".vault.bin") chunks

  let st =
        SessionState
          { stTitle = bookTitle
          , stPersona = persona
          , stMaxWords = initMaxWords opts
          , stTotalChunks = totalChunks
          , stTotalChapters = totalChapters
          , stTotalWords = totalWords
          , stCurrentIndex = 0
          , stCurrentRecorded = True
          , stCurrentJudged = True
          , stCurrentMeta = Nothing
          , stCompletedChunks = []
          , stStoryRecords = []
          , stEntryRecords = []
          , stCuratedMemory = defaultCuratedMemory
          , stPredictions = []
          , stPendingRetirements = []
          , stPendingLinterWarnings = []
          , stLastJudgeSummary = []
          , stPredictionAuditWarnings = []
          , stCuratedTopics = []
          , stTopicAliases = []
          }
  saveState sessionDir st

  let memoryPath = sessionDir </> "memory.md"
  memExists <- doesFileExist memoryPath
  when (not memExists || initOverwrite opts) $ do
    _ <- syncMemoryAndArchives sessionDir st
    pure ()

  let logPath = sessionDir </> "lets_read_log.md"
  logExists <- doesFileExist logPath
  when (not logExists || initOverwrite opts) $
    TIO.writeFile
      logPath
      ( "# Let's Read: "
          <> bookTitle
          <> "\n\n## Reader Persona\n\n"
          <> wrapMarkdownParagraph 78 persona
          <> "\n\n---\n\n"
      )

  let avgWords = if totalChunks > 0 then totalWords `div` totalChunks else 0
  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "initialized")
      , ("title", jsonStr bookTitle)
      , ("session_dir", jsonStr (T.pack sessionDir))
      , ("total_chapters", jsonInt totalChapters)
      , ("total_chunks", jsonInt totalChunks)
      , ("total_words", jsonInt totalWords)
      , ("avg_words_per_chunk", jsonInt avgWords)
      , ("chunks_dir", jsonStr (T.pack chunksDir))
      , ("entries_dir", jsonStr (T.pack entriesDir))
      , ("archive_dir", jsonStr (T.pack archiveDir))
      , ("predictions_dir", jsonStr (T.pack predictionsDir))
      , ("memory_file", jsonStr (T.pack memoryPath))
      , ("log_file", jsonStr (T.pack logPath))
      , ("orchestrator_rule", jsonStr orchestratorRuleText)
      , ("message", jsonStr "Session initialized. Run 'next' to unlock Chunk 1.")
      ]
