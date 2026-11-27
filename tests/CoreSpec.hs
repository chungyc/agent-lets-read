{-# LANGUAGE OverloadedStrings #-}

module CoreSpec
  ( spec
  ) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (buildChunksFromSource)
import LetsRead.Predictions
  ( summarizeFinalPredictions
  , summarizeTurnPredictions
  )
import LetsRead.Prompts (expandPersonaPreset)
import LetsRead.Types
  ( Chunk (..)
  , PredictionRecord (..)
  , PredictionStatus (..)
  , ResolutionMeta (..)
  , SessionState (..)
  , chunkToMeta
  , formatTurnChapterLabel
  , loadState
  , loadVaultChunk
  , orchestratorRuleText
  , saveState
  , saveVault
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , findExecutable
  , getCurrentDirectory
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it)
import TestHarness
  ( assertBool
  , assertEq
  , baseDummyState
  , withTempDir
  )

spec :: Spec
spec = describe "Core Gatekeeper & CLI" $ do
  it "chunks stories, round-trips vault and state, and formats turn summaries" testVaultAndChunker
  it "compiles standalone binary via scripts/prepare.sh" testPrepareScript
  it "enforces orchestrator anti-race guardrails and full CLI session lifecycle" testRec1OrchestratorGuardrails

testPrepareScript :: IO ()
testPrepareScript = do
  repoDir <- getCurrentDirectory
  (ec, _, errOut) <- readProcessWithExitCode (repoDir </> "scripts" </> "prepare.sh") [] ""
  assertEq ("scripts/prepare.sh exits 0 (" ++ errOut ++ ")") ExitSuccess ec
  hasBin <- doesFileExist (repoDir </> ".bin" </> "lets-read")
  assertBool ".bin/lets-read exists after scripts/prepare.sh" hasBin

testVaultAndChunker :: IO ()
testVaultAndChunker = withTempDir "vault" $ \tmp -> do
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

  forM_
    [ ("Suspense & Dread Reader", "suspense and dread reader", "escalating danger, quiet unease")
    , ("History & Folklore Buff", "history and folklore buff", "real-world parallels in a story's customs")
    , ("Drama & Motives Watcher", "drama and motives watcher", "unspoken rivalries, bruised pride")
    ]
    $ \(presetName, altName, snippet) -> do
      let expanded = expandPersonaPreset presetName
      assertBool
        ("expandPersonaPreset expands " ++ T.unpack presetName)
        ((presetName <> " \x2014 ") `T.isPrefixOf` expanded && snippet `T.isInfixOf` expanded)
      assertEq
        ("expandPersonaPreset handles 'and' variant for " ++ T.unpack presetName)
        expanded
        (expandPersonaPreset altName)

  let mkDummyPred orig stStatus =
        PredictionRecord
          { prOriginChunk = orig
          , prChapterNumber = 1
          , prChapterTitle = "Arrival"
          , prPartInChapter = 1
          , prPartsInChapter = 1
          , prTopics = ["Harbor"]
          , prClue = "Clue"
          , prTheory = "Theory"
          , prRawBody = "Clue -> Theory"
          , prStatus = stStatus
          }
      rmAt c =
        ResolutionMeta
          { rmChunk = c
          , rmChapterNumber = 2
          , rmChapterTitle = "Departure"
          , rmPartInChapter = 1
          , rmPartsInChapter = 1
          , rmNote = "Resolved."
          }
      samplePreds =
        [ mkDummyPred 1 (PredStatusConfirmed (rmAt 4) False)
        , mkDummyPred 2 (PredStatusDebunked (rmAt 4))
        , mkDummyPred 3 (PredStatusActive Nothing)
        , mkDummyPred 4 (PredStatusActive (Just "Good bet."))
        ]
  assertEq
    "summarizeTurnPredictions reports count-only outcomes and active count"
    "1 CONFIRMED, 1 DEBUNKED, 1 new staked; 2 active"
    (summarizeTurnPredictions 4 samplePreds [])
  assertEq
    "summarizeTurnPredictions reports screened-out proposal when rejected on turn"
    "proposal screened out; 1 active"
    (summarizeTurnPredictions 5 [mkDummyPred 3 (PredStatusActive Nothing)] [(mkDummyPred 5 (PredStatusActive Nothing), "[UNINTERESTING] Routine.")])
  assertEq
    "summarizeFinalPredictions tallies foresight vs same-chunk confirmed, subverted, debunked, and unresolved"
    "Final tally: 1 CONFIRMED, 1 same-chunk CONFIRMED, 1 SUBVERTED, 1 DEBUNKED, 1 unresolved"
    ( summarizeFinalPredictions
        [ mkDummyPred 1 (PredStatusConfirmed (rmAt 3) False)
        , mkDummyPred 2 (PredStatusConfirmed (rmAt 2) True)
        , mkDummyPred 3 (PredStatusSubverted (rmAt 4))
        , mkDummyPred 4 (PredStatusDebunked (rmAt 4))
        , mkDummyPred 5 (PredStatusActive Nothing)
        ]
    )
  assertEq
    "formatTurnChapterLabel omits (Part 1/1) on single-part chapters and formats multi-part and wrapup"
    ("Chapter 2: Departure", "Chapter 2: Departure (Part 1/2)", "Final Wrapup & Retrospective")
    ( formatTurnChapterLabel False (2, "Departure", 1, 1)
    , formatTurnChapterLabel False (2, "Departure", 1, 2)
    , formatTurnChapterLabel True (2, "Departure", 1, 2)
    )

testRec1OrchestratorGuardrails :: IO ()
testRec1OrchestratorGuardrails = do
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

  repoDir <- getCurrentDirectory
  mBinPath <- findExecutable "lets-read"
  case mBinPath of
    Nothing -> expectationFailure "lets-read executable not found on PATH (check build-tool-depends in lets-read.cabal)"
    Just binPath -> withTempDir "rec1-cli" $ \tmp -> do
      let agentFiles =
            [ ("lets-read-script-writer.md", "name: lets-read-script-writer", "model: flash")
            , ("lets-read-researcher.md", "name: lets-read-researcher", "model: flash")
            , ("lets-read-blind-reader.md", "name: lets-read-blind-reader", "model: inherit")
            , ("lets-read-prediction-judge.md", "name: lets-read-prediction-judge", "model: inherit")
            , ("lets-read-fact-checker.md", "name: lets-read-fact-checker", "model: inherit")
            , ("lets-read-commentary-critic.md", "name: lets-read-commentary-critic", "model: inherit")
            , ("lets-read-topic-curator.md", "name: lets-read-topic-curator", "model: flash_lite")
            ]
          driverFiles =
            [ ("lets-read-interactive-driver.md", "name: lets-read-interactive-driver")
            , ("lets-read-batch-driver.md", "name: lets-read-batch-driver")
            ]
      forM_ agentFiles $ \(af, expectedName, expectedModel) -> do
        agentTxt <- TIO.readFile (repoDir </> "agents" </> af)
        assertBool
          (af ++ " declares expected frontmatter " ++ T.unpack expectedName ++ " and " ++ T.unpack expectedModel)
          ( ("\n" <> expectedName <> "\n") `T.isInfixOf` agentTxt
              && ("\n" <> expectedModel <> "\n") `T.isInfixOf` agentTxt
          )
        assertBool
          (af ++ " forbids run_command, edit_file, and send_message concisely")
          ("- Never call `run_command`, `edit_file`, or `send_message`." `T.isInfixOf` agentTxt)
        assertBool
          (af ++ " omits misleading 'reply to the host' phrasing and uses [SUBAGENT_DONE |")
          ( not ("reply to the host" `T.isInfixOf` T.toLower agentTxt)
              && "[SUBAGENT_DONE |" `T.isInfixOf` agentTxt
          )
        assertBool
          (af ++ " forbids reading current_turn.md and last_discussion_exchange.md")
          ( "current_turn.md" `T.isInfixOf` agentTxt
              && "last_discussion_exchange.md" `T.isInfixOf` agentTxt
          )
      forM_ driverFiles $ \(df, expectedName) -> do
        drvTxt <- TIO.readFile (repoDir </> "agents" </> df)
        assertBool
          (df ++ " declares subagent/model/tools frontmatter and references driver-pipeline.md with [HOST_WAIT | and [DRIVER_DONE |")
          ( ("\n" <> expectedName <> "\n") `T.isInfixOf` drvTxt
              && "\nsubagent: true\n" `T.isInfixOf` drvTxt
              && "\nmainAgent: false\n" `T.isInfixOf` drvTxt
              && "\nmodel: inherit\n" `T.isInfixOf` drvTxt
              && "run_command" `T.isInfixOf` drvTxt
              && "invoke_subagent" `T.isInfixOf` drvTxt
              && "send_message" `T.isInfixOf` drvTxt
              && "manage_subagents" `T.isInfixOf` drvTxt
              && "driver-pipeline.md" `T.isInfixOf` drvTxt
              && "[HOST_WAIT |" `T.isInfixOf` drvTxt
              && "[DRIVER_DONE |" `T.isInfixOf` drvTxt
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
      (ecInit, outInit, errInit) <- readProcessWithExitCode binPath ["init", srcPath, "--session", sessDir] ""
      assertEq ("CLI init exit 0 (" ++ errInit ++ ")") ExitSuccess ecInit
      assertBool "init JSON includes current_turn_file" ("\"current_turn_file\":" `isInfixOf` outInit)
      initLogTxt <- TIO.readFile (sessDir </> "lets_read_log.md")
      assertBool "lets_read_log.md after init uses ## Reader Persona heading" ("## Reader Persona" `T.isInfixOf` initLogTxt)
      assertBool "lets_read_log.md after init omits *Reader Persona*: pseudo-heading" (not ("*Reader Persona*:" `T.isInfixOf` initLogTxt))
      let initHeaderLines = takeWhile (/= "---") (T.lines initLogTxt)
      assertBool
        "lets_read_log.md header prose lines after init wrap <= 80 cols"
        (all (\l -> "#" `T.isPrefixOf` l || T.length l <= 80) initHeaderLines)
      initTurnTxt <- TIO.readFile (sessDir </> "current_turn.md")
      assertBool
        "current_turn.md after init uses semantic headings and wraps lines <= 80 cols"
        ( "## Reader Persona" `T.isInfixOf` initTurnTxt
            && "## Current Turn" `T.isInfixOf` initTurnTxt
            && not ("*Reader Persona*:" `T.isInfixOf` initTurnTxt)
            && all (\l -> "#" `T.isPrefixOf` l || T.length l <= 80) (T.lines initTurnTxt)
        )
      hasInitLastDisc <- doesFileExist (sessDir </> "last_discussion_exchange.md")
      assertBool "last_discussion_exchange.md is absent after init" (not hasInitLastDisc)

      (ecNext, outNext, _) <- readProcessWithExitCode binPath ["next", "--session", sessDir] ""
      assertEq "CLI next exit 0" ExitSuccess ecNext
      assertBool
        "next unlocks awaiting_script with Model: \"flash\", [HOST_WAIT | Chunk 0001 | script], and [SUBAGENT_DONE | Chunk 0001 | lets-read-script-writer]"
        ( "\"status\": \"awaiting_script\"" `isInfixOf` outNext
            && "\"is_wrapup\": false" `isInfixOf` outNext
            && "Model: \\\"flash\\\"" `isInfixOf` outNext
            && "ZERO tool calls" `isInfixOf` outNext
            && "[HOST_WAIT | Chunk 0001 | script | 0/1 idle | pending: lets-read-script-writer]" `isInfixOf` outNext
            && "[SUBAGENT_DONE | Chunk 0001 | lets-read-script-writer]" `isInfixOf` outNext
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
        "script transitions to awaiting_research with Model: \"flash\" and reminds host to kill lets-read-script-writer"
        ( "\"status\": \"awaiting_research\"" `isInfixOf` outScr1
            && "lets-read-script-writer" `isInfixOf` outScr1
            && "lets-read-researcher" `isInfixOf` outScr1
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
        "research unlocks chunk for lets-read-blind-reader and reminds host to kill one-shot lets-read-researcher"
        ("\"status\": \"unlocked\"" `isInfixOf` outRes1 && "ZERO tool calls" `isInfixOf` outRes1 && "Kill the finished one-shot lets-read-researcher" `isInfixOf` outRes1)
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
            && "[HOST_WAIT | Chunk 0001 | judge | 0/3 idle | pending: lets-read-prediction-judge, lets-read-fact-checker, lets-read-commentary-critic]" `isInfixOf` outRec
            && "[SUBAGENT_DONE | Chunk 0001 | <role>]" `isInfixOf` outRec
        )
      preJudgeEntry1Txt <- TIO.readFile (sessDir </> "entries" </> "chunk_0001.md")
      assertBool
        "record writes temporary Prediction Tracker Update (Reader Proposal) callout before judge runs"
        ("Prediction Tracker Update (Reader Proposal)" `T.isInfixOf` preJudgeEntry1Txt)
      preJudgeTurn1Txt <- TIO.readFile (sessDir </> "current_turn.md")
      assertBool
        "mid-chunk record leaves current_turn.md untouched before judge finalizes verdicts"
        ("## Current Turn" `T.isInfixOf` preJudgeTurn1Txt && not ("That compass is definitely planted!" `T.isInfixOf` preJudgeTurn1Txt))

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
      assertBool
        "judge includes is_chapter_end, compact turn metadata, and omits topic-curator kill prompt when unused"
        ( "\"is_chapter_end\": true" `isInfixOf` outJ1
            && "\"chapter_label\": \"Chapter 1: Harbor\"" `isInfixOf` outJ1
            && "\"prediction_summary\": \"1 new staked; 1 active\"" `isInfixOf` outJ1
            && "\"current_turn_file\":" `isInfixOf` outJ1
            && "\"story_chunk_file\":" `isInfixOf` outJ1
            && "\"word_count\":" `isInfixOf` outJ1
            && not ("lets-read-topic-curator" `isInfixOf` outJ1)
        )
      judgedTurn1Txt <- TIO.readFile (sessDir </> "current_turn.md")
      assertBool
        "judge populates current_turn.md with finalized entry and strips trailing horizontal rule"
        ( "## Chunk 1/2" `T.isInfixOf` judgedTurn1Txt
            && "That compass is definitely planted!" `T.isInfixOf` judgedTurn1Txt
            && "**Prediction Judge Rulings (Chunk 0001)**:" `T.isInfixOf` judgedTurn1Txt
            && not ("---\n" `T.isSuffixOf` judgedTurn1Txt)
        )

      let topicResp = tmp </> "topic_resp.md"
      TIO.writeFile topicResp "=== TOPIC MERGES ===\n- NONE\n"
      (ecJ2, outJ2, _) <- readProcessWithExitCode binPath ["judge", "--session", sessDir, "--topic-response-file", topicResp] ""
      assertEq "CLI judge (with topic-curator) exit 0" ExitSuccess ecJ2
      assertBool
        "judge with topic-curator reminds orchestrator to kill lets-read-topic-curator"
        ("lets-read-topic-curator" `isInfixOf` outJ2 && "manage_subagents" `isInfixOf` outJ2)
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
      interactiveDrvTxt <- TIO.readFile (repoDir </> "agents" </> "lets-read-interactive-driver.md")
      pipelineTxt <- TIO.readFile (repoDir </> "references" </> "driver-pipeline.md")
      let (_, fromStep4Interactive) = T.breakOn "\n#### Interactive Mode\n" skillTxt
      assertBool
        "SKILL.md delegates Interactive Mode and Batch Mode to lets-read-*-driver with compact current_turn.md and delta last_discussion_exchange.md rules"
        ( "lets-read-interactive-driver" `T.isInfixOf` skillTxt
            && "lets-read-batch-driver" `T.isInfixOf` skillTxt
            && not ("driver-pipeline.md" `T.isInfixOf` skillTxt)
            && "chunks_in_driver >= 8" `T.isInfixOf` skillTxt
            && "[DRIVER_DONE |" `T.isInfixOf` skillTxt
            && "current_turn.md" `T.isInfixOf` skillTxt
            && "last_discussion_exchange.md" `T.isInfixOf` skillTxt
            && "zero follow-up tool calls" `T.isInfixOf` skillTxt
            && "invoke_subagent" `T.isInfixOf` fst (T.breakOn "\n#### Batch Mode\n" fromStep4Interactive)
        )
      assertBool
        "lets-read-interactive-driver.md carries compact turn metadata in [DRIVER_DONE | and forbids reading current_turn.md"
        ( "chapter_label=" `T.isInfixOf` interactiveDrvTxt
            && "predictions=" `T.isInfixOf` interactiveDrvTxt
            && "current_turn_file=" `T.isInfixOf` interactiveDrvTxt
            && "story_chunk_file=" `T.isInfixOf` interactiveDrvTxt
            && "last_discussion_exchange.md" `T.isInfixOf` interactiveDrvTxt
        )
      let (_, fromProc2) = T.breakOn "## Procedure 2: Final Wrapup Round" pipelineTxt
          (_, fromProc3) = T.breakOn "## Procedure 3: User Discussion Turn" pipelineTxt
      assertBool
        "driver-pipeline.md separates Reading Chunk, Final Wrapup, and User Discussion procedures with invoke_subagent fallbacks"
        ( "## Procedure 1: Single Reading Chunk" `T.isInfixOf` pipelineTxt
            && not (T.null fromProc2)
            && not (T.null fromProc3)
            && "invoke_subagent" `T.isInfixOf` fst (T.breakOn "## Procedure 3" fromProc2)
            && "invoke_subagent" `T.isInfixOf` fromProc3
        )

      (ecNext2, _, errNext2) <- readProcessWithExitCode binPath ["next", "--session", sessDir] ""
      assertEq ("CLI next chunk 2/2 exit 0 (" ++ errNext2 ++ ")") ExitSuccess ecNext2
      turnDuringChunk2Txt <- TIO.readFile (sessDir </> "current_turn.md")
      assertBool
        "next leaves previous finalized chunk in current_turn.md while chunk 2 runs"
        ("That compass is definitely planted!" `T.isInfixOf` turnDuringChunk2Txt)
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
      turnWhileDisputedTxt <- TIO.readFile (sessDir </> "current_turn.md")
      assertBool
        "judge with pending fact-check dispute does not prematurely overwrite current_turn.md"
        ( "That compass is definitely planted!" `T.isInfixOf` turnWhileDisputedTxt
            && not ("Mara was at the lighthouse the whole time" `T.isInfixOf` turnWhileDisputedTxt)
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
        "fact-check discuss on chunk N/N flips wrapup_pending to true and directs driver to [DRIVER_DONE"
        ( "\"wrapup_pending\": true" `isInfixOf` outFcDisc
            && "\"fact_check_discussion_resolved\": true" `isInfixOf` outFcDisc
            && "\"fact_check_discussion_pending\": false" `isInfixOf` outFcDisc
            && "\"last_discussion_file\": null" `isInfixOf` outFcDisc
            && "\"prediction_summary\": \"1 new staked; 2 active\"" `isInfixOf` outFcDisc
            && "Fact-check discussion resolved" `isInfixOf` outFcDisc
            && "[DRIVER_DONE | ...]" `isInfixOf` outFcDisc
        )
      hasLastDiscAfterFc <- doesFileExist (sessDir </> "last_discussion_exchange.md")
      assertBool "fact-check peer query does not write last_discussion_exchange.md" (not hasLastDiscAfterFc)
      turnAfterFcTxt <- TIO.readFile (sessDir </> "current_turn.md")
      assertBool
        "fact-check discuss updates current_turn.md once peer query resolves"
        ( "Mara was at the lighthouse the whole time" `T.isInfixOf` turnAfterFcTxt
            && "Good catch: Chapter 2 only mentions climbing" `T.isInfixOf` turnAfterFcTxt
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
        "clean judge on chunk N/N sets wrapup_pending true and directs driver to [DRIVER_DONE"
        ( "\"wrapup_pending\": true" `isInfixOf` outJFinal
            && "[DRIVER_DONE | ...]" `isInfixOf` outJFinal
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
        "user discuss on chunk N/N reports total_chunks, is_chapter_end true, wrapup_pending true, is_finished false, and fact_check_discussion_resolved false"
        ( "\"total_chunks\": 2" `isInfixOf` outDisc
            && "\"is_chapter_end\": true" `isInfixOf` outDisc
            && "\"wrapup_pending\": true" `isInfixOf` outDisc
            && "\"is_finished\": false" `isInfixOf` outDisc
            && "\"fact_check_discussion_resolved\": false" `isInfixOf` outDisc
        )
      assertBool
        "user discuss on chunk N/N does not mislabel hint as Fact-check discussion resolved and directs driver to [DRIVER_DONE"
        ( not ("Fact-check discussion resolved" `isInfixOf` outDisc)
            && "[DRIVER_DONE | ...]" `isInfixOf` outDisc
        )
      hasWrapupAfterDisc <- doesFileExist (sessDir </> "entries" </> "wrapup.md")
      assertBool "wrapup.md is still not created during pre-wrapup finale discussion" (not hasWrapupAfterDisc)
      chunk2EntryTxt <- TIO.readFile (sessDir </> "entries" </> "chunk_0002.md")
      assertBool
        "pre-wrapup user discussion appends ### Reader Discussion to entries/chunk_0002.md"
        ( "### Reader Discussion" `T.isInfixOf` chunk2EntryTxt
            && T.pack userFinaleMsg `T.isInfixOf` chunk2EntryTxt
        )
      assertBool
        "user discuss emits non-null last_discussion_file and prediction_summary"
        ( "\"last_discussion_file\": \"" `isInfixOf` outDisc
            && "\"prediction_summary\": \"1 new staked; 2 active\"" `isInfixOf` outDisc
        )
      lastDiscTxt <- TIO.readFile (sessDir </> "last_discussion_exchange.md")
      assertBool
        "last_discussion_exchange.md holds only the reader reply without echoing user prompt or earlier chunk commentary"
        ( not (T.pack userFinaleMsg `T.isInfixOf` lastDiscTxt)
            && "Ending right on the spiral stairs leaves the compass mystery wide open!" `T.isInfixOf` lastDiscTxt
            && not ("Mara was at the lighthouse the whole time" `T.isInfixOf` lastDiscTxt)
        )
      turnAfterUserDiscTxt <- TIO.readFile (sessDir </> "current_turn.md")
      assertBool
        "user discuss refreshes current_turn.md with both chunk commentary and discussion"
        ( "Mara was at the lighthouse the whole time" `T.isInfixOf` turnAfterUserDiscTxt
            && T.pack userFinaleMsg `T.isInfixOf` turnAfterUserDiscTxt
        )

      (ecNextWrap, outNextWrap, errNextWrap) <- readProcessWithExitCode binPath ["next", "--session", sessDir] ""
      assertEq ("CLI next wrapup unlock exit 0 (" ++ errNextWrap ++ ")") ExitSuccess ecNextWrap
      hasLastDiscAfterNextWrap <- doesFileExist (sessDir </> "last_discussion_exchange.md")
      assertBool "next cleans up stale last_discussion_exchange.md while preserving current_turn.md" (not hasLastDiscAfterNextWrap)
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
        "record wrapup emits wrapup_recorded, compact wrapup metadata, [DRIVER_DONE hint, is_chapter_end false, wrapup_pending false, and is_finished true"
        ( "\"status\": \"wrapup_recorded\"" `isInfixOf` outRecWrap
            && "\"chapter_label\": \"Final Wrapup & Retrospective\"" `isInfixOf` outRecWrap
            && "\"story_chunk_file\": null" `isInfixOf` outRecWrap
            && "\"prediction_summary\": \"Final tally: 2 unresolved\"" `isInfixOf` outRecWrap
            && "\"current_turn_file\":" `isInfixOf` outRecWrap
            && "[DRIVER_DONE | ...]" `isInfixOf` outRecWrap
            && "\"is_chapter_end\": false" `isInfixOf` outRecWrap
            && "\"wrapup_pending\": false" `isInfixOf` outRecWrap
            && "\"is_finished\": true" `isInfixOf` outRecWrap
        )
      wrapupTurnTxt <- TIO.readFile (sessDir </> "current_turn.md")
      assertBool
        "record wrapup updates current_turn.md with wrapup entry without trailing rule"
        ( "## Final Wrapup & Retrospective" `T.isInfixOf` wrapupTurnTxt
            && "Looking back across both chapters" `T.isInfixOf` wrapupTurnTxt
            && not ("---\n" `T.isSuffixOf` wrapupTurnTxt)
        )

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
        "post-wrapup discuss reports total_chunks, is_chapter_end false, is_finished true, wrapup_pending false, and directs driver to [DRIVER_DONE"
        ( "\"total_chunks\": 2" `isInfixOf` outDiscWrap
            && "\"is_chapter_end\": false" `isInfixOf` outDiscWrap
            && "\"is_finished\": true" `isInfixOf` outDiscWrap
            && "\"wrapup_pending\": false" `isInfixOf` outDiscWrap
            && "Post-wrapup discussion recorded!" `isInfixOf` outDiscWrap
            && "[DRIVER_DONE | ...]" `isInfixOf` outDiscWrap
            && not ("entries/wrapup.md to the user" `isInfixOf` outDiscWrap)
            && not ("unlock the next chunk" `isInfixOf` outDiscWrap)
        )
      wrapupEntryTxt <- TIO.readFile (sessDir </> "entries" </> "wrapup.md")
      assertBool
        "post-wrapup user discussion appends ### Reader Discussion to entries/wrapup.md"
        ( "### Reader Discussion" `T.isInfixOf` wrapupEntryTxt
            && T.pack postWrapMsg `T.isInfixOf` wrapupEntryTxt
        )
      postWrapLastDiscTxt <- TIO.readFile (sessDir </> "last_discussion_exchange.md")
      postWrapTurnTxt <- TIO.readFile (sessDir </> "current_turn.md")
      assertBool
        "post-wrapup user discussion writes reply-only delta to last_discussion_exchange.md and refreshes current_turn.md"
        ( not (T.pack postWrapMsg `T.isInfixOf` postWrapLastDiscTxt)
            && "Definitely the brass compass discovery" `T.isInfixOf` postWrapLastDiscTxt
            && not ("Looking back across both chapters" `T.isInfixOf` postWrapLastDiscTxt)
            && "Looking back across both chapters" `T.isInfixOf` postWrapTurnTxt
            && T.pack postWrapMsg `T.isInfixOf` postWrapTurnTxt
        )
      (ecNextFin, outNextFin, errNextFin) <- readProcessWithExitCode binPath ["next", "--session", sessDir] ""
      assertEq ("CLI next on already-finished session exit 0 (" ++ errNextFin ++ ")") ExitSuccess ecNextFin
      hasLastDiscAfterFinNext <- doesFileExist (sessDir </> "last_discussion_exchange.md")
      assertBool
        "post-finale no-op next reports finished with current_turn_file and preserves last_discussion_exchange.md"
        ( "\"status\": \"finished\"" `isInfixOf` outNextFin
            && "\"current_turn_file\":" `isInfixOf` outNextFin
            && hasLastDiscAfterFinNext
        )

      forM_
        [ ("persona_suspense", "Suspense & Dread Reader", "suspense and dread reader")
        , ("persona_history", "History & Folklore Buff", "history and folklore buff")
        , ("persona_drama", "Drama & Motives Watcher", "drama and motives watcher")
        ]
        $ \(dirSlug, presetName, altName) -> do
          let pSessDir = tmp </> dirSlug
          (ecPInit, _, errPInit) <-
            readProcessWithExitCode
              binPath
              ["init", srcPath, "--session", pSessDir, "--persona", T.unpack presetName]
              ""
          assertEq ("CLI init with preset " ++ T.unpack presetName ++ " exit 0 (" ++ errPInit ++ ")") ExitSuccess ecPInit
          stPreset <- loadState pSessDir
          assertEq
            ("CLI init resolves " ++ T.unpack presetName ++ " via personas.md matching Prompts fallback")
            (expandPersonaPreset presetName)
            (stPersona stPreset)
          assertEq
            ("CLI init preset fallback matches 'and' variant for " ++ T.unpack presetName)
            (expandPersonaPreset altName)
            (stPersona stPreset)
