{-# LANGUAGE OverloadedStrings #-}

module CoreSpec
  ( testVaultAndChunker
  , testRec1OrchestratorGuardrails
  ) where

import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (buildChunksFromSource)
import LetsRead.Types
  ( SessionState (..)
  , chunkToMeta
  , loadState
  , loadVaultChunk
  , orchestratorRuleText
  , saveState
  , saveVault
  )
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import TestHarness
  ( assertBool
  , assertEq
  , baseDummyState
  , withTempDir
  )

testVaultAndChunker :: IO ()
testVaultAndChunker = withTempDir "vault" $ \tmp -> do
  putStrLn "== Core Vault, State & Chunker =="
  let srcPath = tmp </> "story.md"
      chapBody = T.unwords (replicate 120 "The lantern flickered across the harbor water.")
      storyDoc =
        T.unlines
          [ "# The Harbor Lantern"
          , ""
          , "Written by A. Author"
          , ""
          , "## Chapter 1: Arrival"
          , ""
          , chapBody
          , ""
          , "## Chapter 2: Departure"
          , ""
          , chapBody
          ]
  TIO.writeFile srcPath storyDoc
  (defaultDetectedTitle, _) <- buildChunksFromSource srcPath 900 Nothing
  assertEq "Default markdown title uses file basename" "story" defaultDetectedTitle
  (title, chunks) <- buildChunksFromSource srcPath 900 (Just "The Harbor Lantern")
  assertEq "Title override preserved" "The Harbor Lantern" title
  assertBool "Front matter + 2 chapters chunked" (length chunks >= 3)

  let vaultPath = tmp </> ".vault.bin"
  saveVault vaultPath chunks
  c2 <- loadVaultChunk vaultPath 2
  assertEq "Vault round-trip preserves chunk 2" (chunks !! 1) c2

  let sessDir = tmp </> "sess"
  createDirectoryIfMissing True (sessDir </> "entries")
  createDirectoryIfMissing True (sessDir </> "predictions")
  let st0 = (baseDummyState (length chunks)) {stCurrentMeta = Just (chunkToMeta c2)}
  saveState sessDir st0
  stLoaded <- loadState sessDir
  assertEq "SessionState binary serialization round-trip" st0 stLoaded

testRec1OrchestratorGuardrails :: Maybe FilePath -> IO ()
testRec1OrchestratorGuardrails mBinPath = do
  putStrLn "== Rec #1: Orchestrator Anti-Race Guardrails & Topic-Curator Cleanup Hints =="
  assertBool
    "orchestratorRuleText forbids calling record/judge/discuss before idle notices"
    ("NEVER call 'record', 'judge', or 'discuss'" `T.isInfixOf` orchestratorRuleText)
  assertBool
    "orchestratorRuleText forbids emitting Waiting... alongside CLI calls"
    ("Waiting..." `T.isInfixOf` orchestratorRuleText && "ZERO tool calls" `T.isInfixOf` orchestratorRuleText)
  assertBool
    "orchestratorRuleText directs status check via lets-read status"
    ("lets-read status --session <dir>" `T.isInfixOf` orchestratorRuleText)

  case mBinPath of
    Nothing -> pure ()
    Just binPath -> withTempDir "rec1-cli" $ \tmp -> do
      let srcPath = tmp </> "mini.md"
          sessDir = tmp </> "session"
      TIO.writeFile
        srcPath
        ( T.unlines
            [ "## Chapter 1: Harbor"
            , ""
            , T.unwords (replicate 120 "Inspector Lin examined the brass compass on the dock.")
            , ""
            , "## Chapter 2: Lighthouse"
            , ""
            , T.unwords (replicate 120 "Mara climbed the spiral stairs toward the beacon.")
            ]
        )
      (ecInit, _, errInit) <- readProcessWithExitCode binPath ["init", srcPath, "--session", sessDir] ""
      assertEq ("CLI init exit 0 (" ++ errInit ++ ")") ExitSuccess ecInit
      initLogTxt <- TIO.readFile (sessDir </> "lets_read_log.md")
      assertBool "lets_read_log.md after init uses ## Reader Persona heading" ("## Reader Persona" `T.isInfixOf` initLogTxt)
      assertBool "lets_read_log.md after init omits *Reader Persona*: pseudo-heading" (not ("*Reader Persona*:" `T.isInfixOf` initLogTxt))
      let initHeaderLines = takeWhile (/= "---") (T.lines initLogTxt)
      assertBool
        "lets_read_log.md header prose lines after init wrap <= 80 cols"
        (all (\l -> "#" `T.isPrefixOf` l || T.length l <= 80) initHeaderLines)

      (ecNext, outNext, _) <- readProcessWithExitCode binPath ["next", "--session", sessDir] ""
      assertEq "CLI next exit 0" ExitSuccess ecNext
      assertBool "next hint forbids Waiting... race" ("ZERO tool calls" `isInfixOf` outNext && "Waiting..." `isInfixOf` outNext)

      let readerResp = sessDir </> "current_reader_response.md"
      TIO.writeFile
        readerResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_chunk.md, memory.md) -->"
            , "=== COMMENTARY ==="
            , "> \"Inspector Lin examined the brass compass on the dock.\""
            , ""
            , "That compass is definitely planted!"
            , ""
            , "- **[Predicted Chunk 0001 | Topics: Inspector Lin, Brass Compass, Harbor]** **Clue/Anomaly**: Lin finds an unmarked brass compass on the dock -> **Theory**: Mara left the compass as a signal for Lin (vs. **Plausible Rival**: A dockworker dropped it during cargo unloading)"
            , ""
            , "=== CHUNK SUMMARY ==="
            , "- **[Story | Topics: Inspector Lin, Brass Compass, Harbor]** *Brass* compass appears on the dock as Inspector Lin arrives."
            , "- **[Entry | Topics: Inspector Lin, Brass Compass, Harbor]** Suspicion over the planted dockside compass."
            , ""
            , "=== PREDICTION UPDATES ==="
            , "- **[Predicted Chunk 0001 | Topics: Inspector Lin, Brass Compass, Harbor]** **Clue/Anomaly**: Lin finds an unmarked brass compass on the dock -> **Theory**: Mara left the compass as a signal for Lin (vs. **Plausible Rival**: A dockworker dropped it during cargo unloading)"
            , ""
            , "=== UPDATED MEMORY ==="
            , "## Story Summary So Far"
            , "- **Core Premise, Timeline & Baseline Facts (Persistent)**: Coastal mystery following Inspector Lin and Mara at the harbor."
            ]
        )
      (ecRec, outRec, _) <- readProcessWithExitCode binPath ["record", "--session", sessDir] ""
      assertEq "CLI record exit 0" ExitSuccess ecRec
      assertBool "record hint enforces waiting for all reviewers with ZERO tool calls" ("ZERO tool calls" `isInfixOf` outRec && "Waiting..." `isInfixOf` outRec)

      TIO.writeFile
        (sessDir </> "current_judge_response.md")
        "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0001 -> ACTIVE]** Solid cross-thread setup.\n"
      TIO.writeFile
        (sessDir </> "current_fact_check_response.md")
        "<!-- TOOLS: read_file(current_chunk.md, entries/chunk_0001.md, memory.md) -->\n=== VERIFIED CLAIMS LOG ===\n- [OK | Source: current_chunk.md] Lin examined the brass compass on the dock.\n\n=== DISPUTED FACTS & MEMORY CHECKS ===\n- PASS\n"
      TIO.writeFile
        (sessDir </> "current_critic_response.md")
        "=== PERSONA & STYLE CRITIQUE ===\n- **[Persona & Lens]** Conversational voice.\n- **[What Worked Well]** Punchy reaction.\n- **[Where the Voice Drifted or Felt Formulaic]** Keep varying rhythm.\n"

      (ecJ1, outJ1, _) <- readProcessWithExitCode binPath ["judge", "--session", sessDir] ""
      assertEq "CLI judge (no topic-curator) exit 0" ExitSuccess ecJ1
      assertBool "judge without topic-curator omits topic-curator kill prompt" (not ("topic-curator" `isInfixOf` outJ1))

      let topicResp = tmp </> "topic_resp.md"
      TIO.writeFile topicResp "=== TOPIC MERGES ===\n- NONE\n"
      (ecJ2, outJ2, _) <- readProcessWithExitCode binPath ["judge", "--session", sessDir, "--topic-response-file", topicResp] ""
      assertEq "CLI judge (with topic-curator) exit 0" ExitSuccess ecJ2
      assertBool
        "judge with topic-curator reminds orchestrator to kill topic-curator"
        ("topic-curator" `isInfixOf` outJ2 && "manage_subagents" `isInfixOf` outJ2)
      rebuiltLogTxt <- TIO.readFile (sessDir </> "lets_read_log.md")
      assertBool "lets_read_log.md after rebuildMasterLog uses ## Reader Persona heading" ("## Reader Persona" `T.isInfixOf` rebuiltLogTxt)
      assertBool "lets_read_log.md after rebuildMasterLog omits *Reader Persona*: pseudo-heading" (not ("*Reader Persona*:" `T.isInfixOf` rebuiltLogTxt))
      let rebuiltHeaderLines = takeWhile (/= "---") (T.lines rebuiltLogTxt)
      assertBool
        "lets_read_log.md header prose lines after rebuildMasterLog wrap <= 80 cols"
        (all (\l -> "#" `T.isPrefixOf` l || T.length l <= 80) rebuiltHeaderLines)
