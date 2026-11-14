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
  , PredictionStatus (..)
  , PredictionRecord (..)
  , SessionState (..)
  , ResolutionKind (..)
  , ParsedPrediction (..)
  , ResponseSection (..)
  , ParsedChunkSummaries (..)
  , emptyParsedChunkSummaries
  , CriticSection (..)
  , InitOptions (..)
  , RecordOptions (..)
  , JudgeOptions (..)
  , DiscussPromptOptions (..)
  , DiscussOptions (..)
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
  , prPartInChapter :: !Int
  , prPartsInChapter :: !Int
  , prTopics :: ![Text]
  , prClue :: !Text
  , prTheory :: !Text
  , prRival :: !Text
  , prRawBody :: !Text
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
-- Auxiliary Parsing & CLI Option Types
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

data InitOptions = InitOptions
  { initSource :: FilePath
  , initSession :: FilePath
  , initMaxWords :: Int
  , initTitle :: Maybe Text
  , initPersona :: Maybe Text
  , initOverwrite :: Bool
  }

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
  , jdgFactCheckResponseFile :: Maybe FilePath
  , jdgFactCheckLog :: Maybe FilePath
  , jdgCriticResponseFile :: Maybe FilePath
  , jdgCriticLog :: Maybe FilePath
  , jdgTopicResponseFile :: Maybe FilePath
  , jdgTopicLog :: Maybe FilePath
  }

data DiscussPromptOptions = DiscussPromptOptions
  { dpoSession :: FilePath
  , dpoUserMessage :: Maybe Text
  , dpoUserFile :: Maybe FilePath
  }

data DiscussOptions = DiscussOptions
  { discSession :: FilePath
  , discResponseFile :: Maybe FilePath
  , discSubagentLog :: Maybe FilePath
  , discCommentaryFile :: Maybe FilePath
  , discMemoryFile :: Maybe FilePath
  , discUserMessage :: Maybe Text
  , discUserFile :: Maybe FilePath
  }

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
  "Pass generated prompt files (<session_dir>/current_*_prompt.md) verbatim to subagents; never run python/ad-hoc scripts, impersonate subagents, or edit memory.md directly."

renderStateJson :: FilePath -> Bool -> Bool -> Bool -> SessionState -> Text
renderStateJson sessionDir hasWrapup hasFactCheckPending hasTopicPrompt st =
  let storyChunksDone = stCurrentIndex st >= stTotalChunks st && stCurrentRecorded st && stCurrentJudged st && not hasFactCheckPending
      isFin = storyChunksDone && hasWrapup
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
        , ("fact_check_discussion_pending", jsonBool hasFactCheckPending)
        , ("completed_chunks_count", jsonInt (length (stCompletedChunks st)))
        , ("wrapup_recorded", jsonBool hasWrapup)
        , ("is_finished", jsonBool isFin)
        , ("active_predictions_count", jsonInt activeCnt)
        , ("total_predictions_count", jsonInt totalPreds)
        , ("pending_retirements_count", jsonInt (length (stPendingRetirements st)))
        , ("pending_linter_warnings_count", jsonInt (length (stPendingLinterWarnings st)))
        , ("current_chunk_meta", renderMetaJson (stCurrentMeta st))
        , ("current_chunk_file", jsonStr (T.pack (sessionDir </> "current_chunk.md")))
        , ("subagent_prompt_file", jsonStr (T.pack (sessionDir </> "current_prompt.md")))
        , ("judge_prompt_file", jsonStr (T.pack (sessionDir </> "current_judge_prompt.md")))
        , ("fact_check_prompt_file", jsonStr (T.pack (sessionDir </> "current_fact_check_prompt.md")))
        , ("critic_prompt_file", jsonStr (T.pack (sessionDir </> "current_critic_prompt.md")))
        , ("topic_prompt_file", if hasTopicPrompt then jsonStr (T.pack (sessionDir </> "current_topic_prompt.md")) else "null")
        , ("discussion_prompt_file", if hasFactCheckPending then jsonStr (T.pack (sessionDir </> "current_discussion_prompt.md")) else "null")
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

-- | Locate a file inside the skill directory (skills/start/<relPath>)
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
    else pure ("skills/start" </> relPath)
