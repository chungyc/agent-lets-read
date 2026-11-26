{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : LetsRead.Command.Discuss
-- Description : Handler and CLI parser for the 'discuss' subcommand
--
-- Records a @lets-read-blind-reader@ discussion reply—either resolving a pending
-- @lets-read-fact-checker@ peer verification query or answering a user discussion
-- message—into the current chunk entry (or @entries/wrapup.md@), updates
-- curated memory and predictions if revised, and refreshes all session indexes.
module LetsRead.Command.Discuss
  ( DiscussOptions (..)
  , parseDiscussArgs
  , cmdDiscuss
  ) where

import Control.Monad (unless, when)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Command.Common
  ( currentChunkMetaTuple
  , readOptionalMemoryFile
  , removeFileIfExists
  , resolveCommentaryOrResponseWithRaw
  , usage
  )
import LetsRead.Index (applyTopicAliases)
import LetsRead.Memory
  ( extractFallbackSummary
  , formatPeerFactCheckQuote
  , formatUserQuote
  , rebuildMasterLog
  , resolveAndAuditTurn
  , stripLeadingChunkHeading
  , stripTrailingEntryRule
  , syncMemoryAndArchives
  )
import LetsRead.Predictions
  ( countActivePredictions
  , formatAuditEntryCallout
  , formatPredictionTrackerCallout
  )
import LetsRead.Types
  ( ChunkMeta (..)
  , EntryDiscussionRecord (..)
  , EntryLogRecord (..)
  , ParsedChunkSummaries (..)
  , PredictionRecord (..)
  , SessionState (..)
  , StoryChunkRecord (..)
  , emptyParsedChunkSummaries
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
  , resolveSubagentToolAudit
  )
import System.Directory
  ( canonicalizePath
  , doesFileExist
  )
import System.Exit (die)
import System.FilePath (takeFileName, (</>))

-- | Command-line options for @lets-read discuss@.
data DiscussOptions = DiscussOptions
  { discSession :: FilePath
  -- ^ Target session directory.
  , discResponseFile :: Maybe FilePath
  -- ^ Optional explicit path to the structured discussion response file.
  , discSubagentLog :: Maybe FilePath
  -- ^ Optional path or conversation ID for the @lets-read-blind-reader@ transcript log.
  , discCommentaryFile :: Maybe FilePath
  -- ^ Optional path to a plain reply file (without delimiter sections).
  , discMemoryFile :: Maybe FilePath
  -- ^ Optional path to an explicit curated memory override file.
  , discUserMessage :: Maybe Text
  -- ^ Optional inline user question or comment string.
  , discUserFile :: Maybe FilePath
  -- ^ Optional path to a file containing the user question or comment.
  }

-- | Parse CLI arguments for the @discuss@ subcommand.
parseDiscussArgs :: [String] -> IO DiscussOptions
parseDiscussArgs = go (DiscussOptions "" Nothing Nothing Nothing Nothing Nothing Nothing)
  where
    go opts []
      | null (discSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {discSession = v} rest
    go opts ("--response-file" : v : rest) = go opts {discResponseFile = Just v} rest
    go opts ("--subagent-log" : v : rest) = go opts {discSubagentLog = Just v} rest
    go opts ("--commentary-file" : v : rest) = go opts {discCommentaryFile = Just v} rest
    go opts ("--memory-file" : v : rest) = go opts {discMemoryFile = Just v} rest
    go opts ("--user-message" : v : rest) = go opts {discUserMessage = Just (T.pack v)} rest
    go opts ("--user-file" : v : rest) = go opts {discUserFile = Just v} rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

-- | Execute the @discuss@ subcommand: resolve the reader's discussion reply,
-- append a formatted @### Reader Discussion@ exchange (peer fact-check quote or
-- user quote + reply + any prediction tracker updates) to the current entry,
-- clear resolved prompt files, update indexes and @lets_read_log.md@, and emit
-- a JSON status summary.
cmdDiscuss :: DiscussOptions -> IO ()
cmdDiscuss opts = do
  sessionDir <- canonicalizePath (discSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
      questionsPath = sessionDir </> "current_fact_check_questions.md"
      discPromptPath = sessionDir </> "current_discussion_prompt.md"
      defaultUserFilePath = sessionDir </> "last_user_message.md"
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."
  unless (stCurrentRecorded st) $
    die "Error: Current chunk commentary has not been recorded yet. Run 'record' before 'discuss'."

  hasWrapupEarly <- doesFileExist (sessionDir </> "entries" </> "wrapup.md")
  let discRoundStr = if hasWrapupEarly then "Wrapup (Discuss)" else "Chunk " ++ padChunkNumber curIdx ++ " (Discuss)"

  (rawDiscResp, mParsedUser, replyText, parsedSummaries, mParsedPredUpdates, mParsedMem) <-
    resolveCommentaryOrResponseWithRaw
      (discResponseFile opts)
      (discCommentaryFile opts)
      [sessionDir </> "current_discussion_response.md"]
      (discSubagentLog opts)
      "Discussion"
      ( "Error: current_discussion_response.md has not been written yet (lets-read-blind-reader is still running). Do not re-message lets-read-blind-reader; end your turn with ZERO tool calls outputting ONLY '[HOST_WAIT | "
          ++ discRoundStr
          ++ " | discuss | 0/1 idle | pending: lets-read-blind-reader]' and wait for '[SUBAGENT_DONE | "
          ++ discRoundStr
          ++ " | lets-read-blind-reader]' before running 'discuss'."
      )

  when (T.null replyText) $
    die "Error: Discussion reply content is empty."

  hasPendingFactCheck <- doesFileExist questionsPath
  let userFileIsFactCheck =
        case discUserFile opts of
          Nothing -> False
          Just uPath ->
            let base = takeFileName uPath
             in base == "current_fact_check_questions.md" || base == "current_discussion_prompt.md"
      hasExplicitCustomUser =
        (case discUserMessage opts of Just m -> not (T.null (T.strip m)); Nothing -> False)
          || (isJust (discUserFile opts) && not userFileIsFactCheck)
      isFactCheckDiscussion = hasPendingFactCheck && not hasExplicitCustomUser

  mUserFromFile <-
    if isFactCheckDiscussion
      then do
        txt <- readTextFileSafe questionsPath
        let stripped = T.strip txt
        pure (if T.null stripped then Nothing else Just stripped)
      else case discUserFile opts of
        Just uPath -> do
          exists <- doesFileExist uPath
          unless exists $ die ("Error: User message file not found: " ++ uPath)
          txt <- readTextFileSafe uPath
          let stripped = T.strip txt
          pure (if T.null stripped then Nothing else Just stripped)
        Nothing -> do
          hasDefaultUserFile <- doesFileExist defaultUserFilePath
          if hasDefaultUserFile
            then do
              txt <- readTextFileSafe defaultUserFilePath
              let stripped = T.strip txt
              pure (if T.null stripped then Nothing else Just stripped)
            else pure Nothing

  let mUserMsg =
        case discUserMessage opts of
          Just m | not (T.null (T.strip m)) -> Just (T.strip m)
          _ ->
            case mUserFromFile of
              Just m -> Just m
              Nothing -> mParsedUser

  mExplicitMem <- readOptionalMemoryFile (discMemoryFile opts)

  let finalMem =
        case mExplicitMem of
          Just m -> Just m
          Nothing -> mParsedMem
      entriesDir = sessionDir </> "entries"
      wrapupPath = entriesDir </> "wrapup.md"
      (chapNum, chapTitle, partNum, partsTotal) = currentChunkMetaTuple st

  hasWrapup <- doesFileExist wrapupPath
  let entryFile =
        if hasWrapup && curIdx >= stTotalChunks st
          then wrapupPath
          else entriesDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")

  entryExists <- doesFileExist entryFile
  unless entryExists $
    die ("Error: Recorded entry file not found: " ++ entryFile)

  let (curated', rawPreds', _, auditBlocks, rawTrackerUpdates) =
        resolveAndAuditTurn
          curIdx
          (stTotalChunks st)
          chapNum
          chapTitle
          partNum
          partsTotal
          False
          replyText
          (stCuratedMemory st)
          (stPredictions st)
          (stPredictionAuditWarnings st)
          mParsedPredUpdates
          finalMem
      curWasRejected =
        stCurrentJudged st
          && any (\(pr, _) -> prOriginChunk pr == curIdx) (stRejectedPredictions st)
          && all (\pr -> prOriginChunk pr /= curIdx) (stPredictions st)
      preds' =
        if curWasRejected
          then [pr | pr <- rawPreds', prOriginChunk pr /= curIdx]
          else rawPreds'
      trackerUpdates =
        if curWasRejected
          then []
          else rawTrackerUpdates
      rejected' =
        if curWasRejected
          then
            [ if prOriginChunk pr == curIdx
                then case [p | p <- rawPreds', prOriginChunk p == curIdx] of
                  (newP : _) -> (newP, n)
                  [] -> (pr, n)
                else (pr, n)
            | (pr, n) <- stRejectedPredictions st
            ]
          else stRejectedPredictions st

  existingEntry <- readTextFileSafe entryFile
  let baseEntry = stripTrailingEntryRule existingEntry
      hasDiscussionHeader = "### Reader Discussion" `T.isInfixOf` baseEntry
      headingPrefix = if hasDiscussionHeader then "" else "### Reader Discussion\n\n"
      userBlock =
        case mUserMsg of
          Nothing -> ""
          Just u
            | isFactCheckDiscussion -> formatPeerFactCheckQuote u <> "\n"
            | otherwise -> formatUserQuote u <> "\n"
      trackerCallout = formatPredictionTrackerCallout trackerUpdates
      auditCallout = formatAuditEntryCallout auditBlocks
      appendedSection = headingPrefix <> userBlock <> stripLeadingChunkHeading replyText <> trackerCallout <> auditCallout
      updatedEntry = baseEntry <> "\n\n" <> appendedSection <> "\n\n---\n\n"

  TIO.writeFile entryFile updatedEntry

  discToolAudit <- resolveSubagentToolAudit (discSubagentLog opts) (Just rawDiscResp)
  let mUsedVerifyTools = staUsedVerificationTools discToolAudit

  when isFactCheckDiscussion $
    removeFileIfExists questionsPath
  removeFileIfExists discPromptPath
  unless isFactCheckDiscussion $
    removeFileIfExists defaultUserFilePath
  removeFileIfExists (sessionDir </> "current_discussion_response.md")

  let isWrapupTarget = hasWrapup && curIdx >= stTotalChunks st
      storyRecords' =
        case pcsStory parsedSummaries of
          Nothing -> stStoryRecords st
          Just (newStoryTopics, newStorySum) ->
            map
              ( \e ->
                  if scrChunkIndex e == curIdx
                    then
                      e
                        { scrTopics = if null newStoryTopics then scrTopics e else newStoryTopics
                        , scrSummary = newStorySum
                        }
                    else e
              )
              (stStoryRecords st)
      (discTopics, discSumTxt) =
        fromMaybe ([], extractFallbackSummary replyText) (pcsDiscussion parsedSummaries)
      discRecord =
        EntryDiscussionRecord
          { edrIsFactCheck = isFactCheckDiscussion
          , edrTopics = discTopics
          , edrSummary = discSumTxt
          }
      matchesTargetEntry e
        | isWrapupTarget = elrIsWrapup e
        | otherwise = elrEntryIndex e == curIdx && not (elrIsWrapup e)
      entryRecords' =
        map
          ( \e ->
              if matchesTargetEntry e
                then
                  let (updTopics, updSum) =
                        case pcsEntry parsedSummaries of
                          Nothing -> (elrTopics e, elrSummary e)
                          Just (et, es) -> (if null et then elrTopics e else et, es)
                   in e
                        { elrTopics = updTopics
                        , elrSummary = updSum
                        , elrDiscussions = elrDiscussions e ++ [discRecord]
                        }
                else e
          )
          (stEntryRecords st)
      memUpdated =
        isJust finalMem
          || isJust mParsedPredUpdates
          || (parsedSummaries /= emptyParsedChunkSummaries)
          || (curated' /= stCuratedMemory st)
          || (preds' /= stPredictions st)
          || (rejected' /= stRejectedPredictions st)
          || (storyRecords' /= stStoryRecords st)
          || (entryRecords' /= stEntryRecords st)
          || (auditBlocks /= stPredictionAuditWarnings st)
      st' =
        applyTopicAliases
          st
            { stStoryRecords = storyRecords'
            , stEntryRecords = entryRecords'
            , stCuratedMemory = curated'
            , stPredictions = preds'
            , stRejectedPredictions = rejected'
            , stPredictionAuditWarnings = auditBlocks
            }

  (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
  logPath <- rebuildMasterLog sessionDir st'
  when (memUpdated || isFactCheckDiscussion) $
    saveState sessionDir st'

  stillPending <- doesFileExist questionsPath
  let storyChunksDone = curIdx >= stTotalChunks st && stCurrentRecorded st' && stCurrentJudged st' && not stillPending
      isChapEnd = not hasWrapup && maybe False metaIsChapterEnd (stCurrentMeta st)
      wrapupPending = storyChunksDone && not hasWrapup
      isFin = storyChunksDone && hasWrapup
      nextHint
        | stillPending =
            "A Fact-Check Peer Query is still pending in current_discussion_prompt.md. Send it to lets-read-blind-reader and run 'discuss' before 'next'."
        | wrapupPending && isFactCheckDiscussion =
            "Fact-check discussion resolved and all story chunks are judged! Run 'lets-read next --session <dir>' to unlock the dedicated Final Wrapup Round (or present the commentary and discussion to the user)."
        | wrapupPending =
            "Discussion recorded! Run 'lets-read next --session <dir>' to unlock the dedicated Final Wrapup Round (or present the commentary and discussion to the user)."
        | isFin =
            "Post-wrapup discussion recorded! Relay the appended Reader Discussion reply from entries/wrapup.md to the user."
        | otherwise =
            "Discussion recorded! Run 'lets-read next --session <dir>' to unlock the next chunk (or present the commentary and discussion to the user)."

  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "discussed")
      , ("chunk_index", jsonInt curIdx)
      , ("total_chunks", jsonInt (stTotalChunks st))
      , ("is_chapter_end", jsonBool isChapEnd)
      , ("is_finished", jsonBool isFin)
      , ("wrapup_pending", jsonBool wrapupPending)
      , ("fact_check_discussion_resolved", jsonBool isFactCheckDiscussion)
      , ("fact_check_discussion_pending", jsonBool stillPending)
      , ("reader_verified_with_tools", maybe "null" jsonBool mUsedVerifyTools)
      , ("entry_file", jsonStr (T.pack entryFile))
      , ("log_file", jsonStr (T.pack logPath))
      , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
      , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
      , ("memory_updated", jsonBool memUpdated)
      , ("active_predictions_count", jsonInt (countActivePredictions preds'))
      , ("prediction_audit_warnings_count", jsonInt (length auditBlocks))
      , ("memory_compaction_needed", jsonBool needsCompaction)
      , ("curated_memory_lines", jsonInt curLines)
      , ("curated_memory_bytes", jsonInt curBytes)
      , ("orchestrator_rule", jsonStr orchestratorRuleText)
      , ("next_step_hint", jsonStr nextHint)
      ]
