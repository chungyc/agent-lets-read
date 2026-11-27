{-# LANGUAGE OverloadedStrings #-}

module TestHarness
  ( assertBool
  , assertEq
  , normWs
  , withTempDir
  , baseDummyState
  , dummyChunk
  ) where

import Control.Exception (finally)
import Control.Monad (unless, when)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Stack (HasCallStack)
import LetsRead.Memory (defaultCuratedMemory)
import LetsRead.Types
  ( Chunk (..)
  , SessionState (..)
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , getTemporaryDirectory
  , removeDirectoryRecursive
  )
import System.FilePath ((</>))
import Test.Hspec (expectationFailure)

assertBool :: HasCallStack => String -> Bool -> IO ()
assertBool label cond =
  unless cond (expectationFailure label)

assertEq :: (HasCallStack, Eq a, Show a) => String -> a -> a -> IO ()
assertEq label expected actual =
  unless (expected == actual) $
    expectationFailure $
      label
        ++ "\n  expected: "
        ++ show expected
        ++ "\n   but got: "
        ++ show actual

normWs :: Text -> Text
normWs = T.unwords . T.words

withTempDir :: String -> (FilePath -> IO a) -> IO a
withTempDir prefix action = do
  baseTmp <- getTemporaryDirectory
  let dir = baseTmp </> (prefix ++ "-lets-read-spec")
  exists <- doesDirectoryExist dir
  when exists (removeDirectoryRecursive dir)
  createDirectoryIfMissing True dir
  action dir
    `finally` do
      stillExists <- doesDirectoryExist dir
      when stillExists (removeDirectoryRecursive dir)

baseDummyState :: Int -> SessionState
baseDummyState totalChks =
  SessionState
    { stTitle = "The Harbor Lantern"
    , stPersona = "Classic Forum Liveblogger"
    , stMaxWords = 1500
    , stTotalChunks = totalChks
    , stTotalChapters = 12
    , stTotalWords = 15000
    , stCurrentIndex = 1
    , stCurrentRecorded = False
    , stCurrentJudged = False
    , stCurrentMeta = Nothing
    , stCompletedChunks = []
    , stStoryRecords = []
    , stEntryRecords = []
    , stCuratedMemory = defaultCuratedMemory
    , stPredictions = []
    , stRejectedPredictions = []
    , stPendingRetirements = []
    , stPendingLinterWarnings = []
    , stLastJudgeSummary = []
    , stPredictionAuditWarnings = []
    , stCuratedTopics = []
    , stTopicAliases = []
    }

dummyChunk :: Int -> Int -> Int -> Int -> Chunk
dummyChunk idx chap pIn pTotal =
  Chunk
    { chunkIndex = idx
    , chapterNumber = chap
    , chapterTitle = "Chapter " <> T.pack (show chap) <> ": Fog on the Pier"
    , partInChapter = pIn
    , partsInChapter = pTotal
    , isChapterStart = pIn == 1
    , isChapterEnd = pIn == pTotal
    , wordCount = 950
    , chunkText = "Detective Lin stepped onto the foggy pier at dusk. \"Check the manifest,\" she told Mara."
    }
