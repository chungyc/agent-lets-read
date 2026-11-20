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
  , parsePredictionLine
  , auditAndApplyPredictionUpdates
  , extractJudgeSection
  , applyJudgeVerdicts
  , countActivePredictions
  , predStatusBadge
  , predShortStatusTag
  , renderSinglePredictionDoc
  , renderPredSummaryBullet
  , renderHallOfFameMarkdown
  , renderPredictionSlateSection
  , formatPredictionTrackerCallout
  , formatJudgeCallout
  , stripExistingJudgeCallout
  , formatAuditEntryCallout
  ) where

import Data.Char (isAlphaNum, isDigit, isSpace, isUpper)
import Data.List (sortOn)
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import LetsRead.Types
  ( ParsedPrediction (..)
  , PredictionRecord (..)
  , PredictionStatus (..)
  , ResolutionKind (..)
  , SessionState (..)
  , formatChapLabel
  , jsonInt
  , padChunkNumber
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
  , "anomaly", "theory", "plausible", "rival", "predicted", "confirmed"
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
          $ T.replace "**Plausible Rival**" " "
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

splitPredictionComponents :: Text -> (Text, Text, Text)
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
      (theoryPart, rivalPart) =
        case T.breakOn "(vs." afterArrow of
          (t, r) | not (T.null r) ->
            let rInner = T.drop 4 r
                rTrim = T.dropWhileEnd (\c -> c == '.' || isSpace c) rInner
                rClean =
                  if ")" `T.isSuffixOf` rTrim
                    then T.dropEnd 1 rTrim
                    else rInner
             in (t, rClean)
          _ ->
            case T.breakOn "**Plausible Rival**" afterArrow of
              (t, r) | not (T.null r) -> (t, r)
              _ -> (afterArrow, "")
      clueClean =
        stripBoldLabel "clue/anomaly"
          $ stripBoldLabel "clue"
          $ stripBoldLabel "anomaly" cluePart
      theoryClean = stripBoldLabel "theory" theoryPart
      rivalClean = stripBoldLabel "plausible rival" (stripBoldLabel "rival" rivalPart)
   in (T.strip clueClean, T.strip theoryClean, T.strip rivalClean)

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
            | c2 - c1 < 3 ->
                "Predicted Chunk " <> c1Str <> " -> CONFIRMED Chunk " <> c2Str <> " (Short-Horizon <3 Chunks — No Hit Credit)"
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
              shortHorizonPrefix = "(short-horizon <3 chunks"
              afterBracket =
                if shortHorizonPrefix `T.isPrefixOf` T.toLower rawAfterBracket
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
                      isKeepActive =
                        hasArrow
                          && ( "active" `T.isInfixOf` inside
                                 || "unresolv" `T.isInfixOf` inside
                                 || "pending" `T.isInfixOf` inside
                             )
                      isActiveTag =
                        ("predicted" `T.isInfixOf` inside || "active" `T.isInfixOf` inside)
                          && not hasArrow
                   in if isKeepActive
                        then case nums of
                          (c1 : _) | c1 > 0 -> PredValidKeepActive c1 l afterBracket
                          _ -> PredInvalidNotation l afterBracket
                        else case nums of
                          [c1]
                            | isActiveTag && c1 > 0 && not (T.null (T.strip afterBracket)) ->
                                let topics = parseTopicsFromBracket insideRaw afterBracket
                                    (clue, theory, rival) = splitPredictionComponents afterBracket
                                    canonL = canonicalizeActiveLine c1 topics afterBracket
                                 in PredValidActive c1 topics clue theory rival canonL afterBracket
                          _ ->
                            PredInvalidNotation l afterBracket

renderRecordActiveLine :: PredictionRecord -> Text
renderRecordActiveLine pr =
  canonicalizeActiveLine (prOriginChunk pr) (prTopics pr) (prRawBody pr)

renderRecordResolvedLine :: PredictionRecord -> Text
renderRecordResolvedLine pr =
  let origC = prOriginChunk pr
      noteTxt = fromMaybe (prRawBody pr) (prResolutionNote pr)
   in case prStatus pr of
        PredStatusActive -> renderRecordActiveLine pr
        PredStatusConfirmed resC _ -> canonicalizeResolvedLine origC resC ResConfirmed noteTxt
        PredStatusDebunked resC -> canonicalizeResolvedLine origC resC ResDebunked noteTxt
        PredStatusSubverted resC -> canonicalizeResolvedLine origC resC ResSubverted noteTxt
        PredStatusRetired resC -> canonicalizeResolvedLine origC resC ResRetired noteTxt

renderOriginalPredictionSummary :: PredictionRecord -> Text
renderOriginalPredictionSummary pr
  | not (T.null (prClue pr)) && not (T.null (prTheory pr)) =
      "**Clue/Anomaly**: "
        <> prClue pr
        <> " -> **Theory**: "
        <> prTheory pr
        <> (if T.null (prRival pr) then "" else " (vs. **Plausible Rival**: " <> prRival pr <> ")")
  | otherwise = T.strip (prRawBody pr)

checkPredictionConcisenessIssues :: PredictionRecord -> [Text]
checkPredictionConcisenessIssues pr =
  let bodyLen = T.length (prRawBody pr)
      clueLen = T.length (prClue pr)
      theoryLen = T.length (prTheory pr)
      rivalLen = T.length (prRival pr)
      clueHasQuote = T.any (\c -> c == '"' || c == '\x201C' || c == '\x201D') (prClue pr)
   in [ "total body was " <> jsonInt bodyLen <> " chars (cap: <= 450 chars)" | bodyLen > 450 ]
        ++ [ "`**Clue/Anomaly**` was " <> jsonInt clueLen <> " chars (cap: <= 120 chars)" | clueLen > 120 ]
        ++ [ "`**Clue/Anomaly**` contained inline quotation marks (summarize the detail in 1 short clause without quoting)" | clueHasQuote ]
        ++ [ "`**Theory**` was " <> jsonInt theoryLen <> " chars (cap: <= 160 chars)" | theoryLen > 160 ]
        ++ [ "`**Plausible Rival**` was " <> jsonInt rivalLen <> " chars (cap: <= 120 chars)" | rivalLen > 120 ]

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
                <> ", keep the post-bracket prediction body `<= 450 chars` total (`**Clue/Anomaly** <= 120 chars` with no inline quotes, `**Theory** <= 160 chars` stating 1 direct outcome, `**Plausible Rival** <= 120 chars`)."
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
      prevActives = [pr | pr <- prevRecords, prStatus pr == PredStatusActive]
      prevActiveChunksSummary =
        case map (T.pack . padChunkNumber . prOriginChunk) prevActives of
          [] -> "none currently active in `memory.md`"
          cs -> T.intercalate ", " ["`[Predicted Chunk " <> c <> "]`" | c <- cs]
      sampleOrigStr =
        case prevActives of
          (p : _) -> T.pack (padChunkNumber (prOriginChunk p))
          [] -> curStr

      allBullets =
        case mPredUpdatesTxt of
          Nothing -> []
          Just b ->
            [ parsePredictionLine trimmed
            | rawL <- coalesceBulletLines (T.lines b)
            , let trimmed = T.strip rawL
            , not (isPlaceholderLine trimmed)
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
            "Self-judging predictions (`CONFIRMED`, `DEBUNKED`, `SUBVERTED`) is handled exclusively by the `prediction-judge` subagent; `blind-reader` must not emit resolution verdicts in `=== PREDICTION UPDATES ===`."
            (ppRawLine r)
            ( "Remove `CONFIRMED` / `DEBUNKED` / `SUBVERTED` lines from `=== PREDICTION UPDATES ===`. Only output your 1 new prediction (`- **[Predicted Chunk "
                <> nextStr
                <> " | Topics: Topic 1, Topic 2]** ...`) and, when at the 10-prediction cap, your conditional retirement suggestion (`- **[Predicted Chunk XXXX -> RETIRED Chunk "
                <> nextStr
                <> "]** <reason>`)."
            )
        | r <- selfJudgedBullets
        ]

      classifyActiveBullet :: ParsedPrediction -> Either (Int, ParsedPrediction) (Maybe Text)
      classifyActiveBullet p@(PredValidActive c1 _ clue theory rival canonL bodyAfter)
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
                    <> "]` (existing active tags: "
                    <> prevActiveChunksSummary
                    <> ")."
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
        | T.null clue || T.null theory || T.null rival =
            Right
              ( Just
                  ( renderTagFormatAuditBlock
                      "New prediction is missing one or more required structured segments (`**Clue/Anomaly**`, `-> **Theory**`, or `(vs. **Plausible Rival**: ...)`)."
                      canonL
                      ( "Format every new prediction as `- **[Predicted Chunk "
                          <> nextStr
                          <> " | Topics: Topic 1, Topic 2, Topic 3]** **Clue/Anomaly**: <detail> -> **Theory**: <primary bet> (vs. **Plausible Rival**: <rival explanation>)`."
                      )
                  )
              )
        | otherwise = Left (c1, p)
      classifyActiveBullet _ = Right Nothing

      classifyInvalidBullet :: ParsedPrediction -> Text
      classifyInvalidBullet (PredInvalidNotation rawInv bodyAfter) =
        let trimmedBody =
              if T.null (T.strip bodyAfter)
                then "**Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)"
                else T.strip bodyAfter
         in renderTagFormatAuditBlock
              ("Malformed or unsupported prediction bracket tag in `=== PREDICTION UPDATES ===` (currently active tags: " <> prevActiveChunksSummary <> ").")
              rawInv
              ( "Fix or remove this line in `=== PREDICTION UPDATES ===`! To log your new prediction, use `- **[Predicted Chunk "
                  <> nextStr
                  <> " | Topics: Topic 1, Topic 2]** "
                  <> trimmedBody
                  <> "` (on Chunk "
                  <> nextStr
                  <> "). Or when at the 10-prediction cap, suggest a conditional retirement using `- **[Predicted Chunk "
                  <> sampleOrigStr
                  <> " -> RETIRED Chunk "
                  <> nextStr
                  <> "]** <reason>`."
              )
      classifyInvalidBullet p =
        renderTagFormatAuditBlock
          "Unexpected prediction line format."
          (ppRawLine p)
          "Use standard `[Predicted Chunk XXXX | Topics: ...]` or (when above the 10-prediction cap) `[Predicted Chunk XXXX -> RETIRED Chunk YYYY]` notation."

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
      toPredictionRecord (PredValidActive c1 topics clue theory rival _ bodyAfter) =
        PredictionRecord
          { prOriginChunk = c1
          , prChapterNumber = chapNum
          , prChapterTitle = chapTitle
          , prPartInChapter = partNum
          , prPartsInChapter = partsTotal
          , prTopics = topics
          , prClue = clue
          , prTheory = theory
          , prRival = rival
          , prRawBody = bodyAfter
          , prStatus = PredStatusActive
          , prResolutionNote = Nothing
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

      activePoolBeforeJudge = [pr | pr <- candidateRecords, prStatus pr == PredStatusActive]

      findMatchingRetireTarget :: ParsedPrediction -> Maybe PredictionRecord
      findMatchingRetireTarget (PredValidResolved origC _ _ _ _) =
        listToMaybe [pr | pr <- activePoolBeforeJudge, prOriginChunk pr == origC]
      findMatchingRetireTarget _ = Nothing

      dedupRetireByOrigin _ [] = []
      dedupRetireByOrigin seen ((origC, resP, targetPr) : rest)
        | origC `elem` seen = dedupRetireByOrigin seen rest
        | otherwise = (origC, resP, targetPr) : dedupRetireByOrigin (origC : seen) rest

      matchedRetires =
        dedupRetireByOrigin
          []
          [ (prOriginChunk targetPr, r, targetPr)
          | r <- retireBullets
          , Just targetPr <- [findMatchingRetireTarget r]
          ]
      unmatchedRetires =
        [ r
        | r <- retireBullets
        , isNothing (findMatchingRetireTarget r)
        ]

      unmatchedRetireAuditBlocks =
        [ let origC = ppResOrigChunk r
              msg =
                "Conditional retirement tag references `[Predicted Chunk "
                  <> T.pack (padChunkNumber origC)
                  <> "]`, which does not match any active prediction in `memory.md` (currently active tags: "
                  <> prevActiveChunksSummary
                  <> ")."
              act =
                "Only nominate predictions that are currently active in `memory.md` ("
                  <> prevActiveChunksSummary
                  <> ") using `- **[Predicted Chunk "
                  <> sampleOrigStr
                  <> " -> RETIRED Chunk "
                  <> curStr
                  <> "]** <reason>`."
           in renderTagFormatAuditBlock msg (ppRawLine r) act
        | r <- unmatchedRetires
        ]

      totalUnresolvedBeforeJudge = length activePoolBeforeJudge
      allowedRetireCount = max 0 (totalUnresolvedBeforeJudge - 10)
      (validRetireCandidates, prematureRetirements) = splitAt allowedRetireCount matchedRetires

      pendingRetirePairs :: [(Int, Text)]
      pendingRetirePairs =
        [ ( origC
          , if T.null (T.strip (ppBodyAfterBracket r))
              then prRawBody targetPr
              else T.strip (ppBodyAfterBracket r)
          )
        | (origC, r, targetPr) <- validRetireCandidates
        ]

      prematureRetireAuditBlocks =
        [ let origStr = T.pack (padChunkNumber origC)
               in renderTagFormatAuditBlock
                    ("Prediction `[Predicted Chunk " <> origStr <> "]` was nominated for `RETIRED` when total unresolved predictions (" <> jsonInt totalUnresolvedBeforeJudge <> "/10) did not exceed the cap of 10.")
                    (ppRawLine r)
                    ( "Only nominate predictions for conditional retirement (`RETIRED`) when total unresolved predictions (including your new prediction) exceed 10. It remains active in `memory.md` (`"
                        <> renderRecordActiveLine targetPr
                        <> "`) for `prediction-judge` to evaluate."
                    )
        | (origC, r, targetPr) <- prematureRetirements
        ]

      hasNewForCur =
        any (\pr -> prOriginChunk pr == curIdx) candidateRecords
          || not (null activeAuditBlocks)
          || not (null invalidAuditBlocks)
          || not (null duplicateChunkAuditBlocks)
      missingNewPredAuditBlocks
        | isRecordTurn && curIdx >= 1 && curIdx < totalChunks && not hasNewForCur =
            [ renderTagFormatAuditBlock
                ("No new prediction was logged for Chunk " <> curStr <> " (every chunk before the final chunk must log 1 new non-softball, multi-chapter prediction, capped at 10 unresolved predictions).")
                ("*(Missing `- **[Predicted Chunk " <> curStr <> " | Topics: Topic 1, Topic 2]** **Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)` in `=== PREDICTION UPDATES ===`)*")
                ( "On Chunk "
                    <> nextStr
                    <> ", make sure to log 1 new non-softball, multi-chapter prediction using `- **[Predicted Chunk "
                    <> nextStr
                    <> " | Topics: Topic 1, Topic 2]** **Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)` in both `=== COMMENTARY ===` and `=== PREDICTION UPDATES ===`."
                )
            ]
        | otherwise = []

      allAuditBlocks =
        activeAuditBlocks
          ++ invalidAuditBlocks
          ++ duplicateChunkAuditBlocks
          ++ concisenessAuditBlocks
          ++ selfJudgedAuditBlocks
          ++ unmatchedRetireAuditBlocks
          ++ prematureRetireAuditBlocks
          ++ missingNewPredAuditBlocks

      commLower = T.toLower commText
      turnEvents = map renderRecordActiveLine newOrAmendedRecords
      trackerUpdateLines =
        [ evLine
        | evLine <- turnEvents
        , not (isPredictionMentionedInComm commLower evLine)
        ]
   in (candidateRecords, pendingRetirePairs, allAuditBlocks, trackerUpdateLines)

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

applyJudgeVerdicts
  :: Int
  -> [PredictionRecord]
  -> [(Int, Text)]
  -> Text
  -> ([PredictionRecord], [Text], [Text])
applyJudgeVerdicts curIdx prevRecords pendingRetires rawJudgeTxt =
  let nextStr = T.pack (padChunkNumber (max 1 curIdx + 1))
      judgeBody = extractJudgeSection rawJudgeTxt
      parsedLines =
        [ parsePredictionLine trimmed
        | rawL <- coalesceBulletLines (T.lines judgeBody)
        , let trimmed = T.strip rawL
        , not (isPlaceholderLine trimmed)
        , "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
        , "[" `T.isInfixOf` trimmed && "]" `T.isInfixOf` trimmed
        ]
      resolvedVerdicts =
        [ r
        | r@(PredValidResolved _ _ rKind _ _) <- parsedLines
        , rKind `elem` [ResConfirmed, ResDebunked, ResSubverted]
        ]
      keepActiveVerdicts =
        [ k
        | k@(PredValidKeepActive {}) <- parsedLines
        ]

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
          ]

      reopenedOrigins =
        [ origC
        | PredValidKeepActive origC _ noteTxt <- keepActiveVerdicts
        , not (T.null (T.strip noteTxt))
        , pr <- prevRecords
        , prOriginChunk pr == origC
        , prStatus pr /= PredStatusActive
        ]

      applySingleJudgeVerdict :: PredictionRecord -> PredictionRecord
      applySingleJudgeVerdict pr =
        case [ r | (origC, r) <- matchedResolutions, origC == prOriginChunk pr ] of
          (r : _) ->
            let origC = prOriginChunk pr
                noteTxt =
                  if T.null (T.strip (ppBodyAfterBracket r))
                    then prRawBody pr
                    else T.strip (ppBodyAfterBracket r)
                newStatus =
                  case ppResKind r of
                    ResConfirmed -> PredStatusConfirmed curIdx (curIdx - origC < 3)
                    ResDebunked -> PredStatusDebunked curIdx
                    ResSubverted -> PredStatusSubverted curIdx
                    ResRetired -> PredStatusRetired curIdx
             in pr {prStatus = newStatus, prResolutionNote = Just noteTxt}
          []
            | prOriginChunk pr `elem` reopenedOrigins ->
                pr {prStatus = PredStatusActive, prResolutionNote = Nothing}
            | otherwise -> pr

      recordsAfterJudge = map applySingleJudgeVerdict prevRecords

      activeAfterJudge = [pr | pr <- recordsAfterJudge, prStatus pr == PredStatusActive]
      neededRetires = max 0 (length activeAfterJudge - 10)

      overriddenCandidates =
        [ (origC, reason, pr)
        | (origC, reason) <- pendingRetires
        , pr <- recordsAfterJudge
        , prOriginChunk pr == origC
        , prStatus pr /= PredStatusActive
        ]
      stillActiveCandidates =
        [ (origC, reason, pr)
        | (origC, reason) <- pendingRetires
        , pr <- recordsAfterJudge
        , prOriginChunk pr == origC
        , prStatus pr == PredStatusActive
        ]
      (appliedRetires, sparedRetires) = splitAt neededRetires stillActiveCandidates

      applyConditionalRetire :: PredictionRecord -> PredictionRecord
      applyConditionalRetire pr =
        case [ reason | (origC, reason, _) <- appliedRetires, origC == prOriginChunk pr ] of
          (reason : _) ->
            pr {prStatus = PredStatusRetired curIdx, prResolutionNote = Just reason}
          [] -> pr

      finalRecords = sortOn prOriginChunk (map applyConditionalRetire recordsAfterJudge)
      finalActiveCount = length [pr | pr <- finalRecords, prStatus pr == PredStatusActive]

      capExceededAuditBlocks
        | finalActiveCount > 10 =
            let excess = finalActiveCount - 10
             in [ renderTagFormatAuditBlock
                    ("Active prediction slate has " <> jsonInt finalActiveCount <> " unresolved predictions after `prediction-judge` rulings, exceeding the maximum cap of 10.")
                    ("*(Active pool has " <> jsonInt finalActiveCount <> "/10 unresolved predictions — " <> jsonInt excess <> " over the cap of 10)*")
                    ( "On your next turn (Chunk "
                        <> nextStr
                        <> "), in addition to nominating 1 conditional retirement for Chunk "
                        <> nextStr
                        <> "'s new prediction, nominate "
                        <> jsonInt excess
                        <> " extra prediction(s) (prioritizing `[DUPLICATE-THESIS]`, `[LINEAR]`/`[SHORT-HORIZON]`/`[SPLIT-CONTINUATION]`, or expired-trigger bets over unique subplot bets—never defaulting to mechanical oldest-first FIFO) in `=== PREDICTION UPDATES ===` using `- **[Predicted Chunk XXXX -> RETIRED Chunk "
                        <> nextStr
                        <> "]** <reason>` so that at most 10 unresolved predictions remain."
                    )
                ]
        | otherwise = []

      resolvedOrigins = [origC | (origC, _) <- matchedResolutions]
      resolvedLines =
        [ renderRecordResolvedLine pr
        | pr <- finalRecords
        , prOriginChunk pr `elem` resolvedOrigins
        ]
      reopenedLines =
        [ "- **[Predicted Chunk "
            <> T.pack (padChunkNumber (prOriginChunk pr))
            <> " -> ACTIVE (Cliffhanger Fake-Out Reversal)]** Restored to active status by `prediction-judge`."
        | pr <- finalRecords
        , prOriginChunk pr `elem` reopenedOrigins
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
        , prStatus pr == PredStatusActive
        ]
      overriddenLines =
        [ "- *Retirement Nomination Judged on Merits*: **[Predicted Chunk "
            <> T.pack (padChunkNumber origC)
            <> "]** (nominated for retirement by `blind-reader`) was evaluated by `prediction-judge` and ruled **"
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
            <> "]** (nominated for retirement by `blind-reader`) remains **ACTIVE** because `prediction-judge` resolved enough predictions to keep the active slate at "
            <> jsonInt finalActiveCount
            <> "/10."
        | (origC, _, _) <- sparedRetires
        ]
      tallyLine =
        "- *Slate Status After Judge*: **"
          <> jsonInt finalActiveCount
          <> "/10 Active** ("
          <> jsonInt (length resolvedLines)
          <> " resolved by Judge, "
          <> jsonInt (length appliedRetires)
          <> " retired for cap)."
      judgeSummaryLines =
        resolvedLines
          ++ reopenedLines
          ++ overriddenLines
          ++ appliedRetireLines
          ++ sparedRetireLines
          ++ newCurLine
          ++ [tallyLine]
   in (finalRecords, capExceededAuditBlocks, judgeSummaryLines)

countActivePredictions :: [PredictionRecord] -> Int
countActivePredictions preds =
  length [pr | pr <- preds, prStatus pr == PredStatusActive]

predStatusBadge :: PredictionRecord -> Text
predStatusBadge pr =
  case prStatus pr of
    PredStatusActive -> "ACTIVE (Unresolved)"
    PredStatusConfirmed resC isShort
      | isShort ->
          "CONFIRMED in Chunk "
            <> T.pack (padChunkNumber resC)
            <> " (Short-Horizon <3 Chunks — No Hit Credit)"
      | otherwise ->
          "CONFIRMED in Chunk "
            <> T.pack (padChunkNumber resC)
            <> " (Major Hit, +"
            <> jsonInt (resC - prOriginChunk pr)
            <> " chunks foresight)"
    PredStatusDebunked resC ->
      "DEBUNKED in Chunk " <> T.pack (padChunkNumber resC)
    PredStatusSubverted resC ->
      "SUBVERTED in Chunk " <> T.pack (padChunkNumber resC)
    PredStatusRetired resC ->
      "RETIRED in Chunk " <> T.pack (padChunkNumber resC) <> " (10-Prediction Cap)"

predShortStatusTag :: PredictionRecord -> Text
predShortStatusTag pr =
  case prStatus pr of
    PredStatusActive -> "ACTIVE"
    PredStatusConfirmed resC isShort
      | isShort -> "CONFIRMED Chk " <> T.pack (padChunkNumber resC) <> " (<3 Chk)"
      | otherwise -> "CONFIRMED Chk " <> T.pack (padChunkNumber resC) <> " (Hit)"
    PredStatusDebunked resC -> "DEBUNKED Chk " <> T.pack (padChunkNumber resC)
    PredStatusSubverted resC -> "SUBVERTED Chk " <> T.pack (padChunkNumber resC)
    PredStatusRetired resC -> "RETIRED Chk " <> T.pack (padChunkNumber resC)

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
        let resolvedBlock resC =
              let resPad = padChunkNumber resC
                  resStoryPath = T.pack ("chunks" </> ("chunk_" ++ resPad ++ ".md"))
                  resEntryPath = T.pack ("entries" </> ("chunk_" ++ resPad ++ ".md"))
                  noteTxt = fromMaybe (prRawBody pr) (prResolutionNote pr)
               in [ "## Resolution / Outcome"
                  , ""
                  , "- **Outcome**: " <> predStatusBadge pr
                  , "- **Resolution Chunk Links**: [story]("
                      <> resStoryPath
                      <> ") | [entry]("
                      <> resEntryPath
                      <> ")"
                  , "- **Explanation**: " <> noteTxt
                  ]
         in case prStatus pr of
              PredStatusActive ->
                [ "## Resolution / Outcome"
                , ""
                , "- *Status*: Currently **ACTIVE** (unresolved)."
                ]
              PredStatusConfirmed c _ -> resolvedBlock c
              PredStatusDebunked c -> resolvedBlock c
              PredStatusSubverted c -> resolvedBlock c
              PredStatusRetired c -> resolvedBlock c
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
        , "- **Plausible Rival**: " <> (if T.null (prRival pr) then "*(Not separately specified)*" else prRival pr)
        , "- **Canonical Tracker Line**: " <> renderRecordActiveLine pr
        , ""
        ]
          ++ resolutionSection

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
        case prResolutionNote pr of
          Just n | prStatus pr /= PredStatusActive -> " -> *Outcome*: " <> n
          _ -> ""
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

renderHallOfFameMarkdown :: FilePath -> SessionState -> Text
renderHallOfFameMarkdown sessionDir st =
  let preds = stPredictions st
      majorHits =
        sortOn
          ( \pr ->
              case prStatus pr of
                PredStatusConfirmed resC _ -> Down (resC - prOriginChunk pr)
                _ -> Down 0
          )
          [ pr
          | pr <- preds
          , case prStatus pr of
              PredStatusConfirmed _ isShort -> not isShort
              _ -> False
          ]
      shortConfirmations =
        [ pr
        | pr <- preds
        , case prStatus pr of
            PredStatusConfirmed _ isShort -> isShort
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
        , prStatus pr == PredStatusActive
        ]
      totalLogged = length preds
      storyJudgedCount = length majorHits + length subvertedList + length debunkedList
      accuracyNote
        | storyJudgedCount == 0 = "N/A (0 multi-chunk story-judged predictions)"
        | otherwise =
            let pct = (length majorHits * 100) `div` storyJudgedCount
             in jsonInt pct
                  <> "% ("
                  <> jsonInt (length majorHits)
                  <> " Major Hits out of "
                  <> jsonInt storyJudgedCount
                  <> " non-short-horizon story-resolved predictions)"
      renderDetailedBullet pr =
        let origPad = padChunkNumber (prOriginChunk pr)
            predFile = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
            origBet = renderOriginalPredictionSummary pr
            topLine =
              wrapMarkdownBullet
                78
                ( renderRecordResolvedLine pr
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
        , "- Major Confirmed Hits (>= 3 Chunks Foresight): **" <> jsonInt (length majorHits) <> "**"
        , "- Subverted Twists (Right Clue, Surprise Twist): **" <> jsonInt (length subvertedList) <> "**"
        , "- Debunked Misses: **" <> jsonInt (length debunkedList) <> "**"
        , "- Short-Horizon Confirmations (< 3 Chunks — No Hit Credit): " <> jsonInt (length shortConfirmations)
        , "- Retired for 10-Prediction Cap: " <> jsonInt (length retiredList)
        , "- Unresolved / Open-Ended at Finale: " <> jsonInt (length unresolvedList)
        , "- Multi-Chunk Hit Rate: " <> accuracyNote
        , ""
        , "## Hall of Fame — Major Confirmed Hits"
        , ""
        ]
          ++ sectionOrEmpty
            "- *(No major multi-chunk confirmed hits recorded.)*"
            majorHits
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
          ++ [ ""
             , "## Short-Horizon Confirmations"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(None.)*"
            shortConfirmations
            renderDetailedBullet
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

renderPredictionSlateSection :: SessionState -> Text
renderPredictionSlateSection st =
  let preds = stPredictions st
      curIdx = stCurrentIndex st
      isFinished = curIdx >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
      activePreds = [pr | pr <- preds, prStatus pr == PredStatusActive]
      majorHitsCnt =
        length
          [ pr
          | pr <- preds
          , case prStatus pr of
              PredStatusConfirmed _ isShort -> not isShort
              _ -> False
          ]
      shortHitsCnt =
        length
          [ pr
          | pr <- preds
          , case prStatus pr of
              PredStatusConfirmed _ isShort -> isShort
              _ -> False
          ]
      debunkedCnt =
        length
          [ pr
          | pr <- preds
          , case prStatus pr of
              PredStatusDebunked {} -> True
              _ -> False
          ]
      subvertedCnt =
        length
          [ pr
          | pr <- preds
          , case prStatus pr of
              PredStatusSubverted {} -> True
              _ -> False
          ]
      retiredCnt =
        length
          [ pr
          | pr <- preds
          , case prStatus pr of
              PredStatusRetired {} -> True
              _ -> False
          ]
      recentResolved =
        [ pr
        | pr <- preds
        , case prStatus pr of
            PredStatusConfirmed resC _ -> resC >= max 1 (curIdx - 1)
            PredStatusDebunked resC -> resC >= max 1 (curIdx - 1)
            PredStatusSubverted resC -> resC >= max 1 (curIdx - 1)
            _ -> False
        ]
      chronPath = T.pack ("predictions" </> "by_chronology.md")
      topicPath = T.pack ("predictions" </> "by_topic.md")
      hofLinkSuffix =
        if isFinished
          then " | [Hall of Fame & Shame](" <> T.pack ("predictions" </> "hall_of_fame.md") <> ")"
          else ""
      scoreboardPara =
        wrapMarkdownParagraph
          78
          ( jsonInt (length preds)
              <> " logged | **"
              <> jsonInt majorHitsCnt
              <> " Major Hits** (>=3 chunks) | "
              <> jsonInt shortHitsCnt
              <> " Short-Horizon (<3 chunks) | **"
              <> jsonInt subvertedCnt
              <> " Subverted** | **"
              <> jsonInt debunkedCnt
              <> " Debunked** | "
              <> jsonInt retiredCnt
              <> " Retired | **"
              <> jsonInt (length activePreds)
              <> "/10 Active**"
          )
      indexLinksPara =
        "[Chronological Index]("
          <> chronPath
          <> ") | [Semantic Topic Index]("
          <> topicPath
          <> ") | [Prediction Files](predictions/)"
          <> hofLinkSuffix
      slateIntroPara =
        wrapMarkdownParagraph
          78
          "Do not re-emit this section in `=== UPDATED MEMORY ===`; submit only this turn's new prediction and any conditional `RETIRED` nomination in `=== PREDICTION UPDATES ===`. The `prediction-judge` subagent evaluates all active predictions after your turn."
      lastJudgeLines =
        if null (stLastJudgeSummary st)
          then []
          else
            [ ""
            , "### Latest Prediction Judge Rulings"
            , ""
            , wrapMarkdownParagraph 78 "React naturally in your commentary to any `CONFIRMED`, `DEBUNKED`, or `SUBVERTED` verdicts below:"
            , ""
            , T.intercalate "\n\n" (map (wrapMarkdownBullet 78) (stLastJudgeSummary st))
            ]
      recentResLines =
        if null recentResolved
          then []
          else
            [ ""
            , "### Recently Resolved"
            , ""
            , T.intercalate
                "\n\n"
                [ let origPad = padChunkNumber (prOriginChunk pr)
                      pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
                   in wrapMarkdownBullet 78 (renderRecordResolvedLine pr <> " ([details](" <> pPath <> "))")
                | pr <- recentResolved
                ]
            ]
      activeLines =
        if null activePreds
          then
            [ wrapMarkdownParagraph
                78
                "No active predictions yet. On every chunk before the final chunk, output 1 new non-softball, multi-chapter prediction (`<= 450 chars` total) in `=== PREDICTION UPDATES ===`."
            ]
          else
            [ let origPad = padChunkNumber (prOriginChunk pr)
                  pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
               in renderRecordActiveLine pr <> " ([details](" <> pPath <> "))"
            | pr <- activePreds
            ]
      warningSection =
        if null (stPredictionAuditWarnings st)
          then []
          else
            [ ""
            , "### Prediction Audit Warnings"
            , ""
            , T.intercalate "\n\n" (stPredictionAuditWarnings st)
            ]
   in T.unlines $
        [ "## Active Prediction Slate & Index"
        , ""
        , slateIntroPara
        , ""
        , "### Prediction Scoreboard and Indexes"
        , ""
        , scoreboardPara
        , ""
        , indexLinksPara
        ]
          ++ lastJudgeLines
          ++ recentResLines
          ++ [ ""
             , "### Currently Active Unresolved Predictions (" <> jsonInt (length activePreds) <> "/10)"
             , ""
             ]
          ++ activeLines
          ++ warningSection

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
