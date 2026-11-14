{-# LANGUAGE OverloadedStrings #-}

module LetsRead.Chunker.Markdown
  ( parseMarkdownHeading
  , isPlainChapterHeading
  , isHeadingParagraph
  , isSceneBreak
  , normalizeMarkdown
  , splitTextIntoChapters
  ) where

import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LetsRead.Types (countWords)

normalizeMarkdown :: Text -> Text
normalizeMarkdown raw =
  let normLines = map cleanLine (T.lines (T.replace "\r\n" "\n" (T.replace "\r" "\n" raw)))
      paras = splitBlankGroups normLines
   in T.intercalate "\n\n" (map (T.intercalate "\n") paras)
  where
    cleanLine l = T.unwords (T.words l)
    splitBlankGroups [] = []
    splitBlankGroups ls =
      let nonBlank = dropWhile T.null ls
          (grp, rest) = break T.null nonBlank
       in if null grp then [] else grp : splitBlankGroups rest

parseMarkdownHeading :: Text -> Maybe (Int, Text)
parseMarkdownHeading line =
  let s = T.strip line
      hashes = T.takeWhile (== '#') s
      n = T.length hashes
      afterHashes = T.drop n s
   in if n >= 1 && n <= 6 && not (T.null afterHashes) && isSpace (T.head afterHashes)
        then
          let title = T.strip afterHashes
           in if T.null title then Nothing else Just (n, title)
        else Nothing

isPlainChapterHeading :: Text -> Maybe Text
isPlainChapterHeading line =
  let s = T.strip line
      lower = T.toLower s
      prefixes =
        [ "chapter "
        , "prologue"
        , "epilogue"
        , "interlude"
        , "part "
        , "book "
        , "act "
        ]
   in if T.length s <= 85 && any (`T.isPrefixOf` lower) prefixes
        then Just s
        else Nothing

isHeadingParagraph :: Text -> Bool
isHeadingParagraph para =
  case T.lines (T.strip para) of
    [singleLine] ->
      case parseMarkdownHeading singleLine of
        Just _ -> True
        Nothing -> False
    _ -> False

isSceneBreak :: Text -> Bool
isSceneBreak para =
  let s = T.strip para
      noSpaces = T.filter (not . isSpace) s
   in s == "#"
        || (T.length noSpaces >= 3
              && (T.all (== '*') noSpaces
                    || T.all (== '-') noSpaces
                    || T.all (== '_') noSpaces
                    || T.all (== '~') noSpaces))

splitTextIntoChapters :: Text -> Text -> [(Int, Text, Text)]
splitTextIntoChapters defaultTitle rawText =
  let norm = T.replace "\r\n" "\n" (T.replace "\r" "\n" rawText)
      ls = T.lines norm
      total = length ls
      indexed = zip [0 ..] ls

      isStandalone :: Int -> Bool
      isStandalone i =
        let prevBlank = i == 0 || T.null (T.strip (ls !! (i - 1)))
            nextBlank = i + 1 >= total || T.null (T.strip (ls !! (i + 1)))
         in prevBlank && nextBlank

      standaloneMdHeadings =
        [ (lvl, title)
        | (i, line) <- indexed
        , isStandalone i
        , Just (lvl, title) <- [parseMarkdownHeading line]
        ]
      h1Count = length [() | (1, _) <- standaloneMdHeadings]
      h2Count = length [() | (2, _) <- standaloneMdHeadings]

      -- If the document uses multiple H1 (#) headings, H1 is the chapter level
      -- and H2+ (##, ###) are sub-headings within chapters.
      -- Otherwise, if H1 is used at most once (e.g. document title) and H2 (##)
      -- is used for chapters, allow levels 1 and 2 as chapter boundaries.
      maxChapterHeadingLevel :: Int
      maxChapterHeadingLevel
        | h1Count >= 2 = 1
        | h2Count >= 1 = 2
        | otherwise = 2

      matchChapterHeading :: Int -> Text -> Maybe (Int, Text)
      matchChapterHeading i line
        | not (isStandalone i) = Nothing
        | Just (lvl, title) <- parseMarkdownHeading line =
            if lvl <= maxChapterHeadingLevel
              then Just (lvl, title)
              else Nothing
        | h1Count <= 1 && h2Count == 0 =
            fmap (\t -> (1, t)) (isPlainChapterHeading line)
        | otherwise = Nothing

      step
        :: (Maybe (Int, Text), [Text], [(Int, Text, Text)])
        -> (Int, Text)
        -> (Maybe (Int, Text), [Text], [(Int, Text, Text)])
      step (mCurHeading, curLines, acc) (i, line) =
        case matchChapterHeading i line of
          Just (newLvl, newTitle) ->
            let body = T.strip (T.unlines (reverse curLines))
             in case mCurHeading of
                  Nothing
                    | not (T.null body) && countWords body >= 20 ->
                        (Just (newLvl, newTitle), [line], (0, defaultTitle, body) : acc)
                    | otherwise ->
                        (Just (newLvl, newTitle), line : curLines, acc)
                  Just (prevLvl, prevTitle)
                    | not (T.null body) && length (filter (not . T.null . T.strip) curLines) > 1 ->
                        (Just (newLvl, newTitle), [line], (prevLvl, prevTitle, body) : acc)
                    | otherwise ->
                        (Just (newLvl, newTitle), line : curLines, acc)
          Nothing -> (mCurHeading, line : curLines, acc)

      (mLastHeading, lastLines, revChapters) = foldl step (Nothing, [], []) indexed
      lastBody = T.strip (T.unlines (reverse lastLines))
      (finalLvl, finalTitle) = fromMaybe (1, defaultTitle) mLastHeading
      allChapters =
        reverse $
          if T.null lastBody
            then revChapters
            else (finalLvl, finalTitle, lastBody) : revChapters
   in [(lvl, t, b) | (lvl, t, b) <- allChapters, not (T.null b)]
