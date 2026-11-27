#!/usr/bin/env runghc
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Spoiler-free Gatekeeper CLI for AI-hosted Let's Reads
--
-- Orchestrates story ingestion, chunk unlocking, commentary recording,
-- prediction judging, fact-check receipt verification, persona/style
-- critique routing, and multi-layer indexing.

module Main (main) where

import LetsRead.Command.Common (usage)
import LetsRead.Command.Discuss (cmdDiscuss, parseDiscussArgs)
import LetsRead.Command.DiscussPrompt (cmdDiscussPrompt, parseDiscussPromptArgs)
import LetsRead.Command.Init (cmdInit, parseInitArgs)
import LetsRead.Command.Judge (cmdJudge, parseJudgeArgs)
import LetsRead.Command.Next (cmdNext, parseNextArgs)
import LetsRead.Command.Record (cmdRecord, parseRecordArgs)
import LetsRead.Command.Research (cmdResearch, parseResearchArgs)
import LetsRead.Command.Script (cmdScript, parseScriptArgs)
import LetsRead.Command.Status (cmdStatus, parseStatusArgs)
import System.Environment (getArgs)
import System.Exit (die, exitSuccess)
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (setFileCreationMask)

-- | CLI entrypoint: sets a default @0o022@ file creation mask and dispatches
-- the requested @lets-read@ subcommand.
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
    ("script" : rest) -> parseScriptArgs rest >>= cmdScript
    ("research" : rest) -> parseResearchArgs rest >>= cmdResearch
    ("record" : rest) -> parseRecordArgs rest >>= cmdRecord
    ("judge" : rest) -> parseJudgeArgs rest >>= cmdJudge
    ("discuss-prompt" : rest) -> parseDiscussPromptArgs rest >>= cmdDiscussPrompt
    ("discuss" : rest) -> parseDiscussArgs rest >>= cmdDiscuss
    ("status" : rest) -> parseStatusArgs rest >>= cmdStatus
    _ -> do
      hPutStrLn stderr usage
      die "Error: Please specify a valid command (init, next, script, research, record, judge, discuss-prompt, discuss, status)."
