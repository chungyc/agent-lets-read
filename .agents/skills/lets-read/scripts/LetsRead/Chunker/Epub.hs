{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LetsRead.Chunker.Epub
  ( extractXmlTags
  , parseXmlAttrs
  , extractFirstTagText
  , readZipEntry
  , parseEpub
  ) where

import Control.Exception (IOException, catch)
import Control.Monad (forM)
import Data.Char (isSpace)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LetsRead.Chunker.Html (decodeEntities, htmlToMarkdown)
import LetsRead.Chunker.Markdown (parseMarkdownHeading)
import LetsRead.Types (countWords, jsonInt)
import System.Exit (ExitCode (..), die)
import System.FilePath (takeBaseName)
import qualified System.FilePath.Posix as Posix
import System.Process (readProcessWithExitCode)

-- | Extract all occurrences of `<tagName ...>` or `<ns:tagName ...>` and their attributes
extractXmlTags :: Text -> Text -> [[(Text, Text)]]
extractXmlTags targetTag = go
  where
    targetLower = T.toLower targetTag
    go txt =
      let (_, rest) = T.breakOn "<" txt
       in if T.null rest
            then []
            else
              let (tagContent, afterClose) = T.breakOn ">" (T.drop 1 rest)
               in if T.null afterClose
                    then []
                    else
                      let nextTxt = T.drop 1 afterClose
                          trimmed = T.strip tagContent
                          isEndOrSpecial =
                            "/" `T.isPrefixOf` trimmed
                              || "?" `T.isPrefixOf` trimmed
                              || "!" `T.isPrefixOf` trimmed
                          rawName = T.takeWhile (\c -> not (isSpace c) && c /= '/') trimmed
                          localName = T.toLower (snd (T.breakOnEnd ":" rawName))
                       in if not isEndOrSpecial && localName == targetLower
                            then parseXmlAttrs (T.drop (T.length rawName) trimmed) : go nextTxt
                            else go nextTxt

parseXmlAttrs :: Text -> [(Text, Text)]
parseXmlAttrs txt =
  let s = T.strip (fromMaybe txt (T.stripSuffix "/" (T.strip txt)))
   in if T.null s
        then []
        else
          let (rawKey, rest1) = T.break (\c -> c == '=' || isSpace c) s
              key = T.toLower (T.strip rawKey)
              afterEq = T.strip (T.drop 1 (T.dropWhile (/= '=') rest1))
           in case T.uncons afterEq of
                Just (q, rest2)
                  | q == '"' || q == '\'' ->
                      let (val, rest3) = T.break (== q) rest2
                       in (key, decodeEntities val) : parseXmlAttrs (T.drop 1 rest3)
                _ -> []

-- | Extract inner text of the first matching `<tagName ...>INNER</tagName>` (namespace-insensitive)
extractFirstTagText :: Text -> Text -> Maybe Text
extractFirstTagText targetTag = go
  where
    targetLower = T.toLower targetTag
    go txt =
      let (_, rest) = T.breakOn "<" txt
       in if T.null rest
            then Nothing
            else
              let (tagHeader, afterOpen) = T.breakOn ">" (T.drop 1 rest)
               in if T.null afterOpen
                    then Nothing
                    else
                      let afterTag = T.drop 1 afterOpen
                          trimmed = T.strip tagHeader
                          rawName = T.takeWhile (\c -> not (isSpace c) && c /= '/') trimmed
                          localName = T.toLower (snd (T.breakOnEnd ":" rawName))
                          isSelfClosing = "/" `T.isSuffixOf` trimmed
                       in if not ("/" `T.isPrefixOf` trimmed) && not isSelfClosing && localName == targetLower
                            then
                              let closePat = "</" <> rawName <> ">"
                                  (inner, _) = T.breakOn closePat afterTag
                               in Just (T.strip (decodeEntities inner))
                            else go afterTag

readZipEntry :: FilePath -> FilePath -> IO (Maybe Text)
readZipEntry epubPath entryPath = do
  (code, out, _) <-
    readProcessWithExitCode "unzip" ["-p", epubPath, entryPath] ""
      `catch` (\(_ :: IOException) -> pure (ExitFailure 1, "", ""))
  case code of
    ExitSuccess -> pure (Just (T.pack out))
    ExitFailure _ -> pure Nothing

parseEpub :: FilePath -> IO (Text, [(Int, Text, Text)])
parseEpub epubPath = do
  mContainer <- readZipEntry epubPath "META-INF/container.xml"
  containerXml <-
    case mContainer of
      Nothing -> die ("Error: Invalid EPUB (missing META-INF/container.xml): " ++ epubPath)
      Just xml -> pure xml

  let rootfiles = extractXmlTags "rootfile" containerXml
      mOpfPath = listToMaybe [val | attrs <- rootfiles, ("full-path", val) <- attrs]
  opfPathText <-
    case mOpfPath of
      Nothing -> die "Error: Invalid EPUB (no rootfile full-path in container.xml)"
      Just p -> pure p

  let opfPath = T.unpack opfPathText
      opfDir = Posix.takeDirectory opfPath
      resolveHref href =
        let rawHref = T.unpack (fst (T.breakOn "#" href))
         in if opfDir == "." || null opfDir
              then Posix.normalise rawHref
              else Posix.normalise (opfDir Posix.</> rawHref)

  mOpfXml <- readZipEntry epubPath opfPath
  opfXml <-
    case mOpfXml of
      Nothing -> die ("Error: Could not read OPF file in EPUB: " ++ opfPath)
      Just xml -> pure xml

  let defaultBookTitle = T.pack (takeBaseName epubPath)
      bookTitle =
        case extractFirstTagText "title" opfXml of
          Just t | not (T.null t) -> t
          _ -> defaultBookTitle

      manifestItems = extractXmlTags "item" opfXml
      manifestMap =
        Map.fromList
          [ (itemId, resolveHref href)
          | attrs <- manifestItems
          , Just itemId <- [lookup "id" attrs]
          , Just href <- [lookup "href" attrs]
          , let mtype = fromMaybe "" (lookup "media-type" attrs)
          , "html" `T.isInfixOf` mtype
              || any (`T.isSuffixOf` T.toLower href) [".xhtml", ".html", ".htm", ".xml"]
          ]

      spineRefs =
        [ idref
        | attrs <- extractXmlTags "itemref" opfXml
        , lookup "linear" attrs /= Just "no"
        , Just idref <- [lookup "idref" attrs]
        ]

  rawSections <- forM spineRefs $ \idref ->
    case Map.lookup idref manifestMap of
      Nothing -> pure Nothing
      Just entryPath -> do
        mHtml <- readZipEntry epubPath entryPath
        case mHtml of
          Nothing -> pure Nothing
          Just htmlTxt -> do
            let md = htmlToMarkdown htmlTxt
            if countWords md < 5
              then pure Nothing
              else pure (Just md)

  let validMds = [md | Just md <- rawSections]
      withTitles = zipWith assignSectionTitle [1 ..] validMds
  pure (bookTitle, withTitles)
  where
    assignSectionTitle :: Int -> Text -> (Int, Text, Text)
    assignSectionTitle idx md =
      case T.lines md of
        (firstLine : _)
          | Just (lvl, title) <- parseMarkdownHeading firstLine ->
              (lvl, title, md)
          | "#" `T.isPrefixOf` firstLine ->
              let title = T.strip (T.dropWhile (== '#') firstLine)
               in (1, if T.null title then "Section " <> jsonInt idx else title, md)
        _ -> (1, "Section " <> jsonInt idx, md)
