{-# LANGUAGE OverloadedStrings #-}

module LetsRead.Chunker
  ( parseMarkdownHeading
  , numberChaptersWithFrontMatter
  , splitChapterIntoChunks
  , buildChunksFromSource
  , computeShouldRotate
  , computeShouldRotateMeta
  ) where

import Control.Monad (when)
import Data.Char (isAlphaNum, toLower)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LetsRead.Chunker.Epub (parseEpub)
import LetsRead.Chunker.Html (htmlToMarkdown)
import LetsRead.Chunker.Markdown
  ( isHeadingParagraph
  , isSceneBreak
  , parseMarkdownHeading
  , splitTextIntoChapters
  )
import LetsRead.Types
  ( Chunk (..)
  , ChunkMeta (..)
  , StoryChunkRecord (..)
  , chunkToMeta
  , countWords
  , readTextFileSafe
  )
import System.Exit (die)
import System.FilePath (takeBaseName, takeExtension)

normalizeTitleText :: Text -> Text
normalizeTitleText = T.filter isAlphaNum . T.toLower

isExplicitFrontMatterTitle :: Text -> Bool
isExplicitFrontMatterTitle title =
  let lower = T.strip (T.toLower title)
      exactOrPrefixes =
        [ "front matter"
        , "frontmatter"
        , "title page"
        , "cover"
        , "synopsis"
        , "summary"
        , "author's note"
        , "authors note"
        , "author note"
        , "a/n"
        , "foreword"
        , "preface"
        , "content warning"
        , "trigger warning"
        , "disclaimer"
        , "table of contents"
        , "contents"
        , "dedication"
        , "acknowledgments"
        , "acknowledgements"
        , "copyright"
        , "about the author"
        , "dramatis personae"
        , "cast of characters"
        ]
   in any (\p -> lower == p || (p <> ":") `T.isPrefixOf` lower || (p <> " ") `T.isPrefixOf` lower) exactOrPrefixes

isExplicitStoryChapterTitle :: Text -> Bool
isExplicitStoryChapterTitle title =
  let lower = T.strip (T.toLower title)
      prefixes =
        [ "chapter "
        , "prologue"
        , "epilogue"
        , "interlude"
        , "act "
        , "part "
        , "book "
        ]
   in any (`T.isPrefixOf` lower) prefixes

hasFrontMatterMarkers :: Text -> Bool
hasFrontMatterMarkers body =
  let lower = T.toLower body
      markers =
        [ "written by "
        , "author:"
        , "content warning"
        , "trigger warning"
        , "disclaimer:"
        , "copyright "
        , "all rights reserved"
        , "table of contents"
        , "fanfiction"
        , "originally published"
        ]
   in any (`T.isInfixOf` lower) markers

numberChaptersWithFrontMatter :: Text -> [(Int, Text, Text)] -> [(Int, Text, Text)]
numberChaptersWithFrontMatter _ [] = []
numberChaptersWithFrontMatter _ [(_, onlyTitle, onlyBody)] = [(1, onlyTitle, onlyBody)]
numberChaptersWithFrontMatter bookTitle sections =
  let hasH2Chapters = any (\(lvl, _, _) -> lvl == 2) sections
      h1Count = length [() | (1, _, _) <- sections]
      normBookTitle = normalizeTitleText bookTitle

      isFrontSection :: (Int, Text, Text) -> Bool
      isFrontSection (lvl, title, body)
        | isExplicitFrontMatterTitle title = True
        | isExplicitStoryChapterTitle title = False
        | lvl == 0 = True
        | lvl == 1 && h1Count == 1 && hasH2Chapters = True
        | not (T.null normBookTitle)
            && normalizeTitleText title == normBookTitle
            && (countWords body <= 800 || hasFrontMatterMarkers body) =
            True
        | countWords body <= 600 && hasFrontMatterMarkers body = True
        | otherwise = False

      splitFront :: [(Int, Text, Text)] -> ([(Int, Text, Text)], [(Int, Text, Text)])
      splitFront [] = ([], [])
      splitFront [lastSec] = ([], [lastSec])
      splitFront (s : rest)
        | isFrontSection s =
            let (moreFront, remaining) = splitFront rest
             in (s : moreFront, remaining)
        | otherwise = ([], s : rest)

      (frontSecs, storySecs) = splitFront sections
      numberedStory =
        [ (chapNum, chapTitle, chapBody)
        | (chapNum, (_, chapTitle, chapBody)) <- zip [1 ..] storySecs
        ]
   in case frontSecs of
        [] -> numberedStory
        ((_, firstFrontTitle, _) : _) ->
          let combinedFrontBody = T.intercalate "\n\n---\n\n" [b | (_, _, b) <- frontSecs]
              lowerFront = T.toLower firstFrontTitle
              frontDisplayTitle =
                if "front matter" `T.isInfixOf` lowerFront
                  then firstFrontTitle
                  else firstFrontTitle <> " (Front Matter)"
           in (0, frontDisplayTitle, combinedFrontBody) : numberedStory

splitParagraphs :: Text -> [Text]
splitParagraphs txt =
  let ls = map T.stripEnd (T.lines txt)
      groups [] = []
      groups xs =
        let nonBlank = dropWhile (T.null . T.strip) xs
            (paraLines, rest) = break (T.null . T.strip) nonBlank
         in if null paraLines
              then []
              else T.strip (T.unlines paraLines) : groups rest
   in filter (not . T.null) (groups ls)

groupScenes :: [Text] -> [[Text]]
groupScenes [] = []
groupScenes paras = go [] paras
  where
    go cur [] = [reverse cur | not (null cur)]
    go cur (p : ps)
      | isSceneBreak p =
          if null cur
            then go [p] ps
            else reverse (p : cur) : go [] ps
      | isHeadingParagraph p && any (not . isHeadingParagraph) cur =
          reverse cur : go [p] ps
      | otherwise = go (p : cur) ps

splitOversizedParagraph :: Int -> Text -> [Text]
splitOversizedParagraph maxWords para
  | countWords para <= maxWords = [para]
  | otherwise =
      let ws = T.words para
          totalW = length ws
          k = (totalW + maxWords - 1) `div` maxWords
          chunkW = (totalW + k - 1) `div` k
          groupsOf _ [] = []
          groupsOf n xs =
            let (h, t) = splitAt n xs
             in T.unwords h : groupsOf n t
       in groupsOf chunkW ws

splitChapterIntoChunks :: Int -> Text -> [Text]
splitChapterIntoChunks maxWords chapText
  | countWords chapText <= maxWords = [T.strip chapText]
  | otherwise =
      let rawParas = splitParagraphs chapText
          paras = concatMap (splitOversizedParagraph maxWords) rawParas
          scenes = groupScenes paras
          sceneBlocks = concatMap (splitOversizedScene maxWords) scenes
          packed = packBalanced maxWords sceneBlocks
       in mergeTinyTrailing maxWords packed

splitOversizedScene :: Int -> [Text] -> [Text]
splitOversizedScene maxWords scene
  | sum (map countWords scene) <= maxWords = [T.intercalate "\n\n" scene]
  | otherwise = packBalanced maxWords (glueSceneEnds scene)

glueSceneEnds :: [Text] -> [Text]
glueSceneEnds paras =
  let (headings, rest) = span (\p -> isHeadingParagraph p && not (isSceneBreak p)) paras
      withHeadings = case (headings, rest) of
        ([], xs) -> xs
        (hs, x : xs) -> T.intercalate "\n\n" (hs ++ [x]) : xs
        (hs, []) -> [T.intercalate "\n\n" hs]
   in case reverse withHeadings of
        (lastP : prevP : moreRev)
          | isSceneBreak lastP -> reverse ((prevP <> "\n\n" <> lastP) : moreRev)
        _ -> withHeadings

packBalanced :: Int -> [Text] -> [Text]
packBalanced maxWords items = go (sum (map countWords items)) [] 0 items
  where
    go _ [] _ [] = []
    go _ cur _ [] = [T.intercalate "\n\n" (reverse cur)]
    go remWords cur curWords (x : xs) =
      let w = countWords x
          k = max 1 ((remWords + maxWords - 1) `div` maxWords)
          target = remWords `div` k
          afterWords = remWords - curWords
          mustFlush = curWords > 0 && curWords + w > maxWords
          shouldFlush =
            curWords > 0
              && k > 1
              && curWords + (w `div` 2) >= target
              && afterWords <= (k - 1) * maxWords
       in if mustFlush || shouldFlush
            then T.intercalate "\n\n" (reverse cur) : go afterWords [x] w xs
            else go remWords (x : cur) (curWords + w) xs

mergeTinyTrailing :: Int -> [Text] -> [Text]
mergeTinyTrailing maxWords chunks =
  let minWords = max 150 (maxWords `div` 5)
   in case reverse chunks of
        (lastChunk : prevChunk : restRev)
          | countWords lastChunk < minWords ->
              reverse ((prevChunk <> "\n\n" <> lastChunk) : restRev)
        _ -> chunks

buildChunksFromSource :: FilePath -> Int -> Maybe Text -> IO (Text, [Chunk])
buildChunksFromSource sourcePath maxWords mTitleOverride = do
  let ext = map toLower (takeExtension sourcePath)
      defaultTitle = T.pack (takeBaseName sourcePath)
  (detectedTitle, chapters) <-
    case ext of
      ".epub" -> parseEpub sourcePath
      ".html" -> do
        raw <- readTextFileSafe sourcePath
        let md = htmlToMarkdown raw
        pure (defaultTitle, splitTextIntoChapters defaultTitle md)
      ".htm" -> do
        raw <- readTextFileSafe sourcePath
        let md = htmlToMarkdown raw
        pure (defaultTitle, splitTextIntoChapters defaultTitle md)
      _ -> do
        raw <- readTextFileSafe sourcePath
        pure (defaultTitle, splitTextIntoChapters defaultTitle raw)

  let bookTitle = fromMaybe detectedTitle mTitleOverride
      numberedChapters = numberChaptersWithFrontMatter bookTitle chapters
      chapChunks =
        [ (chapNum, chapTitle, partIdx, totalParts, partText)
        | (chapNum, chapTitle, chapBody) <- numberedChapters
        , let parts = splitChapterIntoChunks maxWords chapBody
              totalParts = length parts
        , (partIdx, partText) <- zip [1 ..] parts
        ]
      allChunks =
        [ Chunk
            { chunkIndex = globalIdx
            , chapterNumber = chapNum
            , chapterTitle = chapTitle
            , partInChapter = partIdx
            , partsInChapter = totalParts
            , isChapterStart = partIdx == 1
            , isChapterEnd = partIdx == totalParts
            , wordCount = countWords partText
            , chunkText = partText
            }
        | (globalIdx, (chapNum, chapTitle, partIdx, totalParts, partText)) <- zip [1 ..] chapChunks
        ]

  when (null allChunks) $
    die ("Error: No readable story content found in " ++ sourcePath)

  pure (bookTitle, allChunks)

computeShouldRotate :: [StoryChunkRecord] -> Chunk -> Bool
computeShouldRotate history chunk = computeShouldRotateMeta history (chunkToMeta chunk)

computeShouldRotateMeta :: [StoryChunkRecord] -> ChunkMeta -> Bool
computeShouldRotateMeta history meta =
  let nextIdx = metaChunkIndex meta
      priorEntries =
        sortOn
          scrChunkIndex
          [ e
          | e <- history
          , scrChunkIndex e > 1
          , scrChunkIndex e < nextIdx
          ]
      stepLastRot lastRot e =
        let idx = scrChunkIndex e
            sinceLast = idx - lastRot
            rotatedHere =
              (scrPartInChapter e == 1 && (sinceLast >= 6 || sinceLast + scrPartsInChapter e > 9))
                || sinceLast >= 15
         in if rotatedHere then idx else lastRot
      lastRotIdx = foldl' stepLastRot 1 priorEntries
      chunksSinceRotation = nextIdx - lastRotIdx
   in nextIdx > 1
        && ( ( metaIsChapterStart meta
                 && (chunksSinceRotation >= 6 || chunksSinceRotation + metaPartsInChapter meta > 9)
             )
               || chunksSinceRotation >= 15
           )
