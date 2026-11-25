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
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
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
    "orchestratorRuleText forbids calling script/research/record/judge/discuss before [SUBAGENT_DONE"
    ( "NEVER call 'script', 'research', 'record', 'judge', or 'discuss'" `T.isInfixOf` orchestratorRuleText
        && "[SUBAGENT_DONE | <round> | <role>]" `T.isInfixOf` orchestratorRuleText
    )
  assertBool
    "orchestratorRuleText mandates [HOST_WAIT token with ZERO tool calls without priming prohibited tokens"
    ( "[HOST_WAIT | <round> | <phase>" `T.isInfixOf` orchestratorRuleText
        && "ZERO tool calls" `T.isInfixOf` orchestratorRuleText
        && not ("never emit '[SUBAGENT_DONE'" `T.isInfixOf` orchestratorRuleText)
    )
  assertBool
    "orchestratorRuleText directs status check via lets-read status"
    ("lets-read status --session <dir>" `T.isInfixOf` orchestratorRuleText)

  case mBinPath of
    Nothing -> pure ()
    Just binPath -> withTempDir "rec1-cli" $ \tmp -> do
      let repoDir = takeDirectory (takeDirectory (takeDirectory (takeDirectory binPath)))
          agentFiles =
            [ ("script-writer.md", "model: flash")
            , ("researcher.md", "model: flash")
            , ("blind-reader.md", "model: inherit")
            , ("prediction-judge.md", "model: inherit")
            , ("fact-checker.md", "model: inherit")
            , ("commentary-critic.md", "model: inherit")
            , ("topic-curator.md", "model: flash_lite")
            ]
      forM_ agentFiles $ \(af, expectedModel) -> do
        agentTxt <- TIO.readFile (repoDir </> "agents" </> af)
        assertBool
          (af ++ " declares expected frontmatter " ++ T.unpack expectedModel)
          (("\n" <> expectedModel <> "\n") `T.isInfixOf` agentTxt)
        assertBool
          (af ++ " forbids run_command, edit_file, and send_message concisely")
          ("- Never call `run_command`, `edit_file`, or `send_message`." `T.isInfixOf` agentTxt)
        assertBool
          (af ++ " omits misleading 'reply to the host' phrasing and uses [SUBAGENT_DONE |")
          ( not ("reply to the host" `T.isInfixOf` T.toLower agentTxt)
              && "[SUBAGENT_DONE |" `T.isInfixOf` agentTxt
          )
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
      assertBool
        "next unlocks awaiting_script with Model: \"flash\", [HOST_WAIT | Chunk 0001 | script], and [SUBAGENT_DONE | Chunk 0001 | script-writer]"
        ( "\"status\": \"awaiting_script\"" `isInfixOf` outNext
            && "\"is_wrapup\": false" `isInfixOf` outNext
            && "Model: \\\"flash\\\"" `isInfixOf` outNext
            && "ZERO tool calls" `isInfixOf` outNext
            && "[HOST_WAIT | Chunk 0001 | script | 0/1 idle | pending: script-writer]" `isInfixOf` outNext
            && "[SUBAGENT_DONE | Chunk 0001 | script-writer]" `isInfixOf` outNext
        )

      (ecStatScript, outStatScript, _) <- readProcessWithExitCode binPath ["status", "--session", sessDir] ""
      assertEq "CLI status during awaiting_script exit 0" ExitSuccess ecStatScript
      assertBool
        "status reports awaiting_script true and awaiting_research/awaiting_reader false"
        ( "\"awaiting_script\": true" `isInfixOf` outStatScript
            && "\"awaiting_research\": false" `isInfixOf` outStatScript
            && "\"awaiting_reader\": false" `isInfixOf` outStatScript
        )

      (ecEarlyRes, _, _) <- readProcessWithExitCode binPath ["research", "--session", sessDir] ""
      assertBool "CLI research is gated while awaiting_script" (ecEarlyRes /= ExitSuccess)
      (ecEarlyRec1, _, _) <- readProcessWithExitCode binPath ["record", "--session", sessDir] ""
      assertBool "CLI record is gated while awaiting_script" (ecEarlyRec1 /= ExitSuccess)

      let scriptResp = sessDir </> "current_script_response.md"
          researchResp = sessDir </> "current_research_response.md"
          readerResp = sessDir </> "current_reader_response.md"
          secretCanaryPhrase = "CANARY_SECRET_MARKER_0001"
      TIO.writeFile
        scriptResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_chunk.md, memory.md) -->"
            , "=== DRAFT COMMENTARY ==="
            , "> \"Inspector Lin examined the brass compass on the dock.\""
            , ""
            , "Unresearched canary riff " <> T.pack secretCanaryPhrase <> " wondering about harbor compasses!"
            , ""
            , "=== DRAFT PREDICTION ==="
            , "- **[Predicted Chunk 0001 | Topics: Inspector Lin, Brass Compass]** **Clue/Anomaly**: Unmarked compass -> **Theory**: Mara left it"
            ]
        )
      (ecScr1, outScr1, errScr1) <- readProcessWithExitCode binPath ["script", "--session", sessDir] ""
      assertEq ("CLI script chunk 1/2 exit 0 (" ++ errScr1 ++ ")") ExitSuccess ecScr1
      assertBool
        "script transitions to awaiting_research with Model: \"flash\" and reminds host to kill script-writer"
        ( "\"status\": \"awaiting_research\"" `isInfixOf` outScr1
            && "script-writer" `isInfixOf` outScr1
            && "Model: \\\"flash\\\"" `isInfixOf` outScr1
            && "manage_subagents" `isInfixOf` outScr1
            && "ZERO tool calls" `isInfixOf` outScr1
        )
      hasScriptPromptAfterScr <- doesFileExist (sessDir </> "current_script_prompt.md")
      hasScriptRespAfterScr <- doesFileExist scriptResp
      assertBool
        "script immediately deletes current_script_prompt.md and current_script_response.md"
        (not hasScriptPromptAfterScr && not hasScriptRespAfterScr)

      (ecStatRes, outStatRes, _) <- readProcessWithExitCode binPath ["status", "--session", sessDir] ""
      assertEq "CLI status during awaiting_research exit 0" ExitSuccess ecStatRes
      assertBool
        "status reports awaiting_research true"
        ( "\"awaiting_script\": false" `isInfixOf` outStatRes
            && "\"awaiting_research\": true" `isInfixOf` outStatRes
            && "\"awaiting_reader\": false" `isInfixOf` outStatRes
        )
      (ecEarlyRec2, _, _) <- readProcessWithExitCode binPath ["record", "--session", sessDir] ""
      assertBool "CLI record is gated while awaiting_research" (ecEarlyRec2 /= ExitSuccess)

      TIO.writeFile
        researchResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_chunk.md, memory.md) -->"
            , "=== RESEARCH NOTES ==="
            , "- NONE"
            ]
        )
      (ecRes1, outRes1, errRes1) <- readProcessWithExitCode binPath ["research", "--session", sessDir] ""
      assertEq ("CLI research chunk 1/2 exit 0 (" ++ errRes1 ++ ")") ExitSuccess ecRes1
      assertBool
        "research unlocks chunk for blind-reader and reminds host to kill one-shot researcher"
        ("\"status\": \"unlocked\"" `isInfixOf` outRes1 && "ZERO tool calls" `isInfixOf` outRes1 && "Kill the finished one-shot researcher" `isInfixOf` outRes1)
      hasResPromptAfterRes <- doesFileExist (sessDir </> "current_research_prompt.md")
      hasResRespAfterRes <- doesFileExist researchResp
      hasResPacket1 <- doesFileExist (sessDir </> "current_research.md")
      assertBool
        "research deletes current_research_prompt.md and current_research_response.md and writes current_research.md"
        (not hasResPromptAfterRes && not hasResRespAfterRes && hasResPacket1)
      resPacket1Txt <- TIO.readFile (sessDir </> "current_research.md")
      readerPrompt1Txt <- TIO.readFile (sessDir </> "current_prompt.md")
      assertBool
        "blind-reader files contain zero trace of the deleted canary draft"
        ( not (T.pack secretCanaryPhrase `T.isInfixOf` resPacket1Txt)
            && not (T.pack secretCanaryPhrase `T.isInfixOf` readerPrompt1Txt)
        )
      (ecStatReader, outStatReader, _) <- readProcessWithExitCode binPath ["status", "--session", sessDir] ""
      assertEq "CLI status during awaiting_reader exit 0" ExitSuccess ecStatReader
      assertBool
        "status reports awaiting_reader true once current_prompt.md is unlocked"
        ( "\"awaiting_script\": false" `isInfixOf` outStatReader
            && "\"awaiting_research\": false" `isInfixOf` outStatReader
            && "\"awaiting_reader\": true" `isInfixOf` outStatReader
        )

      TIO.writeFile
        readerResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_chunk.md, memory.md, current_research.md) -->"
            , "=== COMMENTARY ==="
            , "> \"Inspector Lin examined the brass compass on the dock.\""
            , ""
            , "That compass is definitely planted!"
            , ""
            , "=== CHUNK SUMMARY ==="
            , "- **[Story | Topics: Inspector Lin, Brass Compass, Harbor]** *Brass* compass appears on the dock as Inspector Lin arrives."
            , "- **[Entry | Topics: Inspector Lin, Brass Compass, Harbor]** Suspicion over the planted dockside compass."
            , ""
            , "=== PREDICTION UPDATES ==="
            , "- **[Predicted Chunk 0001 | Topics: Inspector Lin, Brass Compass, Harbor]** **Clue/Anomaly**: Lin finds an unmarked brass compass on the dock -> **Theory**: Mara left the compass as a signal for Lin"
            , ""
            , "=== UPDATED MEMORY ==="
            , "## Story Summary So Far"
            , "- **Core Premise, Timeline & Baseline Facts (Persistent)**: Coastal mystery following Inspector Lin and Mara at the harbor."
            ]
        )
      (ecRec, outRec, _) <- readProcessWithExitCode binPath ["record", "--session", sessDir] ""
      assertEq "CLI record exit 0" ExitSuccess ecRec
      assertBool
        "record hint enforces concrete initial [HOST_WAIT | Chunk 0001 | judge | 0/3 idle] and [SUBAGENT_DONE | Chunk 0001 | <role>] with ZERO tool calls"
        ( "ZERO tool calls" `isInfixOf` outRec
            && "[HOST_WAIT | Chunk 0001 | judge | 0/3 idle | pending: prediction-judge, fact-checker, commentary-critic]" `isInfixOf` outRec
            && "[SUBAGENT_DONE | Chunk 0001 | <role>]" `isInfixOf` outRec
        )
      preJudgeEntry1Txt <- TIO.readFile (sessDir </> "entries" </> "chunk_0001.md")
      assertBool
        "record writes temporary Prediction Tracker Update (Reader Proposal) callout before judge runs"
        ("Prediction Tracker Update (Reader Proposal)" `T.isInfixOf` preJudgeEntry1Txt)

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
      assertBool
        "judge folds reader's proposed Clue/Anomaly -> Theory into a single Prediction Judge Rulings callout"
        ( "**Prediction Judge Rulings (Chunk 0001)**:" `T.isInfixOf` rebuiltLogTxt
            && "Lin finds an unmarked brass compass on the dock -> **Theory**: Mara left the compass as a signal for Lin" `T.isInfixOf` rebuiltLogTxt
            && not ("Prediction Tracker Update (Reader Proposal)" `T.isInfixOf` rebuiltLogTxt)
        )
      assertBool "lets_read_log.md after rebuildMasterLog uses ## Reader Persona heading" ("## Reader Persona" `T.isInfixOf` rebuiltLogTxt)
      assertBool "lets_read_log.md after rebuildMasterLog omits *Reader Persona*: pseudo-heading" (not ("*Reader Persona*:" `T.isInfixOf` rebuiltLogTxt))
      let rebuiltHeaderLines = takeWhile (/= "---") (T.lines rebuiltLogTxt)
      assertBool
        "lets_read_log.md header prose lines after rebuildMasterLog wrap <= 80 cols"
        (all (\l -> "#" `T.isPrefixOf` l || T.length l <= 80) rebuiltHeaderLines)

      skillTxt <- TIO.readFile (repoDir </> "skills" </> "lets-read" </> "SKILL.md")
      let (beforeStep5, fromStep5) = T.breakOn "### Step 5: Interactive Discussion vs. Batch Progression" skillTxt
      assertBool
        "SKILL.md contains Step 5 heading"
        (not (T.null fromStep5))
      assertBool
        "SKILL.md places Step 6 Final Wrapup after Step 5 rather than inside Step 4"
        ( not ("Dedicated Final Wrapup Round" `T.isInfixOf` beforeStep5)
            && "### Step 6: Dedicated Final Wrapup Round" `T.isInfixOf` fromStep5
            && not ("Step 4.7" `T.isInfixOf` skillTxt)
        )
      let (_, fromStep6) = T.breakOn "### Step 6: Dedicated Final Wrapup Round" fromStep5
      assertBool
        "SKILL.md Step 5 and Step 6 mention invoke_subagent fallback when no blind-reader is active"
        ( "invoke_subagent" `T.isInfixOf` fst (T.breakOn "#### Batch Mode" fromStep5)
            && "invoke_subagent" `T.isInfixOf` fromStep6
        )

      (ecNext2, _, errNext2) <- readProcessWithExitCode binPath ["next", "--session", sessDir] ""
      assertEq ("CLI next chunk 2/2 exit 0 (" ++ errNext2 ++ ")") ExitSuccess ecNext2
      TIO.writeFile
        scriptResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_chunk.md, memory.md, chunks/chunk_0001.md, chunks/by_chronology.md, entries/by_chronology.md) -->"
            , "=== DRAFT COMMENTARY ==="
            , "Mara is climbing toward the beacon—maybe connecting back to the compass on the dock!"
            ]
        )
      (ecScr2, _, errScr2) <- readProcessWithExitCode binPath ["script", "--session", sessDir] ""
      assertEq ("CLI script chunk 2/2 exit 0 (" ++ errScr2 ++ ")") ExitSuccess ecScr2
      TIO.writeFile
        researchResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_chunk.md, memory.md, chunks/chunk_0001.md) -->"
            , "=== RESEARCH NOTES ==="
            , "- **[Earlier Story Passage | Source: chunks/chunk_0001.md | Quote: \"Inspector Lin examined the brass compass on the dock.\"]** Chapter 1 established the unmarked brass compass on the dock."
            ]
        )
      (ecRes2, outRes2, errRes2) <- readProcessWithExitCode binPath ["research", "--session", sessDir] ""
      assertEq ("CLI research chunk 2/2 exit 0 (" ++ errRes2 ++ ")") ExitSuccess ecRes2
      assertBool
        "research on chunk 2/2 verifies 1 excerpt from chunk_0001.md"
        ("\"verified_research_notes_count\": 1" `isInfixOf` outRes2 && "\"rejected_research_notes_count\": 0" `isInfixOf` outRes2)
      TIO.writeFile
        readerResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_chunk.md, memory.md, current_research.md) -->"
            , "=== COMMENTARY ==="
            , "> \"Mara climbed the spiral stairs toward the beacon.\""
            , ""
            , "Mara was at the lighthouse the whole time, right after the dockside compass in `chunks/chunk_0001.md`!"
            , ""
            , "=== CHUNK SUMMARY ==="
            , "- **[Story | Topics: Mara, Lighthouse, Beacon]** Mara climbs the spiral stairs toward the lighthouse beacon."
            , "- **[Entry | Topics: Mara, Lighthouse, Beacon]** Reaction to Mara reaching the beacon in the finale."
            , ""
            , "=== PREDICTION UPDATES ==="
            , "- **[Predicted Chunk 0002 | Topics: Mara, Lighthouse, Beacon]** **Clue/Anomaly**: Mara ascends the spiral stairs toward the unlit beacon -> **Theory**: Mara is relighting the beacon to warn ships away from the harbor reef"
            , ""
            , "=== UPDATED MEMORY ==="
            , "## Story Summary So Far"
            , "- **Core Premise, Timeline & Baseline Facts (Persistent)**: Inspector Lin investigates the dock while Mara climbs the lighthouse."
            ]
        )
      (ecRec2, outRec2, errRec2) <- readProcessWithExitCode binPath ["record", "--session", sessDir] ""
      assertEq ("CLI record chunk 2/2 exit 0 (" ++ errRec2 ++ ")") ExitSuccess ecRec2
      assertBool
        "record credits chunk_0001.md verified in current_research.md with 0 callback audit warnings"
        ("\"reader_callback_audit_warnings_count\": 0" `isInfixOf` outRec2)

      TIO.writeFile
        (sessDir </> "current_judge_response.md")
        ( T.unlines
            [ "=== PREDICTION JUDGMENTS ==="
            , "- **[Predicted Chunk 0001 -> ACTIVE]** Still unresolved."
            , "- **[Predicted Chunk 0002 -> ACTIVE]** Open finale thread."
            ]
        )
      TIO.writeFile
        (sessDir </> "current_fact_check_response.md")
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_chunk.md, entries/chunk_0002.md, memory.md) -->"
            , "=== VERIFIED CLAIMS LOG ==="
            , "- [OK | Source: current_chunk.md] Mara climbed the spiral stairs toward the beacon."
            , ""
            , "=== DISPUTED FACTS & MEMORY CHECKS ==="
            , "- [In-Story Fact | Source: current_chunk.md | Quote: \"Mara climbed the spiral stairs toward the beacon.\"] Does Chapter 2 actually state that the beacon is unlit?"
            ]
        )
      TIO.writeFile
        (sessDir </> "current_critic_response.md")
        "=== PERSONA & STYLE CRITIQUE ===\n- **[Persona & Lens]** Strong voice.\n- **[What Worked Well]** Good energy.\n- **[Where the Voice Drifted or Felt Formulaic]** None.\n"
      TIO.writeFile
        (sessDir </> "current_topic_response.md")
        "=== TOPIC MERGES ===\n- NONE\n"

      (ecJDispute, outJDispute, errJDispute) <- readProcessWithExitCode binPath ["judge", "--session", sessDir] ""
      assertEq ("CLI judge chunk 2/2 with fact-check dispute exit 0 (" ++ errJDispute ++ ")") ExitSuccess ecJDispute
      assertBool
        "judge on chunk N/N with pending fact-check dispute withholds wrapup_pending"
        ( "\"status\": \"awaiting_fact_check_response\"" `isInfixOf` outJDispute
            && "\"fact_check_discussion_pending\": true" `isInfixOf` outJDispute
            && "\"wrapup_pending\": false" `isInfixOf` outJDispute
        )

      (ecStatPending, outStatPending, _) <- readProcessWithExitCode binPath ["status", "--session", sessDir] ""
      assertEq "CLI status while fact-check dispute is pending on chunk 2/2 exit 0" ExitSuccess ecStatPending
      assertBool
        "status on chunk N/N withholds wrapup_pending while fact-check dispute is pending"
        ( "\"fact_check_discussion_pending\": true" `isInfixOf` outStatPending
            && "\"wrapup_pending\": false" `isInfixOf` outStatPending
        )

      TIO.writeFile
        (sessDir </> "current_discussion_response.md")
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_discussion_prompt.md, current_chunk.md, memory.md) -->"
            , "=== COMMENTARY ==="
            , "Good catch: Chapter 2 only mentions climbing toward the beacon without stating it is unlit."
            , ""
            , "=== CHUNK SUMMARY ==="
            , "- **[Discussion | Topics: Mara, Beacon]** Clarified that Chapter 2 does not explicitly state the beacon is unlit."
            ]
        )
      (ecFcDisc, outFcDisc, errFcDisc) <-
        readProcessWithExitCode binPath ["discuss", "--session", sessDir] ""
      assertEq ("CLI fact-check discuss on chunk 2/2 exit 0 (" ++ errFcDisc ++ ")") ExitSuccess ecFcDisc
      assertBool
        "fact-check discuss on chunk N/N flips wrapup_pending to true and includes present-to-user option"
        ( "\"wrapup_pending\": true" `isInfixOf` outFcDisc
            && "\"fact_check_discussion_resolved\": true" `isInfixOf` outFcDisc
            && "\"fact_check_discussion_pending\": false" `isInfixOf` outFcDisc
            && "Fact-check discussion resolved" `isInfixOf` outFcDisc
            && "(or present the commentary and discussion to the user)" `isInfixOf` outFcDisc
        )

      (ecStatFinal, outStatFinal, _) <- readProcessWithExitCode binPath ["status", "--session", sessDir] ""
      assertEq "CLI status after resolving fact-check on chunk 2/2 exit 0" ExitSuccess ecStatFinal
      assertBool
        "status on chunk N/N reports wrapup_pending true once fact-check dispute is resolved"
        ( "\"fact_check_discussion_pending\": false" `isInfixOf` outStatFinal
            && "\"wrapup_pending\": true" `isInfixOf` outStatFinal
        )

      TIO.writeFile
        (sessDir </> "current_fact_check_response.md")
        "<!-- TOOLS: read_file(current_chunk.md, entries/chunk_0002.md, memory.md) -->\n=== VERIFIED CLAIMS LOG ===\n- [OK | Source: current_chunk.md] Mara climbed the spiral stairs toward the beacon.\n\n=== DISPUTED FACTS & MEMORY CHECKS ===\n- PASS\n"
      (ecJFinal, outJFinal, errJFinal) <- readProcessWithExitCode binPath ["judge", "--session", sessDir] ""
      assertEq ("CLI clean judge chunk 2/2 exit 0 (" ++ errJFinal ++ ")") ExitSuccess ecJFinal
      assertBool
        "clean judge on chunk N/N sets wrapup_pending true and includes present-to-user option"
        ( "\"wrapup_pending\": true" `isInfixOf` outJFinal
            && "(or present the commentary to the user)" `isInfixOf` outJFinal
        )

      let userFinaleMsg = "What did you make of that cliffhanger at the lighthouse?"
      (ecDP, outDP, errDP) <-
        readProcessWithExitCode
          binPath
          ["discuss-prompt", "--session", sessDir, "--user-message", userFinaleMsg]
          ""
      assertEq ("CLI discuss-prompt on chunk 2/2 exit 0 (" ++ errDP ++ ")") ExitSuccess ecDP
      assertBool
        "discuss-prompt hint mentions invoke_subagent fallback when no blind-reader is active"
        ("invoke_subagent" `isInfixOf` outDP)
      TIO.writeFile
        (sessDir </> "current_discussion_response.md")
        ( T.unlines
            [ "<!-- TOOLS: read_file(current_discussion_prompt.md, current_chunk.md, memory.md) -->"
            , "=== COMMENTARY ==="
            , "Ending right on the spiral stairs leaves the compass mystery wide open!"
            , ""
            , "=== CHUNK SUMMARY ==="
            , "- **[Discussion | Topics: Mara, Lighthouse]** Discussing the cliffhanger ending on the lighthouse stairs."
            ]
        )
      (ecDisc, outDisc, errDisc) <-
        readProcessWithExitCode
          binPath
          ["discuss", "--session", sessDir, "--user-message", userFinaleMsg]
          ""
      assertEq ("CLI discuss on chunk 2/2 exit 0 (" ++ errDisc ++ ")") ExitSuccess ecDisc
      assertBool
        "user discuss on chunk N/N reports wrapup_pending true, is_finished false, and fact_check_discussion_resolved false"
        ( "\"wrapup_pending\": true" `isInfixOf` outDisc
            && "\"is_finished\": false" `isInfixOf` outDisc
            && "\"fact_check_discussion_resolved\": false" `isInfixOf` outDisc
        )
      assertBool
        "user discuss on chunk N/N does not mislabel hint as Fact-check discussion resolved and includes present-to-user option"
        ( not ("Fact-check discussion resolved" `isInfixOf` outDisc)
            && "(or present the commentary and discussion to the user)" `isInfixOf` outDisc
        )
      hasWrapupAfterDisc <- doesFileExist (sessDir </> "entries" </> "wrapup.md")
      assertBool "wrapup.md is still not created during pre-wrapup finale discussion" (not hasWrapupAfterDisc)
      chunk2EntryTxt <- TIO.readFile (sessDir </> "entries" </> "chunk_0002.md")
      assertBool
        "pre-wrapup user discussion appends ### Reader Discussion to entries/chunk_0002.md"
        ( "### Reader Discussion" `T.isInfixOf` chunk2EntryTxt
            && T.pack userFinaleMsg `T.isInfixOf` chunk2EntryTxt
        )

      (ecNextWrap, outNextWrap, errNextWrap) <- readProcessWithExitCode binPath ["next", "--session", sessDir] ""
      assertEq ("CLI next wrapup unlock exit 0 (" ++ errNextWrap ++ ")") ExitSuccess ecNextWrap
      assertBool
        "next on wrapup starts awaiting_script with is_wrapup true"
        ("\"status\": \"awaiting_script\"" `isInfixOf` outNextWrap && "\"is_wrapup\": true" `isInfixOf` outNextWrap)
      (ecDoubleNextWrap, _, _) <- readProcessWithExitCode binPath ["next", "--session", sessDir] ""
      assertBool "duplicate next on wrapup without --force is gated" (ecDoubleNextWrap /= ExitSuccess)
      TIO.writeFile
        scriptResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(memory.md, predictions/hall_of_fame.md, chunks/by_chronology.md, entries/by_chronology.md) -->"
            , "=== DRAFT COMMENTARY ==="
            , "Draft retrospective recalling the Chunk 1 compass prediction and Chapter 2 lighthouse climb."
            ]
        )
      (ecScrWrap, outScrWrap, errScrWrap) <- readProcessWithExitCode binPath ["script", "--session", sessDir] ""
      assertEq ("CLI script wrapup exit 0 (" ++ errScrWrap ++ ")") ExitSuccess ecScrWrap
      assertBool
        "script on wrapup emits awaiting_research and is_wrapup true"
        ("\"status\": \"awaiting_research\"" `isInfixOf` outScrWrap && "\"is_wrapup\": true" `isInfixOf` outScrWrap)
      TIO.writeFile
        researchResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(memory.md, predictions/hall_of_fame.md, predictions/pred_0001.md, entries/chunk_0002.md) -->"
            , "=== RESEARCH NOTES ==="
            , "- **[Prior Prediction | Source: predictions/pred_0001.md | Quote: \"Lin finds an unmarked brass compass on the dock\"]** Exact original Clue/Anomaly from Chunk 0001."
            , "- **[Prior Session Entry | Source: entries/chunk_0002.md | Quote: \"Mara was at the lighthouse the whole time\"]** Finale liveblog reaction on Chunk 0002."
            ]
        )
      (ecResWrap, outResWrap, errResWrap) <- readProcessWithExitCode binPath ["research", "--session", sessDir] ""
      assertEq ("CLI research wrapup exit 0 (" ++ errResWrap ++ ")") ExitSuccess ecResWrap
      assertBool
        "wrapup_unlocked hint mentions invoke_subagent fallback and verifies both pred_0001 and entries/chunk_0002"
        ( "\"status\": \"wrapup_unlocked\"" `isInfixOf` outResWrap
            && "\"verified_research_notes_count\": 2" `isInfixOf` outResWrap
            && "invoke_subagent" `isInfixOf` outResWrap
        )
      TIO.writeFile
        readerResp
        ( T.unlines
            [ "<!-- TOOLS: read_file(memory.md, predictions/hall_of_fame.md, current_research.md) -->"
            , "=== COMMENTARY ==="
            , "Looking back across both chapters, Lin's harbor investigation and Mara's climb tie together cleanly."
            ]
        )
      (ecRecWrap, outRecWrap, errRecWrap) <- readProcessWithExitCode binPath ["record", "--session", sessDir] ""
      assertEq ("CLI record wrapup exit 0 (" ++ errRecWrap ++ ")") ExitSuccess ecRecWrap
      assertBool
        "record wrapup emits wrapup_recorded and is_finished true"
        ("\"status\": \"wrapup_recorded\"" `isInfixOf` outRecWrap && "\"is_finished\": true" `isInfixOf` outRecWrap)

      let postWrapMsg = "Any favorite scene looking back at the whole story?"
      (ecDPWrap, _, errDPWrap) <-
        readProcessWithExitCode
          binPath
          ["discuss-prompt", "--session", sessDir, "--user-message", postWrapMsg]
          ""
      assertEq ("CLI post-wrapup discuss-prompt exit 0 (" ++ errDPWrap ++ ")") ExitSuccess ecDPWrap
      TIO.writeFile
        (sessDir </> "current_discussion_response.md")
        ( T.unlines
            [ "<!-- TOOLS: none -->"
            , "=== COMMENTARY ==="
            , "Definitely the brass compass discovery on the dock in Chapter 1!"
            , ""
            , "=== CHUNK SUMMARY ==="
            , "- **[Discussion | Topics: Brass Compass, Harbor]** Post-wrapup favorite scene reflection."
            ]
        )
      (ecDiscWrap, outDiscWrap, errDiscWrap) <-
        readProcessWithExitCode
          binPath
          ["discuss", "--session", sessDir, "--user-message", postWrapMsg]
          ""
      assertEq ("CLI post-wrapup discuss exit 0 (" ++ errDiscWrap ++ ")") ExitSuccess ecDiscWrap
      assertBool
        "post-wrapup discuss reports is_finished true, wrapup_pending false, and omits unlock-next-chunk hint"
        ( "\"is_finished\": true" `isInfixOf` outDiscWrap
            && "\"wrapup_pending\": false" `isInfixOf` outDiscWrap
            && "Post-wrapup discussion recorded!" `isInfixOf` outDiscWrap
            && not ("unlock the next chunk" `isInfixOf` outDiscWrap)
        )
      wrapupEntryTxt <- TIO.readFile (sessDir </> "entries" </> "wrapup.md")
      assertBool
        "post-wrapup user discussion appends ### Reader Discussion to entries/wrapup.md"
        ( "### Reader Discussion" `T.isInfixOf` wrapupEntryTxt
            && T.pack postWrapMsg `T.isInfixOf` wrapupEntryTxt
        )
