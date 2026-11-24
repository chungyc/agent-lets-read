{-# LANGUAGE OverloadedStrings #-}

module VerificationSpec
  ( testRec2SandboxToolTelemetry
  , testRec3CallbackAndFactCheckAudits
  , testRec10HiddenScriptAndResearchVerification
  ) where

import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (computeShouldRotate)
import LetsRead.Memory (parseCombinedResponse)
import LetsRead.Prompts
  ( writeCurrentChunkFile
  , writeCurrentFactCheckPromptFile
  , writeCurrentPromptFile
  , writeCurrentResearchPromptFile
  , writeCurrentScriptPromptFile
  , writeWrapupScriptPromptFile
  )
import LetsRead.Types
  ( SessionState (..)
  , StoryChunkRecord (..)
  , stripToolReceiptComments
  )
import LetsRead.Verification
  ( SubagentToolAudit (..)
  , auditFactCheckerClaims
  , auditReaderToolUsage
  , auditReaderToolUsageWithResearch
  , checkSubagentLogUsedSearchWeb
  , checkSubagentLogUsedVerificationTools
  , extractSubagentLogResponse
  , extractVerifiedResearchChunkRefs
  , parseResearchNotesSection
  , parseToolReceiptTag
  , renderCurrentResearchMarkdown
  , resolveSubagentToolAudit
  , verifyAndFilterCriticFactBullets
  , verifyAndFilterResearchBullets
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import TestHarness
  ( assertBool
  , assertEq
  , baseDummyState
  , dummyChunk
  , normWs
  , withTempDir
  )

testRec2SandboxToolTelemetry :: IO ()
testRec2SandboxToolTelemetry = withTempDir "rec2-sandbox" $ \tmp -> do
  putStrLn "== Rec #2: Sandbox-Compatible Subagent Tool-Verification Telemetry =="
  assertEq
    "parseToolReceiptTag parses [Tools: read_file(...), search_web]"
    (Just (True, ["current_chunk.md", "chunks/chunk_0002.md"], False))
    (parseToolReceiptTag "Done: wrote response to /tmp/s/current_reader_response.md [Tools: read_file(current_chunk.md, chunks/chunk_0002.md), search_web(\"harbor lighthouse\")]")
  assertEq
    "parseToolReceiptTag parses [Tools: none]"
    (Just (False, [], False))
    (parseToolReceiptTag "Done: wrote discussion response to /tmp/s/current_discussion_response.md [Tools: none]")
  assertEq
    "parseToolReceiptTag parses <!-- TOOLS: ... --> comment"
    (Just (False, ["chunks/chunk_0003.md"], False))
    (parseToolReceiptTag "<!-- TOOLS: read_file(chunks/chunk_0003.md) -->\n=== COMMENTARY ===\nHello!")

  let childId1 = "11111111-2222-3333-4444-555555555555"
      childLogDir1 = tmp </> "brain" </> childId1 </> ".system_generated" </> "logs"
      childLog1 = childLogDir1 </> "transcript.jsonl"
  createDirectoryIfMissing True childLogDir1
  TIO.writeFile
    childLog1
    ( T.unlines
        [ "{\"step_index\":0,\"type\":\"SYSTEM_MESSAGE\",\"content\":\"Read prompt\"}"
        , "{\"step_index\":1,\"type\":\"PLANNER_RESPONSE\",\"tool_calls\":[{\"name\":\"read_file\",\"args\":{\"Path\":\"\\\"/sess/current_discussion_prompt.md\\\"\"}},{\"name\":\"read_file\",\"args\":{\"Path\":\"\\\"/sess/chunks/chunk_0002.md\\\"\"}}]}"
        , "{\"step_index\":2,\"type\":\"PLANNER_RESPONSE\",\"content\":\"Done: wrote discussion response to /sess/current_discussion_response.md\"}"
        ]
    )
  v1 <- checkSubagentLogUsedVerificationTools childLog1
  s1 <- checkSubagentLogUsedSearchWeb childLog1
  assertEq "Tier 1 child transcript detects read_file on chunk_0002.md" (Just True) v1
  assertEq "Tier 1 child transcript detects no search_web" (Just False) s1

  let childIdPromptOnly = "11111111-2222-3333-4444-666666666666"
      childLogDirPO = tmp </> "brain" </> childIdPromptOnly </> ".system_generated" </> "logs"
      childLogPO = childLogDirPO </> "transcript.jsonl"
  createDirectoryIfMissing True childLogDirPO
  TIO.writeFile
    childLogPO
    ( T.unlines
        [ "{\"step_index\":0,\"type\":\"SYSTEM_MESSAGE\",\"content\":\"Read prompt\"}"
        , "{\"step_index\":1,\"type\":\"PLANNER_RESPONSE\",\"tool_calls\":[{\"name\":\"read_file\",\"args\":{\"Path\":\"\\\"/sess/current_discussion_prompt.md\\\"\"}}]}"
        ]
    )
  vPO <- checkSubagentLogUsedVerificationTools childLogPO
  assertEq "Tier 1 child transcript reading ONLY current_discussion_prompt.md -> Just False" (Just False) vPO

  let callerId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      unmountedChildA = "99999999-8888-7777-6666-555555555551"
      unmountedChildB = "99999999-8888-7777-6666-555555555552"
      unmountedChildC = "99999999-8888-7777-6666-555555555553"
      sandboxBrain = tmp </> "sandbox-brain"
      callerLogDir = sandboxBrain </> callerId </> ".system_generated" </> "logs"
      callerMsgDir = sandboxBrain </> callerId </> ".system_generated" </> "messages"
  createDirectoryIfMissing True callerLogDir
  createDirectoryIfMissing True callerMsgDir

  TIO.writeFile
    (callerLogDir </> "transcript.jsonl")
    ( T.unlines
        [ "{\"step_index\":10,\"type\":\"SYSTEM_MESSAGE\",\"created_at\":\"2026-11-17T10:00:01Z\",\"content\":\"<SYSTEM_MESSAGE>\\nSubagent "
            <> T.pack unmountedChildA
            <> " has gone idle. This was the subagent's most recent response: Done: wrote discussion response to /sess/current_discussion_response.md [Tools: read_file(chunks/chunk_0004.md)]\\n</SYSTEM_MESSAGE>\"}"
        , "{\"step_index\":11,\"type\":\"SYSTEM_MESSAGE\",\"created_at\":\"2026-11-17T10:00:02Z\",\"content\":\"<SYSTEM_MESSAGE>\\nSubagent "
            <> T.pack unmountedChildB
            <> " has gone idle. This was the subagent's most recent response: Done: wrote discussion response to /sess/current_discussion_response.md [Tools: none]\\n</SYSTEM_MESSAGE>\"}"
        ]
    )
  TIO.writeFile
    (callerMsgDir </> "msg1.json")
    ( "{\"sender\":\"system\",\"timestamp\":\"2026-11-17T10:00:05Z\",\"content\":\"Subagent "
        <> T.pack unmountedChildC
        <> " has gone idle. This was the subagent's most recent response: Done: wrote fact-check audit to /sess/current_fact_check_response.md [Tools: read_file(current_chunk.md, memory.md), search_web]\"}"
    )

  let unmountedPathA = sandboxBrain </> unmountedChildA </> ".system_generated" </> "logs" </> "transcript.jsonl"
      unmountedPathB = sandboxBrain </> unmountedChildB </> ".system_generated" </> "logs" </> "transcript.jsonl"
      unmountedPathC = sandboxBrain </> unmountedChildC </> ".system_generated" </> "logs" </> "transcript.jsonl"
  vSandA <- checkSubagentLogUsedVerificationTools unmountedPathA
  sSandA <- checkSubagentLogUsedSearchWeb unmountedPathA
  vSandB <- checkSubagentLogUsedVerificationTools unmountedPathB
  sSandC <- checkSubagentLogUsedSearchWeb unmountedPathC
  mExtractedNotice <- extractSubagentLogResponse unmountedPathA
  assertEq "Tier 2 sandbox parent transcript resolves [Tools: read_file(...)] -> Just True" (Just True) vSandA
  assertEq "Tier 2 sandbox parent transcript resolves no search_web -> Just False" (Just False) sSandA
  assertEq "Tier 2 sandbox parent transcript resolves [Tools: none] -> Just False" (Just False) vSandB
  assertEq "Tier 2 sandbox parent system message resolves search_web -> Just True" (Just True) sSandC
  assertEq "Completion notice with [Tools: ...] is not mistaken for full response body" Nothing mExtractedNotice

  let rawRespWithTools =
        T.unlines
          [ "<!-- TOOLS: read_file(chunks/chunk_0001.md), search_web(\"harbor\") -->"
          , "=== COMMENTARY ==="
          , "Checked the harbor chart and verified!"
          ]
  auditHdr <- resolveSubagentToolAudit Nothing (Just rawRespWithTools)
  assertEq "Tier 3 response header source" "response_header" (staSource auditHdr)
  assertEq "Tier 3 response header usedVerificationTools" (Just True) (staUsedVerificationTools auditHdr)
  assertEq "Tier 3 response header usedSearchWeb" (Just True) (staUsedSearchWeb auditHdr)
  let (_, parsedComm, _, _, _) = parseCombinedResponse rawRespWithTools
  assertEq "parseCombinedResponse strips <!-- TOOLS: ... --> cleanly" "Checked the harbor chart and verified!" parsedComm
  assertBool "stripToolReceiptComments removes comment line" (not ("TOOLS:" `T.isInfixOf` stripToolReceiptComments rawRespWithTools))

testRec3CallbackAndFactCheckAudits :: IO ()
testRec3CallbackAndFactCheckAudits = withTempDir "rec3-callbacks" $ \tmp -> do
  putStrLn "== Rec #3: Rotation chunk_(N-1).md, Callback Read Audits & Canon Welcoming =="
  let priorRecs =
        [ StoryChunkRecord i i ("Chap " <> T.pack (show i)) 1 1 ["Harbor"] "Summary."
        | i <- [1 .. 6]
        ]
      stRot = (baseDummyState 12) {stCurrentIndex = 7, stStoryRecords = priorRecs}
      chk7 = dummyChunk 7 7 1 1
  assertBool "Chunk 7 triggers computeShouldRotate" (computeShouldRotate priorRecs chk7)
  promptPath <- writeCurrentPromptFile tmp stRot chk7
  promptTxt <- TIO.readFile promptPath
  let promptNorm = normWs promptTxt
  assertBool
    "Rotated reader prompt highlights mandatory chunks/chunk_0006.md read"
    ("chunks/chunk_0006.md" `T.isInfixOf` promptNorm && "BEFORE" `T.isInfixOf` promptNorm)
  assertBool
    "Reader prompt highlights Bullet 1 updates and welcomes external canon"
    ("Core Premise, Timeline & Baseline Facts (Persistent)" `T.isInfixOf` promptNorm && "Connecting external canon" `T.isInfixOf` promptNorm)
  assertBool
    "Reader prompt has zero quarantine-leak ban phrasing"
    (not ("quarantine leak" `T.isInfixOf` T.toLower promptNorm))

  fcPromptPath <- writeCurrentFactCheckPromptFile tmp stRot "Story sum" "Entry sum"
  fcPromptTxt <- TIO.readFile fcPromptPath
  let fcNorm = normWs fcPromptTxt
  assertBool
    "Fact-check prompt forbids memory.md as proof & welcomes canon connections"
    ("Never treat `memory.md` as proof" `T.isInfixOf` fcNorm && "Connecting external canon" `T.isInfixOf` fcNorm)
  assertBool
    "Fact-check prompt has zero quarantine-leak policing"
    (not ("quarantine leak" `T.isInfixOf` T.toLower fcNorm))

  let auditSkippedPrev =
        SubagentToolAudit
          { staSource = "parent_log"
          , staUsedSearchWeb = Just False
          , staUsedVerificationTools = Just True
          , staReadFiles = ["current_chunk.md", "memory.md"]
          , staPriorTranscriptReadFiles = []
          , staIsFirstTurnInTranscript = Just True
          }
      (mPrev1, cbCnt1, warns1) = auditReaderToolUsage 7 True "Great chapter!" auditSkippedPrev
  assertEq "Rotated reader skipping chunk_0006.md -> Just False" (Just False) mPrev1
  assertEq "Callback reads count is 0" 0 cbCnt1
  assertEq "Emits 1 rotation continuity audit warning" 1 (length warns1)

  let auditReadPrev =
        auditSkippedPrev
          { staReadFiles = ["current_chunk.md", "memory.md", "chunks/chunk_0006.md", "entries/chunk_0005.md"]
          }
      (mPrev2, cbCnt2, warns2) = auditReaderToolUsage 7 True "Great chapter!" auditReadPrev
  assertEq "Rotated reader reading chunks/chunk_0006.md -> Just True" (Just True) mPrev2
  assertEq "entries/chunk_0005.md is not miscounted as story chunk read" 1 cbCnt2
  assertEq "Zero warnings when chunk_0006.md was read" 0 (length warns2)

  writeCurrentChunkFile (tmp </> "current_chunk.md") chk7 12 12
  let fcAuditNoPrior =
        SubagentToolAudit
          { staSource = "response_header"
          , staUsedSearchWeb = Just False
          , staUsedVerificationTools = Just True
          , staReadFiles = ["current_chunk.md", "entries/chunk_0007.md", "memory.md"]
          , staPriorTranscriptReadFiles = []
          , staIsFirstTurnInTranscript = Nothing
          }
      verifiedLinesBad =
        [ "- [OK | Source: chunks/chunk_0002.md] Verified earlier dock manifest."
        , "- [OK | Source: current_chunk.md] Confirmed callback from chunks/chunk_0003.md."
        , "- [OK | Source: current_chunk.md | Quote: \"This sentence is nowhere on the pier\"] Fabricated quote."
        ]
  (_, fcWarnsBad) <- auditFactCheckerClaims tmp 7 fcAuditNoPrior verifiedLinesBad []
  assertEq "Catches unread chunk_0002, misattributed chunk_0003, and bad quote" 3 (length fcWarnsBad)

  let fcAuditWithPrior =
        fcAuditNoPrior {staReadFiles = ["current_chunk.md", "entries/chunk_0007.md", "memory.md", "chunks/chunk_0002.md"]}
      verifiedLinesGood =
        [ "- [OK | Source: chunks/chunk_0002.md] Verified earlier dock manifest."
        , "- [OK | Source: current_chunk.md | Quote: \"Detective Lin stepped onto the foggy pier\"] Verified current scene."
        ]
  (_, fcWarnsGood) <- auditFactCheckerClaims tmp 7 fcAuditWithPrior verifiedLinesGood []
  assertEq "Zero fact-check audit warnings when prior chunk read and quote matches" 0 (length fcWarnsGood)

  (_, rejCnt) <-
    verifyAndFilterCriticFactBullets
      tmp
      False
      ["- **[External Canon | Source: search_web(\"harbor lore\") | Work: Harbor Tales]** Uninvoked search."]
  assertEq "Rejects External Canon dispute when search_web was not invoked" 1 rejCnt

testRec10HiddenScriptAndResearchVerification :: IO ()
testRec10HiddenScriptAndResearchVerification = withTempDir "rec10-research" $ \tmp -> do
  putStrLn "== Rec #10: Hidden-Script Prompts, Research Receipt Filtering & Quarantine Guardrails =="
  let st1 = (baseDummyState 6) {stCurrentIndex = 1}
      chk1 = dummyChunk 1 1 1 1
  sp1Path <- writeCurrentScriptPromptFile tmp st1 chk1
  sp1Txt <- TIO.readFile sp1Path
  assertBool
    "Chunk 1 script prompt omits prior chunk_0000.md and by_chronology.md"
    (not ("chunk_0000.md" `T.isInfixOf` sp1Txt) && not ("by_chronology.md" `T.isInfixOf` sp1Txt))

  let st3 = (baseDummyState 6) {stCurrentIndex = 3}
      chk3 = dummyChunk 3 2 1 2
  sp3Path <- writeCurrentScriptPromptFile tmp st3 chk3
  sp3Txt <- TIO.readFile sp3Path
  assertBool
    "Chunk 3 script prompt includes chunks/chunk_0002.md, chunks/by_chronology.md, and entries/by_chronology.md"
    ( "chunk_0002.md" `T.isInfixOf` sp3Txt
        && "chunks/by_chronology.md" `T.isInfixOf` sp3Txt
        && "entries/by_chronology.md" `T.isInfixOf` sp3Txt
    )

  wspPath <- writeWrapupScriptPromptFile tmp ((baseDummyState 6) {stCurrentIndex = 6, stCurrentRecorded = True, stCurrentJudged = True})
  wspTxt <- TIO.readFile wspPath
  assertBool
    "Wrapup script prompt includes hall_of_fame.md and both by_chronology.md indexes"
    ( "hall_of_fame.md" `T.isInfixOf` wspTxt
        && "chunks/by_chronology.md" `T.isInfixOf` wspTxt
        && "entries/by_chronology.md" `T.isInfixOf` wspTxt
    )

  rpPath <- writeCurrentResearchPromptFile tmp st3 False "=== DRAFT COMMENTARY ===\nWait, didn't Mara drop the brass key at Pier 2?"
  rpTxt <- TIO.readFile rpPath
  assertBool
    "Research prompt embeds stripped draft and enforces quarantine silence"
    ("Mara drop the brass key" `T.isInfixOf` rpTxt && "completely blind to this draft" `T.isInfixOf` normWs rpTxt)
  assertBool
    "Research prompt states explicit story text takes precedence over external sources and canon"
    ("takes precedence over external sources and canon" `T.isInfixOf` normWs rpTxt)

  createDirectoryIfMissing True (tmp </> "chunks")
  createDirectoryIfMissing True (tmp </> "entries")
  createDirectoryIfMissing True (tmp </> "predictions")
  createDirectoryIfMissing True (tmp </> "archive" </> "memory")
  TIO.writeFile (tmp </> "chunks" </> "chunk_0001.md") "Inspector Lin found the silver whistle beside Pier 2."
  TIO.writeFile (tmp </> "chunks" </> "chunk_0004.md") "Future spoiler chunk that must never be accepted on Chunk 3."
  TIO.writeFile (tmp </> "entries" </> "chunk_0002.md") "I joked that the harbor seagulls are running the smuggling ring."
  TIO.writeFile (tmp </> "entries" </> "chunk_0003.md") "Same-chunk entry not yet valid before Chunk 3 is recorded."
  TIO.writeFile (tmp </> "predictions" </> "pred_0001.md") "**Clue/Anomaly**: Silver whistle on Pier 2 -> **Theory**: The bosun signaled the cutter."
  TIO.writeFile (tmp </> "predictions" </> "hall_of_fame.md") "Confirmed Hit: Chunk 0001 bosun whistle bet."
  TIO.writeFile (tmp </> "archive" </> "memory" </> "curated_0002.md") "Early theory noted: harbor clerk might be covering for the cutter."

  assertEq
    "parseResearchNotesSection returns empty list on - NONE"
    []
    (parseResearchNotesSection "<!-- TOOLS: read_file(current_chunk.md, memory.md) -->\n=== RESEARCH NOTES ===\n- NONE\n")

  let rawResearchMix =
        T.unlines
          [ "=== RESEARCH NOTES ==="
          , "- **[Earlier Story Passage | Source: chunks/chunk_0001.md | Quote: \"Inspector Lin found the silver whistle beside Pier 2.\"]** Chapter 1 established a silver whistle on Pier 2, not a brass key."
          , "- **[Prior Session Entry | Source: entries/chunk_0002.md | Quote: \"harbor seagulls are running the smuggling ring\"]** Running gag from Chunk 0002."
          , "- **[Prior Session Entry | Source: archive/memory/curated_0002.md | Quote: \"harbor clerk might be covering for the cutter\"]** Earlier reader notebook belief after Chunk 0002."
          , "- **[Prior Prediction | Source: predictions/pred_0001.md | Quote: \"Silver whistle on Pier 2\"]** Active Chunk 0001 bet."
          , "- **[External Canon / Reference | Source: search_web(\"maritime bosun whistle signal\") | Work: Naval Tradition]** Bosun pipes signal deck crews."
          , "- **[Earlier Story Passage | Source: chunks/chunk_0001.md | Quote: \"Fabricated quote nowhere in chunk 1\"]** Should be dropped."
          , "- **[Earlier Story Passage | Source: chunks/chunk_0004.md | Quote: \"Future spoiler chunk\"]** Out-of-bounds chunk > curIdx."
          , "- **[Prior Session Entry | Source: entries/chunk_0003.md | Quote: \"Same-chunk entry\"]** Out-of-bounds entry == curIdx on non-wrapup."
          , "- **[Earlier Story Passage | Source: chunks/chunk_0001.md | Quote: \"Inspector Lin found the silver whistle\"]** As script-writer noted in the draft commentary, this was Pier 2."
          ]
      parsedMix = parseResearchNotesSection rawResearchMix
      auditWithSearch =
        SubagentToolAudit
          { staSource = "response_header"
          , staUsedSearchWeb = Just True
          , staUsedVerificationTools = Just True
          , staReadFiles =
              [ "current_chunk.md"
              , "memory.md"
              , "chunks/chunk_0001.md"
              , "chunks/chunk_0004.md"
              , "entries/chunk_0002.md"
              , "entries/chunk_0003.md"
              , "archive/memory/curated_0002.md"
              , "predictions/pred_0001.md"
              , "predictions/hall_of_fame.md"
              ]
          , staPriorTranscriptReadFiles = []
          , staIsFirstTurnInTranscript = Nothing
          }
  (verifiedMix, rejMix) <- verifyAndFilterResearchBullets tmp 3 False auditWithSearch parsedMix
  assertEq "Keeps all 5 valid receipt-backed research bullets (chunk, entry, memory snapshot, pred, search_web)" 5 (length verifiedMix)
  assertEq "Rejects fabricated quote, future chunk, current-chunk entry, and quarantine meta-leak" 4 rejMix

  (verifiedWrapHof, rejWrapHof) <-
    verifyAndFilterResearchBullets
      tmp
      3
      True
      auditWithSearch
      ["- **[Prior Prediction | Source: predictions/hall_of_fame.md | Quote: \"Confirmed Hit: Chunk 0001 bosun whistle bet.\"]** Scoreboard entry on Wrapup."]
  assertEq "Allows predictions/hall_of_fame.md citation on Wrapup round" (1, 0) (length verifiedWrapHof, rejWrapHof)

  let auditNoSearchNoRead =
        auditWithSearch
          { staUsedSearchWeb = Just False
          , staReadFiles = ["current_chunk.md", "memory.md"]
          }
  (verifiedNone, rejAll) <- verifyAndFilterResearchBullets tmp 3 False auditNoSearchNoRead (take 5 parsedMix)
  assertEq "Drops unread file citations and uninvoked search_web bullets" 0 (length verifiedNone)
  assertEq "All 5 un-receipted bullets counted as rejected" 5 rejAll

  let renderedPacket = renderCurrentResearchMarkdown tmp 3 False verifiedMix
      extractedRefs = extractVerifiedResearchChunkRefs renderedPacket
  assertEq "extractVerifiedResearchChunkRefs extracts [1] from rendered current_research.md" [1] extractedRefs
  assertBool
    "Rendered current_research.md explains the 3-level Story-Factual Hierarchy clearly"
    ( "## Story-Factual Hierarchy" `T.isInfixOf` renderedPacket
        && "### 1. Explicit Story Text" `T.isInfixOf` renderedPacket
        && "### 2. External Canon and Reference Material" `T.isInfixOf` renderedPacket
        && "### 3. Prior Predictions, Session Entries, and Memory Snapshots" `T.isInfixOf` renderedPacket
    )

  let readerAuditUsingPacket =
        SubagentToolAudit
          { staSource = "response_header"
          , staUsedSearchWeb = Just False
          , staUsedVerificationTools = Just True
          , staReadFiles = ["current_chunk.md", "memory.md", "current_research.md", "chunks/chunk_0006.md"]
          , staPriorTranscriptReadFiles = []
          , staIsFirstTurnInTranscript = Just True
          }
      (mPrevRot, _, warnsCredited) =
        auditReaderToolUsageWithResearch
          7
          True
          [1]
          "Calling back to the whistle in `chunks/chunk_0001.md`!"
          readerAuditUsingPacket
  assertEq "Rotated reader reading chunk_0006.md + current_research.md satisfies rotation check" (Just True) mPrevRot
  assertEq "Citation of chunks/chunk_0001.md covered by current_research.md emits 0 warnings" 0 (length warnsCredited)
