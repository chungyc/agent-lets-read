{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : LetsRead.Command.Judge
-- Description : Handler and CLI parser for the 'judge' subcommand
--
-- Collects and applies verdicts from @prediction-judge@, receipt-verified
-- queries from @fact-checker@, persona/style feedback from @commentary-critic@,
-- and optional taxonomy merges from @topic-curator@. Appends the Prediction
-- Referee callout to the recorded chunk entry, updates @critic_feedback.md@
-- and @current_discussion_prompt.md@ (if fact-check peer queries were raised),
-- and synchronizes all multi-layer indexes.
module LetsRead.Command.Judge
  ( JudgeOptions (..)
  , parseJudgeArgs
  , cmdJudge
  ) where

import Control.Monad (unless, when)
import Data.List (sortOn)
import Data.Maybe (isJust)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Command.Common
  ( currentChunkMetaTuple
  , removeFileIfExists
  , resolveOptionalResponse
  , resolveRequiredResponse
  , usage
  )
import LetsRead.Index
  ( applyTopicAliases
  , applyTopicCuratorResponse
  )
import LetsRead.Memory
  ( rebuildMasterLog
  , stripTrailingEntryRule
  , syncMemoryAndArchives
  )
import LetsRead.Predictions
  ( applyJudgeVerdictsWithFeedback
  , countActivePredictions
  , formatAuditEntryCallout
  , formatJudgeCallout
  , stripExistingJudgeCallout
  )
import LetsRead.Types
  ( PredictionRecord (..)
  , PredictionStatus (..)
  , SessionState (..)
  , jsonBool
  , jsonInt
  , jsonObject
  , jsonStr
  , loadState
  , orchestratorRuleText
  , padChunkNumber
  , readTextFileSafe
  , saveState
  )
import LetsRead.Verification
  ( SubagentToolAudit (..)
  , processCriticFeedbackWithAudit
  , resolveSubagentToolAudit
  )
import System.Directory
  ( canonicalizePath
  , doesFileExist
  )
import System.Exit (die)
import System.FilePath ((</>))

-- | Command-line options for @lets-read judge@.
data JudgeOptions = JudgeOptions
  { jdgSession :: FilePath
  -- ^ Target session directory.
  , jdgResponseFile :: Maybe FilePath
  -- ^ Optional explicit path to the @prediction-judge@ response file.
  , jdgSubagentLog :: Maybe FilePath
  -- ^ Optional path or conversation ID for the @prediction-judge@ transcript log.
  , jdgFactCheckResponseFile :: Maybe FilePath
  -- ^ Optional explicit path to the @fact-checker@ response file.
  , jdgFactCheckLog :: Maybe FilePath
  -- ^ Optional path or conversation ID for the @fact-checker@ transcript log.
  , jdgCriticResponseFile :: Maybe FilePath
  -- ^ Optional explicit path to the @commentary-critic@ response file.
  , jdgCriticLog :: Maybe FilePath
  -- ^ Optional path or conversation ID for the @commentary-critic@ transcript log.
  , jdgTopicResponseFile :: Maybe FilePath
  -- ^ Optional explicit path to the @topic-curator@ response file.
  , jdgTopicLog :: Maybe FilePath
  -- ^ Optional path or conversation ID for the @topic-curator@ transcript log.
  }

-- | Parse CLI arguments for the @judge@ subcommand.
parseJudgeArgs :: [String] -> IO JudgeOptions
parseJudgeArgs = go (JudgeOptions "" Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing)
  where
    go opts []
      | null (jdgSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {jdgSession = v} rest
    go opts ("--response-file" : v : rest) = go opts {jdgResponseFile = Just v} rest
    go opts ("--subagent-log" : v : rest) = go opts {jdgSubagentLog = Just v} rest
    go opts ("--fact-check-response-file" : v : rest) = go opts {jdgFactCheckResponseFile = Just v} rest
    go opts ("--fact-check-log" : v : rest) = go opts {jdgFactCheckLog = Just v} rest
    go opts ("--critic-response-file" : v : rest) = go opts {jdgCriticResponseFile = Just v} rest
    go opts ("--critic-log" : v : rest) = go opts {jdgCriticLog = Just v} rest
    go opts ("--topic-response-file" : v : rest) = go opts {jdgTopicResponseFile = Just v} rest
    go opts ("--topic-log" : v : rest) = go opts {jdgTopicLog = Just v} rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

-- | Execute the @judge@ subcommand: resolve responses from all peer reviewers,
-- verify fact-checker receipts and web-search usage, apply prediction verdicts
-- and conditional retirements, apply optional topic-curator merges, update the
-- recorded chunk entry and session archives, and emit a JSON status summary.
cmdJudge :: JudgeOptions -> IO ()
cmdJudge opts = do
  sessionDir <- canonicalizePath (jdgSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."
  unless (stCurrentRecorded st) $
    die "Error: Current chunk commentary has not been recorded yet. Run 'record' before 'judge'."

  rawJudge <-
    resolveRequiredResponse
      (jdgResponseFile opts)
      [sessionDir </> "current_judge_response.md"]
      (jdgSubagentLog opts)
      "Judge"
      "Error: current_judge_response.md has not been written yet (prediction-judge is still running). Do not re-message working reviewers; end your turn with ZERO tool calls and wait for all completion notices before running 'judge'."

  rawFactCheck <-
    resolveRequiredResponse
      (jdgFactCheckResponseFile opts)
      [sessionDir </> "current_fact_check_response.md"]
      (jdgFactCheckLog opts)
      "Fact-check"
      "Error: current_fact_check_response.md has not been written yet (fact-checker is still running). Do not re-message working reviewers; end your turn with ZERO tool calls and wait for all completion notices before running 'judge'."
  factAudit <- resolveSubagentToolAudit (jdgFactCheckLog opts) (Just rawFactCheck)

  rawCritic <-
    resolveRequiredResponse
      (jdgCriticResponseFile opts)
      [sessionDir </> "current_critic_response.md"]
      (jdgCriticLog opts)
      "Critic"
      "Error: current_critic_response.md has not been written yet (commentary-critic is still running). Do not re-message working reviewers; end your turn with ZERO tool calls and wait for all completion notices before running 'judge'."

  let topicPromptPath = sessionDir </> "current_topic_prompt.md"
  hasTopicPrompt <- doesFileExist topicPromptPath
  let usedTopicCurator = hasTopicPrompt || isJust (jdgTopicResponseFile opts) || isJust (jdgTopicLog opts)
  mRawTopic <-
    if usedTopicCurator
      then do
        mT <-
          resolveOptionalResponse
            (jdgTopicResponseFile opts)
            [sessionDir </> "current_topic_response.md"]
            (jdgTopicLog opts)
            "Topic curator"
        case mT of
          Just rawT -> pure (Just rawT)
          Nothing ->
            if hasTopicPrompt
              then die "Error: current_topic_response.md has not been written yet (current_topic_prompt.md exists). If topic-curator is already dispatched, do not re-message it—end your turn with ZERO tool calls and wait for its completion notice; otherwise invoke topic-curator first."
              else pure Nothing
      else pure Nothing

  (criticFeedbackWritten, criticNotesCount, factCheckPending, factQueriesCount, rejectedCriticQuotesCount, factCheckAuditWarningsCount) <-
    processCriticFeedbackWithAudit sessionDir st curIdx factAudit (stPendingLinterWarnings st) (Just rawFactCheck) (Just rawCritic)

  let restoredFromRej =
        [ pr {prStatus = PredStatusActive Nothing}
        | (pr, _) <- stRejectedPredictions st
        , prOriginChunk pr == curIdx
        , all (\p -> prOriginChunk p /= curIdx) (stPredictions st)
        ]
      prevPool = sortOn prOriginChunk (stPredictions st ++ restoredFromRej)
      (preds', newRejs, judgeAuditBlocks, judgeSummaryLines) =
        applyJudgeVerdictsWithFeedback
          curIdx
          (currentChunkMetaTuple st)
          prevPool
          (stPendingRetirements st)
          rawJudge
      rejected' =
        sortOn
          (prOriginChunk . fst)
          ([ (pr, n) | (pr, n) <- stRejectedPredictions st, prOriginChunk pr /= curIdx ] ++ newRejs)
      entriesDir = sessionDir </> "entries"
      entryFile = entriesDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")

  entryExists <- doesFileExist entryFile
  unless entryExists $
    die ("Error: Recorded entry file not found: " ++ entryFile)

  existingEntry <- readTextFileSafe entryFile
  let baseEntry = stripExistingJudgeCallout (stripTrailingEntryRule existingEntry)
      judgeCallout = formatJudgeCallout curIdx judgeSummaryLines
      judgeAuditCallout = formatAuditEntryCallout judgeAuditBlocks
      updatedEntry = baseEntry <> judgeCallout <> judgeAuditCallout <> "\n\n---\n\n"
  TIO.writeFile entryFile updatedEntry

  let combinedAuditBlocks = stPredictionAuditWarnings st ++ judgeAuditBlocks
      stPreTopics =
        st
          { stCurrentJudged = True
          , stPredictions = preds'
          , stRejectedPredictions = rejected'
          , stPendingRetirements = []
          , stPendingLinterWarnings = []
          , stLastJudgeSummary = judgeSummaryLines
          , stPredictionAuditWarnings = combinedAuditBlocks
          }
      (st', topicMergesApplied) =
        case mRawTopic of
          Just rawT -> applyTopicCuratorResponse rawT stPreTopics
          Nothing -> (applyTopicAliases stPreTopics, 0)

  when hasTopicPrompt $
    removeFileIfExists topicPromptPath

  removeFileIfExists (sessionDir </> "current_discussion_response.md")

  (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
  logPath <- rebuildMasterLog sessionDir st'
  saveState sessionDir st'

  hasWrapup <- doesFileExist (sessionDir </> "entries" </> "wrapup.md")
  let storyChunksDone = curIdx >= stTotalChunks st
      isFin = storyChunksDone && hasWrapup && not factCheckPending
      statusStr = if factCheckPending then "awaiting_fact_check_response" else "judged"
      topicKillPrefix =
        if usedTopicCurator
          then "Kill the finished one-shot topic-curator subagent immediately via manage_subagents(Action: \"kill\")! "
          else ""
      nextHintBase
        | factCheckPending =
            "Fact-checker raised "
              <> jsonInt factQueriesCount
              <> " peer verification query(ies) on Chunk "
              <> jsonInt curIdx
              <> "! Send a 1-line notification via send_message to the active blind-reader subagent to read <session_dir>/current_discussion_prompt.md and write <session_dir>/current_discussion_response.md, then STOP and end your turn with ZERO tool calls until blind-reader sends its idle completion notice (never emit 'Waiting...' alongside 'discuss'); only after its idle notice arrives, run 'lets-read discuss --session <dir> --subagent-log <reader_log>' BEFORE running 'next'."
        | storyChunksDone && not hasWrapup =
            "All story chunks have been judged! Run 'lets-read next --session <dir>' to unlock the dedicated Final Wrapup Round (or present the commentary to the user)."
        | otherwise =
            "Run 'lets-read next --session <dir>' to unlock the next chunk (or present the commentary to the user)."
      nextHint = topicKillPrefix <> nextHintBase
  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr statusStr)
      , ("chunk_index", jsonInt curIdx)
      , ("total_chunks", jsonInt (stTotalChunks st))
      , ("remaining_chunks", jsonInt (stTotalChunks st - curIdx))
      , ("is_finished", jsonBool isFin)
      , ("wrapup_recorded", jsonBool hasWrapup)
      , ("wrapup_pending", jsonBool (storyChunksDone && not hasWrapup && not factCheckPending))
      , ("fact_check_discussion_pending", jsonBool factCheckPending)
      , ("fact_check_questions_count", jsonInt factQueriesCount)
      , ("discussion_prompt_file", if factCheckPending then jsonStr (T.pack (sessionDir </> "current_discussion_prompt.md")) else "null")
      , ("discussion_response_file", if factCheckPending then jsonStr (T.pack (sessionDir </> "current_discussion_response.md")) else "null")
      , ("fact_check_questions_file", if factCheckPending then jsonStr (T.pack (sessionDir </> "current_fact_check_questions.md")) else "null")
      , ("entry_file", jsonStr (T.pack entryFile))
      , ("log_file", jsonStr (T.pack logPath))
      , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
      , ("critic_feedback_written", jsonBool criticFeedbackWritten)
      , ("critic_notes_count", jsonInt criticNotesCount)
      , ("rejected_unverified_critic_quotes_count", jsonInt rejectedCriticQuotesCount)
      , ("fact_checker_used_search_web", maybe "null" jsonBool (staUsedSearchWeb factAudit))
      , ("fact_check_audit_warnings_count", jsonInt factCheckAuditWarningsCount)
      , ("topic_merges_applied_count", jsonInt topicMergesApplied)
      , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
      , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
      , ("hall_of_fame_file", if storyChunksDone then jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")) else "null")
      , ("active_predictions_count", jsonInt (countActivePredictions preds'))
      , ("total_predictions_count", jsonInt (length preds'))
      , ("judge_audit_warnings_count", jsonInt (length judgeAuditBlocks))
      , ("prediction_audit_warnings_count", jsonInt (length combinedAuditBlocks))
      , ("memory_compaction_needed", jsonBool needsCompaction)
      , ("curated_memory_lines", jsonInt curLines)
      , ("curated_memory_bytes", jsonInt curBytes)
      , ("orchestrator_rule", jsonStr orchestratorRuleText)
      , ("next_step_hint", jsonStr nextHint)
      , ("discussion_command_hint", jsonStr "If fact_check_discussion_pending is true, notify blind-reader to read discussion_prompt_file and write discussion_response_file, wait for its idle notice (ZERO tool calls while waiting), then run 'lets-read discuss --session <dir> --subagent-log <reader_log>'. If the user replies with comments or questions, run 'lets-read discuss-prompt --session <dir> --user-message \"...\"' (or --user-file), notify blind-reader to read discussion_prompt_file, wait for its idle notice, and record with 'lets-read discuss'.")
      ]
