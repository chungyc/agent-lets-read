{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LetsRead.Index
  ( IndexSpec (..)
  , topicNormKey
  , collectSessionTopicCounts
  , collectCanonicalSessionTopics
  , partitionVettedTopics
  , shouldCurateTopics
  , applyTopicAliases
  , applyTopicCuratorResponse
  , allEntryTopics
  , renderStoryBullet
  , renderEntryBullet
  , storyIndexSpec
  , entryIndexSpec
  , predictionIndexSpec
  , syncMultiLayerIndex
  ) where

import Control.Exception (IOException, catch)
import Control.Monad (forM, forM_, when)
import Data.List (groupBy, isPrefixOf, isSuffixOf, nub, nubBy, partition, sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Predictions (cleanTopicTag, renderPredSummaryBullet)
import LetsRead.Types
  ( EntryDiscussionRecord (..)
  , EntryLogRecord (..)
  , PredictionRecord (..)
  , PredictionStatus (..)
  , SessionState (..)
  , StoryChunkRecord (..)
  , formatChapLabel
  , jsonInt
  , padChunkNumber
  , readTextFileSafe
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeFile
  )
import System.FilePath (takeFileName, (</>))

data IndexSpec a = IndexSpec
  { isDomainDir :: !FilePath
  , isDomainTitle :: !Text
  , isChronIntro :: !Text
  , isTopicIntro :: !Text
  , isItemIndex :: !(a -> Int)
  , isItemChapter :: !(a -> (Int, Text))
  , isItemPart :: !(a -> (Int, Int))
  , isItemTopics :: !(a -> [Text])
  , isDefaultTopic :: !Text
  , isRenderChronBullet :: !(FilePath -> a -> Text)
  , isRenderTopicBullet :: !(FilePath -> a -> Text)
  , isSummarizeArc :: !([a] -> Text)
  , isArcExtraFooter :: !(FilePath -> [a] -> IO [Text])
  }

groupsOfList :: Int -> [a] -> [[a]]
groupsOfList _ [] = []
groupsOfList n xs =
  let (h, t) = splitAt n xs
   in h : groupsOfList n t

groupItemsIntoArcs :: (a -> (Int, Text)) -> (a -> (Int, Int)) -> [a] -> [[a]]
groupItemsIntoArcs getChap getPart = go [] [] (0 :: Int)
  where
    go [] _ _ [] = []
    go cur _ _ [] = [reverse cur]
    go cur chapsInCur countInCur (e : es) =
      let (chap, _) = getChap e
          (partInC, _) = getPart e
          isNewChap = partInC == 1 && chap `notElem` chapsInCur
          shouldSplit =
            countInCur >= 25
              || (isNewChap && (length chapsInCur >= 10 || countInCur >= 18))
       in if shouldSplit && not (null cur)
            then reverse cur : go [e] [chap] 1 es
            else
              let chaps' = if chap `elem` chapsInCur then chapsInCur else chap : chapsInCur
               in go (e : cur) chaps' (countInCur + 1) es

cleanArchiveDirectory :: FilePath -> IO ()
cleanArchiveDirectory dir = do
  exists <- doesDirectoryExist dir
  when exists $ do
    names <- listDirectory dir
    forM_ names $ \f ->
      when (("L" `isPrefixOf` f || "topic_" `isPrefixOf` f) && ".md" `isSuffixOf` f) $
        removeFile (dir </> f) `catch` (\(_ :: IOException) -> pure ())

rollupIndexLevels :: FilePath -> FilePath -> Text -> Int -> [(FilePath, Text, Text)] -> IO [(FilePath, Text, Text)]
rollupIndexLevels sessionDir relArcDir =
  rollupIndexLevelsWithPrefix sessionDir relArcDir "L"

rollupIndexLevelsWithPrefix ::
  FilePath -> FilePath -> String -> Text -> Int -> [(FilePath, Text, Text)] -> IO [(FilePath, Text, Text)]
rollupIndexLevelsWithPrefix sessionDir relArcDir filePrefix dirHeading level nodes
  | length nodes <= 25 = pure nodes
  | otherwise = do
      let groups = groupsOfList 25 nodes
      parents <- forM (zip [1 :: Int ..] groups) $ \(grpIdx, children) -> do
        let fileName = filePrefix ++ show level ++ "_" ++ padChunkNumber grpIdx ++ ".md"
            relPath = relArcDir </> fileName
            fullPath = sessionDir </> relPath
            firstLbl = case children of ((_, l, _) : _) -> l; [] -> ""
            lastLbl = case reverse children of ((_, l, _) : _) -> l; [] -> ""
            parentLabel =
              dirHeading
                <> " L"
                <> jsonInt level
                <> "."
                <> jsonInt grpIdx
                <> " ("
                <> firstLbl
                <> " .. "
                <> lastLbl
                <> ")"
            parentSummary =
              "Contains "
                <> jsonInt (length children)
                <> " archive nodes ("
                <> firstLbl
                <> " through "
                <> lastLbl
                <> ")"
            doc =
              T.unlines
                ( [ "# " <> parentLabel
                  , ""
                  , "*Session Directory*: `" <> T.pack sessionDir <> "`"
                  , ""
                  , "Read the linked archive files below to inspect detailed entries:"
                  , ""
                  ]
                    ++ [ "- **"
                          <> lbl
                          <> "**: ["
                          <> T.pack (takeFileName fp)
                          <> "]("
                          <> T.pack fp
                          <> ") — "
                          <> summ
                       | (fp, lbl, summ) <- children
                       ]
                )
        TIO.writeFile fullPath doc
        pure (relPath, parentLabel, parentSummary)
      rollupIndexLevelsWithPrefix sessionDir relArcDir filePrefix dirHeading (level + 1) parents

topicNormKey :: Text -> Text
topicNormKey raw =
  T.unwords (T.words (T.toLower (cleanTopicTag raw)))

writeChronArcFile :: FilePath -> IndexSpec a -> Int -> [a] -> IO (FilePath, Text, Text)
writeChronArcFile sessionDir spec grpIdx arcItems = do
  let (startIdx, startChap) =
        case arcItems of
          (firstE : _) -> (isItemIndex spec firstE, fst (isItemChapter spec firstE))
          [] -> (1, 1)
      (endIdx, endChap) =
        case reverse arcItems of
          (lastE : _) -> (isItemIndex spec lastE, fst (isItemChapter spec lastE))
          [] -> (1, 1)
      chapRange
        | startChap == 0 && endChap == 0 = "Front Matter"
        | startChap == endChap = "Ch. " <> jsonInt startChap
        | otherwise = "Ch. " <> jsonInt startChap <> "–" <> jsonInt endChap
      itemRange =
        if startIdx == endIdx
          then "Chunk " <> T.pack (padChunkNumber startIdx)
          else "Chunks " <> T.pack (padChunkNumber startIdx) <> "–" <> T.pack (padChunkNumber endIdx)
      label = "Arc " <> jsonInt grpIdx <> " — " <> isDomainTitle spec <> " (" <> chapRange <> " | " <> itemRange <> ")"
      summaryLine = isSummarizeArc spec arcItems
      byChapter = groupBy (\a b -> fst (isItemChapter spec a) == fst (isItemChapter spec b)) arcItems
      renderChapGroup [] = ""
      renderChapGroup grp@(firstE : _) =
        let (cNum, cTitle) = isItemChapter spec firstE
         in "### "
              <> formatChapLabel cNum cTitle
              <> "\n"
              <> T.unlines (map (isRenderChronBullet spec sessionDir) grp)
  extraFooter <- isArcExtraFooter spec sessionDir arcItems
  let relArcDir = isDomainDir spec </> "archive" </> "chronology"
      fileName = "L1_" ++ padChunkNumber grpIdx ++ ".md"
      relPath = relArcDir </> fileName
      fullPath = sessionDir </> relPath
      doc =
        T.unlines $
          [ "# " <> label
          , ""
          , "- **Session Directory**: `" <> T.pack sessionDir <> "`"
          , "- **Summary**: " <> summaryLine
          , ""
          , "## " <> isDomainTitle spec <> " by Chapter"
          , ""
          , if null arcItems
              then "- *(No entries recorded in this arc.)*"
              else T.intercalate "\n" (map renderChapGroup byChapter)
          ]
            ++ extraFooter
  createDirectoryIfMissing True (sessionDir </> relArcDir)
  TIO.writeFile fullPath doc
  pure (relPath, label, summaryLine)

syncChronologicalTree :: FilePath -> SessionState -> IndexSpec a -> [a] -> IO ()
syncChronologicalTree sessionDir st spec items = do
  let domainPath = sessionDir </> isDomainDir spec
      relArcDir = isDomainDir spec </> "archive" </> "chronology"
      fullArcDir = sessionDir </> relArcDir
  createDirectoryIfMissing True domainPath
  createDirectoryIfMissing True fullArcDir
  cleanArchiveDirectory fullArcDir

  let sortedItems = sortOn (isItemIndex spec) items
      arcs = groupItemsIntoArcs (isItemChapter spec) (isItemPart spec) sortedItems
      completedArcs = if length arcs <= 1 then [] else init arcs
  l1Nodes <- forM (zip [1 :: Int ..] completedArcs) $ \(grpIdx, arcItems) ->
    writeChronArcFile sessionDir spec grpIdx arcItems
  topArcNodes <- rollupIndexLevels sessionDir relArcDir (isDomainTitle spec <> " Chronology Archive") 2 l1Nodes

  let inlineItems =
        case reverse arcs of
          [] -> []
          [onlyArc] -> onlyArc
          (lastArc : prevArc : _)
            | length lastArc < 5 ->
                let needed = 5 - length lastArc
                    tailPrev = drop (max 0 (length prevArc - needed)) prevArc
                 in tailPrev ++ lastArc
            | otherwise -> lastArc
      byChap = groupBy (\a b -> fst (isItemChapter spec a) == fst (isItemChapter spec b)) inlineItems
      renderChapGroup [] = ""
      renderChapGroup grp@(firstE : _) =
        let (cNum, cTitle) = isItemChapter spec firstE
         in "### "
              <> formatChapLabel cNum cTitle
              <> "\n"
              <> T.unlines (map (isRenderChronBullet spec sessionDir) grp)
      arcLinksSection =
        if null topArcNodes
          then
            [ "- *(All entries so far are listed inline below. Completed arc archive files will appear here as the story progresses.)*"
            ]
          else
            [ "- **"
                <> lbl
                <> "**: ["
                <> T.pack (takeFileName fp)
                <> "]("
                <> T.pack fp
                <> ") — "
                <> summ
            | (fp, lbl, summ) <- topArcNodes
            ]
      chronologyDoc =
        T.unlines $
          [ "# " <> isDomainTitle spec <> " Index by Story Chronology: " <> stTitle st
          , ""
          , "*Session Directory*: `" <> T.pack sessionDir <> "`"
          , ""
          , isChronIntro spec
          , ""
          , "## Completed Arc Archives"
          , ""
          ]
            ++ arcLinksSection
            ++ [ ""
               , "## Current & Recent Arc (" <> isDomainTitle spec <> ")"
               , ""
               , if null inlineItems
                   then "- *(No entries recorded yet.)*"
                   else T.intercalate "\n" (map renderChapGroup byChap)
               ]
  TIO.writeFile (domainPath </> "by_chronology.md") chronologyDoc

packTopicShards :: Int -> Int -> [(Text, [a], Text, Int)] -> [[(Text, [a], Text, Int)]]
packTopicShards maxLines maxTopics = go [] 0 0
  where
    go [] _ _ [] = []
    go cur _ _ [] = [reverse cur]
    go cur curLines curCnt (t@(_, _, _, lCnt) : ts)
      | not (null cur) && (curLines + lCnt > maxLines || curCnt >= maxTopics) =
          reverse cur : go [t] lCnt 1 ts
      | otherwise =
          go (t : cur) (curLines + lCnt) (curCnt + 1) ts

syncTopicTree :: FilePath -> SessionState -> IndexSpec a -> [a] -> IO ()
syncTopicTree sessionDir st spec items = do
  let domainPath = sessionDir </> isDomainDir spec
      relTopicArcDir = isDomainDir spec </> "archive" </> "topics"
      fullTopicArcDir = sessionDir </> relTopicArcDir
  createDirectoryIfMissing True domainPath
  createDirectoryIfMissing True fullTopicArcDir
  cleanArchiveDirectory fullTopicArcDir

  let topicPairs =
        [ (topicNormKey cTag, (cTag, item))
        | item <- sortOn (isItemIndex spec) items
        , let rawTags = if null (isItemTopics spec item) then [isDefaultTopic spec] else isItemTopics spec item
        , tag <- rawTags
        , let cTag = cleanTopicTag tag
        , not (T.null cTag)
        ]
      topicMap =
        foldl'
          ( \acc (k, (dispTag, item)) ->
              case Map.lookup k acc of
                Nothing -> Map.insert k (dispTag, [item]) acc
                Just (existingDisp, existingItems) ->
                  let bestDisp = if T.length dispTag > T.length existingDisp then dispTag else existingDisp
                      items' =
                        if any (\x -> isItemIndex spec x == isItemIndex spec item) existingItems
                          then existingItems
                          else existingItems ++ [item]
                   in Map.insert k (bestDisp, items') acc
          )
          Map.empty
          topicPairs
      sortedTopics = sortOn (T.toLower . fst) (Map.elems topicMap)
      renderTopicSecIO (topicIdx, (dispTag, grpItems)) = do
        let ordered = sortOn (isItemIndex spec) grpItems
        if length ordered <= 25
          then do
            let secTxt =
                  "### "
                    <> dispTag
                    <> " ("
                    <> jsonInt (length ordered)
                    <> ")\n"
                    <> T.unlines (map (isRenderTopicBullet spec sessionDir) ordered)
            pure (dispTag, ordered, secTxt, length (T.lines secTxt) + 1)
          else do
            let rawArcs = groupItemsIntoArcs (isItemChapter spec) (isItemPart spec) ordered
                arcs = if length rawArcs <= 1 then groupsOfList 20 ordered else rawArcs
                completedArcs = if length arcs <= 1 then [] else init arcs
                inlineItems = case reverse arcs of (lastA : _) -> lastA; [] -> []
                tPrefix = "topic_" ++ padChunkNumber topicIdx ++ "_L"
            l1TopicNodes <- forM (zip [1 :: Int ..] completedArcs) $ \(arcIdx, arcItems) -> do
              let startIdx = case arcItems of (x : _) -> isItemIndex spec x; [] -> 1
                  endIdx = case reverse arcItems of (x : _) -> isItemIndex spec x; [] -> 1
                  itemRange =
                    if startIdx == endIdx
                      then "Chunk " <> T.pack (padChunkNumber startIdx)
                      else "Chunks " <> T.pack (padChunkNumber startIdx) <> "–" <> T.pack (padChunkNumber endIdx)
                  lbl = dispTag <> " Archive L1." <> jsonInt arcIdx <> " (" <> itemRange <> ")"
                  summ = isSummarizeArc spec arcItems
                  fName = tPrefix ++ "1_" ++ padChunkNumber arcIdx ++ ".md"
                  rPath = relTopicArcDir </> fName
                  fPath = sessionDir </> rPath
                  doc =
                    T.unlines
                      [ "# " <> lbl <> " — " <> isDomainTitle spec
                      , ""
                      , "- **Session Directory**: `" <> T.pack sessionDir <> "`"
                      , "- **Summary**: " <> summ
                      , ""
                      , "## Archived Entries for " <> dispTag
                      , ""
                      , T.unlines (map (isRenderTopicBullet spec sessionDir) arcItems)
                      ]
              TIO.writeFile fPath doc
              pure (rPath, lbl, summ)
            topTopicNodes <-
              rollupIndexLevelsWithPrefix
                sessionDir
                relTopicArcDir
                tPrefix
                (dispTag <> " Topic Archive")
                2
                l1TopicNodes
            let arcLinkLines =
                  [ "- **Archived ("
                      <> lbl
                      <> ")**: ["
                      <> T.pack (takeFileName fp)
                      <> "]("
                      <> T.pack fp
                      <> ") — "
                      <> summ
                  | (fp, lbl, summ) <- topTopicNodes
                  ]
                secTxt =
                  "### "
                    <> dispTag
                    <> " ("
                    <> jsonInt (length ordered)
                    <> ")\n"
                    <> T.unlines (arcLinkLines ++ map (isRenderTopicBullet spec sessionDir) inlineItems)
            pure (dispTag, ordered, secTxt, length (T.lines secTxt) + 1)

  renderedTopics <- mapM renderTopicSecIO (zip [1 :: Int ..] sortedTopics)
  let totalTopicLines = sum [lCnt | (_, _, _, lCnt) <- renderedTopics]

  if totalTopicLines <= 100
    then do
      let tocLines =
            if null renderedTopics
              then ["- *(No topics indexed yet.)*"]
              else
                [ "- **" <> dispTag <> "** (" <> jsonInt (length grpItems) <> ")"
                | (dispTag, grpItems, _, _) <- renderedTopics
                ]
          topicSections =
            if null renderedTopics
              then ["*(No entries recorded yet.)*"]
              else [secTxt | (_, _, secTxt, _) <- renderedTopics]
          byTopicDoc =
            T.unlines $
              [ "# " <> isDomainTitle spec <> " Index by Semantic Topic & Entity: " <> stTitle st
              , ""
              , "*Session Directory*: `" <> T.pack sessionDir <> "`"
              , ""
              , isTopicIntro spec
              , ""
              , "## Indexed Topics (" <> jsonInt (length renderedTopics) <> ")"
              , ""
              ]
                ++ tocLines
                ++ [ ""
                   , "## " <> isDomainTitle spec <> " by Topic"
                   , ""
                   , T.intercalate "\n" topicSections
                   ]
      TIO.writeFile (domainPath </> "by_topic.md") byTopicDoc
    else do
      let shards = packTopicShards 80 15 renderedTopics
      shardDetails <- forM (zip [1 :: Int ..] shards) $ \(grpIdx, shardTopics) -> do
        let firstT = case shardTopics of ((t, _, _, _) : _) -> t; [] -> ""
            lastT = case reverse shardTopics of ((t, _, _, _) : _) -> t; [] -> ""
            totalItemsInShard = sum [length g | (_, g, _, _) <- shardTopics]
            label = "Topic Shard L1." <> jsonInt grpIdx <> " (" <> firstT <> " – " <> lastT <> ")"
            topicListStr =
              T.intercalate
                ", "
                [ dispTag <> " (" <> jsonInt (length grpItems) <> ")"
                | (dispTag, grpItems, _, _) <- shardTopics
                ]
            summaryLine =
              jsonInt (length shardTopics)
                <> " topics, "
                <> jsonInt totalItemsInShard
                <> " entries — *Topics*: "
                <> topicListStr
            fileName = "L1_" ++ padChunkNumber grpIdx ++ ".md"
            relPath = relTopicArcDir </> fileName
            fullPath = sessionDir </> relPath
            shardDoc =
              T.unlines
                [ "# " <> label <> " — " <> isDomainTitle spec
                , ""
                , "- **Session Directory**: `" <> T.pack sessionDir <> "`"
                , "- **Summary**: " <> summaryLine
                , ""
                , "## Topics in This Shard"
                , ""
                , T.intercalate "\n" [secTxt | (_, _, secTxt, _) <- shardTopics]
                ]
        TIO.writeFile fullPath shardDoc
        let tagLinks = [(dispTag, relPath) | (dispTag, _, _, _) <- shardTopics]
        pure ((relPath, label, summaryLine), tagLinks)

      let l1ShardNodes = map fst shardDetails
          tagShardMap = Map.fromList (concatMap snd shardDetails)
      topShardNodes <- rollupIndexLevels sessionDir relTopicArcDir (isDomainTitle spec <> " Topic Archive") 2 l1ShardNodes
      let curIdx = stCurrentIndex st
          renderRecentTopicSec (dispTag, ordered) =
            let recentItems = [x | x <- ordered, isItemIndex spec x >= max 1 (curIdx - 2)]
                olderCount = length ordered - length recentItems
                olderNote =
                  case Map.lookup dispTag tagShardMap of
                    Just fp
                      | olderCount > 0 ->
                          [ "- *(+"
                              <> jsonInt olderCount
                              <> " earlier entries in ["
                              <> T.pack (takeFileName fp)
                              <> "]("
                              <> T.pack fp
                              <> "))*"
                          ]
                    _ -> []
             in "### "
                  <> dispTag
                  <> " ("
                  <> jsonInt (length ordered)
                  <> ")\n"
                  <> T.unlines (olderNote ++ map (isRenderTopicBullet spec sessionDir) recentItems)
          recentTopics =
            take
              15
              [ renderRecentTopicSec (dispTag, grpItems)
              | (dispTag, grpItems, _, _) <- renderedTopics
              , any (\x -> isItemIndex spec x >= max 1 (curIdx - 2)) grpItems
              ]
          shardLinksLines =
            [ "- **"
                <> lbl
                <> "**: ["
                <> T.pack (takeFileName fp)
                <> "]("
                <> T.pack fp
                <> ") — "
                <> summ
            | (fp, lbl, summ) <- topShardNodes
            ]
          byTopicDoc =
            T.unlines $
              [ "# " <> isDomainTitle spec <> " Index by Semantic Topic & Entity: " <> stTitle st
              , ""
              , "*Session Directory*: `" <> T.pack sessionDir <> "`"
              , ""
              , isTopicIntro spec
              , ""
              , "## Topic Archive Shards (" <> jsonInt (length renderedTopics) <> " Topics)"
              , ""
              ]
                ++ shardLinksLines
                ++ [ ""
                   , "## Recently Updated Topics (Last 3 Turns Inline)"
                   , ""
                   , if null recentTopics
                       then "*(Read the linked Topic Archive Shards above to inspect topic entries.)*"
                       else T.intercalate "\n" recentTopics
                   ]
      TIO.writeFile (domainPath </> "by_topic.md") byTopicDoc

syncMultiLayerIndex :: FilePath -> SessionState -> IndexSpec a -> [a] -> IO ()
syncMultiLayerIndex sessionDir st spec items = do
  syncChronologicalTree sessionDir st spec items
  syncTopicTree sessionDir st spec items

renderStoryBullet :: FilePath -> StoryChunkRecord -> Text
renderStoryBullet _ r =
  let padStr = padChunkNumber (scrChunkIndex r)
      idxStr = T.pack padStr
      chapStr = formatChapLabel (scrChapterNumber r) (scrChapterTitle r)
      partStr = "Part " <> jsonInt (scrPartInChapter r) <> "/" <> jsonInt (scrPartsInChapter r)
      topicsStr =
        if null (scrTopics r)
          then ""
          else " | *Topics*: " <> T.intercalate ", " (scrTopics r)
      storyPath = T.pack ("chunks" </> ("chunk_" ++ padStr ++ ".md"))
      entryPath = T.pack ("entries" </> ("chunk_" ++ padStr ++ ".md"))
      memPath = T.pack ("archive" </> "memory" </> ("chunk_" ++ padStr ++ ".md"))
   in "- **[chunk_"
        <> idxStr
        <> "]("
        <> storyPath
        <> ")** ("
        <> chapStr
        <> ", "
        <> partStr
        <> topicsStr
        <> "): "
        <> scrSummary r
        <> " ([entry]("
        <> entryPath
        <> ") | [memory]("
        <> memPath
        <> "))"

storyIndexSpec :: IndexSpec StoryChunkRecord
storyIndexSpec =
  IndexSpec
    { isDomainDir = "chunks"
    , isDomainTitle = "Story Chunks"
    , isChronIntro = "Use this index to browse unlocked in-story plot summaries in chronological order by Arc, Chapter, and Chunk."
    , isTopicIntro = "Use this inverted index to look up unlocked story chunks (`chunks/chunk_XXXX.md`) by character, location, faction, prop, or plot thread."
    , isItemIndex = scrChunkIndex
    , isItemChapter = \r -> (scrChapterNumber r, scrChapterTitle r)
    , isItemPart = \r -> (scrPartInChapter r, scrPartsInChapter r)
    , isItemTopics = scrTopics
    , isDefaultTopic = "General Plot"
    , isRenderChronBullet = renderStoryBullet
    , isRenderTopicBullet = renderStoryBullet
    , isSummarizeArc = \rs ->
        let distinctChaps = nub [(scrChapterNumber r, scrChapterTitle r) | r <- rs]
         in "Chapters: *" <> T.intercalate "; " [formatChapLabel cn ct | (cn, ct) <- distinctChaps] <> "*"
    , isArcExtraFooter = \sessionDir rs ->
        case reverse rs of
          [] -> pure []
          (lastR : _) -> do
            let endChk = scrChunkIndex lastR
                curatedSnapPath = sessionDir </> "archive" </> "memory" </> ("curated_" ++ padChunkNumber endChk ++ ".md")
            hasSnap <- doesFileExist curatedSnapPath
            snapContent <- if hasSnap then readTextFileSafe curatedSnapPath else pure ""
            pure
              [ "---"
              , ""
              , "## Historical Reader Memory Snapshot (As of Chunk " <> T.pack (padChunkNumber endChk) <> ")"
              , ""
              , if T.null (T.strip snapContent) then "*(No snapshot recorded.)*" else T.strip snapContent
              ]
    }

allEntryTopics :: EntryLogRecord -> [Text]
allEntryTopics r =
  let discTags =
        concat
          [ edrTopics d ++ [if edrIsFactCheck d then "Fact-Check Verification" else "Reader Discussion"]
          | d <- elrDiscussions r
          ]
   in nubBy (\a b -> topicNormKey a == topicNormKey b) (elrTopics r ++ discTags)

renderEntryBullet :: FilePath -> EntryLogRecord -> Text
renderEntryBullet _ r =
  let padStr = padChunkNumber (elrEntryIndex r)
      idxStr = T.pack padStr
      chapStr = formatChapLabel (elrChapterNumber r) (elrChapterTitle r)
      partStr = "Part " <> jsonInt (elrPartInChapter r) <> "/" <> jsonInt (elrPartsInChapter r)
      topics = allEntryTopics r
      topicsStr =
        if null topics
          then ""
          else " | *Topics*: " <> T.intercalate ", " topics
      discLines =
        [ "  - **"
            <> (if edrIsFactCheck d then "Fact-Check Discussion" else "User Discussion")
            <> "**"
            <> (if null (edrTopics d) then "" else " (*Topics*: " <> T.intercalate ", " (edrTopics d) <> ")")
            <> ": "
            <> edrSummary d
        | d <- elrDiscussions r
        ]
      baseLine =
        if elrIsWrapup r
          then
            let wrapPath = T.pack ("entries" </> "wrapup.md")
             in "- **[wrapup]("
                  <> wrapPath
                  <> ")** (Final Wrapup & Retrospective"
                  <> topicsStr
                  <> "): "
                  <> elrSummary r
          else
            let entryPath = T.pack ("entries" </> ("chunk_" ++ padStr ++ ".md"))
                storyPath = T.pack ("chunks" </> ("chunk_" ++ padStr ++ ".md"))
             in "- **[entry_"
                  <> idxStr
                  <> "]("
                  <> entryPath
                  <> ")** ("
                  <> chapStr
                  <> ", "
                  <> partStr
                  <> topicsStr
                  <> "): "
                  <> elrSummary r
                  <> " ([story]("
                  <> storyPath
                  <> "))"
   in T.intercalate "\n" (baseLine : discLines)

entryIndexSpec :: IndexSpec EntryLogRecord
entryIndexSpec =
  IndexSpec
    { isDomainDir = "entries"
    , isDomainTitle = "Session Log Entries"
    , isChronIntro = "Use this index to browse Let's Read commentary entries, running gags, and Reader Discussions in chronological order."
    , isTopicIntro = "Use this inverted index to look up Let's Read commentary entries (`entries/chunk_XXXX.md`), running gags, craft notes, Fact-Check verifications, and User Discussions by topic."
    , isItemIndex = elrEntryIndex
    , isItemChapter = \r -> (elrChapterNumber r, elrChapterTitle r)
    , isItemPart = \r -> (elrPartInChapter r, elrPartsInChapter r)
    , isItemTopics = allEntryTopics
    , isDefaultTopic = "Liveblog Commentary"
    , isRenderChronBullet = renderEntryBullet
    , isRenderTopicBullet = renderEntryBullet
    , isSummarizeArc = \rs ->
        let discCnt = sum [length (elrDiscussions r) | r <- rs]
            distinctChaps = nub [(elrChapterNumber r, elrChapterTitle r) | r <- rs]
         in jsonInt (length rs)
              <> " entries, "
              <> jsonInt discCnt
              <> " discussions (Chapters: *"
              <> T.intercalate "; " [formatChapLabel cn ct | (cn, ct) <- distinctChaps]
              <> "*)"
    , isArcExtraFooter = \_ _ -> pure []
    }

predictionIndexSpec :: IndexSpec PredictionRecord
predictionIndexSpec =
  IndexSpec
    { isDomainDir = "predictions"
    , isDomainTitle = "Predictions"
    , isChronIntro = "Use this index to browse predictions in chronological order by Arc, Chapter, and Chunk."
    , isTopicIntro = "Use this inverted index to look up all active and resolved predictions associated with a character, faction, artifact, location, or mystery theme."
    , isItemIndex = prOriginChunk
    , isItemChapter = \pr -> (prChapterNumber pr, prChapterTitle pr)
    , isItemPart = \pr -> (prPartInChapter pr, prPartsInChapter pr)
    , isItemTopics = prTopics
    , isDefaultTopic = "General Plot"
    , isRenderChronBullet = \_ pr -> renderPredSummaryBullet pr
    , isRenderTopicBullet = \_ pr -> renderPredSummaryBullet pr
    , isSummarizeArc = \arcPreds ->
        let activeCnt = length [pr | pr <- arcPreds, prStatus pr == PredStatusActive]
            confCnt = length [pr | pr <- arcPreds, case prStatus pr of PredStatusConfirmed {} -> True; _ -> False]
            debCnt = length [pr | pr <- arcPreds, case prStatus pr of PredStatusDebunked {} -> True; _ -> False]
            subCnt = length [pr | pr <- arcPreds, case prStatus pr of PredStatusSubverted {} -> True; _ -> False]
            retCnt = length [pr | pr <- arcPreds, case prStatus pr of PredStatusRetired {} -> True; _ -> False]
         in jsonInt (length arcPreds)
              <> " predictions ("
              <> jsonInt confCnt
              <> " Confirmed, "
              <> jsonInt debCnt
              <> " Debunked, "
              <> jsonInt subCnt
              <> " Subverted, "
              <> jsonInt retCnt
              <> " Retired, "
              <> jsonInt activeCnt
              <> " Active)"
    , isArcExtraFooter = \_ _ -> pure []
    }

collectSessionTopicCounts :: SessionState -> [(Text, Int)]
collectSessionTopicCounts st =
  let rawTags =
        concatMap scrTopics (stStoryRecords st)
          ++ concatMap allEntryTopics (stEntryRecords st)
          ++ concatMap prTopics (stPredictions st)
      counts =
        foldl'
          ( \acc rawT ->
              let c = cleanTopicTag rawT
                  k = topicNormKey c
               in if T.null c || c == "Reader Discussion" || c == "Fact-Check Verification"
                    then acc
                    else
                      case Map.lookup k acc of
                        Nothing -> Map.insert k (c, 1 :: Int) acc
                        Just (oldDisp, n) ->
                          let bestDisp = if T.length c > T.length oldDisp then c else oldDisp
                           in Map.insert k (bestDisp, n + 1) acc
          )
          Map.empty
          rawTags
   in sortOn (\(disp, n) -> (Down n, T.toLower disp)) (Map.elems counts)

collectCanonicalSessionTopics :: SessionState -> [Text]
collectCanonicalSessionTopics = take 30 . map fst . collectSessionTopicCounts

partitionVettedTopics :: SessionState -> ([(Text, Int)], [(Text, Int)])
partitionVettedTopics st =
  let vettedSet = Set.fromList (stCuratedTopics st)
      allCounts = collectSessionTopicCounts st
   in partition (\(disp, _) -> topicNormKey disp `Set.member` vettedSet) allCounts

shouldCurateTopics :: SessionState -> Bool
shouldCurateTopics st =
  let (vetted, unvetted) = partitionVettedTopics st
      totalDistinct = length vetted + length unvetted
      unvettedCnt = length unvetted
      isFinalChunk = stCurrentIndex st >= stTotalChunks st && stTotalChunks st > 0
   in (unvettedCnt >= 8 && totalDistinct >= 10)
        || (isFinalChunk && unvettedCnt >= 3)

applyTopicAliases :: SessionState -> SessionState
applyTopicAliases st
  | null (stTopicAliases st) = st
  | otherwise =
      let aliasMap = Map.fromList (stTopicAliases st)
          rewriteTag raw =
            let cleaned = cleanTopicTag raw
                k = topicNormKey cleaned
             in case Map.lookup k aliasMap of
                  Just canonDisp -> canonDisp
                  Nothing -> cleaned
          rewriteList ts =
            nubBy (\a b -> topicNormKey a == topicNormKey b)
              $ filter (not . T.null) (map rewriteTag ts)
          storyRecords' =
            [ r {scrTopics = rewriteList (scrTopics r)}
            | r <- stStoryRecords st
            ]
          entryRecords' =
            [ r
                { elrTopics = rewriteList (elrTopics r)
                , elrDiscussions =
                    [ d {edrTopics = rewriteList (edrTopics d)}
                    | d <- elrDiscussions r
                    ]
                }
            | r <- stEntryRecords st
            ]
          preds' =
            [ p {prTopics = rewriteList (prTopics p)}
            | p <- stPredictions st
            ]
       in st
            { stStoryRecords = storyRecords'
            , stEntryRecords = entryRecords'
            , stPredictions = preds'
            }

parseTopicMergesSection :: Text -> [(Text, [Text])]
parseTopicMergesSection raw =
  let ls = T.lines raw
      afterHeader =
        case break (\l -> "=== TOPIC MERGES ===" `T.isInfixOf` T.toUpper l) ls of
          (_, _ : rest) -> takeWhile (\l -> not ("===" `T.isPrefixOf` T.stripStart l)) rest
          (allLines, []) -> allLines
      parseLine l =
        let s = T.strip l
            body
              | "- " `T.isPrefixOf` s || "* " `T.isPrefixOf` s = T.strip (T.drop 2 s)
              | otherwise = ""
            upperB = T.toUpper body
         in if T.null body || upperB == "NONE" || upperB == "PASS" || "NONE " `T.isPrefixOf` upperB
              then []
              else
                let (lhs, rhs)
                      | "<=" `T.isInfixOf` body =
                          let (a, b) = T.breakOn "<=" body in (a, T.drop 2 b)
                      | "<-" `T.isInfixOf` body =
                          let (a, b) = T.breakOn "<-" body in (a, T.drop 2 b)
                      | otherwise = ("", "")
                    canon = cleanTopicTag lhs
                    aliases = filter (not . T.null) (map cleanTopicTag (T.splitOn "," rhs))
                 in [(canon, aliases) | not (T.null canon) && not (null aliases)]
   in concatMap parseLine afterHeader

applyTopicCuratorResponse :: Text -> SessionState -> (SessionState, Int)
applyTopicCuratorResponse rawResp st =
  let preCounts = collectSessionTopicCounts st
      countMap = Map.fromList [(topicNormKey disp, (disp, cnt)) | (disp, cnt) <- preCounts]
      stopKeys =
        Set.fromList
          [ ""
          , "general plot"
          , "story progression"
          , "liveblog commentary"
          , "reader discussion"
          , "fact-check verification"
          ]
      proposedRules = parseTopicMergesSection rawResp
      validPairs =
        [ (aKey, canonDisp)
        | (rawCanon, rawAliases) <- proposedRules
        , let cKey = topicNormKey rawCanon
        , cKey `Set.notMember` stopKeys
        , let canonDisp =
                case Map.lookup cKey countMap of
                  Just (existingDisp, _) -> existingDisp
                  Nothing -> rawCanon
        , rawAlias <- rawAliases
        , let aKey = topicNormKey rawAlias
        , aKey /= cKey
        , Map.member aKey countMap
        ]
      existingAliasMap = Map.fromList (stTopicAliases st)
      mergedAliasMap =
        foldl'
          ( \acc (aKey, cDisp) ->
              let cKey = topicNormKey cDisp
                  finalDisp = Map.findWithDefault cDisp cKey acc
                  updatedExisting =
                    Map.map
                      (\v -> if topicNormKey v == aKey then finalDisp else v)
                      acc
               in Map.insert aKey finalDisp updatedExisting
          )
          existingAliasMap
          validPairs
      stWithAliases =
        applyTopicAliases
          (st {stTopicAliases = Map.toList mergedAliasMap})
      postTopics = [topicNormKey disp | (disp, _) <- collectSessionTopicCounts stWithAliases]
      stFinal = stWithAliases {stCuratedTopics = postTopics}
   in (stFinal, length validPairs)
