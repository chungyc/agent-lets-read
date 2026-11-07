#!/usr/bin/env runghc
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
import Control.Monad (forM, forM_, unless, when)
import Data.Binary (Binary, decode, encode)
import Data.Bits (xor)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Char (chr, isAlphaNum, isDigit, isHexDigit, isSpace, isUpper, toLower)
import Data.List (foldl', groupBy, isPrefixOf, isSuffixOf, nub, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Ord (Down (..))
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
  , removeFile
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

data PredictionStatus
  = PredStatusActive
  | PredStatusConfirmed !Int !Bool -- ^ resolvedChunk, isShortHorizon (< 3 chunks)
  | PredStatusDebunked !Int        -- ^ resolvedChunk
  | PredStatusSubverted !Int       -- ^ resolvedChunk
  | PredStatusRetired !Int         -- ^ retiredChunk
  deriving (Show, Eq, Generic)

instance Binary PredictionStatus

data PredictionRecord = PredictionRecord
  { prOriginChunk :: !Int
  , prChapterNumber :: !Int
  , prChapterTitle :: !Text
  , prTopics :: ![Text]
  , prClue :: !Text
  , prTheory :: !Text
  , prRival :: !Text
  , prRawBody :: !Text
  , prNormBody :: !Text
  , prStatus :: !PredictionStatus
  , prResolutionNote :: !(Maybe Text)
  }
  deriving (Show, Eq, Generic)

instance Binary PredictionRecord

data SessionState = SessionState
  { stTitle :: !Text
  , stPersona :: !Text
  , stMaxWords :: !Int
  , stTotalChunks :: !Int
  , stTotalChapters :: !Int
  , stTotalWords :: !Int
  , stCurrentIndex :: !Int
  , stCurrentRecorded :: !Bool
  , stCurrentJudged :: !Bool
  , stCurrentMeta :: !(Maybe ChunkMeta)
  , stCompletedChunks :: ![Int]
  , stChunkIndex :: ![ChunkIndexEntry]
  , stCuratedMemory :: ![(Text, Text)]
  , stPredictions :: ![PredictionRecord]
  , stPendingRetirements :: ![(Int, Text)]
  , stPendingLinterWarnings :: ![Text]
  , stLastJudgeSummary :: ![Text]
  , stPredictionAuditWarnings :: ![Text]
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
  "NEVER run python, python3, or ad-hoc shell scripts; NEVER impersonate blind-reader, prediction-judge, or commentary-critic, answer user story questions in your own voice, edit memory.md directly, or paste current_chunk.md/memory.md inline into prompts. Always pass the prompt from <session_dir>/current_prompt.md to blind-reader, record with 'lets-read record', then pass <session_dir>/current_judge_prompt.md to prediction-judge and <session_dir>/current_critic_prompt.md to commentary-critic in parallel and finalize with 'lets-read judge --session <dir> --subagent-log <judge_log> --critic-log <critic_log>' (or record user discussions with 'lets-read discuss')."

renderStateJson :: FilePath -> SessionState -> Text
renderStateJson sessionDir st =
  let isFin = stCurrentIndex st >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
      activeCnt = length [pr | pr <- stPredictions st, prStatus pr == PredStatusActive]
      totalPreds = length (stPredictions st)
   in jsonObject
        [ ("title", jsonStr (stTitle st))
        , ("persona", jsonStr (stPersona st))
        , ("max_words_per_chunk", jsonInt (stMaxWords st))
        , ("current_index", jsonInt (stCurrentIndex st))
        , ("total_chunks", jsonInt (stTotalChunks st))
        , ("total_chapters", jsonInt (stTotalChapters st))
        , ("total_words", jsonInt (stTotalWords st))
        , ("current_recorded", jsonBool (stCurrentRecorded st))
        , ("current_judged", jsonBool (stCurrentJudged st))
        , ("completed_chunks_count", jsonInt (length (stCompletedChunks st)))
        , ("is_finished", jsonBool isFin)
        , ("active_predictions_count", jsonInt activeCnt)
        , ("total_predictions_count", jsonInt totalPreds)
        , ("pending_retirements_count", jsonInt (length (stPendingRetirements st)))
        , ("pending_linter_warnings_count", jsonInt (length (stPendingLinterWarnings st)))
        , ("current_chunk_meta", renderMetaJson (stCurrentMeta st))
        , ("current_chunk_file", jsonStr (T.pack (sessionDir </> "current_chunk.md")))
        , ("subagent_prompt_file", jsonStr (T.pack (sessionDir </> "current_prompt.md")))
        , ("judge_prompt_file", jsonStr (T.pack (sessionDir </> "current_judge_prompt.md")))
        , ("critic_prompt_file", jsonStr (T.pack (sessionDir </> "current_critic_prompt.md")))
        , ("critic_feedback_file", jsonStr (T.pack (sessionDir </> "critic_feedback.md")))
        , ("chunks_dir", jsonStr (T.pack (sessionDir </> "chunks")))
        , ("story_so_far_file", jsonStr (T.pack (sessionDir </> "story_so_far.md")))
        , ("entries_dir", jsonStr (T.pack (sessionDir </> "entries")))
        , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
        , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
        , ("predictions_by_chronology_file", jsonStr (T.pack (sessionDir </> "predictions" </> "by_chronology.md")))
        , ("predictions_by_topic_file", jsonStr (T.pack (sessionDir </> "predictions" </> "by_topic.md")))
        , ("hall_of_fame_file", if isFin then jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")) else "null")
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
-- Templates, Prediction Ledger, Memory Merger & Multi-Level Archive Tree
-- ---------------------------------------------------------------------------

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
                else if "prediction" `T.isInfixOf` h
                  || "theor" `T.isInfixOf` h
                  || "hall of fame" `T.isInfixOf` h
                  || "shame" `T.isInfixOf` h
                  || "hits & misses" `T.isInfixOf` h
                  then Just "_FallbackPredictions_"
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

isPlaceholderSection :: Text -> Bool
isPlaceholderSection body =
  let s = T.toLower (T.strip body)
   in T.null s || any (`T.isInfixOf` s) placeholderSubstrings

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

data ResolutionKind = ResConfirmed | ResDebunked | ResSubverted | ResRetired
  deriving (Eq, Show)

data ParsedPrediction
  = PredValidActive
      { ppOrigChunk :: !Int
      , ppTopics :: ![Text]
      , ppClue :: !Text
      , ppTheory :: !Text
      , ppRival :: !Text
      , ppRawLine :: !Text
      , ppBodyAfterBracket :: !Text
      , ppNormBody :: !Text
      }
  | PredValidKeepActive
      { ppKeepOrigChunk :: !Int
      , ppRawLine :: !Text
      , ppBodyAfterBracket :: !Text
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
        then PredInvalidNotation Nothing l l (normalizePredBody l)
        else
          let (insideBeforePipe, _) = T.breakOn "|" insideRaw
              (insideBeforeParen, _) = T.breakOn "(" insideBeforePipe
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
                                PredValidResolved (Just cOnly) cOnly rKind l afterBracket normB
                          _ ->
                            PredInvalidNotation (listToMaybe nums) l afterBracket normB
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
                            _ -> PredInvalidNotation (listToMaybe nums) l afterBracket normB
                          else case nums of
                            [c1]
                              | isActiveTag && c1 > 0 && not (T.null normB) ->
                                  let topics = parseTopicsFromBracket insideRaw afterBracket
                                      (clue, theory, rival) = splitPredictionComponents afterBracket
                                      canonL = canonicalizeActiveLine c1 topics afterBracket
                                   in PredValidActive c1 topics clue theory rival canonL afterBracket normB
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

bodiesRelated :: Text -> Text -> Bool
bodiesRelated b1 b2 =
  let p1 = T.take 20 b1
      p2 = T.take 20 b2
   in not (T.null p1) && not (T.null p2) && (p1 `T.isInfixOf` b2 || p2 `T.isInfixOf` b1)

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

renderAuditBlock :: FilePath -> FilePath -> Int -> Int -> Text -> Text -> Text
renderAuditBlock curMemPath prevMemPath origC curIdx beforeTxt afterTxt =
  let origStr = T.pack (padChunkNumber origC)
      _ = curIdx
      nextStr = T.pack (padChunkNumber (max 1 curIdx + 1))
   in T.intercalate
        "\n"
        [ "- **[READER SUB-AGENT REWROTE PREDICTION OR MOVED GOALPOSTS IN FILE " <> T.pack curMemPath <> "]**"
        , "  - *Before (in " <> T.pack prevMemPath <> ")*: " <> T.strip beforeTxt
        , "  - *After (in " <> T.pack curMemPath <> ")*: " <> T.strip afterTxt
        , "  - *Action Required*: Address this prediction rewrite or goalpost-shift openly in your next commentary! Do not rewrite existing active predictions in `=== PREDICTION UPDATES ===`: leave `[Predicted Chunk "
            <> origStr
            <> "]` unchanged for `prediction-judge` to evaluate, or if total unresolved predictions exceed the cap of 10, nominate it for conditional retirement using `- **[Predicted Chunk "
            <> origStr
            <> " -> RETIRED Chunk "
            <> nextStr
            <> "]** <reason>`."
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

isPredictionMentionedInComm :: Text -> Text -> Bool
isPredictionMentionedInComm commLower rawPredLine =
  let (_, afterOpen) = T.breakOn "[" rawPredLine
      (insideRaw, _) = T.breakOn "]" (T.drop 1 afterOpen)
      (insideBeforePipe, _) = T.breakOn "|" insideRaw
      (insideBeforeParen, _) = T.breakOn "(" insideBeforePipe
      tagNorm = T.toLower (T.strip insideBeforeParen)
   in not (T.null tagNorm) && tagNorm `T.isInfixOf` commLower

-- | Audits and applies `blind-reader`'s delta prediction updates from `=== PREDICTION UPDATES ===`:
-- 1. Adds the reader's 1 new prediction for `curIdx` (as `PredStatusActive`).
-- 2. Collects any conditional retirement suggestions (`ResRetired`) into `pendingRetires :: [(Int, Text)]`
--    WITHOUT retiring them yet (so `prediction-judge` evaluates all active predictions first!).
-- 3. Rejects any self-judged `CONFIRMED`/`DEBUNKED`/`SUBVERTED` tags from `blind-reader` (since
--    `prediction-judge` is solely responsible for judging active predictions).
auditAndApplyPredictionUpdates
  :: FilePath
  -> Int
  -> Int
  -> Int
  -> Text
  -> Bool
  -> Text
  -> [PredictionRecord]
  -> [Text]
  -> Maybe Text
  -> ([PredictionRecord], [(Int, Text)], [Text], [Text])
auditAndApplyPredictionUpdates sessionDir curIdx totalChunks chapNum chapTitle isRecordTurn commText prevRecords prevWarnings mPredUpdatesTxt =
  let _ = sessionDir
      curMemPath =
        if curIdx > 0
          then "archive" </> "memory" </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")
          else "memory.md"
      prevMemPath =
        if curIdx > 1
          then "archive" </> "memory" </> ("chunk_" ++ padChunkNumber (curIdx - 1) ++ ".md")
          else "memory.md"
      curStr = T.pack (padChunkNumber (max 1 curIdx))
      nextStr = T.pack (padChunkNumber (max 1 curIdx + 1))
      prevActives = [pr | pr <- prevRecords, prStatus pr == PredStatusActive]
      prevActiveChunksSummary =
        case map (T.pack . padChunkNumber . prOriginChunk) prevActives of
          [] -> "none currently active in `memory.md`"
          cs -> T.intercalate ", " ["`[Predicted Chunk " <> c <> "]`" | c <- cs]
      sampleOrigStr mGuessed =
        case mGuessed of
          Just g | any (\p -> prOriginChunk p == g) prevActives -> T.pack (padChunkNumber g)
          _ ->
            case prevActives of
              (p : _) -> T.pack (padChunkNumber (prOriginChunk p))
              [] ->
                case mGuessed of
                  Just g -> T.pack (padChunkNumber g)
                  Nothing -> curStr
      hadTagAuditPreviously =
        any ("invalid prediction tag or format in file" `T.isInfixOf`) (map T.toLower prevWarnings)

      parseIncomingBullets mBody =
        case mBody of
          Nothing -> []
          Just b ->
            [ parsePredictionLine trimmed
            | rawL <- T.lines b
            , let trimmed = T.strip rawL
            , not (isPlaceholderLine trimmed)
            , not (isAuditHeaderLine trimmed)
            , not (isIndentedAuditSubLine rawL)
            , "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
            ]

      explicitBullets = parseIncomingBullets mPredUpdatesTxt
      isNothing Nothing = True
      isNothing (Just _) = False
      commPredBullets =
        [ p
        | isNothing mPredUpdatesTxt
        , rawL <- T.lines commText
        , let trimmed = T.strip rawL
        , not (isPlaceholderLine trimmed)
        , not (isAuditHeaderLine trimmed)
        , not (isIndentedAuditSubLine rawL)
        , "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
        , "[" `T.isInfixOf` trimmed && "]" `T.isInfixOf` trimmed
        , p <- [parsePredictionLine trimmed]
        , case p of
            PredValidActive {} -> True
            PredValidResolved _ _ ResRetired _ _ _ -> True
            _ -> False
        ]

      allBullets = explicitBullets ++ commPredBullets

      activeBullets = [p | p@(PredValidActive {}) <- allBullets]
      resolvedBullets = [p | p@(PredValidResolved {}) <- allBullets]
      invalidBullets = [p | p@(PredInvalidNotation {}) <- allBullets]

      selfJudgedBullets =
        [ r
        | r@(PredValidResolved _ _ rKind _ _ _) <- resolvedBullets
        , rKind /= ResRetired
        ]
      retireBullets =
        [ r
        | r@(PredValidResolved _ _ ResRetired _ _ _) <- resolvedBullets
        ]

      selfJudgedAuditBlocks =
        [ renderTagFormatAuditBlock
            curMemPath
            prevMemPath
            "Self-judging predictions (`CONFIRMED`, `DEBUNKED`, `SUBVERTED`) is handled exclusively by the `prediction-judge` sub-agent; `blind-reader` must not emit resolution verdicts in `=== PREDICTION UPDATES ===`."
            (ppRawLine r)
            ( "Remove `CONFIRMED` / `DEBUNKED` / `SUBVERTED` lines from `=== PREDICTION UPDATES ===`. Only output your 1 new prediction (`- **[Predicted Chunk "
                <> nextStr
                <> " | Topics: Tag1, Tag2]** ...`) and, when at the 10-prediction cap, your conditional retirement suggestion (`- **[Predicted Chunk XXXX -> RETIRED Chunk "
                <> nextStr
                <> "]** <reason>`)."
            )
        | r <- selfJudgedBullets
        ]

      classifyActiveBullet :: ParsedPrediction -> Either (Int, ParsedPrediction) (Maybe Text)
      classifyActiveBullet p@(PredValidActive c1 _ _ _ _ canonL bodyAfter cNorm) =
        case [pr | pr <- prevRecords, prOriginChunk pr == c1] of
          (existingPr : _)
            | c1 == curIdx -> Left (c1, p)
            | cNorm == prNormBody existingPr || bodiesRelated cNorm (prNormBody existingPr) ->
                Right Nothing
            | otherwise ->
                Right
                  ( Just
                      ( renderAuditBlock
                          curMemPath
                          prevMemPath
                          c1
                          curIdx
                          (renderRecordActiveLine existingPr)
                          canonL
                      )
                  )
          [] ->
            if c1 == curIdx || (hadTagAuditPreviously && c1 == curIdx - 1 && c1 > 0) || (curIdx == 0 && c1 == 1)
              then Left (c1, p)
              else
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
                              curMemPath
                              prevMemPath
                              issueDetail
                              canonL
                              ( "Fix the bracket tag in `=== PREDICTION UPDATES ===`! Use `- **[Predicted Chunk "
                                  <> nextStr
                                  <> " | Topics: Tag1, Tag2]** "
                                  <> trimmedBody
                                  <> "` (when submitting Chunk "
                                  <> nextStr
                                  <> ") or `- **[Predicted Chunk "
                                  <> curStr
                                  <> " | Topics: Tag1, Tag2]** "
                                  <> trimmedBody
                                  <> "` (if updating Chunk "
                                  <> curStr
                                  <> ")."
                              )
                          )
                      )
      classifyActiveBullet _ = Right Nothing

      classifyInvalidBullet :: ParsedPrediction -> Text
      classifyInvalidBullet (PredInvalidNotation mGuessed rawInv bodyAfter cNorm) =
        let mMatchedExisting =
              case mGuessed of
                Just g -> listToMaybe [pr | pr <- prevActives, prOriginChunk pr == g]
                Nothing -> listToMaybe [pr | pr <- prevActives, bodiesRelated (prNormBody pr) cNorm]
         in case mMatchedExisting of
              Just existingPr ->
                renderAuditBlock
                  curMemPath
                  prevMemPath
                  (prOriginChunk existingPr)
                  curIdx
                  (renderRecordActiveLine existingPr)
                  rawInv
              Nothing ->
                let origEx = sampleOrigStr mGuessed
                    trimmedBody =
                      if T.null (T.strip bodyAfter)
                        then "**Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)"
                        else T.strip bodyAfter
                 in renderTagFormatAuditBlock
                      curMemPath
                      prevMemPath
                      ("Malformed or unsupported prediction bracket tag in `=== PREDICTION UPDATES ===` (currently active tags: " <> prevActiveChunksSummary <> ").")
                      rawInv
                      ( "Fix or remove this line in `=== PREDICTION UPDATES ===`! To log your new prediction, use `- **[Predicted Chunk "
                          <> nextStr
                          <> " | Topics: Tag1, Tag2]** "
                          <> trimmedBody
                          <> "` (on Chunk "
                          <> nextStr
                          <> "). Or when at the 10-prediction cap, suggest a conditional retirement using `- **[Predicted Chunk "
                          <> origEx
                          <> " -> RETIRED Chunk "
                          <> nextStr
                          <> "]** <reason>`."
                      )
      classifyInvalidBullet p =
        renderTagFormatAuditBlock
          curMemPath
          prevMemPath
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
                    curMemPath
                    prevMemPath
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
      toPredictionRecord (PredValidActive c1 topics clue theory rival _ bodyAfter normB) =
        PredictionRecord
          { prOriginChunk = c1
          , prChapterNumber = chapNum
          , prChapterTitle = chapTitle
          , prTopics = topics
          , prClue = clue
          , prTheory = theory
          , prRival = rival
          , prRawBody = bodyAfter
          , prNormBody = normB
          , prStatus = PredStatusActive
          , prResolutionNote = Nothing
          }
      toPredictionRecord _ =
        error "toPredictionRecord: expected PredValidActive"

      newActiveRecords = map toPredictionRecord validNewActiveParsed
      newActiveOriginChunks = map prOriginChunk newActiveRecords

      recordsWithNew =
        [ pr
        | pr <- prevRecords
        , prOriginChunk pr `notElem` newActiveOriginChunks
        ]
          ++ newActiveRecords

      -- Support same-chunk retirement where the reader wrote only `- **[Predicted Chunk NNNN -> RETIRED Chunk NNNN]** <body>`
      -- We add it as an ACTIVE prediction first so `prediction-judge` still evaluates it on the merits!
      sameChunkRetireSynthesized =
        [ let (clue, theory, rival) = splitPredictionComponents (ppBodyAfterBracket r)
              topics = extractFallbackTopics (ppBodyAfterBracket r)
           in PredictionRecord
                { prOriginChunk = curIdx
                , prChapterNumber = chapNum
                , prChapterTitle = chapTitle
                , prTopics = topics
                , prClue = clue
                , prTheory = theory
                , prRival = rival
                , prRawBody = ppBodyAfterBracket r
                , prNormBody = ppNormBody r
                , prStatus = PredStatusActive
                , prResolutionNote = Nothing
                }
        | r@(PredValidResolved (Just origC) resC ResRetired _ _ _) <- retireBullets
        , origC == curIdx && resC == curIdx
        , curIdx `notElem` map prOriginChunk recordsWithNew
        ]

      candidateRecords =
        sortOn prOriginChunk (recordsWithNew ++ sameChunkRetireSynthesized)

      findMatchingRetireTarget :: ParsedPrediction -> Maybe PredictionRecord
      findMatchingRetireTarget (PredValidResolved (Just origC) _ _ _ _ rNorm) =
        case [pr | pr <- candidateRecords, prOriginChunk pr == origC] of
          (p : _) -> Just p
          [] -> listToMaybe [pr | pr <- candidateRecords, bodiesRelated (prNormBody pr) rNorm]
      findMatchingRetireTarget (PredValidResolved Nothing _ _ _ _ rNorm) =
        listToMaybe [pr | pr <- candidateRecords, bodiesRelated (prNormBody pr) rNorm]
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
        [ let origEx = sampleOrigStr (ppResOrigChunk r)
              msg =
                case ppResOrigChunk r of
                  Just origC ->
                    "Conditional retirement tag references `[Predicted Chunk "
                      <> T.pack (padChunkNumber origC)
                      <> "]`, which does not match any active prediction in `memory.md` (currently active tags: "
                      <> prevActiveChunksSummary
                      <> ")."
                  Nothing ->
                    "Conditional retirement tag is missing its origin chunk number and did not match any active prediction (currently active tags: "
                      <> prevActiveChunksSummary
                      <> ")."
              act =
                "Only nominate predictions that exist in `memory.md` ("
                  <> prevActiveChunksSummary
                  <> ") using `- **[Predicted Chunk "
                  <> origEx
                  <> " -> RETIRED Chunk "
                  <> curStr
                  <> "]** <reason>`."
           in renderTagFormatAuditBlock curMemPath prevMemPath msg (ppRawLine r) act
        | r <- unmatchedRetires
        ]

      activePoolBeforeJudge = [pr | pr <- candidateRecords, prStatus pr == PredStatusActive]
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
              origLine = renderRecordActiveLine targetPr
           in renderTagFormatAuditBlock
                curMemPath
                prevMemPath
                ("Prediction `[Predicted Chunk " <> origStr <> "]` was nominated for `RETIRED` when total unresolved predictions (" <> jsonInt totalUnresolvedBeforeJudge <> "/10) did not exceed the cap of 10.")
                (ppRawLine r)
                ( "Only nominate predictions for conditional retirement (`RETIRED`) when total unresolved predictions (including your new prediction) exceed 10. It remains active in `memory.md` (`"
                    <> origLine
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
                curMemPath
                prevMemPath
                ("No new prediction was logged for Chunk " <> curStr <> " (every chunk before the final chunk must log 1 new non-softball, multi-chapter prediction, capped at 10 unresolved predictions).")
                ("*(Missing `- **[Predicted Chunk " <> curStr <> " | Topics: Tag1, Tag2]** **Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)` in `=== PREDICTION UPDATES ===`)*")
                ( "On Chunk "
                    <> nextStr
                    <> ", make sure to log 1 new non-softball, multi-chapter prediction using `- **[Predicted Chunk "
                    <> nextStr
                    <> " | Topics: Tag1, Tag2]** **Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)` in both `=== COMMENTARY ===` and `=== PREDICTION UPDATES ===`."
                )
            ]
        | otherwise = []

      allAuditBlocks =
        activeAuditBlocks
          ++ invalidAuditBlocks
          ++ duplicateChunkAuditBlocks
          ++ selfJudgedAuditBlocks
          ++ unmatchedRetireAuditBlocks
          ++ prematureRetireAuditBlocks
          ++ missingNewPredAuditBlocks

      commLower = T.toLower commText
      turnEvents =
        map renderRecordActiveLine (newActiveRecords ++ sameChunkRetireSynthesized)
      trackerUpdateLines =
        [ evLine
        | evLine <- turnEvents
        , not (isPredictionMentionedInComm commLower evLine)
        ]
   in (candidateRecords, pendingRetirePairs, allAuditBlocks, trackerUpdateLines)

extractJudgeSection :: Text -> Text
extractJudgeSection raw =
  let isJudgeHeader l =
        let s = T.toUpper (T.strip l)
         in s == "=== PREDICTION JUDGMENTS ==="
              || s == "=== PREDICTION JUDGEMENTS ==="
              || s == "=== JUDGMENTS ==="
              || s == "=== JUDGEMENTS ==="
              || s == "=== PREDICTION UPDATES ==="
      ls = T.lines raw
      afterHeader = drop 1 (dropWhile (not . isJudgeHeader) ls)
      untilNextSec = takeWhile (\l -> not ("===" `T.isPrefixOf` T.strip l)) afterHeader
   in if null afterHeader
        then T.strip raw
        else T.strip (T.unlines untilNextSec)

-- | Applies `prediction-judge`'s verdicts to all active predictions (and any recently resolved
-- predictions from the last 2 chunks for cliffhanger fake-out reversals), then conditionally
-- applies `blind-reader`'s `pendingRetires` ONLY if more than 10 predictions remain `ACTIVE`.
applyJudgeVerdicts
  :: Int
  -> [PredictionRecord]
  -> [(Int, Text)]
  -> Text
  -> ([PredictionRecord], [Text], [Text])
applyJudgeVerdicts curIdx prevRecords pendingRetires rawJudgeTxt =
  let curMemPath =
        if curIdx > 0
          then "archive" </> "memory" </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")
          else "memory.md"
      prevMemPath =
        if curIdx > 1
          then "archive" </> "memory" </> ("chunk_" ++ padChunkNumber (curIdx - 1) ++ ".md")
          else "memory.md"
      nextStr = T.pack (padChunkNumber (max 1 curIdx + 1))
      judgeBody = extractJudgeSection rawJudgeTxt
      parsedLines =
        [ parsePredictionLine trimmed
        | rawL <- T.lines judgeBody
        , let trimmed = T.strip rawL
        , not (isPlaceholderLine trimmed)
        , not (isAuditHeaderLine trimmed)
        , "- " `T.isPrefixOf` trimmed || "* " `T.isPrefixOf` trimmed
        , "[" `T.isInfixOf` trimmed && "]" `T.isInfixOf` trimmed
        ]
      resolvedVerdicts =
        [ r
        | r@(PredValidResolved _ _ rKind _ _ _) <- parsedLines
        , rKind `elem` [ResConfirmed, ResDebunked, ResSubverted]
        ]
      keepActiveVerdicts =
        [ k
        | k@(PredValidKeepActive {}) <- parsedLines
        ]

      findJudgeTarget :: ParsedPrediction -> Maybe PredictionRecord
      findJudgeTarget (PredValidResolved (Just origC) _ _ _ _ rNorm) =
        case [pr | pr <- prevRecords, prOriginChunk pr == origC] of
          (p : _) -> Just p
          [] -> listToMaybe [pr | pr <- prevRecords, bodiesRelated (prNormBody pr) rNorm]
      findJudgeTarget (PredValidResolved Nothing _ _ _ _ rNorm) =
        listToMaybe [pr | pr <- prevRecords, bodiesRelated (prNormBody pr) rNorm]
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

      -- Step 2: Conditionally apply blind-reader's retirement suggestion(s) ONLY if >10 remain ACTIVE
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
                    curMemPath
                    prevMemPath
                    ("Active prediction slate has " <> jsonInt finalActiveCount <> " unresolved predictions after `prediction-judge` rulings, exceeding the maximum cap of 10.")
                    ("*(Active pool has " <> jsonInt finalActiveCount <> "/10 unresolved predictions — " <> jsonInt excess <> " over the cap of 10)*")
                    ( "On your next turn (Chunk "
                        <> nextStr
                        <> "), in addition to nominating 1 conditional retirement for Chunk "
                        <> nextStr
                        <> "'s new prediction, nominate "
                        <> jsonInt excess
                        <> " extra prediction(s) (choosing those most likely to never be resolved or most likely to be debunked in future installments) in `=== PREDICTION UPDATES ===` using `- **[Predicted Chunk XXXX -> RETIRED Chunk "
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
        [ "- **[Predicted Chunk "
            <> T.pack (padChunkNumber (prOriginChunk pr))
            <> " -> ACTIVE]** Newly logged prediction remains active ("
            <> T.intercalate ", " (prTopics pr)
            <> ")."
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

mergeCuratedNarrativeMemory :: [(Text, Text)] -> Maybe Text -> ([(Text, Text)], Maybe Text)
mergeCuratedNarrativeMemory prevSections Nothing =
  (if null prevSections then defaultCuratedMemory else prevSections, Nothing)
mergeCuratedNarrativeMemory prevSections (Just memTxt) =
  let incoming = parseMemorySections memTxt
      baseSections =
        [ (secName, oldBody)
        | (secName, oldBody) <- if null prevSections then defaultCuratedMemory else prevSections
        , secName `elem` map fst defaultCuratedMemory
        ]
      mergedSections =
        [ (secName, mergedBody)
        | (secName, oldBody) <- baseSections
        , let mergedBody =
                case Map.lookup secName incoming of
                  Nothing -> oldBody
                  Just newBody
                    | isPlaceholderSection newBody && not (isPlaceholderSection oldBody) -> oldBody
                    | otherwise -> newBody
        ]
      mFallbackPreds = Map.lookup "_FallbackPredictions_" incoming
   in (mergedSections, mFallbackPreds)

resolveAndAuditTurn
  :: FilePath
  -> Int
  -> Int
  -> Int
  -> Text
  -> Bool
  -> Text
  -> [(Text, Text)]
  -> [PredictionRecord]
  -> [Text]
  -> Maybe Text
  -> Maybe Text
  -> IO ([(Text, Text)], [PredictionRecord], [(Int, Text)], [Text], [Text])
resolveAndAuditTurn sessionDir curIdx totalChunks chapNum chapTitle isRecordTurn commText prevSections prevPreds prevWarns mPredUpdates mMemTxt = do
  mEffectiveMem <-
    case mMemTxt of
      Just m -> pure (Just m)
      Nothing -> do
        let memPath = sessionDir </> "memory.md"
        exists <- doesFileExist memPath
        if not exists
          then pure Nothing
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
            pure (if hasDiskDiff then Just diskTxt else Nothing)
  let (curated', mFallbackPreds) = mergeCuratedNarrativeMemory prevSections mEffectiveMem
      effectivePredUpdates =
        case mPredUpdates of
          Just pu -> Just pu
          Nothing -> mFallbackPreds
      (preds', pendingRetires, auditBlocks, trackerUpdates) =
        if isRecordTurn || isJust effectivePredUpdates
          then
            auditAndApplyPredictionUpdates
              sessionDir
              curIdx
              totalChunks
              chapNum
              chapTitle
              isRecordTurn
              commText
              prevPreds
              prevWarns
              effectivePredUpdates
          else (prevPreds, [], prevWarns, [])
  pure (curated', preds', pendingRetires, auditBlocks, trackerUpdates)

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

renderChunkIndexLine :: ChunkIndexEntry -> Text
renderChunkIndexLine e =
  let padStr = padChunkNumber (cieChunkIndex e)
      idxStr = T.pack padStr
      chapStr = formatChapLabel (cieChapterNumber e) (cieChapterTitle e)
      partStr = "Part " <> jsonInt (ciePartInChapter e) <> "/" <> jsonInt (ciePartsInChapter e)
      storyPath = T.pack ("chunks" </> ("chunk_" ++ padStr ++ ".md"))
      entryPath = T.pack ("entries" </> ("chunk_" ++ padStr ++ ".md"))
      memPath = T.pack ("archive" </> "memory" </> ("chunk_" ++ padStr ++ ".md"))
   in "- **chunk_"
        <> idxStr
        <> "** ("
        <> chapStr
        <> ", "
        <> partStr
        <> "): "
        <> cieSummary e
        <> " ([story]("
        <> storyPath
        <> ") | [entry]("
        <> entryPath
        <> ") | [memory]("
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
          <> T.unlines (map renderChunkIndexLine grp)
      curatedSnapPath = sessionDir </> "archive" </> "memory" </> ("curated_" ++ padChunkNumber endChk ++ ".md")
  hasSnap <- doesFileExist curatedSnapPath
  snapContent <- if hasSnap then readTextFileSafe curatedSnapPath else pure ""
  let fileName = "L1_" ++ padChunkNumber grpIdx ++ ".md"
      relPath = "archive" </> fileName
      fullPath = sessionDir </> relPath
      archiveDoc =
        T.unlines
          [ "# " <> label
          , ""
          , "*Session Directory*: `" <> T.pack sessionDir <> "`"
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
  pure (relPath, label, summaryLine)

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
            relPath = "archive" </> fileName
            fullPath = sessionDir </> relPath
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
                  , "*Session Directory*: `" <> T.pack sessionDir <> "`"
                  , ""
                  , "Read the linked archive files below to inspect chapter/chunk indices and historical memory snapshots:"
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
      rollupArchiveLevels sessionDir (level + 1) parents

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
   in "- **[pred_"
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

writePredArcArchive :: FilePath -> Int -> [ChunkIndexEntry] -> [PredictionRecord] -> IO (FilePath, Text, Text)
writePredArcArchive sessionDir grpIdx arcEntries allPreds = do
  let (startChk, startChap) =
        case arcEntries of
          (firstE : _) -> (cieChunkIndex firstE, cieChapterNumber firstE)
          [] -> (1, 1)
      (endChk, endChap) =
        case reverse arcEntries of
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
      label = "Arc " <> jsonInt grpIdx <> " Predictions (" <> chapRange <> " | " <> chunkRange <> ")"
      arcPreds =
        [ pr
        | pr <- allPreds
        , prOriginChunk pr >= startChk && prOriginChunk pr <= endChk
        ]
      activeCnt = length [pr | pr <- arcPreds, prStatus pr == PredStatusActive]
      confCnt = length [pr | pr <- arcPreds, case prStatus pr of PredStatusConfirmed {} -> True; _ -> False]
      debCnt = length [pr | pr <- arcPreds, case prStatus pr of PredStatusDebunked {} -> True; _ -> False]
      subCnt = length [pr | pr <- arcPreds, case prStatus pr of PredStatusSubverted {} -> True; _ -> False]
      retCnt = length [pr | pr <- arcPreds, case prStatus pr of PredStatusRetired {} -> True; _ -> False]
      summaryLine =
        jsonInt (length arcPreds)
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
      byChap = groupBy (\a b -> prChapterNumber a == prChapterNumber b) arcPreds
      renderChapGrp [] = ""
      renderChapGrp grp@(firstP : _) =
        "### "
          <> formatChapLabel (prChapterNumber firstP) (prChapterTitle firstP)
          <> "\n"
          <> T.unlines (map renderPredSummaryBullet grp)
      predArchiveDir = sessionDir </> "predictions" </> "archive"
      fileName = "L1_" ++ padChunkNumber grpIdx ++ ".md"
      relPath = "predictions" </> "archive" </> fileName
      fullPath = predArchiveDir </> fileName
      doc =
        T.unlines
          [ "# " <> label
          , ""
          , "- **Session Directory**: `" <> T.pack sessionDir <> "`"
          , "- **Summary**: " <> summaryLine
          , ""
          , "## Predictions by Chapter"
          , ""
          , if null arcPreds
              then "- *(No predictions logged in this arc.)*"
              else T.intercalate "\n" (map renderChapGrp byChap)
          ]
  createDirectoryIfMissing True predArchiveDir
  TIO.writeFile fullPath doc
  pure (relPath, label, summaryLine)

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
         in renderRecordResolvedLine pr
              <> " ([pred_"
              <> T.pack origPad
              <> "]("
              <> predFile
              <> "))"
      renderUnresolvedBullet pr =
        let origPad = padChunkNumber (prOriginChunk pr)
            predFile = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
         in renderRecordActiveLine pr
              <> " ([pred_"
              <> T.pack origPad
              <> "]("
              <> predFile
              <> "))"
      sectionOrEmpty emptyMsg items renderFn =
        if null items
          then [emptyMsg]
          else map renderFn items
   in T.unlines $
        [ "# Prediction Hall of Fame & Shame: " <> stTitle st
        , ""
        , "*Session Directory*: `" <> T.pack sessionDir <> "`"
        , "*Generated automatically upon story completion from all "
            <> jsonInt totalLogged
            <> " recorded predictions.*"
        , ""
        , "## Final Prediction Scoreboard"
        , ""
        , "- **Total Predictions Logged**: " <> jsonInt totalLogged
        , "- **Major Confirmed Hits (>= 3 Chunks Foresight)**: **" <> jsonInt (length majorHits) <> "**"
        , "- **Subverted Twists (Right Clue, Surprise Twist)**: **" <> jsonInt (length subvertedList) <> "**"
        , "- **Debunked Misses (Glorious Corkboard Wipeouts)**: **" <> jsonInt (length debunkedList) <> "**"
        , "- **Short-Horizon Confirmations (< 3 Chunks — No Hit Credit)**: " <> jsonInt (length shortConfirmations)
        , "- **Retired for 10-Prediction Cap**: " <> jsonInt (length retiredList)
        , "- **Unresolved / Open-Ended at Finale**: " <> jsonInt (length unresolvedList)
        , "- **Multi-Chunk Hit Rate**: " <> accuracyNote
        , ""
        , "## Hall of Fame — Major Confirmed Hits (>= 3 Chunks Foresight)"
        , ""
        ]
          ++ sectionOrEmpty
            "- *(No major multi-chunk confirmed hits recorded.)*"
            majorHits
            renderDetailedBullet
          ++ [ ""
             , "## Best Twists — Subverted Predictions (Right Clue, Different Payoff)"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(No subverted predictions recorded.)*"
            subvertedList
            renderDetailedBullet
          ++ [ ""
             , "## Hall of Shame — Debunked Predictions & Glorious Misses"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(No debunked predictions recorded.)*"
            debunkedList
            renderDetailedBullet
          ++ [ ""
             , "## Short-Horizon Confirmations (< 3 Chunks — No Hit Credit)"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(None.)*"
            shortConfirmations
            renderDetailedBullet
          ++ [ ""
             , "## Unresolved / Open-Ended Predictions at Finale"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(None — all active predictions were resolved!)*"
            unresolvedList
            renderUnresolvedBullet
          ++ [ ""
             , "## Retired Predictions (Pruned Under the 10-Prediction Cap)"
             , ""
             ]
          ++ sectionOrEmpty
            "- *(None.)*"
            retiredList
            renderDetailedBullet

syncPredictionsDirectory :: FilePath -> SessionState -> IO ()
syncPredictionsDirectory sessionDir st = do
  let predDir = sessionDir </> "predictions"
      predArcDir = predDir </> "archive"
      preds = stPredictions st
  createDirectoryIfMissing True predDir
  createDirectoryIfMissing True predArcDir

  -- 1. Write individual prediction files: predictions/pred_XXXX.md
  forM_ preds $ \pr -> do
    let fName = "pred_" ++ padChunkNumber (prOriginChunk pr) ++ ".md"
    TIO.writeFile (predDir </> fName) (renderSinglePredictionDoc sessionDir pr)

  -- 2. Write chronological index: predictions/by_chronology.md (+ predictions/archive/L1_XXXX.md for completed arcs)
  let arcs = groupChunksIntoArcs (stChunkIndex st)
  arcNodes <-
    if length arcs <= 1
      then pure []
      else
        forM (zip [1 :: Int ..] (init arcs)) $ \(grpIdx, arcEntries) ->
          writePredArcArchive sessionDir grpIdx arcEntries preds

  let inlineStartChunk =
        case reverse arcs of
          [] -> 1
          [ _ ] -> 1
          (lastArc : _) ->
            case lastArc of
              (firstE : _) -> cieChunkIndex firstE
              [] -> 1
      inlinePreds =
        if length arcs <= 1
          then preds
          else [pr | pr <- preds, prOriginChunk pr >= inlineStartChunk]
      byChap = groupBy (\a b -> prChapterNumber a == prChapterNumber b) inlinePreds
      renderChapGroup [] = ""
      renderChapGroup grp@(firstP : _) =
        "### "
          <> formatChapLabel (prChapterNumber firstP) (prChapterTitle firstP)
          <> "\n"
          <> T.unlines (map renderPredSummaryBullet grp)
      arcLinksSection =
        if null arcNodes
          then
            [ "- *(All predictions so far are listed inline below. Completed arc prediction archives will appear here as the story progresses.)*"
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
            | (fp, lbl, summ) <- arcNodes
            ]
      chronologyDoc =
        T.unlines $
          [ "# Predictions Index by Story Chronology: " <> stTitle st
          , ""
          , "*Session Directory*: `" <> T.pack sessionDir <> "`"
          , ""
          , "Use this index to browse predictions in chronological order by Arc, Chapter, and Chunk."
          , ""
          , "## Completed Arc Prediction Archives"
          , ""
          ]
            ++ arcLinksSection
            ++ [ ""
               , "## Current & Recent Arc Predictions"
               , ""
               , if null inlinePreds
                   then "- *(No predictions logged yet.)*"
                   else T.intercalate "\n" (map renderChapGroup byChap)
               ]
  TIO.writeFile (predDir </> "by_chronology.md") chronologyDoc

  -- 3. Write semantic content index: predictions/by_topic.md
  let topicPairs :: [(Text, (Text, PredictionRecord))]
      topicPairs =
        [ (T.toLower tag, (tag, pr))
        | pr <- preds
        , let tags = if null (prTopics pr) then ["General Plot"] else prTopics pr
        , tag <- tags
        ]
      topicMap :: Map.Map Text (Text, [PredictionRecord])
      topicMap =
        foldl'
          ( \acc (k, (dispTag, pr)) ->
              case Map.lookup k acc of
                Nothing -> Map.insert k (dispTag, [pr]) acc
                Just (existingDisp, existingPrs) ->
                  let prs' =
                        if any (\x -> prOriginChunk x == prOriginChunk pr) existingPrs
                          then existingPrs
                          else existingPrs ++ [pr]
                   in Map.insert k (existingDisp, prs') acc
          )
          Map.empty
          topicPairs
      sortedTopics = Map.elems topicMap
      tocLines =
        if null sortedTopics
          then ["- *(No topics indexed yet.)*"]
          else
            [ "- **" <> dispTag <> "** (" <> jsonInt (length prs) <> ")"
            | (dispTag, prs) <- sortedTopics
            ]
      topicSections =
        if null sortedTopics
          then ["*(No predictions logged yet.)*"]
          else
            [ "### "
                <> dispTag
                <> " ("
                <> jsonInt (length prs)
                <> ")\n"
                <> T.unlines (map renderPredSummaryBullet (sortOn prOriginChunk prs))
            | (dispTag, prs) <- sortedTopics
            ]
      byTopicDoc =
        T.unlines $
          [ "# Predictions Index by Semantic Topic & Entity: " <> stTitle st
          , ""
          , "*Session Directory*: `" <> T.pack sessionDir <> "`"
          , ""
          , "Use this inverted index to look up all active and resolved predictions associated with a character, faction, artifact, location, or mystery theme."
          , ""
          , "## Indexed Topics (" <> jsonInt (length sortedTopics) <> ")"
          , ""
          ]
            ++ tocLines
            ++ [ ""
               , "## Predictions by Topic"
               , ""
               , T.intercalate "\n" topicSections
               ]
  TIO.writeFile (predDir </> "by_topic.md") byTopicDoc

  -- 4. Write end-of-story Hall of Fame & Shame ONLY when all chunks have been recorded and judged
  let isFinished = stCurrentIndex st >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
  when isFinished $ do
    let hofPath = predDir </> "hall_of_fame.md"
    TIO.writeFile hofPath (renderHallOfFameMarkdown sessionDir st)

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
          then " | [End-of-Story Hall of Fame & Shame](" <> T.pack ("predictions" </> "hall_of_fame.md") <> ")"
          else ""
      scoreboardLine =
        "- **Running Tally**: "
          <> jsonInt (length preds)
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
      indexLinksLine =
        "- **Prediction Indices (On-Demand `read_file`)**: [Chronological Index]("
          <> chronPath
          <> ") | [Semantic Topic Index]("
          <> topicPath
          <> ") | [Prediction Files (`pred_XXXX.md`)](predictions/)"
          <> hofLinkSuffix
      lastJudgeLines =
        if null (stLastJudgeSummary st)
          then []
          else
            [ ""
            , "### Latest Prediction Judge Rulings (React to Any Confirmed / Debunked / Subverted Verdicts in Your Commentary!)"
            ]
              ++ stLastJudgeSummary st
      recentResLines =
        if null recentResolved
          then []
          else
            [ ""
            , "### Recently Resolved (Last 2 Chunks)"
            ]
              ++ [ let origPad = padChunkNumber (prOriginChunk pr)
                       pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
                    in renderRecordResolvedLine pr <> " ([details](" <> pPath <> "))"
                 | pr <- recentResolved
                 ]
      activeLines =
        if null activePreds
          then
            [ "- *(No active predictions yet. On every chunk before the final chunk, output 1 new non-softball, multi-chapter prediction in `=== PREDICTION UPDATES ===` using `- **[Predicted Chunk XXXX | Topics: Tag1, Tag2, Tag3]** **Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)`.)*"
            ]
          else
            [ let origPad = padChunkNumber (prOriginChunk pr)
                  pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
               in renderRecordActiveLine pr <> " ([details](" <> pPath <> "))"
            | pr <- activePreds
            ]
      warningLines = stPredictionAuditWarnings st
   in T.unlines $
        [ "## Active Prediction Slate & Index (Auto-Maintained by Gatekeeper & Prediction Judge)"
        , "*(Do not re-emit this section in `=== UPDATED MEMORY ===`; submit only this turn's new prediction and any conditional `RETIRED` nomination in `=== PREDICTION UPDATES ===`. The `prediction-judge` subagent evaluates all active predictions after your turn.)*"
        , ""
        , scoreboardLine
        , indexLinksLine
        ]
          ++ lastJudgeLines
          ++ recentResLines
          ++ [ ""
             , "### Currently Active Unresolved Predictions (" <> jsonInt (length activePreds) <> "/10)"
             ]
          ++ activeLines
          ++ warningLines

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
            , "> **MEMORY COMPACTION NEEDED**: Your 4 curated narrative memory sections (`Story Summary So Far`, `Characters & Relationships`, `Active Mysteries & Unanswered Questions`, `Notable Quotes, Themes & Running Jokes`) are currently "
                <> jsonInt curLines
                <> " lines ("
                <> jsonInt curBytes
                <> " bytes), exceeding the 80-line / 5,000-byte target. On your next turn, condense older chapters in `## Story Summary So Far` into high-level multi-chapter arc bullets and prune minor resolved mysteries. All earlier chunk summaries, full historical memory snapshots, and predictions are permanently preserved in `<session_dir>/archive/` and `<session_dir>/predictions/`, so condensing `memory.md` will not lose any history."
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
                <> "]("
                <> T.pack fp
                <> ") — "
                <> summ
            | (fp, lbl, summ) <- topArchiveNodes
            ]
      inlineChunkLines
        | null inlineChunks = ["- *(No chunks read yet.)*"]
        | otherwise = map renderChunkIndexLine inlineChunks
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
      predictionSlateSection = renderPredictionSlateSection st
   in T.unlines $
        [ "# Reader Memory & Notes: " <> stTitle st
        , ""
        , "*Session Directory*: `" <> T.pack sessionDir <> "`"
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
             , T.strip predictionSlateSection
             , ""
             , "## Notable Quotes, Themes & Running Jokes"
             , T.strip (lookupSec "Notable Quotes, Themes & Running Jokes")
             ]

syncMemoryAndArchives :: FilePath -> SessionState -> IO (Bool, Int, Int)
syncMemoryAndArchives sessionDir st = do
  let archiveDir = sessionDir </> "archive"
      memSnapDir = archiveDir </> "memory"
  createDirectoryIfMissing True memSnapDir
  syncPredictionsDirectory sessionDir st

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

countActivePredictions :: [PredictionRecord] -> Int
countActivePredictions preds =
  length [pr | pr <- preds, prStatus pr == PredStatusActive]

renderPredictionSlateNote :: Int -> Int -> Int -> Text
renderPredictionSlateNote curIdx totalChunks activeCount
  | curIdx >= totalChunks =
      "*Prediction Slate*: Final chunk ("
        <> jsonInt activeCount
        <> "/10 active unresolved predictions in `memory.md`). React in `=== COMMENTARY ===` to any `prediction-judge` rulings from the previous chunk (`### Latest Prediction Judge Rulings` in `memory.md`). No new prediction is required on the final chunk (`prediction-judge` will evaluate all remaining active predictions against the finale; output `- None (story complete!).` in `=== PREDICTION UPDATES ===`)."
  | activeCount < 10 =
      let curPad = T.pack (padChunkNumber curIdx)
       in "*Prediction Slate*: "
            <> jsonInt activeCount
            <> "/10 active unresolved predictions in `memory.md`. React in `=== COMMENTARY ===` to any `prediction-judge` rulings from the previous chunk, and log 1 new non-softball, multi-chapter prediction on this chunk using `- **[Predicted Chunk "
            <> curPad
            <> " | Topics: Tag1, Tag2, Tag3]** **Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)` in both `=== COMMENTARY ===` and `=== PREDICTION UPDATES ===` (`prediction-judge` will evaluate all active predictions after your turn; do NOT emit `CONFIRMED`/`DEBUNKED`/`SUBVERTED` tags)."
  | otherwise =
      let curPad = T.pack (padChunkNumber curIdx)
          needRetire = activeCount + 1 - 10
       in "*Prediction Slate*: "
            <> jsonInt activeCount
            <> "/10 active unresolved predictions in `memory.md` (AT 10-PREDICTION CAP). React in `=== COMMENTARY ===` to any `prediction-judge` rulings from the previous chunk, log 1 new non-softball, multi-chapter prediction using `- **[Predicted Chunk "
            <> curPad
            <> " | Topics: Tag1, Tag2, Tag3]** **Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)`, AND nominate "
            <> jsonInt needRetire
            <> " conditional retirement candidate(s) (choosing from all unresolved predictions, including your new one, the prediction(s) most likely to never be resolved or most likely to be debunked in future installments) in `=== PREDICTION UPDATES ===` using `- **[Predicted Chunk XXXX -> RETIRED Chunk "
            <> curPad
            <> "]** <reason>`. The `prediction-judge` subagent will evaluate all active predictions (including your retirement candidate) first; your retirement nomination will ONLY take effect if more than 10 active predictions remain after `prediction-judge` renders its verdicts."

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

data ResponseSection
  = SecUserQuestion
  | SecCommentary
  | SecChunkSummary
  | SecPredictionUpdates
  | SecUpdatedMemory
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

parseCombinedResponse :: Text -> (Maybe Text, Text, Maybe Text, Maybe Text, Maybe Text)
parseCombinedResponse raw =
  let classifyLine l =
        let s = T.toUpper (T.strip l)
         in if s == "=== USER ===" || s == "=== QUESTION ===" || s == "=== USER MESSAGE ==="
              then Just SecUserQuestion
              else if s == "=== COMMENTARY ===" || s == "=== REPLY ===" || s == "=== RESPONSE ==="
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
      tagged = go SecCommentary (T.lines raw)
      extract sec = T.strip (T.unlines [l | (s, l) <- tagged, s == sec])
      userPart = extract SecUserQuestion
      commPart = extract SecCommentary
      sumPart = extract SecChunkSummary
      predPart = extract SecPredictionUpdates
      memPart = extract SecUpdatedMemory
   in ( if T.null userPart then Nothing else Just userPart
      , commPart
      , if T.null sumPart then Nothing else Just (cleanChunkSummary sumPart)
      , if T.null predPart then Nothing else Just predPart
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
      predictionsDir = sessionDir </> "predictions"
  createDirectoryIfMissing True entriesDir
  createDirectoryIfMissing True chunksDir
  createDirectoryIfMissing True (archiveDir </> "memory")
  createDirectoryIfMissing True (predictionsDir </> "archive")

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
          , stCurrentJudged = True
          , stCurrentMeta = Nothing
          , stCompletedChunks = []
          , stChunkIndex = []
          , stCuratedMemory = defaultCuratedMemory
          , stPredictions = []
          , stPendingRetirements = []
          , stPendingLinterWarnings = []
          , stLastJudgeSummary = []
          , stPredictionAuditWarnings = []
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
      , ("predictions_dir", jsonStr (T.pack predictionsDir))
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
  let criticFeedbackPath = absSession </> "critic_feedback.md"
  hasCriticFeedback <- doesFileExist criticFeedbackPath
  let curIdx = chunkIndex chunk
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      slatePromptLine = renderPredictionSlateNote curIdx totalChunks activeCount
      criticContextLines =
        if hasCriticFeedback
          then
            [ "- Peer Critic & Fact-Check Notes from Chunk "
                <> jsonInt (max 1 (curIdx - 1))
                <> " (MANDATORY READ — verify disputed facts against primary source; overrule if wrong; apply style coaching silently): "
                <> T.pack criticFeedbackPath
            ]
          else []
      prevContextLines =
        if curIdx <= 1
          then []
          else
            let prevPad = padChunkNumber (curIdx - 1)
                prevChunkPath = absSession </> "chunks" </> ("chunk_" ++ prevPad ++ ".md")
             in [ "- Previous Story Chunk (read ONLY if newly rotated or picking up mid-chapter): " <> T.pack prevChunkPath
                ]
      promptPath = sessionDir </> "current_prompt.md"
      promptText =
        T.unlines $
          [ "Please read the newly unlocked chunk (Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> ") and update your Let's Read commentary, prediction updates, and memory."
          , "- Current Chunk File (mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          ]
            ++ criticContextLines
            ++ prevContextLines
            ++ [ "- Commentary Guide Template (flexible reference): " <> T.pack absTemplate
               , "- Predictions Directory (chronological & semantic topic indices, on-demand read_file): " <> T.pack (absSession </> "predictions")
               , "- Multi-Level Memory & Index Archive (on-demand read_file): " <> T.pack (absSession </> "archive")
               , "- Unlocked Story Chunks Archive (on-demand read_file): " <> T.pack (absSession </> "chunks")
               , "- Previous Commentary Entries (on-demand read_file): " <> T.pack (absSession </> "entries")
               , "- Active Persona: " <> expandPersonaPreset (stPersona st)
               , "- " <> slatePromptLine
               , ""
               , "Key Reminders:"
               , "1. Read `current_chunk.md` and `memory.md` first (plus `critic_feedback.md` if listed above, and `chunks/chunk_(N-1).md` ONLY if you are a newly rotated subagent or picking up mid-chapter). Do NOT read `entries/chunk_(N-1).md` unless checking a specific thread callback."
               , "2. If `critic_feedback.md` is present: (a) Never blindly trust `commentary-critic` on factual/canon flags—verify every disputed claim against the cited `chunks/chunk_XXXX.md` quote, Bullet 1 of `## Story Summary So Far` (for AU divergences), or `search_web` before accepting; if verified, fix `=== UPDATED MEMORY ===` and include a natural 1-sentence in-character walkback in `=== COMMENTARY ===`, or overrule and ignore the flag if your original reading/joke was right. (b) Apply any `Persona & Style Coaching` notes silently—never apologize for or mention style feedback in `=== COMMENTARY ===`."
               , "3. Check `### Latest Prediction Judge Rulings` in `memory.md` and react in `=== COMMENTARY ===` to any `CONFIRMED`, `DEBUNKED`, or `SUBVERTED` verdicts from the previous chunk (owning `DEBUNKED`/`SUBVERTED` misses with good humor, and never taking a victory lap on a 1–2 chunk short-horizon call)."
               , "4. Prediction Quota & Conditional Retirement: Do NOT emit `CONFIRMED`, `DEBUNKED`, or `SUBVERTED` tags (`prediction-judge` evaluates all active predictions after your turn). On every chunk before the final chunk, log 1 new non-softball, multi-chapter prediction (`- **[Predicted Chunk " <> curPad <> " | Topics: Tag1, Tag2, Tag3]** **Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)`) in both `=== COMMENTARY ===` and `=== PREDICTION UPDATES ===`. If `memory.md` already has 10/10 active predictions, also nominate 1 conditional retirement candidate (`- **[Predicted Chunk XXXX -> RETIRED Chunk " <> curPad <> "]** <reason>`); it will only be retired if >10 remain active after `prediction-judge`'s verdicts."
               , "5. Stay *inside* the story in your active Persona: weave verbatim `>` blockquotes (`[...]` for skipped beats) with live reactions in a single natural forum post (no `# Chunk X/Y` top header, no multiple `###` subheadings except `### Theory & Mystery Notes` at the end, no double-telling/sportscasting, no review jargon like \"masterclass\"/\"emotional axis\", and no textbook truisms). Verify any earlier-chapter callbacks via `memory.md` / `chunks/chunk_XXXX.md`, and quarantine external `search_web` canon lore from in-story facts."
               , "6. Output all four required sections: `=== COMMENTARY ===`, `=== CHUNK SUMMARY ===` (1 line), `=== PREDICTION UPDATES ===` (new prediction + optional conditional `RETIRED` nomination), and `=== UPDATED MEMORY ===` (only the 4 narrative sections)."
               ]
  TIO.writeFile promptPath promptText
  pure promptPath

writeCurrentJudgePromptFile :: FilePath -> SessionState -> IO FilePath
writeCurrentJudgePromptFile sessionDir st = do
  absSession <- canonicalizePath sessionDir
  let curIdx = stCurrentIndex st
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      preds = stPredictions st
      pendingRetires = stPendingRetirements st
      activePreds = [pr | pr <- preds, prStatus pr == PredStatusActive]
      recentResolved =
        [ pr
        | pr <- preds
        , case prStatus pr of
            PredStatusConfirmed resC _ -> resC < curIdx && resC >= max 1 (curIdx - 2)
            PredStatusDebunked resC -> resC < curIdx && resC >= max 1 (curIdx - 2)
            PredStatusSubverted resC -> resC < curIdx && resC >= max 1 (curIdx - 2)
            _ -> False
        ]
      activeLines =
        if null activePreds
          then ["- *(No active predictions to evaluate on this chunk.)*"]
          else
            concat
              [ let origIdx = prOriginChunk pr
                    origPad = padChunkNumber origIdx
                    pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
                    baseLine = renderRecordActiveLine pr <> " ([details](" <> pPath <> "))"
                    retireNote =
                      case lookup origIdx pendingRetires of
                        Nothing -> []
                        Just reason ->
                          [ "  - *Conditional Retirement Nomination by `blind-reader`*: `"
                              <> reason
                              <> "` — **IGNORE this retirement nomination when judging on the merits!** Evaluate `Predicted Chunk "
                              <> T.pack origPad
                              <> "` strictly as `CONFIRMED`, `DEBUNKED`, `SUBVERTED`, or `ACTIVE` against `current_chunk.md`. (`LetsRead.hs` will automatically apply the conditional retirement only if it remains `ACTIVE` and the active slate still exceeds 10 after your verdicts.)"
                          ]
                 in baseLine : retireNote
              | pr <- activePreds
              ]
      recentLines =
        if null recentResolved
          then []
          else
            [ ""
            , "## Recently Resolved Predictions (Last 2 Chunks — Optional Cliffhanger Fake-Out Reversal Only)"
            , "*(Do NOT emit lines for these unless `current_chunk.md` reveals the prior chunk's resolution was a cliffhanger fake-out!)*"
            , ""
            ]
              ++ [ let origPad = padChunkNumber (prOriginChunk pr)
                       pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
                    in renderRecordResolvedLine pr <> " ([details](" <> pPath <> "))"
                 | pr <- recentResolved
                 ]
      judgePromptPath = sessionDir </> "current_judge_prompt.md"
      judgePromptText =
        T.unlines $
          [ "Please evaluate all currently active predictions against the newly unlocked story chunk (Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> ")."
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File (optional context read): " <> T.pack (absSession </> "memory.md")
          , "- Predictions Directory (optional on-demand `read_file`): " <> T.pack (absSession </> "predictions")
          , ""
          , "## Active Predictions to Judge on Chunk " <> curPad <> " (" <> jsonInt (length activePreds) <> " Active — Evaluate ALL of These)"
          , ""
          ]
            ++ activeLines
            ++ recentLines
            ++ [ ""
               , "## Instructions Reminder"
               , "1. Read `current_chunk.md` carefully. Judge **every** active prediction listed above against the explicit text of `current_chunk.md`."
               , "2. Output a single section starting with `=== PREDICTION JUDGMENTS ===` containing **one bullet line for every active prediction** (or `- None.` if 0 active predictions exist):"
               , "   - Still unresolved: `- **[Predicted Chunk XXXX -> ACTIVE]**`"
               , "   - Confirmed: `- **[Predicted Chunk XXXX -> CONFIRMED Chunk " <> curPad <> "]** <concise 1-sentence explanation citing the specific reveal in Chunk " <> curPad <> " (<= 200 chars)>`"
               , "   - Debunked: `- **[Predicted Chunk XXXX -> DEBUNKED Chunk " <> curPad <> "]** <concise 1-sentence explanation citing the specific contradicting fact in Chunk " <> curPad <> " (<= 200 chars)>`"
               , "   - Subverted: `- **[Predicted Chunk XXXX -> SUBVERTED Chunk " <> curPad <> "]** <concise 1-sentence explanation citing the real anomaly vs. how the story twisted the explanation in Chunk " <> curPad <> " (<= 200 chars)>`"
               , "3. Be rigorous and impartial: do NOT confirm a prediction early on partial circumstantial hints, do NOT grade `DEBUNKED` predictions generously as `SUBVERTED` unless the cited `Clue/Anomaly` was genuinely an in-story setup/red herring, and NEVER emit `RETIRED`."
               ]
  TIO.writeFile judgePromptPath judgePromptText
  pure judgePromptPath

lintReaderCommentary :: Text -> [Text]
lintReaderCommentary commText =
  let low = T.toLower commText
      bannedJargon =
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
      matchedJargon = [w | w <- bannedJargon, w `T.isInfixOf` low]
      jargonWarn =
        if null matchedJargon
          then []
          else
            [ "- **[Deterministic Style Linter (`LetsRead.hs`)]** Your previous commentary used banned book-review/essay jargon ("
                <> T.intercalate ", " ["`\"" <> w <> "\"`" | w <- matchedJargon]
                <> "). Stay *inside* the story as a live forum reader—never step outside to grade or praise the author with review blurbs."
            ]
      extraSubheadings =
        [ l
        | l <- T.lines commText
        , let s = T.strip l
        , "### " `T.isPrefixOf` s
        , let hLow = T.toLower s
        , not ("theory" `T.isInfixOf` hLow && "mystery" `T.isInfixOf` hLow)
        , not ("reader discussion" `T.isInfixOf` hLow)
        ]
      headingWarn =
        if length extraSubheadings < 2
          then []
          else
            [ "- **[Deterministic Style Linter (`LetsRead.hs`)]** Your previous commentary chopped the entry into "
                <> jsonInt (length extraSubheadings)
                <> " titled `###` mini-essay subheadings. Let your commentary flow naturally like a single forum post (save `### Theory & Mystery Notes` for the end)."
            ]
      stageEmoteCount =
        max 0 (length (T.splitOn "*[" commText) - 1)
          + max 0 (length (T.splitOn "[*" commText) - 1)
      emoteWarn =
        if stageEmoteCount < 3
          then []
          else
            [ "- **[Deterministic Style Linter (`LetsRead.hs`)]** Your previous commentary used "
                <> jsonInt stageEmoteCount
                <> " bracketed `*[...]*` stage-direction emotes. Express excitement, shock, or humor in natural prose rather than repetitive stage-direction emotes or action sportscasting."
            ]
   in jargonWarn ++ headingWarn ++ emoteWarn

writeCurrentCriticPromptFile :: FilePath -> SessionState -> Text -> IO FilePath
writeCurrentCriticPromptFile sessionDir st summaryTxt = do
  absSession <- canonicalizePath sessionDir
  let curIdx = stCurrentIndex st
      curPad = padChunkNumber curIdx
      curPadTxt = T.pack curPad
      totalChunks = stTotalChunks st
      entryPath = absSession </> "entries" </> ("chunk_" ++ curPad ++ ".md")
      linterLines =
        if null (stPendingLinterWarnings st)
          then ["- *(None triggered.)*"]
          else stPendingLinterWarnings st
      criticPromptPath = sessionDir </> "current_critic_prompt.md"
      criticPromptText =
        T.unlines $
          [ "Please audit `blind-reader`'s newly recorded commentary, 1-line chunk summary, and updated memory for Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> "."
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (`chunks/chunk_" <> curPadTxt <> ".md` — mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Recorded Commentary Entry (mandatory read): " <> T.pack entryPath
          , "- Updated Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          , "- Unlocked Story Chunks Archive (on-demand `read_file` for callback verification): " <> T.pack (absSession </> "chunks")
          , "- Multi-Level Memory & Index Archive (on-demand `read_file`): " <> T.pack (absSession </> "archive")
          , "- Active Reader Persona: " <> expandPersonaPreset (stPersona st)
          , "- Submitted 1-Line Chunk Summary: `" <> summaryTxt <> "`"
          , ""
          , "## Deterministic Style Linter Hits (`LetsRead.hs`)"
          ]
            ++ linterLines
            ++ [ ""
               , "## Instructions Reminder"
               , "1. Read `current_chunk.md`, `entries/chunk_" <> curPadTxt <> ".md`, and `memory.md`."
               , "2. **3-Tier Hierarchy of Truth**: (Tier 1) Explicit story text in `current_chunk.md` / `chunks/chunk_XXXX.md` and Bullet 1 of `## Story Summary So Far` (AU baseline) always override external canon. (Tier 2) Verify any specific external-canon claims via `search_web` (never search for the story being read) and check that unstated canon assumptions were not leaked into `memory.md` or the 1-line chunk summary as in-story facts. (Tier 3) Never flag jokes, hyperbole, sarcasm, or labeled speculation as factual errors."
               , "3. **Mandatory Verifiable Receipts**: Every factual flag in `=== DISPUTED FACTS & MEMORY CHECKS ===` MUST use either:"
               , "   - `- **[In-Story Fact | Source: chunks/chunk_XXXX.md | Quote: \"<exact verbatim substring copied from chunks/chunk_XXXX.md>\"]** <explanation>` (`LetsRead.hs` deterministically verifies the quote against `chunks/chunk_XXXX.md` on disk and drops any fabricated/paraphrased quote!)"
               , "   - `- **[External Canon | Source: search_web(\"<exact query>\") | Work: <Canon Work>]** <explanation>`"
               , "4. **Exception-Only (`- PASS` Default)**: If there are no genuine factual/memory errors and the entry conforms to the active Reader Persona, output ONLY:"
               , "   ```markdown"
               , "   === CRITIC FEEDBACK ==="
               , "   - PASS"
               , "   ```"
               , "   Otherwise, output `=== DISPUTED FACTS & MEMORY CHECKS ===` and `=== PERSONA & STYLE COACHING ===` (`<= 150 words` total)."
               ]
  TIO.writeFile criticPromptPath criticPromptText
  pure criticPromptPath

data CriticSection
  = CritSecGeneral
  | CritSecFacts
  | CritSecStyle
  deriving (Eq, Show)

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

parseCriticSections :: Text -> ([Text], [Text])
parseCriticSections raw =
  let classifyHeader l =
        let s = T.toUpper (T.strip l)
         in if s == "=== CRITIC FEEDBACK ==="
              then Just CritSecGeneral
              else if s == "=== DISPUTED FACTS & MEMORY CHECKS ===" || s == "=== FACT & MEMORY CORRECTIONS ==="
                then Just CritSecFacts
                else if s == "=== PERSONA & STYLE COACHING ===" || s == "=== STYLE COACHING ==="
                  then Just CritSecStyle
                  else Nothing
      go _ [] = []
      go curSec (l : ls) =
        case classifyHeader l of
          Just newSec -> go newSec ls
          Nothing -> (curSec, l) : go curSec ls
      tagged = go CritSecGeneral (T.lines raw)
      isBullet l =
        let t = T.strip l
         in ("- " `T.isPrefixOf` t || "* " `T.isPrefixOf` t) && not (isCriticPassLine t)
      factBullets =
        [ T.strip l
        | (sec, l) <- tagged
        , sec == CritSecFacts
            || (sec == CritSecGeneral && ("[in-story fact" `T.isInfixOf` T.toLower l || "[external canon" `T.isInfixOf` T.toLower l))
        , isBullet l
        ]
      styleBullets =
        [ T.strip l
        | (sec, l) <- tagged
        , sec == CritSecStyle
            || (sec == CritSecGeneral && "[persona" `T.isInfixOf` T.toLower l)
        , isBullet l
        ]
   in (factBullets, styleBullets)

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
      mSrc = findPrefix "source:"
      mRawQuote = findPrefix "quote:"
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

verifyAndFilterCriticFactBullets :: FilePath -> [Text] -> IO ([Text], Int)
verifyAndFilterCriticFactBullets sessionDir bullets = do
  results <- forM bullets $ \b -> do
    case extractBracketHeaderFromBullet b of
      Nothing -> pure (Left ())
      Just hdr ->
        let hdrLow = T.toLower hdr
         in if "external canon" `T.isInfixOf` hdrLow && "search_web" `T.isInfixOf` hdrLow
              then pure (Right b)
              else case extractSourceAndQuote hdr of
                Nothing -> pure (Left ())
                Just (relSrc, quoteTxt) -> do
                  let baseName = takeFileName relSrc
                      candidatePath
                        | baseName == "current_chunk.md" = sessionDir </> "current_chunk.md"
                        | "chunk_" `isPrefixOf` baseName && ".md" `isSuffixOf` baseName =
                            sessionDir </> "chunks" </> baseName
                        | otherwise = sessionDir </> relSrc
                  exists <- doesFileExist candidatePath
                  if not exists
                    then pure (Left ())
                    else do
                      chunkContent <- readTextFileSafe candidatePath
                      let normChunk = normalizeForQuoteCheck chunkContent
                          rawSegs = concatMap (T.splitOn "...") (T.splitOn "[...]" quoteTxt)
                          normSegs = [normalizeForQuoteCheck s | s <- rawSegs, not (T.null (T.strip s))]
                          hasSubstantialSeg = any (\s -> T.length s >= 6) normSegs
                          allMatch = not (null normSegs) && hasSubstantialSeg && all (`T.isInfixOf` normChunk) normSegs
                       in if allMatch
                            then pure (Right b)
                            else pure (Left ())
  let verified = [b | Right b <- results]
      rejected = length [() | Left () <- results]
  pure (verified, rejected)

renderCriticFeedbackMarkdown :: FilePath -> Int -> [Text] -> [Text] -> Text
renderCriticFeedbackMarkdown sessionDir curIdx verifiedFacts styleCoaching =
  let curPad = T.pack (padChunkNumber curIdx)
      factLines =
        if null verifiedFacts
          then ["- *(None flagged on Chunk " <> curPad <> ".)*"]
          else verifiedFacts
      styleLines =
        if null styleCoaching
          then ["- *(None flagged on Chunk " <> curPad <> " — persona and style were on target.)*"]
          else styleCoaching
   in T.unlines $
        [ "# Peer Critic & Fact-Check Notes (From Chunk " <> curPad <> ")"
        , ""
        , "*Session Directory*: `" <> T.pack sessionDir <> "`"
        , ""
        , "> [!IMPORTANT]"
        , "> **HOW TO USE THIS FILE (DO NOT BLINDLY TRUST THE CRITIC)**:"
        , "> 1. **For Disputed Facts & Memory Checks**: The `commentary-critic` subagent is another AI model and **can also hallucinate, misread jokes/subtext, or confuse external canon with this story's intentional AU divergences**. Treat every factual flag below strictly as a **disputed claim** that you must verify against the primary source (`chunks/chunk_XXXX.md`, Bullet 1 of `## Story Summary So Far` in `memory.md`, or `search_web`) before accepting:"
        , ">    - **If the primary source confirms the critic's point**: Fix the error in `=== UPDATED MEMORY ===` on this turn and, if it was a material misread in your previous commentary, include a brief, natural 1-sentence in-character realization in `=== COMMENTARY ===` (e.g., *\"Wait—looking back at what I wrote last chunk, I misread...\"*)."
        , ">    - **If the primary source, an intentional AU divergence, or context shows your original reading (or joke/speculation) was right**: **Overrule and ignore the critic's flag!**"
        , "> 2. **For Persona & Style Coaching**: Apply these voice/craft adjustments **silently** as you write this chunk's commentary. **NEVER** apologize for, mention, or meta-reference style feedback inside `=== COMMENTARY ===`."
        , ""
        , "## Disputed Facts & Memory Checks (Verify Against Primary Source Before Accepting)"
        , ""
        ]
          ++ factLines
          ++ [ ""
             , "## Persona & Style Coaching (Apply Silently — Never Mention in Commentary)"
             , ""
             ]
          ++ styleLines

processCriticFeedback :: FilePath -> Int -> [Text] -> Maybe Text -> IO (Bool, Int, Int)
processCriticFeedback sessionDir curIdx linterWarnings mRawCritic = do
  let (rawFacts, rawStyles) =
        case mRawCritic of
          Nothing -> ([], [])
          Just txt -> parseCriticSections txt
  (verifiedFacts, rejectedCount) <- verifyAndFilterCriticFactBullets sessionDir rawFacts
  let combinedStyles = linterWarnings ++ rawStyles
      totalActiveNotes = length verifiedFacts + length combinedStyles
      feedbackPath = sessionDir </> "critic_feedback.md"
  if totalActiveNotes == 0
    then do
      fbExists <- doesFileExist feedbackPath
      when fbExists (removeFile feedbackPath `catch` (\(_ :: IOException) -> pure ()))
      pure (False, 0, rejectedCount)
    else do
      let rendered = renderCriticFeedbackMarkdown sessionDir curIdx verifiedFacts combinedStyles
          criticArchDir = sessionDir </> "archive" </> "critic"
      createDirectoryIfMissing True criticArchDir
      TIO.writeFile feedbackPath rendered
      TIO.writeFile (criticArchDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")) rendered
      pure (True, totalActiveNotes, rejectedCount)

stripLeadingChunkHeading :: Text -> Text
stripLeadingChunkHeading txt =
  case T.lines (T.strip txt) of
    (firstLine : restLines)
      | Just (_, hTitle) <- parseMarkdownHeading firstLine
      , let cleaned = T.strip (T.dropWhile (not . isAlphaNum) hTitle)
      , "chunk " `T.isPrefixOf` T.toLower cleaned ->
          T.strip (T.unlines restLines)
    _ -> T.strip txt

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
        ++ "Run 'record' and 'judge' first (or pass --force to override)."

  when (curIdx > 0 && stCurrentRecorded st && not (stCurrentJudged st) && not forceFlag) $
    die $
      "Error: Chunk "
        ++ show curIdx
        ++ " commentary has been recorded, but prediction-judge verdicts have not been recorded yet. "
        ++ "Run 'judge' first (or pass --force to override)."

  if curIdx >= totalChunks
    then
      TIO.putStrLn $
        jsonObject
          [ ("status", jsonStr "finished")
          , ("current_index", jsonInt curIdx)
          , ("total_chunks", jsonInt totalChunks)
          , ("hall_of_fame_file", jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")))
          , ("orchestrator_rule", jsonStr orchestratorRuleText)
          , ("message", jsonStr "All chunks have been read! The Let's Read is complete.")
          ]
    else do
      let nextIdx = curIdx + 1
          activeCount = countActivePredictions (stPredictions st)
      chunk <- loadVaultChunk (sessionDir </> ".vault.bin") nextIdx
      let chunkFile = sessionDir </> "current_chunk.md"
          chunksDir = sessionDir </> "chunks"
          archiveChunkFile = chunksDir </> ("chunk_" ++ padChunkNumber nextIdx ++ ".md")
      createDirectoryIfMissing True chunksDir
      writeCurrentChunkFile chunkFile chunk totalChunks (stTotalChapters st) activeCount
      writeCurrentChunkFile archiveChunkFile chunk totalChunks (stTotalChapters st) activeCount
      promptFile <- writeCurrentPromptFile sessionDir st chunk activeCount

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
              , stCurrentJudged = False
              , stCurrentMeta = Just meta
              , stPendingRetirements = []
              , stPendingLinterWarnings = []
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
          , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
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
  let isFinished = stCurrentIndex st >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st
      hofSuffix =
        if isFinished && not (null (stPredictions st))
          then "\n" <> renderHallOfFameMarkdown sessionDir st <> "\n"
          else ""
      logHeader =
        "# Let's Read: "
          <> stTitle st
          <> "\n\n*Reader Persona*: "
          <> stPersona st
          <> "\n\n---\n\n"
      logPath = sessionDir </> "lets_read_log.md"
  TIO.writeFile logPath (logHeader <> T.concat entryContents <> hofSuffix)
  pure logPath

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

data RecordOptions = RecordOptions
  { recSession :: FilePath
  , recResponseFile :: Maybe FilePath
  , recSubagentLog :: Maybe FilePath
  , recCommentaryFile :: Maybe FilePath
  , recMemoryFile :: Maybe FilePath
  }

data JudgeOptions = JudgeOptions
  { jdgSession :: FilePath
  , jdgResponseFile :: Maybe FilePath
  , jdgSubagentLog :: Maybe FilePath
  , jdgCriticResponseFile :: Maybe FilePath
  , jdgCriticLog :: Maybe FilePath
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
          || "=== PREDICTION UPDATES ===" `T.isInfixOf` t
          || "=== PREDICTION JUDGMENTS ===" `T.isInfixOf` t
          || "=== CRITIC FEEDBACK ===" `T.isInfixOf` t
          || "=== DISPUTED FACTS & MEMORY CHECKS ===" `T.isInfixOf` t
          || "=== PERSONA & STYLE COACHING ===" `T.isInfixOf` t
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

  (_, commText, mParsedSummary, mParsedPredUpdates, mParsedMem) <-
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
                pure (Nothing, T.strip raw, Nothing, Nothing, Nothing)
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
      linterWarnings = lintReaderCommentary cleanedCommText
      (chapNum, chapTitle, partNum, partsTotal) =
        case stCurrentMeta st of
          Just m -> (metaChapterNumber m, metaChapterTitle m, metaPartInChapter m, metaPartsInChapter m)
          Nothing -> (1, "Chapter ?", 1, 1)

  (curated', preds', pendingRetires, auditBlocks, trackerUpdates) <-
    resolveAndAuditTurn
      sessionDir
      curIdx
      (stTotalChunks st)
      chapNum
      chapTitle
      True
      cleanedCommText
      (stCuratedMemory st)
      (stPredictions st)
      (stPredictionAuditWarnings st)
      mParsedPredUpdates
      finalMem

  let summaryTxt = fromMaybe (extractFallbackSummary commText) mParsedSummary
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
          , stCurrentJudged = False
          , stCompletedChunks = completed'
          , stChunkIndex = chunkIndex'
          , stCuratedMemory = curated'
          , stPredictions = preds'
          , stPendingRetirements = pendingRetires
          , stPendingLinterWarnings = linterWarnings
          , stPredictionAuditWarnings = auditBlocks
          }

  judgePromptFile <- writeCurrentJudgePromptFile sessionDir st'
  criticPromptFile <- writeCurrentCriticPromptFile sessionDir st' summaryTxt
  (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
  logPath <- rebuildMasterLog sessionDir st'
  saveState sessionDir st'

  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "awaiting_judge")
      , ("chunk_index", jsonInt curIdx)
      , ("total_chunks", jsonInt (stTotalChunks st))
      , ("remaining_chunks", jsonInt (stTotalChunks st - curIdx))
      , ("is_finished", jsonBool False)
      , ("entry_file", jsonStr (T.pack entryFile))
      , ("log_file", jsonStr (T.pack logPath))
      , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
      , ("judge_prompt_file", jsonStr (T.pack judgePromptFile))
      , ("critic_prompt_file", jsonStr (T.pack criticPromptFile))
      , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
      , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
      , ("active_predictions_count", jsonInt (countActivePredictions preds'))
      , ("pending_retirements_count", jsonInt (length pendingRetires))
      , ("linter_warnings_count", jsonInt (length linterWarnings))
      , ("total_predictions_count", jsonInt (length preds'))
      , ("prediction_audit_warnings_count", jsonInt (length auditBlocks))
      , ("memory_compaction_needed", jsonBool needsCompaction)
      , ("curated_memory_lines", jsonInt curLines)
      , ("curated_memory_bytes", jsonInt curBytes)
      , ("orchestrator_rule", jsonStr orchestratorRuleText)
      , ("next_step_hint", jsonStr "Send judge_prompt_file to prediction-judge and critic_prompt_file to commentary-critic in parallel, then run 'LetsRead.hs judge --session <dir> --subagent-log <judge_log> --critic-log <critic_log>'.")
      ]

cmdJudge :: JudgeOptions -> IO ()
cmdJudge opts = do
  sessionDir <- canonicalizePath (jdgSession opts)
  st <- loadState sessionDir
  let curIdx = stCurrentIndex st
  when (curIdx < 1) $
    die "Error: No chunk is currently unlocked. Run 'next' first."
  unless (stCurrentRecorded st) $
    die "Error: Current chunk commentary has not been recorded yet. Run 'record' before 'judge'."

  rawJudge <-
    case jdgSubagentLog opts of
      Just logPath -> do
        raw <- extractSubagentLogResponse logPath
        TIO.writeFile (sessionDir </> "last_judge_response.md") (raw <> "\n")
        pure raw
      Nothing ->
        case jdgResponseFile opts of
          Just respPath -> do
            exists <- doesFileExist respPath
            unless exists $ die ("Error: Judge response file not found: " ++ respPath)
            readTextFileSafe respPath
          Nothing ->
            die "Error: Provide --subagent-log or --response-file for 'judge'."

  mRawCritic <-
    case jdgCriticLog opts of
      Just cLogPath -> do
        rawC <- extractSubagentLogResponse cLogPath
        TIO.writeFile (sessionDir </> "last_critic_response.md") (rawC <> "\n")
        pure (Just rawC)
      Nothing ->
        case jdgCriticResponseFile opts of
          Just cRespPath -> do
            exists <- doesFileExist cRespPath
            unless exists $ die ("Error: Critic response file not found: " ++ cRespPath)
            rawC <- readTextFileSafe cRespPath
            pure (Just rawC)
          Nothing -> pure Nothing

  (criticFeedbackWritten, criticNotesCount, rejectedCriticQuotesCount) <-
    processCriticFeedback sessionDir curIdx (stPendingLinterWarnings st) mRawCritic

  let judgeSec = extractJudgeSection rawJudge
      (preds', judgeAuditBlocks, judgeSummaryLines) =
        applyJudgeVerdicts
          curIdx
          (stPredictions st)
          (stPendingRetirements st)
          judgeSec
      entriesDir = sessionDir </> "entries"
      entryFile = entriesDir </> ("chunk_" ++ padChunkNumber curIdx ++ ".md")

  entryExists <- doesFileExist entryFile
  unless entryExists $
    die ("Error: Recorded entry file not found: " ++ entryFile)

  existingEntry <- readTextFileSafe entryFile
  let baseEntry = stripExistingJudgeCallout (stripTrailingEntryRule existingEntry)
      judgeCallout = formatJudgeCallout curIdx judgeSummaryLines
      judgeAuditCallout = formatAuditEntryCallout judgeAuditBlocks
      updatedEntry = baseEntry <> judgeCallout <> judgeAuditCallout <> "\n\n---\n\n"
  TIO.writeFile entryFile updatedEntry

  let combinedAuditBlocks = stPredictionAuditWarnings st ++ judgeAuditBlocks
      st' =
        st
          { stCurrentJudged = True
          , stPredictions = preds'
          , stPendingRetirements = []
          , stPendingLinterWarnings = []
          , stLastJudgeSummary = judgeSummaryLines
          , stPredictionAuditWarnings = combinedAuditBlocks
          }

  (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
  logPath <- rebuildMasterLog sessionDir st'
  saveState sessionDir st'

  let isFin = curIdx >= stTotalChunks st
  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "judged")
      , ("chunk_index", jsonInt curIdx)
      , ("total_chunks", jsonInt (stTotalChunks st))
      , ("remaining_chunks", jsonInt (stTotalChunks st - curIdx))
      , ("is_finished", jsonBool isFin)
      , ("entry_file", jsonStr (T.pack entryFile))
      , ("log_file", jsonStr (T.pack logPath))
      , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
      , ("critic_feedback_written", jsonBool criticFeedbackWritten)
      , ("critic_notes_count", jsonInt criticNotesCount)
      , ("rejected_unverified_critic_quotes_count", jsonInt rejectedCriticQuotesCount)
      , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
      , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
      , ("hall_of_fame_file", if isFin then jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")) else "null")
      , ("active_predictions_count", jsonInt (countActivePredictions preds'))
      , ("total_predictions_count", jsonInt (length preds'))
      , ("judge_audit_warnings_count", jsonInt (length judgeAuditBlocks))
      , ("prediction_audit_warnings_count", jsonInt (length combinedAuditBlocks))
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

  (mParsedUser, replyText, mParsedSummary, mParsedPredUpdates, mParsedMem) <-
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
                pure (Nothing, T.strip raw, Nothing, Nothing, Nothing)
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
      (chapNum, chapTitle) =
        case stCurrentMeta st of
          Just m -> (metaChapterNumber m, metaChapterTitle m)
          Nothing -> (1, "Chapter ?")

  entryExists <- doesFileExist entryFile
  unless entryExists $
    die ("Error: Recorded entry file not found: " ++ entryFile)

  (curated', preds', _, auditBlocks, trackerUpdates) <-
    resolveAndAuditTurn
      sessionDir
      curIdx
      (stTotalChunks st)
      chapNum
      chapTitle
      False
      replyText
      (stCuratedMemory st)
      (stPredictions st)
      (stPredictionAuditWarnings st)
      mParsedPredUpdates
      finalMem

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

  let chunkIndex' =
        case mParsedSummary of
          Nothing -> stChunkIndex st
          Just newSum ->
            map
              (\e -> if cieChunkIndex e == curIdx then e {cieSummary = newSum} else e)
              (stChunkIndex st)
      memUpdated =
        isJust finalMem
          || isJust mParsedPredUpdates
          || isJust mParsedSummary
          || (curated' /= stCuratedMemory st)
          || (preds' /= stPredictions st)
          || (auditBlocks /= stPredictionAuditWarnings st)
      st' =
        st
          { stChunkIndex = chunkIndex'
          , stCuratedMemory = curated'
          , stPredictions = preds'
          , stPredictionAuditWarnings = auditBlocks
          }

  (needsCompaction, curLines, curBytes) <- syncMemoryAndArchives sessionDir st'
  logPath <- rebuildMasterLog sessionDir st'
  when memUpdated $
    saveState sessionDir st'

  TIO.putStrLn $
    jsonObject
      [ ("status", jsonStr "discussed")
      , ("chunk_index", jsonInt curIdx)
      , ("entry_file", jsonStr (T.pack entryFile))
      , ("log_file", jsonStr (T.pack logPath))
      , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
      , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
      , ("memory_updated", jsonBool memUpdated)
      , ("active_predictions_count", jsonInt (countActivePredictions preds'))
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
    , "  judge --session <dir> [--response-file <path>] [--subagent-log <path>] [--critic-response-file <path>] [--critic-log <path>]"
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

parseJudgeArgs :: [String] -> IO JudgeOptions
parseJudgeArgs = go (JudgeOptions "" Nothing Nothing Nothing Nothing)
  where
    go opts []
      | null (jdgSession opts) = die ("Error: Missing --session <dir>.\n\n" ++ usage)
      | otherwise = pure opts
    go opts ("--session" : v : rest) = go opts {jdgSession = v} rest
    go opts ("--response-file" : v : rest) = go opts {jdgResponseFile = Just v} rest
    go opts ("--subagent-log" : v : rest) = go opts {jdgSubagentLog = Just v} rest
    go opts ("--critic-response-file" : v : rest) = go opts {jdgCriticResponseFile = Just v} rest
    go opts ("--critic-log" : v : rest) = go opts {jdgCriticLog = Just v} rest
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
    ("judge" : rest) -> parseJudgeArgs rest >>= cmdJudge
    ("discuss" : rest) -> parseDiscussArgs rest >>= cmdDiscuss
    ("status" : rest) -> parseStatusArgs rest >>= cmdStatus
    _ -> do
      hPutStrLn stderr usage
      die "Error: Please specify a valid command (init, next, record, judge, discuss, status)."
