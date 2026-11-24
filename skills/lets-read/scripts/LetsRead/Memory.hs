{-# LANGUAGE OverloadedStrings #-}

module LetsRead.Memory
  ( defaultCuratedMemory
  , isPlaceholderSection
  , parseMemorySections
  , mergeCuratedNarrativeMemory
  , mergeCuratedNarrativeMemoryForTurn
  , resolveAndAuditTurn
  , renderCuratedSections
  , checkMemoryCompaction
  , cleanChunkSummary
  , parseChunkSummaries
  , extractFallbackSummary
  , parseCombinedResponse
  , stripLeadingChunkHeading
  , stripTrailingEntryRule
  , formatUserQuote
  , formatPeerFactCheckQuote
  , syncPredictionsDirectory
  , renderMemoryMarkdown
  , syncMemoryAndArchives
  , rebuildMasterLog
  ) where

import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum)
import Data.List (isPrefixOf, isSuffixOf, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (parseMarkdownHeading)
import LetsRead.Index
  ( collectCanonicalSessionTopics
  , completedStoryArcRollups
  , entryIndexSpec
  , predictionIndexSpec
  , renderStoryBullet
  , storyIndexSpec
  , syncMultiLayerIndex
  )
import LetsRead.Predictions
  ( auditAndApplyPredictionUpdates
  , coalesceBulletLines
  , parseTopicsFromBracket
  , placeholderSubstrings
  , renderHallOfFameMarkdown
  , renderSinglePredictionDoc
  )
import LetsRead.Prompts (expandPersonaPreset)
import LetsRead.Types
  ( ChunkMeta (..)
  , ParsedChunkSummaries (..)
  , PredictionRecord (..)
  , ResponseSection (..)
  , SessionState (..)
  , StoryChunkRecord (..)
  , emptyParsedChunkSummaries
  , formatChapLabel
  , jsonInt
  , padChunkNumber
  , readTextFileSafe
  , stripAfterClosingBracket
  , stripToolReceiptComments
  , wrapMarkdownBullet
  , wrapMarkdownParagraph
  , wrapMarkdownQuote
  )
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.FilePath (takeFileName, (</>))

defaultCuratedMemory :: [(Text, Text)]
defaultCuratedMemory =
  [ ("Story Summary So Far", "- *(No chunks read yet.)*")
  , ("Characters & Relationships", "- *(None introduced yet.)*")
  , ("Active Mysteries & Unanswered Questions", "- *(None yet.)*")
  , ( "Notable Quotes, Themes & Running Jokes"
    , "- **Reader Craft Directives & Running Gags (Persistent)**: Keep a grounded, conversational forum liveblog voice inside the story; no lecturing, video-essay/review jargon, author-grading, or textbook truisms."
    )
  ]

classifyMemoryHeading :: Text -> Maybe Text
classifyMemoryHeading rawHeading =
  let h = T.toLower (T.strip rawHeading)
   in if "chunk index" `T.isInfixOf` h
        || "memory archive" `T.isInfixOf` h
        || "session index" `T.isInfixOf` h
        || "index tree" `T.isInfixOf` h
        || "prediction slate" `T.isInfixOf` h
        || "auto-maintained" `T.isInfixOf` h
        then Nothing
        else if "story summary" `T.isInfixOf` h || "summary so far" `T.isInfixOf` h
          then Just "Story Summary So Far"
          else if "character" `T.isInfixOf` h || "relationship" `T.isInfixOf` h
            then Just "Characters & Relationships"
            else if "myster" `T.isInfixOf` h || "unanswered" `T.isInfixOf` h || "question" `T.isInfixOf` h
              then Just "Active Mysteries & Unanswered Questions"
              else if "quote" `T.isInfixOf` h || "theme" `T.isInfixOf` h || "joke" `T.isInfixOf` h || "meme" `T.isInfixOf` h
                then Just "Notable Quotes, Themes & Running Jokes"
                else Nothing

isPlaceholderSection :: Text -> Bool
isPlaceholderSection body =
  let s = T.toLower (T.strip body)
   in T.null s || any (`T.isInfixOf` s) placeholderSubstrings

parseMemorySections :: Text -> Map.Map Text Text
parseMemorySections txt = Map.fromListWith (\new old -> old <> "\n" <> new) (go Nothing [] (T.lines txt))
  where
    flush Nothing _ = []
    flush (Just h) acc =
      let body = T.strip (T.unlines (reverse acc))
       in [(h, body) | not (T.null body)]
    go curH acc [] = flush curH acc
    go curH acc (l : ls)
      | "## " `T.isPrefixOf` T.stripStart l =
          let hName = T.strip (T.drop 3 (T.stripStart l))
           in flush curH acc ++ go (classifyMemoryHeading hName) [] ls
      | otherwise = go curH (l : acc) ls

isTemplatePlaceholderOnly :: Text -> Bool
isTemplatePlaceholderOnly body =
  let s = T.strip body
      low = T.toLower s
   in T.null s
        || "- <" `T.isPrefixOf` low
        || "* <" `T.isPrefixOf` low
        || "<questions" `T.isPrefixOf` low

isFinalChunkMysteryResolution :: Text -> Bool
isFinalChunkMysteryResolution body =
  let low = T.toLower (T.strip body)
   in not (isTemplatePlaceholderOnly body)
        && ( "story complete" `T.isInfixOf` low
               || "none" `T.isInfixOf` low
               || "resolved" `T.isInfixOf` low
               || "no unanswered" `T.isInfixOf` low
               || "no active myster" `T.isInfixOf` low
           )

mergeCuratedNarrativeMemory :: [(Text, Text)] -> Maybe Text -> [(Text, Text)]
mergeCuratedNarrativeMemory = mergeCuratedNarrativeMemoryForTurn False

mergeCuratedNarrativeMemoryForTurn :: Bool -> [(Text, Text)] -> Maybe Text -> [(Text, Text)]
mergeCuratedNarrativeMemoryForTurn _ prevSections Nothing =
  if null prevSections then defaultCuratedMemory else prevSections
mergeCuratedNarrativeMemoryForTurn isFinalTurn prevSections (Just memTxt) =
  let incoming = parseMemorySections (stripToolReceiptComments memTxt)
      baseSections =
        [ (secName, oldBody)
        | (secName, oldBody) <- if null prevSections then defaultCuratedMemory else prevSections
        , secName `elem` map fst defaultCuratedMemory
        ]
   in [ (secName, mergedBody)
      | (secName, oldBody) <- baseSections
      , let mergedBody =
              case Map.lookup secName incoming of
                Nothing -> oldBody
                Just newBody
                  | isFinalTurn
                      && secName == "Active Mysteries & Unanswered Questions"
                      && isFinalChunkMysteryResolution newBody ->
                      newBody
                  | isPlaceholderSection newBody && not (isPlaceholderSection oldBody) ->
                      oldBody
                  | otherwise ->
                      newBody
      ]

resolveAndAuditTurn
  :: Int
  -> Int
  -> Int
  -> Text
  -> Int
  -> Int
  -> Bool
  -> Text
  -> [(Text, Text)]
  -> [PredictionRecord]
  -> [Text]
  -> Maybe Text
  -> Maybe Text
  -> ([(Text, Text)], [PredictionRecord], [(Int, Text)], [Text], [Text])
resolveAndAuditTurn curIdx totalChunks chapNum chapTitle partNum partsTotal isRecordTurn commText prevSections prevPreds prevWarns mPredUpdates mMemTxt =
  let isFinalTurn = totalChunks > 0 && curIdx >= totalChunks
      curated' = mergeCuratedNarrativeMemoryForTurn isFinalTurn prevSections mMemTxt
      (preds', pendingRetires, auditBlocks, trackerUpdates) =
        if isRecordTurn || isJust mPredUpdates
          then
            auditAndApplyPredictionUpdates
              curIdx
              totalChunks
              chapNum
              chapTitle
              partNum
              partsTotal
              isRecordTurn
              commText
              prevPreds
              mPredUpdates
          else (prevPreds, [], prevWarns, [])
   in (curated', preds', pendingRetires, auditBlocks, trackerUpdates)

renderCuratedSections :: [(Text, Text)] -> Text
renderCuratedSections sections =
  T.intercalate
    "\n\n"
    [ "## " <> secName <> "\n" <> T.strip body
    | (secName, body) <- sections
    , secName `elem` map fst defaultCuratedMemory
    ]

checkMemoryCompaction :: [(Text, Text)] -> (Bool, Int, Int)
checkMemoryCompaction sections =
  let rendered = renderCuratedSections sections
      lineCount = length (T.lines rendered)
      byteCount = BS.length (TE.encodeUtf8 rendered)
   in (lineCount > 80 || byteCount > 8000, lineCount, byteCount)

cleanChunkSummary :: Text -> Text
cleanChunkSummary raw =
  let oneLine = T.unwords [T.strip l | l <- T.lines raw, not (T.null (T.strip l))]
      noBullet =
        if "- " `T.isPrefixOf` oneLine || "* " `T.isPrefixOf` oneLine
          then T.strip (T.drop 2 oneLine)
          else oneLine
      (beforeColonRaw, afterColon) = T.breakOn ":" noBullet
      beforeColonClean = T.toLower (T.strip (T.dropAround (== '*') (T.strip beforeColonRaw)))
   in if not (T.null afterColon)
        && ("chunk " `T.isPrefixOf` beforeColonClean || "chunk_" `T.isPrefixOf` beforeColonClean)
        then T.strip (T.dropWhile (== '*') (T.drop 1 afterColon))
        else noBullet

parseChunkSummaries :: Text -> ParsedChunkSummaries
parseChunkSummaries raw =
  let bullets = coalesceBulletLines (T.lines (stripToolReceiptComments raw))
      step acc line =
        let s = T.strip line
            (_, afterOpen) = T.breakOn "[" s
            (inside, afterClose) = T.breakOn "]" (T.drop 1 afterOpen)
         in if T.null afterOpen || T.null afterClose
              then acc
              else
                let firstSeg =
                      case T.splitOn "|" inside of
                        (h : _) -> T.toLower (T.strip h)
                        [] -> ""
                    bodyRaw = stripAfterClosingBracket afterClose
                    body = cleanChunkSummary bodyRaw
                    topics = parseTopicsFromBracket inside body
                 in if T.null body
                      then acc
                      else
                        if "story" `T.isPrefixOf` firstSeg
                          then acc {pcsStory = Just (topics, body)}
                          else
                            if "entry" `T.isPrefixOf` firstSeg || "commentary" `T.isPrefixOf` firstSeg
                              then acc {pcsEntry = Just (topics, body)}
                              else
                                if "discussion" `T.isPrefixOf` firstSeg
                                  then acc {pcsDiscussion = Just (topics, body)}
                                  else acc
   in foldl' step emptyParsedChunkSummaries bullets

extractFallbackSummary :: Text -> Text
extractFallbackSummary commText =
  let candidates =
        [ if "- " `T.isPrefixOf` s || "* " `T.isPrefixOf` s
            then T.strip (T.drop 2 s)
            else s
        | l <- T.lines (stripToolReceiptComments commText)
        , let s = T.strip l
        , not (T.null s)
        , not ("#" `T.isPrefixOf` s)
        , not (">" `T.isPrefixOf` s)
        , not ("---" `T.isPrefixOf` s)
        ]
      firstLine = fromMaybe "Commentary recorded." (listToMaybe (filter (not . T.null) candidates))
   in if T.length firstLine > 160
        then T.take 157 firstLine <> "..."
        else firstLine

parseCombinedResponse :: Text -> (Maybe Text, Text, ParsedChunkSummaries, Maybe Text, Maybe Text)
parseCombinedResponse raw =
  let cleanRaw = stripToolReceiptComments raw
      classifyLine l =
        let s = T.toUpper (T.strip l)
         in if s == "=== USER ===" || s == "=== QUESTION ===" || s == "=== USER MESSAGE ==="
              then Just SecUserQuestion
              else if s == "=== COMMENTARY ===" || s == "=== REPLY ===" || s == "=== RESPONSE ===" || s == "=== DISCUSSION RESPONSE ===" || s == "=== DISCUSSION ==="
                then Just SecCommentary
                else if s == "=== CHUNK SUMMARY ===" || s == "=== CHUNK INDEX ==="
                  then Just SecChunkSummary
                  else if s == "=== PREDICTION UPDATES ===" || s == "=== PREDICTIONS ==="
                    then Just SecPredictionUpdates
                    else if s == "=== UPDATED MEMORY ==="
                      then Just SecUpdatedMemory
                      else Nothing
      go _ [] = []
      go curSec (l : ls) =
        case classifyLine l of
          Just newSec -> go newSec ls
          Nothing -> (curSec, l) : go curSec ls
      tagged = go SecCommentary (T.lines cleanRaw)
      extract sec = T.strip (T.unlines [l | (s, l) <- tagged, s == sec])
      userPart = extract SecUserQuestion
      commPart = extract SecCommentary
      sumPart = extract SecChunkSummary
      predPart = extract SecPredictionUpdates
      memPart = extract SecUpdatedMemory
   in ( if T.null userPart then Nothing else Just userPart
      , commPart
      , if T.null sumPart then emptyParsedChunkSummaries else parseChunkSummaries sumPart
      , if T.null predPart then Nothing else Just predPart
      , if T.null memPart then Nothing else Just memPart
      )

stripLeadingChunkHeading :: Text -> Text
stripLeadingChunkHeading txt =
  case T.lines (T.strip txt) of
    (firstLine : restLines)
      | Just (_, hTitle) <- parseMarkdownHeading firstLine
      , let cleaned = T.strip (T.dropWhile (not . isAlphaNum) hTitle)
      , let low = T.toLower cleaned
      , "chunk " `T.isPrefixOf` low || "final wrapup" `T.isPrefixOf` low ->
          T.strip (T.unlines restLines)
    _ -> T.strip txt

stripTrailingEntryRule :: Text -> Text
stripTrailingEntryRule txt =
  let s = T.stripEnd txt
   in if "\n---" `T.isSuffixOf` s
        then T.stripEnd (T.dropEnd 3 s)
        else s

formatUserQuote :: Text -> Text
formatUserQuote msg =
  case [T.stripEnd l | l <- T.lines (T.strip msg)] of
    [] -> ""
    (firstLine : restLines) ->
      T.unlines $
        ("> **User**: " <> firstLine)
          : [if T.null (T.strip l) then ">" else "> " <> l | l <- restLines]

formatPeerFactCheckQuote :: Text -> Text
formatPeerFactCheckQuote msg =
  case [T.stripEnd l | l <- T.lines (T.strip msg), not (T.null (T.strip l))] of
    [] -> ""
    ls ->
      T.unlines $
        "> **Fact-Check Peer Query (Unspoiled AI Peer — Verify Against Primary Source)**:"
          : ["> " <> l | l <- ls]

syncPredictionsDirectory :: FilePath -> SessionState -> IO ()
syncPredictionsDirectory sessionDir st = do
  let predDir = sessionDir </> "predictions"
      preds = stPredictions st
  createDirectoryIfMissing True predDir

  forM_ preds $ \pr -> do
    let fName = "pred_" ++ padChunkNumber (prOriginChunk pr) ++ ".md"
    TIO.writeFile (predDir </> fName) (renderSinglePredictionDoc sessionDir pr)

  syncMultiLayerIndex sessionDir st predictionIndexSpec preds

  let isFinished = stCurrentIndex st >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
  when isFinished $ do
    let hofPath = predDir </> "hall_of_fame.md"
    TIO.writeFile hofPath (renderHallOfFameMarkdown sessionDir st)

renderMemoryMarkdown :: FilePath -> SessionState -> Text
renderMemoryMarkdown sessionDir st =
  let curated = if null (stCuratedMemory st) then defaultCuratedMemory else stCuratedMemory st
      (needsCompaction, curLines, curBytes) = checkMemoryCompaction curated
      curIdx = stCurrentIndex st
      progressStr
        | curIdx == 0 = "Initialized (0 / " <> jsonInt (stTotalChunks st) <> " chunks read)"
        | otherwise =
            case stCurrentMeta st of
              Just m ->
                "Chunk "
                  <> jsonInt curIdx
                  <> " / "
                  <> jsonInt (stTotalChunks st)
                  <> " ("
                  <> formatChapLabel (metaChapterNumber m) (metaChapterTitle m)
                  <> ", Part "
                  <> jsonInt (metaPartInChapter m)
                  <> "/"
                  <> jsonInt (metaPartsInChapter m)
                  <> ")"
              Nothing -> "Chunk " <> jsonInt curIdx <> " / " <> jsonInt (stTotalChunks st)
      compactionBanner
        | needsCompaction =
            [ ""
            , "> [!IMPORTANT]"
            , wrapMarkdownQuote
                78
                ( "**Memory Compaction Needed**: Your 4 curated narrative memory sections (`Story Summary So Far`, `Characters & Relationships`, `Active Mysteries & Unanswered Questions`, `Notable Quotes, Themes & Running Jokes`) are currently "
                    <> jsonInt curLines
                    <> " lines ("
                    <> jsonInt curBytes
                    <> " bytes), exceeding the 80-line / 8,000-byte target. On your next turn, condense older chapters in `## Story Summary So Far` into high-level multi-chapter arc bullets and prune minor resolved mysteries. All earlier story chunk summaries, commentary entries, historical memory snapshots, and predictions are permanently preserved in `<session_dir>/chunks/`, `<session_dir>/entries/`, `<session_dir>/predictions/`, and `<session_dir>/archive/`, so condensing `memory.md` will not lose any history."
                )
            ]
        | otherwise = []
      lookupSec name =
        fromMaybe "- *(None yet.)*" (lookup name curated)
      orderedStory = sortOn scrChunkIndex (stStoryRecords st)
      recentStory = drop (max 0 (length orderedStory - 5)) orderedStory
      recentStoryBlock
        | null recentStory = "- *(No story chunks read yet.)*"
        | otherwise = T.intercalate "\n\n" (map (wrapMarkdownBullet 78 . renderStoryBullet sessionDir) recentStory)
      canonTopics = collectCanonicalSessionTopics st
      canonTopicsBlock
        | null canonTopics =
            wrapMarkdownParagraph
              78
              "Established topic tags will appear here as chunks are recorded. Coin clean canonical tags as distinct recurring characters, factions, locations, or plot threads emerge."
        | otherwise =
            wrapMarkdownParagraph
              78
              "Reuse established tags where accurate, and coin clean canonical tags when genuinely distinct recurring characters, factions, locations, or plot threads emerge:"
              <> "\n\n"
              <> wrapMarkdownParagraph 78 ("`" <> T.intercalate "`, `" canonTopics <> "`")
      completedArcs = completedStoryArcRollups orderedStory
      completedArcsBlock
        | null completedArcs =
            wrapMarkdownParagraph
              78
              "None archived yet (still in Arc 1). Consolidate completed chapters in the current arc to 1–2 bullets max in `## Story Summary So Far`."
        | otherwise =
            wrapMarkdownParagraph
              78
              "Collapse each completed arc below to 1 bullet in `## Story Summary So Far`, and consolidate completed chapters in the current arc to 1–2 bullets max:"
              <> "\n\n"
              <> T.intercalate
                   "\n"
                   [ "- **" <> lbl <> "**: [" <> T.pack (takeFileName fp) <> "](" <> T.pack fp <> ")"
                   | (_, lbl, fp) <- completedArcs
                   ]
      isFinished = curIdx >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
      hofIndexSuffix =
        if isFinished
          then " | [Hall of Fame & Shame](predictions/hall_of_fame.md)"
          else ""
      indexIntroPara =
        wrapMarkdownParagraph
          78
          "Do not manually re-emit this section in `=== UPDATED MEMORY ===`; `LetsRead` updates it automatically from your `=== CHUNK SUMMARY ===`."
      indexDirectorySection =
        T.unlines
          [ "## Session Indexes & Recent Story Context"
          , ""
          , indexIntroPara
          , ""
          , "### Multi-Layer Domain Indexes"
          , ""
          , "- Story Chunks: [Chronological Index](chunks/by_chronology.md) | [Semantic Topic Index](chunks/by_topic.md) | [Unlocked Chunks](chunks/)"
          , "- Session Logs: [Chronological Index](entries/by_chronology.md) | [Semantic Topic Index](entries/by_topic.md) | [Entry Files](entries/)"
          , "- Predictions: [Chronological Index](predictions/by_chronology.md) | [Semantic Topic Index](predictions/by_topic.md) | [Prediction Files](predictions/)" <> hofIndexSuffix
          , ""
          , "### Established Topic Tags"
          , ""
          , canonTopicsBlock
          , ""
          , "### Completed L1 Story Arcs"
          , ""
          , completedArcsBlock
          , ""
          , "### Recent Story Chunks"
          , ""
          , recentStoryBlock
          ]
      personaPara = wrapMarkdownParagraph 78 (expandPersonaPreset (stPersona st))
   in T.unlines $
        [ "# Reader Memory & Notes: " <> stTitle st
        , ""
        , "## Session Overview"
        , ""
        , "- Session Directory: `" <> T.pack sessionDir <> "`"
        , "- Progress: " <> progressStr
        , ""
        , "### Reader Persona"
        , ""
        , personaPara
        ]
          ++ compactionBanner
          ++ [ ""
             , "## Story Summary So Far"
             , ""
             , T.strip (lookupSec "Story Summary So Far")
             , ""
             , T.strip indexDirectorySection
             , ""
             , "## Characters & Relationships"
             , ""
             , T.strip (lookupSec "Characters & Relationships")
             , ""
             , "## Active Mysteries & Unanswered Questions"
             , ""
             , T.strip (lookupSec "Active Mysteries & Unanswered Questions")
             , ""
             , "## Notable Quotes, Themes & Running Jokes"
             , ""
             , T.strip (lookupSec "Notable Quotes, Themes & Running Jokes")
             ]

syncMemoryAndArchives :: FilePath -> SessionState -> IO (Bool, Int, Int)
syncMemoryAndArchives sessionDir st = do
  let archiveDir = sessionDir </> "archive"
      memSnapDir = archiveDir </> "memory"
  createDirectoryIfMissing True memSnapDir

  let curated = if null (stCuratedMemory st) then defaultCuratedMemory else stCuratedMemory st
      curIdx = stCurrentIndex st
  when (curIdx > 0) $ do
    let curatedSnapPath = memSnapDir </> ("curated_" ++ padChunkNumber curIdx ++ ".md")
    TIO.writeFile curatedSnapPath (renderCuratedSections curated <> "\n")

  syncMultiLayerIndex sessionDir st storyIndexSpec (stStoryRecords st)
  syncMultiLayerIndex sessionDir st entryIndexSpec (stEntryRecords st)
  syncPredictionsDirectory sessionDir st

  let renderedMem = renderMemoryMarkdown sessionDir st
  TIO.writeFile (sessionDir </> "memory.md") renderedMem
  when (curIdx > 0) $ do
    let fullSnapPath = memSnapDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")
    TIO.writeFile fullSnapPath renderedMem

  pure (checkMemoryCompaction curated)

rebuildMasterLog :: FilePath -> SessionState -> IO FilePath
rebuildMasterLog sessionDir st = do
  let entriesDir = sessionDir </> "entries"
  createDirectoryIfMissing True entriesDir
  allNames <- listDirectory entriesDir
  let chunkFiles =
        sort
          [ entriesDir </> f
          | f <- allNames
          , "chunk_" `isPrefixOf` f
          , ".md" `isSuffixOf` f
          ]
      wrapupPath = entriesDir </> "wrapup.md"
  entryContents <- mapM readTextFileSafe chunkFiles
  hasWrapup <- doesFileExist wrapupPath
  wrapupContent <- if hasWrapup then readTextFileSafe wrapupPath else pure ""
  let isFinished = stCurrentIndex st >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
      hofSuffix =
        if isFinished && not (null (stPredictions st))
          then "\n" <> renderHallOfFameMarkdown sessionDir st <> "\n"
          else ""
      logHeader =
        "# Let's Read: "
          <> stTitle st
          <> "\n\n## Reader Persona\n\n"
          <> wrapMarkdownParagraph 78 (stPersona st)
          <> "\n\n---\n\n"
      logPath = sessionDir </> "lets_read_log.md"
  TIO.writeFile logPath (logHeader <> T.concat entryContents <> wrapupContent <> hofSuffix)
  pure logPath
