{-# LANGUAGE OverloadedStrings #-}

module LetsRead.Predictions
  ( placeholderSubstrings
  , isPlaceholderLine
  , cleanTopicTag
  , extractFallbackTopics
  , parseTopicsFromBracket
  , coalesceBulletLines
  , canonicalizeActiveLine
  , canonicalizeResolvedLine
  , renderRecordActiveLine
  , renderRecordResolvedLine
  , renderOriginalPredictionSummary
  , checkPredictionConcisenessIssues
  , startsWithScreeningFlag
  , parsePredictionLine
  , auditAndApplyPredictionUpdates
  , extractJudgeSection
  , extractJudgeRetirementsSection
  , applyJudgeVerdicts
  , applyJudgeVerdictsWithFeedback
  , countActivePredictions
  , predStatusBadge
  , predShortStatusTag
  , renderSinglePredictionDoc
  , renderPredSummaryBullet
  , renderPredCrossArcResolutionBullet
  , renderHallOfFameMarkdown
  , formatPredictionTrackerCallout
  , formatJudgeCallout
  , isPredictionMentionedInComm
  , stripExistingJudgeCallout
  , stripTrackerProposalCallout
  , formatAuditEntryCallout
  ) where

import Data.Char (isAlphaNum, isDigit, isSpace, isUpper)
import Data.List (sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import LetsRead.Types
  ( ParsedPrediction (..)
  , PredictionRecord (..)
  , PredictionStatus (..)
  , ResolutionKind (..)
  , ResolutionMeta (..)
  , SessionState (..)
  , formatChapLabel
  , isPredActive
  , jsonInt
  , padChunkNumber
  , predActiveScreeningNote
  , predResolutionMeta
  , stripAfterClosingBracket
  , stripToolReceiptComments
  , wrapMarkdownBullet
  , wrapMarkdownParagraph
  )
import System.FilePath ((</>))

placeholderSubstrings :: [Text]
placeholderSubstrings =
  [ "*(none"
  , "*(no chunks"
  , "*(no major"
  , "*(no hits"
  , "*(no active"
  , "*(no predictions"
  , "*(no resolved"
  , "*(no notable"
  , "*(no new"
  , "*(no status"
  , "story complete"
  , "no new prediction"
  , "no prediction"
  , "no status transition"
  , "no updates"
  , "- <1-line"
  , "- <compact"
  , "- <questions"
  , "- <what is"
  , "- <recurring"
  ]

isPlaceholderLine :: Text -> Bool
isPlaceholderLine line =
  let s = T.toLower (T.strip line)
      strippedBullet =
        T.strip
          ( if "- " `T.isPrefixOf` s || "* " `T.isPrefixOf` s
              then T.drop 2 s
              else s
          )
      cleanedWord = T.dropAround (\c -> not (isAlphaNum c)) strippedBullet
   in T.null s
        || cleanedWord == "none"
        || cleanedWord == "na"
        || "none (" `T.isPrefixOf` strippedBullet
        || "none —" `T.isPrefixOf` strippedBullet
        || "none -" `T.isPrefixOf` strippedBullet
        || any (`T.isInfixOf` s) placeholderSubstrings

stopTopicWords :: [Text]
stopTopicWords =
  [ "the", "and", "for", "that", "this", "with", "from", "into", "over", "under"
  , "after", "before", "when", "where", "while", "what", "which", "who", "whom"
  , "whose", "why", "how", "will", "would", "could", "should", "might", "must"
  , "have", "has", "had", "been", "being", "their", "there", "they", "them"
  , "then", "than", "only", "also", "just", "even", "still", "more", "most"
  , "some", "such", "very", "much", "many", "each", "every", "both", "either"
  , "neither", "other", "another", "same", "different", "next", "last", "first"
  , "second", "third", "chapter", "chunk", "part", "story", "scene", "clue"
  , "anomaly", "theory", "predicted", "confirmed"
  , "debunked", "subverted", "retired", "because", "instead", "actually"
  , "really", "simply", "merely", "purely", "routine", "normal", "ordinary"
  , "standard", "mundane", "coincidence", "genuine", "genuinely", "secretly"
  , "already", "later", "earlier", "during", "through", "between", "among"
  , "against", "without", "within", "about", "around", "across", "behind"
  , "beyond", "towards", "toward", "upon", "onto", "until", "unless", "since"
  , "though", "although", "whether", "either", "however", "therefore", "never"
  , "always", "often", "sometimes", "soon", "once", "twice", "three", "four"
  ]

cleanTopicTag :: Text -> Text
cleanTopicTag raw =
  let stripped = T.strip (T.dropAround (\c -> c == '*' || c == '`' || c == '"' || c == '\'' || c == '.' || c == ',' || c == ';' || c == ':') (T.strip raw))
   in T.unwords (T.words stripped)

extractFallbackTopics :: Text -> [Text]
extractFallbackTopics body =
  let cleaned =
        T.replace "**Clue/Anomaly**" " "
          $ T.replace "**Theory**" " "
          $ T.replace "**Clue**" " "
          $ T.replace "**Anomaly**" " " body
      tokens = T.words (T.map (\c -> if isAlphaNum c || c == '-' || c == '\'' then c else ' ') cleaned)
      normTok tok =
        let t0 = T.dropAround (\c -> c == '-' || c == '\'') tok
         in if "'s" `T.isSuffixOf` T.toLower t0
              then T.dropEnd 2 t0
              else t0
      isCandidate t =
        let low = T.toLower t
         in case T.uncons t of
              Just (firstC, rest) ->
                isUpper firstC
                  && T.length t >= 3
                  && not (T.all isUpper t && T.length t > 5)
                  && low `notElem` stopTopicWords
                  && T.any isLowerChar rest
              Nothing -> False
      isLowerChar c = c >= 'a' && c <= 'z'
      dedupCI [] = []
      dedupCI (x : xs) = x : dedupCI [y | y <- xs, T.toLower y /= T.toLower x]
      extracted = take 4 (dedupCI [t | tok <- tokens, let t = normTok tok, isCandidate t])
   in if null extracted then ["General Plot"] else extracted

parseTopicsFromBracket :: Text -> Text -> [Text]
parseTopicsFromBracket insideRaw bodyAfter =
  let (_, afterPipe) = T.breakOn "|" insideRaw
   in if T.null afterPipe
        then extractFallbackTopics bodyAfter
        else
          let pipeBody = T.strip (T.drop 1 afterPipe)
              afterColon =
                if "topic" `T.isPrefixOf` T.toLower pipeBody
                  then T.strip (T.drop 1 (snd (T.breakOn ":" pipeBody)))
                  else pipeBody
              rawTags = map cleanTopicTag (T.split (\c -> c == ',' || c == ';') afterColon)
              validTags = filter (\t -> not (T.null t) && T.length t <= 50) rawTags
           in if null validTags
                then extractFallbackTopics bodyAfter
                else take 6 validTags

splitPredictionComponents :: Text -> (Text, Text)
splitPredictionComponents body =
  let stripBoldLabel lbl txt =
        let s = T.strip txt
            low = T.toLower s
            p1 = "**" <> lbl <> "**:"
            p2 = "**" <> lbl <> "** :"
            p3 = lbl <> ":"
         in if p1 `T.isPrefixOf` low
              then T.strip (T.drop (T.length p1) s)
              else if p2 `T.isPrefixOf` low
                then T.strip (T.drop (T.length p2) s)
                else if p3 `T.isPrefixOf` low
                  then T.strip (T.drop (T.length p3) s)
                  else s
      (cluePart, afterArrow) =
        case T.breakOn "-> **Theory**" body of
          (b, a) | not (T.null a) -> (b, T.drop 2 a)
          _ ->
            case T.breakOn "→ **Theory**" body of
              (b, a) | not (T.null a) -> (b, T.drop 1 a)
              _ ->
                case T.breakOn "->" body of
                  (b, a) | not (T.null a) -> (b, T.drop 2 a)
                  _ -> ("", body)
      clueClean =
        stripBoldLabel "clue/anomaly"
          $ stripBoldLabel "clue"
          $ stripBoldLabel "anomaly" cluePart
      theoryClean = stripBoldLabel "theory" afterArrow
   in (T.strip clueClean, T.strip theoryClean)

canonicalizeActiveLine :: Int -> [Text] -> Text -> Text
canonicalizeActiveLine c1 topics body =
  let topicSuffix =
        if null topics
          then ""
          else " | Topics: " <> T.intercalate ", " topics
   in "- **[Predicted Chunk " <> T.pack (padChunkNumber c1) <> topicSuffix <> "]** " <> T.strip body

canonicalizeResolvedLine :: Int -> Int -> ResolutionKind -> Text -> Text
canonicalizeResolvedLine c1 c2 rKind body =
  let c1Str = T.pack (padChunkNumber c1)
      c2Str = T.pack (padChunkNumber c2)
      tag =
        case rKind of
          ResConfirmed
            | c2 <= c1 ->
                "Predicted Chunk " <> c1Str <> " -> CONFIRMED Chunk " <> c2Str <> " (Same-Chunk — No Foresight Credit)"
            | otherwise ->
                "Predicted Chunk " <> c1Str <> " -> CONFIRMED Chunk " <> c2Str
          ResDebunked ->
            "Predicted Chunk " <> c1Str <> " -> DEBUNKED Chunk " <> c2Str
          ResSubverted ->
            "Predicted Chunk " <> c1Str <> " -> SUBVERTED Chunk " <> c2Str
          ResRetired ->
            "Predicted Chunk " <> c1Str <> " -> RETIRED Chunk " <> c2Str
   in "- **[" <> tag <> "]** " <> T.strip body

coalesceBulletLines :: [Text] -> [Text]
coalesceBulletLines = go Nothing
  where
    isNewBullet t = "- " `T.isPrefixOf` t || "* " `T.isPrefixOf` t
    isBoundary t =
      T.null t
        || "#" `T.isPrefixOf` t
        || "===" `T.isPrefixOf` t
        || "```" `T.isPrefixOf` t
        || ">" `T.isPrefixOf` t
    flush Nothing = []
    flush (Just acc) = [acc]
    go mAcc [] = flush mAcc
    go mAcc (rawL : ls) =
      let t = T.strip rawL
       in if isNewBullet t
            then flush mAcc ++ go (Just t) ls
            else if isBoundary t
              then flush mAcc ++ (rawL : go Nothing ls)
              else case mAcc of
                Just acc -> go (Just (acc <> " " <> t)) ls
                Nothing -> rawL : go Nothing ls

stripFileLinkSuffix :: Text -> Text
stripFileLinkSuffix txt =
  let s = T.strip txt
      (beforeLink, afterLink) = T.breakOn "([details](" s
   in if not (T.null afterLink)
        then T.strip beforeLink
        else s

parsePredictionLine :: Text -> ParsedPrediction
parsePredictionLine rawLine =
  let l = stripFileLinkSuffix (T.strip rawLine)
      (_, afterOpen) = T.breakOn "[" l
      (insideRaw, afterClose) = T.breakOn "]" (T.drop 1 afterOpen)
   in if T.null afterOpen || T.null afterClose
        then PredInvalidNotation l l
        else
          let (insideBeforePipe, _) = T.breakOn "|" insideRaw
              (insideBeforeParen, _) = T.breakOn "(" insideBeforePipe
              inside = T.toLower (T.strip insideBeforeParen)
              rawAfterBracket = stripAfterClosingBracket afterClose
              rawAfterLow = T.toLower rawAfterBracket
              hasStatusParenPrefix =
                "(short-horizon <3 chunks" `T.isPrefixOf` rawAfterLow
                  || "(same-chunk" `T.isPrefixOf` rawAfterLow
              afterBracket =
                if hasStatusParenPrefix
                  then T.strip (T.drop 1 (snd (T.breakOn ")" rawAfterBracket)))
                  else rawAfterBracket
              nums :: [Int]
              nums =
                [ n
                | tok <- T.split (not . isDigit) inside
                , not (T.null tok)
                , [(n, "")] <- [reads (T.unpack tok)]
                ]
              isSubverted = "subvert" `T.isInfixOf` inside
              isDebunked =
                not isSubverted
                  && any
                    (`T.isInfixOf` inside)
                    [ "debunk"
                    , "busted"
                    , "bust"
                    , "miss"
                    , "wrong"
                    , "fals"
                    , "disprov"
                    , "overturn"
                    ]
              isRetired =
                not isSubverted
                  && not isDebunked
                  && any
                    (`T.isInfixOf` inside)
                    [ "retir"
                    , "cull"
                    , "prune"
                    , "moot"
                    , "stale"
                    , "supersed"
                    ]
              isConfirmed =
                not isSubverted
                  && not isDebunked
                  && not isRetired
                  && any
                    (`T.isInfixOf` inside)
                    [ "confirm"
                    , "hit"
                    , "correct"
                    ]
           in if isSubverted || isDebunked || isRetired || isConfirmed
                then
                  let rKind
                        | isSubverted = ResSubverted
                        | isDebunked = ResDebunked
                        | isRetired = ResRetired
                        | otherwise = ResConfirmed
                   in case nums of
                        (c1 : c2 : _)
                          | c1 > 0 && c2 >= c1 ->
                              PredValidResolved c1 c2 rKind (canonicalizeResolvedLine c1 c2 rKind afterBracket) afterBracket
                        _ ->
                          PredInvalidNotation l afterBracket
                else
                  let hasArrow = "->" `T.isInfixOf` inside || "→" `T.isInfixOf` inside
                      bodyFlagged = startsWithScreeningFlag afterBracket
                      isRejected =
                        bodyFlagged
                          || ( hasArrow
                                 && any
                                   (`T.isInfixOf` inside)
                                   [ "not added"
                                   , "not-added"
                                   , "not admitted"
                                   , "not-admitted"
                                   , "unadmitted"
                                   , "not active"
                                   , "not-active"
                                   , "inactive"
                                   , "not accepted"
                                   , "unaccepted"
                                   , "reject"
                                   , "screened"
                                   , "skip"
                                   , "drop"
                                   , "disqualif"
                                   , "feedback"
                                   , "exclud"
                                   , "declin"
                                   , "deni"
                                   , "filter"
                                   ]
                             )
                      isKeepActive =
                        hasArrow
                          && not isRejected
                          && ( "active" `T.isInfixOf` inside
                                 || "unresolv" `T.isInfixOf` inside
                                 || "pending" `T.isInfixOf` inside
                                 || "accept" `T.isInfixOf` inside
                                 || "added" `T.isInfixOf` inside
                             )
                      isActiveTag =
                        ("predicted" `T.isInfixOf` inside || "active" `T.isInfixOf` inside)
                          && not hasArrow
                   in if isRejected
                        then case nums of
                          (c1 : _) | c1 > 0 -> PredValidRejected c1 l afterBracket
                          _ -> PredInvalidNotation l afterBracket
                        else if isKeepActive
                          then case nums of
                            (c1 : _) | c1 > 0 -> PredValidKeepActive c1 l afterBracket
                            _ -> PredInvalidNotation l afterBracket
                          else case nums of
                            [c1]
                              | isActiveTag && c1 > 0 && not (T.null (T.strip afterBracket)) ->
                                  let topics = parseTopicsFromBracket insideRaw afterBracket
                                      (clue, theory) = splitPredictionComponents afterBracket
                                      canonL = canonicalizeActiveLine c1 topics afterBracket
                                   in PredValidActive c1 topics clue theory canonL afterBracket
                            _ ->
                              PredInvalidNotation l afterBracket

renderRecordActiveLine :: PredictionRecord -> Text
renderRecordActiveLine pr =
  canonicalizeActiveLine (prOriginChunk pr) (prTopics pr) (prRawBody pr)

renderRecordResolvedLine :: PredictionRecord -> Text
renderRecordResolvedLine pr =
  let origC = prOriginChunk pr
      noteOrRaw rm = if T.null (T.strip (rmNote rm)) then prRawBody pr else rmNote rm
   in case prStatus pr of
        PredStatusActive _ -> renderRecordActiveLine pr
        PredStatusConfirmed rm _ -> canonicalizeResolvedLine origC (rmChunk rm) ResConfirmed (noteOrRaw rm)
        PredStatusDebunked rm -> canonicalizeResolvedLine origC (rmChunk rm) ResDebunked (noteOrRaw rm)
        PredStatusSubverted rm -> canonicalizeResolvedLine origC (rmChunk rm) ResSubverted (noteOrRaw rm)
        PredStatusRetired rm -> canonicalizeResolvedLine origC (rmChunk rm) ResRetired (noteOrRaw rm)

renderOriginalPredictionSummary :: PredictionRecord -> Text
renderOriginalPredictionSummary pr
  | not (T.null (prClue pr)) && not (T.null (prTheory pr)) =
      "**Clue/Anomaly**: "
        <> prClue pr
        <> " -> **Theory**: "
        <> prTheory pr
  | otherwise = T.strip (prRawBody pr)

checkPredictionConcisenessIssues :: PredictionRecord -> [Text]
checkPredictionConcisenessIssues pr =
  let bodyLen = T.length (prRawBody pr)
      clueLen = T.length (prClue pr)
      theoryLen = T.length (prTheory pr)
      clueHasQuote = T.any (\c -> c == '"' || c == '\x201C' || c == '\x201D') (prClue pr)
   in [ "total body was " <> jsonInt bodyLen <> " chars (cap: <= 400 chars)" | bodyLen > 400 ]
        ++ [ "`**Clue/Anomaly**` was " <> jsonInt clueLen <> " chars (cap: <= 150 chars)" | clueLen > 150 ]
        ++ [ "`**Clue/Anomaly**` contained inline quotation marks (summarize the detail concisely without quoting)" | clueHasQuote ]
        ++ [ "`**Theory**` was " <> jsonInt theoryLen <> " chars (cap: <= 220 chars)" | theoryLen > 220 ]

renderConcisenessAuditBlock :: Text -> PredictionRecord -> [Text] -> Text
renderConcisenessAuditBlock nextStr pr issues =
  let cPad = T.pack (padChunkNumber (prOriginChunk pr))
   in T.intercalate
        "\n"
        [ "- **[PREDICTION CONCISENESS / SUB-CLAUSE OVERFLOW]**"
        , wrapMarkdownBullet
            78
            ( "  - Issue: Prediction `[Predicted Chunk "
                <> cPad
                <> "]` exceeded the conciseness budget ("
                <> T.intercalate "; " issues
                <> ")."
            )
        , "  - Line: " <> renderRecordActiveLine pr
        , wrapMarkdownBullet
            78
            ( "  - Action Required: On Chunk "
                <> nextStr
                <> ", keep the post-bracket prediction body `<= 400 chars` total (`**Clue/Anomaly** <= 150 chars` with no inline quotes, `**Theory** <= 220 chars`)."
            )
        ]

renderTagFormatAuditBlock :: Text -> Text -> Text -> Text
renderTagFormatAuditBlock issueTxt invalidLineTxt actionTxt =
  T.intercalate
    "\n"
    [ "- **[INVALID PREDICTION TAG OR FORMAT]**"
    , wrapMarkdownBullet 78 ("  - Issue: " <> T.strip issueTxt)
    , "  - Line: " <> T.strip invalidLineTxt
    , wrapMarkdownBullet 78 ("  - Action Required: " <> T.strip actionTxt)
    ]

isPredictionMentionedInComm :: Text -> Text -> Bool
isPredictionMentionedInComm commLower rawPredLine =
  let (_, afterOpen) = T.breakOn "[" rawPredLine
      (insideRaw, _) = T.breakOn "]" (T.drop 1 afterOpen)
      (insideBeforePipe, _) = T.breakOn "|" insideRaw
      (insideBeforeParen, _) = T.breakOn "(" insideBeforePipe
      tagNorm = T.toLower (T.strip insideBeforeParen)
   in not (T.null tagNorm) && tagNorm `T.isInfixOf` commLower

isScreeningSubBullet :: Text -> Bool
isScreeningSubBullet line =
  let s = T.toLower (T.strip line)
      strippedBullet =
        T.strip
          ( if "- " `T.isPrefixOf` s || "* " `T.isPrefixOf` s
              then T.drop 2 s
              else s
          )
      cleanLine = T.strip (T.filter (\c -> c /= '*' && c /= '`' && c /= '_') strippedBullet)
      (beforeColon, afterColon) = T.breakOn ":" strippedBullet
      cleanLabel = T.strip (T.filter (\c -> c /= '*' && c /= '`' && c /= '_') beforeColon)
   in (not (T.null afterColon) && (cleanLabel == "judge screening" || cleanLabel == "prior screening"))
        || "original prediction —" `T.isPrefixOf` cleanLine
        || "original prediction --" `T.isPrefixOf` cleanLine
        || "previous prediction —" `T.isPrefixOf` cleanLine
        || "previous prediction --" `T.isPrefixOf` cleanLine

startsWithScreeningFlag :: Text -> Bool
startsWithScreeningFlag raw =
  let cleaned = T.toLower (T.stripStart (T.dropWhile (\c -> isSpace c || c == '*' || c == '`') raw))
      flags =
        [ "[uninteresting]"
        , "[ungrounded]"
        , "[duplicate-thesis]"
        , "[hedged]"
        , "[vague]"
        ]
   in any (`T.isPrefixOf` cleaned) flags

stripLeadingScreeningFlags :: Text -> Text
stripLeadingScreeningFlags raw =
  let s = T.stripStart (T.dropWhile (\c -> isSpace c || c == '*' || c == '`') raw)
   in if startsWithScreeningFlag s
        then
          let (_, rest) = T.breakOn "]" s
           in if T.null rest
                then T.strip raw
                else stripLeadingScreeningFlags (T.drop 1 rest)
        else T.strip raw

auditAndApplyPredictionUpdates
  :: Int
  -> Int
  -> Int
  -> Text
  -> Int
  -> Int
  -> Bool
  -> Text
  -> [PredictionRecord]
  -> Maybe Text
  -> ([PredictionRecord], [(Int, Text)], [Text], [Text])
auditAndApplyPredictionUpdates curIdx totalChunks chapNum chapTitle partNum partsTotal isRecordTurn commText prevRecords mPredUpdatesTxt =
  let curStr = T.pack (padChunkNumber (max 1 curIdx))
      nextStr = T.pack (padChunkNumber (max 1 curIdx + 1))

      allBullets =
        case mPredUpdatesTxt of
          Nothing -> []
          Just b ->
            [ parsePredictionLine trimmed
            | rawL <- coalesceBulletLines (T.lines b)
            , let trimmed = T.strip rawL
            , not (isPlaceholderLine trimmed)
            , not (isScreeningSubBullet trimmed)
            , "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
            ]

      activeBullets = [p | p@(PredValidActive {}) <- allBullets]
      resolvedBullets = [p | p@(PredValidResolved {}) <- allBullets]
      invalidBullets = [p | p@(PredInvalidNotation {}) <- allBullets]

      selfJudgedBullets =
        [ r
        | r@(PredValidResolved _ _ rKind _ _) <- resolvedBullets
        , rKind /= ResRetired
        ]
      retireBullets =
        [ r
        | r@(PredValidResolved _ _ ResRetired _ _) <- resolvedBullets
        ]

      selfJudgedAuditBlocks =
        [ renderTagFormatAuditBlock
            "Self-judging predictions (`CONFIRMED`, `DEBUNKED`, `SUBVERTED`) is handled exclusively by the `lets-read-prediction-judge` subagent; `lets-read-blind-reader` must not emit resolution verdicts in `=== PREDICTION UPDATES ===`."
            (ppRawLine r)
            ( "Remove `CONFIRMED` / `DEBUNKED` / `SUBVERTED` lines from `=== PREDICTION UPDATES ===`. Only output your 1 new prediction (`- **[Predicted Chunk "
                <> nextStr
                <> " | Topics: Topic 1, Topic 2]** ...`)."
            )
        | r <- selfJudgedBullets
        ]

      strayRetireAuditBlocks =
        [ renderTagFormatAuditBlock
            "10-prediction cap retirement (`RETIRED`) is handled automatically by `lets-read-prediction-judge`; `lets-read-blind-reader` should not emit `RETIRED` lines in `=== PREDICTION UPDATES ===`."
            (ppRawLine r)
            ( "Submit only your 1 new prediction (`- **[Predicted Chunk "
                <> nextStr
                <> " | Topics: Topic 1, Topic 2]** ...`) in `=== PREDICTION UPDATES ===`."
            )
        | r <- retireBullets
        ]

      classifyActiveBullet :: ParsedPrediction -> Either (Int, ParsedPrediction) (Maybe Text)
      classifyActiveBullet p@(PredValidActive c1 _ clue theory canonL bodyAfter)
        | any (\pr -> prOriginChunk pr == c1) prevRecords && (isRecordTurn || c1 /= curIdx) =
            Right Nothing
        | c1 /= curIdx =
            let newCStr = T.pack (padChunkNumber c1)
                trimmedBody = T.strip bodyAfter
                issueDetail =
                  "New active prediction logged on Chunk "
                    <> curStr
                    <> " was tagged with wrong chunk number `[Predicted Chunk "
                    <> newCStr
                    <> "]` instead of `[Predicted Chunk "
                    <> curStr
                    <> "]`."
             in Right
                  ( Just
                      ( renderTagFormatAuditBlock
                          issueDetail
                          canonL
                          ( "Use the current chunk number in the bracket tag: `- **[Predicted Chunk "
                              <> nextStr
                              <> " | Topics: Topic 1, Topic 2]** "
                              <> trimmedBody
                              <> "` (when submitting Chunk "
                              <> nextStr
                              <> ")."
                          )
                      )
                  )
        | T.null clue || T.null theory =
            Right
              ( Just
                  ( renderTagFormatAuditBlock
                      "New prediction is missing one or both required structured segments (`**Clue/Anomaly**` or `-> **Theory**`)."
                      canonL
                      ( "Format every new prediction as `- **[Predicted Chunk "
                          <> nextStr
                          <> " | Topics: Topic 1, Topic 2, Topic 3]** **Clue/Anomaly**: <detail> -> **Theory**: <concrete bet>`."
                      )
                  )
              )
        | otherwise = Left (c1, p)
      classifyActiveBullet _ = Right Nothing

      classifyInvalidBullet :: ParsedPrediction -> Text
      classifyInvalidBullet (PredInvalidNotation rawInv bodyAfter) =
        let trimmedBody =
              if T.null (T.strip bodyAfter)
                then "**Clue/Anomaly**: ... -> **Theory**: ..."
                else T.strip bodyAfter
         in renderTagFormatAuditBlock
              "Malformed or unsupported prediction bracket tag in `=== PREDICTION UPDATES ===`."
              rawInv
              ( "Fix or remove this line in `=== PREDICTION UPDATES ===`! To log your new prediction, use `- **[Predicted Chunk "
                  <> nextStr
                  <> " | Topics: Topic 1, Topic 2]** "
                  <> trimmedBody
                  <> "` (on Chunk "
                  <> nextStr
                  <> ")."
              )
      classifyInvalidBullet p =
        renderTagFormatAuditBlock
          "Unexpected prediction line format."
          (ppRawLine p)
          "Use standard `- **[Predicted Chunk XXXX | Topics: Topic 1, Topic 2, Topic 3]** **Clue/Anomaly**: ... -> **Theory**: ...` notation."

      activeResults = map classifyActiveBullet activeBullets
      rawValidNewPairs = [(c, p) | Left (c, p) <- activeResults]
      activeAuditBlocks = [b | Right (Just b) <- activeResults]
      invalidAuditBlocks = map classifyInvalidBullet invalidBullets

      dedupNewByChunk _ [] = ([], [])
      dedupNewByChunk seen ((c, p) : rest)
        | c `elem` seen =
            let cStr = T.pack (padChunkNumber c)
                dupBlk =
                  renderTagFormatAuditBlock
                    ("Multiple new predictions were tagged `[Predicted Chunk " <> cStr <> "]` on the same chunk (only 1 new prediction per chunk is allowed so each chunk tag remains unique).")
                    (ppRawLine p)
                    ("Keep only your single strongest prediction for Chunk " <> cStr <> " and remove the duplicate `- **[Predicted Chunk " <> cStr <> "]**` line(s).")
                (keptP, dupBlks) = dedupNewByChunk seen rest
             in (keptP, dupBlk : dupBlks)
        | otherwise =
            let (keptP, dupBlks) = dedupNewByChunk (c : seen) rest
             in (p : keptP, dupBlks)

      (validNewActiveParsed, duplicateChunkAuditBlocks) = dedupNewByChunk [] rawValidNewPairs

      toPredictionRecord :: ParsedPrediction -> PredictionRecord
      toPredictionRecord (PredValidActive c1 topics clue theory _ bodyAfter) =
        PredictionRecord
          { prOriginChunk = c1
          , prChapterNumber = chapNum
          , prChapterTitle = chapTitle
          , prPartInChapter = partNum
          , prPartsInChapter = partsTotal
          , prTopics = topics
          , prClue = clue
          , prTheory = theory
          , prRawBody = bodyAfter
          , prStatus = PredStatusActive Nothing
          }
      toPredictionRecord _ =
        error "toPredictionRecord: expected PredValidActive"

      newOrAmendedRecords = map toPredictionRecord validNewActiveParsed
      replacedOrigins = map prOriginChunk newOrAmendedRecords

      concisenessAuditBlocks =
        [ renderConcisenessAuditBlock nextStr pr issues
        | pr <- newOrAmendedRecords
        , let issues = checkPredictionConcisenessIssues pr
        , not (null issues)
        ]

      candidateRecords =
        sortOn
          prOriginChunk
          ([pr | pr <- prevRecords, prOriginChunk pr `notElem` replacedOrigins] ++ newOrAmendedRecords)

      hasNewForCur =
        any (\pr -> prOriginChunk pr == curIdx) candidateRecords
          || not (null activeAuditBlocks)
          || not (null invalidAuditBlocks)
          || not (null duplicateChunkAuditBlocks)
      missingNewPredAuditBlocks
        | isRecordTurn && curIdx >= 1 && curIdx < totalChunks && not hasNewForCur =
            [ renderTagFormatAuditBlock
                ("No new prediction was logged for Chunk " <> curStr <> " (every chunk before the final chunk must log 1 new specific, non-obvious prediction).")
                ("*(Missing `- **[Predicted Chunk " <> curStr <> " | Topics: Topic 1, Topic 2]** **Clue/Anomaly**: ... -> **Theory**: ...` in `=== PREDICTION UPDATES ===`)*")
                ( "On Chunk "
                    <> nextStr
                    <> ", make sure to stake 1 new specific, non-obvious prediction using `- **[Predicted Chunk "
                    <> nextStr
                    <> " | Topics: Topic 1, Topic 2]** **Clue/Anomaly**: ... -> **Theory**: ...` in `=== PREDICTION UPDATES ===`."
                )
            ]
        | otherwise = []

      allAuditBlocks =
        activeAuditBlocks
          ++ invalidAuditBlocks
          ++ duplicateChunkAuditBlocks
          ++ concisenessAuditBlocks
          ++ selfJudgedAuditBlocks
          ++ strayRetireAuditBlocks
          ++ missingNewPredAuditBlocks

      commLower = T.toLower commText
      turnEvents = map renderRecordActiveLine newOrAmendedRecords
      trackerUpdateLines =
        [ evLine
        | evLine <- turnEvents
        , not (isPredictionMentionedInComm commLower evLine)
        ]
   in (candidateRecords, [], allAuditBlocks, trackerUpdateLines)

extractJudgeSection :: Text -> Text
extractJudgeSection raw =
  let cleanRaw = stripToolReceiptComments raw
      isJudgeHeader l =
        let s = T.toUpper (T.strip l)
         in s == "=== PREDICTION JUDGMENTS ==="
              || s == "=== PREDICTION JUDGEMENTS ==="
              || s == "=== JUDGMENTS ==="
              || s == "=== JUDGEMENTS ==="
              || s == "=== PREDICTION UPDATES ==="
      ls = T.lines cleanRaw
      afterHeader = drop 1 (dropWhile (not . isJudgeHeader) ls)
      untilNextSec = takeWhile (\l -> not ("===" `T.isPrefixOf` T.strip l)) afterHeader
   in if null afterHeader
        then T.strip cleanRaw
        else T.strip (T.unlines untilNextSec)

extractJudgeRetirementsSection :: Text -> Text
extractJudgeRetirementsSection raw =
  let cleanRaw = stripToolReceiptComments raw
      isRetireHeader l =
        let s = T.toUpper (T.strip l)
         in s == "=== CONDITIONAL RETIREMENTS ==="
              || s == "=== CONDITIONAL RETIREMENT ==="
              || s == "=== RETIREMENTS ==="
      ls = T.lines cleanRaw
      afterHeader = drop 1 (dropWhile (not . isRetireHeader) ls)
      untilNextSec = takeWhile (\l -> not ("===" `T.isPrefixOf` T.strip l)) afterHeader
   in if null afterHeader
        then ""
        else T.strip (T.unlines untilNextSec)

applyJudgeVerdicts
  :: Int
  -> (Int, Text, Int, Int)
  -> [PredictionRecord]
  -> [(Int, Text)]
  -> Text
  -> ([PredictionRecord], [Text], [Text])
applyJudgeVerdicts curIdx chapMeta prevRecords pendingRetires rawJudgeTxt =
  let (finalRecords, _, warns, summaryLines) =
        applyJudgeVerdictsWithFeedback curIdx chapMeta prevRecords pendingRetires rawJudgeTxt
   in (finalRecords, warns, summaryLines)

applyJudgeVerdictsWithFeedback
  :: Int
  -> (Int, Text, Int, Int)
  -> [PredictionRecord]
  -> [(Int, Text)]
  -> Text
  -> ([PredictionRecord], [(PredictionRecord, Text)], [Text], [Text])
applyJudgeVerdictsWithFeedback curIdx (chapNum, chapTitle, partNum, partsTotal) prevRecords pendingRetires rawJudgeTxt =
  let judgeBody = extractJudgeSection rawJudgeTxt
      retireSecBody = extractJudgeRetirementsSection rawJudgeTxt
      parseBulletsFrom txt =
        [ parsePredictionLine trimmed
        | rawL <- coalesceBulletLines (T.lines txt)
        , let trimmed = T.strip rawL
        , not (isPlaceholderLine trimmed)
        , "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
        , "[" `T.isInfixOf` trimmed && "]" `T.isInfixOf` trimmed
        ]
      parsedLines = parseBulletsFrom judgeBody
      parsedRetireSecLines = parseBulletsFrom retireSecBody
      resolvedVerdicts =
        [ r
        | r@(PredValidResolved _ _ rKind _ _) <- parsedLines
        , rKind `elem` [ResConfirmed, ResDebunked, ResSubverted]
        ]
      judgeRetireVerdicts =
        [ (origC, reasonTxt)
        | PredValidResolved origC _ ResRetired _ bodyAfter <- parsedRetireSecLines ++ parsedLines
        , let reasonTxt = T.strip bodyAfter
        ]
      keepActiveVerdicts =
        [ k
        | k@(PredValidKeepActive {}) <- parsedLines
        ]
      rejectedVerdicts =
        [ r
        | r@(PredValidRejected {}) <- parsedLines
        ]

      existingResKind :: PredictionStatus -> Maybe ResolutionKind
      existingResKind stStatus =
        case stStatus of
          PredStatusActive _ -> Nothing
          PredStatusConfirmed _ _ -> Just ResConfirmed
          PredStatusDebunked _ -> Just ResDebunked
          PredStatusSubverted _ -> Just ResSubverted
          PredStatusRetired _ -> Just ResRetired

      isUnchangedPriorEcho :: PredictionRecord -> ParsedPrediction -> Bool
      isUnchangedPriorEcho targetPr r =
        case (predResolutionMeta targetPr, existingResKind (prStatus targetPr)) of
          (Just rmOld, Just oldKind) -> rmChunk rmOld < curIdx && oldKind == ppResKind r
          _ -> False

      findJudgeTarget :: ParsedPrediction -> Maybe PredictionRecord
      findJudgeTarget (PredValidResolved origC _ _ _ _) =
        listToMaybe [pr | pr <- prevRecords, prOriginChunk pr == origC]
      findJudgeTarget _ = Nothing

      dedupByOrigin _ [] = []
      dedupByOrigin seen ((origC, r) : rest)
        | origC `elem` seen = dedupByOrigin seen rest
        | otherwise = (origC, r) : dedupByOrigin (origC : seen) rest

      matchedResolutions =
        dedupByOrigin
          []
          [ (prOriginChunk targetPr, r)
          | r <- resolvedVerdicts
          , Just targetPr <- [findJudgeTarget r]
          , not (isUnchangedPriorEcho targetPr r)
          ]
      resolvedOriginSet = [origC | (origC, _) <- matchedResolutions]

      normalizeRejectionNote :: Text -> Text
      normalizeRejectionNote rawN =
        let n = T.strip rawN
         in if T.null n
              then "[UNINTERESTING] Not added to the active predictions ledger."
              else
                if startsWithScreeningFlag n
                  then n
                  else "[UNINTERESTING] " <> n

      mCurRejectionNote :: Int -> Maybe Text
      mCurRejectionNote origC
        | origC /= curIdx || origC `elem` resolvedOriginSet = Nothing
        | otherwise =
            case [normalizeRejectionNote note | PredValidRejected rOrig _ note <- rejectedVerdicts, rOrig == origC] of
              (n : _) -> Just n
              [] ->
                listToMaybe
                  [ T.strip note
                  | PredValidKeepActive kOrig _ note <- keepActiveVerdicts
                  , kOrig == origC
                  , startsWithScreeningFlag (T.strip note)
                  ]

      rejectedCurPairs =
        [ (pr {prStatus = PredStatusActive Nothing}, rejNote)
        | pr <- prevRecords
        , Just rejNote <- [mCurRejectionNote (prOriginChunk pr)]
        ]
      rejectedOrigins = [prOriginChunk pr | (pr, _) <- rejectedCurPairs]

      reopenedOrigins =
        [ origC
        | PredValidKeepActive origC _ noteTxt <- keepActiveVerdicts
        , not (T.null (T.strip noteTxt))
        , not (startsWithScreeningFlag (T.strip noteTxt))
        , pr <- prevRecords
        , prOriginChunk pr == origC
        , not (isPredActive pr)
        ]

      mkResolutionMeta :: Text -> ResolutionMeta
      mkResolutionMeta noteTxt =
        ResolutionMeta
          { rmChunk = curIdx
          , rmChapterNumber = chapNum
          , rmChapterTitle = chapTitle
          , rmPartInChapter = partNum
          , rmPartsInChapter = partsTotal
          , rmNote = noteTxt
          }

      applySingleJudgeVerdict :: PredictionRecord -> PredictionRecord
      applySingleJudgeVerdict pr =
        case [ r | (origC, r) <- matchedResolutions, origC == prOriginChunk pr ] of
          (r : _) ->
            let origC = prOriginChunk pr
                noteTxt =
                  if T.null (T.strip (ppBodyAfterBracket r))
                    then prRawBody pr
                    else T.strip (ppBodyAfterBracket r)
                rm = mkResolutionMeta noteTxt
                newStatus =
                  case ppResKind r of
                    ResConfirmed -> PredStatusConfirmed rm (curIdx <= origC)
                    ResDebunked -> PredStatusDebunked rm
                    ResSubverted -> PredStatusSubverted rm
                    ResRetired -> PredStatusRetired rm
             in pr {prStatus = newStatus}
          []
            | prOriginChunk pr `elem` reopenedOrigins ->
                pr {prStatus = PredStatusActive Nothing}
            | otherwise ->
                case prStatus pr of
                  PredStatusActive mExisting ->
                    let origC = prOriginChunk pr
                        mIncoming =
                          listToMaybe
                            [ T.strip note
                            | PredValidKeepActive kOrig _ note <- keepActiveVerdicts
                            , kOrig == origC
                            , not (T.null (T.strip note))
                            ]
                        updatedNote =
                          case mIncoming of
                            Just note
                              | origC == curIdx -> Just note
                            _ -> mExisting
                     in pr {prStatus = PredStatusActive updatedNote}
                  _ -> pr

      keptPrevRecords = [pr | pr <- prevRecords, prOriginChunk pr `notElem` rejectedOrigins]
      recordsAfterJudge = map applySingleJudgeVerdict keptPrevRecords

      activeAfterJudge = [pr | pr <- recordsAfterJudge, isPredActive pr]
      neededRetires = max 0 (length activeAfterJudge - 10)

      dedupCandidates _ [] = []
      dedupCandidates seen ((origC, rTxt) : rest)
        | origC `elem` seen = dedupCandidates seen rest
        | otherwise = (origC, rTxt) : dedupCandidates (origC : seen) rest

      combinedRetireNominations = dedupCandidates [] (judgeRetireVerdicts ++ pendingRetires)

      overriddenCandidates =
        [ (origC, reason, pr)
        | (origC, reason) <- combinedRetireNominations
        , pr <- recordsAfterJudge
        , prOriginChunk pr == origC
        , not (isPredActive pr)
        ]
      stillActiveCandidates =
        [ (origC, if T.null reason then prRawBody pr else reason, pr)
        | (origC, reason) <- combinedRetireNominations
        , pr <- recordsAfterJudge
        , prOriginChunk pr == origC
        , isPredActive pr
        ]
      (nominatedApplied, sparedRetires) = splitAt neededRetires stillActiveCandidates
      nominatedOrigins = [origC | (origC, _, _) <- nominatedApplied]
      stillNeededFallback = max 0 (neededRetires - length nominatedApplied)
      fallbackPriority pr =
        let isCur = prOriginChunk pr == curIdx
            mNote = predActiveScreeningNote pr
            noteClean =
              case mNote of
                Nothing -> ""
                Just n -> T.toLower (T.stripStart (T.dropWhile (\c -> isSpace c || c == '*' || c == '`') n))
            isDup = "[duplicate-thesis]" `T.isPrefixOf` noteClean
            isFlagged = maybe False startsWithScreeningFlag mNote
            tier :: Int
            tier
              | not isCur && isDup = 0
              | not isCur && isFlagged = 1
              | isCur && isDup = 2
              | isCur && isFlagged = 3
              | not isCur = 4
              | otherwise = 5
         in (tier, prOriginChunk pr)
      fallbackPool =
        sortOn
          fallbackPriority
          [ pr
          | pr <- activeAfterJudge
          , prOriginChunk pr `notElem` nominatedOrigins
          ]
      autoRetireMsg :: Text
      autoRetireMsg = "Retired automatically to maintain the 10-active-prediction cap."

      fallbackApplied =
        [ (prOriginChunk pr, autoRetireMsg, pr)
        | pr <- take stillNeededFallback fallbackPool
        ]
      appliedRetires = nominatedApplied ++ fallbackApplied

      applyConditionalRetire :: PredictionRecord -> PredictionRecord
      applyConditionalRetire pr =
        case [ reason | (origC, reason, _) <- appliedRetires, origC == prOriginChunk pr ] of
          (reason : _) ->
            let effectiveReason =
                  case predActiveScreeningNote pr of
                    Just sNote
                      | prOriginChunk pr == curIdx
                          && startsWithScreeningFlag sNote
                          && not (startsWithScreeningFlag reason) ->
                          if reason == autoRetireMsg
                            then sNote <> " (" <> reason <> ")"
                            else sNote <> " — " <> reason
                    _ -> reason
             in pr {prStatus = PredStatusRetired (mkResolutionMeta effectiveReason)}
          [] -> pr

      finalRecords = sortOn prOriginChunk (map applyConditionalRetire recordsAfterJudge)
      finalActiveCount = length [pr | pr <- finalRecords, isPredActive pr]

      resolvedOrigins = [origC | (origC, _) <- matchedResolutions]
      resolvedLines =
        [ renderRecordResolvedLine pr
        | pr <- finalRecords
        , prOriginChunk pr `elem` resolvedOrigins
        ]
      reopenedLines =
        [ "- **[Predicted Chunk "
            <> T.pack (padChunkNumber (prOriginChunk pr))
            <> " -> ACTIVE (Cliffhanger Fake-Out Reversal)]** Restored to active status by `lets-read-prediction-judge`."
        | pr <- finalRecords
        , prOriginChunk pr `elem` reopenedOrigins
        ]
      rejectedCurLines =
        [ "- **[Predicted Chunk "
            <> T.pack (padChunkNumber (prOriginChunk pr))
            <> " -> NOT ADDED]** "
            <> rejNote
        | (pr, rejNote) <- rejectedCurPairs
        ]
      newCurLine =
        [ let origC = prOriginChunk pr
              mJudgeNote =
                listToMaybe
                  [ T.strip note
                  | PredValidKeepActive kOrig _ note <- keepActiveVerdicts
                  , kOrig == origC
                  , not (T.null (T.strip note))
                  ]
              noteSuffix =
                fromMaybe
                  ("Newly logged prediction remains active (" <> T.intercalate ", " (prTopics pr) <> ").")
                  mJudgeNote
           in "- **[Predicted Chunk "
                <> T.pack (padChunkNumber origC)
                <> " -> ACTIVE]** "
                <> noteSuffix
        | pr <- finalRecords
        , prOriginChunk pr == curIdx
        , isPredActive pr
        ]
      overriddenLines =
        [ "- *Retirement Candidate Judged on Merits*: **[Predicted Chunk "
            <> T.pack (padChunkNumber origC)
            <> "]** (conditional retirement candidate) was evaluated on the merits and ruled **"
            <> predShortStatusTag pr
            <> "**!"
        | (origC, _, pr) <- overriddenCandidates
        ]
      appliedRetireLines =
        [ renderRecordResolvedLine pr
            <> " *(Conditional retirement applied: >10 predictions remained ACTIVE after Judge rulings)*"
        | (origC, _, _) <- appliedRetires
        , pr <- finalRecords
        , prOriginChunk pr == origC
        ]
      sparedRetireLines =
        [ "- *Conditional Retirement Not Needed*: **[Predicted Chunk "
            <> T.pack (padChunkNumber origC)
            <> "]** remains **ACTIVE** because the active slate stayed at "
            <> jsonInt finalActiveCount
            <> "/10."
        | (origC, _, _) <- sparedRetires
        ]
      notAddedTallySuffix =
        if null rejectedCurPairs
          then ""
          else ", " <> jsonInt (length rejectedCurPairs) <> " not added"
      tallyLine =
        "- *Slate Status After Judge*: **"
          <> jsonInt finalActiveCount
          <> "/10 Active** ("
          <> jsonInt (length resolvedLines)
          <> " resolved by Judge, "
          <> jsonInt (length appliedRetires)
          <> " retired for cap"
          <> notAddedTallySuffix
          <> ")."
      judgeSummaryLines =
        resolvedLines
          ++ reopenedLines
          ++ overriddenLines
          ++ appliedRetireLines
          ++ sparedRetireLines
          ++ rejectedCurLines
          ++ newCurLine
          ++ [tallyLine]
   in (finalRecords, rejectedCurPairs, [], judgeSummaryLines)

countActivePredictions :: [PredictionRecord] -> Int
countActivePredictions preds =
  length [pr | pr <- preds, isPredActive pr]

predStatusBadge :: PredictionRecord -> Text
predStatusBadge pr =
  case prStatus pr of
    PredStatusActive _ -> "ACTIVE (Unresolved)"
    PredStatusConfirmed rm isSameChunk
      | isSameChunk ->
          "CONFIRMED in Chunk "
            <> T.pack (padChunkNumber (rmChunk rm))
            <> " (Same-Chunk — No Foresight Credit)"
      | otherwise ->
          let resC = rmChunk rm
              delta = resC - prOriginChunk pr
              unitTxt = if delta == 1 then " chunk" else " chunks"
           in "CONFIRMED in Chunk "
                <> T.pack (padChunkNumber resC)
                <> " (Confirmed Hit, +"
                <> jsonInt delta
                <> unitTxt
                <> " foresight)"
    PredStatusDebunked rm ->
      "DEBUNKED in Chunk " <> T.pack (padChunkNumber (rmChunk rm))
    PredStatusSubverted rm ->
      "SUBVERTED in Chunk " <> T.pack (padChunkNumber (rmChunk rm))
    PredStatusRetired rm ->
      "RETIRED in Chunk " <> T.pack (padChunkNumber (rmChunk rm)) <> " (10-Prediction Cap)"

predShortStatusTag :: PredictionRecord -> Text
predShortStatusTag pr =
  case prStatus pr of
    PredStatusActive _ -> "ACTIVE"
    PredStatusConfirmed rm isSameChunk
      | isSameChunk -> "CONFIRMED Chk " <> T.pack (padChunkNumber (rmChunk rm)) <> " (0 Chk)"
      | otherwise -> "CONFIRMED Chk " <> T.pack (padChunkNumber (rmChunk rm)) <> " (Hit)"
    PredStatusDebunked rm -> "DEBUNKED Chk " <> T.pack (padChunkNumber (rmChunk rm))
    PredStatusSubverted rm -> "SUBVERTED Chk " <> T.pack (padChunkNumber (rmChunk rm))
    PredStatusRetired rm -> "RETIRED Chk " <> T.pack (padChunkNumber (rmChunk rm))

renderSinglePredictionDoc :: FilePath -> PredictionRecord -> Text
renderSinglePredictionDoc sessionDir pr =
  let origC = prOriginChunk pr
      origPad = padChunkNumber origC
      origStr = T.pack origPad
      chapStr = formatChapLabel (prChapterNumber pr) (prChapterTitle pr)
      storyPath = T.pack ("chunks" </> ("chunk_" ++ origPad ++ ".md"))
      entryPath = T.pack ("entries" </> ("chunk_" ++ origPad ++ ".md"))
      memPath = T.pack ("archive" </> "memory" </> ("chunk_" ++ origPad ++ ".md"))
      topicsLine =
        if null (prTopics pr)
          then "General Plot"
          else T.intercalate ", " (prTopics pr)
      resolutionSection =
        case predResolutionMeta pr of
          Nothing ->
            let screenLines =
                  case predActiveScreeningNote pr of
                    Nothing -> []
                    Just sNote -> ["- **Judge Screening**: " <> sNote]
             in [ "## Resolution / Outcome"
                , ""
                , "- *Status*: Currently **ACTIVE** (unresolved)."
                ]
                  ++ screenLines
          Just rm ->
            let resC = rmChunk rm
                resPad = padChunkNumber resC
                resChapStr = formatChapLabel (rmChapterNumber rm) (rmChapterTitle rm)
                resPartStr = "Part " <> jsonInt (rmPartInChapter rm) <> "/" <> jsonInt (rmPartsInChapter rm)
                resStoryPath = T.pack ("chunks" </> ("chunk_" ++ resPad ++ ".md"))
                resEntryPath = T.pack ("entries" </> ("chunk_" ++ resPad ++ ".md"))
                noteTxt = if T.null (T.strip (rmNote rm)) then prRawBody pr else rmNote rm
             in [ "## Resolution / Outcome"
                , ""
                , "- **Outcome**: " <> predStatusBadge pr <> " (" <> resChapStr <> ", " <> resPartStr <> ")"
                , "- **Resolution Chunk Links**: [story]("
                    <> resStoryPath
                    <> ") | [entry]("
                    <> resEntryPath
                    <> ")"
                , "- **Explanation**: " <> noteTxt
                ]
   in T.unlines $
        [ "# Prediction " <> origStr <> " (" <> chapStr <> ")"
        , ""
        , "- **Session Directory**: `" <> T.pack sessionDir <> "`"
        , "- **Origin Chunk**: Chunk "
            <> origStr
            <> " ("
            <> chapStr
            <> ") — [story]("
            <> storyPath
            <> ") | [entry]("
            <> entryPath
            <> ") | [memory]("
            <> memPath
            <> ")"
        , "- **Status**: **" <> predStatusBadge pr <> "**"
        , "- **Topics**: " <> topicsLine
        , ""
        , "## Structured Breakdown"
        , ""
        , "- **Clue / Anomaly**: " <> (if T.null (prClue pr) then prRawBody pr else prClue pr)
        , "- **Theory**: " <> (if T.null (prTheory pr) then prRawBody pr else prTheory pr)
        , "- **Canonical Tracker Line**: " <> renderRecordActiveLine pr
        , ""
        ]
          ++ resolutionSection

cleanPublicOutcomeNote :: PredictionRecord -> ResolutionMeta -> Text
cleanPublicOutcomeNote pr rm =
  case prStatus pr of
    PredStatusRetired _ -> stripLeadingScreeningFlags (rmNote rm)
    _ -> T.strip (rmNote rm)

renderPredSummaryBullet :: PredictionRecord -> Text
renderPredSummaryBullet pr =
  let origPad = padChunkNumber (prOriginChunk pr)
      predFile = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
      storyPath = T.pack ("chunks" </> ("chunk_" ++ origPad ++ ".md"))
      entryPath = T.pack ("entries" </> ("chunk_" ++ origPad ++ ".md"))
      chapStr = formatChapLabel (prChapterNumber pr) (prChapterTitle pr)
      topicsStr =
        if null (prTopics pr)
          then ""
          else " | *Topics*: " <> T.intercalate ", " (prTopics pr)
      coreTheory =
        if not (T.null (prTheory pr))
          then "**Theory**: " <> prTheory pr
          else prRawBody pr
      resSuffix =
        case predResolutionMeta pr of
          Just rm ->
            let noteClean = cleanPublicOutcomeNote pr rm
             in if T.null noteClean then "" else " -> *Outcome*: " <> noteClean
          Nothing -> ""
   in wrapMarkdownBullet
        78
        ( "- **[pred_"
            <> T.pack origPad
            <> "]("
            <> predFile
            <> ")** ("
            <> chapStr
            <> " | **"
            <> predShortStatusTag pr
            <> "**"
            <> topicsStr
            <> "): "
            <> coreTheory
            <> resSuffix
            <> " ([story]("
            <> storyPath
            <> ") | [entry]("
            <> entryPath
            <> "))"
        )

renderPredCrossArcResolutionBullet :: PredictionRecord -> Text
renderPredCrossArcResolutionBullet pr =
  let origPad = padChunkNumber (prOriginChunk pr)
      origStr = T.pack origPad
      predFile = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
      origStoryPath = T.pack ("chunks" </> ("chunk_" ++ origPad ++ ".md"))
      origChapStr = formatChapLabel (prChapterNumber pr) (prChapterTitle pr)
      topicsStr =
        if null (prTopics pr)
          then ""
          else " | *Topics*: " <> T.intercalate ", " (prTopics pr)
      coreTheory =
        if not (T.null (prTheory pr))
          then "**Theory**: " <> prTheory pr
          else prRawBody pr
      (resLinksSuffix, resNoteSuffix) =
        case predResolutionMeta pr of
          Nothing ->
            (" ([origin](" <> origStoryPath <> "))", "")
          Just rm ->
            let resPad = padChunkNumber (rmChunk rm)
                resStoryPath = T.pack ("chunks" </> ("chunk_" ++ resPad ++ ".md"))
                resEntryPath = T.pack ("entries" </> ("chunk_" ++ resPad ++ ".md"))
                noteClean = cleanPublicOutcomeNote pr rm
                notePart =
                  if T.null noteClean
                    then ""
                    else " -> *Outcome*: " <> noteClean
             in ( " ([origin]("
                    <> origStoryPath
                    <> ") | [resolution]("
                    <> resStoryPath
                    <> ") | [entry]("
                    <> resEntryPath
                    <> "))"
                , notePart
                )
   in wrapMarkdownBullet
        78
        ( "- **[pred_"
            <> origStr
            <> "]("
            <> predFile
            <> ")** (**"
            <> predShortStatusTag pr
            <> "** | Staked: "
            <> origChapStr
            <> ", Chunk "
            <> origStr
            <> topicsStr
            <> "): "
            <> coreTheory
            <> resNoteSuffix
            <> resLinksSuffix
        )

renderHallOfFameMarkdown :: FilePath -> SessionState -> Text
renderHallOfFameMarkdown sessionDir st =
  let preds = stPredictions st
      confirmedHits =
        sortOn
          ( \pr ->
              case prStatus pr of
                PredStatusConfirmed rm _ -> Down (rmChunk rm - prOriginChunk pr)
                _ -> Down 0
          )
          [ pr
          | pr <- preds
          , case prStatus pr of
              PredStatusConfirmed _ isSameChunk -> not isSameChunk
              _ -> False
          ]
      sameChunkConfirmations =
        [ pr
        | pr <- preds
        , case prStatus pr of
            PredStatusConfirmed _ isSameChunk -> isSameChunk
            _ -> False
        ]
      subvertedList =
        [ pr
        | pr <- preds
        , case prStatus pr of
            PredStatusSubverted {} -> True
            _ -> False
        ]
      debunkedList =
        [ pr
        | pr <- preds
        , case prStatus pr of
            PredStatusDebunked {} -> True
            _ -> False
        ]
      retiredList =
        [ pr
        | pr <- preds
        , case prStatus pr of
            PredStatusRetired {} -> True
            _ -> False
        ]
      unresolvedList =
        [ pr
        | pr <- preds
        , isPredActive pr
        ]
      totalLogged = length preds
      storyJudgedCount = length confirmedHits + length subvertedList + length debunkedList
      accuracyNote
        | storyJudgedCount == 0 = "N/A (0 story-judged predictions)"
        | otherwise =
            let pct = (length confirmedHits * 100) `div` storyJudgedCount
             in jsonInt pct
                  <> "% ("
                  <> jsonInt (length confirmedHits)
                  <> " Confirmed Hits out of "
                  <> jsonInt storyJudgedCount
                  <> " story-resolved predictions)"
      renderDetailedBullet pr =
        let origPad = padChunkNumber (prOriginChunk pr)
            predFile = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
            origBet = renderOriginalPredictionSummary pr
            resolvedLine =
              case prStatus pr of
                PredStatusRetired rm ->
                  let cleaned = stripLeadingScreeningFlags (rmNote rm)
                      noteTxt = if T.null cleaned then prRawBody pr else cleaned
                   in canonicalizeResolvedLine (prOriginChunk pr) (rmChunk rm) ResRetired noteTxt
                _ -> renderRecordResolvedLine pr
            topLine =
              wrapMarkdownBullet
                78
                ( resolvedLine
                    <> " ([pred_"
                    <> T.pack origPad
                    <> "]("
                    <> predFile
                    <> "))"
                )
            origLine = wrapMarkdownBullet 78 ("  - Original prediction — " <> origBet)
         in topLine <> "\n" <> origLine
      renderUnresolvedBullet pr =
        let origPad = padChunkNumber (prOriginChunk pr)
            predFile = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
         in wrapMarkdownBullet
              78
              ( renderRecordActiveLine pr
                  <> " ([pred_"
                  <> T.pack origPad
                  <> "]("
                  <> predFile
                  <> "))"
              )
      sectionOrEmpty emptyMsg items renderFn =
        if null items
          then [emptyMsg]
          else [T.intercalate "\n\n" (map renderFn items)]
      sameChunkScoreLine =
        [ "- Same-Chunk Confirmations (0 Chunks Foresight): " <> jsonInt (length sameChunkConfirmations)
        | not (null sameChunkConfirmations)
        ]
      sameChunkSection =
        if null sameChunkConfirmations
          then []
          else
            [ ""
            , "## Same-Chunk Confirmations"
            , ""
            , T.intercalate "\n\n" (map renderDetailedBullet sameChunkConfirmations)
            ]
      introPara =
        wrapMarkdownParagraph
          78
          ( "Generated automatically upon story completion from all "
              <> jsonInt totalLogged
              <> " recorded predictions in `"
              <> T.pack sessionDir
              <> "`."
          )
   in T.unlines $
        [ "# Prediction Hall of Fame & Shame: " <> stTitle st
        , ""
        , introPara
        , ""
        , "## Final Prediction Scoreboard"
        , ""
        , "- Total Predictions Logged: " <> jsonInt totalLogged
        , "- Confirmed Hits: **" <> jsonInt (length confirmedHits) <> "**"
        , "- Subverted Twists (Right Clue, Surprise Twist): **" <> jsonInt (length subvertedList) <> "**"
        , "- Debunked Misses: **" <> jsonInt (length debunkedList) <> "**"
        ]
          ++ sameChunkScoreLine
          ++ [ "- Retired for 10-Prediction Cap: " <> jsonInt (length retiredList)
             , "- Unresolved / Open-Ended at Finale: " <> jsonInt (length unresolvedList)
             , "- Hit Rate: " <> accuracyNote
             , ""
             , "## Hall of Fame — Confirmed Hits"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(No confirmed hits recorded.)*"
            confirmedHits
            renderDetailedBullet
          ++ [ ""
             , "## Best Twists — Subverted Predictions"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(No subverted predictions recorded.)*"
            subvertedList
            renderDetailedBullet
          ++ [ ""
             , "## Hall of Shame — Debunked Predictions"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(No debunked predictions recorded.)*"
            debunkedList
            renderDetailedBullet
          ++ sameChunkSection
          ++ [ ""
             , "## Unresolved Predictions at Finale"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(None — all active predictions were resolved!)*"
            unresolvedList
            renderUnresolvedBullet
          ++ [ ""
             , "## Retired Predictions"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(None.)*"
            retiredList
            renderDetailedBullet

formatPredictionTrackerCallout :: [Text] -> Text
formatPredictionTrackerCallout [] = ""
formatPredictionTrackerCallout trackerLines =
  "\n\n> [!NOTE]\n> **Prediction Tracker Update (Reader Proposal)**:\n"
    <> T.stripEnd
      ( T.unlines
          [ if T.null (T.strip l) then ">" else "> " <> l
          | l <- trackerLines
          ]
      )

formatJudgeCallout :: Int -> [Text] -> Text
formatJudgeCallout _ [] = ""
formatJudgeCallout curIdx judgeLines =
  let curPad = T.pack (padChunkNumber curIdx)
   in "\n\n> [!NOTE]\n> **Prediction Judge Rulings (Chunk "
        <> curPad
        <> ")**:\n"
        <> T.stripEnd
          ( T.unlines
              [ if T.null (T.strip l) then ">" else "> " <> l
              | l <- judgeLines
              ]
          )

stripExistingJudgeCallout :: Text -> Text
stripExistingJudgeCallout txt =
  let marker = "\n\n> [!NOTE]\n> **Prediction Judge Rulings"
      (before, after) = T.breakOn marker txt
   in if T.null after
        then txt
        else before

stripTrackerProposalCallout :: Text -> Text
stripTrackerProposalCallout txt =
  let marker = "\n\n> [!NOTE]\n> **Prediction Tracker Update (Reader Proposal)**:\n"
      (before, after) = T.breakOn marker txt
   in if T.null after
        then txt
        else
          let afterHeader = T.drop (T.length marker) after
              remainingLines = dropWhile (\l -> ">" `T.isPrefixOf` T.stripStart l) (T.lines afterHeader)
              restTxt = T.stripStart (T.unlines remainingLines)
           in if T.null restTxt
                then T.stripEnd before
                else T.stripEnd before <> "\n\n" <> T.stripEnd restTxt

formatAuditEntryCallout :: [Text] -> Text
formatAuditEntryCallout [] = ""
formatAuditEntryCallout auditBlocks =
  "\n\n> [!WARNING]\n> **Gatekeeper Prediction Audit**:\n"
    <> T.stripEnd
      ( T.unlines
          [ if T.null (T.strip l) then ">" else "> " <> l
          | l <- T.lines (T.strip (T.intercalate "\n\n" auditBlocks))
          ]
      )
