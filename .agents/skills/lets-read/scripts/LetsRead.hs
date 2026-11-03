#!/usr/bin/env runghc
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Spoiler-free Gatekeeper & Chunker for AI-hosted Let's Reads
--
-- Parses stories (.txt, .md, .html, .epub) into an obfuscated binary vault
-- (.vault.bin) and dispenses one reading chunk at a time into a session
-- directory so neither the orchestrator nor the blind-reader subagent can
-- accidentally spoil itself on future chapters.
--
-- Uses only GHC boot libraries (base, binary, bytestring, containers,
-- directory, filepath, process, text).

module Main (main) where

import Control.Exception (IOException, catch)
import Control.Monad (forM, unless, when)
import Data.Binary (Binary, decode, encode)
import Data.Bits (xor)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Char (chr, isAlphaNum, isDigit, isHexDigit, isSpace, toLower)
import Data.List (groupBy, isPrefixOf, isSuffixOf, nub, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.IO as TIO
import Data.Word (Word8)
import GHC.Generics (Generic)
import Numeric (readHex)
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  , listDirectory
  )
import System.Environment (getArgs)
import System.Exit (ExitCode (..), die, exitSuccess)
import System.FilePath
  ( takeBaseName
  , takeDirectory
  , takeExtension
  , takeFileName
  , (</>)
  )
import qualified System.FilePath.Posix as Posix
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

-- ---------------------------------------------------------------------------
-- Data Types
-- ---------------------------------------------------------------------------

data Chunk = Chunk
  { chunkIndex :: !Int
  , chapterNumber :: !Int
  , chapterTitle :: !Text
  , partInChapter :: !Int
  , partsInChapter :: !Int
  , isChapterStart :: !Bool
  , isChapterEnd :: !Bool
  , wordCount :: !Int
  , chunkText :: !Text
  }
  deriving (Show, Eq, Generic)

instance Binary Chunk

data ChunkMeta = ChunkMeta
  { metaChunkIndex :: !Int
  , metaChapterNumber :: !Int
  , metaChapterTitle :: !Text
  , metaPartInChapter :: !Int
  , metaPartsInChapter :: !Int
  , metaIsChapterStart :: !Bool
  , metaIsChapterEnd :: !Bool
  , metaWordCount :: !Int
  }
  deriving (Show, Eq, Generic)

instance Binary ChunkMeta

chunkToMeta :: Chunk -> ChunkMeta
chunkToMeta c =
  ChunkMeta
    { metaChunkIndex = chunkIndex c
    , metaChapterNumber = chapterNumber c
    , metaChapterTitle = chapterTitle c
    , metaPartInChapter = partInChapter c
    , metaPartsInChapter = partsInChapter c
    , metaIsChapterStart = isChapterStart c
    , metaIsChapterEnd = isChapterEnd c
    , metaWordCount = wordCount c
    }

data ChunkIndexEntry = ChunkIndexEntry
  { cieChunkIndex :: !Int
  , cieChapterNumber :: !Int
  , cieChapterTitle :: !Text
  , ciePartInChapter :: !Int
  , ciePartsInChapter :: !Int
  , cieSummary :: !Text
  }
  deriving (Show, Eq, Generic)

instance Binary ChunkIndexEntry

data SessionState = SessionState
  { stTitle :: !Text
  , stPersona :: !Text
  , stMaxWords :: !Int
  , stTotalChunks :: !Int
  , stTotalChapters :: !Int
  , stTotalWords :: !Int
  , stCurrentIndex :: !Int
  , stCurrentRecorded :: !Bool
  , stCurrentMeta :: !(Maybe ChunkMeta)
  , stCompletedChunks :: ![Int]
  , stChunkIndex :: ![ChunkIndexEntry]
  , stCuratedMemory :: ![(Text, Text)]
  }
  deriving (Show, Eq, Generic)

instance Binary SessionState

-- ---------------------------------------------------------------------------
-- Vault Obfuscation (Prevents grep / strings spoilers)
-- ---------------------------------------------------------------------------

vaultMask :: [Word8]
vaultMask = cycle [0xA5, 0x5A, 0xC3, 0x3C, 0x96, 0x69, 0xF0, 0x0F]

obfuscate :: BSL.ByteString -> BSL.ByteString
obfuscate = BSL.pack . zipWith xor vaultMask . BSL.unpack

saveVault :: FilePath -> [Chunk] -> IO ()
saveVault path chunks = BSL.writeFile path (obfuscate (encode chunks))

loadVaultChunk :: FilePath -> Int -> IO Chunk
loadVaultChunk path idx = do
  raw <- BSL.fromStrict <$> BS.readFile path
  let chunks = decode (obfuscate raw) :: [Chunk]
  if idx < 1 || idx > length chunks
    then die $ "Error: Chunk index " ++ show idx ++ " out of bounds (1.." ++ show (length chunks) ++ ")"
    else pure (chunks !! (idx - 1))

saveState :: FilePath -> SessionState -> IO ()
saveState sessionDir st = do
  BS.writeFile (sessionDir </> ".state.bin") (BSL.toStrict (encode st))
  TIO.writeFile (sessionDir </> "state.json") (renderStateJson sessionDir st)

loadState :: FilePath -> IO SessionState
loadState sessionDir = do
  let binPath = sessionDir </> ".state.bin"
  exists <- doesFileExist binPath
  unless exists $
    die ("Error: Session not initialized in " ++ sessionDir)
  raw <- BSL.fromStrict <$> BS.readFile binPath
  pure (decode raw)

-- ---------------------------------------------------------------------------
-- JSON Rendering Helpers
-- ---------------------------------------------------------------------------

escapeJson :: Text -> Text
escapeJson = T.concatMap esc
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c
      | c < ' ' = T.singleton ' '
      | otherwise = T.singleton c

jsonStr :: Text -> Text
jsonStr s = "\"" <> escapeJson s <> "\""

jsonBool :: Bool -> Text
jsonBool True = "true"
jsonBool False = "false"

jsonInt :: Int -> Text
jsonInt = T.pack . show

jsonObject :: [(Text, Text)] -> Text
jsonObject pairs =
  "{\n"
    <> T.intercalate ",\n" [ "  " <> jsonStr k <> ": " <> v | (k, v) <- pairs ]
    <> "\n}"

renderMetaJson :: Maybe ChunkMeta -> Text
renderMetaJson Nothing = "null"
renderMetaJson (Just m) =
  "{\n"
    <> T.intercalate
      ",\n"
      [ "    \"chunk_index\": " <> jsonInt (metaChunkIndex m)
      , "    \"chapter_number\": " <> jsonInt (metaChapterNumber m)
      , "    \"chapter_title\": " <> jsonStr (metaChapterTitle m)
      , "    \"part_in_chapter\": " <> jsonInt (metaPartInChapter m)
      , "    \"parts_in_chapter\": " <> jsonInt (metaPartsInChapter m)
      , "    \"is_chapter_start\": " <> jsonBool (metaIsChapterStart m)
      , "    \"is_chapter_end\": " <> jsonBool (metaIsChapterEnd m)
      , "    \"word_count\": " <> jsonInt (metaWordCount m)
      ]
    <> "\n  }"

orchestratorRuleText :: Text
orchestratorRuleText =
  "NEVER run python, python3, or ad-hoc shell scripts; NEVER impersonate blind-reader, answer user story questions in your own voice, edit memory.md directly, or paste current_chunk.md/memory.md inline into prompts. Always pass the prompt from <session_dir>/current_prompt.md so blind-reader reads current_chunk.md and memory.md from disk, prefix chat output with a 1-line third-person host banner, forward user comments/questions to blind-reader via send_message, and record turns/exchanges using 'lets-read record' / 'lets-read discuss' (with --response-file, --subagent-log, --user-file, --commentary-file, or --memory-file)."

renderStateJson :: FilePath -> SessionState -> Text
renderStateJson sessionDir st =
  jsonObject
    [ ("title", jsonStr (stTitle st))
    , ("persona", jsonStr (stPersona st))
    , ("max_words_per_chunk", jsonInt (stMaxWords st))
    , ("current_index", jsonInt (stCurrentIndex st))
    , ("total_chunks", jsonInt (stTotalChunks st))
    , ("total_chapters", jsonInt (stTotalChapters st))
    , ("total_words", jsonInt (stTotalWords st))
    , ("current_recorded", jsonBool (stCurrentRecorded st))
    , ("completed_chunks_count", jsonInt (length (stCompletedChunks st)))
    , ("is_finished", jsonBool (stCurrentIndex st >= stTotalChunks st && stCurrentRecorded st))
    , ("current_chunk_meta", renderMetaJson (stCurrentMeta st))
    , ("current_chunk_file", jsonStr (T.pack (sessionDir </> "current_chunk.md")))
    , ("subagent_prompt_file", jsonStr (T.pack (sessionDir </> "current_prompt.md")))
    , ("chunks_dir", jsonStr (T.pack (sessionDir </> "chunks")))
    , ("story_so_far_file", jsonStr (T.pack (sessionDir </> "story_so_far.md")))
    , ("entries_dir", jsonStr (T.pack (sessionDir </> "entries")))
    , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
    , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
    , ("log_file", jsonStr (T.pack (sessionDir </> "lets_read_log.md")))
    , ("orchestrator_rule", jsonStr orchestratorRuleText)
    ]
    <> "\n"

-- ---------------------------------------------------------------------------
-- HTML / XHTML / XML Parsing & Conversion to Markdown
-- ---------------------------------------------------------------------------

-- | Strip specific container tags and their entire contents (e.g. <script>...</script>)
stripTagBlocks :: Text -> Text -> Text
stripTagBlocks tagName = go
  where
    openPat = "<" <> T.toLower tagName
    closePat = "</" <> T.toLower tagName <> ">"
    go txt =
      let lowerTxt = T.toLower txt
          (beforeIdx, restLower) = T.breakOn openPat lowerTxt
       in if T.null restLower
            then txt
            else
              let prefixLen = T.length beforeIdx
                  beforeOrig = T.take prefixLen txt
                  afterOpenOrig = T.drop prefixLen txt
                  afterOpenLower = restLower
                  -- Check that tag name is followed by space, '>', or '/'
                  afterTagName = T.drop (T.length openPat) afterOpenLower
                  validTag =
                    case T.uncons afterTagName of
                      Nothing -> False
                      Just (c, _) -> isSpace c || c == '>' || c == '/'
               in if not validTag
                    then
                      let step = T.length openPat
                       in beforeOrig <> T.take step afterOpenOrig <> go (T.drop step afterOpenOrig)
                    else
                      let (untilClose, afterCloseLower) = T.breakOn closePat afterOpenLower
                       in if T.null afterCloseLower
                            then beforeOrig
                            else
                              let dropLen = T.length untilClose + T.length closePat
                               in beforeOrig <> go (T.drop dropLen afterOpenOrig)

stripComments :: Text -> Text
stripComments txt =
  let (before, rest) = T.breakOn "<!--" txt
   in if T.null rest
        then txt
        else
          let (_, afterClose) = T.breakOn "-->" (T.drop 4 rest)
           in if T.null afterClose
                then before
                else before <> stripComments (T.drop 3 afterClose)

decodeEntity :: Text -> Text
decodeEntity ent =
  case ent of
    "amp" -> "&"
    "lt" -> "<"
    "gt" -> ">"
    "quot" -> "\""
    "apos" -> "'"
    "nbsp" -> " "
    "mdash" -> "—"
    "ndash" -> "–"
    "hellip" -> "…"
    "lsquo" -> "‘"
    "rsquo" -> "’"
    "ldquo" -> "“"
    "rdquo" -> "”"
    "copy" -> "©"
    _
      | Just hexTxt <- T.stripPrefix "#x" (T.toLower ent)
      , not (T.null hexTxt) && T.all isHexDigit hexTxt ->
          case readHex (T.unpack hexTxt) of
            [(n, "")] | n > 0 && n <= 0x10FFFF -> T.singleton (chr n)
            _ -> "&" <> ent <> ";"
      | Just decTxt <- T.stripPrefix "#" ent
      , not (T.null decTxt) && T.all isDigit decTxt ->
          let n = read (T.unpack decTxt) :: Int
           in if n > 0 && n <= 0x10FFFF
                then T.singleton (chr n)
                else "&" <> ent <> ";"
      | otherwise -> "&" <> ent <> ";"

decodeEntities :: Text -> Text
decodeEntities txt =
  let (before, rest) = T.breakOn "&" txt
   in if T.null rest
        then txt
        else
          let afterAmp = T.drop 1 rest
              (candidate, afterSemi) = T.span (\c -> c /= ';' && c /= '&' && not (isSpace c)) afterAmp
           in if not (T.null candidate) && T.length candidate <= 12 && ";" `T.isPrefixOf` afterSemi
                then before <> decodeEntity candidate <> decodeEntities (T.drop 1 afterSemi)
                else before <> "&" <> decodeEntities afterAmp

translateTag :: Text -> Text
translateTag rawTag =
  let inner = T.strip (T.drop 1 (T.dropEnd 1 rawTag))
      isClosing = "/" `T.isPrefixOf` inner
      cleaned = T.strip (if isClosing then T.drop 1 inner else inner)
      tagName = T.toLower (T.takeWhile (\c -> isAlphaNum c || c == ':' || c == '-') cleaned)
   in case (isClosing, tagName) of
        (False, "h1") -> "\n\n# "
        (False, "h2") -> "\n\n## "
        (False, "h3") -> "\n\n### "
        (False, "h4") -> "\n\n#### "
        (False, "h5") -> "\n\n##### "
        (False, "h6") -> "\n\n###### "
        (True, "h1") -> "\n\n"
        (True, "h2") -> "\n\n"
        (True, "h3") -> "\n\n"
        (True, "h4") -> "\n\n"
        (True, "h5") -> "\n\n"
        (True, "h6") -> "\n\n"
        (False, "p") -> "\n\n"
        (True, "p") -> "\n\n"
        (False, "div") -> "\n\n"
        (True, "div") -> "\n\n"
        (False, "section") -> "\n\n"
        (True, "section") -> "\n\n"
        (False, "article") -> "\n\n"
        (True, "article") -> "\n\n"
        (False, "blockquote") -> "\n\n> "
        (True, "blockquote") -> "\n\n"
        (False, "li") -> "\n- "
        (True, "li") -> "\n"
        (False, "br") -> "\n"
        (False, "hr") -> "\n\n* * *\n\n"
        (_, "em") -> "*"
        (_, "i") -> "*"
        (_, "strong") -> "**"
        (_, "b") -> "**"
        _ -> ""

convertTags :: Text -> Text
convertTags txt =
  let (before, rest) = T.breakOn "<" txt
   in if T.null rest
        then txt
        else
          let (tagBody, afterClose) = T.breakOn ">" rest
           in if T.null afterClose
                then before
                else
                  let fullTag = tagBody <> ">"
                   in before <> translateTag fullTag <> convertTags (T.drop 1 afterClose)

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

htmlToMarkdown :: Text -> Text
htmlToMarkdown =
  normalizeMarkdown
    . decodeEntities
    . convertTags
    . stripComments
    . stripSkippedTags
  where
    skippedTags = ["script", "style", "head", "nav", "footer", "noscript", "svg", "math"]
    stripSkippedTags txt = foldr stripTagBlocks txt skippedTags

-- ---------------------------------------------------------------------------
-- Lightweight XML Tag & Attribute Extraction (for EPUB OPF/NCX/Container)
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- EPUB Parsing (via unzip -p)
-- ---------------------------------------------------------------------------

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
    assignSectionTitle :: Int -> (Text) -> (Int, Text, Text)
    assignSectionTitle idx md =
      case T.lines md of
        (firstLine : _)
          | Just (lvl, title) <- parseMarkdownHeading firstLine ->
              (lvl, title, md)
          | "#" `T.isPrefixOf` firstLine ->
              let title = T.strip (T.dropWhile (== '#') firstLine)
               in (1, if T.null title then "Section " <> jsonInt idx else title, md)
        _ -> (1, "Section " <> jsonInt idx, md)

-- ---------------------------------------------------------------------------
-- Chapter & Chunk Splitting Logic
-- ---------------------------------------------------------------------------

countWords :: Text -> Int
countWords = length . T.words

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
        , "disclaimer"
        , "copyright "
        , "all rights reserved"
        , "table of contents"
        , "fanfiction"
        , "initial draft"
        , "final version"
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

-- | Split long text into balanced word chunks if a single paragraph exceeds maxWords
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

-- | If a scene fits in maxWords, keep it whole so chunks break at scene breaks.
-- If a scene exceeds maxWords, split its paragraphs into balanced sub-scenes.
splitOversizedScene :: Int -> [Text] -> [Text]
splitOversizedScene maxWords scene
  | sum (map countWords scene) <= maxWords = [T.intercalate "\n\n" scene]
  | otherwise = packBalanced maxWords (glueSceneEnds scene)

-- | Ensure leading headings stay attached to the first paragraph and a trailing
-- scene-break marker (---) stays attached to the last paragraph when a scene is split.
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

-- | Linear-time packer that aims for target = remWords / k instead of greedily
-- filling every chunk to maxWords.
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

-- ---------------------------------------------------------------------------
-- Source File Loading & Chunk Building
-- ---------------------------------------------------------------------------

readTextFileSafe :: FilePath -> IO Text
readTextFileSafe path = do
  bs <- BS.readFile path
  pure (TE.decodeUtf8With TEE.lenientDecode bs)

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

-- ---------------------------------------------------------------------------
-- Templates, Memory Merger & Multi-Level Archive Tree
-- ---------------------------------------------------------------------------

defaultHallOfFamePlaceholder :: Text
defaultHallOfFamePlaceholder =
  "- *(None yet. Move story-resolved predictions here using `- **[Predicted Chunk XXXX -> CONFIRMED Chunk YYYY]** ...`, `- **[Predicted Chunk XXXX -> DEBUNKED Chunk YYYY]** ...`, or `- **[Predicted Chunk XXXX -> SUBVERTED Chunk YYYY]** ...`. Confirmations with `YYYY - XXXX < 3` are tagged as short-horizon and do not count as major Hits; Debunked/Subverted misses of any distance are welcome. Predictions retired to stay within the 10-prediction cap using `- **[Predicted Chunk XXXX -> RETIRED Chunk YYYY]** ...` are recorded in the chunk commentary and automatically pruned from `memory.md`.)*"

defaultCuratedMemory :: [(Text, Text)]
defaultCuratedMemory =
  [ ("Story Summary So Far", "- *(No chunks read yet.)*")
  , ("Characters & Relationships", "- *(None introduced yet.)*")
  , ("Active Mysteries & Unanswered Questions", "- *(None yet.)*")
  , ( "Active Predictions & Theories"
    , "- *(None yet. Log 1 new non-softball, multi-chapter prediction on every chunk using `- **[Predicted Chunk XXXX]** *Clue/Anomaly*: ... -> *Theory*: ... *(vs. Plausible Rival: ...)*`, capped at 10 unresolved predictions. When total unresolved predictions exceed 10, retire the prediction(s) most likely to never be resolved or most likely to be debunked using `- **[Predicted Chunk XXXX -> RETIRED Chunk YYYY]** <reason>` until at most 10 remain. Never log stated itineraries, cliffhanger completions, or status-quo routines, and never rewrite or silently drop an active prediction.)*"
    )
  , ("Hall of Fame & Shame (Major Hits & Misses)", defaultHallOfFamePlaceholder)
  , ( "Notable Quotes, Themes & Running Jokes"
    , "- **Reader Craft Directives & Running Gags (Persistent)**: Keep a grounded, conversational forum liveblog voice inside the story; no lecturing, video-essay/review jargon, author-grading, or textbook truisms."
    )
  ]

classifyMemoryHeading :: Text -> Maybe Text
classifyMemoryHeading rawHeading =
  let h = T.toLower (T.strip rawHeading)
   in if "chunk index" `T.isInfixOf` h || "memory archive" `T.isInfixOf` h || "index tree" `T.isInfixOf` h
        then Nothing
        else if "story summary" `T.isInfixOf` h || "summary so far" `T.isInfixOf` h
          then Just "Story Summary So Far"
          else if "character" `T.isInfixOf` h || "relationship" `T.isInfixOf` h
            then Just "Characters & Relationships"
            else if "myster" `T.isInfixOf` h || "unanswered" `T.isInfixOf` h || "question" `T.isInfixOf` h
              then Just "Active Mysteries & Unanswered Questions"
              else if "hall of fame" `T.isInfixOf` h
                || "shame" `T.isInfixOf` h
                || "hits & misses" `T.isInfixOf` h
                || "resolved prediction" `T.isInfixOf` h
                || "confirmed" `T.isInfixOf` h
                then Just "Hall of Fame & Shame (Major Hits & Misses)"
                else if "prediction" `T.isInfixOf` h || "theor" `T.isInfixOf` h
                  then Just "Active Predictions & Theories"
                  else if "quote" `T.isInfixOf` h || "theme" `T.isInfixOf` h || "joke" `T.isInfixOf` h || "meme" `T.isInfixOf` h
                    then Just "Notable Quotes, Themes & Running Jokes"
                    else Nothing

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
  , "- <1-line"
  , "- <compact"
  , "- <questions"
  , "- <what is"
  , "- <recurring"
  ]

isPlaceholderSection :: Text -> Bool
isPlaceholderSection body =
  let s = T.toLower (T.strip body)
   in T.null s || any (`T.isInfixOf` s) placeholderSubstrings

isPlaceholderLine :: Text -> Bool
isPlaceholderLine line =
  let s = T.toLower (T.strip line)
   in T.null s || any (`T.isInfixOf` s) placeholderSubstrings

data ResolutionKind = ResConfirmed | ResDebunked | ResSubverted | ResRetired
  deriving (Eq, Show)

data ParsedPrediction
  = PredValidActive
      { ppOrigChunk :: !Int
      , ppRawLine :: !Text
      , ppBodyAfterBracket :: !Text
      , ppNormBody :: !Text
      }
  | PredValidResolved
      { ppResOrigChunk :: !(Maybe Int)
      , ppResChunk :: !Int
      , ppResKind :: !ResolutionKind
      , ppRawLine :: !Text
      , ppBodyAfterBracket :: !Text
      , ppNormBody :: !Text
      }
  | PredInvalidNotation
      { ppGuessedOrigChunk :: !(Maybe Int)
      , ppRawLine :: !Text
      , ppBodyAfterBracket :: !Text
      , ppNormBody :: !Text
      }
  deriving (Eq, Show)

normalizePredBody :: Text -> Text
normalizePredBody = T.filter isAlphaNum . T.toLower

canonicalizeActiveLine :: Int -> Text -> Text
canonicalizeActiveLine c1 body =
  "- **[Predicted Chunk " <> T.pack (padChunkNumber c1) <> "]** " <> T.strip body

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

parsePredictionLine :: Text -> ParsedPrediction
parsePredictionLine rawLine =
  let l = T.strip rawLine
      (_, afterOpen) = T.breakOn "[" l
      (insideRaw, afterClose) = T.breakOn "]" (T.drop 1 afterOpen)
   in if T.null afterOpen || T.null afterClose
        then PredInvalidNotation Nothing l l (normalizePredBody l)
        else
          let (insideBeforeParen, _) = T.breakOn "(" insideRaw
              inside = T.toLower (T.strip insideBeforeParen)
              rawAfterBracket =
                T.strip
                  (T.dropWhile (\c -> c == '*' || c == ':') (T.drop 1 afterClose))
              shortHorizonPrefix = "(short-horizon <3 chunks"
              afterBracket =
                if shortHorizonPrefix `T.isPrefixOf` T.toLower rawAfterBracket
                  then T.strip (T.drop 1 (snd (T.breakOn ")" rawAfterBracket)))
                  else rawAfterBracket
              normB = normalizePredBody afterBracket
              nums :: [Int]
              nums =
                [ n
                | tok <- T.split (not . isDigit) inside
                , not (T.null tok)
                , [(n, "")] <- [reads (T.unpack tok)]
                ]
              hasForbiddenKeyword =
                any
                  (`T.isInfixOf` inside)
                  [ "refin"
                  , "updat"
                  , "revis"
                  , "modif"
                  , "chang"
                  , "adjust"
                  , "tweak"
                  , "semi"
                  , "partial"
                  , "shift"
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
           in if hasForbiddenKeyword
                then PredInvalidNotation (listToMaybe nums) l afterBracket normB
                else if isSubverted || isDebunked || isRetired || isConfirmed
                  then
                    let rKind
                          | isSubverted = ResSubverted
                          | isDebunked = ResDebunked
                          | isRetired = ResRetired
                          | otherwise = ResConfirmed
                     in case nums of
                          (c1 : c2 : _)
                            | c1 > 0 && c2 >= c1 ->
                                PredValidResolved (Just c1) c2 rKind (canonicalizeResolvedLine c1 c2 rKind afterBracket) afterBracket normB
                          [cOnly]
                            | cOnly > 0 ->
                                PredValidResolved Nothing cOnly rKind l afterBracket normB
                          _ ->
                            PredInvalidNotation (listToMaybe nums) l afterBracket normB
                  else
                    let isActiveTag =
                          ("predicted" `T.isInfixOf` inside || "active" `T.isInfixOf` inside)
                            && not ("->" `T.isInfixOf` inside)
                     in case nums of
                          [c1]
                            | isActiveTag && c1 > 0 && not (T.null normB) ->
                                PredValidActive c1 (canonicalizeActiveLine c1 afterBracket) afterBracket normB
                          _ ->
                            PredInvalidNotation (listToMaybe nums) l afterBracket normB

isAuditHeaderLine :: Text -> Bool
isAuditHeaderLine line =
  let l = T.toLower line
   in "reader sub-agent rewrote prediction or moved goalposts" `T.isInfixOf` l
        || "invalid prediction tag or format in file" `T.isInfixOf` l

isIndentedAuditSubLine :: Text -> Bool
isIndentedAuditSubLine rawLine =
  let trimmed = T.stripStart rawLine
      leadingSpaces = T.length rawLine - T.length trimmed
   in leadingSpaces >= 2
        && ( "- *Before (" `T.isPrefixOf` trimmed
               || "- *After (" `T.isPrefixOf` trimmed
               || "- *Issue (" `T.isPrefixOf` trimmed
               || "- *Invalid Line (" `T.isPrefixOf` trimmed
               || "- *Action Required*:" `T.isPrefixOf` trimmed
           )

extractPrevActivePredictions :: Text -> [ParsedPrediction]
extractPrevActivePredictions oldActiveBody =
  let parseLine rawL =
        let trimmed = T.strip rawL
         in if "- *Before (" `T.isPrefixOf` trimmed
              then
                let (_, afterMarker) = T.breakOn ")*: " trimmed
                    extracted = T.strip (T.dropAround (== '`') (T.strip (T.drop 4 afterMarker)))
                 in if "- " `T.isPrefixOf` extracted || "* " `T.isPrefixOf` extracted
                      then case parsePredictionLine extracted of
                        p@(PredValidActive {}) -> Just p
                        _ -> Nothing
                      else Nothing
              else
                if isIndentedAuditSubLine rawL || isAuditHeaderLine trimmed || isPlaceholderLine trimmed
                  then Nothing
                  else
                    if "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
                      then case parsePredictionLine trimmed of
                        p@(PredValidActive {}) -> Just p
                        _ -> Nothing
                      else Nothing
      candidates = [p | rawL <- T.lines oldActiveBody, Just p <- [parseLine rawL]]
      dedup [] = []
      dedup (p : ps) =
        p : dedup [q | q <- ps, (ppOrigChunk q, ppNormBody q) /= (ppOrigChunk p, ppNormBody p)]
   in dedup candidates

extractOldHallResolved :: Text -> [ParsedPrediction]
extractOldHallResolved oldHallBody =
  [ p
  | rawL <- T.lines oldHallBody
  , let trimmed = T.strip rawL
  , not (isPlaceholderLine trimmed)
  , not (isAuditHeaderLine trimmed)
  , not (isIndentedAuditSubLine rawL)
  , "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
  , p@(PredValidResolved {}) <- [parsePredictionLine trimmed]
  , ppResKind p /= ResRetired
  ]

bodiesRelated :: Text -> Text -> Bool
bodiesRelated b1 b2 =
  let p1 = T.take 20 b1
      p2 = T.take 20 b2
   in not (T.null p1) && not (T.null p2) && (p1 `T.isInfixOf` b2 || p2 `T.isInfixOf` b1)

renderAuditBlock :: FilePath -> FilePath -> Int -> Int -> Text -> Text -> Text
renderAuditBlock curMemPath prevMemPath origC curIdx beforeTxt afterTxt =
  let origStr = T.pack (padChunkNumber origC)
      curStr = T.pack (padChunkNumber (max 1 curIdx))
      nextStr = T.pack (padChunkNumber (max 1 curIdx + 1))
   in T.intercalate
        "\n"
        [ "- **[READER SUB-AGENT REWROTE PREDICTION OR MOVED GOALPOSTS IN FILE " <> T.pack curMemPath <> "]**"
        , "  - *Before (in " <> T.pack prevMemPath <> ")*: " <> T.strip beforeTxt
        , "  - *After (in " <> T.pack curMemPath <> ")*: " <> T.strip afterTxt
        , "  - *Action Required*: Address this prediction rewrite, goalpost-shift, or silent omission openly in your next commentary! In `=== UPDATED MEMORY ===`, either: (1) restore the exact `*Before*` line above (`- **[Predicted Chunk "
            <> origStr
            <> "]** ...`) in `## Active Predictions & Theories`, (2) move it to `## Hall of Fame & Shame (Major Hits & Misses)` using `- **[Predicted Chunk "
            <> origStr
            <> " -> CONFIRMED Chunk "
            <> curStr
            <> "]** <explanation>`, `- **[Predicted Chunk "
            <> origStr
            <> " -> DEBUNKED Chunk "
            <> curStr
            <> "]** <explanation>`, or `- **[Predicted Chunk "
            <> origStr
            <> " -> SUBVERTED Chunk "
            <> curStr
            <> "]** <explanation>` (or `Chunk "
            <> nextStr
            <> "` if resolving on Chunk "
            <> nextStr
            <> "), or (3) if total unresolved predictions exceed the cap of 10, retire it using `- **[Predicted Chunk "
            <> origStr
            <> " -> RETIRED Chunk "
            <> nextStr
            <> "]** <reason>` before logging any new prediction with `- **[Predicted Chunk "
            <> nextStr
            <> "]**`."
        ]

renderTagFormatAuditBlock :: FilePath -> FilePath -> Text -> Text -> Text -> Text
renderTagFormatAuditBlock curMemPath prevMemPath issueTxt invalidLineTxt actionTxt =
  T.intercalate
    "\n"
    [ "- **[INVALID PREDICTION TAG OR FORMAT IN FILE " <> T.pack curMemPath <> "]**"
    , "  - *Issue (against " <> T.pack prevMemPath <> ")*: " <> T.strip issueTxt
    , "  - *Invalid Line (in " <> T.pack curMemPath <> ")*: " <> T.strip invalidLineTxt
    , "  - *Action Required*: " <> T.strip actionTxt
    ]

mergeHallOfFameEntries :: [ParsedPrediction] -> [ParsedPrediction] -> Text
mergeHallOfFameEntries oldEntries newEntries =
  let sameHallPrediction p1 p2 =
        case (ppResOrigChunk p1, ppResOrigChunk p2) of
          (Just c1, Just c2) | c1 == c2 ->
            bodiesRelated (ppNormBody p1) (ppNormBody p2)
              || ( length [x | x <- oldEntries, ppResOrigChunk x == Just c1] <= 1
                    && length [x | x <- newEntries, ppResOrigChunk x == Just c1] <= 1
                 )
          _ -> bodiesRelated (ppNormBody p1) (ppNormBody p2)
      keptOld =
        [ oldE
        | oldE <- oldEntries
        , not (any (sameHallPrediction oldE) newEntries)
        ]
      dedupNew [] = []
      dedupNew (e : es) = e : dedupNew [x | x <- es, not (sameHallPrediction e x)]
      combined = map ppRawLine (keptOld ++ dedupNew newEntries)
   in if null combined
        then defaultHallOfFamePlaceholder
        else T.strip (T.unlines combined)

isPredictionMentionedInComm :: Text -> Text -> Bool
isPredictionMentionedInComm commLower rawPredLine =
  let (_, afterOpen) = T.breakOn "[" rawPredLine
      (insideRaw, _) = T.breakOn "]" (T.drop 1 afterOpen)
      (insideBeforeParen, _) = T.breakOn "(" insideRaw
      tagNorm = T.toLower (T.strip insideBeforeParen)
   in not (T.null tagNorm) && tagNorm `T.isInfixOf` commLower

auditAndMergePredictions
  :: FilePath
  -> Int
  -> Int
  -> Bool
  -> Text
  -> Text
  -> Text
  -> Maybe Text
  -> Maybe Text
  -> (Text, Text, [Text], [Text])
auditAndMergePredictions sessionDir curIdx totalChunks isRecordTurn commText oldActiveBody oldHallBody mNewActiveBody mNewHallBody =
  let curMemPath =
        if curIdx > 0
          then sessionDir </> "archive" </> "memory" </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")
          else sessionDir </> "memory.md"
      prevMemPath =
        if curIdx > 1
          then sessionDir </> "archive" </> "memory" </> ("chunk_" ++ padChunkNumber (curIdx - 1) ++ ".md")
          else sessionDir </> "memory.md"
      prevActives = extractPrevActivePredictions oldActiveBody
      oldHallResolved = extractOldHallResolved oldHallBody
      parseIncomingBullets mBody =
        case mBody of
          Nothing -> []
          Just b ->
            [ parsePredictionLine (T.strip rawL)
            | rawL <- T.lines b
            , let trimmed = T.strip rawL
            , not (isPlaceholderLine trimmed)
            , not (isAuditHeaderLine trimmed)
            , not (isIndentedAuditSubLine rawL)
            , "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
            ]
      rawFromActive = parseIncomingBullets mNewActiveBody
      rawFromHall = parseIncomingBullets mNewHallBody
      commResolvedBullets =
        [ p
        | rawL <- T.lines commText
        , let trimmed = T.strip rawL
        , not (isPlaceholderLine trimmed)
        , not (isAuditHeaderLine trimmed)
        , not (isIndentedAuditSubLine rawL)
        , "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
        , p@(PredValidResolved {}) <- [parsePredictionLine trimmed]
        ]
      newActiveCandidates = [p | p <- rawFromActive, case p of PredValidResolved {} -> False; _ -> True]
      harvestedResolved = [p | p@(PredValidResolved {}) <- rawFromActive]
      resolvedFromHall = [p | p@(PredValidResolved {}) <- rawFromHall]
      invalidFromHall = [p | p <- rawFromHall, case p of PredValidResolved {} -> False; _ -> True]
      allIncomingResolved = harvestedResolved ++ resolvedFromHall

      -- Step A: Match unchanged active predictions
      matchUnchanged [] cands = ([], [], cands)
      matchUnchanged (p : ps) cands =
        let isSameActive c =
              case c of
                PredValidActive cOrig _ _ cNorm ->
                  cOrig == ppOrigChunk p && cNorm == ppNormBody p
                _ -> False
         in case break isSameActive cands of
              (beforeC, _ : afterC) ->
                let (kept, remP, remC) = matchUnchanged ps (beforeC ++ afterC)
                 in (ppRawLine p : kept, remP, remC)
              (_, []) ->
                let (kept, remP, remC) = matchUnchanged ps cands
                 in (kept, p : remP, remC)

      (keptActiveLines, remPrevAfterA, remCandAfterA) =
        if isJust mNewActiveBody
          then matchUnchanged prevActives newActiveCandidates
          else (map ppRawLine prevActives, [], [])

      -- Step B: Match properly resolved/retired predictions against remPrevAfterA
      prevCountWithChunk c = length [x | x <- remPrevAfterA, ppOrigChunk x == c]
      matchResolved [] resList = ([], [], resList)
      matchResolved (p : ps) resList =
        let origC = ppOrigChunk p
            origNorm = ppNormBody p
            matchesP r =
              case r of
                PredValidResolved (Just rOrig) _ _ _ _ rNorm ->
                  rOrig == origC && (bodiesRelated origNorm rNorm || prevCountWithChunk origC == 1)
                PredValidResolved Nothing _ _ _ _ rNorm ->
                  bodiesRelated origNorm rNorm
                _ -> False
         in case break matchesP resList of
              (beforeR, matchedR : afterR) ->
                let rChunk = ppResChunk matchedR
                    rKind = ppResKind matchedR
                    rBody =
                      if T.null (T.strip (ppBodyAfterBracket matchedR))
                        then ppBodyAfterBracket p
                        else ppBodyAfterBracket matchedR
                    canonRes =
                      PredValidResolved
                        (Just origC)
                        rChunk
                        rKind
                        (canonicalizeResolvedLine origC rChunk rKind rBody)
                        rBody
                        (normalizePredBody rBody)
                    (resAcc, remP, remR) = matchResolved ps (beforeR ++ afterR)
                 in (canonRes : resAcc, remP, remR)
              (_, []) ->
                let (resAcc, remP, remR) = matchResolved ps resList
                 in (resAcc, p : remP, remR)

      (resolvedFromMem, remPrevAfterMemB, remResAfterB) = matchResolved remPrevAfterA allIncomingResolved
      (resolvedFromComm, remPrevAfterB, _) = matchResolved remPrevAfterMemB commResolvedBullets
      resolvedFromPrev = resolvedFromMem ++ resolvedFromComm
      storyResolvedFromPrev = [r | r <- resolvedFromPrev, ppResKind r /= ResRetired]
      retiredFromPrev = [r | r <- resolvedFromPrev, ppResKind r == ResRetired]

      sameChunkRetired =
        [ r
        | r@(PredValidResolved (Just origC) resC ResRetired _ _ _) <- remResAfterB ++ commResolvedBullets
        , origC == curIdx && resC == curIdx
        ]
      remResAfterBFiltered =
        [ r
        | r <- remResAfterB
        , ppResKind r /= ResRetired
        ]

      -- Step C: Pair remaining unmatched prevActives with rewrites or flag as silent drops
      candidateChunk :: ParsedPrediction -> Maybe Int
      candidateChunk (PredValidActive c _ _ _) = Just c
      candidateChunk (PredInvalidNotation mc _ _ _) = mc
      candidateChunk (PredValidResolved mc _ _ _ _ _) = mc

      curStr = T.pack (padChunkNumber (max 1 curIdx))
      nextStr = T.pack (padChunkNumber (max 1 curIdx + 1))
      hadTagAuditInOldActive =
        "invalid prediction tag or format in file" `T.isInfixOf` T.toLower oldActiveBody
      prevActiveChunksSummary =
        case map (T.pack . padChunkNumber . ppOrigChunk) prevActives of
          [] -> "none currently active in previous `memory.md`"
          cs -> T.intercalate ", " ["`[Predicted Chunk " <> c <> "]`" | c <- cs]
      sampleOrigStr mGuessed =
        case mGuessed of
          Just g | any (\p -> ppOrigChunk p == g) prevActives -> T.pack (padChunkNumber g)
          _ ->
            case prevActives of
              (p : _) -> T.pack (padChunkNumber (ppOrigChunk p))
              [] ->
                case mGuessed of
                  Just g -> T.pack (padChunkNumber g)
                  Nothing -> curStr

      pairRewrites [] cands = ([], cands)
      pairRewrites (p : ps) cands =
        let origC = ppOrigChunk p
            origLine = ppRawLine p
            exactChunkCand c = candidateChunk c == Just origC
            relatedBodyCand c =
              case c of
                PredInvalidNotation _ _ _ cNorm -> bodiesRelated (ppNormBody p) cNorm
                PredValidActive cNum _ _ cNorm -> cNum /= curIdx && bodiesRelated (ppNormBody p) cNorm
                PredValidResolved {} -> False
         in case break exactChunkCand cands of
              (b1, m1 : a1) ->
                let blk = renderAuditBlock curMemPath prevMemPath origC curIdx origLine (ppRawLine m1)
                    (blks, remC) = pairRewrites ps (b1 ++ a1)
                 in (blk : blks, remC)
              (_, []) ->
                case break relatedBodyCand cands of
                  (b2, m2 : a2) ->
                    let blk = renderAuditBlock curMemPath prevMemPath origC curIdx origLine (ppRawLine m2)
                        (blks, remC) = pairRewrites ps (b2 ++ a2)
                     in (blk : blks, remC)
                  (_, []) ->
                    let omittedMsg =
                          "*(Silently omitted without `[Predicted Chunk "
                            <> T.pack (padChunkNumber origC)
                            <> " -> CONFIRMED/DEBUNKED/SUBVERTED/RETIRED Chunk "
                            <> curStr
                            <> "]` notation)*"
                        blk = renderAuditBlock curMemPath prevMemPath origC curIdx origLine omittedMsg
                        (blks, remC) = pairRewrites ps cands
                     in (blk : blks, remC)

      (rewriteAndDropBlocks, remCandAfterC) = pairRewrites remPrevAfterB remCandAfterA

      -- Step D: Classify remaining candidates in remCandAfterC, invalidFromHall, and remResAfterBFiltered
      classifyRemainingCand :: ParsedPrediction -> Either (Int, Text) Text
      classifyRemainingCand (PredValidActive newC canonLine bodyAfter _)
        | newC == curIdx || (hadTagAuditInOldActive && newC == curIdx - 1 && newC > 0) || curIdx <= 1 =
            Left (newC, canonLine)
        | otherwise =
            let newCStr = T.pack (padChunkNumber newC)
                trimmedBody = T.strip bodyAfter
                issueDetail =
                  if any (\p -> ppOrigChunk p == newC) prevActives
                    then
                      "New active prediction logged on Chunk "
                        <> curStr
                        <> " was tagged with `[Predicted Chunk "
                        <> newCStr
                        <> "]` instead of `[Predicted Chunk "
                        <> curStr
                        <> "]` (the existing `[Predicted Chunk "
                        <> newCStr
                        <> "]` entry was already matched; any newly added prediction on Chunk "
                        <> curStr
                        <> " must use the current chunk number)."
                    else
                      "New active prediction logged on Chunk "
                        <> curStr
                        <> " was tagged with wrong chunk number `[Predicted Chunk "
                        <> newCStr
                        <> "]` (no active prediction from Chunk "
                        <> newCStr
                        <> " existed in previous `memory.md`; existing active tags: "
                        <> prevActiveChunksSummary
                        <> ")."
             in Right $
                  renderTagFormatAuditBlock
                    curMemPath
                    prevMemPath
                    issueDetail
                    canonLine
                    ( "Fix the bracket tag in `=== UPDATED MEMORY ===`! Replace `- **[Predicted Chunk "
                        <> newCStr
                        <> "]**` with `- **[Predicted Chunk "
                        <> nextStr
                        <> "]** "
                        <> trimmedBody
                        <> "` (when submitting Chunk "
                        <> nextStr
                        <> ") or `- **[Predicted Chunk "
                        <> curStr
                        <> "]** "
                        <> trimmedBody
                        <> "` (if updating Chunk "
                        <> curStr
                        <> "), or remove the mistagged line."
                    )
      classifyRemainingCand (PredInvalidNotation mGuessed rawInv bodyAfter _) =
        let origEx = sampleOrigStr mGuessed
            trimmedBody =
              if T.null (T.strip bodyAfter)
                then "*Clue/Anomaly*: ... -> *Theory*: ... *(vs. Plausible Rival: ...)*"
                else T.strip bodyAfter
         in Right $
              renderTagFormatAuditBlock
                curMemPath
                prevMemPath
                ("Malformed or unsupported prediction bracket tag in `## Active Predictions & Theories` (existing active tags in previous `memory.md`: " <> prevActiveChunksSummary <> ").")
                rawInv
                ( "Fix or remove this line in `=== UPDATED MEMORY ===`! To log an active prediction in `## Active Predictions & Theories`, use `- **[Predicted Chunk "
                    <> nextStr
                    <> "]** "
                    <> trimmedBody
                    <> "` (on Chunk "
                    <> nextStr
                    <> ") or `- **[Predicted Chunk "
                    <> curStr
                    <> "]** "
                    <> trimmedBody
                    <> "` (on Chunk "
                    <> curStr
                    <> "). Or if resolving an existing active prediction, move it to `## Hall of Fame & Shame (Major Hits & Misses)` using `- **[Predicted Chunk "
                    <> origEx
                    <> " -> CONFIRMED Chunk "
                    <> curStr
                    <> "]** ...`, `- **[Predicted Chunk "
                    <> origEx
                    <> " -> DEBUNKED Chunk "
                    <> curStr
                    <> "]** ...`, `- **[Predicted Chunk "
                    <> origEx
                    <> " -> SUBVERTED Chunk "
                    <> curStr
                    <> "]** ...`, or (when retiring above the 10-prediction cap) `- **[Predicted Chunk "
                    <> origEx
                    <> " -> RETIRED Chunk "
                    <> curStr
                    <> "]** ...`."
                )
      classifyRemainingCand (PredValidResolved mOrig _ _ rawR _ _) =
        let origEx = sampleOrigStr mOrig
         in Right $
              renderTagFormatAuditBlock
                curMemPath
                prevMemPath
                ("Unmatched resolved prediction tag in `## Active Predictions & Theories` (existing active tags in previous `memory.md`: " <> prevActiveChunksSummary <> ").")
                rawR
                ( "Move valid resolved predictions to `## Hall of Fame & Shame (Major Hits & Misses)` using an origin chunk that existed in `## Active Predictions & Theories` (`- **[Predicted Chunk "
                    <> origEx
                    <> " -> CONFIRMED Chunk "
                    <> curStr
                    <> "]** ...`, `- **[Predicted Chunk "
                    <> origEx
                    <> " -> DEBUNKED Chunk "
                    <> curStr
                    <> "]** ...`, `- **[Predicted Chunk "
                    <> origEx
                    <> " -> SUBVERTED Chunk "
                    <> curStr
                    <> "]** ...`, or `- **[Predicted Chunk "
                    <> origEx
                    <> " -> RETIRED Chunk "
                    <> curStr
                    <> "]** ...`), or remove the unmatched line."
                )

      candResults = map classifyRemainingCand remCandAfterC
      rawValidNewPairs = [(c, l) | Left (c, l) <- candResults]
      dedupNewByChunk _ [] = ([], [])
      dedupNewByChunk seen ((c, l) : rest)
        | c `elem` seen =
            let cStr = T.pack (padChunkNumber c)
                dupBlk =
                  renderTagFormatAuditBlock
                    curMemPath
                    prevMemPath
                    ("Multiple new predictions were tagged `[Predicted Chunk " <> cStr <> "]` on the same chunk (only 1 new prediction per chunk is allowed so each chunk tag remains unique).")
                    l
                    ("Keep only your single strongest prediction for Chunk " <> cStr <> " and remove the duplicate `- **[Predicted Chunk " <> cStr <> "]**` line(s).")
                (keptL, dupBlks) = dedupNewByChunk seen rest
             in (keptL, dupBlk : dupBlks)
        | otherwise =
            let (keptL, dupBlks) = dedupNewByChunk (c : seen) rest
             in (l : keptL, dupBlks)
      (newValidActiveLines, duplicateChunkAuditBlocks) = dedupNewByChunk [] rawValidNewPairs
      candAuditBlocks = [b | Right b <- candResults] ++ duplicateChunkAuditBlocks
      hallInvalidBlocks =
        [ let (issueMsg, actMsg) =
                case inv of
                  PredValidActive c1 canonAct _ _ ->
                    let c1Str = T.pack (padChunkNumber c1)
                     in ( "Active prediction tag `[Predicted Chunk " <> c1Str <> "]` was placed inside `## Hall of Fame & Shame (Major Hits & Misses)` without a resolution tag."
                        , "Either move `"
                            <> canonAct
                            <> "` back to `## Active Predictions & Theories`, or resolve it in `## Hall of Fame & Shame` using `- **[Predicted Chunk "
                            <> c1Str
                            <> " -> CONFIRMED Chunk "
                            <> curStr
                            <> "]** ...`, `- **[Predicted Chunk "
                            <> c1Str
                            <> " -> DEBUNKED Chunk "
                            <> curStr
                            <> "]** ...`, or `- **[Predicted Chunk "
                            <> c1Str
                            <> " -> SUBVERTED Chunk "
                            <> curStr
                            <> "]** ...`."
                        )
                  PredInvalidNotation mGuessed _ _ _ ->
                    let origEx = sampleOrigStr mGuessed
                     in ( "Invalid or unresolved prediction notation placed in `## Hall of Fame & Shame (Major Hits & Misses)` (existing active tags in previous `memory.md`: " <> prevActiveChunksSummary <> ")."
                        , "Fix or remove this line in `=== UPDATED MEMORY ===`! Every bullet in `## Hall of Fame & Shame (Major Hits & Misses)` MUST use one of these exact tags: `- **[Predicted Chunk "
                            <> origEx
                            <> " -> CONFIRMED Chunk "
                            <> curStr
                            <> "]** ...`, `- **[Predicted Chunk "
                            <> origEx
                            <> " -> DEBUNKED Chunk "
                            <> curStr
                            <> "]** ...`, or `- **[Predicted Chunk "
                            <> origEx
                            <> " -> SUBVERTED Chunk "
                            <> curStr
                            <> "]** ...` (or `- *(No resolved predictions yet.)*` when empty)."
                        )
                  PredValidResolved {} ->
                    ( "Unmatched resolved prediction notation in `## Hall of Fame & Shame (Major Hits & Misses)`."
                    , "Remove or fix this line in `=== UPDATED MEMORY ===`."
                    )
           in renderTagFormatAuditBlock
                curMemPath
                prevMemPath
                issueMsg
                (ppRawLine inv)
                actMsg
        | inv <- invalidFromHall
        ]

      -- Check remaining PredValidResolved in remResAfterBFiltered against oldHallResolved
      matchesOldHall :: ParsedPrediction -> Maybe ParsedPrediction
      matchesOldHall r@(PredValidResolved (Just origC) resC rKind _ rBody rNorm) =
        let hasOldMatch =
              any
                ( \oldH ->
                    ppResOrigChunk oldH == Just origC
                      || bodiesRelated (ppNormBody oldH) rNorm
                )
                oldHallResolved
         in if hasOldMatch || curIdx <= 1
              then
                Just
                  ( r
                      { ppRawLine = canonicalizeResolvedLine origC resC rKind rBody
                      }
                  )
              else Nothing
      matchesOldHall (PredValidResolved Nothing resC rKind _ rBody rNorm) =
        case [oldH | oldH <- oldHallResolved, bodiesRelated (ppNormBody oldH) rNorm, Just _ <- [ppResOrigChunk oldH]] of
          (matchedOld : _)
            | Just origC <- ppResOrigChunk matchedOld ->
                Just
                  ( PredValidResolved
                      (Just origC)
                      resC
                      rKind
                      (canonicalizeResolvedLine origC resC rKind rBody)
                      rBody
                      rNorm
                  )
          _ -> Nothing
      matchesOldHall _ = Nothing

      (validRemainingHall, unmatchedResAuditBlocks) =
        foldr
          ( \r (vAcc, bAcc) ->
              case matchesOldHall r of
                Just validR -> (validR : vAcc, bAcc)
                Nothing ->
                  let origEx = sampleOrigStr (ppResOrigChunk r)
                      msg =
                        case ppResOrigChunk r of
                          Just origC ->
                            "Resolved prediction in `## Hall of Fame & Shame` references `[Predicted Chunk "
                              <> T.pack (padChunkNumber origC)
                              <> "]`, which did not exist in `## Active Predictions & Theories` or `## Hall of Fame & Shame` in previous `memory.md` (existing active tags: "
                              <> prevActiveChunksSummary
                              <> ")."
                          Nothing ->
                            "Resolved prediction is missing its origin chunk number and did not match any active prediction in previous `memory.md` (existing active tags: "
                              <> prevActiveChunksSummary
                              <> ")."
                      act =
                        if null prevActives
                          then
                            "No active predictions existed in previous `memory.md` to resolve! Remove this line from `## Hall of Fame & Shame (Major Hits & Misses)`, or if logging a new active prediction, place it in `## Active Predictions & Theories` using `- **[Predicted Chunk "
                              <> nextStr
                              <> "]** *Clue/Anomaly*: ... -> *Theory*: ... *(vs. Plausible Rival: ...)*` (on Chunk "
                              <> nextStr
                              <> ") or `- **[Predicted Chunk "
                              <> curStr
                              <> "]** ...` (on Chunk "
                              <> curStr
                              <> ")."
                          else
                            "Only resolve predictions that actually existed in `## Active Predictions & Theories` ("
                              <> prevActiveChunksSummary
                              <> "), using `- **[Predicted Chunk "
                              <> origEx
                              <> " -> CONFIRMED Chunk "
                              <> curStr
                              <> "]** ...`, `- **[Predicted Chunk "
                              <> origEx
                              <> " -> DEBUNKED Chunk "
                              <> curStr
                              <> "]** ...`, or `- **[Predicted Chunk "
                              <> origEx
                              <> " -> SUBVERTED Chunk "
                              <> curStr
                              <> "]** ...`, or remove the unmatched line."
                   in (vAcc, renderTagFormatAuditBlock curMemPath prevMemPath msg (ppRawLine r) act : bAcc)
          )
          ([], [])
          remResAfterBFiltered

      -- Step E: Validate 10-prediction cap, premature retirements, and 1-per-chunk quota
      totalUnresolvedBeforeRetire =
        length keptActiveLines
          + length newValidActiveLines
          + length retiredFromPrev
          + length sameChunkRetired
          + length candAuditBlocks
      maxPoolBeforeRetire =
        max
          (length prevActives + max (if isRecordTurn && curIdx < totalChunks then 1 else 0) (length newValidActiveLines + length sameChunkRetired))
          totalUnresolvedBeforeRetire
      allowedRetireCount = max 0 (maxPoolBeforeRetire - 10)
      (validRetiredFromPrev, prematureRetired) = splitAt allowedRetireCount retiredFromPrev
      restoredPrematurePairs =
        [ let origC = fromMaybe curIdx (ppResOrigChunk pRet)
              origStr = T.pack (padChunkNumber origC)
              origActiveLine =
                fromMaybe
                  (canonicalizeActiveLine origC (ppBodyAfterBracket pRet))
                  (listToMaybe [ppRawLine p | p <- prevActives, ppOrigChunk p == origC])
              blk =
                renderTagFormatAuditBlock
                  curMemPath
                  prevMemPath
                  ("Prediction `[Predicted Chunk " <> origStr <> "]` was marked `RETIRED` when total unresolved predictions (" <> jsonInt totalUnresolvedBeforeRetire <> "/10) did not exceed the cap of 10.")
                  (ppRawLine pRet)
                  ( "Only retire predictions with `RETIRED` when total unresolved predictions (including your new prediction) would exceed 10. Keep `"
                      <> origActiveLine
                      <> "` in `## Active Predictions & Theories` until the 10-prediction cap is reached, or if the story text already falsified it, move it to `## Hall of Fame & Shame` as `- **[Predicted Chunk "
                      <> origStr
                      <> " -> DEBUNKED Chunk "
                      <> curStr
                      <> "]** <explanation>`."
                  )
           in (origActiveLine, blk)
        | pRet <- prematureRetired
        ]
      restoredPrematureLines = map fst restoredPrematurePairs
      prematureRetireAuditBlocks = map snd restoredPrematurePairs

      finalValidActiveLines = keptActiveLines ++ restoredPrematureLines ++ newValidActiveLines
      activeCountAfter = length finalValidActiveLines
      capExceededAuditBlocks
        | activeCountAfter > 10 =
            let excess = activeCountAfter - 10
             in [ renderTagFormatAuditBlock
                    curMemPath
                    prevMemPath
                    ("`## Active Predictions & Theories` has " <> jsonInt activeCountAfter <> " unresolved predictions, exceeding the maximum cap of 10.")
                    ("*(Active pool has " <> jsonInt activeCountAfter <> "/10 unresolved predictions — " <> jsonInt excess <> " over the cap of 10)*")
                    ( "On your next turn (Chunk "
                        <> nextStr
                        <> "), in addition to retiring 1 prediction for Chunk "
                        <> nextStr
                        <> "'s new prediction, retire "
                        <> jsonInt excess
                        <> " extra prediction(s) (choosing those most likely to never be resolved or most likely to be debunked in future installments) using `- **[Predicted Chunk XXXX -> RETIRED Chunk "
                        <> nextStr
                        <> "]** <reason>` so that at most 10 unresolved predictions remain in `## Active Predictions & Theories`."
                    )
                ]
        | otherwise = []

      hasNewForCur =
        not (null newValidActiveLines)
          || not (null sameChunkRetired)
          || not (null candAuditBlocks)
          || not (null rewriteAndDropBlocks)
      missingNewPredAuditBlocks
        | isRecordTurn && curIdx >= 1 && curIdx < totalChunks && isJust mNewActiveBody && not hasNewForCur =
            [ renderTagFormatAuditBlock
                curMemPath
                prevMemPath
                ("No new prediction was logged for Chunk " <> curStr <> " (every chunk before the final chunk must log 1 new non-softball, multi-chapter prediction, capped at 10 unresolved predictions).")
                ("*(Missing `- **[Predicted Chunk " <> curStr <> "]** *Clue/Anomaly*: ... -> *Theory*: ... *(vs. Plausible Rival: ...)*` in `## Active Predictions & Theories`)*")
                ( "On Chunk "
                    <> nextStr
                    <> ", make sure to log 1 new non-softball, multi-chapter prediction using `- **[Predicted Chunk "
                    <> nextStr
                    <> "]** *Clue/Anomaly*: ... -> *Theory*: ... *(vs. Plausible Rival: ...)*` in both `=== COMMENTARY ===` and `## Active Predictions & Theories` (and if total unresolved predictions exceed 10, retire the weakest one using `- **[Predicted Chunk XXXX -> RETIRED Chunk "
                    <> nextStr
                    <> "]** <reason>`)."
                )
            ]
        | otherwise = []

      allAuditBlocks =
        rewriteAndDropBlocks
          ++ candAuditBlocks
          ++ hallInvalidBlocks
          ++ unmatchedResAuditBlocks
          ++ prematureRetireAuditBlocks
          ++ capExceededAuditBlocks
          ++ missingNewPredAuditBlocks
      finalActiveLines = finalValidActiveLines ++ allAuditBlocks
      defaultActivePlaceholder =
        fromMaybe
          "- *(None yet.)*"
          (lookup "Active Predictions & Theories" defaultCuratedMemory)
      finalActiveBody =
        if null finalActiveLines
          then defaultActivePlaceholder
          else T.strip (T.unlines finalActiveLines)
      finalHallBody =
        mergeHallOfFameEntries
          oldHallResolved
          (storyResolvedFromPrev ++ validRemainingHall)

      commLower = T.toLower commText
      turnEvents =
        newValidActiveLines
          ++ map ppRawLine storyResolvedFromPrev
          ++ map ppRawLine (validRetiredFromPrev ++ sameChunkRetired)
      trackerUpdateLines =
        [ evLine
        | evLine <- turnEvents
        , not (isPredictionMentionedInComm commLower evLine)
        ]
   in (finalActiveBody, finalHallBody, allAuditBlocks, trackerUpdateLines)

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

auditAndMergeCuratedMemory
  :: FilePath
  -> Int
  -> Int
  -> Bool
  -> Text
  -> [(Text, Text)]
  -> Maybe Text
  -> ([(Text, Text)], [Text], [Text])
auditAndMergeCuratedMemory _ _ _ _ _ prevSections Nothing = (prevSections, [], [])
auditAndMergeCuratedMemory sessionDir curIdx totalChunks isRecordTurn commText prevSections (Just memTxt) =
  let incoming = parseMemorySections memTxt
      baseSections = if null prevSections then defaultCuratedMemory else prevSections
      oldActiveBody = fromMaybe "" (lookup "Active Predictions & Theories" baseSections)
      oldHallBody = fromMaybe defaultHallOfFamePlaceholder (lookup "Hall of Fame & Shame (Major Hits & Misses)" baseSections)
      mNewActive = Map.lookup "Active Predictions & Theories" incoming
      mNewHall = Map.lookup "Hall of Fame & Shame (Major Hits & Misses)" incoming
      (mergedActive, mergedHall, auditBlocks, trackerUpdates) =
        if isJust mNewActive || isJust mNewHall
          then auditAndMergePredictions sessionDir curIdx totalChunks isRecordTurn commText oldActiveBody oldHallBody mNewActive mNewHall
          else (oldActiveBody, oldHallBody, [], [])
      mergedSections =
        [ (secName, mergedBody)
        | (secName, oldBody) <- baseSections
        , let mergedBody =
                case secName of
                  "Active Predictions & Theories" -> mergedActive
                  "Hall of Fame & Shame (Major Hits & Misses)" -> mergedHall
                  _ ->
                    case Map.lookup secName incoming of
                      Nothing -> oldBody
                      Just newBody
                        | isPlaceholderSection newBody && not (isPlaceholderSection oldBody) -> oldBody
                        | otherwise -> newBody
        ]
   in (mergedSections, auditBlocks, trackerUpdates)

resolveAndAuditMemory
  :: FilePath
  -> Int
  -> Int
  -> Bool
  -> Text
  -> [(Text, Text)]
  -> Maybe Text
  -> IO ([(Text, Text)], [Text], [Text])
resolveAndAuditMemory sessionDir curIdx totalChunks isRecordTurn commText prevSections (Just memTxt) =
  pure (auditAndMergeCuratedMemory sessionDir curIdx totalChunks isRecordTurn commText prevSections (Just memTxt))
resolveAndAuditMemory sessionDir curIdx totalChunks isRecordTurn commText prevSections Nothing = do
  let memPath = sessionDir </> "memory.md"
  exists <- doesFileExist memPath
  if not exists
    then pure (prevSections, [], [])
    else do
      diskTxt <- readTextFileSafe memPath
      let incoming = parseMemorySections diskTxt
          baseSections = if null prevSections then defaultCuratedMemory else prevSections
          hasDiskDiff =
            any
              ( \(secName, oldBody) ->
                  case Map.lookup secName incoming of
                    Nothing -> False
                    Just diskBody -> T.strip diskBody /= T.strip oldBody
              )
              baseSections
      if hasDiskDiff
        then pure (auditAndMergeCuratedMemory sessionDir curIdx totalChunks isRecordTurn commText prevSections (Just diskTxt))
        else pure (prevSections, [], [])

renderCuratedSections :: [(Text, Text)] -> Text
renderCuratedSections sections =
  T.intercalate "\n\n" [ "## " <> secName <> "\n" <> T.strip body | (secName, body) <- sections ]

checkMemoryCompaction :: [(Text, Text)] -> (Bool, Int, Int)
checkMemoryCompaction sections =
  let rendered = renderCuratedSections sections
      lineCount = length (T.lines rendered)
      byteCount = BS.length (TE.encodeUtf8 rendered)
   in (lineCount > 80 || byteCount > 5000, lineCount, byteCount)

groupChunksIntoArcs :: [ChunkIndexEntry] -> [[ChunkIndexEntry]]
groupChunksIntoArcs = go [] [] (0 :: Int)
  where
    go [] _ _ [] = []
    go cur _ _ [] = [reverse cur]
    go cur chapsInCur countInCur (e : es) =
      let chap = cieChapterNumber e
          isNewChap = ciePartInChapter e == 1 && chap `notElem` chapsInCur
          shouldSplit =
            countInCur >= 25
              || (isNewChap && (length chapsInCur >= 10 || countInCur >= 18))
       in if shouldSplit && not (null cur)
            then reverse cur : go [e] [chap] 1 es
            else
              let chaps' = if chap `elem` chapsInCur then chapsInCur else chap : chapsInCur
               in go (e : cur) chaps' (countInCur + 1) es

formatChapLabel :: Int -> Text -> Text
formatChapLabel chapNum chapTitle
  | chapNum == 0 = chapTitle
  | "chapter " `T.isPrefixOf` T.toLower (T.strip chapTitle) = chapTitle
  | otherwise = "Ch. " <> jsonInt chapNum <> ": " <> chapTitle

renderChunkIndexLine :: FilePath -> ChunkIndexEntry -> Text
renderChunkIndexLine sessionDir e =
  let idxStr = T.pack (padChunkNumber (cieChunkIndex e))
      chapStr = formatChapLabel (cieChapterNumber e) (cieChapterTitle e)
      partStr = "Part " <> jsonInt (ciePartInChapter e) <> "/" <> jsonInt (ciePartsInChapter e)
      storyPath = T.pack (sessionDir </> "chunks" </> ("chunk_" ++ padChunkNumber (cieChunkIndex e) ++ ".md"))
      entryPath = T.pack (sessionDir </> "entries" </> ("chunk_" ++ padChunkNumber (cieChunkIndex e) ++ ".md"))
      memPath = T.pack (sessionDir </> "archive" </> "memory" </> ("chunk_" ++ padChunkNumber (cieChunkIndex e) ++ ".md"))
   in "- **chunk_"
        <> idxStr
        <> "** ("
        <> chapStr
        <> ", "
        <> partStr
        <> "): "
        <> cieSummary e
        <> " ([story](file://"
        <> storyPath
        <> ") | [entry](file://"
        <> entryPath
        <> ") | [memory](file://"
        <> memPath
        <> "))"

writeL1Archive :: FilePath -> Int -> [ChunkIndexEntry] -> IO (FilePath, Text, Text)
writeL1Archive sessionDir grpIdx entries = do
  let (startChk, startChap) =
        case entries of
          (firstE : _) -> (cieChunkIndex firstE, cieChapterNumber firstE)
          [] -> (1, 1)
      (endChk, endChap) =
        case reverse entries of
          (lastE : _) -> (cieChunkIndex lastE, cieChapterNumber lastE)
          [] -> (1, 1)
      chapRange
        | startChap == 0 && endChap == 0 = "Front Matter"
        | startChap == endChap = "Ch. " <> jsonInt startChap
        | otherwise = "Ch. " <> jsonInt startChap <> "–" <> jsonInt endChap
      chunkRange =
        if startChk == endChk
          then "Chunk " <> T.pack (padChunkNumber startChk)
          else "Chunks " <> T.pack (padChunkNumber startChk) <> "–" <> T.pack (padChunkNumber endChk)
      label = "Arc " <> jsonInt grpIdx <> " (" <> chapRange <> " | " <> chunkRange <> ")"
      distinctChaps = nub [(cieChapterNumber e, cieChapterTitle e) | e <- entries]
      summaryLine = "Chapters: *" <> T.intercalate "; " [formatChapLabel cn ct | (cn, ct) <- distinctChaps] <> "*"
      byChapter = groupBy (\a b -> cieChapterNumber a == cieChapterNumber b) entries
      renderChapGroup [] = ""
      renderChapGroup grp@(firstE : _) =
        "### "
          <> formatChapLabel (cieChapterNumber firstE) (cieChapterTitle firstE)
          <> "\n"
          <> T.unlines (map (renderChunkIndexLine sessionDir) grp)
      curatedSnapPath = sessionDir </> "archive" </> "memory" </> ("curated_" ++ padChunkNumber endChk ++ ".md")
  hasSnap <- doesFileExist curatedSnapPath
  snapContent <- if hasSnap then readTextFileSafe curatedSnapPath else pure ""
  let fileName = "L1_" ++ padChunkNumber grpIdx ++ ".md"
      fullPath = sessionDir </> "archive" </> fileName
      archiveDoc =
        T.unlines
          [ "# " <> label
          , ""
          , summaryLine
          , ""
          , "## Chapter & Chunk Index"
          , ""
          , T.intercalate "\n" (map renderChapGroup byChapter)
          , "---"
          , ""
          , "## Historical Reader Memory Snapshot (As of Chunk " <> T.pack (padChunkNumber endChk) <> ")"
          , ""
          , if T.null (T.strip snapContent) then "*(No snapshot recorded.)*" else T.strip snapContent
          ]
  TIO.writeFile fullPath archiveDoc
  pure (fullPath, label, summaryLine)

groupsOfList :: Int -> [a] -> [[a]]
groupsOfList _ [] = []
groupsOfList n xs =
  let (h, t) = splitAt n xs
   in h : groupsOfList n t

rollupArchiveLevels :: FilePath -> Int -> [(FilePath, Text, Text)] -> IO [(FilePath, Text, Text)]
rollupArchiveLevels sessionDir level nodes
  | length nodes <= 25 = pure nodes
  | otherwise = do
      let groups = groupsOfList 25 nodes
      parents <- forM (zip [1 :: Int ..] groups) $ \(grpIdx, children) -> do
        let fileName = "L" ++ show level ++ "_" ++ padChunkNumber grpIdx ++ ".md"
            fullPath = sessionDir </> "archive" </> fileName
            firstLbl = case children of ((_, l, _) : _) -> l; [] -> ""
            lastLbl = case reverse children of ((_, l, _) : _) -> l; [] -> ""
            parentLabel =
              "Archive Directory L"
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
                  , "Read the linked archive files below to inspect chapter/chunk indices and historical memory snapshots:"
                  , ""
                  ]
                    ++ [ "- **"
                          <> lbl
                          <> "**: ["
                          <> T.pack (takeFileName fp)
                          <> "](file://"
                          <> T.pack fp
                          <> ") — "
                          <> summ
                       | (fp, lbl, summ) <- children
                       ]
                )
        TIO.writeFile fullPath doc
        pure (fullPath, parentLabel, parentSummary)
      rollupArchiveLevels sessionDir (level + 1) parents

renderMemoryMarkdown :: FilePath -> SessionState -> [(FilePath, Text, Text)] -> [ChunkIndexEntry] -> Text
renderMemoryMarkdown sessionDir st topArchiveNodes inlineChunks =
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
            , "> **MEMORY COMPACTION NEEDED**: Your curated memory sections are currently "
                <> jsonInt curLines
                <> " lines ("
                <> jsonInt curBytes
                <> " bytes), exceeding the 80-line / 5,000-byte target. On your next turn, condense older chapters in `## Story Summary So Far` into high-level multi-chapter arc bullets and prune minor resolved mysteries. All earlier chunk summaries and full historical memory snapshots are permanently preserved in `<session_dir>/archive/`, so condensing `memory.md` will not lose any history."
            ]
        | otherwise = []
      lookupSec name =
        fromMaybe "- *(None yet.)*" (lookup name curated)
      archivePointersLines
        | null topArchiveNodes =
            ["- *(All chunks read so far are listed inline below. Completed arc archive files will appear here as the story progresses.)*"]
        | otherwise =
            [ "- **"
                <> lbl
                <> "**: ["
                <> T.pack (takeFileName fp)
                <> "](file://"
                <> T.pack fp
                <> ") — "
                <> summ
            | (fp, lbl, summ) <- topArchiveNodes
            ]
      inlineChunkLines
        | null inlineChunks = ["- *(No chunks read yet.)*"]
        | otherwise = map (renderChunkIndexLine sessionDir) inlineChunks
      archiveSection =
        T.unlines $
          [ "## Memory Archive & Index Tree (Auto-Maintained by Gatekeeper)"
          , "*(Do not manually re-emit this section in `=== UPDATED MEMORY ===`; `LetsRead.hs` updates it automatically from your `=== CHUNK SUMMARY ===`.)*"
          , ""
          , "### Completed Arc Archives (Chunk Indices & Historical Memory Snapshots)"
          ]
            ++ archivePointersLines
            ++ [ ""
               , "### Current & Recent Arc Chunks"
               ]
            ++ inlineChunkLines
   in T.unlines $
        [ "# Reader Memory & Notes: " <> stTitle st
        , ""
        , "*Reader Persona*: " <> expandPersonaPreset (stPersona st)
        , "*Progress*: " <> progressStr
        ]
          ++ compactionBanner
          ++ [ ""
             , "## Story Summary So Far"
             , T.strip (lookupSec "Story Summary So Far")
             , ""
             , T.strip archiveSection
             , ""
             , "## Characters & Relationships"
             , T.strip (lookupSec "Characters & Relationships")
             , ""
             , "## Active Mysteries & Unanswered Questions"
             , T.strip (lookupSec "Active Mysteries & Unanswered Questions")
             , ""
             , "## Active Predictions & Theories"
             , T.strip (lookupSec "Active Predictions & Theories")
             , ""
             , "## Hall of Fame & Shame (Major Hits & Misses)"
             , T.strip (lookupSec "Hall of Fame & Shame (Major Hits & Misses)")
             , ""
             , "## Notable Quotes, Themes & Running Jokes"
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

  let arcs = groupChunksIntoArcs (stChunkIndex st)
  l1Nodes <- forM (zip [1 :: Int ..] arcs) $ \(grpIdx, arcEntries) ->
    writeL1Archive sessionDir grpIdx arcEntries

  let completedL1Nodes = if length l1Nodes <= 1 then [] else init l1Nodes
      inlineChunks =
        case reverse arcs of
          [] -> []
          [onlyArc] -> onlyArc
          (lastArc : prevArc : _)
            | length lastArc < 5 ->
                let needed = 5 - length lastArc
                    tailPrev = drop (max 0 (length prevArc - needed)) prevArc
                 in tailPrev ++ lastArc
            | otherwise -> lastArc

  topArchiveNodes <- rollupArchiveLevels sessionDir 2 completedL1Nodes
  let renderedMem = renderMemoryMarkdown sessionDir st topArchiveNodes inlineChunks
  TIO.writeFile (sessionDir </> "memory.md") renderedMem
  when (curIdx > 0) $ do
    let fullSnapPath = memSnapDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")
    TIO.writeFile fullSnapPath renderedMem

  pure (checkMemoryCompaction curated)

countActivePredictionsInMemory :: [(Text, Text)] -> Int
countActivePredictionsInMemory curated =
  let activeBody = fromMaybe "" (lookup "Active Predictions & Theories" curated)
   in length (extractPrevActivePredictions activeBody)

renderPredictionSlateNote :: Int -> Int -> Int -> Text
renderPredictionSlateNote curIdx totalChunks activeCount
  | curIdx >= totalChunks =
      "*Prediction Slate*: Final chunk ("
        <> jsonInt activeCount
        <> "/10 active unresolved predictions in `memory.md`). Resolve any remaining predictions that are `CONFIRMED`, `DEBUNKED`, or `SUBVERTED` by the finale; no new prediction is required on the final chunk."
  | activeCount < 10 =
      let curPad = T.pack (padChunkNumber curIdx)
       in "*Prediction Slate*: "
            <> jsonInt activeCount
            <> "/10 active unresolved predictions in `memory.md`. You MUST log 1 new non-softball, multi-chapter prediction on this chunk using `- **[Predicted Chunk "
            <> curPad
            <> "]** *Clue/Anomaly*: ... -> *Theory*: ... *(vs. Plausible Rival: ...)*` in both `=== COMMENTARY ===` and `## Active Predictions & Theories`."
  | otherwise =
      let curPad = T.pack (padChunkNumber curIdx)
          needRetire = activeCount + 1 - 10
       in "*Prediction Slate*: "
            <> jsonInt activeCount
            <> "/10 active unresolved predictions in `memory.md` (AT 10-PREDICTION CAP). You MUST log 1 new non-softball, multi-chapter prediction using `- **[Predicted Chunk "
            <> curPad
            <> "]** *Clue/Anomaly*: ... -> *Theory*: ... *(vs. Plausible Rival: ...)*`, and unless at least "
            <> jsonInt needRetire
            <> " existing prediction(s) are `CONFIRMED`, `DEBUNKED`, or `SUBVERTED` on this chunk, you MUST retire "
            <> jsonInt needRetire
            <> " prediction(s) (choosing from all unresolved predictions, including your new one, the prediction(s) most likely to never be resolved or most likely to be debunked in future installments) using `- **[Predicted Chunk XXXX -> RETIRED Chunk "
            <> curPad
            <> "]** <reason>` so at most 10 unresolved predictions remain in `## Active Predictions & Theories`."

writeCurrentChunkFile :: FilePath -> Chunk -> Int -> Int -> Int -> IO ()
writeCurrentChunkFile path c totalChunks totalChapters activeCount = do
  let isFront = chapterNumber c == 0
      labelKind = if isFront then "FRONT MATTER" else "CHAPTER"
      boundaries =
        [ "START OF " <> labelKind | isChapterStart c ]
          ++ [ "END OF " <> labelKind | isChapterEnd c ]
      boundaryNote =
        if null boundaries
          then ""
          else " (" <> T.intercalate ", " boundaries <> ")"
      chapterProgress =
        if isFront
          then "Front Matter"
          else "Chapter " <> jsonInt (chapterNumber c) <> " of " <> jsonInt totalChapters
      midChapterNote =
        if isChapterEnd c
          then []
          else
            [ "*Gatekeeper Note*: Mid-chapter split (Part "
                <> jsonInt (partInChapter c)
                <> " of "
                <> jsonInt (partsInChapter c)
                <> " — this chapter continues in the next chunk. Do not log immediate next-part scene continuations or chapter-title payoffs as predictions)."
            ]
      slateNote = [renderPredictionSlateNote (chunkIndex c) totalChunks activeCount]
      header =
        T.unlines $
          [ "<!-- LET'S READ GATEKEEPER: CHUNK " <> jsonInt (chunkIndex c) <> " OF " <> jsonInt totalChunks <> " -->"
          , "# " <> chapterTitle c
          , "**Progress**: Chunk "
              <> jsonInt (chunkIndex c)
              <> " of "
              <> jsonInt totalChunks
              <> " | "
              <> chapterProgress
              <> ", Part "
              <> jsonInt (partInChapter c)
              <> " of "
              <> jsonInt (partsInChapter c)
              <> boundaryNote
              <> " | ~"
              <> jsonInt (wordCount c)
              <> " words"
          ]
            ++ midChapterNote
            ++ slateNote
            ++ [ ""
               , "---"
               , ""
               ]
  TIO.writeFile path (header <> chunkText c <> "\n")

data ResponseSection = SecUserQuestion | SecCommentary | SecChunkSummary | SecUpdatedMemory
  deriving (Eq, Show)

cleanChunkSummary :: Text -> Text
cleanChunkSummary raw =
  let oneLine = T.unwords [T.strip l | l <- T.lines raw, not (T.null (T.strip l))]
      noBullet =
        if "- " `T.isPrefixOf` oneLine || "* " `T.isPrefixOf` oneLine
          then T.strip (T.drop 2 oneLine)
          else oneLine
      strippedStars = T.dropAround (== '*') noBullet
      (beforeColon, afterColon) = T.breakOn ":" strippedStars
   in if not (T.null afterColon)
        && ("chunk " `T.isPrefixOf` T.toLower (T.strip beforeColon) || "chunk_" `T.isPrefixOf` T.toLower (T.strip beforeColon))
        then T.strip (T.drop 1 afterColon)
        else noBullet

extractFallbackSummary :: Text -> Text
extractFallbackSummary commText =
  let candidates =
        [ T.strip l
        | l <- T.lines commText
        , let s = T.strip l
        , not (T.null s)
        , not ("#" `T.isPrefixOf` s)
        , not (">" `T.isPrefixOf` s)
        , not ("---" `T.isPrefixOf` s)
        ]
      firstLine = fromMaybe "Commentary recorded." (listToMaybe candidates)
   in if T.length firstLine > 160
        then T.take 157 firstLine <> "..."
        else firstLine

parseCombinedResponse :: Text -> (Maybe Text, Text, Maybe Text, Maybe Text)
parseCombinedResponse raw =
  let classifyLine l =
        let s = T.toUpper (T.strip l)
         in if s == "=== USER ===" || s == "=== QUESTION ===" || s == "=== USER MESSAGE ==="
              then Just SecUserQuestion
              else if s == "=== COMMENTARY ===" || s == "=== REPLY ===" || s == "=== RESPONSE ==="
                then Just SecCommentary
                else if s == "=== CHUNK SUMMARY ===" || s == "=== CHUNK INDEX ==="
                  then Just SecChunkSummary
                  else if s == "=== UPDATED MEMORY ==="
                    then Just SecUpdatedMemory
                    else Nothing
      go _ [] = []
      go curSec (l : ls) =
        case classifyLine l of
          Just newSec -> go newSec ls
          Nothing -> (curSec, l) : go curSec ls
      tagged = go SecCommentary (T.lines raw)
      extract sec = T.strip (T.unlines [l | (s, l) <- tagged, s == sec])
      userPart = extract SecUserQuestion
      commPart = extract SecCommentary
      sumPart = extract SecChunkSummary
      memPart = extract SecUpdatedMemory
   in ( if T.null userPart then Nothing else Just userPart
      , commPart
      , if T.null sumPart then Nothing else Just (cleanChunkSummary sumPart)
      , if T.null memPart then Nothing else Just memPart
      )

padChunkNumber :: Int -> String
padChunkNumber n =
  let s = show n
   in replicate (max 0 (4 - length s)) '0' ++ s

-- ---------------------------------------------------------------------------
-- CLI Commands
-- ---------------------------------------------------------------------------

data InitOptions = InitOptions
  { initSource :: FilePath
  , initSession :: FilePath
  , initMaxWords :: Int
  , initTitle :: Maybe Text
  , initPersona :: Maybe Text
  , initOverwrite :: Bool
  }

defaultPersonaText :: Text
defaultPersonaText =
  "Classic Forum Liveblogger — Conversational, observant, witty first-time reader posting live reactions in a forum thread: "
    <> "reacting directly inside the story's moments, talking back to the characters, tracking mysteries, "
    <> "and making bold predictions without lecturing, grading the author, or writing literary essays."

expandPersonaPreset :: Text -> Text
expandPersonaPreset raw =
  let norm = T.toLower (T.strip raw)
   in if norm == ""
        || norm == "classic forum liveblogger"
        || norm == "classic forum liveblogger (default)"
        || norm == "conversational, observant, witty first-time reader in a forum thread (reacting, quoting, speculating, and tracking mysteries)."
        then defaultPersonaText
        else if norm == "literary & craft analyst" || norm == "literary and craft analyst"
          then
            "Literary & Craft Analyst — Attentive workshop beta-reader who shares how specific word choices, pacing shifts, "
              <> "point-of-view cues, and subtext land on a first-time reader in real time: concrete and honest about what works "
              <> "or surprises on the page, without hollow book-review puffery ('masterclass', 'tour de force'), professorial lectures, or textbook truisms."
          else if norm == "mystery & theorycrafter"
            || norm == "mystery and theorycrafter"
            || norm == "mystery & theorycrafter (\"charlie day corkboard\")"
            || norm == "mystery & theorycrafter ('charlie day corkboard')"
            || norm == "charlie day corkboard"
            then
              "Mystery & Theorycrafter ('Charlie Day Corkboard') — Hyper-vigilant detective reader with infectious corkboard energy "
                <> "who treats every odd phrasing, timeline detail, and casual alibi as a live clue: cross-examining characters' excuses "
                <> "in the moment and connecting red string across chapters, without dry police-report summaries or detached lecturing."
            else if norm == "snarky riff-track" || norm == "snarky riff track"
              then
                "Snarky Riff-Track — Irreverent, affectionate riff-track host in the tradition of MST3K and Something Awful liveblogs: "
                  <> "cracking quick, in-the-moment jokes at absurd situations, melodrama, and questionable character survival instincts "
                  <> "while cheering for the story's wilder swings, never slipping into smug CinemaSins pedantry or mean-spirited lectures at the author."
              else if norm == "cozy & enthusiastic first-timer" || norm == "cozy and enthusiastic first-timer"
                then
                  "Cozy & Enthusiastic First-Timer — Warm, emotionally invested reader who roots wholeheartedly for the characters, "
                    <> "savors atmospheric and character-relationship details, and shares genuine gut reactions in natural prose: "
                    <> "expressing excitement and sympathy through specific details on the page, never relying on repetitive *[GASPS]* "
                    <> "stage-direction emotes or Hallmark/therapy-speak truisms."
                else T.strip raw

cmdInit :: InitOptions -> IO ()
cmdInit opts = do
  srcExists <- doesFileExist (initSource opts)
  unless srcExists $
    die ("Error: Source file not found: " ++ initSource opts)

  createDirectoryIfMissing True (initSession opts)
  sessionDir <- canonicalizePath (initSession opts)
  let entriesDir = sessionDir </> "entries"
      chunksDir = sessionDir </> "chunks"
      archiveDir = sessionDir </> "archive"
  createDirectoryIfMissing True entriesDir
  createDirectoryIfMissing True chunksDir
  createDirectoryIfMissing True (archiveDir </> "memory")

  (bookTitle, chunks) <- buildChunksFromSource (initSource opts) (initMaxWords opts) (initTitle opts)

  let totalChunks = length chunks
      totalChapters = max 1 (maximum (map chapterNumber chunks))
      totalWords = sum (map wordCount chunks)
      persona = maybe defaultPersonaText expandPersonaPreset (initPersona opts)

  saveVault (sessionDir </> ".vault.bin") chunks

  let st =
        SessionState
          { stTitle = bookTitle
          , stPersona = persona
          , stMaxWords = initMaxWords opts
          , stTotalChunks = totalChunks
          , stTotalChapters = totalChapters
          , stTotalWords = totalWords
          , stCurrentIndex = 0
          , stCurrentRecorded = True
          , stCurrentMeta = Nothing
          , stCompletedChunks = []
          , stChunkIndex = []
          , stCuratedMemory = defaultCuratedMemory
          }
  saveState sessionDir st

  let memoryPath = sessionDir </> "memory.md"
  memExists <- doesFileExist memoryPath
  when (not memExists || initOverwrite opts) $ do
    _ <- syncMemoryAndArchives sessionDir st
    pure ()

  let logPath = sessionDir </> "lets_read_log.md"
  logExists <- doesFileExist logPath
  when (not logExists || initOverwrite opts) $
    TIO.writeFile
      logPath
      ( "# Let's Read: "
          <> bookTitle
          <> "\n\n*Reader Persona*: "
          <> persona
          <> "\n\n---\n\n"
      )

  let storyPath = sessionDir </> "story_so_far.md"
  storyExists <- doesFileExist storyPath
  when (not storyExists || initOverwrite opts) $
    TIO.writeFile
      storyPath
      ( "# Story So Far: "
          <> bookTitle
          <> "\n\n---\n\n"
      )

  let avgWords = if totalChunks > 0 then totalWords `div` totalChunks else 0
  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "initialized")
      , ("title", jsonStr bookTitle)
      , ("session_dir", jsonStr (T.pack sessionDir))
      , ("total_chapters", jsonInt totalChapters)
      , ("total_chunks", jsonInt totalChunks)
      , ("total_words", jsonInt totalWords)
      , ("avg_words_per_chunk", jsonInt avgWords)
      , ("chunks_dir", jsonStr (T.pack chunksDir))
      , ("entries_dir", jsonStr (T.pack entriesDir))
      , ("archive_dir", jsonStr (T.pack archiveDir))
      , ("story_so_far_file", jsonStr (T.pack storyPath))
      , ("memory_file", jsonStr (T.pack memoryPath))
      , ("log_file", jsonStr (T.pack logPath))
      , ("orchestrator_rule", jsonStr orchestratorRuleText)
      , ("message", jsonStr "Session initialized. Run 'next' to unlock Chunk 1.")
      ]

writeCurrentPromptFile :: FilePath -> SessionState -> Chunk -> Int -> IO FilePath
writeCurrentPromptFile sessionDir st chunk activeCount = do
  absSession <- canonicalizePath sessionDir
  absTemplate <- canonicalizePath ".agents/skills/lets-read/resources/commentary_template.md"
  let curIdx = chunkIndex chunk
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      slatePromptLine = renderPredictionSlateNote curIdx totalChunks activeCount
      prevContextLines =
        if curIdx <= 1
          then []
          else
            let prevPad = padChunkNumber (curIdx - 1)
                prevEntryPath = absSession </> "entries" </> ("chunk_" ++ prevPad ++ ".md")
                prevChunkPath = absSession </> "chunks" </> ("chunk_" ++ prevPad ++ ".md")
             in [ "- Previous Commentary Entry (mandatory self-audit read): " <> T.pack prevEntryPath
                , "- Previous Story Chunk (read if newly rotated or mid-chapter): " <> T.pack prevChunkPath
                ]
      promptPath = sessionDir </> "current_prompt.md"
      promptText =
        T.unlines $
          [ "Please read the newly unlocked chunk (Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> ") and update your Let's Read commentary and memory."
          , "- Current Chunk File (mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          ]
            ++ prevContextLines
            ++ [ "- Commentary Guide Template (flexible reference): " <> T.pack absTemplate
               , "- Multi-Level Memory & Index Archive (on-demand read_file): " <> T.pack (absSession </> "archive")
               , "- Unlocked Story Chunks Archive (on-demand read_file): " <> T.pack (absSession </> "chunks")
               , "- Previous Commentary Entries (on-demand read_file): " <> T.pack (absSession </> "entries")
               , "- Active Persona: " <> expandPersonaPreset (stPersona st)
               , "- " <> slatePromptLine
               , ""
               , "Remember:"
               , "1. Read `current_chunk.md` and `memory.md` first (plus `entries/chunk_(N-1).md` for self-audit when Chunk > 1, and `chunks/chunk_(N-1).md` if you are a newly rotated subagent or picking up mid-chapter). Reference `commentary_template.md` as a flexible guide; let your commentary flow naturally like a single forum post without chopping it into multiple `###` mini-essay subheadings (save `### Theory & Mystery Notes` for the end), and do not start `=== COMMENTARY ===` with a redundant `# Chunk X/Y` header."
               , "2. Self-Audit, Craft Check & \"Egg-on-Face\" Rule: Before writing your reaction, compare what just happened in `current_chunk.md` against your previous entry (`entries/chunk_(N-1).md`) and your predictions in `memory.md`. First, audit your prose voice: if `entries/chunk_(N-1).md` slipped into essayist/professorial lecturing (review jargon like \"masterclass\"/\"emotional axis\", grading the author, unsolicited lore lectures, textbook truisms, or multi-header mini-essays) OR relied on repetitive bracketed `*[...]*` stage directions / sportscasting, deliberately break that habit on this turn. Second, if the story subverted your expectations or pulled a fake-out that tricked you—especially if a character in the story had the exact same misconception you just had—call yourself out openly! Never gloss over a wrong theory or pretend you knew all along, and never take a victory lap (\"I called it!\") on an obvious 1–2 chunk cliffhanger guess right after getting fooled."
               , "3. Mandatory 1-Per-Chunk Prediction Quota, 10-Prediction Cap & Enforced Notation (Audited by `LetsRead.hs`):"
               , "   - On every chunk (before the final chunk), you MUST make 1 new non-softball, multi-chapter prediction (`- **[Predicted Chunk " <> curPad <> "]** *Clue/Anomaly*: ... -> *Theory*: ... *(vs. Plausible Rival: ...)*`) in both `=== COMMENTARY ===` and `## Active Predictions & Theories` in `=== UPDATED MEMORY ===`. (Never log stated itineraries, immediate next-part scene/cliffhanger continuations, or status-quo routines.)"
               , "   - Cap unresolved predictions in `## Active Predictions & Theories` at 10. If adding your new prediction leaves more than 10 unresolved predictions overall (after moving any `CONFIRMED`/`DEBUNKED`/`SUBVERTED` predictions to `## Hall of Fame & Shame`), you MUST retire the prediction(s) most likely to never be resolved or most likely to be debunked in future installments using `- **[Predicted Chunk XXXX -> RETIRED Chunk " <> curPad <> "]** <reason>` (in both `=== COMMENTARY ===` and `=== UPDATED MEMORY ===`, removing the retired item from `## Active Predictions & Theories`) until at most 10 unresolved predictions remain."
               , "   - Story-resolved predictions MUST be moved to `## Hall of Fame & Shame (Major Hits & Misses)` with exact notation (`<= 200 chars` after the bracket header) and also showcased in `=== COMMENTARY ===`: `- **[Predicted Chunk XXXX -> CONFIRMED Chunk " <> curPad <> "]** ...`, `- **[Predicted Chunk XXXX -> DEBUNKED Chunk " <> curPad <> "]** ...`, or `- **[Predicted Chunk XXXX -> SUBVERTED Chunk " <> curPad <> "]** ...`."
               , "   - Never use `[Refined ...]`, `[Updated ...]`, or `[Active / Refined ...]`, never rewrite an existing active prediction's text in place to fit new facts, and never silently drop an unresolved prediction. If `LetsRead.hs` injected a `[READER SUB-AGENT REWROTE PREDICTION OR MOVED GOALPOSTS IN FILE ...]` block into `memory.md`, you MUST address it openly in your commentary and either restore the exact `*Before*` prediction, resolve it with `CONFIRMED`/`DEBUNKED`/`SUBVERTED`, or (if above the 10-prediction cap) retire it with `RETIRED`. If `LetsRead.hs` injected an `[INVALID PREDICTION TAG OR FORMAT IN FILE ...]` block, fix the bracket tag or chunk number in `=== UPDATED MEMORY ===` (or remove the malformed line) as instructed."
               , "4. Quote verbatim from `current_chunk.md` (inserting `[...]` if skipping intervening stage directions). React *inside* the story as a live forum reader: never lecture, never grade or praise the author with review jargon (\"masterclass\", \"philosophical engine\", \"emotional axis\", \"encapsulates\"), never write detached textbook truisms about human nature, never \"double-tell\" (or use \"hype-disguised double-telling\" with `*[ALL-CAPS EMOTE]*` + plot paraphrase), and never append a `Key Developments` summary bullet list to `=== COMMENTARY ===`."
               , "5. Whenever you reference, quote, or compare specific scenes, predictions, or dialogue from an earlier chunk that is not in your immediate conversation history, verify it first using `## Memory Archive & Index Tree` in `memory.md` (following links into `<session_dir>/archive/L1_XXXX.md` if needed, then reading `<session_dir>/chunks/chunk_XXXX.md`, `<session_dir>/entries/chunk_XXXX.md`, or `<session_dir>/archive/memory/chunk_XXXX.md`). Never invent quotes or scene details from condensed `memory.md` bullets."
               , "6. Never inspect `.vault.bin` or any local file outside `<session_dir>` (except `commentary_template.md`), and never search the web for the specific story being read. Background canon/franchise lore searches via `search_web` are welcome, but strictly quarantine external canon from in-story fact: in `=== COMMENTARY ===`, explicitly attribute external lore to the source material and cross-check age/timeline math against Bullet 1 of `## Story Summary So Far`; in `=== CHUNK SUMMARY ===` and `=== UPDATED MEMORY ===`, record only facts established in the story text (or confirmed in `Reader Discussion`)."
               , "7. Output all three required sections: `=== COMMENTARY ===`, `=== CHUNK SUMMARY ===` (1 line), and `=== UPDATED MEMORY ===` (all 6 curated sections, preserving the `(Persistent)` baseline, core-cast/supporting-fates, and craft-directive anchors; `LetsRead.hs` automatically maintains `## Memory Archive & Index Tree`)."
               ]
  TIO.writeFile promptPath promptText
  pure promptPath

stripLeadingChunkHeading :: Text -> Text
stripLeadingChunkHeading txt =
  case T.lines (T.strip txt) of
    (firstLine : restLines)
      | Just (_, hTitle) <- parseMarkdownHeading firstLine
      , let cleaned = T.strip (T.dropWhile (not . isAlphaNum) hTitle)
      , "chunk " `T.isPrefixOf` T.toLower cleaned ->
          T.strip (T.unlines restLines)
    _ -> T.strip txt

-- | Recommend rotating the blind-reader subagent only at a chapter boundary
-- after at least 6 chunks have been read since the last rotation (or after
-- 10 chunks if a single chapter is unusually long), so 2-4 part chapters
-- are never split mid-scene across two subagent instances.
computeShouldRotate :: [ChunkIndexEntry] -> Chunk -> Bool
computeShouldRotate history chunk =
  let nextIdx = chunkIndex chunk
      priorEntries =
        sortOn
          cieChunkIndex
          [ e
          | e <- history
          , cieChunkIndex e > 1
          , cieChunkIndex e < nextIdx
          ]
      stepLastRot lastRot e =
        let idx = cieChunkIndex e
            sinceLast = idx - lastRot
            rotatedHere = (ciePartInChapter e == 1 && sinceLast >= 6) || sinceLast >= 10
         in if rotatedHere then idx else lastRot
      lastRotIdx = foldl' stepLastRot 1 priorEntries
      chunksSinceRotation = nextIdx - lastRotIdx
   in nextIdx > 1
        && ( (isChapterStart chunk && chunksSinceRotation >= 6)
              || chunksSinceRotation >= 10
           )

cmdNext :: FilePath -> Bool -> IO ()
cmdNext rawSessionDir forceFlag = do
  sessionDir <- canonicalizePath rawSessionDir
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
      totalChunks = stTotalChunks st

  when (curIdx > 0 && not (stCurrentRecorded st) && not forceFlag) $
    die $
      "Error: Chunk "
        ++ show curIdx
        ++ " is already unlocked, but its commentary has not been recorded yet. "
        ++ "Run 'record' first (or pass --force to override)."

  if curIdx >= totalChunks
    then
      TIO.putStrLn $
        jsonObject
          [ ("status", jsonStr "finished")
          , ("current_index", jsonInt curIdx)
          , ("total_chunks", jsonInt totalChunks)
          , ("orchestrator_rule", jsonStr orchestratorRuleText)
          , ("message", jsonStr "All chunks have been read! The Let's Read is complete.")
          ]
    else do
      let nextIdx = curIdx + 1
          activeCount = countActivePredictionsInMemory (stCuratedMemory st)
      chunk <- loadVaultChunk (sessionDir </> ".vault.bin") nextIdx
      let chunkFile = sessionDir </> "current_chunk.md"
          chunksDir = sessionDir </> "chunks"
          archiveChunkFile = chunksDir </> ("chunk_" ++ padChunkNumber nextIdx ++ ".md")
      createDirectoryIfMissing True chunksDir
      writeCurrentChunkFile chunkFile chunk totalChunks (stTotalChapters st) activeCount
      writeCurrentChunkFile archiveChunkFile chunk totalChunks (stTotalChapters st) activeCount
      promptFile <- writeCurrentPromptFile sessionDir st chunk activeCount

      -- Rebuild cumulative unlocked story text from all unlocked chunks so far
      allChunkNames <- listDirectory chunksDir
      let unlockedFiles =
            sort
              [ chunksDir </> f
              | f <- allChunkNames
              , "chunk_" `isPrefixOf` f
              , ".md" `isSuffixOf` f
              ]
      unlockedContents <- mapM readTextFileSafe unlockedFiles
      let storyHeader =
            "# Story So Far: "
              <> stTitle st
              <> "\n\n---\n\n"
          storySoFarPath = sessionDir </> "story_so_far.md"
      TIO.writeFile storySoFarPath (storyHeader <> T.intercalate "\n\n---\n\n" unlockedContents)

      let meta = chunkToMeta chunk
          st' =
            st
              { stCurrentIndex = nextIdx
              , stCurrentRecorded = False
              , stCurrentMeta = Just meta
              }
      saveState sessionDir st'

      let shouldRotate = computeShouldRotate (stChunkIndex st) chunk
      TIO.putStrLn $
        jsonObject
          [ ("status", jsonStr "unlocked")
          , ("chunk_index", jsonInt (chunkIndex chunk))
          , ("total_chunks", jsonInt totalChunks)
          , ("chapter_number", jsonInt (chapterNumber chunk))
          , ("total_chapters", jsonInt (stTotalChapters st))
          , ("chapter_title", jsonStr (chapterTitle chunk))
          , ("part_in_chapter", jsonInt (partInChapter chunk))
          , ("parts_in_chapter", jsonInt (partsInChapter chunk))
          , ("is_chapter_start", jsonBool (isChapterStart chunk))
          , ("is_chapter_end", jsonBool (isChapterEnd chunk))
          , ("word_count", jsonInt (wordCount chunk))
          , ("active_predictions_count", jsonInt activeCount)
          , ("current_chunk_file", jsonStr (T.pack chunkFile))
          , ("subagent_prompt_file", jsonStr (T.pack promptFile))
          , ("chunk_archive_file", jsonStr (T.pack archiveChunkFile))
          , ("chunks_dir", jsonStr (T.pack chunksDir))
          , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
          , ("entries_dir", jsonStr (T.pack (sessionDir </> "entries")))
          , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
          , ("rotate_subagent_recommended", jsonBool shouldRotate)
          , ("orchestrator_rule", jsonStr orchestratorRuleText)
          ]

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
  entryContents <- mapM readTextFileSafe chunkFiles
  let logHeader =
        "# Let's Read: "
          <> stTitle st
          <> "\n\n*Reader Persona*: "
          <> stPersona st
          <> "\n\n---\n\n"
      logPath = sessionDir </> "lets_read_log.md"
  TIO.writeFile logPath (logHeader <> T.concat entryContents)
  pure logPath

formatPredictionTrackerCallout :: [Text] -> Text
formatPredictionTrackerCallout [] = ""
formatPredictionTrackerCallout trackerLines =
  "\n\n> [!NOTE]\n> **Prediction Tracker Update**:\n"
    <> T.stripEnd
      ( T.unlines
          [ if T.null (T.strip l) then ">" else "> " <> l
          | l <- trackerLines
          ]
      )

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

data RecordOptions = RecordOptions
  { recSession :: FilePath
  , recResponseFile :: Maybe FilePath
  , recSubagentLog :: Maybe FilePath
  , recCommentaryFile :: Maybe FilePath
  , recMemoryFile :: Maybe FilePath
  }

stripFileUriPrefix :: FilePath -> FilePath
stripFileUriPrefix p
  | "file://" `isPrefixOf` p = drop 7 p
  | otherwise = p

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

extractSubagentLogResponse :: FilePath -> IO Text
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
          else die ("Error: Subagent transcript log not found: " ++ rawLogPath)
  raw <- readTextFileSafe targetPath
  let isPlannerResponseLine l =
        extractJsonStringField "type" l == Just "PLANNER_RESPONSE"
      revLines = filter isPlannerResponseLine (reverse (T.lines raw))
      lineTexts l =
        [ T.strip m
        | Just m <- [extractJsonStringField "Message" l, extractJsonStringField "content" l]
        , not (T.null (T.strip m))
        ]
      allCandidates = concatMap lineTexts revLines
      hasDelimiters t =
        "=== COMMENTARY ===" `T.isInfixOf` t
          || "=== UPDATED MEMORY ===" `T.isInfixOf` t
          || "=== CHUNK SUMMARY ===" `T.isInfixOf` t
      sendMsgCandidates =
        [ T.strip m
        | l <- revLines
        , Just m <- [extractJsonStringField "Message" l]
        , not (T.null (T.strip m))
        ]
      preferred =
        filter hasDelimiters allCandidates
          ++ sendMsgCandidates
          ++ filter (\t -> T.length t > 200) allCandidates
          ++ allCandidates
  case preferred of
    (latest : _) -> pure latest
    [] ->
      die ("Error: No non-empty PLANNER_RESPONSE content or send_message found in subagent log: " ++ targetPath)

cmdRecord :: RecordOptions -> IO ()
cmdRecord opts = do
  sessionDir <- canonicalizePath (recSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."

  (_, commText, mParsedSummary, mParsedMem) <-
    case recSubagentLog opts of
      Just logPath -> do
        raw <- extractSubagentLogResponse logPath
        TIO.writeFile (sessionDir </> "last_response.md") (raw <> "\n")
        pure (parseCombinedResponse raw)
      Nothing ->
        case recResponseFile opts of
          Just respPath -> do
            exists <- doesFileExist respPath
            unless exists $ die ("Error: Response file not found: " ++ respPath)
            raw <- readTextFileSafe respPath
            pure (parseCombinedResponse raw)
          Nothing ->
            case recCommentaryFile opts of
              Just commPath -> do
                exists <- doesFileExist commPath
                unless exists $ die ("Error: Commentary file not found: " ++ commPath)
                raw <- readTextFileSafe commPath
                pure (Nothing, T.strip raw, Nothing, Nothing)
              Nothing ->
                die "Error: Provide --response-file, --subagent-log, or --commentary-file."

  when (T.null commText) $
    die "Error: Commentary content is empty."

  mExplicitMem <-
    case recMemoryFile opts of
      Nothing -> pure Nothing
      Just memPath -> do
        exists <- doesFileExist memPath
        unless exists $ die ("Error: Memory file not found: " ++ memPath)
        txt <- readTextFileSafe memPath
        let stripped = T.strip txt
        pure (if T.null stripped then Nothing else Just stripped)

  let finalMem =
        case mExplicitMem of
          Just m -> Just m
          Nothing -> mParsedMem
      cleanedCommText = stripLeadingChunkHeading commText
  (curated', auditBlocks, trackerUpdates) <-
    resolveAndAuditMemory sessionDir curIdx (stTotalChunks st) True cleanedCommText (stCuratedMemory st) finalMem

  let summaryTxt = fromMaybe (extractFallbackSummary commText) mParsedSummary
      (chapNum, chapTitle, partNum, partsTotal) =
        case stCurrentMeta st of
          Just m -> (metaChapterNumber m, metaChapterTitle m, metaPartInChapter m, metaPartsInChapter m)
          Nothing -> (1, "Chapter ?", 1, 1)
      chapDisplay
        | chapNum == 0 = chapTitle
        | "chapter " `T.isPrefixOf` T.toLower (T.strip chapTitle) = chapTitle
        | otherwise = "Chapter " <> jsonInt chapNum <> ": " <> chapTitle
      entryHeader =
        "## Chunk "
          <> jsonInt curIdx
          <> "/"
          <> jsonInt (stTotalChunks st)
          <> " — "
          <> chapDisplay
          <> " (Part "
          <> jsonInt partNum
          <> "/"
          <> jsonInt partsTotal
          <> ")\n\n"
      trackerCallout = formatPredictionTrackerCallout trackerUpdates
      auditCallout = formatAuditEntryCallout auditBlocks
      entryContent = entryHeader <> cleanedCommText <> trackerCallout <> auditCallout <> "\n\n---\n\n"
      entriesDir = sessionDir </> "entries"
      entryFile = entriesDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")

  createDirectoryIfMissing True entriesDir
  TIO.writeFile entryFile entryContent
  logPath <- rebuildMasterLog sessionDir st

  let completed' =
        if curIdx `elem` stCompletedChunks st
          then stCompletedChunks st
          else sort (curIdx : stCompletedChunks st)
      newIndexEntry =
        ChunkIndexEntry
          { cieChunkIndex = curIdx
          , cieChapterNumber = chapNum
          , cieChapterTitle = chapTitle
          , ciePartInChapter = partNum
          , ciePartsInChapter = partsTotal
          , cieSummary = summaryTxt
          }
      chunkIndex' =
        sortOn
          cieChunkIndex
          (newIndexEntry : filter (\e -> cieChunkIndex e /= curIdx) (stChunkIndex st))
      st' =
        st
          { stCurrentRecorded = True
          , stCompletedChunks = completed'
          , stChunkIndex = chunkIndex'
          , stCuratedMemory = curated'
          }

  (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
  saveState sessionDir st'

  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "recorded")
      , ("chunk_index", jsonInt curIdx)
      , ("total_chunks", jsonInt (stTotalChunks st))
      , ("remaining_chunks", jsonInt (stTotalChunks st - curIdx))
      , ("entry_file", jsonStr (T.pack entryFile))
      , ("log_file", jsonStr (T.pack logPath))
      , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
      , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
      , ("active_predictions_count", jsonInt (countActivePredictionsInMemory curated'))
      , ("prediction_audit_warnings_count", jsonInt (length auditBlocks))
      , ("memory_compaction_needed", jsonBool needsCompaction)
      , ("curated_memory_lines", jsonInt curLines)
      , ("curated_memory_bytes", jsonInt curBytes)
      , ("orchestrator_rule", jsonStr orchestratorRuleText)
      , ("discussion_command_hint", jsonStr "If the user replies with comments, questions, or theories before asking to continue, forward their message to blind-reader and record the exchange using 'LetsRead.hs discuss --session <dir> --user-message \"...\" --response-file <path>'.")
      ]

data DiscussOptions = DiscussOptions
  { discSession :: FilePath
  , discResponseFile :: Maybe FilePath
  , discSubagentLog :: Maybe FilePath
  , discCommentaryFile :: Maybe FilePath
  , discMemoryFile :: Maybe FilePath
  , discUserMessage :: Maybe Text
  , discUserFile :: Maybe FilePath
  }

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

cmdDiscuss :: DiscussOptions -> IO ()
cmdDiscuss opts = do
  sessionDir <- canonicalizePath (discSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."
  unless (stCurrentRecorded st) $
    die "Error: Current chunk commentary has not been recorded yet. Run 'record' before 'discuss'."

  (mParsedUser, replyText, mParsedSummary, mParsedMem) <-
    case discSubagentLog opts of
      Just logPath -> do
        raw <- extractSubagentLogResponse logPath
        TIO.writeFile (sessionDir </> "last_response.md") (raw <> "\n")
        pure (parseCombinedResponse raw)
      Nothing ->
        case discResponseFile opts of
          Just respPath -> do
            exists <- doesFileExist respPath
            unless exists $ die ("Error: Response file not found: " ++ respPath)
            raw <- readTextFileSafe respPath
            pure (parseCombinedResponse raw)
          Nothing ->
            case discCommentaryFile opts of
              Just commPath -> do
                exists <- doesFileExist commPath
                unless exists $ die ("Error: Commentary file not found: " ++ commPath)
                raw <- readTextFileSafe commPath
                pure (Nothing, T.strip raw, Nothing, Nothing)
              Nothing ->
                die "Error: Provide --response-file, --subagent-log, or --commentary-file."

  when (T.null replyText) $
    die "Error: Discussion reply content is empty."

  mUserFromFile <-
    case discUserFile opts of
      Nothing -> pure Nothing
      Just uPath -> do
        exists <- doesFileExist uPath
        unless exists $ die ("Error: User message file not found: " ++ uPath)
        txt <- readTextFileSafe uPath
        let stripped = T.strip txt
        pure (if T.null stripped then Nothing else Just stripped)

  let mUserMsg =
        case discUserMessage opts of
          Just m | not (T.null (T.strip m)) -> Just (T.strip m)
          _ ->
            case mUserFromFile of
              Just m -> Just m
              Nothing -> mParsedUser

  mExplicitMem <-
    case discMemoryFile opts of
      Nothing -> pure Nothing
      Just memPath -> do
        exists <- doesFileExist memPath
        unless exists $ die ("Error: Memory file not found: " ++ memPath)
        txt <- readTextFileSafe memPath
        let stripped = T.strip txt
        pure (if T.null stripped then Nothing else Just stripped)

  let finalMem =
        case mExplicitMem of
          Just m -> Just m
          Nothing -> mParsedMem
      entriesDir = sessionDir </> "entries"
      entryFile = entriesDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")

  entryExists <- doesFileExist entryFile
  unless entryExists $
    die ("Error: Recorded entry file not found: " ++ entryFile)

  (curated', auditBlocks, trackerUpdates) <-
    resolveAndAuditMemory sessionDir curIdx (stTotalChunks st) False replyText (stCuratedMemory st) finalMem

  existingEntry <- readTextFileSafe entryFile
  let baseEntry = stripTrailingEntryRule existingEntry
      hasDiscussionHeader = "### Reader Discussion" `T.isInfixOf` baseEntry
      headingPrefix = if hasDiscussionHeader then "" else "### Reader Discussion\n\n"
      userBlock =
        case mUserMsg of
          Nothing -> ""
          Just u -> formatUserQuote u <> "\n"
      trackerCallout = formatPredictionTrackerCallout trackerUpdates
      auditCallout = formatAuditEntryCallout auditBlocks
      appendedSection = headingPrefix <> userBlock <> replyText <> trackerCallout <> auditCallout
      updatedEntry = baseEntry <> "\n\n" <> appendedSection <> "\n\n---\n\n"

  TIO.writeFile entryFile updatedEntry
  logPath <- rebuildMasterLog sessionDir st

  let chunkIndex' =
        case mParsedSummary of
          Nothing -> stChunkIndex st
          Just newSum ->
            map
              (\e -> if cieChunkIndex e == curIdx then e {cieSummary = newSum} else e)
              (stChunkIndex st)
      memUpdated = isJust finalMem || isJust mParsedSummary || (curated' /= stCuratedMemory st) || not (null auditBlocks)
      st' =
        st
          { stChunkIndex = chunkIndex'
          , stCuratedMemory = curated'
          }

  (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
  when memUpdated $
    saveState sessionDir st'

  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "discussed")
      , ("chunk_index", jsonInt curIdx)
      , ("entry_file", jsonStr (T.pack entryFile))
      , ("log_file", jsonStr (T.pack logPath))
      , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
      , ("memory_updated", jsonBool memUpdated)
      , ("prediction_audit_warnings_count", jsonInt (length auditBlocks))
      , ("memory_compaction_needed", jsonBool needsCompaction)
      , ("curated_memory_lines", jsonInt curLines)
      , ("curated_memory_bytes", jsonInt curBytes)
      , ("orchestrator_rule", jsonStr orchestratorRuleText)
      ]

cmdStatus :: FilePath -> IO ()
cmdStatus rawSessionDir = do
  sessionDir <- canonicalizePath rawSessionDir
  st <- loadState sessionDir
  TIO.putStr (renderStateJson sessionDir st)

-- ---------------------------------------------------------------------------
-- Argument Parsing & Entrypoint
-- ---------------------------------------------------------------------------

usage :: String
usage =
  unlines
    [ "Usage: LetsRead.hs <command> [options]"
    , ""
    , "Commands:"
    , "  init <source> --session <dir> [--max-words <n>] [--title <str>] [--persona <str>] [--overwrite]"
    , "  next --session <dir> [--force]"
    , "  record --session <dir> [--response-file <path>] [--subagent-log <path>] [--commentary-file <path>] [--memory-file <path>]"
    , "  discuss --session <dir> [--response-file <path>] [--subagent-log <path>] [--commentary-file <path>] [--user-message <str>] [--user-file <path>] [--memory-file <path>]"
    , "  status --session <dir>"
    ]

parseInitArgs :: [String] -> IO InitOptions
parseInitArgs args = go (InitOptions "" "" 1500 Nothing Nothing False) args
  where
    go opts []
      | null (initSource opts) = die ("Error: Missing <source> path.\n\n" ++ usage)
      | null (initSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {initSession = v} rest
    go opts ("--max-words" : v : rest) =
      case reads v of
        [(n, "")] | n > 50 -> go opts {initMaxWords = n} rest
        _ -> die ("Error: Invalid --max-words value: " ++ v)
    go opts ("--title" : v : rest) = go opts {initTitle = Just (T.pack v)} rest
    go opts ("--persona" : v : rest) = go opts {initPersona = Just (T.pack v)} rest
    go opts ("--overwrite" : rest) = go opts {initOverwrite = True} rest
    go opts (arg : rest)
      | "-" `isPrefixOf` arg = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)
      | null (initSource opts) = go opts {initSource = arg} rest
      | otherwise = die ("Error: Unexpected argument: " ++ arg ++ "\n\n" ++ usage)

parseNextArgs :: [String] -> IO (FilePath, Bool)
parseNextArgs = go ("", False)
  where
    go (sess, frc) []
      | null sess = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure (sess, frc)
    go (_, frc) ("--session" : v : rest) = go (v, frc) rest
    go (sess, _) ("--force" : rest) = go (sess, True) rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

parseRecordArgs :: [String] -> IO RecordOptions
parseRecordArgs = go (RecordOptions "" Nothing Nothing Nothing Nothing)
  where
    go opts []
      | null (recSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {recSession = v} rest
    go opts ("--response-file" : v : rest) = go opts {recResponseFile = Just v} rest
    go opts ("--subagent-log" : v : rest) = go opts {recSubagentLog = Just v} rest
    go opts ("--commentary-file" : v : rest) = go opts {recCommentaryFile = Just v} rest
    go opts ("--memory-file" : v : rest) = go opts {recMemoryFile = Just v} rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

parseDiscussArgs :: [String] -> IO DiscussOptions
parseDiscussArgs = go (DiscussOptions "" Nothing Nothing Nothing Nothing Nothing Nothing)
  where
    go opts []
      | null (discSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {discSession = v} rest
    go opts ("--response-file" : v : rest) = go opts {discResponseFile = Just v} rest
    go opts ("--subagent-log" : v : rest) = go opts {discSubagentLog = Just v} rest
    go opts ("--commentary-file" : v : rest) = go opts {discCommentaryFile = Just v} rest
    go opts ("--memory-file" : v : rest) = go opts {discMemoryFile = Just v} rest
    go opts ("--user-message" : v : rest) = go opts {discUserMessage = Just (T.pack v)} rest
    go opts ("--user-file" : v : rest) = go opts {discUserFile = Just v} rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

parseStatusArgs :: [String] -> IO FilePath
parseStatusArgs = go ""
  where
    go sess []
      | null sess = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure sess
    go _ ("--session" : v : rest) = go v rest
    go _ (arg : _) = die ("Error: Unknown option: " ++ arg ++ "\n\n" ++ usage)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ("--help" : _) -> putStr usage >> exitSuccess
    ("-h" : _) -> putStr usage >> exitSuccess
    ("init" : rest) -> parseInitArgs rest >>= cmdInit
    ("next" : rest) -> do
      (sess, frc) <- parseNextArgs rest
      cmdNext sess frc
    ("record" : rest) -> parseRecordArgs rest >>= cmdRecord
    ("discuss" : rest) -> parseDiscussArgs rest >>= cmdDiscuss
    ("status" : rest) -> parseStatusArgs rest >>= cmdStatus
    _ -> do
      hPutStrLn stderr usage
      die "Error: Please specify a valid command (init, next, record, discuss, status)."
