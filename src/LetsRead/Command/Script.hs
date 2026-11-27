{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : LetsRead.Command.Script
-- Description : Handler and CLI parser for the 'script' subcommand
--
-- Ingests the stateless @lets-read-script-writer@ subagent's unresearched draft reaction
-- (@current_script_response.md@), embeds the stripped draft into
-- @current_research_prompt.md@ for @lets-read-researcher@, and immediately deletes both
-- @current_script_prompt.md@ and @current_script_response.md@ so no script file
-- remains on disk to contaminate @lets-read-blind-reader@.
module LetsRead.Command.Script
  ( ScriptOptions (..)
  , parseScriptArgs
  , cmdScript
  ) where

import Control.Monad (when)
import Data.Maybe (isNothing)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Command.Common
  ( removeFileIfExists
  , resolveRequiredResponse
  , usage
  )
import LetsRead.Prompts (writeCurrentResearchPromptFile)
import LetsRead.Types
  ( SessionFileStatus (..)
  , SessionState (..)
  , jsonBool
  , jsonInt
  , jsonObject
  , jsonStr
  , loadState
  , orchestratorRuleText
  , padChunkNumber
  , readSessionFileStatus
  , saveState
  , stripToolReceiptComments
  )
import System.Directory (canonicalizePath)
import System.Exit (die)
import System.FilePath ((</>))

-- | Command-line options for @lets-read script@.
data ScriptOptions = ScriptOptions
  { scrOptSession :: FilePath
  -- ^ Target session directory.
  , scrOptResponseFile :: Maybe FilePath
  -- ^ Optional explicit path to the @lets-read-script-writer@ response file.
  , scrOptSubagentLog :: Maybe FilePath
  -- ^ Optional path or conversation ID for the @lets-read-script-writer@ transcript log.
  }

-- | Parse CLI arguments for the @script@ subcommand.
parseScriptArgs :: [String] -> IO ScriptOptions
parseScriptArgs = go (ScriptOptions "" Nothing Nothing)
  where
    go opts []
      | null (scrOptSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {scrOptSession = v} rest
    go opts ("--response-file" : v : rest) = go opts {scrOptResponseFile = Just v} rest
    go opts ("--subagent-log" : v : rest) = go opts {scrOptSubagentLog = Just v} rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

-- | Execute the @script@ subcommand: resolve @lets-read-script-writer@'s draft, write
-- @current_research_prompt.md@ with the stripped draft embedded, immediately
-- delete @current_script_prompt.md@ and @current_script_response.md@, update
-- @state.json@, and emit a JSON status summary.
cmdScript :: ScriptOptions -> IO ()
cmdScript opts = do
  sessionDir <- canonicalizePath (scrOptSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."

  let isWrapupTurn = curIdx >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
      scriptPromptPath = sessionDir </> "current_script_prompt.md"
      scriptRespPath = sessionDir </> "current_script_response.md"
      researchRespPath = sessionDir </> "current_research_response.md"
      researchFilePath = sessionDir </> "current_research.md"
      readerPromptPath = sessionDir </> "current_prompt.md"
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

  when (not hasScriptPrompt && isNothing (scrOptResponseFile opts)) $ do
    when hasResearchPrompt $
      die "Error: 'script' has already completed and current_research_prompt.md is active. Wait for lets-read-researcher and run 'lets-read research' next."
    when hasActiveReaderPrompt $
      die "Error: 'script' and 'research' have already completed and current_prompt.md is active. Wait for lets-read-blind-reader and run 'lets-read record' next."
    die "Error: No active current_script_prompt.md found. Run 'lets-read next --session <dir>' first."

  let roundTag = if isWrapupTurn then "Wrapup" else "Chunk " <> T.pack (padChunkNumber curIdx)
      roundTagStr = T.unpack roundTag

  rawScript <-
    resolveRequiredResponse
      (scrOptResponseFile opts)
      [scriptRespPath]
      (scrOptSubagentLog opts)
      "Script writer"
      ( "Error: current_script_response.md has not been written yet (lets-read-script-writer is still running). Do not re-message lets-read-script-writer; end your turn with ZERO tool calls outputting ONLY '[HOST_WAIT | "
          ++ roundTagStr
          ++ " | script | 0/1 idle | pending: lets-read-script-writer]' and wait for '[SUBAGENT_DONE | "
          ++ roundTagStr
          ++ " | lets-read-script-writer]' before running 'script'."
      )

  let strippedDraft = T.strip (stripToolReceiptComments rawScript)
  when (T.null strippedDraft) $
    die "Error: Script draft content in current_script_response.md is empty."

  removeFileIfExists researchRespPath
  removeFileIfExists researchFilePath
  removeFileIfExists readerPromptPath
  removeFileIfExists readerRespPath

  writtenResearchPrompt <- writeCurrentResearchPromptFile sessionDir st isWrapupTurn strippedDraft

  removeFileIfExists scriptPromptPath
  removeFileIfExists scriptRespPath

  saveState sessionDir st

  let dispatchResearcherHint =
        "Kill the finished one-shot lets-read-script-writer immediately via manage_subagents(Action: \"kill\"), invoke a fresh one-shot lets-read-researcher subagent via invoke_subagent (Model: \"flash\") with a 1-line notification to read research_prompt_file and write research_response_file, then park with ZERO tool calls outputting ONLY '[HOST_WAIT | "
          <> roundTag
          <> " | research | 0/1 idle | pending: lets-read-researcher]'; once '[SUBAGENT_DONE | "
          <> roundTag
          <> " | lets-read-researcher]' arrives, run 'lets-read research --session <dir> --subagent-log <research_log>'."

  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "awaiting_research")
      , ("chunk_index", jsonInt curIdx)
      , ("total_chunks", jsonInt (stTotalChunks st))
      , ("is_wrapup", jsonBool isWrapupTurn)
      , ("research_prompt_file", jsonStr (T.pack writtenResearchPrompt))
      , ("research_response_file", jsonStr (T.pack researchRespPath))
      , ("script_files_deleted", jsonBool True)
      , ("rotate_researcher_recommended", jsonBool True)
      , ("orchestrator_rule", jsonStr orchestratorRuleText)
      , ("next_step_hint", jsonStr dispatchResearcherHint)
      ]
