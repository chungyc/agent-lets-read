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
  , writeCurrentScriptPromptFile
  , writeWrapupScriptPromptFile
  )
import LetsRead.Types
  ( Chunk (..)
  , SessionFileStatus (..)
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
  , readSessionFileStatus
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
      scriptPromptPath = sessionDir </> "current_script_prompt.md"
      scriptRespPath = sessionDir </> "current_script_response.md"
      researchPromptPath = sessionDir </> "current_research_prompt.md"
      researchRespPath = sessionDir </> "current_research_response.md"
      researchFilePath = sessionDir </> "current_research.md"
      readerPromptPath = sessionDir </> "current_prompt.md"

  sfs <- readSessionFileStatus sessionDir
  let hasScriptPrompt = sfsHasScriptPrompt sfs
      hasResearchPrompt = sfsHasResearchPrompt sfs
      hasWrapupReaderPrompt = sfsHasWrapupReaderPrompt sfs

  when (curIdx > 0 && not (stCurrentRecorded st) && not forceFlag) $
    if hasScriptPrompt
      then
        die $
          "Error: Chunk "
            ++ show curIdx
            ++ " is already unlocked and awaiting script-writer. "
            ++ "Run 'script', 'research', 'record', and 'judge' first (or pass --force to override)."
      else
        if hasResearchPrompt
          then
            die $
              "Error: Chunk "
                ++ show curIdx
                ++ " is awaiting researcher. "
                ++ "Run 'research', 'record', and 'judge' first (or pass --force to override)."
          else
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

  when (curIdx >= totalChunks && stCurrentRecorded st && stCurrentJudged st && not forceFlag) $ do
    hasWrapup <- doesFileExist (sessionDir </> "entries" </> "wrapup.md")
    when (not hasWrapup) $ do
      when hasScriptPrompt $
        die "Error: Final Wrapup is already unlocked and awaiting script-writer. Run 'script', 'research', and 'record' first (or pass --force to override)."
      when hasResearchPrompt $
        die "Error: Final Wrapup is awaiting researcher. Run 'research' and 'record' first (or pass --force to override)."
      when hasWrapupReaderPrompt $
        die "Error: Final Wrapup is already unlocked and awaiting blind-reader. Run 'record' first (or pass --force to override)."

  when forceFlag $ do
    when hasFactCheckPending $ do
      removeFileIfExists questionsPath
      removeFileIfExists discPromptPath
    removeFileIfExists topicPromptPath

  let readerRespPath = sessionDir </> "current_reader_response.md"
      discRespPath = sessionDir </> "current_discussion_response.md"
  removeFileIfExists scriptPromptPath
  removeFileIfExists scriptRespPath
  removeFileIfExists researchPromptPath
  removeFileIfExists researchRespPath
  removeFileIfExists researchFilePath
  removeFileIfExists readerPromptPath
  removeFileIfExists readerRespPath
  removeFileIfExists discRespPath

  if curIdx >= totalChunks
    then do
      let wrapupPath = sessionDir </> "entries" </> "wrapup.md"
      hasWrapup <- doesFileExist wrapupPath
      if not hasWrapup || forceFlag
        then do
          scriptPromptFile <- writeWrapupScriptPromptFile sessionDir st
          saveState sessionDir st
          TIO.putStrLn $
            jsonObject
              [ ("status", jsonStr "awaiting_script")
              , ("is_wrapup", jsonBool True)
              , ("current_index", jsonInt curIdx)
              , ("total_chunks", jsonInt totalChunks)
              , ("script_prompt_file", jsonStr (T.pack scriptPromptFile))
              , ("script_response_file", jsonStr (T.pack scriptRespPath))
              , ("hall_of_fame_file", jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")))
              , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
              , ("entries_dir", jsonStr (T.pack (sessionDir </> "entries")))
              , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
              , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
              , ("orchestrator_rule", jsonStr orchestratorRuleText)
              , ("next_step_hint", jsonStr "Invoke a fresh one-shot script-writer subagent with a 1-line notification to read script_prompt_file and write script_response_file for the Final Wrapup draft, then STOP and end your turn with ZERO tool calls until script-writer sends its idle completion notice (never emit 'Waiting...' text alongside 'script'); only after its idle notice arrives, run 'lets-read script --session <dir> --subagent-log <script_log>'.")
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
      writeCurrentChunkFile chunkFile chunk totalChunks (stTotalChapters st)
      writeCurrentChunkFile archiveChunkFile chunk totalChunks (stTotalChapters st)
      scriptPromptFile <- writeCurrentScriptPromptFile sessionDir st chunk

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
          unlockHint =
            "Invoke a fresh one-shot script-writer subagent with a 1-line notification to read script_prompt_file and write script_response_file, then STOP and end your turn with ZERO tool calls until script-writer sends its idle completion notice (never emit 'Waiting...' alongside 'script'); only after its idle notice arrives, run 'lets-read script --session <dir> --subagent-log <script_log>'."
      TIO.putStrLn $
        jsonObject
          [ ("status", jsonStr "awaiting_script")
          , ("is_wrapup", jsonBool False)
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
          , ("script_prompt_file", jsonStr (T.pack scriptPromptFile))
          , ("script_response_file", jsonStr (T.pack scriptRespPath))
          , ("subagent_prompt_file", jsonStr (T.pack readerPromptPath))
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
          , ("next_step_hint", jsonStr unlockHint)
          ]
