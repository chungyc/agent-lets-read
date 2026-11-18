{-# LANGUAGE OverloadedStrings #-}

module PredictionsAndMemorySpec
  ( testRec4PredictionSubClausesAndScreening
  , testRec5ArcRollupsFinalMysteriesAndHallOfFame
  , testRec6LeadingEmphasisAndMarkdownFormatting
  ) where

import Control.Monad (forM_, when)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Index
  ( checkStorySummaryStructure
  , completedStoryArcRollups
  )
import LetsRead.Memory
  ( cleanChunkSummary
  , mergeCuratedNarrativeMemoryForTurn
  , parseChunkSummaries
  , renderMemoryMarkdown
  )
import LetsRead.Predictions
  ( applyJudgeVerdicts
  , auditAndApplyPredictionUpdates
  , checkPredictionConcisenessIssues
  , parsePredictionLine
  , renderHallOfFameMarkdown
  )
import LetsRead.Prompts
  ( renderPredictionSlateNote
  , writeCurrentJudgePromptFile
  , writeWrapupPromptFile
  )
import LetsRead.Types
  ( ParsedChunkSummaries (..)
  , ParsedPrediction (..)
  , PredictionRecord (..)
  , PredictionStatus (..)
  , SessionState (..)
  , StoryChunkRecord (..)
  , chunkToMeta
  , stripAfterClosingBracket
  , wrapMarkdownBullet
  , wrapMarkdownParagraph
  )
import LetsRead.Verification
  ( lintStorySummaryBullets
  , renderCriticFeedbackMarkdown
  )
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
      theoryOk = "Mara used the boathouse at high tide to hide the harbor master's ledger"
      rival139 = "The salt stains are leftover spray from last week's gale, and the harbor master still has the ledger locked inside his upstairs office safe"
      predLineOverflow =
        "- **[Predicted Chunk 0004 | Topics: Detective Lin, Mara, Boathouse]** **Clue/Anomaly**: "
          <> clueOk
          <> " -> **Theory**: "
          <> theoryOk
          <> " (vs. **Plausible Rival**: "
          <> rival139
          <> ")"
  assertBool "Rival clause > 120 chars" (T.length rival139 > 120)
  let (recs1, _, auditBlocks1, _) =
        auditAndApplyPredictionUpdates
          4
          10
          2
          "Boathouse"
          1
          2
          True
          predLineOverflow
          []
          (Just predLineOverflow)
  assertEq "Overflowing sub-clause still records the active prediction" 1 (length recs1)
  assertEq "Sub-clause overflow increments prediction_audit_warnings_count" 1 (length auditBlocks1)
  case recs1 of
    (firstPr : _) ->
      assertBool
        "checkPredictionConcisenessIssues flags Plausible Rival cap"
        (any ("Plausible Rival" `T.isInfixOf`) (checkPredictionConcisenessIssues firstPr))
    [] -> die "Expected 1 prediction record"

  let rivalOk = "The salt stains are spray from last night's storm and the boathouse was never opened"
      predLineClean =
        "- **[Predicted Chunk 0004 | Topics: Detective Lin, Mara]** **Clue/Anomaly**: "
          <> clueOk
          <> " -> **Theory**: "
          <> theoryOk
          <> " (vs. **Plausible Rival**: "
          <> rivalOk
          <> ")"
      (_, _, auditBlocksClean, _) =
        auditAndApplyPredictionUpdates 4 10 2 "Boathouse" 1 2 True predLineClean [] (Just predLineClean)
  assertEq "Clean sub-clauses produce 0 prediction audit warnings" 0 (length auditBlocksClean)

  let midChunk = dummyChunk 4 2 1 2
      stMid =
        (baseDummyState 10)
          { stCurrentIndex = 4
          , stCurrentMeta = Just (chunkToMeta midChunk)
          , stPredictions = recs1
          }
  jpPath <- writeCurrentJudgePromptFile tmp stMid
  jpTxt <- TIO.readFile jpPath
  forM_ ["[SPLIT-CONTINUATION]", "[SHORT-HORIZON]", "[DUPLICATE-THESIS]", "[LINEAR]", "[HEDGED]", "[VAGUE]"] $ \flag ->
    assertBool ("Judge prompt includes screening flag " ++ T.unpack flag) (flag `T.isInfixOf` jpTxt)
  assertBool "Judge prompt highlights mid-chapter split context" ("Mid-Chapter Split Context" `T.isInfixOf` jpTxt)
  assertBool "Judge prompt includes Event-Trigger and Window Expiry guidance" ("Event-Trigger" `T.isInfixOf` jpTxt)

  let slate10 = normWs (renderPredictionSlateNote 8 12 10)
  assertBool
    "10-cap slate note warns against mechanical oldest-first FIFO"
    ("[DUPLICATE-THESIS]" `T.isInfixOf` slate10 && "oldest-first FIFO" `T.isInfixOf` slate10)

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
          , prRival = "Mara tosses the key into the bay"
          , prRawBody = "**Clue/Anomaly**: Mara pockets the brass key -> **Theory**: Mara unlocks the lighthouse vault in Act 2 (vs. **Plausible Rival**: Mara tosses the key into the bay)"
          , prStatus = PredStatusActive
          , prResolutionNote = Nothing
          }
      (judgedPreds, _, _) =
        applyJudgeVerdicts
          8
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
    "hall_of_fame.md includes original Clue/Anomaly -> Theory (vs. Plausible Rival)"
    ( "**Clue/Anomaly**: Mara pockets the brass key -> **Theory**: Mara unlocks the lighthouse vault in Act 2 (vs. **Plausible Rival**: Mara tosses the key into the bay)"
        `T.isInfixOf` hofNorm
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
      (all (\l -> T.pack tmp `T.isInfixOf` l || T.length l <= 80) (T.lines wrapNoCritic))

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
      (all (\l -> T.pack tmp `T.isInfixOf` l || T.length l <= 80) (T.lines wrapWithCritic))
