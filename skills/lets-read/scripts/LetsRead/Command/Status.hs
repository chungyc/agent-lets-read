{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : LetsRead.Command.Status
-- Description : Handler and CLI parser for the 'status' subcommand
--
-- Reads the persisted session state (@.state.bin@) and current session files,
-- rendering the full JSON status object to stdout without mutating session state.
module LetsRead.Command.Status
  ( parseStatusArgs
  , cmdStatus
  ) where

import qualified Data.Text.IO as TIO
import LetsRead.Command.Common (usage)
import LetsRead.Types
  ( loadState
  , renderStateJson
  )
import System.Directory
  ( canonicalizePath
  , doesFileExist
  )
import System.Exit (die)
import System.FilePath ((</>))

-- | Parse CLI arguments for the @status@ subcommand, returning the session directory path.
parseStatusArgs :: [String] -> IO FilePath
parseStatusArgs = go ""
  where
    go sess []
      | null sess = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure sess
    go _ ("--session" : v : rest) = go v rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

-- | Execute the @status@ subcommand: load @.state.bin@, inspect active prompt
-- and wrapup files in the session directory, and print the JSON status summary.
cmdStatus :: FilePath -> IO ()
cmdStatus rawSessionDir = do
  sessionDir <- canonicalizePath rawSessionDir
  st <- loadState sessionDir
  hasWrapup <- doesFileExist (sessionDir </> "entries" </> "wrapup.md")
  hasFactCheckPending <- doesFileExist (sessionDir </> "current_fact_check_questions.md")
  hasTopicPrompt <- doesFileExist (sessionDir </> "current_topic_prompt.md")
  TIO.putStr (renderStateJson sessionDir hasWrapup hasFactCheckPending hasTopicPrompt st)
