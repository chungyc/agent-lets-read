{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : LetsRead.Command.Record
-- Description : Handler and CLI parser for the 'record' subcommand
--
-- Records the blind-reader's commentary, chunk summaries, prediction proposals,
-- and curated memory updates for the currently unlocked chunk (or the Final
-- Wrapup & Retrospective turn). Runs the deterministic style linter and writes the prompt files for @prediction-judge@,
-- @fact-checker@, @commentary-critic@, and (when triggered) @topic-curator@.
module LetsRead.Command.Record
  ( RecordOptions (..)
  , parseRecordArgs
  , cmdRecord
  ) where

import Control.Monad (when)
import Data.List (sort, sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (computeShouldRotateMeta)
import LetsRead.Command.Common
  ( currentChunkMetaTuple
  , readOptionalMemoryFile
  , removeFileIfExists
  , resolveCommentaryOrResponseWithRaw
  , usage
  )
import LetsRead.Index
  ( applyTopicAliases
  , shouldCurateTopics
  )
import LetsRead.Memory
  ( extractFallbackSummary
  , mergeCuratedNarrativeMemoryForTurn
  , rebuildMasterLog
  , resolveAndAuditTurn
  , stripLeadingChunkHeading
  , syncMemoryAndArchives
  )
import LetsRead.Predictions
  ( countActivePredictions
  , formatAuditEntryCallout
  , formatPredictionTrackerCallout
  )
import LetsRead.Prompts
  ( writeCurrentCriticPromptFile
  , writeCurrentFactCheckPromptFile
  , writeCurrentJudgePromptFile
  , writeCurrentTopicPromptFile
  )
import LetsRead.Types
  ( EntryLogRecord (..)
  , ParsedChunkSummaries (..)
  , PredictionRecord (..)
  , SessionState (..)
  , StoryChunkRecord (..)
  , jsonBool
  , jsonInt
  , jsonObject
  , jsonStr
  , ledgerPredictions
  , loadState
  , orchestratorRuleText
  , padChunkNumber
  , readTextFileSafe
  , saveState
  )
import LetsRead.Verification
  ( auditReaderToolUsageWithResearch
  , extractVerifiedResearchChunkRefs
  , lintReaderCommentary
  , lintStorySummaryBullets
  , loadBannedJargonIO
  , resolveSubagentToolAudit
  )
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  )
import System.Exit (die)
import System.FilePath ((</>))

-- | Command-line options for @lets-read record@.
data RecordOptions = RecordOptions
  { recSession :: FilePath
  -- ^ Target session directory.
  , recResponseFile :: Maybe FilePath
  -- ^ Optional explicit path to the structured reader response file.
  , recSubagentLog :: Maybe FilePath
  -- ^ Optional path or conversation ID for the @blind-reader@ transcript log.
  , recCommentaryFile :: Maybe FilePath
  -- ^ Optional path to a plain commentary file (without delimiter sections).
  , recMemoryFile :: Maybe FilePath
  -- ^ Optional path to an explicit curated memory override file.
  }

-- | Parse CLI arguments for the @record@ subcommand.
parseRecordArgs :: [String] -> IO RecordOptions
parseRecordArgs = go (RecordOptions "" Nothing Nothing Nothing Nothing)
  where
    go opts []
      | null (recSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {recSession = v} rest
    go opts ("--response-file" : v : rest) = go opts {recResponseFile = Just v} rest
    go opts ("--subagent-log" : v : rest) = go opts {recSubagentLog = Just v} rest
    go opts ("--commentary-file" : v : rest) = go opts {recCommentaryFile = Just v} rest
    go opts ("--memory-file" : v : rest) = go opts {recMemoryFile = Just v} rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

-- | Execute the @record@ subcommand: parse the reader's response, audit
-- prediction updates, run the deterministic style linter, write the chunk entry
-- (or @entries/wrapup.md@), generate downstream reviewer prompts, sync indexes
-- and @lets_read_log.md@, and emit a JSON status summary.
cmdRecord :: RecordOptions -> IO ()
cmdRecord opts = do
  sessionDir <- canonicalizePath (recSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."

  hasScriptPrompt <- doesFileExist (sessionDir </> "current_script_prompt.md")
  when hasScriptPrompt $
    die "Error: script-writer step has not completed yet (current_script_prompt.md is still active). Run 'lets-read script' and 'lets-read research' before 'record'."

  hasResearchPrompt <- doesFileExist (sessionDir </> "current_research_prompt.md")
  when hasResearchPrompt $
    die "Error: researcher step has not completed yet (current_research_prompt.md is still active). Run 'lets-read research' before 'record'."

  let isWrapupTurn = curIdx >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
      curPad = T.pack (padChunkNumber curIdx)
      roundTagStr = if isWrapupTurn then "Wrapup" else "Chunk " ++ padChunkNumber curIdx

  (rawResp, _, commText, parsedSummaries, mParsedPredUpdates, mParsedMem) <-
    resolveCommentaryOrResponseWithRaw
      (recResponseFile opts)
      (recCommentaryFile opts)
      [sessionDir </> "current_reader_response.md"]
      (recSubagentLog opts)
      "Reader"
      ( "Error: current_reader_response.md has not been written yet (blind-reader is still running). Do not re-message blind-reader; end your turn with ZERO tool calls outputting ONLY '[HOST_WAIT | "
          ++ roundTagStr
          ++ " | record | 0/1 idle | pending: blind-reader]' and wait for '[SUBAGENT_DONE | "
          ++ roundTagStr
          ++ " | blind-reader]' before running 'record'."
      )

  when (T.null commText) $
    die "Error: Commentary content is empty."

  mExplicitMem <- readOptionalMemoryFile (recMemoryFile opts)

  let finalMem =
        case mExplicitMem of
          Just m -> Just m
          Nothing -> mParsedMem
      cleanedCommText = stripLeadingChunkHeading commText
      entriesDir = sessionDir </> "entries"

  if isWrapupTurn
    then do
      let curated' = mergeCuratedNarrativeMemoryForTurn True (stCuratedMemory st) finalMem
          (wrapupTopics, wrapupSumTxt) =
            fromMaybe (["Wrapup", "Retrospective"], extractFallbackSummary commText) (pcsEntry parsedSummaries)
          wrapupIdx = curIdx + 1
          existingWrapupDiscussions =
            case [elrDiscussions e | e <- stEntryRecords st, elrIsWrapup e] of
              (ds : _) -> ds
              [] -> []
          wrapupEntryRecord =
            EntryLogRecord
              { elrEntryIndex = wrapupIdx
              , elrIsWrapup = True
              , elrChapterNumber = stTotalChapters st
              , elrChapterTitle = "Final Wrapup & Retrospective"
              , elrPartInChapter = 1
              , elrPartsInChapter = 1
              , elrTopics = wrapupTopics
              , elrSummary = wrapupSumTxt
              , elrDiscussions = existingWrapupDiscussions
              }
          entryRecords' =
            sortOn
              elrEntryIndex
              (wrapupEntryRecord : filter (not . elrIsWrapup) (stEntryRecords st))
          st' =
            applyTopicAliases
              st
                { stCuratedMemory = curated'
                , stEntryRecords = entryRecords'
                }
          wrapupHeader = "## Final Wrapup & Retrospective — " <> stTitle st <> "\n\n"
          wrapupContent = wrapupHeader <> cleanedCommText <> "\n\n---\n\n"
          wrapupFile = entriesDir </> "wrapup.md"

      createDirectoryIfMissing True entriesDir
      TIO.writeFile wrapupFile wrapupContent
      (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
      logPath <- rebuildMasterLog sessionDir st'
      saveState sessionDir st'

      TIO.putStrLn $
        jsonObject
          [ ("status", jsonStr "wrapup_recorded")
          , ("chunk_index", jsonInt curIdx)
          , ("total_chunks", jsonInt (stTotalChunks st))
          , ("remaining_chunks", jsonInt 0)
          , ("is_finished", jsonBool True)
          , ("wrapup_recorded", jsonBool True)
          , ("entry_file", jsonStr (T.pack wrapupFile))
          , ("wrapup_file", jsonStr (T.pack wrapupFile))
          , ("hall_of_fame_file", jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")))
          , ("log_file", jsonStr (T.pack logPath))
          , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
          , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
          , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
          , ("active_predictions_count", jsonInt (countActivePredictions (stPredictions st')))
          , ("total_predictions_count", jsonInt (length (stPredictions st')))
          , ("memory_compaction_needed", jsonBool needsCompaction)
          , ("curated_memory_lines", jsonInt curLines)
          , ("curated_memory_bytes", jsonInt curBytes)
          , ("orchestrator_rule", jsonStr orchestratorRuleText)
          , ("next_step_hint", jsonStr "The Let's Read and Final Wrapup are complete! Present the Final Wrapup and Hall of Fame & Shame to the user (or use 'lets-read discuss-prompt' + 'lets-read discuss' if the user replies with post-story questions).")
          ]
    else do
      bannedJargon <- loadBannedJargonIO
      readerAudit <- resolveSubagentToolAudit (recSubagentLog opts) (Just rawResp)
      let researchFilePath = sessionDir </> "current_research.md"
      hasResearchFile <- doesFileExist researchFilePath
      researchChunkRefs <-
        if hasResearchFile
          then extractVerifiedResearchChunkRefs <$> readTextFileSafe researchFilePath
          else pure []
      let (chapNum, chapTitle, partNum, partsTotal) = currentChunkMetaTuple st
          priorStory = [e | e <- stStoryRecords st, scrChunkIndex e < curIdx]
          shouldRotateHere =
            case stCurrentMeta st of
              Just m -> computeShouldRotateMeta priorStory m
              Nothing -> False

          (curated', preds', pendingRetires, auditBlocks, trackerUpdates) =
            resolveAndAuditTurn
              curIdx
              (stTotalChunks st)
              chapNum
              chapTitle
              partNum
              partsTotal
              True
              cleanedCommText
              (stCuratedMemory st)
              (stPredictions st)
              (stPredictionAuditWarnings st)
              mParsedPredUpdates
              finalMem
          mNewlyLoggedPred =
            listToMaybe
              [ pr
              | pr <- preds'
              , prOriginChunk pr == curIdx
              , all (\oldPr -> prOriginChunk oldPr /= curIdx) (stPredictions st)
              ]
          commAndPredForAudit =
            cleanedCommText
              <> "\n"
              <> fromMaybe "" mParsedPredUpdates
          (mReadPrevChunk, callbackReadsCnt, readerCallbackWarns) =
            auditReaderToolUsageWithResearch curIdx shouldRotateHere researchChunkRefs commAndPredForAudit readerAudit
          (storyTopics, storySumTxt) =
            fromMaybe ([], "Story events recorded.") (pcsStory parsedSummaries)
          (entryTopics, entrySumTxt) =
            fromMaybe ([], extractFallbackSummary commText) (pcsEntry parsedSummaries)
          chapDisplay
            | chapNum == 0 = chapTitle
            | "chapter " `T.isPrefixOf` T.toLower (T.strip chapTitle) = chapTitle
            | otherwise = "Chapter " <> jsonInt chapNum <> ": " <> chapTitle
          entryHeader =
            "## Chunk "
              <> jsonInt curIdx
              <> "/"
              <> jsonInt (stTotalChunks st)
              <> " — "
              <> chapDisplay
              <> " (Part "
              <> jsonInt partNum
              <> "/"
              <> jsonInt partsTotal
              <> ")\n\n"
          trackerCallout = formatPredictionTrackerCallout trackerUpdates
          auditCallout = formatAuditEntryCallout auditBlocks
          entryContent = entryHeader <> cleanedCommText <> trackerCallout <> auditCallout <> "\n\n---\n\n"
          entryFile = entriesDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")

      createDirectoryIfMissing True entriesDir
      TIO.writeFile entryFile entryContent

      let completed' =
            if curIdx `elem` stCompletedChunks st
              then stCompletedChunks st
              else sort (curIdx : stCompletedChunks st)
          newStoryRecord =
            StoryChunkRecord
              { scrChunkIndex = curIdx
              , scrChapterNumber = chapNum
              , scrChapterTitle = chapTitle
              , scrPartInChapter = partNum
              , scrPartsInChapter = partsTotal
              , scrTopics = storyTopics
              , scrSummary = storySumTxt
              }
          storyRecords' =
            sortOn
              scrChunkIndex
              (newStoryRecord : filter (\e -> scrChunkIndex e /= curIdx) (stStoryRecords st))
          linterWarnings =
            lintReaderCommentary bannedJargon cleanedCommText parsedSummaries mNewlyLoggedPred
              ++ lintStorySummaryBullets curated' storyRecords'
              ++ readerCallbackWarns
          existingDiscussions =
            case [elrDiscussions e | e <- stEntryRecords st, elrEntryIndex e == curIdx, not (elrIsWrapup e)] of
              (ds : _) -> ds
              [] -> []
          newEntryRecord =
            EntryLogRecord
              { elrEntryIndex = curIdx
              , elrIsWrapup = False
              , elrChapterNumber = chapNum
              , elrChapterTitle = chapTitle
              , elrPartInChapter = partNum
              , elrPartsInChapter = partsTotal
              , elrTopics = entryTopics
              , elrSummary = entrySumTxt
              , elrDiscussions = existingDiscussions
              }
          entryRecords' =
            sortOn
              elrEntryIndex
              (newEntryRecord : filter (\e -> elrEntryIndex e /= curIdx || elrIsWrapup e) (stEntryRecords st))
          st' =
            applyTopicAliases
              st
                { stCurrentRecorded = True
                , stCurrentJudged = False
                , stCompletedChunks = completed'
                , stStoryRecords = storyRecords'
                , stEntryRecords = entryRecords'
                , stCuratedMemory = curated'
                , stPredictions = preds'
                , stRejectedPredictions =
                    [ (pr, n)
                    | (pr, n) <- stRejectedPredictions st
                    , prOriginChunk pr /= curIdx
                    ]
                , stPendingRetirements = pendingRetires
                , stPendingLinterWarnings = linterWarnings
                , stPredictionAuditWarnings = auditBlocks
                }
          curateTopics = shouldCurateTopics st'
          topicPromptPath = sessionDir </> "current_topic_prompt.md"
          judgeRespPath = sessionDir </> "current_judge_response.md"
          factRespPath = sessionDir </> "current_fact_check_response.md"
          criticRespPath = sessionDir </> "current_critic_response.md"
          topicRespPath = sessionDir </> "current_topic_response.md"
          discRespPath = sessionDir </> "current_discussion_response.md"

      removeFileIfExists judgeRespPath
      removeFileIfExists factRespPath
      removeFileIfExists criticRespPath
      removeFileIfExists topicRespPath
      removeFileIfExists discRespPath

      judgePromptFile <- writeCurrentJudgePromptFile sessionDir st'
      factCheckPromptFile <- writeCurrentFactCheckPromptFile sessionDir st' storySumTxt entrySumTxt
      criticPromptFile <- writeCurrentCriticPromptFile sessionDir st'
      if curateTopics
        then do
          _ <- writeCurrentTopicPromptFile sessionDir st'
          pure ()
        else removeFileIfExists topicPromptPath
      (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
      logPath <- rebuildMasterLog sessionDir st'
      saveState sessionDir st'

      let rotateCritic = curIdx > 1 && (curIdx - 1) `mod` 7 == 0
          rotateFactChecker = curIdx > 1 && (curIdx - 1) `mod` 9 == 0
          rotateJudge = curIdx > 1 && (curIdx - 1) `mod` 11 == 0
          nextHint =
            if curateTopics
              then
                "Notify prediction-judge, fact-checker, commentary-critic (Model: \"inherit\" when invoking), and one-shot topic-curator (Model: \"flash_lite\") in parallel with 1-line messages to read their prompt files and write their current_*_response.md files, then park with ZERO tool calls outputting ONLY '[HOST_WAIT | Chunk "
                  <> curPad
                  <> " | judge | 0/4 idle | pending: prediction-judge, fact-checker, commentary-critic, topic-curator]' (updating the idle count and pending list on intermediate wakeups) until ALL 4 '[SUBAGENT_DONE | Chunk "
                  <> curPad
                  <> " | <role>]' notices arrive; then run 'lets-read judge --session <dir> --subagent-log <judge_log> --fact-check-log <fact_check_log> --critic-log <critic_log> --topic-log <topic_log>'."
              else
                "Notify prediction-judge, fact-checker, and commentary-critic (Model: \"inherit\" when invoking) in parallel with 1-line messages to read their prompt files and write their current_*_response.md files, then park with ZERO tool calls outputting ONLY '[HOST_WAIT | Chunk "
                  <> curPad
                  <> " | judge | 0/3 idle | pending: prediction-judge, fact-checker, commentary-critic]' (updating the idle count and pending list on intermediate wakeups) until ALL 3 '[SUBAGENT_DONE | Chunk "
                  <> curPad
                  <> " | <role>]' notices arrive; then run 'lets-read judge --session <dir> --subagent-log <judge_log> --fact-check-log <fact_check_log> --critic-log <critic_log>'."
      TIO.putStrLn $
        jsonObject
          [ ("status", jsonStr "awaiting_judge")
          , ("chunk_index", jsonInt curIdx)
          , ("total_chunks", jsonInt (stTotalChunks st))
          , ("remaining_chunks", jsonInt (stTotalChunks st - curIdx))
          , ("is_finished", jsonBool False)
          , ("entry_file", jsonStr (T.pack entryFile))
          , ("log_file", jsonStr (T.pack logPath))
          , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
          , ("judge_prompt_file", jsonStr (T.pack judgePromptFile))
          , ("judge_response_file", jsonStr (T.pack judgeRespPath))
          , ("fact_check_prompt_file", jsonStr (T.pack factCheckPromptFile))
          , ("fact_check_response_file", jsonStr (T.pack factRespPath))
          , ("critic_prompt_file", jsonStr (T.pack criticPromptFile))
          , ("critic_response_file", jsonStr (T.pack criticRespPath))
          , ("topic_curation_needed", jsonBool curateTopics)
          , ("topic_prompt_file", if curateTopics then jsonStr (T.pack topicPromptPath) else "null")
          , ("topic_response_file", if curateTopics then jsonStr (T.pack topicRespPath) else "null")
          , ("rotate_judge_recommended", jsonBool rotateJudge)
          , ("rotate_fact_checker_recommended", jsonBool rotateFactChecker)
          , ("rotate_critic_recommended", jsonBool rotateCritic)
          , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
          , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
          , ("active_predictions_count", jsonInt (countActivePredictions (ledgerPredictions st')))
          , ("pending_retirements_count", jsonInt (length pendingRetires))
          , ("linter_warnings_count", jsonInt (length linterWarnings))
          , ("reader_read_prev_chunk", maybe "null" jsonBool mReadPrevChunk)
          , ("reader_callback_reads_count", jsonInt callbackReadsCnt)
          , ("reader_callback_audit_warnings_count", jsonInt (length readerCallbackWarns))
          , ("total_predictions_count", jsonInt (length (ledgerPredictions st')))
          , ("prediction_audit_warnings_count", jsonInt (length auditBlocks))
          , ("memory_compaction_needed", jsonBool needsCompaction)
          , ("curated_memory_lines", jsonInt curLines)
          , ("curated_memory_bytes", jsonInt curBytes)
          , ("orchestrator_rule", jsonStr orchestratorRuleText)
          , ("next_step_hint", jsonStr nextHint)
          ]
