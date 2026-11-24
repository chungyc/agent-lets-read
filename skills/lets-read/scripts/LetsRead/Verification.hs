{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LetsRead.Verification
  ( SubagentToolAudit (..)
  , emptySubagentToolAudit
  , loadBannedJargonIO
  , lintReaderCommentary
  , lintStorySummaryBullets
  , parseCriticAndFactSections
  , verifyAndFilterCriticFactBullets
  , renderCriticFeedbackMarkdown
  , processCriticFeedback
  , processCriticFeedbackWithAudit
  , parseResearchNotesSection
  , verifyAndFilterResearchBullets
  , renderCurrentResearchMarkdown
  , extractVerifiedResearchChunkRefs
  , parseToolReceiptTag
  , resolveSubagentToolAudit
  , auditReaderToolUsage
  , auditReaderToolUsageWithResearch
  , auditFactCheckerClaims
  , extractSubagentLogResponse
  , checkSubagentLogUsedSearchWeb
  , checkSubagentLogUsedVerificationTools
  ) where

import Control.Exception (IOException, catch)
import Control.Monad (filterM, forM, when)
import Data.Char (chr, isDigit, isHexDigit)
import Data.List (isPrefixOf, isSuffixOf, maximumBy, nub)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (UTCTime)
import LetsRead.Index (checkStorySummaryStructure, completedStoryArcRollups)
import LetsRead.Predictions (checkPredictionConcisenessIssues, coalesceBulletLines)
import LetsRead.Prompts (writeFactCheckDiscussionPromptFile)
import LetsRead.Types
  ( CriticSection (..)
  , ParsedChunkSummaries (..)
  , PredictionRecord (..)
  , SessionState (..)
  , StoryChunkRecord
  , jsonInt
  , padChunkNumber
  , readTextFileSafe
  , resolveSkillResourcePath
  , stripAfterClosingBracket
  , stripFileUriPrefix
  , stripToolReceiptComments
  , wrapMarkdownBullet
  , wrapMarkdownParagraph
  , wrapMarkdownQuote
  )
import Numeric (readHex)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getHomeDirectory
  , getModificationTime
  , listDirectory
  , removeFile
  )
import System.FilePath (takeDirectory, takeFileName, (</>))

defaultBannedJargon :: [Text]
defaultBannedJargon =
  [ "masterclass"
  , "tour de force"
  , "breathtaking choreography"
  , "elevates the narrative"
  , "philosophical engine"
  , "emotional axis"
  , "encapsulates the thesis"
  , "encapsulates the philosophy"
  , "pitch-perfect"
  , "deftly subverts"
  ]

loadBannedJargonIO :: IO [Text]
loadBannedJargonIO = do
  jargonPath <- resolveSkillResourcePath ("resources" </> "banned_jargon.txt")
  exists <- doesFileExist jargonPath
  if not exists
    then pure defaultBannedJargon
    else do
      raw <- readTextFileSafe jargonPath
      let items =
            [ T.toLower s
            | l <- T.lines raw
            , let s = T.strip l
            , not (T.null s)
            , not ("#" `T.isPrefixOf` s)
            ]
      pure (if null items then defaultBannedJargon else items)

lintReaderCommentary :: [Text] -> Text -> ParsedChunkSummaries -> Maybe PredictionRecord -> [Text]
lintReaderCommentary bannedJargon commText parsedSummaries mNewPred =
  let low = T.toLower commText
      matchedJargon = [w | w <- bannedJargon, w `T.isInfixOf` low]
      jargonWarn =
        if null matchedJargon
          then []
          else
            [ "- **[Deterministic Style Linter (`LetsRead`)]** Your previous commentary used banned book-review/essay jargon ("
                <> T.intercalate ", " ["`\"" <> w <> "\"`" | w <- matchedJargon]
                <> "). Stay *inside* the story as a live forum reader—never step outside to grade or praise the author with review blurbs."
            ]
      extraSubheadings =
        [ l
        | l <- T.lines commText
        , let s = T.strip l
        , "### " `T.isPrefixOf` s
        , let hLow = T.toLower s
        , not ("reader discussion" `T.isInfixOf` hLow)
        ]
      headingWarn =
        if null extraSubheadings
          then []
          else
            [ "- **[Deterministic Style Linter (`LetsRead`)]** Your previous commentary used `###` subheadings (`"
                <> T.intercalate "`, `" (map T.strip extraSubheadings)
                <> "`). Let your commentary flow naturally like a single forum post without `###` section subheadings."
            ]
      stageEmoteCount =
        max 0 (length (T.splitOn "*[" commText) - 1)
          + max 0 (length (T.splitOn "[*" commText) - 1)
      emoteWarn =
        if stageEmoteCount < 3
          then []
          else
            [ "- **[Deterministic Style Linter (`LetsRead`)]** Your previous commentary used "
                <> jsonInt stageEmoteCount
                <> " bracketed `*[...]*` stage-direction emotes. Express excitement, shock, or humor in natural prose rather than repetitive stage-direction emotes or action sportscasting."
            ]
      summaryIssues =
        ( case pcsStory parsedSummaries of
            Nothing -> ["missing `- **[Story | Topics: Topic 1, Topic 2, Topic 3]** <1-line factual story summary>`"]
            Just (ts, sBody) ->
              ["`[Story]` bullet had 0 `Topics:` tags" | null ts]
                ++ [ "`[Story]` summary was " <> jsonInt (T.length sBody) <> " chars (cap: <= 250 chars)"
                   | T.length sBody > 250
                   ]
                ++ [ "`[Story]` summary included reader-prediction/meta boilerplate (`\"leading me to predict\"`/`\"I predict\"`); keep `[Story]` strictly to in-story events and put reaction/gag highlights in `[Entry]`"
                   | let sl = T.toLower sBody
                   , "leading me to predict" `T.isInfixOf` sl || "i predict" `T.isInfixOf` sl
                   ]
        )
          ++ ( case pcsEntry parsedSummaries of
                 Nothing -> ["missing `- **[Entry | Topics: Topic 1, Topic 2, Topic 3]** <1-line liveblog reaction/gags summary>`"]
                 Just (ts, eBody) ->
                   ["`[Entry]` bullet had 0 `Topics:` tags" | null ts]
                     ++ [ "`[Entry]` summary was " <> jsonInt (T.length eBody) <> " chars (cap: <= 250 chars)"
                        | T.length eBody > 250
                        ]
             )
      summaryWarn =
        if null summaryIssues
          then []
          else
            [ "- **[Deterministic Style Linter (`LetsRead`)]** Your `=== CHUNK SUMMARY ===` section had formatting issues ("
                <> T.intercalate "; " summaryIssues
                <> "). Always include both `- **[Story | Topics: Topic 1, Topic 2, Topic 3]** <1-line factual summary of in-story events, <= 250 chars>` and `- **[Entry | Topics: Topic 1, Topic 2, Topic 3]** <1-line summary of your liveblog reaction, standout quotes, or running gags, <= 250 chars>`."
            ]
      predLenWarn =
        case mNewPred of
          Nothing -> []
          Just pr ->
            let issues = checkPredictionConcisenessIssues pr
                cPad = T.pack (padChunkNumber (prOriginChunk pr))
             in if null issues
                  then []
                  else
                    [ "- **[Deterministic Style Linter (`LetsRead`)]** Your prediction `[Predicted Chunk "
                        <> cPad
                        <> "]` exceeded the conciseness budget ("
                        <> T.intercalate "; " issues
                        <> "). On your next turn, keep the prediction body `<= 550 chars` total (`**Clue/Anomaly** <= 150 chars` with no inline quotes, `**Theory** <= 220 chars`, `**Plausible Rival** <= 150 chars`)."
                    ]
   in jargonWarn ++ headingWarn ++ emoteWarn ++ summaryWarn ++ predLenWarn

lintStorySummaryBullets :: [(Text, Text)] -> [StoryChunkRecord] -> [Text]
lintStorySummaryBullets curated storyRecords =
  case checkStorySummaryStructure curated (completedStoryArcRollups storyRecords) of
    Nothing -> []
    Just msg -> ["- **[Deterministic Style Linter (`LetsRead`)]** " <> msg]

isCriticPassLine :: Text -> Bool
isCriticPassLine raw =
  let s = T.toLower (T.strip raw)
      noBullet =
        if "- " `T.isPrefixOf` s || "* " `T.isPrefixOf` s
          then T.strip (T.drop 2 s)
          else s
      cleaned = T.dropAround (\c -> c == '*' || c == '_' || c == '`' || c == '(' || c == ')' || c == '.') noBullet
   in T.null cleaned
        || cleaned == "pass"
        || cleaned == "none"
        || cleaned == "n/a"
        || "no factual" `T.isPrefixOf` cleaned
        || "no issues" `T.isPrefixOf` cleaned

parseCriticAndFactSections :: Text -> ([Text], [Text], [Text])
parseCriticAndFactSections raw =
  let classifyHeader l =
        let s = T.toUpper (T.strip l)
         in if s == "=== CRITIC FEEDBACK ==="
              then Just CritSecGeneral
              else if s == "=== VERIFIED CLAIMS LOG ==="
                then Just CritSecVerifiedLog
                else if s == "=== DISPUTED FACTS & MEMORY CHECKS ===" || s == "=== FACT & MEMORY CORRECTIONS ==="
                  then Just CritSecFacts
                  else if s == "=== PERSONA & STYLE CRITIQUE ===" || s == "=== PERSONA & STYLE COACHING ===" || s == "=== STYLE COACHING ==="
                    then Just CritSecStyle
                    else Nothing
      go _ [] = []
      go curSec (l : ls) =
        case classifyHeader l of
          Just newSec -> go newSec ls
          Nothing -> (curSec, l) : go curSec ls
      tagged = go CritSecGeneral (coalesceBulletLines (T.lines (stripToolReceiptComments raw)))
      isBullet l =
        let t = T.strip l
         in ("- " `T.isPrefixOf` t || "* " `T.isPrefixOf` t) && not (isCriticPassLine t)
      verifiedLogBullets =
        [ T.strip l
        | (sec, l) <- tagged
        , sec == CritSecVerifiedLog
        , isBullet l
        ]
      factBullets =
        [ T.strip l
        | (sec, l) <- tagged
        , sec == CritSecFacts
            || (sec == CritSecGeneral && ("[in-story fact" `T.isInfixOf` T.toLower l || "[external canon" `T.isInfixOf` T.toLower l || "[peer verification query" `T.isInfixOf` T.toLower l))
        , isBullet l
        ]
      styleBullets =
        [ T.strip l
        | (sec, l) <- tagged
        , let low = T.toLower l
        , sec == CritSecStyle
            || (sec == CritSecGeneral && ("[persona" `T.isInfixOf` low || "[what worked" `T.isInfixOf` low || "[where the voice" `T.isInfixOf` low || "[skeptical" `T.isInfixOf` low || "[anti-timidity" `T.isInfixOf` low))
        , isBullet l
        ]
   in (verifiedLogBullets, factBullets, styleBullets)

normalizeForQuoteCheck :: Text -> Text
normalizeForQuoteCheck =
  T.unwords . T.words . T.map normQChar . T.toLower
  where
    normQChar '\x2018' = '\''
    normQChar '\x2019' = '\''
    normQChar '\x201C' = '"'
    normQChar '\x201D' = '"'
    normQChar '\x2014' = '-'
    normQChar '\x2013' = '-'
    normQChar c = c

splitBracketHeader :: Text -> Maybe (Text, Text)
splitBracketHeader line =
  let (_, afterOpen) = T.breakOn "[" line
   in if T.null afterOpen
        then Nothing
        else
          let body = T.drop 1 afterOpen
              scanBalanced :: Int -> [Char] -> Text -> Maybe (Text, Text)
              scanBalanced _ _ t | T.null t = Nothing
              scanBalanced depth acc t =
                case T.uncons t of
                  Nothing -> Nothing
                  Just ('[', rest) -> scanBalanced (depth + 1) ('[' : acc) rest
                  Just (']', rest)
                    | depth <= 1 -> Just (T.pack (reverse acc), T.cons ']' rest)
                    | otherwise -> scanBalanced (depth - 1) (']' : acc) rest
                  Just (c, rest) -> scanBalanced depth (c : acc) rest
           in case scanBalanced 1 [] body of
                Just res -> Just res
                Nothing ->
                  let (inside2, afterBoldClose) = T.breakOn "]**" body
                   in if not (T.null afterBoldClose)
                        then Just (inside2, afterBoldClose)
                        else
                          let (inside3, afterAnyClose) = T.breakOn "]" body
                           in if T.null afterAnyClose
                                then Nothing
                                else Just (inside3, afterAnyClose)

extractBracketHeaderFromBullet :: Text -> Maybe Text
extractBracketHeaderFromBullet line = fst <$> splitBracketHeader line

splitNormalizedQuoteSegments :: Text -> [Text]
splitNormalizedQuoteSegments qTxt =
  let isQuoteDelim c =
        c == '"'
          || c == '\''
          || c == '\x201C'
          || c == '\x201D'
          || c == '\x2018'
          || c == '\x2019'
      rawSegs =
        concatMap (T.splitOn "...") $
          concatMap (T.splitOn "\x2026") $
            T.splitOn "[...]" qTxt
      cleanSeg s = normalizeForQuoteCheck (T.dropAround isQuoteDelim (T.strip s))
   in [cs | s <- rawSegs, let cs = cleanSeg s, not (T.null cs)]

segmentsAppearInOrder :: [Text] -> Text -> Bool
segmentsAppearInOrder [] _ = False
segmentsAppearInOrder segs haystack = go segs haystack
  where
    go [] _ = True
    go (s : rest) remTxt =
      let (_, matchedAndAfter) = T.breakOn s remTxt
       in if T.null matchedAndAfter
            then False
            else go rest (T.drop (T.length s) matchedAndAfter)

verifyQuoteInNormalizedDoc :: Text -> Text -> Bool
verifyQuoteInNormalizedDoc quoteTxt normDoc =
  let normSegs = splitNormalizedQuoteSegments quoteTxt
      hasSubstantialSeg = any (\s -> T.length s >= 6) normSegs
   in not (null normSegs) && hasSubstantialSeg && segmentsAppearInOrder normSegs normDoc

extractSourceAndQuote :: Text -> Maybe (FilePath, Text)
extractSourceAndQuote hdr =
  let parts = map T.strip (T.splitOn "|" hdr)
      findPrefix pfx =
        listToMaybe
          [ T.strip (T.drop (T.length pfx) p)
          | p <- parts
          , pfx `T.isPrefixOf` T.toLower p
          ]
      mSrc =
        case findPrefix "source:" of
          Just s -> Just s
          Nothing -> findPrefix "cited passage:"
      mRawQuote =
        case findPrefix "quote:" of
          Just q -> Just q
          Nothing -> findPrefix "verbatim excerpt:"
      cleanQuotes q =
        let s = T.strip q
            s1 =
              if ("\"" `T.isPrefixOf` s && "\"" `T.isSuffixOf` s && T.length s >= 2)
                || ("\x201C" `T.isPrefixOf` s && "\x201D" `T.isSuffixOf` s && T.length s >= 2)
                then T.drop 1 (T.dropEnd 1 s)
                else T.dropAround (\c -> c == '"' || c == '\x201C' || c == '\x201D') s
         in T.strip s1
   in case (mSrc, mRawQuote) of
        (Just srcTxt, Just qTxt) ->
          let cleanSrc = T.unpack (T.dropAround (\c -> c == '`' || c == '"' || c == '\'') srcTxt)
              cleanQ = cleanQuotes qTxt
           in if null cleanSrc || T.null cleanQ
                then Nothing
                else Just (cleanSrc, cleanQ)
        _ -> Nothing

formatFactBulletAsPeerQuery :: Text -> Text
formatFactBulletAsPeerQuery rawBullet =
  let s = T.strip rawBullet
   in case splitBracketHeader s of
        Nothing -> s
        Just (inside, afterClose) ->
          let bodyAfter = stripAfterClosingBracket afterClose
              parts = map T.strip (T.splitOn "|" inside)
              rewritePart idx p =
                let low = T.toLower p
                 in if idx == (0 :: Int) && ("in-story fact" `T.isPrefixOf` low || "external canon" `T.isPrefixOf` low || "peer verification query" `T.isPrefixOf` low)
                      then "Peer Verification Query"
                      else if "source:" `T.isPrefixOf` low
                        then
                          let val = T.strip (T.drop 7 p)
                           in if "search_web" `T.isInfixOf` T.toLower val
                                then "Fact-Checker Search: " <> val
                                else "Cited Passage: " <> val
                        else if "quote:" `T.isPrefixOf` low
                          then "Verbatim Excerpt: " <> T.strip (T.drop 6 p)
                          else if "work:" `T.isPrefixOf` low
                            then "Reference Work: " <> T.strip (T.drop 5 p)
                            else p
              newHeader = T.intercalate " | " (zipWith rewritePart [0 ..] parts)
           in "- **[" <> newHeader <> "]** " <> bodyAfter

verifyAndFilterCriticFactBullets :: FilePath -> Bool -> [Text] -> IO ([Text], Int)
verifyAndFilterCriticFactBullets sessionDir hasSearchWebCall bullets = do
  results <- forM bullets $ \b -> do
    case extractBracketHeaderFromBullet b of
      Nothing -> pure (Left ())
      Just hdr ->
        let hdrLow = T.toLower hdr
         in if ("external canon" `T.isInfixOf` hdrLow || "fact-checker search" `T.isInfixOf` hdrLow) && "search_web" `T.isInfixOf` hdrLow
              then
                if hasSearchWebCall
                  then pure (Right (formatFactBulletAsPeerQuery b))
                  else pure (Left ())
              else case extractSourceAndQuote hdr of
                Nothing -> pure (Left ())
                Just (relSrc, quoteTxt) -> do
                  let rawSrcTokens =
                        filter (not . null) $
                          map (T.unpack . T.dropAround (\c -> c == '`' || c == '"' || c == '\'' || c == ',' || c == ';') . T.strip) $
                            concatMap (T.splitOn "&") (concatMap (T.splitOn " and ") (T.splitOn "," (T.pack relSrc)))
                      resolveCandidate tok =
                        let baseName = takeFileName tok
                         in if baseName == "current_chunk.md"
                              then sessionDir </> "current_chunk.md"
                              else
                                if "chunk_" `isPrefixOf` baseName && ".md" `isSuffixOf` baseName
                                  then sessionDir </> "chunks" </> baseName
                                  else sessionDir </> tok
                      candidatePaths = map resolveCandidate (if null rawSrcTokens then [relSrc] else rawSrcTokens)
                  existingPaths <- filterM doesFileExist candidatePaths
                  if null existingPaths
                    then pure (Left ())
                    else do
                      chunkContents <- mapM readTextFileSafe existingPaths
                      let normChunk = normalizeForQuoteCheck (T.unlines chunkContents)
                       in if verifyQuoteInNormalizedDoc quoteTxt normChunk
                            then pure (Right (formatFactBulletAsPeerQuery b))
                            else pure (Left ())
  let verified = [b | Right b <- results]
      rejected = length [() | Left () <- results]
  pure (verified, rejected)

renderCriticFeedbackMarkdown :: FilePath -> Int -> Bool -> [Text] -> [Text] -> [Text] -> Text
renderCriticFeedbackMarkdown sessionDir curIdx isArchiveDoc verifiedLog peerQueries styleCoaching =
  let curPad = T.pack (padChunkNumber curIdx)
      styleBlock =
        if null styleCoaching
          then "- *(None flagged on Chunk " <> curPad <> " — persona and style were on target.)*"
          else T.intercalate "\n\n" (map (wrapMarkdownBullet 78) styleCoaching)
      factArchiveSection =
        if not isArchiveDoc
          then []
          else
            [ ""
            , "## Fact-Checker Peer Verification Queries"
            , ""
            , if null peerQueries
                then "- *(None flagged on Chunk " <> curPad <> ".)*"
                else T.intercalate "\n\n" (map (wrapMarkdownBullet 78) peerQueries)
            ]
      verifiedLogSection =
        if not isArchiveDoc || null verifiedLog
          then []
          else
            [ ""
            , "## Fact-Checker Verified Claims Audit Log"
            , ""
            , T.intercalate "\n\n" (map (wrapMarkdownBullet 78) verifiedLog)
            ]
      howToUseQuote =
        wrapMarkdownQuote
          78
          "Read `commentary-critic`'s editorial review of how your previous entry aligned with your Active Persona. Apply useful voice and craft adjustments silently as you write this chunk's commentary (while retaining editorial autonomy over what fits the current scene). Never apologize for, mention, or meta-reference style feedback inside `=== COMMENTARY ===`."
   in T.unlines $
        [ "# Persona & Style Critique Notes (Chunk " <> curPad <> ")"
        , ""
        , "Session Directory: `" <> T.pack sessionDir <> "`"
        , ""
        , "> [!IMPORTANT]"
        , howToUseQuote
        , ""
        , "## Persona & Style Critique"
        , ""
        , styleBlock
        ]
          ++ factArchiveSection
          ++ verifiedLogSection

data SubagentToolAudit = SubagentToolAudit
  { staSource :: !Text
  -- ^ @"transcript"@ | @"parent_log"@ | @"response_header"@ | @"unavailable"@
  , staUsedSearchWeb :: !(Maybe Bool)
  , staUsedVerificationTools :: !(Maybe Bool)
  , staReadFiles :: ![Text]
  , staPriorTranscriptReadFiles :: ![Text]
  , staIsFirstTurnInTranscript :: !(Maybe Bool)
  }
  deriving (Eq, Show)

emptySubagentToolAudit :: SubagentToolAudit
emptySubagentToolAudit =
  SubagentToolAudit
    { staSource = "unavailable"
    , staUsedSearchWeb = Nothing
    , staUsedVerificationTools = Nothing
    , staReadFiles = []
    , staPriorTranscriptReadFiles = []
    , staIsFirstTurnInTranscript = Nothing
    }

isStoryChunkFileRef :: Text -> Maybe Int
isStoryChunkFileRef rawRef =
  let norm = T.map (\c -> if c == '\\' then '/' else c) (T.dropAround (\c -> c == '"' || c == '\'' || c == '`') (T.strip rawRef))
      low = T.toLower norm
      base = T.unpack (snd (T.breakOnEnd "/" norm))
      inExcludedDir = "entries/" `T.isInfixOf` low || "archive/" `T.isInfixOf` low || "predictions/" `T.isInfixOf` low
      isChunkDirOrBare =
        not ("/" `T.isInfixOf` norm)
          || ("/chunks/" <> T.pack base) `T.isSuffixOf` low
          || ("chunks/" <> T.pack base) == low
   in if not inExcludedDir && isChunkDirOrBare && "chunk_" `isPrefixOf` base && ".md" `isSuffixOf` base
        then
          let digits = take (length base - 9) (drop 6 base)
           in if not (null digits) && all isDigit digits
                then case reads digits of
                  [(n, "")] | n >= 1 -> Just n
                  _ -> Nothing
                else Nothing
        else Nothing

isEntryFileRef :: Text -> Maybe Int
isEntryFileRef rawRef =
  let norm = T.map (\c -> if c == '\\' then '/' else c) (T.dropAround (\c -> c == '"' || c == '\'' || c == '`') (T.strip rawRef))
      low = T.toLower norm
      base = T.unpack (snd (T.breakOnEnd "/" norm))
      inEntriesDir = ("/entries/" <> T.pack base) `T.isSuffixOf` low || ("entries/" <> T.pack base) == low
   in if inEntriesDir && "chunk_" `isPrefixOf` base && ".md" `isSuffixOf` base
        then
          let digits = take (length base - 9) (drop 6 base)
           in if not (null digits) && all isDigit digits
                then case reads digits of
                  [(n, "")] | n >= 1 -> Just n
                  _ -> Nothing
                else Nothing
        else Nothing

isPredictionFileRef :: Text -> Maybe Int
isPredictionFileRef rawRef =
  let norm = T.map (\c -> if c == '\\' then '/' else c) (T.dropAround (\c -> c == '"' || c == '\'' || c == '`') (T.strip rawRef))
      low = T.toLower norm
      base = T.unpack (snd (T.breakOnEnd "/" norm))
      inPredsOrBare =
        not ("/" `T.isInfixOf` norm)
          || ("/predictions/" <> T.pack base) `T.isSuffixOf` low
          || ("predictions/" <> T.pack base) == low
   in if inPredsOrBare && "pred_" `isPrefixOf` base && ".md" `isSuffixOf` base
        then
          let digits = take (length base - 8) (drop 5 base)
           in if not (null digits) && all isDigit digits
                then case reads digits of
                  [(n, "")] | n >= 1 -> Just n
                  _ -> Nothing
                else Nothing
        else Nothing

isMemoryArchiveFileRef :: Text -> Maybe (String, Int)
isMemoryArchiveFileRef rawRef =
  let norm = T.map (\c -> if c == '\\' then '/' else c) (T.dropAround (\c -> c == '"' || c == '\'' || c == '`') (T.strip rawRef))
      low = T.toLower norm
      base = T.unpack (snd (T.breakOnEnd "/" norm))
      inMemArcDir =
        ("/archive/memory/" <> T.pack base) `T.isSuffixOf` low
          || ("archive/memory/" <> T.pack base) == low
      parsePfx pfx =
        if pfx `isPrefixOf` base && ".md" `isSuffixOf` base
          then
            let digits = take (length base - length pfx - 3) (drop (length pfx) base)
             in if not (null digits) && all isDigit digits
                  then case reads digits of
                    [(n, "")] | n >= 1 -> Just (pfx, n)
                    _ -> Nothing
                  else Nothing
          else Nothing
   in if not inMemArcDir
        then Nothing
        else case parsePfx "curated_" of
          Just res -> Just res
          Nothing -> parsePfx "chunk_"

isHallOfFameFileRef :: Text -> Bool
isHallOfFameFileRef rawRef =
  let norm = T.map (\c -> if c == '\\' then '/' else c) (T.dropAround (\c -> c == '"' || c == '\'' || c == '`') (T.strip rawRef))
      low = T.toLower norm
   in low == "predictions/hall_of_fame.md" || "/predictions/hall_of_fame.md" `T.isSuffixOf` low || low == "hall_of_fame.md"

isResearchNoneLine :: Text -> Bool
isResearchNoneLine raw =
  let s = T.toLower (T.strip raw)
      noBullet =
        if "- " `T.isPrefixOf` s || "* " `T.isPrefixOf` s
          then T.strip (T.drop 2 s)
          else s
      cleaned = T.dropAround (\c -> c == '*' || c == '_' || c == '`' || c == '(' || c == ')' || c == '.') noBullet
   in T.null cleaned
        || cleaned == "none"
        || cleaned == "pass"
        || cleaned == "n/a"
        || "no prior" `T.isPrefixOf` cleaned
        || "no earlier" `T.isPrefixOf` cleaned
        || "no specific" `T.isPrefixOf` cleaned

parseResearchNotesSection :: Text -> [Text]
parseResearchNotesSection raw =
  let ls = coalesceBulletLines (T.lines (stripToolReceiptComments raw))
      isResHdr l = T.toUpper (T.strip l) == "=== RESEARCH NOTES ==="
      (_, afterHdr) = break isResHdr ls
      targetLines =
        case afterHdr of
          (_ : rest) -> takeWhile (not . isDelimiterHeaderLine) rest
          [] -> ls
      isBullet l =
        let t = T.strip l
         in ("- " `T.isPrefixOf` t || "* " `T.isPrefixOf` t) && not (isResearchNoneLine t)
   in [T.strip l | l <- targetLines, isBullet l]

hasDraftQuarantineLeak :: Text -> Bool
hasDraftQuarantineLeak bullet =
  let low = T.toLower bullet
      forbidden =
        [ "script-writer"
        , "script writer"
        , "draft commentary"
        , "draft prediction"
        , "current_script"
        , "unverified draft"
        , "internal draft"
        ]
   in any (`T.isInfixOf` low) forbidden

verifyAndFilterResearchBullets :: FilePath -> Int -> Bool -> SubagentToolAudit -> [Text] -> IO ([Text], Int)
verifyAndFilterResearchBullets sessionDir curIdx isWrapup researchAudit bullets = do
  let allReadPaths = staReadFiles researchAudit ++ staPriorTranscriptReadFiles researchAudit
      readStoryChunks = nub [n | f <- allReadPaths, Just n <- [isStoryChunkFileRef f]]
      readEntryChunks = nub [n | f <- allReadPaths, Just n <- [isEntryFileRef f]]
      readPredChunks = nub [n | f <- allReadPaths, Just n <- [isPredictionFileRef f]]
      readMemArchives = nub [ pair | f <- allReadPaths, Just pair <- [isMemoryArchiveFileRef f] ]
      readHallOfFame = any isHallOfFameFileRef allReadPaths
      readCurChunk =
        any
          ( \f ->
              let b = takeFileName (stripFileUriPrefix (T.unpack (T.strip f)))
               in b == "current_chunk.md"
          )
          allReadPaths
      hasSearchWebCall = staUsedSearchWeb researchAudit == Just True
      enforceReceipts = staSource researchAudit /= "unavailable"
      maxPriorIdx = if isWrapup then curIdx else curIdx - 1
      resolveResearchTarget srcRaw
        | T.toLower (T.pack (takeFileName srcRaw)) == "current_chunk.md" && not isWrapup =
            Just (sessionDir </> "current_chunk.md", readCurChunk || curIdx `elem` readStoryChunks)
        | isWrapup && isHallOfFameFileRef (T.pack srcRaw) =
            Just (sessionDir </> "predictions" </> "hall_of_fame.md", readHallOfFame)
        | Just n <- isStoryChunkFileRef (T.pack srcRaw)
        , n >= 1 && n <= curIdx =
            let rMatch = n `elem` readStoryChunks || (not isWrapup && n == curIdx && readCurChunk)
             in Just (sessionDir </> "chunks" </> ("chunk_" ++ padChunkNumber n ++ ".md"), rMatch)
        | Just n <- isEntryFileRef (T.pack srcRaw)
        , n >= 1 && n <= maxPriorIdx =
            Just (sessionDir </> "entries" </> ("chunk_" ++ padChunkNumber n ++ ".md"), n `elem` readEntryChunks)
        | Just n <- isPredictionFileRef (T.pack srcRaw)
        , n >= 1 && n <= maxPriorIdx =
            Just (sessionDir </> "predictions" </> ("pred_" ++ padChunkNumber n ++ ".md"), n `elem` readPredChunks)
        | Just (pfx, n) <- isMemoryArchiveFileRef (T.pack srcRaw)
        , n >= 1 && n <= maxPriorIdx =
            Just (sessionDir </> "archive" </> "memory" </> (pfx ++ padChunkNumber n ++ ".md"), (pfx, n) `elem` readMemArchives)
        | otherwise = Nothing
  results <- forM bullets $ \b ->
    if hasDraftQuarantineLeak b
      then pure (Left ())
      else case extractBracketHeaderFromBullet b of
        Nothing -> pure (Left ())
        Just hdr ->
          let hdrLow = T.toLower hdr
           in if "search_web" `T.isInfixOf` hdrLow
                && ("external canon" `T.isInfixOf` hdrLow || "reference" `T.isInfixOf` hdrLow || "source:" `T.isInfixOf` hdrLow)
                then
                  if hasSearchWebCall
                    then pure (Right (T.strip b))
                    else pure (Left ())
                else case extractSourceAndQuote hdr of
                  Nothing -> pure (Left ())
                  Just (relSrc, quoteTxt) ->
                    case resolveResearchTarget relSrc of
                      Nothing -> pure (Left ())
                      Just (targetPath, receiptOk)
                        | enforceReceipts && not receiptOk -> pure (Left ())
                        | otherwise -> do
                            exists <- doesFileExist targetPath
                            if not exists
                              then pure (Left ())
                              else do
                                docTxt <- readTextFileSafe targetPath
                                let normDoc = normalizeForQuoteCheck docTxt
                                 in if verifyQuoteInNormalizedDoc quoteTxt normDoc
                                      then pure (Right (T.strip b))
                                      else pure (Left ())
  let verified = [b | Right b <- results]
      rejected = length [() | Left () <- results]
  pure (verified, rejected)

renderCurrentResearchMarkdown :: FilePath -> Int -> Bool -> [Text] -> Text
renderCurrentResearchMarkdown sessionDir curIdx isWrapup verifiedBullets =
  let titleSuffix =
        if isWrapup
          then "Final Wrapup"
          else "Chunk " <> T.pack (padChunkNumber curIdx)
      notesBlock =
        if null verifiedBullets
          then "- *(No prior-chunk excerpts or external canon notes pulled for this turn.)*"
          else T.intercalate "\n\n" (map (wrapMarkdownBullet 78) verifiedBullets)
   in T.unlines
        [ "# Pre-Pulled Continuity & Canon Reference Packet (" <> titleSuffix <> ")"
        , ""
        , "Session Directory: `" <> T.pack sessionDir <> "`"
        , ""
        , "> [!NOTE]"
        , wrapMarkdownQuote
            78
            "Optional pre-pulled excerpts and external reference notes. Draw on an item only when it naturally connects to what you want to react to—never force callbacks."
        , ""
        , "## Story-Factual Hierarchy"
        , ""
        , "### 1. Explicit Story Text (Highest Authority on This Story)"
        , ""
        , wrapMarkdownParagraph
            78
            "Excerpts from `chunks/chunk_XXXX.md` (together with `current_chunk.md` and verified baseline facts in Bullet 1 of `memory.md`) are primary ground truth for what is true inside *this story* and override all other sources below."
        , ""
        , "### 2. External Canon and Reference Material"
        , ""
        , wrapMarkdownParagraph
            78
            "`search_web` notes establish what external source canon or real-world reference works state (overriding fanon), but never override or fill in unconfirmed facts inside *this story* where the story diverges from canon."
        , ""
        , "### 3. Prior Predictions, Session Entries, and Memory Snapshots"
        , ""
        , wrapMarkdownParagraph
            78
            "Excerpts from `predictions/`, `entries/`, and `archive/memory/` record earlier reader bets, verdicts, gags, and discussions only—never treat earlier reader speculation as established story fact unless confirmed by `chunks/` text."
        , ""
        , "## Verified Reference Notes"
        , ""
        , notesBlock
        ]

extractVerifiedResearchChunkRefs :: Text -> [Int]
extractVerifiedResearchChunkRefs researchDoc =
  nub
    [ n
    | l <- coalesceBulletLines (T.lines researchDoc)
    , Just hdr <- [extractBracketHeaderFromBullet l]
    , Just (srcPath, _) <- [extractSourceAndQuote hdr]
    , Just n <- [isStoryChunkFileRef (T.pack srcPath)]
    ]

extractExplicitStoryChunkRefs :: Text -> [Int]
extractExplicitStoryChunkRefs txt =
  let norm = T.map (\c -> if c == '\\' then '/' else c) txt
      cleaned = T.map (\c -> if isDigit c || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c `elem` ['_', '/', '.'] then c else ' ') norm
   in nub [n | rawTok <- T.words cleaned, let tok = T.dropAround (\c -> c == '.' || c == '/') rawTok, Just n <- [isStoryChunkFileRef tok]]

auditReaderToolUsage :: Int -> Bool -> Text -> SubagentToolAudit -> (Maybe Bool, Int, [Text])
auditReaderToolUsage curIdx shouldRotateRecommended =
  auditReaderToolUsageWithResearch curIdx shouldRotateRecommended []

auditReaderToolUsageWithResearch :: Int -> Bool -> [Int] -> Text -> SubagentToolAudit -> (Maybe Bool, Int, [Text])
auditReaderToolUsageWithResearch curIdx shouldRotateRecommended researchChunkRefs commAndPredText audit =
  let allReadFiles = staReadFiles audit ++ staPriorTranscriptReadFiles audit
      didReadResearchPacket =
        any
          ( \f ->
              takeFileName (stripFileUriPrefix (T.unpack (T.strip f))) == "current_research.md"
          )
          allReadFiles
      creditedResearchChunks =
        if didReadResearchPacket
          then [n | n <- researchChunkRefs, n < curIdx]
          else []
      readPriorChunks = nub [n | f <- staReadFiles audit, Just n <- [isStoryChunkFileRef f], n < curIdx]
      allKnownReadChunks =
        nub $
          [ n
          | f <- allReadFiles
          , Just n <- [isStoryChunkFileRef f]
          , n < curIdx
          ]
            ++ creditedResearchChunks
      callbackCount = length readPriorChunks
   in if staSource audit == "unavailable" || curIdx <= 1
        then (Nothing, callbackCount, [])
        else
          let didReadPrev = (curIdx - 1) `elem` readPriorChunks
              isFreshRotation =
                case staIsFirstTurnInTranscript audit of
                  Just isFirst -> isFirst
                  Nothing -> shouldRotateRecommended
              curPad = T.pack (padChunkNumber curIdx)
              prevPad = T.pack (padChunkNumber (curIdx - 1))
              rotWarn =
                [ "- **[Callback & Continuity Audit (`LetsRead`)]** Newly rotated `blind-reader` on Chunk "
                    <> curPad
                    <> " did not call `read_file` on `chunks/chunk_"
                    <> prevPad
                    <> ".md`. On rotated turns (`Chunk > 1`), read `chunks/chunk_(N-1).md` before writing your response so continuity stays anchored in primary text."
                | isFreshRotation && not didReadPrev
                ]
              unverifiedExplicitRefs =
                [ n
                | n <- extractExplicitStoryChunkRefs commAndPredText
                , n < curIdx
                , n `notElem` allKnownReadChunks
                ]
              citeWarn =
                [ "- **[Callback & Continuity Audit (`LetsRead`)]** Chunk "
                    <> curPad
                    <> " cited earlier story chunk file(s) ("
                    <> T.intercalate ", " ["`chunks/chunk_" <> T.pack (padChunkNumber n) <> ".md`" | n <- unverifiedExplicitRefs]
                    <> ") without a `read_file` receipt. Verify earlier-chunk callbacks via `read_file` on `chunks/chunk_XXXX.md` rather than relying on `memory.md`."
                | not (null unverifiedExplicitRefs)
                ]
           in (Just didReadPrev, callbackCount, rotWarn ++ citeWarn)

auditFactCheckerClaims :: FilePath -> Int -> SubagentToolAudit -> [Text] -> [Text] -> IO ([Text], [Text])
auditFactCheckerClaims sessionDir curIdx audit verifiedLogBullets factBullets = do
  let curChunkPath = sessionDir </> "current_chunk.md"
  hasCurChunk <- doesFileExist curChunkPath
  mCurChunkNorm <-
    if hasCurChunk
      then Just . normalizeForQuoteCheck <$> readTextFileSafe curChunkPath
      else pure Nothing
  let allKnownReadChunks =
        nub
          [ n
          | f <- staReadFiles audit ++ staPriorTranscriptReadFiles audit
          , Just n <- [isStoryChunkFileRef f]
          ]
      hasSearchWebCall = fromMaybe True (staUsedSearchWeb audit)
      extractSourceText hdr =
        let parts = map T.strip (T.splitOn "|" hdr)
            findPrefix pfx =
              listToMaybe
                [ T.strip (T.drop (T.length pfx) p)
                | p <- parts
                , pfx `T.isPrefixOf` T.toLower p
                ]
         in case findPrefix "source:" of
              Just s -> Just s
              Nothing -> findPrefix "cited passage:"
      auditSingleVerifiedLine l =
        let low = T.toLower l
            searchIssue =
              [ "search_web tool was not invoked on this turn"
              | not hasSearchWebCall && "search_web" `T.isInfixOf` low
              ]
            hdrIssues =
              case extractBracketHeaderFromBullet l of
                Nothing -> []
                Just hdr ->
                  let hdrLow = T.toLower (T.strip hdr)
                      isOk = "ok" `T.isPrefixOf` hdrLow
                      mSrcTxt = extractSourceText hdr
                      srcTxt = fromMaybe "" mSrcTxt
                      srcLow = T.toLower srcTxt
                      citedPriorChunks =
                        [ n
                        | n <- extractExplicitStoryChunkRefs srcTxt
                        , n < curIdx
                        ]
                      unverifiedPrior =
                        [ "cited chunks/chunk_" <> T.pack (padChunkNumber n) <> ".md without a read_file receipt"
                        | staSource audit /= "unavailable"
                        , n <- citedPriorChunks
                        , n `notElem` allKnownReadChunks
                        ]
                      curPad = T.pack (padChunkNumber curIdx)
                      citesOnlyCurrentChunk =
                        null citedPriorChunks
                          && not ("search_web" `T.isInfixOf` srcLow)
                          && not ("memory.md" `T.isInfixOf` srcLow)
                          && ( "current_chunk.md" `T.isInfixOf` srcLow
                                 || ("chunk_" <> curPad <> ".md") `T.isInfixOf` srcLow
                             )
                      claimBody =
                        case splitBracketHeader l of
                          Nothing -> ""
                          Just (_, afterClose) -> stripAfterClosingBracket afterClose
                      bodyPriorRefs =
                        [ n
                        | n <- extractExplicitStoryChunkRefs claimBody
                        , n < curIdx
                        ]
                      misusedCurChunkForPriorRef =
                        [ "Source: current_chunk.md cited for claim referencing earlier chunks/chunk_"
                            <> T.pack (padChunkNumber n)
                            <> ".md"
                        | isOk && citesOnlyCurrentChunk
                        , n <- bodyPriorRefs
                        ]
                      misusedCurChunkQuote =
                        case (isOk && citesOnlyCurrentChunk, extractSourceAndQuote hdr, mCurChunkNorm) of
                          (True, Just (_, qTxt), Just normCur) ->
                            let normSegs = splitNormalizedQuoteSegments qTxt
                             in [ "Quote cited under Source: current_chunk.md was not found in current_chunk.md"
                                | not (null normSegs) && not (segmentsAppearInOrder normSegs normCur)
                                ]
                          _ -> []
                      citesMemoryAsPrimary =
                        [ "Source: memory.md cited as primary verification source instead of chunks/chunk_XXXX.md"
                        | isOk
                        , "memory.md" `T.isInfixOf` srcLow
                        , not ("core premise" `T.isInfixOf` T.toLower claimBody)
                        , not ("bullet 1" `T.isInfixOf` T.toLower claimBody)
                        , not ("current_chunk.md" `T.isInfixOf` srcLow)
                        , null citedPriorChunks
                        ]
                   in unverifiedPrior ++ misusedCurChunkForPriorRef ++ misusedCurChunkQuote ++ citesMemoryAsPrimary
            allIssues = searchIssue ++ hdrIssues
            annotatedLine =
              if null allIssues
                then l
                else l <> " *(note: " <> T.intercalate "; " allIssues <> ")*"
         in (annotatedLine, allIssues)
      disputedPriorReadIssues =
        [ "Disputed fact bullet cited chunks/chunk_" <> T.pack (padChunkNumber n) <> ".md without a read_file receipt"
        | staSource audit /= "unavailable"
        , b <- factBullets
        , Just hdr <- [extractBracketHeaderFromBullet b]
        , Just srcTxt <- [extractSourceText hdr]
        , n <- extractExplicitStoryChunkRefs srcTxt
        , n < curIdx
        , n `notElem` allKnownReadChunks
        ]
      auditedPairs = map auditSingleVerifiedLine verifiedLogBullets
      annotatedVerified = map fst auditedPairs
      allWarnings = concatMap snd auditedPairs ++ disputedPriorReadIssues
  pure (annotatedVerified, allWarnings)

processCriticFeedback :: FilePath -> SessionState -> Int -> Bool -> [Text] -> Maybe Text -> Maybe Text -> IO (Bool, Int, Bool, Int, Int)
processCriticFeedback sessionDir st curIdx hasSearchWebCall linterWarnings mRawFactCheck mRawCritic = do
  let syntheticAudit =
        emptySubagentToolAudit
          { staSource = "legacy_bool"
          , staUsedSearchWeb = Just hasSearchWebCall
          }
  (fbW, notesCnt, hasFQ, fqCnt, rejCnt, _) <-
    processCriticFeedbackWithAudit sessionDir st curIdx syntheticAudit linterWarnings mRawFactCheck mRawCritic
  pure (fbW, notesCnt, hasFQ, fqCnt, rejCnt)

processCriticFeedbackWithAudit :: FilePath -> SessionState -> Int -> SubagentToolAudit -> [Text] -> Maybe Text -> Maybe Text -> IO (Bool, Int, Bool, Int, Int, Int)
processCriticFeedbackWithAudit sessionDir st curIdx factAudit linterWarnings mRawFactCheck mRawCritic = do
  let hasSearchWebCall = fromMaybe True (staUsedSearchWeb factAudit)
      (factVerLog1, rawFacts1, rawStyles1) =
        case mRawFactCheck of
          Nothing -> ([], [], [])
          Just txt -> parseCriticAndFactSections txt
      (factVerLog2, rawFacts2, rawStyles2) =
        case mRawCritic of
          Nothing -> ([], [], [])
          Just txt -> parseCriticAndFactSections txt
      rawVerifiedLog = factVerLog1 ++ factVerLog2
      allRawFacts = rawFacts1 ++ rawFacts2
      allRawStyles = rawStyles1 ++ rawStyles2
  (allVerifiedLog, factAuditWarnings) <-
    auditFactCheckerClaims sessionDir curIdx factAudit rawVerifiedLog allRawFacts
  (peerQueries, rejectedCount) <- verifyAndFilterCriticFactBullets sessionDir hasSearchWebCall allRawFacts
  let combinedStyles = linterWarnings ++ allRawStyles
      totalStyleNotes = length combinedStyles
      factQueriesCount = length peerQueries
      hasFactQueries = factQueriesCount > 0
      factAuditWarnCount = length factAuditWarnings
      feedbackPath = sessionDir </> "critic_feedback.md"
      questionsPath = sessionDir </> "current_fact_check_questions.md"
      discPromptPath = sessionDir </> "current_discussion_prompt.md"
      criticArchDir = sessionDir </> "archive" </> "critic"
  when (totalStyleNotes > 0 || hasFactQueries || not (null allVerifiedLog)) $ do
    createDirectoryIfMissing True criticArchDir
    let archivedDoc = renderCriticFeedbackMarkdown sessionDir curIdx True allVerifiedLog peerQueries combinedStyles
    TIO.writeFile (criticArchDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")) archivedDoc
  if hasFactQueries
    then do
      _ <- writeFactCheckDiscussionPromptFile sessionDir st peerQueries
      pure ()
    else do
      qExists <- doesFileExist questionsPath
      when qExists (removeFile questionsPath `catch` (\(_ :: IOException) -> pure ()))
      dExists <- doesFileExist discPromptPath
      when dExists (removeFile discPromptPath `catch` (\(_ :: IOException) -> pure ()))
  if totalStyleNotes == 0
    then do
      fbExists <- doesFileExist feedbackPath
      when fbExists (removeFile feedbackPath `catch` (\(_ :: IOException) -> pure ()))
      pure (False, 0, hasFactQueries, factQueriesCount, rejectedCount, factAuditWarnCount)
    else do
      let rendered = renderCriticFeedbackMarkdown sessionDir curIdx False [] [] combinedStyles
      TIO.writeFile feedbackPath rendered
      pure (True, totalStyleNotes, hasFactQueries, factQueriesCount, rejectedCount, factAuditWarnCount)

-- ---------------------------------------------------------------------------
-- Subagent Transcript JSONL Extraction & Sandbox-Safe Tool-Call Auditing
-- ---------------------------------------------------------------------------

parseJsonStringLiteral :: Text -> Maybe Text
parseJsonStringLiteral txt = go [] txt
  where
    go acc t =
      case T.uncons t of
        Nothing -> Nothing
        Just ('"', _) -> Just (T.pack (reverse acc))
        Just ('\\', rest) ->
          case T.uncons rest of
            Nothing -> Nothing
            Just ('"', r2) -> go ('"' : acc) r2
            Just ('\\', r2) -> go ('\\' : acc) r2
            Just ('/', r2) -> go ('/' : acc) r2
            Just ('b', r2) -> go ('\b' : acc) r2
            Just ('f', r2) -> go ('\f' : acc) r2
            Just ('n', r2) -> go ('\n' : acc) r2
            Just ('r', r2) -> go ('\r' : acc) r2
            Just ('t', r2) -> go ('\t' : acc) r2
            Just ('u', r2) ->
              let hexDigits = T.take 4 r2
                  afterHex = T.drop 4 r2
               in if T.length hexDigits == 4 && T.all isHexDigit hexDigits
                    then case readHex (T.unpack hexDigits) of
                      [(code, "")] -> go (chr code : acc) afterHex
                      _ -> Nothing
                    else Nothing
            Just (c, r2) -> go (c : acc) r2
        Just (c, rest) -> go (c : acc) rest

extractJsonStringField :: Text -> Text -> Maybe Text
extractJsonStringField fieldName line =
  let needle1 = "\"" <> fieldName <> "\":\""
      needle2 = "\"" <> fieldName <> "\": \""
      (_, after1) = T.breakOn needle1 line
   in if not (T.null after1)
        then parseJsonStringLiteral (T.drop (T.length needle1) after1)
        else
          let (_, after2) = T.breakOn needle2 line
           in if not (T.null after2)
                then parseJsonStringLiteral (T.drop (T.length needle2) after2)
                else Nothing

extractSubagentIdFromPath :: FilePath -> Maybe Text
extractSubagentIdFromPath rawPath =
  let clean = stripFileUriPrefix rawPath
      segs = map T.pack (wordsBy (== '/') clean)
      isUuid t = T.length t == 36 && T.count "-" t == 4
   in listToMaybe (filter isUuid segs)
  where
    wordsBy p s =
      case dropWhile p s of
        "" -> []
        s' -> let (w, s'') = break p s' in w : wordsBy p s''

deriveBrainDirFromLogPath :: FilePath -> Maybe FilePath
deriveBrainDirFromLogPath rawPath =
  let clean = stripFileUriPrefix rawPath
      isUuid t = T.length t == 36 && T.count "-" t == 4
      walkUp d
        | d == "/" || d == "." || null d = Nothing
        | isUuid (T.pack (takeFileName d)) =
            let parent = takeDirectory d
             in if parent == d || parent == "." || null parent
                  then Nothing
                  else Just parent
        | otherwise =
            let parent = takeDirectory d
             in if parent == d then Nothing else walkUp parent
   in walkUp clean

-- | Extract the inner response text when a message is a runtime idle wakeup
-- (@Subagent <subId> has gone idle. This was the subagent's most recent response: ...@).
extractIdleSubagentResponse :: Text -> Text -> Maybe Text
extractIdleSubagentResponse subId rawContent =
  let marker = "Subagent " <> subId <> " has gone idle"
      (_, afterSub) = T.breakOn marker rawContent
   in if T.null afterSub
        then Nothing
        else
          let respMarker = "This was the subagent's most recent response:"
              (_, afterResp) = T.breakOn respMarker afterSub
              rawPayload =
                if T.null afterResp
                  then T.drop (T.length marker) afterSub
                  else T.drop (T.length respMarker) afterResp
              withoutClosingTag = fst (T.breakOn "</SYSTEM_MESSAGE>" rawPayload)
              cleaned = T.strip withoutClosingTag
           in if T.null cleaned then Nothing else Just cleaned

findSubagentMessageFromParent :: FilePath -> Text -> IO (Maybe Text)
findSubagentMessageFromParent rawLogPath subId = do
  homeDir <- getHomeDirectory
  let candidateBrainDirs =
        nub $
          [d | Just d <- [deriveBrainDirFromLogPath rawLogPath]]
            ++ [ homeDir </> ".gemini" </> "antigravity" </> "brain"
               , homeDir </> ".gemini" </> "antigravity-cli" </> "brain"
               ]
  existingBrainDirs <- filterM doesDirectoryExist candidateBrainDirs
  if null existingBrainDirs
    then pure Nothing
    else do
      convPairs <- fmap concat $ forM existingBrainDirs $ \brainDir -> do
        convs <- listDirectory brainDir `catch` (\(_ :: IOException) -> pure [])
        pure [(brainDir, c) | c <- convs, T.pack c /= subId]
      let msgDirs =
            nub $
              concat
                [ [ brainDir </> c </> ".system_generated" </> "messages"
                  , brainDir </> c </> ".system_generated" </> "messages" </> "undelivered"
                  ]
                | (brainDir, c) <- convPairs
                ]
      existingMsgDirs <- filterM doesDirectoryExist msgDirs
      allMsgFiles <- concatMapM listJsonFiles existingMsgDirs
      msgMatches <- forM allMsgFiles $ \f -> do
        txt <- readTextFileSafe f
        let senderField = extractJsonStringField "sender" txt
            mContent = extractJsonStringField "content" txt
            tsField = fromMaybe "" (extractJsonStringField "timestamp" txt)
            mPayload =
              case mContent of
                Nothing -> Nothing
                Just c
                  | senderField == Just subId -> Just (T.strip c)
                  | otherwise -> extractIdleSubagentResponse subId c
        case mPayload of
          Just payload | not (T.null payload) -> do
            mtime <- getModificationTime f
            pure (Just ((tsField, mtime, 1 :: Int), payload))
          _ -> pure Nothing

      parentLogMatches <- forM convPairs $ \(brainDir, c) -> do
        let logDir = brainDir </> c </> ".system_generated" </> "logs"
            fullLog = logDir </> "transcript_full.jsonl"
            compactLog = logDir </> "transcript.jsonl"
        hasFullLog <- doesFileExist fullLog
        pPath <-
          if hasFullLog
            then pure fullLog
            else do
              hasCompact <- doesFileExist compactLog
              pure (if hasCompact then compactLog else "")
        if null pPath
          then pure []
          else do
            raw <- readTextFileSafe pPath
            mtime <- getModificationTime pPath
            let marker = "Subagent " <> subId <> " has gone idle"
                matchedLines =
                  [ ( (fromMaybe "" (extractJsonStringField "created_at" l), mtime, idx)
                    , payload
                    )
                  | (idx, l) <- zip [1 :: Int ..] (T.lines raw)
                  , marker `T.isInfixOf` l
                  , Just contentTxt <- [extractJsonStringField "content" l]
                  , Just payload <- [extractIdleSubagentResponse subId contentTxt]
                  ]
            pure matchedLines

      let valid :: [((Text, UTCTime, Int), Text)]
          valid =
            [ m | Just m <- msgMatches ]
              ++ concat parentLogMatches
      if null valid
        then pure Nothing
        else pure (Just (snd (maximumBy (comparing fst) valid)))
  where
    listJsonFiles d = do
      names <- listDirectory d `catch` (\(_ :: IOException) -> pure [])
      pure [d </> n | n <- names, ".json" `isSuffixOf` n]
    concatMapM f xs = fmap concat (mapM f xs)

-- | Parse a @<!-- TOOLS: ... -->@ comment or @[Tools: ...]@ completion-notice
-- receipt tag into @(usedSearchWeb, readFilePaths, bareReadFile)@.
parseToolReceiptTag :: Text -> Maybe (Bool, [Text], Bool)
parseToolReceiptTag raw =
  case extractCommentToolsSpec raw of
    Just spec -> Just (parseToolsSpecBody spec)
    Nothing ->
      case extractBracketToolsSpec raw of
        Just spec -> Just (parseToolsSpecBody spec)
        Nothing -> Nothing
  where
    extractCommentToolsSpec txt =
      listToMaybe
        [ T.strip (T.drop 6 inner)
        | l <- T.lines txt
        , let s = T.strip l
        , "<!--" `T.isPrefixOf` s && "-->" `T.isSuffixOf` s
        , let inner = T.strip (T.dropEnd 3 (T.drop 4 s))
        , "tools:" `T.isPrefixOf` T.toLower inner
        ]

    extractBracketToolsSpec txt =
      let low = T.toLower txt
          (_, afterIdx) = T.breakOn "[tools:" low
       in if T.null afterIdx
            then Nothing
            else
              let startOffset = T.length txt - T.length afterIdx + 7
                  restOrig = T.drop startOffset txt
               in takeUntilMatchingBracket (0 :: Int) False [] restOrig

    takeUntilMatchingBracket _ _ _ t | T.null t = Nothing
    takeUntilMatchingBracket parenDepth inQuotes acc t =
      case T.uncons t of
        Nothing -> Nothing
        Just ('\\', rest)
          | inQuotes ->
              case T.uncons rest of
                Nothing -> Nothing
                Just (c2, r2) -> takeUntilMatchingBracket parenDepth inQuotes (c2 : '\\' : acc) r2
        Just ('"', rest) ->
          takeUntilMatchingBracket parenDepth (not inQuotes) ('"' : acc) rest
        Just ('(', rest)
          | not inQuotes ->
              takeUntilMatchingBracket (parenDepth + 1) inQuotes ('(' : acc) rest
        Just (')', rest)
          | not inQuotes && parenDepth > 0 ->
              takeUntilMatchingBracket (parenDepth - 1) inQuotes (')' : acc) rest
        Just (']', _)
          | not inQuotes && parenDepth == 0 ->
              Just (T.strip (T.pack (reverse acc)))
        Just (c, rest) ->
          takeUntilMatchingBracket parenDepth inQuotes (c : acc) rest

    splitOutsideQuotes :: (Char -> Bool) -> Text -> [Text]
    splitOutsideQuotes isSep = go (0 :: Int) False []
      where
        flush cur =
          let tok = T.strip (T.pack (reverse cur))
           in [tok | not (T.null tok)]
        go _ _ cur s
          | T.null s = flush cur
        go pDepth inQ cur s =
          case T.uncons s of
            Nothing -> flush cur
            Just ('"', r) -> go pDepth (not inQ) ('"' : cur) r
            Just ('(', r) | not inQ -> go (pDepth + 1) inQ ('(' : cur) r
            Just (')', r) | not inQ && pDepth > 0 -> go (pDepth - 1) inQ (')' : cur) r
            Just (c, r)
              | not inQ && pDepth == 0 && isSep c ->
                  flush cur ++ go pDepth inQ [] r
              | otherwise ->
                  go pDepth inQ (c : cur) r

    cleanPathTok :: Text -> Text
    cleanPathTok =
      T.strip . T.dropAround (\c -> c == '"' || c == '\'' || c == '`') . T.strip

    parseToolsSpecBody :: Text -> (Bool, [Text], Bool)
    parseToolsSpecBody spec =
      let trimmed = T.strip spec
          low = T.toLower trimmed
       in if T.null trimmed || low == "none" || low == "n/a"
            then (False, [], False)
            else
              let items = splitOutsideQuotes (\c -> c == ',' || c == ';') trimmed
                  usedSearch =
                    any
                      ( \it ->
                          let il = T.toLower it
                           in "search_web" `T.isInfixOf` il
                                && not ("no search_web" `T.isInfixOf` il)
                                && not ("search_web: false" `T.isInfixOf` il)
                                && not ("search_web=false" `T.isInfixOf` il)
                      )
                      items
                  parseItem it =
                    let il = T.toLower (T.strip it)
                     in if "read_file" `T.isPrefixOf` il
                          then
                            let afterRf = T.strip (T.drop 9 (T.strip it))
                             in if "(" `T.isPrefixOf` afterRf && ")" `T.isSuffixOf` afterRf
                                  then
                                    let inside = T.dropEnd 1 (T.drop 1 afterRf)
                                        ps = filter (not . T.null) (map cleanPathTok (splitOutsideQuotes (\c -> c == ',' || c == ';') inside))
                                     in (ps, null ps)
                                  else ([], True)
                          else
                            if "search_web" `T.isPrefixOf` il
                              then ([], False)
                              else
                                let cleaned = cleanPathTok it
                                 in if ".md" `T.isSuffixOf` T.toLower cleaned
                                      then ([cleaned], False)
                                      else ([], False)
                  parsedItems = map parseItem items
                  allFiles = nub (concatMap fst parsedItems)
                  bareRead = any snd parsedItems
               in (usedSearch, allFiles, bareRead)

isTurnPromptFilePath :: Text -> Bool
isTurnPromptFilePath rawP =
  takeFileName (stripFileUriPrefix (T.unpack (T.strip rawP)))
    `elem` [ "current_prompt.md"
           , "current_script_prompt.md"
           , "current_research_prompt.md"
           , "current_discussion_prompt.md"
           , "current_fact_check_prompt.md"
           , "current_judge_prompt.md"
           , "current_critic_prompt.md"
           , "current_topic_prompt.md"
           ]

auditFromReceiptTuple :: Text -> (Bool, [Text], Bool) -> SubagentToolAudit
auditFromReceiptTuple src (usedSearch, files, bareRead) =
  let nonPromptFiles = filter (not . isTurnPromptFilePath) files
      usedVerify = usedSearch || not (null nonPromptFiles) || bareRead
   in SubagentToolAudit
        { staSource = src
        , staUsedSearchWeb = Just usedSearch
        , staUsedVerificationTools = Just usedVerify
        , staReadFiles = files
        , staPriorTranscriptReadFiles = []
        , staIsFirstTurnInTranscript = Nothing
        }

extractReadFileCallsFromPlannerLine :: Text -> (Bool, [Text])
extractReadFileCallsFromPlannerLine line =
  let segs1 = T.splitOn "\"name\":\"read_file\"" line
      afterCalls =
        case segs1 of
          (_ : rs@(_ : _)) -> concatMap (T.splitOn "\"name\": \"read_file\"") rs
          _ ->
            case T.splitOn "\"name\": \"read_file\"" line of
              (_ : rs) -> rs
              [] -> []
      extractPathFromSeg seg =
        let beforeNextTool = fst (T.breakOn "\"name\":" seg)
            mRawPath =
              case extractJsonStringField "Path" beforeNextTool of
                Just p -> Just p
                Nothing -> extractJsonStringField "path" beforeNextTool
         in case mRawPath of
              Nothing -> Nothing
              Just p ->
                let cleaned = T.pack (stripFileUriPrefix (T.unpack (T.strip (T.dropAround (== '"') (T.strip p)))))
                 in if T.null cleaned then Nothing else Just cleaned
      paths = [p | seg <- afterCalls, Just p <- [extractPathFromSeg seg]]
   in (not (null afterCalls), paths)

isolateLatestTurnLines :: [Text] -> [Text]
isolateLatestTurnLines allRevLines =
  let isTurnStart l =
        let t = extractJsonStringField "type" l
         in t == Just "SYSTEM_MESSAGE" || t == Just "USER_INPUT"
      nonEmptyRevLines = filter (not . T.null . T.strip) allRevLines
   in takeWhile (not . isTurnStart) nonEmptyRevLines

isDelimiterHeaderLine :: Text -> Bool
isDelimiterHeaderLine rawLine =
  let s = T.toUpper (T.strip (T.dropAround (\c -> c == '`' || c == '*') (T.strip rawLine)))
   in s
        `elem` [ "=== COMMENTARY ==="
               , "=== DRAFT COMMENTARY ==="
               , "=== DRAFT PREDICTION ==="
               , "=== RESEARCH NOTES ==="
               , "=== UPDATED MEMORY ==="
               , "=== PREDICTION UPDATES ==="
               , "=== PREDICTION JUDGMENTS ==="
               , "=== CONDITIONAL RETIREMENTS ==="
               , "=== CONDITIONAL RETIREMENT ==="
               , "=== RETIREMENTS ==="
               , "=== VERIFIED CLAIMS LOG ==="
               , "=== CRITIC FEEDBACK ==="
               , "=== DISPUTED FACTS & MEMORY CHECKS ==="
               , "=== FACT & MEMORY CORRECTIONS ==="
               , "=== PERSONA & STYLE CRITIQUE ==="
               , "=== PERSONA & STYLE COACHING ==="
               , "=== STYLE COACHING ==="
               , "=== CHUNK SUMMARY ==="
               , "=== TOPIC MERGES ==="
               , "=== FINAL WRAPUP ==="
               ]

isCompletionNoticeOnly :: Text -> Bool
isCompletionNoticeOnly raw =
  let ls = filter (not . T.null) (map T.strip (T.lines raw))
      low = T.toLower (T.strip raw)
      hasDelimiter = any isDelimiterHeaderLine ls
   in not hasDelimiter
        && length ls <= 2
        && ( "done:" `T.isPrefixOf` low
               || "completed:" `T.isPrefixOf` low
               || ("wrote " `T.isInfixOf` low && "_response.md" `T.isInfixOf` low)
           )

resolveTranscriptTargetPath :: FilePath -> IO FilePath
resolveTranscriptTargetPath rawLogPath = do
  let cleanPath = stripFileUriPrefix rawLogPath
      fullCandidate = takeDirectory cleanPath </> "transcript_full.jsonl"
  hasFull <- doesFileExist fullCandidate
  if hasFull
    then pure fullCandidate
    else do
      hasClean <- doesFileExist cleanPath
      pure (if hasClean then cleanPath else "")

-- | Resolve subagent tool-usage telemetry with 3-tier sandbox compatibility:
--
-- 1. Direct child transcript (@transcript_full.jsonl@ / @transcript.jsonl@) when accessible.
-- 2. @<!-- TOOLS: ... -->@ header comment inside the freshly written response file.
-- 3. Mounted parent/caller @<brain>/<caller_id>/.system_generated/@ logs & messages
--    (including @[Tools: ...]@ tags on 1-line completion notices) when the response
--    file omitted @<!-- TOOLS: ... -->@ or was not provided.
resolveSubagentToolAudit :: Maybe FilePath -> Maybe Text -> IO SubagentToolAudit
resolveSubagentToolAudit mRawLogPath mRawResponseText = do
  targetPath <-
    case mRawLogPath of
      Nothing -> pure ""
      Just lp -> resolveTranscriptTargetPath lp
  if not (null targetPath)
    then do
      raw <- readTextFileSafe targetPath
      let allLines = filter (not . T.null . T.strip) (T.lines raw)
          isTurnStart l =
            let t = extractJsonStringField "type" l
             in t == Just "SYSTEM_MESSAGE" || t == Just "USER_INPUT"
          turnStartCount = length (filter isTurnStart allLines)
          revLines = reverse allLines
          currentTurnLines = isolateLatestTurnLines revLines
          priorTurnLines = drop (length currentTurnLines) revLines
          isPlanner l = extractJsonStringField "type" l == Just "PLANNER_RESPONSE"
          curPlannerLines = filter isPlanner currentTurnLines
          priorPlannerLines = filter isPlanner priorTurnLines
          hasSearchCall l =
            "\"name\":\"search_web\"" `T.isInfixOf` l || "\"name\": \"search_web\"" `T.isInfixOf` l
          usedSearch = any hasSearchCall curPlannerLines
          curReadPairs = map extractReadFileCallsFromPlannerLine curPlannerLines
          hasAnyReadCall = any fst curReadPairs
          curReadPaths = nub (concatMap snd curReadPairs)
          priorReadPaths = nub (concatMap (snd . extractReadFileCallsFromPlannerLine) priorPlannerLines)
          bareRead = hasAnyReadCall && null curReadPaths
          nonPromptReads = filter (not . isTurnPromptFilePath) curReadPaths
          usedVerify = usedSearch || not (null nonPromptReads) || bareRead
      pure
        SubagentToolAudit
          { staSource = "transcript"
          , staUsedSearchWeb = Just usedSearch
          , staUsedVerificationTools = Just usedVerify
          , staReadFiles = curReadPaths
          , staPriorTranscriptReadFiles = priorReadPaths
          , staIsFirstTurnInTranscript = Just (turnStartCount <= 1)
          }
    else
      case mRawResponseText >>= parseToolReceiptTag of
        Just tup -> pure (auditFromReceiptTuple "response_header" tup)
        Nothing -> do
          mParentAudit <-
            case mRawLogPath >>= extractSubagentIdFromPath of
              Nothing -> pure Nothing
              Just subId -> do
                let rawLp = fromMaybe "" mRawLogPath
                mMsg <- findSubagentMessageFromParent rawLp subId
                case mMsg of
                  Nothing -> pure Nothing
                  Just msg ->
                    case parseToolReceiptTag msg of
                      Just tup -> pure (Just (auditFromReceiptTuple "parent_log" tup))
                      Nothing
                        | isCompletionNoticeOnly msg -> pure Nothing
                        | otherwise ->
                            let low = T.toLower msg
                                hasSW = "search_web" `T.isInfixOf` low
                                hasRF = "read_file" `T.isInfixOf` low
                             in pure
                                  ( Just
                                      SubagentToolAudit
                                        { staSource = "parent_log"
                                        , staUsedSearchWeb = Just hasSW
                                        , staUsedVerificationTools = Just (hasSW || hasRF)
                                        , staReadFiles = []
                                        , staPriorTranscriptReadFiles = []
                                        , staIsFirstTurnInTranscript = Nothing
                                        }
                                  )
          pure (fromMaybe emptySubagentToolAudit mParentAudit)

checkSubagentLogUsedSearchWeb :: FilePath -> IO (Maybe Bool)
checkSubagentLogUsedSearchWeb rawLogPath =
  staUsedSearchWeb <$> resolveSubagentToolAudit (Just rawLogPath) Nothing

checkSubagentLogUsedVerificationTools :: FilePath -> IO (Maybe Bool)
checkSubagentLogUsedVerificationTools rawLogPath =
  staUsedVerificationTools <$> resolveSubagentToolAudit (Just rawLogPath) Nothing

extractSubagentLogResponse :: FilePath -> IO (Maybe Text)
extractSubagentLogResponse rawLogPath = do
  targetPath <- resolveTranscriptTargetPath rawLogPath
  if null targetPath
    then case extractSubagentIdFromPath rawLogPath of
      Just subId -> do
        mMsg <- findSubagentMessageFromParent rawLogPath subId
        case mMsg of
          Just msg | not (isCompletionNoticeOnly msg) -> pure (Just msg)
          _ -> pure Nothing
      Nothing -> pure Nothing
    else do
      raw <- readTextFileSafe targetPath
      let isPlannerResponseLine l =
            extractJsonStringField "type" l == Just "PLANNER_RESPONSE"
          allRevLines = reverse (T.lines raw)
          revLines = filter isPlannerResponseLine (isolateLatestTurnLines allRevLines)
          lineTexts l =
            [ T.strip m
            | Just m <-
                [ extractJsonStringField "Content" l
                , extractJsonStringField "Message" l
                , extractJsonStringField "content" l
                ]
            , not (T.null (T.strip m))
            , not (isCompletionNoticeOnly m)
            ]
          allCandidates = concatMap lineTexts revLines
          hasDelimiters t = any isDelimiterHeaderLine (T.lines t)
          writeFileCandidates =
            [ T.strip m
            | l <- revLines
            , Just m <- [extractJsonStringField "Content" l]
            , not (T.null (T.strip m))
            , not (isCompletionNoticeOnly m)
            ]
          sendMsgCandidates =
            [ T.strip m
            | l <- revLines
            , Just m <- [extractJsonStringField "Message" l]
            , not (T.null (T.strip m))
            , not (isCompletionNoticeOnly m)
            ]
          preferred =
            filter hasDelimiters writeFileCandidates
              ++ filter hasDelimiters sendMsgCandidates
              ++ filter hasDelimiters allCandidates
      case preferred of
        (latest : _) -> pure (Just latest)
        [] -> pure Nothing
