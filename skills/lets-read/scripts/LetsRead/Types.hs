{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LetsRead.Types
  ( Chunk (..)
  , ChunkMeta (..)
  , chunkToMeta
  , StoryChunkRecord (..)
  , EntryDiscussionRecord (..)
  , EntryLogRecord (..)
  , ResolutionMeta (..)
  , PredictionStatus (..)
  , PredictionRecord (..)
  , isPredActive
  , predActiveScreeningNote
  , predResolutionMeta
  , predStoryResolutionMeta
  , SessionState (..)
  , ResolutionKind (..)
  , ParsedPrediction (..)
  , ResponseSection (..)
  , ParsedChunkSummaries (..)
  , emptyParsedChunkSummaries
  , CriticSection (..)
  , saveVault
  , loadVaultChunk
  , saveState
  , loadState
  , escapeJson
  , jsonStr
  , jsonBool
  , jsonInt
  , jsonObject
  , renderMetaJson
  , orchestratorRuleText
  , renderStateJson
  , padChunkNumber
  , formatChapLabel
  , countWords
  , readTextFileSafe
  , stripFileUriPrefix
  , isToolReceiptCommentLine
  , stripToolReceiptComments
  , stripAfterClosingBracket
  , wrapMarkdownParagraph
  , wrapMarkdownBullet
  , wrapMarkdownQuote
  , resolveSkillResourcePath
  ) where

import Control.Exception (IOException, catch)
import Control.Monad (unless)
import Data.Binary (Binary, decode, encode)
import Data.Bits (xor)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.IO as TIO
import Data.Word (Word8)
import GHC.Generics (Generic)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))

-- ---------------------------------------------------------------------------
-- Core Data Types (Binary-compatible with .vault.bin and .state.bin)
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

data StoryChunkRecord = StoryChunkRecord
  { scrChunkIndex :: !Int
  , scrChapterNumber :: !Int
  , scrChapterTitle :: !Text
  , scrPartInChapter :: !Int
  , scrPartsInChapter :: !Int
  , scrTopics :: ![Text]
  , scrSummary :: !Text
  }
  deriving (Show, Eq, Generic)

instance Binary StoryChunkRecord

data EntryDiscussionRecord = EntryDiscussionRecord
  { edrIsFactCheck :: !Bool
  , edrTopics :: ![Text]
  , edrSummary :: !Text
  }
  deriving (Show, Eq, Generic)

instance Binary EntryDiscussionRecord

data EntryLogRecord = EntryLogRecord
  { elrEntryIndex :: !Int
  , elrIsWrapup :: !Bool
  , elrChapterNumber :: !Int
  , elrChapterTitle :: !Text
  , elrPartInChapter :: !Int
  , elrPartsInChapter :: !Int
  , elrTopics :: ![Text]
  , elrSummary :: !Text
  , elrDiscussions :: ![EntryDiscussionRecord]
  }
  deriving (Show, Eq, Generic)

instance Binary EntryLogRecord

data ResolutionMeta = ResolutionMeta
  { rmChunk :: !Int
  , rmChapterNumber :: !Int
  , rmChapterTitle :: !Text
  , rmPartInChapter :: !Int
  , rmPartsInChapter :: !Int
  , rmNote :: !Text
  }
  deriving (Show, Eq, Generic)

instance Binary ResolutionMeta

data PredictionStatus
  = PredStatusActive !(Maybe Text) -- ^ optional Judge screening note while active
  | PredStatusConfirmed !ResolutionMeta !Bool -- ^ meta, isSameChunk (0 chunks foresight)
  | PredStatusDebunked !ResolutionMeta
  | PredStatusSubverted !ResolutionMeta
  | PredStatusRetired !ResolutionMeta
  deriving (Show, Eq, Generic)

instance Binary PredictionStatus

data PredictionRecord = PredictionRecord
  { prOriginChunk :: !Int
  , prChapterNumber :: !Int
  , prChapterTitle :: !Text
  , prPartInChapter :: !Int
  , prPartsInChapter :: !Int
  , prTopics :: ![Text]
  , prClue :: !Text
  , prTheory :: !Text
  , prRival :: !Text
  , prRawBody :: !Text
  , prStatus :: !PredictionStatus
  }
  deriving (Show, Eq, Generic)

instance Binary PredictionRecord

isPredActive :: PredictionRecord -> Bool
isPredActive pr =
  case prStatus pr of
    PredStatusActive _ -> True
    _ -> False

predActiveScreeningNote :: PredictionRecord -> Maybe Text
predActiveScreeningNote pr =
  case prStatus pr of
    PredStatusActive mNote -> mNote
    _ -> Nothing

predResolutionMeta :: PredictionRecord -> Maybe ResolutionMeta
predResolutionMeta pr =
  case prStatus pr of
    PredStatusActive _ -> Nothing
    PredStatusConfirmed rm _ -> Just rm
    PredStatusDebunked rm -> Just rm
    PredStatusSubverted rm -> Just rm
    PredStatusRetired rm -> Just rm

predStoryResolutionMeta :: PredictionRecord -> Maybe ResolutionMeta
predStoryResolutionMeta pr =
  case prStatus pr of
    PredStatusConfirmed rm _ -> Just rm
    PredStatusDebunked rm -> Just rm
    PredStatusSubverted rm -> Just rm
    PredStatusRetired _ -> Nothing
    PredStatusActive _ -> Nothing

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
  , stStoryRecords :: ![StoryChunkRecord]
  , stEntryRecords :: ![EntryLogRecord]
  , stCuratedMemory :: ![(Text, Text)]
  , stPredictions :: ![PredictionRecord]
  , stPendingRetirements :: ![(Int, Text)]
  , stPendingLinterWarnings :: ![Text]
  , stLastJudgeSummary :: ![Text]
  , stPredictionAuditWarnings :: ![Text]
  , stCuratedTopics :: ![Text]
  , stTopicAliases :: ![(Text, Text)]
  }
  deriving (Show, Eq, Generic)

instance Binary SessionState

-- ---------------------------------------------------------------------------
-- Auxiliary Parsing Types
-- ---------------------------------------------------------------------------

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
      }
  | PredValidKeepActive
      { ppKeepOrigChunk :: !Int
      , ppRawLine :: !Text
      , ppBodyAfterBracket :: !Text
      }
  | PredValidResolved
      { ppResOrigChunk :: !Int
      , ppResChunk :: !Int
      , ppResKind :: !ResolutionKind
      , ppRawLine :: !Text
      , ppBodyAfterBracket :: !Text
      }
  | PredInvalidNotation
      { ppRawLine :: !Text
      , ppBodyAfterBracket :: !Text
      }
  deriving (Eq, Show)

data ResponseSection
  = SecUserQuestion
  | SecCommentary
  | SecChunkSummary
  | SecPredictionUpdates
  | SecUpdatedMemory
  deriving (Eq, Show)

data ParsedChunkSummaries = ParsedChunkSummaries
  { pcsStory :: Maybe ([Text], Text)
  , pcsEntry :: Maybe ([Text], Text)
  , pcsDiscussion :: Maybe ([Text], Text)
  }
  deriving (Eq, Show)

emptyParsedChunkSummaries :: ParsedChunkSummaries
emptyParsedChunkSummaries = ParsedChunkSummaries Nothing Nothing Nothing

data CriticSection
  = CritSecGeneral
  | CritSecVerifiedLog
  | CritSecFacts
  | CritSecStyle
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Vault Obfuscation & State Persistence
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
  hasWrapup <- doesFileExist (sessionDir </> "entries" </> "wrapup.md")
  hasFactCheckPending <- doesFileExist (sessionDir </> "current_fact_check_questions.md")
  hasTopicPrompt <- doesFileExist (sessionDir </> "current_topic_prompt.md")
  TIO.writeFile (sessionDir </> "state.json") (renderStateJson sessionDir hasWrapup hasFactCheckPending hasTopicPrompt st)

loadState :: FilePath -> IO SessionState
loadState sessionDir = do
  let binPath = sessionDir </> ".state.bin"
  exists <- doesFileExist binPath
  unless exists $
    die ("Error: Session not initialized in " ++ sessionDir)
  raw <- BSL.fromStrict <$> BS.readFile binPath
  pure (decode raw)

-- ---------------------------------------------------------------------------
-- JSON & Formatting Helpers
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
  "Use messages ONLY as 1-line notifications pointing subagents to read <session_dir>/current_*_prompt.md and write <session_dir>/current_*_response.md; wait for lets-read CLI commands to exit 0 before messaging subagents, never send duplicate notifications or poll, NEVER call 'record', 'judge', or 'discuss' while ANY dispatched subagent has not yet sent its idle completion notice (never emit 'Waiting...' text alongside a CLI tool call—if fewer than all dispatched subagents have reported idle, end your turn with ZERO tool calls), use 'lets-read status --session <dir>' (never ls/cat) to check state, and never read/paste prompt/chunk files into messages, run python/ad-hoc scripts, impersonate subagents, or edit memory.md directly."

renderStateJson :: FilePath -> Bool -> Bool -> Bool -> SessionState -> Text
renderStateJson sessionDir hasWrapup hasFactCheckPending hasTopicPrompt st =
  let storyChunksDone = stCurrentIndex st >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st && not hasFactCheckPending
      isFin = storyChunksDone && hasWrapup
      activeCnt = length [pr | pr <- stPredictions st, isPredActive pr]
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
        , ("fact_check_discussion_pending", jsonBool hasFactCheckPending)
        , ("completed_chunks_count", jsonInt (length (stCompletedChunks st)))
        , ("wrapup_recorded", jsonBool hasWrapup)
        , ("wrapup_pending", jsonBool (storyChunksDone && not hasWrapup))
        , ("is_finished", jsonBool isFin)
        , ("active_predictions_count", jsonInt activeCnt)
        , ("total_predictions_count", jsonInt totalPreds)
        , ("pending_retirements_count", jsonInt (length (stPendingRetirements st)))
        , ("pending_linter_warnings_count", jsonInt (length (stPendingLinterWarnings st)))
        , ("current_chunk_meta", renderMetaJson (stCurrentMeta st))
        , ("current_chunk_file", jsonStr (T.pack (sessionDir </> "current_chunk.md")))
        , ("subagent_prompt_file", jsonStr (T.pack (sessionDir </> "current_prompt.md")))
        , ("reader_response_file", jsonStr (T.pack (sessionDir </> "current_reader_response.md")))
        , ("judge_prompt_file", jsonStr (T.pack (sessionDir </> "current_judge_prompt.md")))
        , ("judge_response_file", jsonStr (T.pack (sessionDir </> "current_judge_response.md")))
        , ("fact_check_prompt_file", jsonStr (T.pack (sessionDir </> "current_fact_check_prompt.md")))
        , ("fact_check_response_file", jsonStr (T.pack (sessionDir </> "current_fact_check_response.md")))
        , ("critic_prompt_file", jsonStr (T.pack (sessionDir </> "current_critic_prompt.md")))
        , ("critic_response_file", jsonStr (T.pack (sessionDir </> "current_critic_response.md")))
        , ("topic_prompt_file", if hasTopicPrompt then jsonStr (T.pack (sessionDir </> "current_topic_prompt.md")) else "null")
        , ("topic_response_file", if hasTopicPrompt then jsonStr (T.pack (sessionDir </> "current_topic_response.md")) else "null")
        , ("discussion_prompt_file", if hasFactCheckPending then jsonStr (T.pack (sessionDir </> "current_discussion_prompt.md")) else "null")
        , ("discussion_response_file", if hasFactCheckPending then jsonStr (T.pack (sessionDir </> "current_discussion_response.md")) else "null")
        , ("fact_check_questions_file", if hasFactCheckPending then jsonStr (T.pack (sessionDir </> "current_fact_check_questions.md")) else "null")
        , ("critic_feedback_file", jsonStr (T.pack (sessionDir </> "critic_feedback.md")))
        , ("chunks_dir", jsonStr (T.pack (sessionDir </> "chunks")))
        , ("chunks_by_chronology_file", jsonStr (T.pack (sessionDir </> "chunks" </> "by_chronology.md")))
        , ("chunks_by_topic_file", jsonStr (T.pack (sessionDir </> "chunks" </> "by_topic.md")))
        , ("entries_dir", jsonStr (T.pack (sessionDir </> "entries")))
        , ("entries_by_chronology_file", jsonStr (T.pack (sessionDir </> "entries" </> "by_chronology.md")))
        , ("entries_by_topic_file", jsonStr (T.pack (sessionDir </> "entries" </> "by_topic.md")))
        , ("wrapup_file", if hasWrapup then jsonStr (T.pack (sessionDir </> "entries" </> "wrapup.md")) else "null")
        , ("archive_dir", jsonStr (T.pack (sessionDir </> "archive")))
        , ("predictions_dir", jsonStr (T.pack (sessionDir </> "predictions")))
        , ("predictions_by_chronology_file", jsonStr (T.pack (sessionDir </> "predictions" </> "by_chronology.md")))
        , ("predictions_by_topic_file", jsonStr (T.pack (sessionDir </> "predictions" </> "by_topic.md")))
        , ("hall_of_fame_file", if storyChunksDone then jsonStr (T.pack (sessionDir </> "predictions" </> "hall_of_fame.md")) else "null")
        , ("memory_file", jsonStr (T.pack (sessionDir </> "memory.md")))
        , ("log_file", jsonStr (T.pack (sessionDir </> "lets_read_log.md")))
        , ("orchestrator_rule", jsonStr orchestratorRuleText)
        ]
        <> "\n"

padChunkNumber :: Int -> String
padChunkNumber n =
  let s = show n
   in replicate (max 0 (4 - length s)) '0' ++ s

formatChapLabel :: Int -> Text -> Text
formatChapLabel chapNum chapTitle
  | chapNum == 0 = chapTitle
  | "chapter " `T.isPrefixOf` T.toLower (T.strip chapTitle) = chapTitle
  | otherwise = "Ch. " <> jsonInt chapNum <> ": " <> chapTitle

countWords :: Text -> Int
countWords = length . T.words

readTextFileSafe :: FilePath -> IO Text
readTextFileSafe path = do
  bs <- BS.readFile path
  pure (TE.decodeUtf8With TEE.lenientDecode bs)

stripFileUriPrefix :: FilePath -> FilePath
stripFileUriPrefix p
  | "file://" `isPrefixOf` p = drop 7 p
  | otherwise = p

-- | Return 'True' when a line is a structured @<!-- TOOLS: ... -->@ metadata
-- comment emitted at the top of a subagent response file.
isToolReceiptCommentLine :: Text -> Bool
isToolReceiptCommentLine rawLine =
  let s = T.strip rawLine
   in "<!--" `T.isPrefixOf` s
        && "-->" `T.isSuffixOf` s
        && let inner = T.strip (T.dropEnd 3 (T.drop 4 s))
            in "tools:" `T.isPrefixOf` T.toLower inner

-- | Strip any @<!-- TOOLS: ... -->@ metadata lines from a response text while
-- preserving all remaining lines intact.
stripToolReceiptComments :: Text -> Text
stripToolReceiptComments txt
  | T.null txt = txt
  | otherwise =
      let kept = [l | l <- T.lines txt, not (isToolReceiptCommentLine l)]
          trailNl = if "\n" `T.isSuffixOf` txt then "\n" else ""
       in if null kept then "" else T.intercalate "\n" kept <> trailNl

-- | Strip the closing bold/italic stars immediately attached to a @]@ bracket
-- tag (such as @**[Story | Topics: ...]**@) plus an optional @:@ separator,
-- without stripping leading Markdown emphasis (e.g. @*Title* opens...@) from
-- the body text that follows.
stripAfterClosingBracket :: Text -> Text
stripAfterClosingBracket afterClose =
  let afterBracket = T.drop 1 afterClose
      afterClosingStars = T.dropWhile (== '*') afterBracket
      trimmed = T.stripStart afterClosingStars
   in case T.uncons trimmed of
        Just (':', rest) -> T.strip rest
        _ -> T.strip trimmed

wrapWordsAt :: Int -> Text -> Text -> [Text] -> [Text]
wrapWordsAt maxWidth firstPrefix contPrefix = go True ""
  where
    go _ cur [] = [cur | not (T.null cur)]
    go isFirst cur (w : ws)
      | T.null cur =
          let pfx = if isFirst then firstPrefix else contPrefix
           in go False (pfx <> w) ws
      | T.length cur + 1 + T.length w <= maxWidth =
          go isFirst (cur <> " " <> w) ws
      | otherwise =
          cur : go False (contPrefix <> w) ws

-- | Word-wrap a plain Markdown paragraph at @maxWidth@ columns without breaking
-- single non-whitespace tokens (such as long file paths or URLs).
wrapMarkdownParagraph :: Int -> Text -> Text
wrapMarkdownParagraph maxWidth txt =
  let ws = T.words txt
   in if null ws
        then ""
        else T.intercalate "\n" (wrapWordsAt maxWidth "" "" ws)

-- | Word-wrap a Markdown list item (@- @, @* @, or @1. @), indenting continuation
-- lines to align beneath the list marker's text column.
wrapMarkdownBullet :: Int -> Text -> Text
wrapMarkdownBullet maxWidth rawBullet =
  let leadSpaces = T.takeWhile (== ' ') rawBullet
      rest = T.drop (T.length leadSpaces) rawBullet
      (marker, body)
        | "- " `T.isPrefixOf` rest = ("- ", T.drop 2 rest)
        | "* " `T.isPrefixOf` rest = ("* ", T.drop 2 rest)
        | otherwise =
            let (digits, afterDigits) = T.span (\c -> c >= '0' && c <= '9') rest
             in if not (T.null digits) && ". " `T.isPrefixOf` afterDigits
                  then (digits <> ". ", T.drop 2 afterDigits)
                  else ("", rest)
      firstPfx = leadSpaces <> marker
      contPfx = leadSpaces <> T.replicate (T.length marker) " "
      ws = T.words body
   in if null ws
        then T.stripEnd rawBullet
        else T.intercalate "\n" (wrapWordsAt maxWidth firstPfx contPfx ws)

-- | Word-wrap a Markdown blockquote paragraph at @maxWidth@ columns with a @> @
-- prefix on every line.
wrapMarkdownQuote :: Int -> Text -> Text
wrapMarkdownQuote maxWidth txt =
  let ws = T.words txt
   in if null ws
        then ">"
        else T.intercalate "\n" (wrapWordsAt maxWidth "> " "> " ws)

-- | Locate a file inside the skill directory (skills/lets-read/<relPath>)
-- using the compiled executable's location (.bin/lets-read -> parent directory),
-- falling back to the relative workspace path if run via runghc.
resolveSkillResourcePath :: FilePath -> IO FilePath
resolveSkillResourcePath relPath = do
  exeCandidate <-
    ( do
        exePath <- getExecutablePath
        let skillDir = takeDirectory (takeDirectory exePath)
        pure (skillDir </> relPath)
    )
      `catch` (\(_ :: IOException) -> pure "")
  hasExeCandidate <-
    if null exeCandidate
      then pure False
      else doesFileExist exeCandidate
  if hasExeCandidate
    then pure exeCandidate
    else pure ("skills/lets-read" </> relPath)
