{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : LetsRead.Command.Research
-- Description : Handler and CLI parser for the 'research' subcommand
--
-- Audits @lets-read-researcher@'s verbatim quotes and @search_web@ receipts against
-- primary session files and tool telemetry, immediately deletes
-- @current_research_prompt.md@ and @current_research_response.md@ (removing the
-- embedded script draft from disk), writes the neutral @current_research.md@
-- reference packet, and unlocks @current_prompt.md@ for @lets-read-blind-reader@.
module LetsRead.Command.Research
  ( ResearchOptions (..)
  , parseResearchArgs
  , cmdResearch
  ) where

import Control.Monad (when)
import Data.Maybe (isNothing)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (computeShouldRotate)
import LetsRead.Command.Common
  ( removeFileIfExists
  , resolveRequiredResponse
  , usage
  )
import LetsRead.Predictions (countActivePredictions)
import LetsRead.Prompts
  ( writeCurrentPromptFile
  , writeWrapupPromptFile
  )
import LetsRead.Types
  ( SessionFileStatus (..)
  , SessionState (..)
  , StoryChunkRecord (..)
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
import LetsRead.Verification
  ( parseResearchNotesSection
  , renderCurrentResearchMarkdown
  , resolveSubagentToolAudit
  , verifyAndFilterResearchBullets
  )
import System.Directory (canonicalizePath)
import System.Exit (die)
import System.FilePath ((</>))

-- | Command-line options for @lets-read research@.
data ResearchOptions = ResearchOptions
  { resOptSession :: FilePath
  -- ^ Target session directory.
  , resOptResponseFile :: Maybe FilePath
  -- ^ Optional explicit path to the @lets-read-researcher@ response file.
  , resOptSubagentLog :: Maybe FilePath
  -- ^ Optional path or conversation ID for the @lets-read-researcher@ transcript log.
  }

-- | Parse CLI arguments for the @research@ subcommand.
parseResearchArgs :: [String] -> IO ResearchOptions
parseResearchArgs = go (ResearchOptions "" Nothing Nothing)
  where
    go opts []
      | null (resOptSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {resOptSession = v} rest
    go opts ("--response-file" : v : rest) = go opts {resOptResponseFile = Just v} rest
    go opts ("--subagent-log" : v : rest) = go opts {resOptSubagentLog = Just v} rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

-- | Execute the @research@ subcommand: verify @lets-read-researcher@'s notes against disk
-- and tool receipts, delete @current_research_prompt.md@ and
-- @current_research_response.md@, write @current_research.md@ and
-- @current_prompt.md@ for @lets-read-blind-reader@, update @state.json@, and emit JSON.
cmdResearch :: ResearchOptions -> IO ()
cmdResearch opts = do
  sessionDir <- canonicalizePath (resOptSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
      totalChunks = stTotalChunks st
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."

  let isWrapupTurn = curIdx >= totalChunks && stCurrentRecorded st && stCurrentJudged st
      scriptPromptPath = sessionDir </> "current_script_prompt.md"
      scriptRespPath = sessionDir </> "current_script_response.md"
      researchPromptPath = sessionDir </> "current_research_prompt.md"
      researchRespPath = sessionDir </> "current_research_response.md"
      researchFilePath = sessionDir </> "current_research.md"
      readerRespPath = sessionDir </> "current_reader_response.md"

  when (not isWrapupTurn && stCurrentRecorded st) $
    die "Error: Current chunk commentary has already been recorded. Run 'judge' or 'next' instead."

  sfs <- readSessionFileStatus sessionDir
  let hasScriptPrompt = sfsHasScriptPrompt sfs
      hasResearchPrompt = sfsHasResearchPrompt sfs
      hasActiveReaderPrompt =
        if isWrapupTurn
          then sfsHasWrapupReaderPrompt sfs
          else sfsHasReaderPrompt sfs

  when (hasScriptPrompt && isNothing (resOptResponseFile opts)) $
    die "Error: lets-read-script-writer step has not completed yet (current_script_prompt.md is still active). Wait for lets-read-script-writer and run 'lets-read script' before 'research'."

  when (not hasResearchPrompt && isNothing (resOptResponseFile opts)) $ do
    when hasActiveReaderPrompt $
      die "Error: 'research' has already completed and current_prompt.md is active. Wait for lets-read-blind-reader and run 'lets-read record' next."
    die "Error: No active current_research_prompt.md found. Run 'lets-read next' and 'lets-read script' first."

  let curPad = T.pack (padChunkNumber curIdx)
      roundTag = if isWrapupTurn then "Wrapup" else "Chunk " <> curPad
      roundTagStr = T.unpack roundTag

  rawResearch <-
    resolveRequiredResponse
      (resOptResponseFile opts)
      [researchRespPath]
      (resOptSubagentLog opts)
      "Researcher"
      ( "Error: current_research_response.md has not been written yet (lets-read-researcher is still running). Do not re-message lets-read-researcher; end your turn with ZERO tool calls outputting ONLY '[HOST_WAIT | "
          ++ roundTagStr
          ++ " | research | 0/1 idle | pending: lets-read-researcher]' and wait for '[SUBAGENT_DONE | "
          ++ roundTagStr
          ++ " | lets-read-researcher]' before running 'research'."
      )

  researchAudit <- resolveSubagentToolAudit (resOptSubagentLog opts) (Just rawResearch)
  let rawBullets = parseResearchNotesSection rawResearch
  (verifiedNotes, rejectedCount) <-
    verifyAndFilterResearchBullets sessionDir curIdx isWrapupTurn researchAudit rawBullets

  removeFileIfExists scriptPromptPath
  removeFileIfExists scriptRespPath
  removeFileIfExists researchPromptPath
  removeFileIfExists researchRespPath
  removeFileIfExists readerRespPath

  let renderedResearch = renderCurrentResearchMarkdown sessionDir curIdx isWrapupTurn verifiedNotes
  TIO.writeFile researchFilePath renderedResearch

  if isWrapupTurn
    then do
      promptFile <- writeWrapupPromptFile sessionDir st
      saveState sessionDir st
      TIO.putStrLn $
        jsonObject
          [ ("status", jsonStr "wrapup_unlocked")
          , ("is_wrapup", jsonBool True)
          , ("current_index", jsonInt curIdx)
          , ("total_chunks", jsonInt totalChunks)
          , ("subagent_prompt_file", jsonStr (T.pack promptFile))
          , ("reader_response_file", jsonStr (T.pack readerRespPath))
          , ("research_file", jsonStr (T.pack researchFilePath))
          , ("verified_research_notes_count", jsonInt (length verifiedNotes))
          , ("rejected_research_notes_count", jsonInt rejectedCount)
          , ("research_prompt_deleted", jsonBool True)
          , ("hall_of_fame_file", jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")))
          , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
          , ("entries_dir", jsonStr (T.pack (sessionDir </> "entries")))
          , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
          , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
          , ("orchestrator_rule", jsonStr orchestratorRuleText)
          , ("next_step_hint", jsonStr "Kill the finished one-shot lets-read-researcher immediately via manage_subagents(Action: \"kill\"), send a 1-line notification to lets-read-blind-reader (via send_message, or invoke_subagent if no lets-read-blind-reader is active) to read subagent_prompt_file and write reader_response_file for the Final Wrapup & Retrospective, then park with ZERO tool calls outputting ONLY '[HOST_WAIT | Wrapup | record | 0/1 idle | pending: lets-read-blind-reader]'; once '[SUBAGENT_DONE | Wrapup | lets-read-blind-reader]' arrives, run 'lets-read record --session <dir> --subagent-log <reader_log>'.")
          ]
    else do
      let activeCount = countActivePredictions (stPredictions st)
          priorStory = [e | e <- stStoryRecords st, scrChunkIndex e < curIdx]
      chunk <- loadVaultChunk (sessionDir </> ".vault.bin") curIdx
      promptFile <- writeCurrentPromptFile sessionDir st chunk
      saveState sessionDir st
      let shouldRotate = computeShouldRotate priorStory chunk
          unlockHint =
            if shouldRotate
              then
                "Kill the finished one-shot lets-read-researcher via manage_subagents(Action: \"kill\"), and because rotate_reader_recommended is true, also kill the previous lets-read-blind-reader via manage_subagents(Action: \"kill\") and invoke a fresh lets-read-blind-reader with a 1-line notification to read subagent_prompt_file and write reader_response_file, then park with ZERO tool calls outputting ONLY '[HOST_WAIT | Chunk "
                  <> curPad
                  <> " | record | 0/1 idle | pending: lets-read-blind-reader]'; once '[SUBAGENT_DONE | Chunk "
                  <> curPad
                  <> " | lets-read-blind-reader]' arrives, run 'lets-read record --session <dir> --subagent-log <reader_log>'."
              else
                "Kill the finished one-shot lets-read-researcher immediately via manage_subagents(Action: \"kill\"), send a 1-line notification to lets-read-blind-reader (via send_message, or invoke_subagent on Chunk 1 or if no lets-read-blind-reader is active) to read subagent_prompt_file and write reader_response_file, then park with ZERO tool calls outputting ONLY '[HOST_WAIT | Chunk "
                  <> curPad
                  <> " | record | 0/1 idle | pending: lets-read-blind-reader]'; once '[SUBAGENT_DONE | Chunk "
                  <> curPad
                  <> " | lets-read-blind-reader]' arrives, run 'lets-read record --session <dir> --subagent-log <reader_log>'."
      TIO.putStrLn $
        jsonObject
          [ ("status", jsonStr "unlocked")
          , ("is_wrapup", jsonBool False)
          , ("chunk_index", jsonInt curIdx)
          , ("total_chunks", jsonInt totalChunks)
          , ("active_predictions_count", jsonInt activeCount)
          , ("current_chunk_file", jsonStr (T.pack (sessionDir </> "current_chunk.md")))
          , ("subagent_prompt_file", jsonStr (T.pack promptFile))
          , ("reader_response_file", jsonStr (T.pack readerRespPath))
          , ("research_file", jsonStr (T.pack researchFilePath))
          , ("verified_research_notes_count", jsonInt (length verifiedNotes))
          , ("rejected_research_notes_count", jsonInt rejectedCount)
          , ("research_prompt_deleted", jsonBool True)
          , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
          , ("rotate_reader_recommended", jsonBool shouldRotate)
          , ("orchestrator_rule", jsonStr orchestratorRuleText)
          , ("next_step_hint", jsonStr unlockHint)
          ]
