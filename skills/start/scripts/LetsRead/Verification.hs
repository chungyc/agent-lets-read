{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LetsRead.Verification
  ( loadBannedJargonIO
  , lintReaderCommentary
  , parseCriticAndFactSections
  , verifyAndFilterCriticFactBullets
  , renderCriticFeedbackMarkdown
  , processCriticFeedback
  , extractSubagentLogResponse
  , checkSubagentLogUsedSearchWeb
  , checkSubagentLogUsedVerificationTools
  ) where

import Control.Exception (IOException, catch)
import Control.Monad (filterM, forM, when)
import Data.Char (chr, isHexDigit)
import Data.List (isPrefixOf, isSuffixOf, maximumBy, nub)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Predictions (coalesceBulletLines)
import LetsRead.Prompts (writeFactCheckDiscussionPromptFile)
import LetsRead.Types
  ( CriticSection (..)
  , ParsedChunkSummaries (..)
  , PredictionRecord (..)
  , SessionState (..)
  , jsonInt
  , padChunkNumber
  , readTextFileSafe
  , resolveSkillResourcePath
  , stripFileUriPrefix
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
                ++ [ "`[Story]` summary included reader-prediction/meta boilerplate (`\"leading me to predict\"`/`\"I predict\"`); keep `[Story]` strictly to in-story events and put reaction/gag highlights in `[Entry]`"
                   | let sl = T.toLower sBody
                   , "leading me to predict" `T.isInfixOf` sl || "i predict" `T.isInfixOf` sl
                   ]
        )
          ++ ( case pcsEntry parsedSummaries of
                 Nothing -> ["missing `- **[Entry | Topics: Topic 1, Topic 2, Topic 3]** <1-line liveblog reaction/gags summary>`"]
                 Just (ts, _) -> ["`[Entry]` bullet had 0 `Topics:` tags" | null ts]
             )
      summaryWarn =
        if null summaryIssues
          then []
          else
            [ "- **[Deterministic Style Linter (`LetsRead`)]** Your `=== CHUNK SUMMARY ===` section had formatting issues ("
                <> T.intercalate "; " summaryIssues
                <> "). Always include both `- **[Story | Topics: Topic 1, Topic 2, Topic 3]** <1-line factual summary of in-story events>` and `- **[Entry | Topics: Topic 1, Topic 2, Topic 3]** <1-line summary of your liveblog reaction, standout quotes, or running gags>`."
            ]
      predLenWarn =
        case mNewPred of
          Nothing -> []
          Just pr ->
            let bodyLen = T.length (prRawBody pr)
                clueLen = T.length (prClue pr)
                theoryLen = T.length (prTheory pr)
                rivalLen = T.length (prRival pr)
                clueHasQuote = T.any (\c -> c == '"' || c == '\x201C' || c == '\x201D') (prClue pr)
                issues =
                  [ "total body was " <> jsonInt bodyLen <> " chars (cap: <= 450 chars)" | bodyLen > 450 ]
                    ++ [ "`**Clue/Anomaly**` was " <> jsonInt clueLen <> " chars (cap: <= 120 chars)" | clueLen > 120 ]
                    ++ [ "`**Clue/Anomaly**` contained inline quotation marks (summarize the detail in 1 short clause without quoting)" | clueHasQuote ]
                    ++ [ "`**Theory**` was " <> jsonInt theoryLen <> " chars (cap: <= 160 chars)" | theoryLen > 160 ]
                    ++ [ "`**Plausible Rival**` was " <> jsonInt rivalLen <> " chars (cap: <= 120 chars)" | rivalLen > 120 ]
                cPad = T.pack (padChunkNumber (prOriginChunk pr))
             in if null issues
                  then []
                  else
                    [ "- **[Deterministic Style Linter (`LetsRead`)]** Your prediction `[Predicted Chunk "
                        <> cPad
                        <> "]` exceeded the conciseness budget ("
                        <> T.intercalate "; " issues
                        <> "). On your next turn, keep the prediction body `<= 450 chars` total (`**Clue/Anomaly** <= 120 chars` with no inline quotes, `**Theory** <= 160 chars` stating 1 direct outcome, `**Plausible Rival** <= 120 chars`)."
                    ]
   in jargonWarn ++ headingWarn ++ emoteWarn ++ summaryWarn ++ predLenWarn

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
      tagged = go CritSecGeneral (coalesceBulletLines (T.lines raw))
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

extractBracketHeaderFromBullet :: Text -> Maybe Text
extractBracketHeaderFromBullet line =
  let (_, afterOpen) = T.breakOn "[" line
   in if T.null afterOpen
        then Nothing
        else
          let (inside, afterClose) = T.breakOn "]" (T.drop 1 afterOpen)
           in if T.null afterClose then Nothing else Just inside

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
      (_, afterOpen) = T.breakOn "[" s
      (inside, afterClose) = T.breakOn "]" (T.drop 1 afterOpen)
   in if T.null afterOpen || T.null afterClose
        then s
        else
          let bodyAfter = T.strip (T.dropWhile (\c -> c == '*' || c == ':') (T.drop 1 afterClose))
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
                          rawSegs = concatMap (T.splitOn "...") (T.splitOn "[...]" quoteTxt)
                          normSegs = [normalizeForQuoteCheck s | s <- rawSegs, not (T.null (T.strip s))]
                          hasSubstantialSeg = any (\s -> T.length s >= 6) normSegs
                          allMatch = not (null normSegs) && hasSubstantialSeg && all (`T.isInfixOf` normChunk) normSegs
                       in if allMatch
                            then pure (Right (formatFactBulletAsPeerQuery b))
                            else pure (Left ())
  let verified = [b | Right b <- results]
      rejected = length [() | Left () <- results]
  pure (verified, rejected)

renderCriticFeedbackMarkdown :: FilePath -> Int -> Bool -> [Text] -> [Text] -> [Text] -> Text
renderCriticFeedbackMarkdown sessionDir curIdx isArchiveDoc verifiedLog peerQueries styleCoaching =
  let curPad = T.pack (padChunkNumber curIdx)
      styleLines =
        if null styleCoaching
          then ["- *(None flagged on Chunk " <> curPad <> " — persona and style were on target.)*"]
          else styleCoaching
      factArchiveSection =
        if not isArchiveDoc
          then []
          else
            [ ""
            , "## Fact-Checker Peer Verification Queries (Delivered via Pre-Next `Reader Discussion`)"
            , ""
            ]
              ++ (if null peerQueries then ["- *(None flagged on Chunk " <> curPad <> ".)*"] else peerQueries)
      verifiedLogSection =
        if not isArchiveDoc || null verifiedLog
          then []
          else
            [ ""
            , "## Fact-Checker Verified Claims Audit Log"
            , ""
            ]
              ++ verifiedLog
   in T.unlines $
        [ "# Persona & Style Critique Notes (From Chunk " <> curPad <> ")"
        , ""
        , "*Session Directory*: `" <> T.pack sessionDir <> "`"
        , ""
        , "> [!IMPORTANT]"
        , "> **HOW TO USE THIS FILE**:"
        , "> Read `commentary-critic`'s editorial review of how your previous entry aligned with your Active Persona. Apply useful voice and craft adjustments **silently** as you write this chunk's commentary (while retaining editorial autonomy over what fits the current scene). **NEVER** apologize for, mention, or meta-reference style/coaching feedback inside `=== COMMENTARY ===`."
        , ""
        , "## Persona & Style Critique (Apply Silently — Never Mention in Commentary)"
        , ""
        ]
          ++ styleLines
          ++ factArchiveSection
          ++ verifiedLogSection

processCriticFeedback :: FilePath -> SessionState -> Int -> Bool -> [Text] -> Maybe Text -> Maybe Text -> IO (Bool, Int, Bool, Int, Int)
processCriticFeedback sessionDir st curIdx hasSearchWebCall linterWarnings mRawFactCheck mRawCritic = do
  let (factVerLog1, rawFacts1, rawStyles1) =
        case mRawFactCheck of
          Nothing -> ([], [], [])
          Just txt -> parseCriticAndFactSections txt
      (factVerLog2, rawFacts2, rawStyles2) =
        case mRawCritic of
          Nothing -> ([], [], [])
          Just txt -> parseCriticAndFactSections txt
      annotateSearchWeb l
        | not hasSearchWebCall && "search_web" `T.isInfixOf` T.toLower l =
            l <> " *(note: search_web tool was not invoked on this turn)*"
        | otherwise = l
      allVerifiedLog = map annotateSearchWeb (factVerLog1 ++ factVerLog2)
      allRawFacts = rawFacts1 ++ rawFacts2
      allRawStyles = rawStyles1 ++ rawStyles2
  (peerQueries, rejectedCount) <- verifyAndFilterCriticFactBullets sessionDir hasSearchWebCall allRawFacts
  let combinedStyles = linterWarnings ++ allRawStyles
      totalStyleNotes = length combinedStyles
      factQueriesCount = length peerQueries
      hasFactQueries = factQueriesCount > 0
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
      pure (False, 0, hasFactQueries, factQueriesCount, rejectedCount)
    else do
      let rendered = renderCriticFeedbackMarkdown sessionDir curIdx False [] [] combinedStyles
      TIO.writeFile feedbackPath rendered
      pure (True, totalStyleNotes, hasFactQueries, factQueriesCount, rejectedCount)

-- ---------------------------------------------------------------------------
-- Subagent Transcript JSONL Extraction & Tool-Call Auditing
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
      msgDirs <- fmap concat $ forM existingBrainDirs $ \brainDir -> do
        convs <- listDirectory brainDir `catch` (\(_ :: IOException) -> pure [])
        pure $
          concat
            [ [ brainDir </> c </> ".system_generated" </> "messages"
              , brainDir </> c </> ".system_generated" </> "messages" </> "undelivered"
              ]
            | c <- convs
            ]
      existingMsgDirs <- filterM doesDirectoryExist (nub msgDirs)
      allMsgFiles <- concatMapM listJsonFiles existingMsgDirs
      matches <- forM allMsgFiles $ \f -> do
        txt <- readTextFileSafe f
        let senderField = extractJsonStringField "sender" txt
            contentField = extractJsonStringField "content" txt
            tsField = fromMaybe "" (extractJsonStringField "timestamp" txt)
        if senderField == Just subId && isJust contentField
          then do
            mtime <- getModificationTime f
            pure (Just ((tsField, mtime), fromMaybe "" contentField))
          else pure Nothing
      let valid = [ (k, c) | Just (k, c) <- matches, not (T.null c) ]
      if null valid
        then pure Nothing
        else pure (Just (snd (maximumBy (comparing fst) valid)))
  where
    listJsonFiles d = do
      names <- listDirectory d `catch` (\(_ :: IOException) -> pure [])
      pure [d </> n | n <- names, ".json" `isSuffixOf` n]
    concatMapM f xs = fmap concat (mapM f xs)

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
               , "=== UPDATED MEMORY ==="
               , "=== PREDICTION UPDATES ==="
               , "=== PREDICTION JUDGMENTS ==="
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

checkSubagentLogUsedSearchWeb :: FilePath -> IO (Maybe Bool)
checkSubagentLogUsedSearchWeb rawLogPath = do
  let cleanPath = stripFileUriPrefix rawLogPath
      fullCandidate = takeDirectory cleanPath </> "transcript_full.jsonl"
  hasFull <- doesFileExist fullCandidate
  targetPath <-
    if hasFull
      then pure fullCandidate
      else do
        hasClean <- doesFileExist cleanPath
        if hasClean
          then pure cleanPath
          else pure ""
  if null targetPath
    then case extractSubagentIdFromPath rawLogPath of
      Nothing -> pure Nothing
      Just subId -> do
        mMsg <- findSubagentMessageFromParent rawLogPath subId
        case mMsg of
          Nothing -> pure Nothing
          Just msg
            | "search_web" `T.isInfixOf` T.toLower msg -> pure (Just True)
            | isCompletionNoticeOnly msg -> pure Nothing
            | otherwise -> pure (Just False)
    else do
      raw <- readTextFileSafe targetPath
      let revLines = reverse (T.lines raw)
          currentTurnLines = isolateLatestTurnLines revLines
          hasSearchCall l =
            extractJsonStringField "type" l == Just "PLANNER_RESPONSE"
              && ("\"name\":\"search_web\"" `T.isInfixOf` l || "\"name\": \"search_web\"" `T.isInfixOf` l)
      pure (Just (any hasSearchCall currentTurnLines))

checkSubagentLogUsedVerificationTools :: FilePath -> IO (Maybe Bool)
checkSubagentLogUsedVerificationTools rawLogPath = do
  let cleanPath = stripFileUriPrefix rawLogPath
      fullCandidate = takeDirectory cleanPath </> "transcript_full.jsonl"
  hasFull <- doesFileExist fullCandidate
  targetPath <-
    if hasFull
      then pure fullCandidate
      else do
        hasClean <- doesFileExist cleanPath
        if hasClean
          then pure cleanPath
          else pure ""
  if null targetPath
    then case extractSubagentIdFromPath rawLogPath of
      Nothing -> pure Nothing
      Just subId -> do
        mMsg <- findSubagentMessageFromParent rawLogPath subId
        case mMsg of
          Nothing -> pure Nothing
          Just msg ->
            let low = T.toLower msg
             in if "read_file" `T.isInfixOf` low || "search_web" `T.isInfixOf` low
                  then pure (Just True)
                  else
                    if isCompletionNoticeOnly msg
                      then pure Nothing
                      else pure (Just False)
    else do
      raw <- readTextFileSafe targetPath
      let revLines = reverse (T.lines raw)
          currentTurnLines = isolateLatestTurnLines revLines
          hasVerifyCall l =
            extractJsonStringField "type" l == Just "PLANNER_RESPONSE"
              && ( "\"name\":\"read_file\"" `T.isInfixOf` l
                     || "\"name\": \"read_file\"" `T.isInfixOf` l
                     || "\"name\":\"search_web\"" `T.isInfixOf` l
                     || "\"name\": \"search_web\"" `T.isInfixOf` l
                 )
      pure (Just (any hasVerifyCall currentTurnLines))

extractSubagentLogResponse :: FilePath -> IO (Maybe Text)
extractSubagentLogResponse rawLogPath = do
  let cleanPath = stripFileUriPrefix rawLogPath
      fullCandidate = takeDirectory cleanPath </> "transcript_full.jsonl"
  hasFull <- doesFileExist fullCandidate
  targetPath <-
    if hasFull
      then pure fullCandidate
      else do
        hasClean <- doesFileExist cleanPath
        if hasClean
          then pure cleanPath
          else pure ""
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
