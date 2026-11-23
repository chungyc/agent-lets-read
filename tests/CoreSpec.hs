{-# LANGUAGE OverloadedStrings #-}

module CoreSpec
  ( testVaultAndChunker
  , testRec1OrchestratorGuardrails
  ) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (buildChunksFromSource)
import LetsRead.Types
  ( Chunk (..)
  , SessionState (..)
  , chunkToMeta
  , loadState
  , loadVaultChunk
  , orchestratorRuleText
  , saveState
  , saveVault
  )
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (readProcessWithExitCode)
import TestHarness
  ( assertBool
  , assertEq
  , baseDummyState
  , normWs
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

  let draftScenePath = tmp </> "draft_scene.md"
  TIO.writeFile
    draftScenePath
    ( T.unlines
        [ "## I"
        , ""
        , "Mara gave the usual disclaimer, burned the initial draft of the letter, and sealed the final version in wax."
        , ""
        , "## II"
        , ""
        , "By dawn the courier had reached the lighthouse."
        ]
    )
  (_, draftSceneChunks) <- buildChunksFromSource draftScenePath 900 Nothing
  assertEq
    "Short numeral-headed opening scene mentioning 'disclaimer' / 'initial draft' / 'final version' stays Chapter 1"
    [1, 2]
    (map chapterNumber draftSceneChunks)

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
      let repoDir = takeDirectory (takeDirectory (takeDirectory (takeDirectory binPath)))
          agentFiles =
            [ "blind-reader.md"
            , "prediction-judge.md"
            , "fact-checker.md"
            , "commentary-critic.md"
            , "topic-curator.md"
            ]
      forM_ agentFiles $ \af -> do
        agentTxt <- TIO.readFile (repoDir </> "agents" </> af)
        assertBool
          (af ++ " forbids run_command, edit_file, and send_message concisely")
          ("- Never call `run_command`, `edit_file`, or `send_message`." `T.isInfixOf` agentTxt)
        assertBool
          (af ++ " omits misleading 'reply to the host' phrasing")
          (not ("reply to the host" `T.isInfixOf` T.toLower agentTxt))
      forM_ ["blind-reader.md", "fact-checker.md"] $ \af -> do
        agentTxt <- TIO.readFile (repoDir </> "agents" </> af)
        let normTxt = normWs agentTxt
        assertBool
          (af ++ " includes compact Session File Map & Lookup Rules section")
          ("#### Session File Map & Lookup Rules" `T.isInfixOf` agentTxt)
        assertBool
          (af ++ " includes pick-one-axis and topic-shard freshness rules")
          ( "Pick one index axis" `T.isInfixOf` normTxt
              && "topic shard numbers" `T.isInfixOf` T.toLower normTxt
              && "by_topic.md" `T.isInfixOf` normTxt
          )
      criticTxt <- normWs <$> TIO.readFile (repoDir </> "agents" </> "commentary-critic.md")
      assertBool
        "commentary-critic.md directs scanning entries/by_chronology.md summaries first"
        ("entries/by_chronology.md" `T.isInfixOf` criticTxt && "[Entry]" `T.isInfixOf` criticTxt)
      judgeTxt <- normWs <$> TIO.readFile (repoDir </> "agents" </> "prediction-judge.md")
      assertBool
        "prediction-judge.md directs jumping to L1_XXXX.md from memory.md and predictions/by_chronology.md for resolved history"
        ("chunks/archive/chronology/L1_XXXX.md" `T.isInfixOf` judgeTxt && "predictions/by_chronology.md" `T.isInfixOf` judgeTxt)
      curatorTxt <- normWs <$> TIO.readFile (repoDir </> "agents" </> "topic-curator.md")
      assertBool
        "topic-curator.md prioritizes chunks/by_topic.md for ambiguous story entities"
        ("start with `<session_dir>/chunks/by_topic.md`" `T.isInfixOf` curatorTxt)
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
