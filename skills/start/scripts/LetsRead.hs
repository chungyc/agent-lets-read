#!/usr/bin/env runghc
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Main
-- Description : Spoiler-free Gatekeeper CLI for AI-hosted Let's Reads
--
-- Orchestrates story ingestion, chunk unlocking, commentary recording,
-- prediction judging, fact-check receipt verification, persona/style
-- critique routing, and multi-layer indexing.

module Main (main) where

import Control.Exception (IOException, catch)
import Control.Monad (unless, when)
import Data.List (isPrefixOf, sort, sortOn)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker
  ( buildChunksFromSource
  , computeShouldRotate
  )
import LetsRead.Index
  ( applyTopicAliases
  , applyTopicCuratorResponse
  , shouldCurateTopics
  )
import LetsRead.Memory
  ( defaultCuratedMemory
  , extractFallbackSummary
  , formatPeerFactCheckQuote
  , formatUserQuote
  , mergeCuratedNarrativeMemory
  , parseCombinedResponse
  , rebuildMasterLog
  , resolveAndAuditTurn
  , stripLeadingChunkHeading
  , stripTrailingEntryRule
  , syncMemoryAndArchives
  )
import LetsRead.Predictions
  ( applyJudgeVerdicts
  , countActivePredictions
  , extractJudgeSection
  , formatAuditEntryCallout
  , formatJudgeCallout
  , formatPredictionTrackerCallout
  , stripExistingJudgeCallout
  )
import LetsRead.Prompts
  ( resolvePersonaPresetIO
  , writeCurrentChunkFile
  , writeCurrentCriticPromptFile
  , writeCurrentFactCheckPromptFile
  , writeCurrentJudgePromptFile
  , writeCurrentPromptFile
  , writeCurrentTopicPromptFile
  , writeUserDiscussionPromptFile
  , writeWrapupPromptFile
  )
import LetsRead.Types
  ( Chunk (..)
  , ChunkMeta (..)
  , DiscussOptions (..)
  , DiscussPromptOptions (..)
  , EntryDiscussionRecord (..)
  , EntryLogRecord (..)
  , InitOptions (..)
  , JudgeOptions (..)
  , ParsedChunkSummaries (..)
  , PredictionRecord (..)
  , RecordOptions (..)
  , SessionState (..)
  , StoryChunkRecord (..)
  , chunkToMeta
  , emptyParsedChunkSummaries
  , jsonBool
  , jsonInt
  , jsonObject
  , jsonStr
  , loadState
  , loadVaultChunk
  , orchestratorRuleText
  , padChunkNumber
  , readTextFileSafe
  , renderStateJson
  , saveState
  , saveVault
  )
import LetsRead.Verification
  ( checkSubagentLogUsedSearchWeb
  , checkSubagentLogUsedVerificationTools
  , extractSubagentLogResponse
  , lintReaderCommentary
  , loadBannedJargonIO
  , processCriticFeedback
  )
import Control.Concurrent (threadDelay)
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  , removeFile
  )
import System.Environment (getArgs)
import System.Exit (die, exitSuccess)
import System.FilePath (takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (setFileCreationMask)

-- ---------------------------------------------------------------------------
-- Response File & Cleanup Helpers
-- ---------------------------------------------------------------------------

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists p = do
  exists <- doesFileExist p
  when exists (removeFile p `catch` (\(_ :: IOException) -> pure ()))

readNonEmptyFileIfExists :: FilePath -> IO (Maybe T.Text)
readNonEmptyFileIfExists p = do
  exists <- doesFileExist p
  if not exists
    then pure Nothing
    else do
      raw <- readTextFileSafe p
      if T.null (T.strip raw)
        then pure Nothing
        else pure (Just raw)

firstNonEmptyFile :: [FilePath] -> IO (Maybe T.Text)
firstNonEmptyFile [] = pure Nothing
firstNonEmptyFile (p : ps) = do
  mTxt <- readNonEmptyFileIfExists p
  case mTxt of
    Just t -> pure (Just t)
    Nothing -> firstNonEmptyFile ps

resolveOptionalResponse :: Maybe FilePath -> [FilePath] -> Maybe FilePath -> String -> IO (Maybe T.Text)
resolveOptionalResponse mExplicit defaultFiles mLog label =
  case mExplicit of
    Just respPath -> do
      exists <- doesFileExist respPath
      unless exists $ die ("Error: " ++ label ++ " response file not found: " ++ respPath)
      raw <- readTextFileSafe respPath
      pure (Just raw)
    Nothing -> poll 40
  where
    tryOnce = do
      mDef <- firstNonEmptyFile defaultFiles
      case mDef of
        Just raw -> pure (Just raw)
        Nothing ->
          case mLog of
            Just logPath -> extractSubagentLogResponse logPath
            Nothing -> pure Nothing
    poll :: Int -> IO (Maybe T.Text)
    poll retriesLeft = do
      mRes <- tryOnce
      case mRes of
        Just raw -> pure (Just raw)
        Nothing
          | retriesLeft <= 0 -> pure Nothing
          | otherwise -> do
              threadDelay 250000
              poll (retriesLeft - 1)

resolveRequiredResponse :: Maybe FilePath -> [FilePath] -> Maybe FilePath -> String -> String -> IO T.Text
resolveRequiredResponse mExplicit defaultFiles mLog label errMsg = do
  mRes <- resolveOptionalResponse mExplicit defaultFiles mLog label
  case mRes of
    Just raw -> pure raw
    Nothing -> die errMsg

-- ---------------------------------------------------------------------------
-- CLI Command Handlers
-- ---------------------------------------------------------------------------

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
          <> "\n\n*Reader Persona*: "
          <> persona
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

cmdNext :: FilePath -> Bool -> IO ()
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
      removeFile questionsPath `catch` (\(_ :: IOException) -> pure ())
      dExists <- doesFileExist discPromptPath
      when dExists (removeFile discPromptPath `catch` (\(_ :: IOException) -> pure ()))
    tExists <- doesFileExist topicPromptPath
    when tExists (removeFile topicPromptPath `catch` (\(_ :: IOException) -> pure ()))

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

cmdRecord :: RecordOptions -> IO ()
cmdRecord opts = do
  sessionDir <- canonicalizePath (recSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."

  (_, commText, parsedSummaries, mParsedPredUpdates, mParsedMem) <-
    case (recResponseFile opts, recCommentaryFile opts) of
      (Nothing, Just commPath) -> do
        exists <- doesFileExist commPath
        unless exists $ die ("Error: Commentary file not found: " ++ commPath)
        raw <- readTextFileSafe commPath
        pure (Nothing, T.strip raw, emptyParsedChunkSummaries, Nothing, Nothing)
      _ -> do
        raw <-
          resolveRequiredResponse
            (recResponseFile opts)
            [sessionDir </> "current_reader_response.md"]
            (recSubagentLog opts)
            "Reader"
            "Error: Provide --response-file, --subagent-log, --commentary-file, or write current_reader_response.md."
        pure (parseCombinedResponse raw)

  when (T.null commText) $
    die "Error: Commentary content is empty."

  mExplicitMem <-
    case recMemoryFile opts of
      Nothing -> pure Nothing
      Just memPath -> do
        exists <- doesFileExist memPath
        unless exists $ die ("Error: Memory file not found: " ++ memPath)
        txt <- readTextFileSafe memPath
        let stripped = T.strip txt
        pure (if T.null stripped then Nothing else Just stripped)

  let finalMem =
        case mExplicitMem of
          Just m -> Just m
          Nothing -> mParsedMem
      cleanedCommText = stripLeadingChunkHeading commText
      isWrapupTurn = curIdx >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
      entriesDir = sessionDir </> "entries"

  if isWrapupTurn
    then do
      let curated' = mergeCuratedNarrativeMemory (stCuratedMemory st) finalMem
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
      let (chapNum, chapTitle, partNum, partsTotal) =
            case stCurrentMeta st of
              Just m -> (metaChapterNumber m, metaChapterTitle m, metaPartInChapter m, metaPartsInChapter m)
              Nothing -> (1, "Chapter ?", 1, 1)

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
          linterWarnings = lintReaderCommentary bannedJargon cleanedCommText parsedSummaries mNewlyLoggedPred
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
        else do
          tExists <- doesFileExist topicPromptPath
          when tExists (removeFile topicPromptPath `catch` (\(_ :: IOException) -> pure ()))
      (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
      logPath <- rebuildMasterLog sessionDir st'
      saveState sessionDir st'

      let rotateCritic = curIdx > 1 && (curIdx - 1) `mod` 7 == 0
          rotateFactChecker = curIdx > 1 && (curIdx - 1) `mod` 9 == 0
          rotateJudge = curIdx > 1 && (curIdx - 1) `mod` 11 == 0
          nextHint =
            if curateTopics
              then "Notify prediction-judge (judge_prompt_file), fact-checker (fact_check_prompt_file), commentary-critic (critic_prompt_file), and topic-curator (topic_prompt_file) in parallel with 1-line messages to read their prompt files and write their current_*_response.md files, then run 'lets-read judge --session <dir> --subagent-log <judge_log> --fact-check-log <fact_check_log> --critic-log <critic_log> --topic-log <topic_log>'."
              else "Notify prediction-judge (judge_prompt_file), fact-checker (fact_check_prompt_file), and commentary-critic (critic_prompt_file) in parallel with 1-line messages to read their prompt files and write their current_*_response.md files, then run 'lets-read judge --session <dir> --subagent-log <judge_log> --fact-check-log <fact_check_log> --critic-log <critic_log>'."
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
          , ("active_predictions_count", jsonInt (countActivePredictions (stPredictions st')))
          , ("pending_retirements_count", jsonInt (length pendingRetires))
          , ("linter_warnings_count", jsonInt (length linterWarnings))
          , ("total_predictions_count", jsonInt (length (stPredictions st')))
          , ("prediction_audit_warnings_count", jsonInt (length auditBlocks))
          , ("memory_compaction_needed", jsonBool needsCompaction)
          , ("curated_memory_lines", jsonInt curLines)
          , ("curated_memory_bytes", jsonInt curBytes)
          , ("orchestrator_rule", jsonStr orchestratorRuleText)
          , ("next_step_hint", jsonStr nextHint)
          ]

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
      "Error: Provide --response-file, --subagent-log, or write current_judge_response.md for 'judge'."

  rawFactCheck <-
    resolveRequiredResponse
      (jdgFactCheckResponseFile opts)
      [sessionDir </> "current_fact_check_response.md"]
      (jdgFactCheckLog opts)
      "Fact-check"
      "Error: Provide --fact-check-response-file, --fact-check-log, or write current_fact_check_response.md for 'judge'."
  mFactCheckSearchWeb <-
    case jdgFactCheckLog opts of
      Just fLogPath -> checkSubagentLogUsedSearchWeb fLogPath
      Nothing -> pure Nothing
  let hasFactCheckSearchWeb = fromMaybe True mFactCheckSearchWeb

  rawCritic <-
    resolveRequiredResponse
      (jdgCriticResponseFile opts)
      [sessionDir </> "current_critic_response.md"]
      (jdgCriticLog opts)
      "Critic"
      "Error: Provide --critic-response-file, --critic-log, or write current_critic_response.md for 'judge'."

  let topicPromptPath = sessionDir </> "current_topic_prompt.md"
  hasTopicPrompt <- doesFileExist topicPromptPath
  mRawTopic <-
    if hasTopicPrompt || isJust (jdgTopicResponseFile opts) || isJust (jdgTopicLog opts)
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
              then die "Error: Chunk triggered topic_curation_needed (current_topic_prompt.md exists). Provide --topic-log, --topic-response-file, or write current_topic_response.md for 'judge'."
              else pure Nothing
      else pure Nothing

  (criticFeedbackWritten, criticNotesCount, factCheckPending, factQueriesCount, rejectedCriticQuotesCount) <-
    processCriticFeedback sessionDir st curIdx hasFactCheckSearchWeb (stPendingLinterWarnings st) (Just rawFactCheck) (Just rawCritic)

  let judgeSec = extractJudgeSection rawJudge
      (preds', judgeAuditBlocks, judgeSummaryLines) =
        applyJudgeVerdicts
          curIdx
          (stPredictions st)
          (stPendingRetirements st)
          judgeSec
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
    removeFile topicPromptPath `catch` (\(_ :: IOException) -> pure ())

  removeFileIfExists (sessionDir </> "current_discussion_response.md")

  (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
  logPath <- rebuildMasterLog sessionDir st'
  saveState sessionDir st'

  hasWrapup <- doesFileExist (sessionDir </> "entries" </> "wrapup.md")
  let storyChunksDone = curIdx >= stTotalChunks st
      isFin = storyChunksDone && hasWrapup && not factCheckPending
      statusStr = if factCheckPending then "awaiting_fact_check_response" else "judged"
      nextHint
        | factCheckPending =
            "Fact-checker raised "
              <> jsonInt factQueriesCount
              <> " peer verification query(ies) on Chunk "
              <> jsonInt curIdx
              <> "! Send a 1-line notification via send_message to the active blind-reader subagent to read <session_dir>/current_discussion_prompt.md and write <session_dir>/current_discussion_response.md, then record the response using 'lets-read discuss --session <dir> --subagent-log <reader_log>' BEFORE running 'next'."
        | storyChunksDone && not hasWrapup =
            "All story chunks have been judged! Run 'lets-read next --session <dir>' to unlock the dedicated Final Wrapup Round for blind-reader."
        | otherwise =
            "Run 'lets-read next --session <dir>' to unlock the next chunk (or present the commentary to the user)."
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
      , ("discussion_command_hint", jsonStr "If fact_check_discussion_pending is true, notify blind-reader to read discussion_prompt_file and write discussion_response_file, then run 'lets-read discuss --session <dir> --subagent-log <reader_log>'. If the user replies with comments or questions, run 'lets-read discuss-prompt --session <dir> --user-message \"...\"' (or --user-file), notify blind-reader to read discussion_prompt_file, and record with 'lets-read discuss'.")
      ]

cmdDiscussPrompt :: DiscussPromptOptions -> IO ()
cmdDiscussPrompt opts = do
  sessionDir <- canonicalizePath (dpoSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."
  unless (stCurrentRecorded st) $
    die "Error: Current chunk commentary has not been recorded yet. Run 'record' before 'discuss-prompt'."

  userMsg <-
    case dpoUserMessage opts of
      Just m | not (T.null (T.strip m)) -> pure (T.strip m)
      _ ->
        case dpoUserFile opts of
          Just uPath -> do
            exists <- doesFileExist uPath
            unless exists $ die ("Error: User message file not found: " ++ uPath)
            txt <- readTextFileSafe uPath
            let stripped = T.strip txt
            when (T.null stripped) $ die "Error: User message file is empty."
            pure stripped
          Nothing ->
            die "Error: Provide --user-message <str> or --user-file <path> for 'discuss-prompt'."

  removeFileIfExists (sessionDir </> "current_discussion_response.md")
  (userFile, promptFile) <- writeUserDiscussionPromptFile sessionDir st userMsg
  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "discussion_prompt_ready")
      , ("chunk_index", jsonInt curIdx)
      , ("discussion_prompt_file", jsonStr (T.pack promptFile))
      , ("discussion_response_file", jsonStr (T.pack (sessionDir </> "current_discussion_response.md")))
      , ("user_file", jsonStr (T.pack userFile))
      , ("orchestrator_rule", jsonStr orchestratorRuleText)
      , ("next_step_hint", jsonStr "Send a 1-line notification to blind-reader via send_message to read discussion_prompt_file and write discussion_response_file, then record the reply with 'lets-read discuss --session <dir> --user-file <user_file> --subagent-log <reader_log>'.")
      ]

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

  (mParsedUser, replyText, parsedSummaries, mParsedPredUpdates, mParsedMem) <-
    case (discResponseFile opts, discCommentaryFile opts) of
      (Nothing, Just commPath) -> do
        exists <- doesFileExist commPath
        unless exists $ die ("Error: Commentary file not found: " ++ commPath)
        raw <- readTextFileSafe commPath
        pure (Nothing, T.strip raw, emptyParsedChunkSummaries, Nothing, Nothing)
      _ -> do
        raw <-
          resolveRequiredResponse
            (discResponseFile opts)
            [sessionDir </> "current_discussion_response.md"]
            (discSubagentLog opts)
            "Discussion"
            "Error: Provide --response-file, --subagent-log, --commentary-file, or write current_discussion_response.md."
        pure (parseCombinedResponse raw)

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

  mExplicitMem <-
    case discMemoryFile opts of
      Nothing -> pure Nothing
      Just memPath -> do
        exists <- doesFileExist memPath
        unless exists $ die ("Error: Memory file not found: " ++ memPath)
        txt <- readTextFileSafe memPath
        let stripped = T.strip txt
        pure (if T.null stripped then Nothing else Just stripped)

  let finalMem =
        case mExplicitMem of
          Just m -> Just m
          Nothing -> mParsedMem
      entriesDir = sessionDir </> "entries"
      wrapupPath = entriesDir </> "wrapup.md"
      (chapNum, chapTitle, partNum, partsTotal) =
        case stCurrentMeta st of
          Just m -> (metaChapterNumber m, metaChapterTitle m, metaPartInChapter m, metaPartsInChapter m)
          Nothing -> (1, "Chapter ?", 1, 1)

  hasWrapup <- doesFileExist wrapupPath
  let entryFile =
        if hasWrapup && curIdx >= stTotalChunks st
          then wrapupPath
          else entriesDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")

  entryExists <- doesFileExist entryFile
  unless entryExists $
    die ("Error: Recorded entry file not found: " ++ entryFile)

  let (curated', preds', _, auditBlocks, trackerUpdates) =
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

  when isFactCheckDiscussion $ do
    qExists <- doesFileExist questionsPath
    when qExists (removeFile questionsPath `catch` (\(_ :: IOException) -> pure ()))
  dExists <- doesFileExist discPromptPath
  when dExists (removeFile discPromptPath `catch` (\(_ :: IOException) -> pure ()))
  uExists <- doesFileExist defaultUserFilePath
  when (uExists && not isFactCheckDiscussion) $
    removeFile defaultUserFilePath `catch` (\(_ :: IOException) -> pure ())
  removeFileIfExists (sessionDir </> "current_discussion_response.md")

  mUsedVerifyTools <-
    case discSubagentLog opts of
      Just logPath -> checkSubagentLogUsedVerificationTools logPath
      Nothing -> pure Nothing

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
            , stPredictionAuditWarnings = auditBlocks
            }

  (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
  logPath <- rebuildMasterLog sessionDir st'
  when (memUpdated || isFactCheckDiscussion) $
    saveState sessionDir st'

  stillPending <- doesFileExist questionsPath
  let storyChunksDone = curIdx >= stTotalChunks st && stCurrentRecorded st' && stCurrentJudged st' && not stillPending
      nextHint
        | stillPending =
            "A Fact-Check Peer Query is still pending in current_discussion_prompt.md. Send it to blind-reader and run 'discuss' before 'next'."
        | storyChunksDone && not hasWrapup =
            "Fact-check discussion resolved and all story chunks are judged! Run 'lets-read next --session <dir>' to unlock the dedicated Final Wrapup Round."
        | otherwise =
            "Discussion recorded! Run 'lets-read next --session <dir>' to unlock the next chunk (or present the commentary and discussion to the user)."

  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "discussed")
      , ("chunk_index", jsonInt curIdx)
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

cmdStatus :: FilePath -> IO ()
cmdStatus rawSessionDir = do
  sessionDir <- canonicalizePath rawSessionDir
  st <- loadState sessionDir
  hasWrapup <- doesFileExist (sessionDir </> "entries" </> "wrapup.md")
  hasFactCheckPending <- doesFileExist (sessionDir </> "current_fact_check_questions.md")
  hasTopicPrompt <- doesFileExist (sessionDir </> "current_topic_prompt.md")
  TIO.putStr (renderStateJson sessionDir hasWrapup hasFactCheckPending hasTopicPrompt st)

-- ---------------------------------------------------------------------------
-- Argument Parsing & Entrypoint
-- ---------------------------------------------------------------------------

usage :: String
usage =
  unlines
    [ "Usage: lets-read <command> [options]"
    , ""
    , "Commands:"
    , "  init <source> --session <dir> [--max-words <n>] [--title <str>] [--persona <str>] [--overwrite]"
    , "  next --session <dir> [--force]"
    , "  record --session <dir> [--response-file <path>] [--subagent-log <path>] [--commentary-file <path>] [--memory-file <path>]"
    , "  judge --session <dir> [--response-file <path>] [--subagent-log <path>] [--fact-check-response-file <path>] [--fact-check-log <path>] [--critic-response-file <path>] [--critic-log <path>] [--topic-response-file <path>] [--topic-log <path>]"
    , "  discuss-prompt --session <dir> [--user-message <str>] [--user-file <path>]"
    , "  discuss --session <dir> [--response-file <path>] [--subagent-log <path>] [--commentary-file <path>] [--user-message <str>] [--user-file <path>] [--memory-file <path>]"
    , "  status --session <dir>"
    ]

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

parseNextArgs :: [String] -> IO (FilePath, Bool)
parseNextArgs = go ("", False)
  where
    go (sess, frc) []
      | null sess = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure (sess, frc)
    go (_, frc) ("--session" : v : rest) = go (v, frc) rest
    go (sess, _) ("--force" : rest) = go (sess, True) rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

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

parseDiscussPromptArgs :: [String] -> IO DiscussPromptOptions
parseDiscussPromptArgs = go (DiscussPromptOptions "" Nothing Nothing)
  where
    go opts []
      | null (dpoSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {dpoSession = v} rest
    go opts ("--user-message" : v : rest) = go opts {dpoUserMessage = Just (T.pack v)} rest
    go opts ("--user-file" : v : rest) = go opts {dpoUserFile = Just v} rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

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

parseStatusArgs :: [String] -> IO FilePath
parseStatusArgs = go ""
  where
    go sess []
      | null sess = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure sess
    go _ ("--session" : v : rest) = go v rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

main :: IO ()
main = do
  _ <- setFileCreationMask 0o022
  args <- getArgs
  case args of
    ("--help" : _) -> putStr usage >> exitSuccess
    ("-h" : _) -> putStr usage >> exitSuccess
    ("init" : rest) -> parseInitArgs rest >>= cmdInit
    ("next" : rest) -> do
      (sess, frc) <- parseNextArgs rest
      cmdNext sess frc
    ("record" : rest) -> parseRecordArgs rest >>= cmdRecord
    ("judge" : rest) -> parseJudgeArgs rest >>= cmdJudge
    ("discuss-prompt" : rest) -> parseDiscussPromptArgs rest >>= cmdDiscussPrompt
    ("discuss" : rest) -> parseDiscussArgs rest >>= cmdDiscuss
    ("status" : rest) -> parseStatusArgs rest >>= cmdStatus
    _ -> do
      hPutStrLn stderr usage
      die "Error: Please specify a valid command (init, next, record, judge, discuss-prompt, discuss, status)."
