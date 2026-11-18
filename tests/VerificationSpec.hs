{-# LANGUAGE OverloadedStrings #-}

module VerificationSpec
  ( testRec2SandboxToolTelemetry
  , testRec3CallbackAndFactCheckAudits
  ) where

import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (computeShouldRotate)
import LetsRead.Memory (parseCombinedResponse)
import LetsRead.Prompts
  ( writeCurrentChunkFile
  , writeCurrentFactCheckPromptFile
  , writeCurrentPromptFile
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
  , checkSubagentLogUsedSearchWeb
  , checkSubagentLogUsedVerificationTools
  , extractSubagentLogResponse
  , parseToolReceiptTag
  , resolveSubagentToolAudit
  , verifyAndFilterCriticFactBullets
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
  promptPath <- writeCurrentPromptFile tmp stRot chk7 3
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

  writeCurrentChunkFile (tmp </> "current_chunk.md") chk7 12 12 3
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
