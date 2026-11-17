{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : LetsRead.Command.DiscussPrompt
-- Description : Handler and CLI parser for the 'discuss-prompt' subcommand
--
-- Prepares @current_discussion_prompt.md@ and @last_user_message.md@ in the
-- session directory so the @blind-reader@ subagent can respond to a user
-- question or comment on the current chunk (or post-wrapup).
module LetsRead.Command.DiscussPrompt
  ( DiscussPromptOptions (..)
  , parseDiscussPromptArgs
  , cmdDiscussPrompt
  ) where

import Control.Monad (unless, when)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Command.Common (removeFileIfExists, usage)
import LetsRead.Prompts (writeUserDiscussionPromptFile)
import LetsRead.Types
  ( SessionState (..)
  , jsonInt
  , jsonObject
  , jsonStr
  , loadState
  , orchestratorRuleText
  , readTextFileSafe
  )
import System.Directory
  ( canonicalizePath
  , doesFileExist
  )
import System.Exit (die)
import System.FilePath ((</>))

-- | Command-line options for @lets-read discuss-prompt@.
data DiscussPromptOptions = DiscussPromptOptions
  { dpoSession :: FilePath
  -- ^ Target session directory.
  , dpoUserMessage :: Maybe Text
  -- ^ Inline user message string (@--user-message@).
  , dpoUserFile :: Maybe FilePath
  -- ^ Path to a file containing the user message (@--user-file@).
  }

-- | Parse CLI arguments for the @discuss-prompt@ subcommand.
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

-- | Execute the @discuss-prompt@ subcommand: read the user's question or
-- comment, write @last_user_message.md@ and @current_discussion_prompt.md@,
-- clear any stale @current_discussion_response.md@, and print a JSON status object.
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
