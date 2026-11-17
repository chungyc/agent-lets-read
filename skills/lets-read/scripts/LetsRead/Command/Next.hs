{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : LetsRead.Command.Next
-- Description : Handler and CLI parser for the 'next' subcommand
--
-- Enforces turn-ordering gates (requiring the current chunk to be recorded,
-- judged, and any pending fact-check peer query to be resolved unless @--force@
-- is passed) and unlocks either the next story chunk from @.vault.bin@ or,
-- once all story chunks are completed, the Final Wrapup & Retrospective prompt.
module LetsRead.Command.Next
  ( parseNextArgs
  , cmdNext
  ) where

import Control.Monad (when)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (computeShouldRotate)
import LetsRead.Command.Common (removeFileIfExists, usage)
import LetsRead.Predictions (countActivePredictions)
import LetsRead.Prompts
  ( writeCurrentChunkFile
  , writeCurrentPromptFile
  , writeWrapupPromptFile
  )
import LetsRead.Types
  ( Chunk (..)
  , SessionState (..)
  , chunkToMeta
  , jsonBool
  , jsonInt
  , jsonObject
  , jsonStr
  , loadState
  , loadVaultChunk
  , orchestratorRuleText
  , padChunkNumber
  , saveState
  )
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  )
import System.Exit (die)
import System.FilePath ((</>))

-- | Parse CLI arguments for the @next@ subcommand, returning @(sessionDir, forceFlag)@.
parseNextArgs :: [String] -> IO (FilePath, Bool)
parseNextArgs = go ("", False)
  where
    go (sess, frc) []
      | null sess = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure (sess, frc)
    go (_, frc) ("--session" : v : rest) = go (v, frc) rest
    go (sess, _) ("--force" : rest) = go (sess, True) rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

-- | Execute the @next@ subcommand: validate that the previous turn completed
-- (or @--force@ was specified), unlock the next chunk or Final Wrapup prompt,
-- write @current_chunk.md@ and @current_prompt.md@, and emit a JSON status object.
cmdNext ::
  -- | Path to the session directory.
  FilePath ->
  -- | Whether @--force@ was passed to bypass turn-completion gates.
  Bool ->
  IO ()
cmdNext rawSessionDir forceFlag = do
  sessionDir <- canonicalizePath rawSessionDir
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
      totalChunks = stTotalChunks st
      questionsPath = sessionDir </> "current_fact_check_questions.md"
      discPromptPath = sessionDir </> "current_discussion_prompt.md"
      topicPromptPath = sessionDir </> "current_topic_prompt.md"

  when (curIdx > 0 && not (stCurrentRecorded st) && not forceFlag) $
    die $
      "Error: Chunk "
        ++ show curIdx
        ++ " is already unlocked, but its commentary has not been recorded yet. "
        ++ "Run 'record' and 'judge' first (or pass --force to override)."

  when (curIdx > 0 && stCurrentRecorded st && not (stCurrentJudged st) && not forceFlag) $
    die $
      "Error: Chunk "
        ++ show curIdx
        ++ " commentary has been recorded, but prediction-judge verdicts have not been recorded yet. "
        ++ "Run 'judge' first (or pass --force to override)."

  hasFactCheckPending <- doesFileExist questionsPath
  when (curIdx > 0 && hasFactCheckPending && not forceFlag) $
    die $
      "Error: Chunk "
        ++ show curIdx
        ++ " has a pending Fact-Check Peer Query in "
        ++ discPromptPath
        ++ ". Notify blind-reader via send_message to read current_discussion_prompt.md and write current_discussion_response.md, then record the response with 'lets-read discuss --session <dir> --subagent-log <reader_log>' before running 'next' (or pass --force to override)."

  when forceFlag $ do
    when hasFactCheckPending $ do
      removeFileIfExists questionsPath
      removeFileIfExists discPromptPath
    removeFileIfExists topicPromptPath

  let readerRespPath = sessionDir </> "current_reader_response.md"
      discRespPath = sessionDir </> "current_discussion_response.md"
  removeFileIfExists readerRespPath
  removeFileIfExists discRespPath

  if curIdx >= totalChunks
    then do
      let wrapupPath = sessionDir </> "entries" </> "wrapup.md"
      hasWrapup <- doesFileExist wrapupPath
      if not hasWrapup || forceFlag
        then do
          promptFile <- writeWrapupPromptFile sessionDir st
          TIO.putStrLn $
            jsonObject
              [ ("status", jsonStr "wrapup_unlocked")
              , ("current_index", jsonInt curIdx)
              , ("total_chunks", jsonInt totalChunks)
              , ("subagent_prompt_file", jsonStr (T.pack promptFile))
              , ("reader_response_file", jsonStr (T.pack readerRespPath))
              , ("hall_of_fame_file", jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")))
              , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
              , ("entries_dir", jsonStr (T.pack (sessionDir </> "entries")))
              , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
              , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
              , ("orchestrator_rule", jsonStr orchestratorRuleText)
              , ("next_step_hint", jsonStr "Send a 1-line notification to blind-reader to read subagent_prompt_file and write reader_response_file for the Final Wrapup & Retrospective, then record with 'lets-read record --session <dir> --subagent-log <reader_log>'.")
              ]
        else
          TIO.putStrLn $
            jsonObject
              [ ("status", jsonStr "finished")
              , ("current_index", jsonInt curIdx)
              , ("total_chunks", jsonInt totalChunks)
              , ("wrapup_file", jsonStr (T.pack wrapupPath))
              , ("hall_of_fame_file", jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")))
              , ("orchestrator_rule", jsonStr orchestratorRuleText)
              , ("message", jsonStr "All chunks and the Final Wrapup have been completed! The Let's Read is complete.")
              ]
    else do
      let nextIdx = curIdx + 1
          activeCount = countActivePredictions (stPredictions st)
      chunk <- loadVaultChunk (sessionDir </> ".vault.bin") nextIdx
      let chunkFile = sessionDir </> "current_chunk.md"
          chunksDir = sessionDir </> "chunks"
          archiveChunkFile = chunksDir </> ("chunk_" ++ padChunkNumber nextIdx ++ ".md")
      createDirectoryIfMissing True chunksDir
      writeCurrentChunkFile chunkFile chunk totalChunks (stTotalChapters st) activeCount
      writeCurrentChunkFile archiveChunkFile chunk totalChunks (stTotalChapters st) activeCount
      promptFile <- writeCurrentPromptFile sessionDir st chunk activeCount

      let meta = chunkToMeta chunk
          st' =
            st
              { stCurrentIndex = nextIdx
              , stCurrentRecorded = False
              , stCurrentJudged = False
              , stCurrentMeta = Just meta
              , stPendingRetirements = []
              , stPendingLinterWarnings = []
              }
      saveState sessionDir st'

      let shouldRotate = computeShouldRotate (stStoryRecords st) chunk
      TIO.putStrLn $
        jsonObject
          [ ("status", jsonStr "unlocked")
          , ("chunk_index", jsonInt (chunkIndex chunk))
          , ("total_chunks", jsonInt totalChunks)
          , ("chapter_number", jsonInt (chapterNumber chunk))
          , ("total_chapters", jsonInt (stTotalChapters st))
          , ("chapter_title", jsonStr (chapterTitle chunk))
          , ("part_in_chapter", jsonInt (partInChapter chunk))
          , ("parts_in_chapter", jsonInt (partsInChapter chunk))
          , ("is_chapter_start", jsonBool (isChapterStart chunk))
          , ("is_chapter_end", jsonBool (isChapterEnd chunk))
          , ("word_count", jsonInt (wordCount chunk))
          , ("active_predictions_count", jsonInt activeCount)
          , ("current_chunk_file", jsonStr (T.pack chunkFile))
          , ("subagent_prompt_file", jsonStr (T.pack promptFile))
          , ("reader_response_file", jsonStr (T.pack readerRespPath))
          , ("chunk_archive_file", jsonStr (T.pack archiveChunkFile))
          , ("chunks_dir", jsonStr (T.pack chunksDir))
          , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
          , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
          , ("entries_dir", jsonStr (T.pack (sessionDir </> "entries")))
          , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
          , ("rotate_reader_recommended", jsonBool shouldRotate)
          , ("rotate_subagent_recommended", jsonBool shouldRotate)
          , ("orchestrator_rule", jsonStr orchestratorRuleText)
          ]
