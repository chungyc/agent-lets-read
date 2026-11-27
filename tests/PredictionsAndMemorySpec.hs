{-# LANGUAGE OverloadedStrings #-}

module PredictionsAndMemorySpec
  ( testRec4PredictionSubClausesAndScreening
  , testRec5ArcRollupsFinalMysteriesAndHallOfFame
  , testRec6LeadingEmphasisAndMarkdownFormatting
  , testRec7IndexByteBudgetsWrappingAndSummaryLint
  , testRec8CrossArcPredictionIndexesAndEchoGuard
  , testRec9PersistentActiveScreeningNotes
  ) where

import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import Data.List (isPrefixOf, isSuffixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Command.Discuss (DiscussOptions (..), cmdDiscuss)
import LetsRead.Command.Judge (JudgeOptions (..), cmdJudge)
import LetsRead.Index
  ( IndexSpec (..)
  , applyTopicCuratorResponse
  , checkStorySummaryStructure
  , completedStoryArcRollups
  , predictionIndexSpec
  , renderEntryBullet
  , renderStoryBullet
  , storyIndexSpec
  , syncMultiLayerIndex
  )
import LetsRead.Memory
  ( cleanChunkSummary
  , mergeCuratedNarrativeMemoryForTurn
  , parseChunkSummaries
  , renderMemoryMarkdown
  , syncPredictionsDirectory
  )
import LetsRead.Predictions
  ( applyJudgeVerdicts
  , applyJudgeVerdictsWithFeedback
  , auditAndApplyPredictionUpdates
  , checkPredictionConcisenessIssues
  , parsePredictionLine
  , renderHallOfFameMarkdown
  , renderPredSummaryBullet
  )
import LetsRead.Prompts
  ( fallbackPluginRefFromExePath
  , renderPredictionSlateNote
  , resolveSessionFilesRefPathIO
  , writeCurrentJudgePromptFile
  , writeCurrentPromptFile
  , writeCurrentScriptPromptFile
  , writeCurrentTopicPromptFile
  , writeFactCheckDiscussionPromptFile
  , writeUserDiscussionPromptFile
  , writeWrapupPromptFile
  )
import LetsRead.Types
  ( EntryDiscussionRecord (..)
  , EntryLogRecord (..)
  , ParsedChunkSummaries (..)
  , ParsedPrediction (..)
  , PredictionRecord (..)
  , PredictionStatus (..)
  , ResolutionMeta (..)
  , SessionState (..)
  , StoryChunkRecord (..)
  , chunkToMeta
  , loadState
  , ledgerPredictions
  , predActiveScreeningNote
  , saveState
  , stripAfterClosingBracket
  , wrapMarkdownBullet
  , wrapMarkdownParagraph
  )
import LetsRead.Verification
  ( lintReaderCommentary
  , lintStorySummaryBullets
  , renderCriticFeedbackMarkdown
  )
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.Exit (die)
import System.FilePath ((</>))
import TestHarness
  ( assertBool
  , assertEq
  , baseDummyState
  , dummyChunk
  , normWs
  , withTempDir
  )

testRec4PredictionSubClausesAndScreening :: IO ()
testRec4PredictionSubClausesAndScreening = withTempDir "rec4-preds" $ \tmp -> do
  putStrLn "== Rec #4: Sub-Clause Overflow Audit, Screening Flags & Diversified Retirement =="
  let clueOk = "Lin notices fresh salt stains on the locked boathouse latch"
      theoryOver =
        "Mara unlocked the flooded North Pier boathouse at high tide using the duplicate brass key from the customs office so she could hide the harbor master's forged cargo ledger behind the upper rafters before dawn patrol arrived"
      predLineOverflow =
        "- **[Predicted Chunk 0004 | Topics: Detective Lin, Mara, Boathouse]** **Clue/Anomaly**: "
          <> clueOk
          <> " -> **Theory**: "
          <> theoryOver
  assertBool "Theory clause > 220 chars" (T.length theoryOver > 220)
  let (recs1, _, auditBlocks1, _) =
        auditAndApplyPredictionUpdates
          4
          10
          2
          "Boathouse"
          1
          2
          True
          "Liveblog commentary in natural prose."
          []
          (Just predLineOverflow)
  assertEq "Overflowing sub-clause still records the active prediction" 1 (length recs1)
  assertEq "Sub-clause overflow increments prediction_audit_warnings_count" 1 (length auditBlocks1)
  case recs1 of
    (firstPr : _) ->
      assertBool
        "checkPredictionConcisenessIssues flags Theory cap"
        (any ("`**Theory**`" `T.isInfixOf`) (checkPredictionConcisenessIssues firstPr))
    [] -> die "Expected 1 prediction record"

  let theoryOk = "Mara used the boathouse at high tide to hide the harbor master's ledger"
      predLineClean =
        "- **[Predicted Chunk 0004 | Topics: Detective Lin, Mara]** **Clue/Anomaly**: "
          <> clueOk
          <> " -> **Theory**: "
          <> theoryOk
      (_, _, auditBlocksClean, trackerLinesClean) =
        auditAndApplyPredictionUpdates 4 10 2 "Boathouse" 1 2 True "Natural commentary prose." [] (Just predLineClean)
  assertEq "Clean sub-clauses produce 0 prediction audit warnings" 0 (length auditBlocksClean)
  assertEq "Decoupled commentary produces 1 tracker proposal line for pre-judge review" 1 (length trackerLinesClean)

  let midChunk = dummyChunk 4 2 1 2
      stMid =
        (baseDummyState 10)
          { stCurrentIndex = 4
          , stCurrentMeta = Just (chunkToMeta midChunk)
          , stPredictions = recs1
          }
  jpPath <- writeCurrentJudgePromptFile tmp stMid
  jpTxt <- TIO.readFile jpPath
  forM_ ["[UNINTERESTING]", "[UNGROUNDED]", "[DUPLICATE-THESIS]", "[HEDGED]", "[VAGUE]"] $ \flag ->
    assertBool ("Judge prompt includes screening flag " ++ T.unpack flag) (flag `T.isInfixOf` jpTxt)
  assertBool
    "Judge prompt marks memory.md as mandatory context read"
    ("Reader Memory File (mandatory context read)" `T.isInfixOf` jpTxt)
  assertBool
    "Judge prompt drops old mechanical proxy flags [LINEAR] and [SHORT-HORIZON]"
    (not ("[LINEAR]" `T.isInfixOf` jpTxt) && not ("[SHORT-HORIZON]" `T.isInfixOf` jpTxt))
  assertBool "Judge prompt highlights mid-chapter split context" ("Mid-Chapter Split Context" `T.isInfixOf` jpTxt)
  assertBool "Judge prompt includes Event-Trigger and Window Expiry guidance" ("Event-Trigger" `T.isInfixOf` jpTxt)

  let chap3Meta = (3, "Boathouse Reveal", 1, 1)
      (recsNextChunkHit, _, _) =
        applyJudgeVerdicts
          5
          chap3Meta
          recs1
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0004 -> CONFIRMED Chunk 0005]** Mara reveals the ledger hidden in the boathouse.\n"
  case recsNextChunkHit of
    (pr5 : _) ->
      assertEq
        "1-chunk foresight confirmation receives full Confirmed Hit status (isSameChunk = False)"
        (PredStatusConfirmed (ResolutionMeta 5 3 "Boathouse Reveal" 1 1 "Mara reveals the ledger hidden in the boathouse.") False)
        (prStatus pr5)
    [] -> die "Expected 1 judged prediction record"
  let chap2Meta = (2, "Boathouse", 1, 2)
      (recsSameChunk, _, _) =
        applyJudgeVerdicts
          4
          chap2Meta
          recs1
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0004 -> CONFIRMED Chunk 0004]** Already revealed in Chunk 4.\n"
  case recsSameChunk of
    (pr4 : _) ->
      assertEq
        "Same-chunk confirmation marks isSameChunk = True (0 chunks foresight)"
        (PredStatusConfirmed (ResolutionMeta 4 2 "Boathouse" 1 2 "Already revealed in Chunk 4.") True)
        (prStatus pr4)
    [] -> die "Expected 1 same-chunk prediction record"

  let slate10 = normWs (renderPredictionSlateNote 8 12)
  assertBool
    "Reader slate note stays focused on 1 new prediction with zero 10-cap or RETIRED bookkeeping"
    (not ("RETIRED" `T.isInfixOf` slate10) && not ("10-PREDICTION CAP" `T.isInfixOf` slate10))

  let elevenActives =
        [ PredictionRecord
            { prOriginChunk = i
            , prChapterNumber = i
            , prChapterTitle = "Chap " <> T.pack (show i)
            , prPartInChapter = 1
            , prPartsInChapter = 1
            , prTopics = ["Harbor"]
            , prClue = "Clue " <> T.pack (show i)
            , prTheory = "Theory " <> T.pack (show i)
            , prRawBody = "**Clue/Anomaly**: Clue " <> T.pack (show i) <> " -> **Theory**: Theory " <> T.pack (show i)
            , prStatus =
                if i == 5
                  then PredStatusActive (Just "[DUPLICATE-THESIS] Duplicates Predicted Chunk 0002.")
                  else PredStatusActive Nothing
            }
        | i <- [1 .. 11]
        ]
      stOver10 = (baseDummyState 15) {stCurrentIndex = 11, stPredictions = elevenActives}
  jpOverPath <- writeCurrentJudgePromptFile tmp stOver10
  jpOverNorm <- normWs <$> TIO.readFile jpOverPath
  assertBool
    "Judge prompt at 11 active includes Conditional 10-Cap Retirement prioritizing [DUPLICATE-THESIS] and [UNINTERESTING]"
    ( "### Conditional 10-Cap Retirement" `T.isInfixOf` jpOverNorm
        && "=== CONDITIONAL RETIREMENTS ===" `T.isInfixOf` jpOverNorm
        && "[DUPLICATE-THESIS]" `T.isInfixOf` jpOverNorm
        && "[UNINTERESTING]" `T.isInfixOf` jpOverNorm
    )

  let (afterJudgeRetire, capWarns1, _) =
        applyJudgeVerdicts
          11
          (11, "Chap 11", 1, 1)
          elevenActives
          []
          ( T.unlines
              [ "=== PREDICTION JUDGMENTS ==="
              , "- **[Predicted Chunk 0011 -> ACTIVE]** Sharp finale setup."
              , "=== CONDITIONAL RETIREMENTS ==="
              , "- **[Predicted Chunk 0005 -> RETIRED Chunk 0011]** Retiring duplicate bet."
              ]
          )
  assertEq "Judge conditional retirement brings active count from 11 to 10 with 0 warnings" (10, 0) (length [p | p <- afterJudgeRetire, prStatus p /= PredStatusRetired (ResolutionMeta 11 11 "Chap 11" 1 1 "Retiring duplicate bet.")], length capWarns1)

  let (afterJudgeSpared, _, _) =
        applyJudgeVerdicts
          11
          (11, "Chap 11", 1, 1)
          elevenActives
          []
          ( T.unlines
              [ "=== PREDICTION JUDGMENTS ==="
              , "- **[Predicted Chunk 0002 -> CONFIRMED Chunk 0011]** Confirmed on page."
              , "=== CONDITIONAL RETIREMENTS ==="
              , "- **[Predicted Chunk 0005 -> RETIRED Chunk 0011]** Spare if merit resolution suffices."
              ]
          )
  assertEq
    "Judge conditional retirement is spared when a merit CONFIRMED verdict already brings active count to 10"
    0
    (length [p | p <- afterJudgeSpared, case prStatus p of PredStatusRetired _ -> True; _ -> False])

  let (afterFallbackRetire, _, _) =
        applyJudgeVerdicts
          11
          (11, "Chap 11", 1, 1)
          elevenActives
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0011 -> ACTIVE]** Still open.\n"
  case [p | p <- afterFallbackRetire, prOriginChunk p == 5] of
    (p5Fallback : _) ->
      assertBool
        "Deterministic fallback retires [DUPLICATE-THESIS] Chunk 0005 rather than oldest unflagged Chunk 0001"
        (case prStatus p5Fallback of PredStatusRetired _ -> True; _ -> False)
    [] -> die "Expected pred 5 in afterFallbackRetire"

  -- End-to-end cmdJudge test: flagged proposal on Chunk 11 is NOT ADDED (feedback-only), sparing all 10 active bets
  withTempDir "cmd-judge-retire" $ \sessTmp -> do
    createDirectoryIfMissing True (sessTmp </> "entries")
    createDirectoryIfMissing True (sessTmp </> "chunks")
    TIO.writeFile (sessTmp </> "chunks" </> "chunk_0011.md") "Mara checked the narrow lantern alcove.\n"
    TIO.writeFile
      (sessTmp </> "entries" </> "chunk_0011.md")
      "## Chunk 11/15\n\nCommentary.\n\n> [!NOTE]\n> **Prediction Tracker Update (Reader Proposal)**:\n> - **[Predicted Chunk 0011 | Topics: Harbor]** **Clue/Anomaly**: Clue 11 -> **Theory**: Theory 11\n\n---\n\n"
    let unflagged11 = [p {prStatus = PredStatusActive Nothing} | p <- elevenActives]
        stJudge11 =
          (baseDummyState 15)
            { stCurrentIndex = 11
            , stCurrentRecorded = True
            , stCurrentJudged = False
            , stCurrentMeta = Just (chunkToMeta (dummyChunk 11 11 1 1))
            , stPredictions = unflagged11
            }
    saveState sessTmp stJudge11
    TIO.writeFile
      (sessTmp </> "current_judge_response.md")
      ( T.unlines
          [ "=== PREDICTION JUDGMENTS ==="
          , "- **[Predicted Chunk 0011 -> NOT ADDED]** [DUPLICATE-THESIS] Duplicates Predicted Chunk 0004's lantern signal theory."
          , "=== CONDITIONAL RETIREMENTS ==="
          , "- **[Predicted Chunk 0005 -> RETIRED Chunk 0011]** Spare if Chunk 0011 is not added."
          ]
      )
    TIO.writeFile
      (sessTmp </> "current_fact_check_response.md")
      "<!-- TOOLS: read_file(current_chunk.md, entries/chunk_0011.md, memory.md) -->\n=== VERIFIED CLAIMS LOG ===\n- [OK | Source: current_chunk.md] Checked.\n\n=== DISPUTED FACTS & MEMORY CHECKS ===\n- PASS\n"
    TIO.writeFile
      (sessTmp </> "current_critic_response.md")
      "=== PERSONA & STYLE CRITIQUE ===\n- **[Persona & Lens]** Good.\n- **[What Worked Well]** Good.\n- **[Where the Voice Drifted or Felt Formulaic]** None.\n"
    cmdJudge (JudgeOptions sessTmp Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing)
    stAfterCmdJudge <- loadState sessTmp
    entry11AfterRejTxt <- TIO.readFile (sessTmp </> "entries" </> "chunk_0011.md")
    assertBool
      "cmdJudge folds pre-judge Reader Proposal callout into Prediction Judge Rulings (Chunk 0011) even on NOT ADDED"
      ( not ("Prediction Tracker Update (Reader Proposal)" `T.isInfixOf` entry11AfterRejTxt)
          && "**Prediction Judge Rulings (Chunk 0011)**:" `T.isInfixOf` entry11AfterRejTxt
          && "- **[Predicted Chunk 0011 | Topics: Harbor]** **Clue/Anomaly**: Clue 11 -> **Theory**: Theory 11" `T.isInfixOf` entry11AfterRejTxt
          && "Predicted Chunk 0011 -> NOT ADDED" `T.isInfixOf` entry11AfterRejTxt
      )
    pred11FileExists <- doesFileExist (sessTmp </> "predictions" </> "pred_0011.md")
    assertBool
      "cmdJudge excludes flagged Chunk 0011 from stPredictions and predictions/pred_0011.md while sparing all 10 active bets"
      ( length (stPredictions stAfterCmdJudge) == 10
          && all (\p -> prOriginChunk p /= 11 && prStatus p == PredStatusActive Nothing) (stPredictions stAfterCmdJudge)
          && length (stRejectedPredictions stAfterCmdJudge) == 1
          && not pred11FileExists
      )
    p12Path <- writeCurrentPromptFile sessTmp (stAfterCmdJudge {stCurrentIndex = 12}) (dummyChunk 12 12 1 1)
    p12Norm <- normWs <$> TIO.readFile p12Path
    assertBool
      "Flagged NOT ADDED bet delivers ### Prediction Quality Note as feedback on Chunk 12"
      ( "### Prediction Quality Note from Chunk 11" `T.isInfixOf` p12Norm
          && "Predicted Chunk 0011 -> NOT ADDED" `T.isInfixOf` p12Norm
          && "[DUPLICATE-THESIS] Duplicates Predicted Chunk 0004's lantern signal theory." `T.isInfixOf` p12Norm
      )
    chron11Txt <- TIO.readFile (sessTmp </> "predictions" </> "by_chronology.md")
    topic11Txt <- TIO.readFile (sessTmp </> "predictions" </> "by_topic.md")
    let hof11Txt = renderHallOfFameMarkdown sessTmp (stAfterCmdJudge {stCurrentIndex = 15, stCurrentRecorded = True, stCurrentJudged = True})
    assertBool
      "Screened-out bet never appears in by_chronology.md, by_topic.md, or hall_of_fame.md"
      ( not ("pred_0011" `T.isInfixOf` chron11Txt)
          && not ("pred_0011" `T.isInfixOf` topic11Txt)
          && not ("pred_0011" `T.isInfixOf` hof11Txt)
      )

    -- Re-run cmdJudge on Chunk 11 when Chunk 11 IS accepted: === CONDITIONAL RETIREMENTS === retires Chunk 0005
    TIO.writeFile
      (sessTmp </> "current_judge_response.md")
      ( T.unlines
          [ "=== PREDICTION JUDGMENTS ==="
          , "- **[Predicted Chunk 0011 -> ACTIVE]** Non-obvious catch on the hidden alcove."
          , "=== CONDITIONAL RETIREMENTS ==="
          , "- **[Predicted Chunk 0005 -> RETIRED Chunk 0011]** Retiring narrower alcove bet to keep central harbor mysteries."
          ]
      )
    TIO.writeFile
      (sessTmp </> "current_fact_check_response.md")
      "<!-- TOOLS: read_file(current_chunk.md, entries/chunk_0011.md, memory.md) -->\n=== VERIFIED CLAIMS LOG ===\n- [OK | Source: current_chunk.md] Checked.\n\n=== DISPUTED FACTS & MEMORY CHECKS ===\n- PASS\n"
    TIO.writeFile
      (sessTmp </> "current_critic_response.md")
      "=== PERSONA & STYLE CRITIQUE ===\n- **[Persona & Lens]** Good.\n- **[What Worked Well]** Good.\n- **[Where the Voice Drifted or Felt Formulaic]** None.\n"
    cmdJudge (JudgeOptions sessTmp Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing)
    stAfterAccept11 <- loadState sessTmp
    entry11AfterAcceptTxt <- TIO.readFile (sessTmp </> "entries" </> "chunk_0011.md")
    assertBool
      "Idempotent cmdJudge re-run keeps proposed Clue/Anomaly -> Theory in single Prediction Judge Rulings callout"
      ( not ("Prediction Tracker Update (Reader Proposal)" `T.isInfixOf` entry11AfterAcceptTxt)
          && "- **[Predicted Chunk 0011 | Topics: Harbor]** **Clue/Anomaly**: Clue 11 -> **Theory**: Theory 11" `T.isInfixOf` entry11AfterAcceptTxt
          && "Predicted Chunk 0011 -> ACTIVE" `T.isInfixOf` entry11AfterAcceptTxt
      )
    pred11ExistsAfterAccept <- doesFileExist (sessTmp </> "predictions" </> "pred_0011.md")
    assertBool
      "Idempotent cmdJudge re-run restores accepted Chunk 0011, clears stRejectedPredictions, and retires nominated Chunk 0005"
      ( pred11ExistsAfterAccept
          && null (stRejectedPredictions stAfterAccept11)
          && any (\p -> prOriginChunk p == 11 && prStatus p == PredStatusActive (Just "Non-obvious catch on the hidden alcove.")) (stPredictions stAfterAccept11)
          && any (\p -> prOriginChunk p == 5 && case prStatus p of PredStatusRetired _ -> True; _ -> False) (stPredictions stAfterAccept11)
      )

testRec5ArcRollupsFinalMysteriesAndHallOfFame :: IO ()
testRec5ArcRollupsFinalMysteriesAndHallOfFame = do
  putStrLn "== Rec #5: Inline L1 Arc Rollups, Final-Chunk Mysteries & Hall of Fame Original Bet =="
  let arc1And2Story =
        [ StoryChunkRecord i ((i + 1) `div` 2) ("Chap " <> T.pack (show ((i + 1) `div` 2))) (if odd i then 1 else 2) 2 ["Harbor"] "Summary."
        | i <- [1 .. 20]
        ]
      rollups = completedStoryArcRollups arc1And2Story
  assertEq "19+ chunks across 10 chapters produces 1 completed L1 arc" 1 (length rollups)
  (arc1Label, arc1Path) <-
    case rollups of
      ((_, lbl, p) : _) -> pure (lbl, p)
      [] -> die "Expected 1 completed arc rollup"
  assertBool "Arc 1 label contains Arc 1 and chunk range" ("Arc 1 (" `T.isInfixOf` arc1Label && "Chunks 0001–0018" `T.isInfixOf` arc1Label)
  assertEq "Arc 1 path points to L1_0001.md" "chunks/archive/chronology/L1_0001.md" arc1Path

  let uncollapsedMem =
        [ ( "Story Summary So Far"
          , T.unlines
              [ "- **Core Premise, Timeline & Baseline Facts (Persistent)**: Harbor mystery."
              , "- **Ch. 1**: Arrival."
              , "- **Ch. 2**: Clues."
              , "- **Ch. 3**: Stakeout."
              , "- **Ch. 4**: Storm."
              ]
          )
        ]
  assertBool
    "Uncollapsed chapter bullets trigger structure warning"
    (checkStorySummaryStructure uncollapsedMem rollups /= Nothing)
  assertEq "lintStorySummaryBullets emits 1 linter warning" 1 (length (lintStorySummaryBullets uncollapsedMem arc1And2Story))

  let collapsedMem =
        [ ( "Story Summary So Far"
          , T.unlines
              [ "- **Core Premise, Timeline & Baseline Facts (Persistent)**: Harbor mystery."
              , "- **Arc 1 (Ch. 1–9 | Chunks 0001–0018)**: Lin and Mara uncover the smuggling ring."
              , "- **Ch. 10**: The harbor master flees toward the lighthouse."
              ]
          )
        ]
  assertEq "Properly collapsed Arc 1 + 1 current-arc bullet passes cleanly" Nothing (checkStorySummaryStructure collapsedMem rollups)

  let stWithArc =
        (baseDummyState 22)
          { stCurrentIndex = 20
          , stStoryRecords = arc1And2Story
          , stCuratedMemory = collapsedMem
          }
      memMd = renderMemoryMarkdown "/tmp/harbor-sess" stWithArc
  assertBool "memory.md renders ## Session Overview heading" ("## Session Overview" `T.isInfixOf` memMd)
  assertBool "memory.md renders ### Reader Persona heading" ("### Reader Persona" `T.isInfixOf` memMd)
  assertBool "memory.md does not use ### Session Overview (no skipped H2)" (not ("### Session Overview" `T.isInfixOf` memMd))
  let headingLevels =
        [ T.length (T.takeWhile (== '#') s)
        | l <- T.lines memMd
        , let s = T.stripStart l
        , "#" `T.isPrefixOf` s
        ]
      noSkippedHeadingLevels (a : b : rest) = b <= a + 1 && noSkippedHeadingLevels (b : rest)
      noSkippedHeadingLevels _ = True
  assertBool "memory.md heading hierarchy never skips a heading level" (noSkippedHeadingLevels headingLevels)
  assertBool "memory.md renders ### Completed L1 Story Arcs heading" ("### Completed L1 Story Arcs" `T.isInfixOf` memMd)
  assertBool "memory.md renders ### Established Topic Tags heading" ("### Established Topic Tags" `T.isInfixOf` memMd)
  assertBool "memory.md has no *Session Directory*: pseudo-heading" (not ("*Session Directory*:" `T.isInfixOf` memMd))
  assertBool "memory.md renders inline Arc 1 range & L1_0001.md link" (arc1Label `T.isInfixOf` memMd && "L1_0001.md" `T.isInfixOf` memMd)

  let priorMemWithMystery =
        [ ("Story Summary So Far", "- **Core Premise, Timeline & Baseline Facts (Persistent)**: Harbor mystery.")
        , ("Characters & Relationships", "- **Lin (Persistent)**: Inspector.")
        , ("Active Mysteries & Unanswered Questions", "- Who took the brass compass?")
        , ("Notable Quotes, Themes & Running Jokes", "- **Reader Craft Directives & Running Gags (Persistent)**: Stay grounded.")
        ]
      clearDoc1 = "## Active Mysteries & Unanswered Questions\n- None (story complete)."
      clearDoc2 = "## Active Mysteries & Unanswered Questions\n- Story complete!"
      mergedMid = mergeCuratedNarrativeMemoryForTurn False priorMemWithMystery (Just clearDoc1)
      mergedFinal1 = mergeCuratedNarrativeMemoryForTurn True priorMemWithMystery (Just clearDoc1)
      mergedFinal2 = mergeCuratedNarrativeMemoryForTurn True priorMemWithMystery (Just clearDoc2)
  assertEq
    "Mid-story turn protects Active Mysteries against accidental placeholder clear"
    (Just "- Who took the brass compass?")
    (lookup "Active Mysteries & Unanswered Questions" mergedMid)
  assertEq
    "Final chunk accepts '- None (story complete).'"
    (Just "- None (story complete).")
    (lookup "Active Mysteries & Unanswered Questions" mergedFinal1)
  assertEq
    "Final chunk accepts '- Story complete!'"
    (Just "- Story complete!")
    (lookup "Active Mysteries & Unanswered Questions" mergedFinal2)

  let prHit =
        PredictionRecord
          { prOriginChunk = 2
          , prChapterNumber = 1
          , prChapterTitle = "Arrival"
          , prPartInChapter = 2
          , prPartsInChapter = 2
          , prTopics = ["Inspector Lin", "Mara"]
          , prClue = "Mara pockets the brass key"
          , prTheory = "Mara unlocks the lighthouse vault in Act 2"
          , prRawBody = "**Clue/Anomaly**: Mara pockets the brass key -> **Theory**: Mara unlocks the lighthouse vault in Act 2"
          , prStatus = PredStatusActive Nothing
          }
      (judgedPreds, _, _) =
        applyJudgeVerdicts
          8
          (4, "The Lighthouse Vault", 2, 2)
          [prHit]
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0002 -> CONFIRMED Chunk 0008]** Mara opens the lighthouse vault using the brass key."
      stFin =
        (baseDummyState 8)
          { stCurrentIndex = 8
          , stCurrentRecorded = True
          , stCurrentJudged = True
          , stPredictions = judgedPreds
          }
      hofMd = renderHallOfFameMarkdown "/tmp/harbor-sess" stFin
      hofNorm = normWs hofMd
  assertBool
    "hall_of_fame.md includes Judge outcome note"
    ("Mara opens the lighthouse vault using the brass key." `T.isInfixOf` hofNorm)
  assertBool
    "hall_of_fame.md has no *Session Directory*: pseudo-heading"
    (not ("*Session Directory*:" `T.isInfixOf` hofMd))
  assertBool
    "hall_of_fame.md includes original Clue/Anomaly -> Theory without Plausible Rival"
    ( "**Clue/Anomaly**: Mara pockets the brass key -> **Theory**: Mara unlocks the lighthouse vault in Act 2"
        `T.isInfixOf` hofNorm
        && not ("Plausible Rival" `T.isInfixOf` hofMd)
    )

testRec6LeadingEmphasisAndMarkdownFormatting :: IO ()
testRec6LeadingEmphasisAndMarkdownFormatting = do
  putStrLn "== Rec #6 & #34: Leading Emphasis Preservation & Clean Wrapped Markdown =="
  let sumRaw =
        T.unlines
          [ "- **[Story | Topics: Harbor, Starlight]** *Starlight* arrives at Pier 4 under heavy fog."
          , "* **[Entry | Topics: Harbor, Starlight]** **Boldly** cheering as *Starlight* docks!"
          , "- **[Discussion | Topics: Harbor]**: *Starlight* manifest details confirmed."
          ]
      parsed = parseChunkSummaries sumRaw
  assertEq
    "[Story] preserves leading *Starlight* emphasis"
    (Just (["Harbor", "Starlight"], "*Starlight* arrives at Pier 4 under heavy fog."))
    (pcsStory parsed)
  assertEq
    "[Entry] with * list marker preserves leading **Boldly** emphasis"
    (Just (["Harbor", "Starlight"], "**Boldly** cheering as *Starlight* docks!"))
    (pcsEntry parsed)
  assertEq
    "[Discussion] with ]: separator preserves leading *Starlight* emphasis"
    (Just (["Harbor"], "*Starlight* manifest details confirmed."))
    (pcsDiscussion parsed)
  assertEq "cleanChunkSummary strips '- ' list marker safely" "*Starlight* sails." (cleanChunkSummary "- *Starlight* sails.")
  assertEq "cleanChunkSummary strips '* ' list marker safely" "*Starlight* sails." (cleanChunkSummary "* *Starlight* sails.")
  assertEq
    "cleanChunkSummary strips '**Chunk 0003:**' prefix while keeping *Starlight*"
    "*Starlight* sails."
    (cleanChunkSummary "**Chunk 0003:** *Starlight* sails.")
  assertEq
    "stripAfterClosingBracket preserves leading *Title*"
    "*Starlight* sails."
    (stripAfterClosingBracket "]** *Starlight* sails.")

  case parsePredictionLine "- **[Predicted Chunk 0003 -> CONFIRMED Chunk 0007]** *Starlight* carries the missing manifest." of
    PredValidResolved _ _ _ _ bodyAfter ->
      assertEq "parsePredictionLine preserves leading *Starlight* in resolution note" "*Starlight* carries the missing manifest." bodyAfter
    other -> die ("Unexpected parsePredictionLine result: " ++ show other)

  let longPara =
        "Reuse established tags where accurate, and coin clean canonical tags when genuinely distinct recurring characters, factions, locations, or plot threads emerge across chapters."
      wrappedP = wrapMarkdownParagraph 78 longPara
      wrappedB = wrapMarkdownBullet 78 ("1. " <> longPara)
  assertBool "wrapMarkdownParagraph wraps all lines <= 78 cols" (all (\l -> T.length l <= 78) (T.lines wrappedP))
  assertBool "wrapMarkdownBullet wraps all lines <= 78 cols with hanging indent" (all (\l -> T.length l <= 78) (T.lines wrappedB))
  when (length (T.lines wrappedB) < 2) $
    die "Expected wrapped bullet to span at least 2 lines"
  assertBool "Continuation line of numbered bullet has 3-space indent" ("   " `T.isPrefixOf` (T.lines wrappedB !! 1))

  withTempDir "wrapup-prompt" $ \tmp -> do
    let stWrap = (baseDummyState 8) {stCurrentIndex = 8, stCurrentRecorded = True, stCurrentJudged = True}
    wrapPath1 <- writeWrapupPromptFile tmp stWrap
    wrapNoCritic <- TIO.readFile wrapPath1
    assertBool "Wrapup prompt includes H1 title heading" ("# Final Wrapup" `T.isPrefixOf` wrapNoCritic)
    assertBool "Wrapup prompt includes ## Active Persona heading" ("## Active Persona" `T.isInfixOf` wrapNoCritic)
    assertBool "Wrapup prompt without critic_feedback.md has no triple blank lines" (not ("\n\n\n" `T.isInfixOf` wrapNoCritic))
    assertBool
      "Wrapup prompt without critic_feedback.md wraps all non-path lines <= 80 cols"
      (all (\l -> T.pack tmp `T.isInfixOf` l || "session-files.md" `T.isInfixOf` l || T.length l <= 80) (T.lines wrapNoCritic))
    assertBool
      "Wrapup prompt substitutes session-files.md reference path"
      ("session-files.md" `T.isInfixOf` wrapNoCritic && not ("{{SESSION_FILES_REF}}" `T.isInfixOf` wrapNoCritic))
    assertBool
      "Wrapup prompt mandates reading chunks/by_chronology.md and entries/by_chronology.md with zero leftover placeholders"
      ( "chunks/by_chronology.md" `T.isInfixOf` wrapNoCritic
          && "entries/by_chronology.md" `T.isInfixOf` wrapNoCritic
          && not ("{{CHUNKS_CHRON_FILE}}" `T.isInfixOf` wrapNoCritic)
          && not ("{{ENTRIES_CHRON_FILE}}" `T.isInfixOf` wrapNoCritic)
      )

    refPath <- resolveSessionFilesRefPathIO
    hasRefFile <- doesFileExist refPath
    assertBool "Resolved session-files.md plugin reference exists on disk" hasRefFile
    assertEq
      "fallbackPluginRefFromExePath derives <plugin_dir>/references/session-files.md from .bin/lets-read"
      (Just "/opt/plugins/lets-read/references/session-files.md")
      (fallbackPluginRefFromExePath ("references" </> "session-files.md") "/opt/plugins/lets-read/.bin/lets-read")
    assertEq
      "fallbackPluginRefFromExePath returns Nothing for non-.bin test executables"
      Nothing
      (fallbackPluginRefFromExePath ("references" </> "session-files.md") "/tmp/tmp.1234/Spec-bin")
    topicPromptPath <- writeCurrentTopicPromptFile tmp stWrap
    topicPromptTxt <- TIO.readFile topicPromptPath
    assertBool
      "Topic curator prompt includes session-files.md reference path"
      (T.pack refPath `T.isInfixOf` topicPromptTxt)

    let criticDoc =
          renderCriticFeedbackMarkdown
            tmp
            8
            False
            []
            []
            [ "- **[Persona & Lens]** Attentive coastal mystery liveblogger."
            , "- **[What Worked Well]** Sharp eye for brass-compass clues."
            , "- **[Where the Voice Drifted or Felt Formulaic]** Keep sentence openings varied in the finale."
            ]
    TIO.writeFile (tmp </> "critic_feedback.md") criticDoc
    wrapPath2 <- writeWrapupPromptFile tmp stWrap
    wrapWithCritic <- TIO.readFile wrapPath2
    assertBool "Wrapup prompt with critic_feedback.md includes inline critique section" ("## Persona & Style Critique from Chunk 8" `T.isInfixOf` wrapWithCritic)
    assertBool "Wrapup prompt with critic_feedback.md has no triple blank lines" (not ("\n\n\n" `T.isInfixOf` wrapWithCritic))
    assertBool
      "Wrapup prompt with critic_feedback.md wraps all non-path lines <= 80 cols"
      (all (\l -> T.pack tmp `T.isInfixOf` l || "session-files.md" `T.isInfixOf` l || T.length l <= 80) (T.lines wrapWithCritic))

testRec7IndexByteBudgetsWrappingAndSummaryLint :: IO ()
testRec7IndexByteBudgetsWrappingAndSummaryLint = do
  putStrLn "== Rec #7: Index Byte Budgets, Wrapped Bullets & Summary Length Linter =="
  let verboseSummary =
        "Mara and Inspector Lin inspect the flooded North Pier boathouse, recover the wax-sealed harbor manifest from behind theLoose pilings, and spot a lantern signal from the outer breakwater."
      sampleStoryRec =
        StoryChunkRecord
          { scrChunkIndex = 4
          , scrChapterNumber = 2
          , scrChapterTitle = "Fog Over the Outer Breakwater"
          , scrPartInChapter = 1
          , scrPartsInChapter = 2
          , scrTopics = ["Inspector Lin", "Mara", "North Pier", "Harbor Manifest"]
          , scrSummary = verboseSummary
          }
      renderedStoryB = renderStoryBullet "/tmp/sess" sampleStoryRec
  assertBool
    "renderStoryBullet wraps lines <= 78 cols"
    (all (\l -> T.length l <= 78) (T.lines renderedStoryB))
  assertBool
    "renderStoryBullet preserves full summary text without truncation"
    ("outer breakwater." `T.isInfixOf` T.unwords (T.words renderedStoryB))

  let sampleEntryRec =
        EntryLogRecord
          { elrEntryIndex = 4
          , elrIsWrapup = False
          , elrChapterNumber = 2
          , elrChapterTitle = "Fog Over the Outer Breakwater"
          , elrPartInChapter = 1
          , elrPartsInChapter = 2
          , elrTopics = ["Inspector Lin", "Mara"]
          , elrSummary = "Cheered when Lin noticed the wax seal and joked about the damp ledger."
          , elrDiscussions =
              [ EntryDiscussionRecord
                  { edrIsFactCheck = True
                  , edrTopics = ["North Pier"]
                  , edrSummary = "Verified against chunk_0002.md that the boathouse key came from the harbor clerk."
                  }
              , EntryDiscussionRecord
                  { edrIsFactCheck = False
                  , edrTopics = ["Mara"]
                  , edrSummary = "Discussed with user whether Mara suspects the lighthouse keeper yet."
                  }
              ]
          }
      renderedEntryB = renderEntryBullet "/tmp/sess" sampleEntryRec
      entryLines = T.lines renderedEntryB
  assertBool
    "renderEntryBullet wraps all lines <= 78 cols"
    (all (\l -> T.length l <= 78) entryLines)
  assertEq
    "renderEntryBullet keeps both discussion sub-bullets on separate indented lines"
    2
    (length [l | l <- entryLines, "  - **" `T.isPrefixOf` l])

  let samplePredRec =
        PredictionRecord
          { prOriginChunk = 4
          , prChapterNumber = 2
          , prChapterTitle = "Fog Over the Outer Breakwater"
          , prPartInChapter = 1
          , prPartsInChapter = 2
          , prTopics = ["Inspector Lin", "Harbor Manifest"]
          , prClue = "Wax seal matches the customs house stamp"
          , prTheory = "The deputy collector forged the manifest to divert contraband to the lighthouse"
          , prRawBody = "**Clue/Anomaly**: Wax seal matches the customs house stamp -> **Theory**: The deputy collector forged the manifest to divert contraband to the lighthouse"
          , prStatus =
              PredStatusConfirmed
                ( ResolutionMeta
                    { rmChunk = 9
                    , rmChapterNumber = 5
                    , rmChapterTitle = "Lighthouse Cellar"
                    , rmPartInChapter = 1
                    , rmPartsInChapter = 1
                    , rmNote = "Chunk 0009 reveals the deputy collector's duplicate stamp and ledger in the lighthouse cellar."
                    }
                )
                False
          }
      renderedPredB = renderPredSummaryBullet samplePredRec
  assertBool
    "renderPredSummaryBullet wraps lines <= 78 cols"
    (all (\l -> T.length l <= 78) (T.lines renderedPredB))

  let manyLongChaps =
        [ StoryChunkRecord i i ("The Very Long Light-Novel Style Chapter Title About Stormy Pier Investigation Part " <> T.pack (show i)) 1 1 ["Harbor"] "Summary."
        | i <- [1 .. 10]
        ]
      arcSummary = isSummarizeArc storyIndexSpec manyLongChaps
  assertBool "isSummarizeArc stays bounded <= 220 chars" (T.length arcSummary <= 220)
  assertBool "isSummarizeArc keeps closing * italic delimiter intact" ("*" `T.isSuffixOf` arcSummary && "+8 more*" `T.isSuffixOf` arcSummary || "more*" `T.isSuffixOf` arcSummary)

  let shortSummaryStory =
        [ StoryChunkRecord i ((i + 1) `div` 2) ("Chap " <> T.pack (show ((i + 1) `div` 2))) (if odd i then 1 else 2) 2 ["Harbor Patrol"] "Short."
        | i <- [1 .. 20]
        ]
      longSummaryStory =
        [ r {scrSummary = T.replicate 5 "Detailed coastal investigation summary across the misty pier. "}
        | r <- shortSummaryStory
        ]
      (stMergedAliases, _) =
        applyTopicCuratorResponse
          "=== TOPIC MERGES ===\n- Harbor Watch <= Harbor Patrol\n"
          ((baseDummyState 25) {stStoryRecords = longSummaryStory})
  assertEq
    "completedStoryArcRollups boundaries are unaffected by summary length"
    (completedStoryArcRollups shortSummaryStory)
    (completedStoryArcRollups longSummaryStory)
  assertEq
    "completedStoryArcRollups boundaries are unaffected by topic alias merges"
    (completedStoryArcRollups shortSummaryStory)
    (completedStoryArcRollups (stStoryRecords stMergedAliases))

  withTempDir "index-byte-budget" $ \tmp -> do
    let bigSum = T.replicate 5 "Mara and Inspector Lin cross-check the harbor ledger, customs manifest, and signal timestamps along the pier. "
        verboseRecords =
          [ StoryChunkRecord
              { scrChunkIndex = i
              , scrChapterNumber = (i + 1) `div` 2
              , scrChapterTitle = "Chapter " <> T.pack (show ((i + 1) `div` 2)) <> ": Harbor Signals and Sealed Manifests"
              , scrPartInChapter = if odd i then 1 else 2
              , scrPartsInChapter = 2
              , scrTopics =
                  [ "Inspector Lin"
                  , "Topic Group " <> T.pack (show ((i `mod` 12) + 1))
                  , "Thread " <> T.pack (show ((i `mod` 8) + 1))
                  ]
              , scrSummary = bigSum
              }
          | i <- [1 .. 20]
          ]
        stIdx =
          (baseDummyState 25)
            { stCurrentIndex = 20
            , stStoryRecords = verboseRecords
            }
    syncMultiLayerIndex tmp stIdx storyIndexSpec verboseRecords
    byTopicBytes <- BS.length <$> BS.readFile (tmp </> "chunks" </> "by_topic.md")
    byTopicTxt <- TIO.readFile (tmp </> "chunks" </> "by_topic.md")
    assertBool "Verbose by_topic.md triggers sharding when bytes exceed inline budget" ("## Topic Archive Shards" `T.isInfixOf` byTopicTxt)
    assertBool "Sharded by_topic.md stays <= 20,000 bytes" (byTopicBytes <= 20000)

    let topicArcDir = tmp </> "chunks" </> "archive" </> "topics"
    arcFiles <- listDirectory topicArcDir
    let shardFiles = [f | f <- arcFiles, "L1_" `isPrefixOf` f && ".md" `isSuffixOf` f]
        perTopicFiles = [f | f <- arcFiles, "topic_" `isPrefixOf` f && ".md" `isSuffixOf` f]
    assertBool "Multiple L1 topic shards created under byte budget" (length shardFiles >= 2)
    assertBool "Verbose 20-item topic (>6KB, <=25 items) creates per-topic L1 archive" (not (null perTopicFiles))
    forM_ arcFiles $ \f -> do
      hasF <- doesFileExist (topicArcDir </> f)
      when hasF $ do
        sz <- BS.length <$> BS.readFile (topicArcDir </> f)
        assertBool ("Topic archive file " ++ f ++ " stays <= 16,000 bytes") (sz <= 16000)

  let okSummaries =
        ParsedChunkSummaries
          { pcsStory = Just (["Harbor"], "Mara finds the manifest in the boathouse.")
          , pcsEntry = Just (["Harbor"], "Loved the banter on the pier.")
          , pcsDiscussion = Nothing
          }
      overlongText = T.replicate 6 "This single-line summary runs way past the 250-character target budget. "
      overlongSummaries =
        ParsedChunkSummaries
          { pcsStory = Just (["Harbor"], overlongText)
          , pcsEntry = Just (["Harbor"], overlongText)
          , pcsDiscussion = Nothing
          }
  assertEq
    "Concise <= 250 char summaries produce 0 linter warnings"
    []
    (lintReaderCommentary [] "Normal liveblog reaction." okSummaries Nothing)
  let overlongWarns = lintReaderCommentary [] "Normal liveblog reaction." overlongSummaries Nothing
  assertEq "Overlong > 250 char summaries trigger 1 summary linter warning" 1 (length overlongWarns)
  assertBool
    "Summary linter warning flags both [Story] and [Entry] > 250 char caps"
    ( case overlongWarns of
        (w : _) -> "`[Story]` summary was " `T.isInfixOf` w && "`[Entry]` summary was " `T.isInfixOf` w && "<= 250 chars" `T.isInfixOf` w
        [] -> False
    )

testRec8CrossArcPredictionIndexesAndEchoGuard :: IO ()
testRec8CrossArcPredictionIndexesAndEchoGuard = withTempDir "rec8-cross-arc" $ \tmp -> do
  putStrLn "== Rec #8: Cross-Arc Prediction Resolutions, Gap Spans, Echo Guard & Topic Recency =="
  let stEmpty = baseDummyState 40
  syncPredictionsDirectory tmp stEmpty
  emptyChronTxt <- TIO.readFile (tmp </> "predictions" </> "by_chronology.md")
  assertBool
    "Empty prediction slate renders by_chronology.md without crashing"
    ("No entries recorded yet" `T.isInfixOf` emptyChronTxt)

  let mkActivePred idx chap topics theoryTxt =
        PredictionRecord
          { prOriginChunk = idx
          , prChapterNumber = chap
          , prChapterTitle = "Chapter " <> T.pack (show chap) <> ": Pier Thread " <> T.pack (show chap)
          , prPartInChapter = if odd idx then 1 else 2
          , prPartsInChapter = 2
          , prTopics = topics
          , prClue = "Clue on chunk " <> T.pack (show idx)
          , prTheory = theoryTxt
          , prRawBody =
              "**Clue/Anomaly**: Clue on chunk "
                <> T.pack (show idx)
                <> " -> **Theory**: "
                <> theoryTxt
          , prStatus = PredStatusActive Nothing
          }

      pr2 = mkActivePred 2 1 ["Beacon Cipher", "Mara"] "Mara uses the Beacon Cipher to unlock the vault"
      pr3 = mkActivePred 3 2 ["Customs Seal", "Inspector Lin"] "The Customs Seal was forged at North Pier"
      pr4 = mkActivePred 4 2 ["Tide Bell"] "The Tide Bell rings only at low water"

      (after18, _, summary18) =
        applyJudgeVerdicts
          18
          (9, "Chapter 9: Harbor Gate", 2, 2)
          [pr2, pr3, pr4]
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0003 -> DEBUNKED Chunk 0018]** Draft note.\n"
      (after18ReRun, _, summary18ReRun) =
        applyJudgeVerdicts
          18
          (9, "Chapter 9: Harbor Gate", 2, 2)
          after18
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0003 -> DEBUNKED Chunk 0018]** Customs clerk proves the seal was authentic.\n"
      (after19Echo, _, summary19Echo) =
        applyJudgeVerdicts
          19
          (10, "Chapter 10: Outer Reef", 1, 2)
          after18ReRun
          []
          ( T.unlines
              [ "=== PREDICTION JUDGMENTS ==="
              , "- **[Predicted Chunk 0003 -> DEBUNKED Chunk 0018]** Customs clerk proves the seal was authentic."
              , "- **[Predicted Chunk 0002 -> CONFIRMED Chunk 0019]** Mara decodes the Beacon Cipher on the reef door."
              ]
          )
  assertBool
    "Chunk 18 summary records pred_0003 resolution"
    (any ("Predicted Chunk 0003 -> DEBUNKED Chunk 0018" `T.isInfixOf`) summary18)
  assertBool
    "Same-chunk Judge re-run (rmChunk == curIdx) stays idempotent and keeps pred_0003 in Chunk 18 summary"
    (any ("Predicted Chunk 0003 -> DEBUNKED Chunk 0018" `T.isInfixOf`) summary18ReRun)
  assertBool
    "Unchanged Recently Resolved echo of pred_0003 on Chunk 19 is not re-emitted in Chunk 19 summary"
    (not (any ("Predicted Chunk 0003" `T.isInfixOf`) summary19Echo))
  case [p | p <- after19Echo, prOriginChunk p == 3] of
    (p3After : _) ->
      assertEq
        "Same-chunk re-run updates Chunk 18 note and Chunk 19 echo preserves Chunk 18 & Chapter 9 ResolutionMeta"
        (PredStatusDebunked (ResolutionMeta 18 9 "Chapter 9: Harbor Gate" 2 2 "Customs clerk proves the seal was authentic."))
        (prStatus p3After)
    [] -> die "Expected pred_0003 in after19Echo"

  let (after20Reversal, _, _) =
        applyJudgeVerdicts
          20
          (10, "Chapter 10: Outer Reef", 2, 2)
          after19Echo
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0003 -> SUBVERTED Chunk 0020]** The authentic seal was stamped onto a decoy manifest!\n"
  p2Resolved <-
    case [p | p <- after20Reversal, prOriginChunk p == 2] of
      (p : _) -> pure p
      [] -> die "Expected pred_0002 in after20Reversal"
  p3Rev <-
    case [p | p <- after20Reversal, prOriginChunk p == 3] of
      (p : _) -> pure p
      [] -> die "Expected pred_0003 in after20Reversal"
  assertEq
    "Genuine cliffhanger fake-out reversal updates ResolutionMeta to Chunk 20 & Chapter 10"
    (PredStatusSubverted (ResolutionMeta 20 10 "Chapter 10: Outer Reef" 2 2 "The authentic seal was stamped onto a decoy manifest!"))
    (prStatus p3Rev)

  -- Build Arc 1 (Chunks 1..18, Ch. 1..9), skip Chunk 19 (gap!), and build Arc 2 (Chunks 20..25, Ch. 10..12)
  let pr4Retired =
        pr4
          { prStatus =
              PredStatusRetired
                (ResolutionMeta 21 11 "Chapter 11: Fog Bell" 1 2 "Retired for 10-prediction cap.")
          }
      arc1Preds =
        [ if i == 2
            then p2Resolved
            else
              if i == 3
                then p3Rev
                else
                  if i == 4
                    then pr4Retired
                    else mkActivePred i ((i + 1) `div` 2) ["Topic Group " <> T.pack (show i), "Harbor Thread " <> T.pack (show (i `mod` 7))] ("Long theory text for prediction " <> T.pack (show i) <> " across the misty breakwater and customs pier.")
        | i <- [1 .. 18]
        ]
      arc2Preds =
        [ mkActivePred i ((i + 1) `div` 2) ["Topic Group " <> T.pack (show i)] ("Arc 2 theory text for prediction " <> T.pack (show i) <> " in the upper lighthouse.")
        | i <- [20 .. 25]
        ]
      stArc2 =
        (baseDummyState 45)
          { stCurrentIndex = 20
          , stPredictions = arc1Preds ++ arc2Preds
          }
  syncPredictionsDirectory tmp stArc2
  chronArc2 <- TIO.readFile (tmp </> "predictions" </> "by_chronology.md")
  l1Arc1 <- TIO.readFile (tmp </> "predictions" </> "archive" </> "chronology" </> "L1_0001.md")
  pred2Doc <- TIO.readFile (tmp </> "predictions" </> "pred_0002.md")
  assertBool
    "pred_0002.md includes resolution chapter metadata"
    ("Chapter 10: Outer Reef, Part 1/2" `T.isInfixOf` pred2Doc)
  assertBool
    "L1_0001.md retains Arc 1 predictions 1..18 without an earlier-arc footer"
    ("[pred_0002]" `T.isInfixOf` l1Arc1 && not ("Earlier-Arc Predictions Resolved in This Arc" `T.isInfixOf` l1Arc1))
  assertBool
    "by_chronology.md renders ## Earlier-Arc Active Predictions with still-active Arc 1 bets"
    ( "## Earlier-Arc Active Predictions" `T.isInfixOf` chronArc2
        && "[pred_0001]" `T.isInfixOf` chronArc2
        && not ("\n\n\n" `T.isInfixOf` chronArc2)
    )
  assertBool
    "by_chronology.md renders ## Earlier-Arc Predictions Resolved Here"
    ("## Earlier-Arc Predictions Resolved Here" `T.isInfixOf` chronArc2)
  assertBool
    "Gap-chunk resolution (Chunk 19 between Arc 1 end 18 and Arc 2 start 20) appears inline in by_chronology.md"
    ("[pred_0002]" `T.isInfixOf` chronArc2 && "CONFIRMED Chk 0019 (Hit)" `T.isInfixOf` chronArc2)
  assertBool
    "Chunk 20 reversal of pred_0003 also appears inline in by_chronology.md"
    ("[pred_0003]" `T.isInfixOf` chronArc2 && "SUBVERTED Chk 0020" `T.isInfixOf` chronArc2)
  assertBool
    "Cap-retired pred_0004 is excluded from Earlier-Arc Active and Resolved sections"
    (not ("[pred_0004]" `T.isInfixOf` chronArc2))

  -- Also check when earlier-arc active bets exist with zero cross-arc resolutions
  let arc1AllActiveOrRetired =
        [ if i == 4 then pr4Retired else mkActivePred i ((i + 1) `div` 2) ["Harbor"] ("Open theory " <> T.pack (show i))
        | i <- [1 .. 18]
        ]
      stArc2ActiveOnly =
        (baseDummyState 45)
          { stCurrentIndex = 20
          , stPredictions = arc1AllActiveOrRetired ++ arc2Preds
          }
  syncPredictionsDirectory tmp stArc2ActiveOnly
  chronArc2ActiveOnly <- TIO.readFile (tmp </> "predictions" </> "by_chronology.md")
  assertBool
    "by_chronology.md with earlier-arc active bets and 0 cross-arc resolutions omits Resolved section cleanly"
    ( "## Earlier-Arc Active Predictions" `T.isInfixOf` chronArc2ActiveOnly
        && "[pred_0001]" `T.isInfixOf` chronArc2ActiveOnly
        && not ("[pred_0004]" `T.isInfixOf` chronArc2ActiveOnly)
        && not ("## Earlier-Arc Predictions Resolved Here" `T.isInfixOf` chronArc2ActiveOnly)
        && not ("\n\n\n" `T.isInfixOf` chronArc2ActiveOnly)
    )
  syncPredictionsDirectory tmp stArc2

  -- Advance into Arc 3 (Chunks 39..43, Ch. 20..22) so Arc 2 (Chunks 20..38) archives into L1_0002.md
  let arc2FullPreds =
        [ mkActivePred i ((i + 1) `div` 2) ["Topic Group " <> T.pack (show i), "Extra Tag " <> T.pack (show (i + 20))] (T.replicate 2 "Detailed coastal mystery theory text to push by_topic.md past the inline threshold into sharded mode. ")
        | i <- [20 .. 38]
        ]
      arc3Preds =
        [ mkActivePred i ((i + 1) `div` 2) ["Arc Three Tag " <> T.pack (show i)] "Final act theory."
        | i <- [39 .. 43]
        ]
      pr4LateRetired =
        pr4
          { prStatus =
              PredStatusRetired
                (ResolutionMeta 42 21 "Chapter 21: Bell Tower" 2 2 "Retired on Chunk 42 for 10-prediction cap.")
          }
      pr5LateHit =
        (mkActivePred 5 3 ["Silent Bell", "North Breakwater"] "The Silent Bell hides the smuggler's cipher key")
          { prStatus =
              PredStatusConfirmed
                (ResolutionMeta 41 21 "Chapter 21: Bell Tower" 1 2 "Mara finds the cipher key inside the Silent Bell.")
                False
          }
      pr6SameChunkHit =
        (mkActivePred 6 3 ["Silent Bell"] "A second secret compartment sits under the bell")
          { prStatus =
              PredStatusDebunked
                (ResolutionMeta 41 21 "Chapter 21: Bell Tower" 1 2 "No second compartment existed under the bell.")
          }
      arc1WithLateHits =
        [ if prOriginChunk p == 4
            then pr4LateRetired
            else
              if prOriginChunk p == 5
                then pr5LateHit
                else if prOriginChunk p == 6 then pr6SameChunkHit else p
        | p <- arc1Preds
        ]
      allPredsArc3 = arc1WithLateHits ++ arc2FullPreds ++ arc3Preds
      stArc3 =
        (baseDummyState 45)
          { stCurrentIndex = 43
          , stPredictions = allPredsArc3
          }
  syncMultiLayerIndex tmp stArc3 predictionIndexSpec allPredsArc3
  l1Arc2 <- TIO.readFile (tmp </> "predictions" </> "archive" </> "chronology" </> "L1_0002.md")
  chronArc3 <- TIO.readFile (tmp </> "predictions" </> "by_chronology.md")
  byTopicArc3 <- TIO.readFile (tmp </> "predictions" </> "by_topic.md")
  assertBool
    "Completed L1_0002.md retains Chunk 19 & 20 cross-arc resolutions in its footer"
    ("## Earlier-Arc Predictions Resolved in This Arc" `T.isInfixOf` l1Arc2 && "[pred_0002]" `T.isInfixOf` l1Arc2 && "[pred_0003]" `T.isInfixOf` l1Arc2)
  assertBool
    "Completed Arc 2 summary in by_chronology.md notes +2 earlier resolved here"
    ("+2 earlier resolved here" `T.isInfixOf` normWs chronArc3)
  assertBool
    "Arc 3 by_chronology.md shows newly resolved pred_0005 and pred_0006 inline under Chapter 21"
    ("### Chapter 21: Bell Tower" `T.isInfixOf` chronArc3 && "[pred_0005]" `T.isInfixOf` chronArc3 && "[pred_0006]" `T.isInfixOf` chronArc3)
  assertBool
    "predictions/by_topic.md is in Sharded Mode"
    ("## Topic Archive Shards" `T.isInfixOf` byTopicArc3 && "## Recently Updated Topics" `T.isInfixOf` byTopicArc3)
  assertBool
    "Sharded predictions/by_topic.md surfaces Silent Bell inline with both same-chunk-resolved predictions (no deduplication collision)"
    ("### Silent Bell" `T.isInfixOf` byTopicArc3 && "[pred_0005]" `T.isInfixOf` byTopicArc3 && "[pred_0006]" `T.isInfixOf` byTopicArc3)
  assertBool
    "Sharded predictions/by_topic.md excludes cap-retired Tide Bell from Recently Updated Topics"
    (not ("### Tide Bell" `T.isInfixOf` byTopicArc3))

testRec9PersistentActiveScreeningNotes :: IO ()
testRec9PersistentActiveScreeningNotes = withTempDir "rec9-screening" $ \tmp -> do
  putStrLn "== Rec #9: Persistent Active Screening Notes, Overwrite Guards & Copied-Slate Parser Guard =="
  let mkBet idx chap topics theoryTxt =
        PredictionRecord
          { prOriginChunk = idx
          , prChapterNumber = chap
          , prChapterTitle = "Chapter " <> T.pack (show chap) <> ": Harbor"
          , prPartInChapter = 1
          , prPartsInChapter = 1
          , prTopics = topics
          , prClue = "Clue " <> T.pack (show idx)
          , prTheory = theoryTxt
          , prRawBody =
              "**Clue/Anomaly**: Clue "
                <> T.pack (show idx)
                <> " -> **Theory**: "
                <> theoryTxt
          , prStatus = PredStatusActive Nothing
          }
      bet1 = mkBet 1 1 ["Mara", "Harbor"] "Mara hid the tide chart in the boathouse"
      bet2 = mkBet 2 2 ["Inspector Lin", "Harbor"] "Lin arrives at Pier 2 after breakfast"

      -- Chunk 1 initial screening: flagged proposal is NOT ADDED, whereas unflagged re-run enters the active ledger
      (after1Draft, rejs1Draft, _, summary1Draft) =
        applyJudgeVerdictsWithFeedback
          1
          (1, "Chapter 1: Harbor", 1, 1)
          [bet1]
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0001 -> NOT ADDED]** [UNINTERESTING] Initial mistaken flag.\n"
      (after1ReRun, rejs1ReRun, _, _) =
        applyJudgeVerdictsWithFeedback
          1
          (1, "Chapter 1: Harbor", 1, 1)
          [bet1]
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0001 -> ACTIVE]** Sharp catch linking Mara's wet boots to the tide chart!\n"
  assertEq "Flagged Chunk 1 proposal is excluded from active ledger" 0 (length after1Draft)
  assertEq "Flagged Chunk 1 proposal is returned in rejected feedback list" 1 (length rejs1Draft)
  assertBool
    "Judge callout summary marks screened-out proposal as -> NOT ADDED"
    (any ("Predicted Chunk 0001 -> NOT ADDED" `T.isInfixOf`) summary1Draft)
  assertEq "Unflagged Chunk 1 re-run produces 0 rejections" 0 (length rejs1ReRun)
  case after1ReRun of
    (p1 : _) ->
      assertEq
        "Unflagged Chunk 1 prediction enters active ledger with Judge note"
        (Just "Sharp catch linking Mara's wet boots to the tide chart!")
        (predActiveScreeningNote p1)
    [] -> die "Expected bet1 after Chunk 1 judge"

  -- Chunk 2: bet2 gets [UNINTERESTING] (even if Judge wrote -> ACTIVE [UNINTERESTING]); bet1 stays active untouched
  let (after2, rejs2, _, _) =
        applyJudgeVerdictsWithFeedback
          2
          (2, "Chapter 2: Harbor", 1, 1)
          (after1ReRun ++ [bet2])
          []
          ( T.unlines
              [ "=== PREDICTION JUDGMENTS ==="
              , "- **[Predicted Chunk 0001 -> ACTIVE]** Still unresolved; not addressed in Chunk 0002 (avoid logging a [DUPLICATE-THESIS] of this)."
              , "- **[Predicted Chunk 0002 -> ACTIVE]** [UNINTERESTING] Routine morning itinerary already stated on page."
              ]
          )
  case [p | p <- after2, prOriginChunk p == 1] of
    (p1After2 : _) ->
      assertEq
        "Later-chunk 'Still unresolved' mentioning [DUPLICATE-THESIS] mid-sentence does not clobber bet1's note"
        (Just "Sharp catch linking Mara's wet boots to the tide chart!")
        (predActiveScreeningNote p1After2)
    [] -> die "Expected bet1 after Chunk 2"
  assertBool
    "Flagged bet2 (even with -> ACTIVE [UNINTERESTING]) is NOT added to active ledger"
    (all (\p -> prOriginChunk p /= 2) after2)
  assertEq
    "Flagged bet2 is captured as feedback-only rejection"
    [(bet2, "[UNINTERESTING] Routine morning itinerary already stated on page.")]
    rejs2

  -- Chunk 3: bet3 resolves same-chunk CONFIRMED; check rendering & non-active thesis visibility
  let bet3 = mkBet 3 3 ["Mara"] "Mara's lantern signal summons the cutter"
      (after3, _, _, _) =
        applyJudgeVerdictsWithFeedback
          3
          (3, "Chapter 3: Harbor", 1, 1)
          (after2 ++ [bet3])
          []
          ( T.unlines
              [ "=== PREDICTION JUDGMENTS ==="
              , "- **[Predicted Chunk 0001 -> ACTIVE]** Still unresolved in Chunk 0003."
              , "- **[Predicted Chunk 0003 -> CONFIRMED Chunk 0003]** Cutter answers Mara's lantern immediately."
              ]
          )

  let stRender =
        (baseDummyState 10)
          { stCurrentIndex = 3
          , stCurrentRecorded = True
          , stCurrentJudged = True
          , stPredictions = after3
          , stRejectedPredictions = rejs2
          }
  syncPredictionsDirectory tmp stRender
  let memTxt = renderMemoryMarkdown tmp stRender
  pred1FileTxt <- TIO.readFile (tmp </> "predictions" </> "pred_0001.md")
  pred2Exists <- doesFileExist (tmp </> "predictions" </> "pred_0002.md")
  byChronTxt <- TIO.readFile (tmp </> "predictions" </> "by_chronology.md")
  byTopicTxt <- TIO.readFile (tmp </> "predictions" </> "by_topic.md")
  jpPersistPath <- writeCurrentJudgePromptFile tmp (stRender {stCurrentIndex = 4})
  jpPersistNorm <- normWs <$> TIO.readFile jpPersistPath
  assertBool
    "memory.md omits Active Prediction Slate and scoreboard tally while preserving predictions index links"
    ( not ("Active Prediction Slate" `T.isInfixOf` memTxt)
        && not ("Judge screening" `T.isInfixOf` memTxt)
        && "predictions/by_chronology.md" `T.isInfixOf` memTxt
        && "predictions/by_topic.md" `T.isInfixOf` memTxt
    )
  assertBool
    "Judge prompt retains accepted active screening note and lists prior NOT ADDED / resolved theses against recycling"
    ( "*Prior screening*: Sharp catch linking Mara's wet boots to the tide chart!" `T.isInfixOf` jpPersistNorm
        && "## Prior Non-Active Theses" `T.isInfixOf` jpPersistNorm
        && "Chunk 0002 (NOT ADDED): Lin arrives at Pier 2 after breakfast" `T.isInfixOf` jpPersistNorm
    )
  assertBool
    "pred_0001.md renders - **Judge Screening**: without Plausible Rival while unresolved, and rejected pred_0002.md does not exist"
    ( "- **Judge Screening**: Sharp catch linking Mara's wet boots to the tide chart!" `T.isInfixOf` normWs pred1FileTxt
        && not ("Plausible Rival" `T.isInfixOf` pred1FileTxt)
        && not pred2Exists
    )
  assertBool
    "by_chronology.md and by_topic.md omit rejected pred_0002 completely"
    (not ("pred_0002" `T.isInfixOf` byChronTxt) && not ("pred_0002" `T.isInfixOf` byTopicTxt))

  -- Event-only turn prompts check: quiet turn vs. verdict + rejected-proposal feedback + syntax-warning turn
  let stQuietTurn2 = (baseDummyState 10) {stCurrentIndex = 2, stPredictions = after1ReRun}
      chk2 = dummyChunk 2 2 1 1
  quietPromptPath <- writeCurrentPromptFile tmp stQuietTurn2 chk2
  quietPromptTxt <- TIO.readFile quietPromptPath
  assertBool
    "Quiet turn (accepted bet on Chunk 1, 0 resolutions, 0 rejections, 0 warnings) emits zero prediction event subsections"
    ( not ("### Prediction Verdicts" `T.isInfixOf` quietPromptTxt)
        && not ("### Prediction Quality Note" `T.isInfixOf` quietPromptTxt)
        && not ("### Prediction Format and Length Warnings" `T.isInfixOf` quietPromptTxt)
        && not ("Sharp catch linking Mara's wet boots" `T.isInfixOf` quietPromptTxt)
    )

  let bet3DupRej = mkBet 3 3 ["Harbor"] "Lin arrives at Pier 2 right after breakfast"
      stEventTurn4 =
        (baseDummyState 10)
          { stCurrentIndex = 4
          , stPredictions = after3
          , stRejectedPredictions = [(bet3DupRej, "[DUPLICATE-THESIS] Duplicates prior dock schedule bet.")]
          , stPredictionAuditWarnings = ["- **[INVALID PREDICTION TAG OR FORMAT]** Sample syntax warning."]
          }
      chk4 = dummyChunk 4 4 1 1
  evReaderPath <- writeCurrentPromptFile tmp stEventTurn4 chk4
  evReaderNorm <- normWs <$> TIO.readFile evReaderPath
  evScriptPath <- writeCurrentScriptPromptFile tmp stEventTurn4 chk4
  evScriptNorm <- normWs <$> TIO.readFile evScriptPath
  assertBool
    "Reader prompt surfaces CONFIRMED verdict + original Theory, NOT ADDED feedback note, and syntax warnings"
    ( "### Prediction Verdicts from Chunk 3" `T.isInfixOf` evReaderNorm
        && "Original prediction — **Clue/Anomaly**: Clue 3 -> **Theory**: Mara's lantern signal summons the cutter" `T.isInfixOf` evReaderNorm
        && "### Prediction Quality Note from Chunk 3" `T.isInfixOf` evReaderNorm
        && "Predicted Chunk 0003 -> NOT ADDED" `T.isInfixOf` evReaderNorm
        && "### Prediction Format and Length Warnings" `T.isInfixOf` evReaderNorm
    )
  assertBool
    "Script-writer prompt surfaces verdicts and NOT ADDED quality feedback while omitting syntax warnings"
    ( "### Prediction Verdicts from Chunk 3" `T.isInfixOf` evReaderNorm
        && "### Prediction Verdicts from Chunk 3" `T.isInfixOf` evScriptNorm
        && "### Prediction Quality Note from Chunk 3" `T.isInfixOf` evScriptNorm
        && "Predicted Chunk 0003 -> NOT ADDED" `T.isInfixOf` evScriptNorm
        && not ("### Prediction Format and Length Warnings" `T.isInfixOf` evScriptNorm)
    )

  (_, fcDiscPath) <- writeFactCheckDiscussionPromptFile tmp (stRender {stCurrentIndex = 1}) ["- **[Peer Verification Query]** Check timeline."]
  fcDiscTxt <- TIO.readFile fcDiscPath
  (_, uDiscPath) <- writeUserDiscussionPromptFile tmp (stRender {stCurrentIndex = 1}) "What about Pier 2?"
  uDiscTxt <- TIO.readFile uDiscPath
  assertBool
    "Fact-check and user discussion prompts include Chunk N's accepted prediction as a clean single bullet"
    ( "- **[Predicted Chunk 0001" `T.isInfixOf` fcDiscTxt
        && "- **[Predicted Chunk 0001" `T.isInfixOf` uDiscTxt
        && not ("- `- **[Predicted" `T.isInfixOf` fcDiscTxt)
        && not ("- `- **[Predicted" `T.isInfixOf` uDiscTxt)
    )
  (_, fcDiscPath3) <- writeFactCheckDiscussionPromptFile tmp stRender ["- **[Peer Verification Query]** Check timeline."]
  fcDiscNorm3 <- normWs <$> TIO.readFile fcDiscPath3
  (_, uDiscPath3) <- writeUserDiscussionPromptFile tmp stRender "What about Pier 2?"
  uDiscNorm3 <- normWs <$> TIO.readFile uDiscPath3
  (_, uDiscPreWrapPath) <- writeUserDiscussionPromptFile tmp (stRender {stCurrentIndex = 10}) "Thoughts on the finale before wrapup?"
  uDiscPreWrapNorm <- normWs <$> TIO.readFile uDiscPreWrapPath
  createDirectoryIfMissing True (tmp </> "entries")
  TIO.writeFile (tmp </> "entries" </> "wrapup.md") "## Final Wrapup\n\nRetrospective.\n"
  (_, uDiscPostWrapPath) <- writeUserDiscussionPromptFile tmp (stRender {stCurrentIndex = 10}) "Final thoughts?"
  uDiscPostWrapNorm <- normWs <$> TIO.readFile uDiscPostWrapPath
  assertBool
    "Chunk > 1 discussion prompts list Recorded Entry Under Discussion and cold-start by_chronology.md guidance"
    ( "Recorded Entry Under Discussion (`entries/chunk_0003.md`)" `T.isInfixOf` fcDiscNorm3
        && "Recorded Entry Under Discussion (`entries/chunk_0003.md`)" `T.isInfixOf` uDiscNorm3
        && "chunks/by_chronology.md" `T.isInfixOf` fcDiscNorm3
        && "entries/by_chronology.md" `T.isInfixOf` fcDiscNorm3
        && "predictions/by_chronology.md" `T.isInfixOf` fcDiscNorm3
        && "chunks/by_chronology.md" `T.isInfixOf` uDiscNorm3
        && "predictions/by_chronology.md" `T.isInfixOf` uDiscNorm3
    )
  assertBool
    "Pre-wrapup finale user discussion (Chunk N/N before entries/wrapup.md exists) references entries/chunk_0010.md + hall_of_fame.md and NOT entries/wrapup.md"
    ( "entries/chunk_0010.md" `T.isInfixOf` uDiscPreWrapNorm
        && "current_chunk.md" `T.isInfixOf` uDiscPreWrapNorm
        && "predictions/hall_of_fame.md" `T.isInfixOf` uDiscPreWrapNorm
        && not ("entries/wrapup.md" `T.isInfixOf` uDiscPreWrapNorm)
    )
  assertBool
    "Post-wrapup user discussion (once entries/wrapup.md exists) references entries/wrapup.md and predictions/hall_of_fame.md"
    ( "Recorded Entry Under Discussion (`entries/wrapup.md`)" `T.isInfixOf` uDiscPostWrapNorm
        && "entries/wrapup.md" `T.isInfixOf` uDiscPostWrapNorm
        && "predictions/hall_of_fame.md" `T.isInfixOf` uDiscPostWrapNorm
        && not ("entries/chunk_0010.md" `T.isInfixOf` uDiscPostWrapNorm)
        && not ("current_chunk.md" `T.isInfixOf` uDiscPostWrapNorm)
    )
  assertBool
    "Chunk 1 discussion prompts omit by_chronology.md cold-start list"
    (not ("by_chronology.md" `T.isInfixOf` fcDiscTxt) && not ("by_chronology.md" `T.isInfixOf` uDiscTxt))

  -- Chunk 4: cliffhanger fake-out reopening resets bet3 to PredStatusActive Nothing
  let (after4Reopen, _, _) =
        applyJudgeVerdicts
          4
          (4, "Chapter 4: Harbor", 1, 1)
          after3
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0003 -> ACTIVE]** The cutter turned out to be a harbor patrol decoy!\n"
  case [p | p <- after4Reopen, prOriginChunk p == 3] of
    (p3Reopened : _) ->
      assertEq
        "Cliffhanger fake-out reopening resets to PredStatusActive Nothing"
        (PredStatusActive Nothing)
        (prStatus p3Reopened)
    [] -> die "Expected reopened bet3 after Chunk 4"

  -- Parser guard: copying active prediction + indented '*Judge screening*:' sub-bullet from memory.md into === PREDICTION UPDATES ===
  let copiedSlateWithNewBet =
        T.unlines
          [ "- **[Predicted Chunk 0001 | Topics: Mara, Harbor]** **Clue/Anomaly**: Clue 1 -> **Theory**: Mara hid the tide chart in the boathouse ([details](predictions/pred_0001.md))"
          , "  - *Judge screening*: [DUPLICATE-THESIS] Redundant restatement of stated dock schedule."
          , "  - `Judge screening`: [UNINTERESTING] Backtick-formatted screening label."
          , "  - *Prior screening*: [DUPLICATE-THESIS] Prior screening label."
          , "  - Original prediction — **Clue/Anomaly**: Clue 1 -> **Theory**: Mara hid the tide chart in the boathouse"
          , "  - Previous prediction — **Clue/Anomaly**: Clue 4 -> **Theory**: Patrol cutter"
          , "- **[Predicted Chunk 0005 | Topics: Mara, Beacon]** **Clue/Anomaly**: Mara oils the shutter hinge -> **Theory**: Mara will flash a shuttered signal at midnight"
          ]
      (recs5, _, auditWarns5, _) =
        auditAndApplyPredictionUpdates
          5
          10
          5
          "Chapter 5: Beacon"
          1
          1
          True
          copiedSlateWithNewBet
          after4Reopen
          (Just copiedSlateWithNewBet)
  assertEq
    "Copying active prediction + '*Judge screening*: [DUPLICATE-THESIS] ...' from memory.md produces 0 audit warnings"
    0
    (length auditWarns5)
  assertEq "Records new Chunk 5 prediction cleanly alongside existing bets" 3 (length recs5)

  -- Regression checks for review findings #1, #2, #3, and #4
  let (_, rejsNotAdmitted, _, _) =
        applyJudgeVerdictsWithFeedback
          2
          (2, "Chapter 2: Harbor", 1, 1)
          [bet2]
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0002 -> NOT ADMITTED]** [UNINTERESTING] Paraphrased rejection tag.\n"
      (_, rejsNotActive, _, _) =
        applyJudgeVerdictsWithFeedback
          2
          (2, "Chapter 2: Harbor", 1, 1)
          [bet2]
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0002 -> NOT ACTIVE]** Plain rejection without bracket flag.\n"
      (_, rejsNoArrowFlagged, _, _) =
        applyJudgeVerdictsWithFeedback
          2
          (2, "Chapter 2: Harbor", 1, 1)
          [bet2]
          []
          "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0002]** [HEDGED] Menu bet across three distinct suspects.\n"
  assertEq "-> NOT ADMITTED parses as rejected (not fail-open ACTIVE)" 1 (length rejsNotAdmitted)
  assertEq "-> NOT ACTIVE without bracket flag parses as rejected with normalized flag" 1 (length rejsNotActive)
  assertEq "Arrowless bullet starting with [HEDGED] parses as rejected" 1 (length rejsNoArrowFlagged)

  -- Finding #3: priorNonActive sorts by closure chunk so a Ch. 1 bet retired on Chunk 19 stays visible on Chunk 20
  let earlyBetRetiredLate =
        (mkBet 1 1 ["Harbor"] "Early Chapter 1 conspiracy thesis retired on Chunk 19")
          { prStatus = PredStatusRetired (ResolutionMeta 19 10 "Chap 10" 1 1 "Retired on Chunk 19.")
          }
      manyMidRejects =
        [ (mkBet idx idx ["Harbor"] ("Rejected mid-story bet " <> T.pack (show idx)), "[UNINTERESTING] Routine.")
        | idx <- [2 .. 15]
        ]
      stManyClosed =
        (baseDummyState 25)
          { stCurrentIndex = 20
          , stPredictions = [earlyBetRetiredLate]
          , stRejectedPredictions = manyMidRejects
          }
  jpManyPath <- writeCurrentJudgePromptFile tmp stManyClosed
  jpManyNorm <- normWs <$> TIO.readFile jpManyPath
  assertBool
    "Prior Non-Active Theses retains Chunk 0001 retired on Chunk 19 ahead of older rejections"
    ("Chunk 0001 (RETIRED Chk 0019): Early Chapter 1 conspiracy thesis retired on Chunk 19" `T.isInfixOf` jpManyNorm)

  -- Finding #4: ledgerPredictions hides unjudged current-chunk proposal until judged
  let stUnjudged =
        (baseDummyState 10)
          { stCurrentIndex = 2
          , stCurrentRecorded = True
          , stCurrentJudged = False
          , stPredictions = [bet1, bet2]
          }
  assertEq "ledgerPredictions excludes unjudged Chunk 2 proposal" [1] (map prOriginChunk (ledgerPredictions stUnjudged))

  -- Finding #2: cmdJudge with NOT ADDED + fact-check dispute omits Prediction Logged section, and cmdDiscuss suppresses phantom tracker callout
  withTempDir "cmd-judge-discuss-rejected" $ \discTmp -> do
    createDirectoryIfMissing True (discTmp </> "entries")
    createDirectoryIfMissing True (discTmp </> "chunks")
    TIO.writeFile (discTmp </> "current_chunk.md") "Lin walked along North Pier.\n"
    TIO.writeFile (discTmp </> "chunks" </> "chunk_0002.md") "Lin walked along North Pier.\n"
    TIO.writeFile (discTmp </> "entries" </> "chunk_0002.md") "## Chunk 2/10\n\nCommentary.\n\n---\n\n"
    saveState
      discTmp
      ( (baseDummyState 10)
          { stCurrentIndex = 2
          , stCurrentRecorded = True
          , stCurrentJudged = False
          , stCurrentMeta = Just (chunkToMeta (dummyChunk 2 2 1 1))
          , stPredictions = [bet1, bet2]
          }
      )
    TIO.writeFile
      (discTmp </> "current_judge_response.md")
      "=== PREDICTION JUDGMENTS ===\n- **[Predicted Chunk 0001 -> ACTIVE]** Still open.\n- **[Predicted Chunk 0002 -> NOT ADDED]** [UNINTERESTING] Routine dock walk.\n"
    TIO.writeFile
      (discTmp </> "current_fact_check_response.md")
      ( T.unlines
          [ "<!-- TOOLS: read_file(current_chunk.md, entries/chunk_0002.md, memory.md) -->"
          , "=== VERIFIED CLAIMS LOG ==="
          , "- [DISPUTED | Source: current_chunk.md] Check pier name."
          , ""
          , "=== DISPUTED FACTS & MEMORY CHECKS ==="
          , "- **[In-Story Fact | Source: current_chunk.md | Quote: \"Lin walked along North Pier.\"]** Was it North Pier or South Pier?"
          ]
      )
    TIO.writeFile
      (discTmp </> "current_critic_response.md")
      "=== PERSONA & STYLE CRITIQUE ===\n- **[Persona & Lens]** Good.\n- **[What Worked Well]** Good.\n- **[Where the Voice Drifted or Felt Formulaic]** None.\n"
    cmdJudge (JudgeOptions discTmp Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing)
    fcPromptAfterRej <- TIO.readFile (discTmp </> "current_discussion_prompt.md")
    assertBool
      "Fact-check discussion prompt after NOT ADDED omits ## Prediction Logged on Chunk 0002 and === PREDICTION UPDATES ==="
      ( not ("## Prediction Logged on Chunk 0002" `T.isInfixOf` fcPromptAfterRej)
          && not ("=== PREDICTION UPDATES ===" `T.isInfixOf` fcPromptAfterRej)
      )
    TIO.writeFile
      (discTmp </> "current_discussion_response.md")
      ( T.unlines
          [ "<!-- TOOLS: read_file(current_discussion_prompt.md, current_chunk.md) -->"
          , "=== COMMENTARY ==="
          , "Right, it was North Pier!"
          , ""
          , "=== CHUNK SUMMARY ==="
          , "- **[Discussion | Topics: Harbor]** Confirmed North Pier."
          , ""
          , "=== PREDICTION UPDATES ==="
          , "- **[Predicted Chunk 0002 | Topics: Inspector Lin, Harbor]** **Clue/Anomaly**: North Pier walk -> **Theory**: Lin arrives after breakfast"
          ]
      )
    cmdDiscuss (DiscussOptions discTmp Nothing Nothing Nothing Nothing Nothing Nothing)
    stAfterRejDisc <- loadState discTmp
    entry2AfterDisc <- TIO.readFile (discTmp </> "entries" </> "chunk_0002.md")
    assertBool
      "cmdDiscuss keeps NOT ADDED Chunk 0002 out of stPredictions and suppresses phantom Prediction Tracker Update callout"
      ( all (\p -> prOriginChunk p /= 2) (stPredictions stAfterRejDisc)
          && not ("Prediction Tracker Update" `T.isInfixOf` entry2AfterDisc)
      )
