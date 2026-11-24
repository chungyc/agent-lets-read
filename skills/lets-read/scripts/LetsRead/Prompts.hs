{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LetsRead.Prompts
  ( defaultPersonaText
  , expandPersonaPreset
  , resolvePersonaPresetIO
  , fallbackSkillRefFromExePath
  , resolveSessionFilesRefPathIO
  , renderPredictionSlateNote
  , renderTurnPredictionSection
  , writeCurrentChunkFile
  , writeCurrentScriptPromptFile
  , writeWrapupScriptPromptFile
  , writeCurrentResearchPromptFile
  , writeCurrentPromptFile
  , writeWrapupPromptFile
  , writeCurrentJudgePromptFile
  , writeCurrentFactCheckPromptFile
  , writeCurrentCriticPromptFile
  , writeCurrentTopicPromptFile
  , writeFactCheckDiscussionPromptFile
  , writeUserDiscussionPromptFile
  ) where

import Control.Exception (IOException, catch)
import Data.Char (isDigit, isSpace)
import Data.List (find, sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Chunker (computeShouldRotate)
import LetsRead.Index
  ( checkStorySummaryStructure
  , completedStoryArcRollups
  , partitionVettedTopics
  )
import LetsRead.Predictions
  ( predShortStatusTag
  , renderOriginalPredictionSummary
  , renderRecordActiveLine
  , renderRecordResolvedLine
  , startsWithScreeningFlag
  )
import LetsRead.Types
  ( Chunk (..)
  , ChunkMeta (..)
  , PredictionRecord (..)
  , PredictionStatus (..)
  , ResolutionMeta (..)
  , SessionState (..)
  , StoryChunkRecord (..)
  , isPredActive
  , jsonInt
  , padChunkNumber
  , predActiveScreeningNote
  , predResolutionMeta
  , predStoryResolutionMeta
  , readTextFileSafe
  , resolveSkillResourcePath
  , wrapMarkdownBullet
  , wrapMarkdownParagraph
  , wrapMarkdownQuote
  )
import System.Directory (canonicalizePath, doesFileExist, makeAbsolute)
import System.Environment (getExecutablePath)
import System.FilePath (takeDirectory, takeFileName, (</>))

defaultPersonaText :: Text
defaultPersonaText =
  "Classic Forum Liveblogger — Conversational, observant, witty first-time reader posting live reactions in a forum thread: "
    <> "reacting directly inside the story's moments, talking back to the characters, tracking mysteries, "
    <> "and making bold predictions without lecturing, grading the author, or writing literary essays."

-- | Parse preset headings and their blockquoted voice briefs from references/personas.md
parsePersonasMarkdown :: Text -> [(Text, Text)]
parsePersonasMarkdown raw = go Nothing [] (T.lines raw)
  where
    cleanHeading h =
      let s = T.strip (T.drop 3 (T.stripStart h))
          afterNum = T.dropWhile (\c -> isDigit c || c == '.' || isSpace c) s
          noDefault = fromMaybe afterNum (T.stripSuffix "(Default)" (T.strip afterNum))
       in T.strip noDefault
    cleanQuoteBlock qs =
      let joined = T.unwords [T.strip (T.drop 1 (T.stripStart q)) | q <- qs]
       in T.dropAround (\c -> c == '"' || c == '\x201C' || c == '\x201D') (T.strip joined)
    flush (Just name) qs
      | not (null qs) = [(name, cleanQuoteBlock (reverse qs))]
    flush _ _ = []
    go mName qAcc [] = flush mName qAcc
    go mName qAcc (l : ls)
      | "## " `T.isPrefixOf` T.stripStart l =
          flush mName qAcc ++ go (Just (cleanHeading l)) [] ls
      | ">" `T.isPrefixOf` T.stripStart l =
          go mName (l : qAcc) ls
      | otherwise =
          go mName qAcc ls

matchPersonaFromList :: [(Text, Text)] -> Text -> Maybe Text
matchPersonaFromList presets raw =
  let norm s =
        T.replace " and " " & "
          $ T.replace "\"" "'"
          $ T.toLower (T.unwords (T.words s))
      target = norm raw
      matches (name, brief) =
        let nName = norm name
         in target == nName
              || nName `T.isPrefixOf` target
              || target `T.isInfixOf` nName
              || norm brief == target
   in fmap snd (find matches presets)

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

-- | Resolve a persona name or custom string by reading references/personas.md
-- from the skill package, falling back to expandPersonaPreset.
resolvePersonaPresetIO :: Maybe Text -> IO Text
resolvePersonaPresetIO Nothing = pure defaultPersonaText
resolvePersonaPresetIO (Just raw)
  | T.null (T.strip raw) = pure defaultPersonaText
  | otherwise = do
      personasPath <- resolveSkillResourcePath ("references" </> "personas.md")
      exists <- doesFileExist personasPath
      if not exists
        then pure (expandPersonaPreset raw)
        else do
          content <- readTextFileSafe personasPath
          let presets = parsePersonasMarkdown content
          case matchPersonaFromList presets raw of
            Just matched -> pure matched
            Nothing -> pure (expandPersonaPreset raw)

fallbackSkillRefFromExePath :: FilePath -> FilePath -> Maybe FilePath
fallbackSkillRefFromExePath relRef exePath =
  let binDir = takeDirectory exePath
      skillDir = takeDirectory binDir
   in if takeFileName binDir == ".bin"
        then Just (skillDir </> relRef)
        else Nothing

resolveSessionFilesRefPathIO :: IO FilePath
resolveSessionFilesRefPathIO = do
  let relRef = "references" </> "session-files.md"
  rawPath <- resolveSkillResourcePath relRef
  exists <- doesFileExist rawPath
  if exists
    then canonicalizePath rawPath `catch` (\(_ :: IOException) -> makeAbsolute rawPath)
    else do
      mBinCandidate <-
        ( do
            exePath <- getExecutablePath
            case fallbackSkillRefFromExePath relRef exePath of
              Just cand -> Just <$> makeAbsolute cand
              Nothing -> pure Nothing
        )
          `catch` (\(_ :: IOException) -> pure Nothing)
      case mBinCandidate of
        Just p -> pure p
        Nothing -> makeAbsolute rawPath

renderPredictionSlateNote :: Int -> Int -> Text
renderPredictionSlateNote curIdx totalChunks
  | curIdx >= totalChunks =
      wrapMarkdownParagraph
        78
        "Final story chunk. Focus `=== COMMENTARY ===` on your live reaction to this final story passage (and any prediction verdicts below). Output `- None (story complete!).` in `=== PREDICTION UPDATES ===`."
  | otherwise =
      let curPad = T.pack (padChunkNumber curIdx)
       in wrapMarkdownParagraph
            78
            ( "Log 1 new specific, non-obvious prediction (`<= 550 chars` total; avoid routine continuations, stated plans, and generic placeholders) on this chunk using `- **[Predicted Chunk "
                <> curPad
                <> " | Topics: Topic 1, Topic 2, Topic 3]** **Clue/Anomaly**: <detail, <= 150 chars, no quotes> -> **Theory**: <concrete bet, <= 220 chars> (vs. **Plausible Rival**: <rival explanation, <= 150 chars>)` at the end of `=== COMMENTARY ===` and in `=== PREDICTION UPDATES ===`."
            )

renderTurnPredictionSection :: Bool -> Bool -> Int -> Int -> SessionState -> [Text]
renderTurnPredictionSection isDraftTurn includeSyntaxWarnings curIdx totalChunks st =
  let curPad = T.pack (padChunkNumber curIdx)
      prevIdx = max 1 (curIdx - 1)
      prevPad = T.pack (padChunkNumber prevIdx)
      basePara
        | isDraftTurn && curIdx >= totalChunks =
            wrapMarkdownParagraph
              78
              "Final story chunk. Focus `=== DRAFT COMMENTARY ===` on your live reaction to this final passage (and any prediction verdicts below); omit `=== DRAFT PREDICTION ===` on this final chunk."
        | isDraftTurn =
            wrapMarkdownParagraph
              78
              ( "React naturally in `=== DRAFT COMMENTARY ===` to `current_chunk.md` (and any prediction verdicts below), and include 1 specific, non-obvious candidate prediction in `=== DRAFT PREDICTION ===` (`- **[Predicted Chunk "
                  <> curPad
                  <> " | Topics: Topic 1, Topic 2, Topic 3]** **Clue/Anomaly**: <detail, <= 150 chars, no quotes> -> **Theory**: <concrete bet, <= 220 chars> (vs. **Plausible Rival**: <rival explanation, <= 150 chars>)`)."
              )
        | otherwise =
            renderPredictionSlateNote curIdx totalChunks
      prevResolved =
        [ pr
        | curIdx > 1
        , pr <- stPredictions st
        , Just rm <- [predStoryResolutionMeta pr]
        , rmChunk rm == prevIdx
        ]
      reopenedSummaryLines =
        [ l
        | curIdx > 1
        , l <- stLastJudgeSummary st
        , "Cliffhanger Fake-Out Reversal" `T.isInfixOf` l
        ]
      renderResolvedItem pr =
        let origPad = padChunkNumber (prOriginChunk pr)
            pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
            topLine = wrapMarkdownBullet 78 (renderRecordResolvedLine pr <> " ([details](" <> pPath <> "))")
            origLine = wrapMarkdownBullet 78 ("  - Original prediction — " <> renderOriginalPredictionSummary pr)
         in topLine <> "\n" <> origLine
      verdictsSection =
        if null prevResolved && null reopenedSummaryLines
          then []
          else
            let items = map renderResolvedItem prevResolved ++ map (wrapMarkdownBullet 78) reopenedSummaryLines
             in [ ""
                , "### Prediction Verdicts from Chunk " <> jsonInt prevIdx
                , ""
                , wrapMarkdownParagraph
                    78
                    "Weave your reaction naturally into your commentary where relevant:"
                , ""
                , T.intercalate "\n\n" items
                ]
      flaggedPrevNew =
        case [ (pr, sNote, " -> NOT ADDED")
             | curIdx > 1
             , (pr, sNote) <- stRejectedPredictions st
             , prOriginChunk pr == prevIdx
             ] of
          (hit : _) -> [hit]
          [] ->
            [ (pr, sNote, if isCapRetired then " -> RETIRED (10-Cap)" else " -> NOT ADDED")
            | curIdx > 1
            , pr <- stPredictions st
            , prOriginChunk pr == prevIdx
            , (sNote, isCapRetired) <-
                case prStatus pr of
                  PredStatusActive (Just n)
                    | startsWithScreeningFlag n -> [(n, False)]
                  PredStatusRetired rm
                    | rmChunk rm == prevIdx && startsWithScreeningFlag (rmNote rm) -> [(rmNote rm, True)]
                  _ -> []
            ]
      screeningSection =
        case flaggedPrevNew of
          [] -> []
          ((pr, sNote, statusArrow) : _) ->
            let topLine = wrapMarkdownBullet 78 ("- **[Predicted Chunk " <> prevPad <> statusArrow <> "]** " <> sNote)
                origLine = wrapMarkdownBullet 78 ("  - Previous prediction — " <> renderOriginalPredictionSummary pr)
                introNote =
                  if statusArrow == " -> RETIRED (10-Cap)"
                    then "Your previous prediction was retired at the 10-prediction cap. Apply this calibration silently when staking your new prediction on this turn—never mention screening flags in commentary:"
                    else "Your previous prediction was not added to the active predictions ledger. Apply this calibration silently when staking your new prediction on this turn—never mention screening flags or rejected predictions in commentary:"
             in [ ""
                , "### Prediction Quality Note from Chunk " <> jsonInt prevIdx
                , ""
                , wrapMarkdownParagraph 78 introNote
                , ""
                , topLine <> "\n" <> origLine
                ]
      syntaxSection =
        if not includeSyntaxWarnings || null (stPredictionAuditWarnings st)
          then []
          else
            [ ""
            , "### Prediction Format and Length Warnings"
            , ""
            , wrapMarkdownParagraph
                78
                "Fix the formatting or length issue(s) below when submitting `=== PREDICTION UPDATES ===` on this turn:"
            , ""
            , T.intercalate "\n\n" (stPredictionAuditWarnings st)
            ]
   in [ "## Predictions"
      , ""
      , basePara
      ]
        ++ verdictsSection
        ++ screeningSection
        ++ syntaxSection

renderFinaleVerdictSection :: SessionState -> [Text]
renderFinaleVerdictSection st =
  let totalChunks = stTotalChunks st
      finaleResolved =
        [ pr
        | totalChunks >= 1
        , pr <- stPredictions st
        , Just rm <- [predStoryResolutionMeta pr]
        , rmChunk rm == totalChunks
        ]
      reopenedFinaleLines =
        [ l
        | totalChunks >= 1
        , l <- stLastJudgeSummary st
        , "Cliffhanger Fake-Out Reversal" `T.isInfixOf` l
        ]
      renderItem pr =
        let origPad = padChunkNumber (prOriginChunk pr)
            pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
            topL = wrapMarkdownBullet 78 (renderRecordResolvedLine pr <> " ([details](" <> pPath <> "))")
            origL = wrapMarkdownBullet 78 ("  - Original prediction — " <> renderOriginalPredictionSummary pr)
         in topL <> "\n" <> origL
   in if null finaleResolved && null reopenedFinaleLines
        then []
        else
          let items = map renderItem finaleResolved ++ map (wrapMarkdownBullet 78) reopenedFinaleLines
           in [ ""
              , "## Prediction Verdicts from Chunk " <> jsonInt totalChunks
              , ""
              , T.intercalate "\n\n" items
              ]

writeCurrentChunkFile :: FilePath -> Chunk -> Int -> Int -> IO ()
writeCurrentChunkFile path c totalChunks totalChapters = do
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
      progressLine =
        wrapMarkdownParagraph
          78
          ( "Chunk "
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
          )
      midChapterCallout =
        if isChapterEnd c
          then []
          else
            [ ""
            , "> [!NOTE]"
            , wrapMarkdownQuote
                78
                ( "Mid-chapter split (Part "
                    <> jsonInt (partInChapter c)
                    <> " of "
                    <> jsonInt (partsInChapter c)
                    <> " — this chapter continues in the next chunk. Do not log routine next-part scene continuations as predictions)."
                )
            ]
      header =
        T.unlines $
          [ "<!-- LET'S READ GATEKEEPER: CHUNK " <> jsonInt (chunkIndex c) <> " OF " <> jsonInt totalChunks <> " -->"
          , "# " <> chapterTitle c
          , ""
          , progressLine
          ]
            ++ midChapterCallout
            ++ [ ""
               , "---"
               , ""
               ]
  TIO.writeFile path (header <> chunkText c <> "\n")

extractInlineCriticSection :: Int -> Text -> [Text]
extractInlineCriticSection fromChunkIdx rawFb =
  let ls = T.lines (T.strip rawFb)
      (_, afterHeader) = break (\l -> "## Persona & Style Critique" `T.isPrefixOf` T.stripStart l) ls
      bodyLines =
        case afterHeader of
          (_ : rest) ->
            let untilNextH2 = takeWhile (\l -> not ("## " `T.isPrefixOf` T.stripStart l)) rest
             in reverse (dropWhile (T.null . T.strip) (reverse (dropWhile (T.null . T.strip) untilNextH2)))
          [] -> [l | l <- ls, "- " `T.isPrefixOf` T.stripStart l]
   in if null bodyLines
        then []
        else
          [ ""
          , "## Persona & Style Critique from Chunk " <> jsonInt fromChunkIdx
          , ""
          , wrapMarkdownParagraph 78 "Apply useful voice and craft adjustments silently—never mention or apologize for style critique inside `=== COMMENTARY ===`."
          , ""
          ]
            ++ bodyLines

writeCurrentScriptPromptFile :: FilePath -> SessionState -> Chunk -> IO FilePath
writeCurrentScriptPromptFile sessionDir st chunk = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let criticFeedbackPath = absSession </> "critic_feedback.md"
  hasCriticFeedback <- doesFileExist criticFeedbackPath
  rawCriticFb <-
    if hasCriticFeedback
      then readTextFileSafe criticFeedbackPath
      else pure ""
  let curIdx = chunkIndex chunk
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      inlineCriticLines =
        if hasCriticFeedback
          then extractInlineCriticSection (max 1 (curIdx - 1)) rawCriticFb
          else []
      priorSessionFileLines =
        if curIdx <= 1
          then []
          else
            let prevPad = padChunkNumber (curIdx - 1)
             in [ "- Previous Story Chunk (mandatory read): " <> T.pack (absSession </> "chunks" </> ("chunk_" ++ prevPad ++ ".md"))
                , "- Story Chronological Index (mandatory read): " <> T.pack (absSession </> "chunks" </> "by_chronology.md")
                , "- Commentary Entries Chronological Index (mandatory read): " <> T.pack (absSession </> "entries" </> "by_chronology.md")
                ]
      readListNote =
        if curIdx <= 1
          then "`current_chunk.md` and `memory.md`"
          else
            let prevPadTxt = T.pack (padChunkNumber (curIdx - 1))
             in "`current_chunk.md`, `memory.md`, `chunks/chunk_" <> prevPadTxt <> ".md`, `chunks/by_chronology.md`, and `entries/by_chronology.md`"
      predictionSectionLines = renderTurnPredictionSection True False curIdx totalChunks st
      scriptRespPath = absSession </> "current_script_response.md"
      scriptPromptPath = sessionDir </> "current_script_prompt.md"
      predBulletLines =
        if curIdx >= totalChunks
          then []
          else
            [ ""
            , wrapMarkdownBullet
                78
                ( "   - `=== DRAFT PREDICTION ===` (`- **[Predicted Chunk "
                    <> curPad
                    <> " | Topics: Topic 1, Topic 2, Topic 3]** **Clue/Anomaly**: <detail, <= 150 chars, no quotes> -> **Theory**: <concrete bet, <= 220 chars> (vs. **Plausible Rival**: <rival, <= 150 chars>)`; do not emit `=== CHUNK SUMMARY ===` or `=== UPDATED MEMORY ===`)"
                )
            ]
      sessionFileBullets =
        [ "- Current Chunk File (mandatory read): " <> T.pack (absSession </> "current_chunk.md")
        , "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
        ]
          ++ priorSessionFileLines
          ++ [ "- Session Directory (optional `read_file` inside `<session_dir>`): " <> T.pack absSession
             , "- Session File & Index Reference (optional `read_file`): " <> T.pack sessionFilesRefPath
             , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack scriptRespPath
             ]
      promptText =
        T.unlines $
          [ "# Script Draft Turn Prompt — Chunk " <> jsonInt curIdx <> " of " <> jsonInt totalChunks
          , ""
          , wrapMarkdownParagraph
              78
              ( "Please read the newly unlocked passage (Chunk "
                  <> jsonInt curIdx
                  <> " of "
                  <> jsonInt totalChunks
                  <> ") and write your spontaneous first-pass draft reaction in the Active Persona."
              )
          , ""
          , "## Session Files"
          , ""
          , T.intercalate "\n\n" (map (wrapMarkdownBullet 78) sessionFileBullets)
          , ""
          , "## Active Persona"
          , ""
          , wrapMarkdownParagraph 78 (expandPersonaPreset (stPersona st))
          , ""
          ]
            ++ predictionSectionLines
            ++ inlineCriticLines
            ++ [ ""
               , "## Turn Output Contract"
               , ""
               , wrapMarkdownBullet
                   78
                   ("1. Read " <> readListNote <> " in parallel via `read_file` (applying any `## Persona & Style Critique` notes silently).")
               , ""
               , wrapMarkdownBullet
                   78
                   ( "2. Write line 1 as `<!-- TOOLS: read_file(...) -->` followed by your draft sections to `"
                       <> T.pack scriptRespPath
                       <> "` via `write_file` (`Overwrite: true`):"
                   )
               , ""
               , wrapMarkdownBullet
                   78
                   "   - `=== DRAFT COMMENTARY ===` (react in your Active Persona with 3–5 tight `>` blockquotes from `current_chunk.md`, weaving natural callbacks, running gags, character reads, prediction reactions, and external canon comparisons)"
               ]
            ++ predBulletLines
            ++ [ ""
               , wrapMarkdownBullet
                   78
                   "3. Once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice ending with `[Tools: read_file(...)]` and no tool calls (do not call `send_message` or re-read files, and never paste your draft into your message)."
               ]
  TIO.writeFile scriptPromptPath promptText
  pure scriptPromptPath

writeWrapupScriptPromptFile :: FilePath -> SessionState -> IO FilePath
writeWrapupScriptPromptFile sessionDir st = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let criticFeedbackPath = absSession </> "critic_feedback.md"
  hasCriticFeedback <- doesFileExist criticFeedbackPath
  rawCriticFb <-
    if hasCriticFeedback
      then readTextFileSafe criticFeedbackPath
      else pure ""
  let totalChunks = stTotalChunks st
      finaleVerdictLines = renderFinaleVerdictSection st
      inlineCriticLines =
        if hasCriticFeedback
          then extractInlineCriticSection totalChunks rawCriticFb
          else []
      scriptRespPath = absSession </> "current_script_response.md"
      scriptPromptPath = sessionDir </> "current_script_prompt.md"
      sessionFileBullets =
        [ "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
        , "- Prediction Hall of Fame & Shame (mandatory read): " <> T.pack (absSession </> "predictions" </> "hall_of_fame.md")
        , "- Story Chronological Index (mandatory read): " <> T.pack (absSession </> "chunks" </> "by_chronology.md")
        , "- Commentary Entries Chronological Index (mandatory read): " <> T.pack (absSession </> "entries" </> "by_chronology.md")
        , "- Session Directory (optional `read_file` inside `<session_dir>`): " <> T.pack absSession
        , "- Session File & Index Reference (optional `read_file`): " <> T.pack sessionFilesRefPath
        , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack scriptRespPath
        ]
      promptText =
        T.unlines $
          [ "# Final Wrapup Script Draft Prompt — " <> stTitle st
          , ""
          , wrapMarkdownParagraph
              78
              ( "All "
                  <> jsonInt totalChunks
                  <> " story chunks of *"
                  <> stTitle st
                  <> "* have been read and judged! Please write your spontaneous first-pass Final Wrapup & Retrospective draft in the Active Persona."
              )
          , ""
          , "## Session Files"
          , ""
          , T.intercalate "\n\n" (map (wrapMarkdownBullet 78) sessionFileBullets)
          , ""
          , "## Active Persona"
          , ""
          , wrapMarkdownParagraph 78 (expandPersonaPreset (stPersona st))
          ]
            ++ finaleVerdictLines
            ++ inlineCriticLines
            ++ [ ""
               , "## Turn Output Contract"
               , ""
               , wrapMarkdownBullet
                   78
                   "1. Read `memory.md`, `predictions/hall_of_fame.md`, `chunks/by_chronology.md`, and `entries/by_chronology.md` in parallel via `read_file`."
               , ""
               , wrapMarkdownBullet
                   78
                   ( "2. Write line 1 as `<!-- TOOLS: read_file(memory.md, predictions/hall_of_fame.md, chunks/by_chronology.md, entries/by_chronology.md) -->` followed by `=== DRAFT COMMENTARY ===` (covering finale verdicts, whole-story & character retrospective, prediction scoreboard highlights/misses, and running gags/sign-off in your Active Persona; omit `=== DRAFT PREDICTION ===`, `=== CHUNK SUMMARY ===`, and `=== UPDATED MEMORY ===`) to `"
                       <> T.pack scriptRespPath
                       <> "` via `write_file` (`Overwrite: true`)."
                   )
               , ""
               , wrapMarkdownBullet
                   78
                   "3. Once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice ending with `[Tools: read_file(...)]` and no tool calls."
               ]
  TIO.writeFile scriptPromptPath promptText
  pure scriptPromptPath

writeCurrentResearchPromptFile :: FilePath -> SessionState -> Bool -> Text -> IO FilePath
writeCurrentResearchPromptFile sessionDir st isWrapup strippedDraft = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let curIdx = stCurrentIndex st
      curPadTxt = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      researchPromptPath = sessionDir </> "current_research_prompt.md"
      researchRespPath = absSession </> "current_research_response.md"
      titleLine =
        if isWrapup
          then "# Research Turn Prompt — Final Wrapup (" <> stTitle st <> ")"
          else "# Research Turn Prompt — Chunk " <> jsonInt curIdx <> " of " <> jsonInt totalChunks
      introLine =
        if isWrapup
          then
            wrapMarkdownParagraph
              78
              "Please collect receipt-backed primary-source story excerpts, prior commentary/discussion excerpts, exact original prediction wordings, and verified external canon notes relevant to the internal Final Wrapup draft below."
          else
            wrapMarkdownParagraph
              78
              ( "Please collect receipt-backed primary-source story excerpts, prior commentary/discussion excerpts, prediction records, and verified external canon notes relevant to the internal draft reaction for Chunk "
                  <> jsonInt curIdx
                  <> " of "
                  <> jsonInt totalChunks
                  <> " below."
              )
      mandatoryFiles =
        if isWrapup
          then
            [ "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
            , "- Prediction Hall of Fame & Shame (mandatory read): " <> T.pack (absSession </> "predictions" </> "hall_of_fame.md")
            ]
          else
            [ "- Current Story Chunk (`chunks/chunk_" <> curPadTxt <> ".md` — mandatory read): " <> T.pack (absSession </> "current_chunk.md")
            , "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
            ]
      step1Reads =
        if isWrapup
          then "`memory.md` and `predictions/hall_of_fame.md`"
          else "`current_chunk.md` and `memory.md`"
      sessionFileBullets =
        ["- Session Directory: `" <> T.pack absSession <> "`"]
          ++ mandatoryFiles
          ++ [ "- Story Chunks & Topic/Chronology Indexes (on-demand `read_file`): " <> T.pack (absSession </> "chunks")
             , "- Prior Commentary Entries & Indexes (on-demand `read_file`): " <> T.pack (absSession </> "entries")
             , "- Predictions & Indexes (on-demand `read_file`): " <> T.pack (absSession </> "predictions")
             , "- Historical Memory Snapshots (on-demand `read_file`): " <> T.pack (absSession </> "archive" </> "memory")
             , "- Session File & Index Reference (optional on-demand `read_file`): " <> T.pack sessionFilesRefPath
             , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack researchRespPath
             ]
      promptText =
        T.unlines $
          [ titleLine
          , ""
          , introLine
          , ""
          , "## Session Files"
          , ""
          , T.intercalate "\n\n" (map (wrapMarkdownBullet 78) sessionFileBullets)
          , ""
          , "## Internal Draft Reaction (Quarantined — NEVER Mention in Output)"
               , ""
               , wrapMarkdownParagraph
                   78
                   "`blind-reader` is completely blind to this draft. NEVER mention or allude to `script-writer`, 'the draft', or 'the script' in your output—write neutral background reference notes only."
               , ""
               , "~~~~~markdown"
               , T.strip strippedDraft
               , "~~~~~"
               , ""
               , "## Turn Output Contract"
               , ""
               , wrapMarkdownBullet
                   78
                   ( "1. Read "
                       <> step1Reads
                       <> " (and call `read_file` in THIS turn on every `chunks/`, `entries/`, `predictions/`, or `archive/memory/` file you cite, listing all of them in `<!-- TOOLS: ... -->`). Pull ALL relevant material suggested by the internal draft above across every applicable category—earlier story passages (`chunks/chunk_XXXX.md`, including `chunk_(N-1).md` and verifying any elapsed-time spans or chapter-count claims against `chunks/by_chronology.md` and `chunks/chunk_XXXX.md`), prior Let's Read commentary entries, gags, discussions, or memory snapshots (`entries/chunk_XXXX.md`, `archive/memory/`), prior predictions (`predictions/pred_XXXX.md`, ONLY when the draft explicitly recalls or questions an earlier prediction/verdict, or on the Final Wrapup Round—do NOT sweep `predictions/by_topic.md` merely because a character or location appears in the scene), and external canon or real-world/literary reference works via neutral, non-spoiler `search_web` queries (never searching for the specific story being read)—including pulling the actual passage or canon fact when the draft misremembered a detail or substituted fanon. Keep the story-factual hierarchy explicit: explicit story text (`current_chunk.md`, `chunks/chunk_XXXX.md`, and Bullet 1 of `memory.md`) always takes precedence over external sources and canon regarding facts about this story itself; `search_web` establishes only what the external work states (explicitly note whenever a canon date, full name, or detail is unstated in the story text so far); and `predictions/`, `entries/`, and `archive/memory/` record earlier reader bets, reactions, and discussions rather than primary story fact."
                   )
               , ""
               , wrapMarkdownBullet
                   78
                   ( "2. Write line 1 as `<!-- TOOLS: read_file(...) -->` (adding `, search_web` only if invoked) followed by `=== RESEARCH NOTES ===` (`<= 80 lines`; output `- NONE` only if nothing beyond `current_chunk.md` is relevant) to `"
                       <> T.pack researchRespPath
                       <> "` via `write_file` (`Overwrite: true`) using receipt-backed bullets:"
                   )
               , ""
               , T.intercalate
                   "\n\n"
                   ( map
                       (wrapMarkdownBullet 78)
                       [ "   - `- **[Earlier Story Passage | Source: chunks/chunk_XXXX.md | Quote: \"<verbatim substring>\"]** <1-2 neutral authoritative in-story context sentences>`"
                       , "   - `- **[Prior Session Entry | Source: entries/chunk_XXXX.md | Quote: \"<verbatim substring>\"]** <1-2 neutral sentences on prior reader reaction/gag/discussion (or archive/memory/curated_XXXX.md for memory snapshots)>`"
                       , "   - `- **[Prior Prediction | Source: predictions/pred_XXXX.md | Quote: \"<verbatim substring>\"]** <1-2 neutral sentences on exact original bet and status/ruling>`"
                       , "   - `- **[External Canon / Reference | Source: search_web(\"<neutral query>\") | Work: ...]** <1-2 neutral sentences on what the external work establishes, subordinate to explicit story text>`"
                       ]
                   )
               , ""
               , wrapMarkdownBullet
                   78
                   "3. Once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice ending with `[Tools: read_file(...)]` (adding `, search_web` only if invoked) and no tool calls (do not call `send_message` or re-read files)."
               ]
  TIO.writeFile researchPromptPath promptText
  pure researchPromptPath

writeCurrentPromptFile :: FilePath -> SessionState -> Chunk -> IO FilePath
writeCurrentPromptFile sessionDir st chunk = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let criticFeedbackPath = absSession </> "critic_feedback.md"
  hasCriticFeedback <- doesFileExist criticFeedbackPath
  rawCriticFb <-
    if hasCriticFeedback
      then readTextFileSafe criticFeedbackPath
      else pure ""
  let curIdx = chunkIndex chunk
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      predictionSectionLines = renderTurnPredictionSection False True curIdx totalChunks st
      inlineCriticLines =
        if hasCriticFeedback
          then extractInlineCriticSection (max 1 (curIdx - 1)) rawCriticFb
          else []
      priorStory = [e | e <- stStoryRecords st, scrChunkIndex e < curIdx]
      shouldRotate = computeShouldRotate priorStory chunk
      isMidChapter = partInChapter chunk > 1
      prevContextLines =
        if curIdx <= 1
          then []
          else
            let prevPad = padChunkNumber (curIdx - 1)
                prevPathTxt = T.pack (absSession </> "chunks" </> ("chunk_" ++ prevPad ++ ".md"))
             in [ "- Previous Story Chunk: " <> prevPathTxt ]
      continuitySection =
        if curIdx <= 1
          then []
          else
            let prevPadTxt = T.pack (padChunkNumber (curIdx - 1))
                continuityMsg =
                  if shouldRotate || isMidChapter
                    then
                      "Mandatory continuity read on this turn ("
                        <> (if shouldRotate && isMidChapter then "rotated reader + mid-chapter split" else if shouldRotate then "rotated reader" else "mid-chapter split")
                        <> "): call `read_file` on `chunks/chunk_"
                        <> prevPadTxt
                        <> ".md` BEFORE calling `write_file`."
                    else
                      "If this is your first turn in a newly spawned conversation, call `read_file` on `chunks/chunk_"
                        <> prevPadTxt
                        <> ".md` BEFORE calling `write_file`."
             in [ ""
                , "### Previous Chunk Continuity"
                , ""
                , wrapMarkdownParagraph 78 continuityMsg
                ]
      completedArcs = completedStoryArcRollups (stStoryRecords st)
      mSummaryStructWarn = checkStorySummaryStructure (stCuratedMemory st) completedArcs
      summaryAlertSection =
        case mSummaryStructWarn of
          Nothing -> []
          Just warnTxt ->
            [ ""
            , "### Story Summary Compaction Alert"
            , ""
            , wrapMarkdownParagraph 78 warnTxt
            ]
      step1PrevNote =
        if curIdx <= 1
          then ""
          else
            let prevPadTxt = T.pack (padChunkNumber (curIdx - 1))
             in if shouldRotate || isMidChapter
                  then " Call `read_file` on `chunks/chunk_" <> prevPadTxt <> ".md` BEFORE writing your response."
                  else " If newly spawned in this conversation, also call `read_file` on `chunks/chunk_" <> prevPadTxt <> ".md` before writing."
      commentaryPredictionSuffix =
        if curIdx >= totalChunks
          then "; since this is the final chunk, do not propose a new prediction"
          else ", and end with `- **[Predicted Chunk " <> curPad <> " | Topics: Topic 1, Topic 2, Topic 3]** ...`"
      predictionUpdatesBody =
        if curIdx >= totalChunks
          then "Output `- None (story complete!).` on this final chunk (`prediction-judge` still evaluates prior predictions against this chunk)"
          else "`- **[Predicted Chunk " <> curPad <> " | Topics: ...]** **Clue/Anomaly**: <detail, <= 150 chars, no quotes> -> **Theory**: <concrete bet, <= 220 chars> (vs. **Plausible Rival**: <rival, <= 150 chars>)` (`<= 550 chars` total)"
      updatedMemoryBody =
        if curIdx >= totalChunks
          then "the 4 narrative sections only; keep Bullet 1 (`Core Premise, Timeline & Baseline Facts (Persistent)`) accurate, collapse completed `Arc K` rollups, and clear resolved mysteries in `Active Mysteries & Unanswered Questions` with `- None (story complete).` unless genuine open-ended mysteries remain"
          else "the 4 narrative sections only; update Bullet 1 (`Core Premise, Timeline & Baseline Facts (Persistent)`) whenever new setting/timeline milestones or adaptation divergences (if applicable) are established, collapse completed `L1` `Arc K` rollups to 1 bullet each, and keep current-arc completed chapters consolidated to 1–2 bullets max"
      promptPath = sessionDir </> "current_prompt.md"
      introPara =
        wrapMarkdownParagraph
          78
          ( "Please read the newly unlocked chunk (Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> ") and write your Let's Read entry."
          )
      step1Line =
        wrapMarkdownBullet
          78
          ( "1. Read `current_chunk.md`, `memory.md`, and `current_research.md` (applying any critique or calibration notes above silently, using `current_research.md` selectively where relevant without forcing callbacks, and anchoring covered callbacks/canon details in its verified excerpts/notes)."
              <> step1PrevNote
              <> " Whenever quoting, counting, or building a prediction premise (`**Clue/Anomaly**`) on an earlier chunk not verbatim in `current_chunk.md` or `current_research.md`, call `read_file` on `chunks/chunk_XXXX.md` (never rely on `memory.md` alone); when referencing an earlier prediction/ruling not shown above or in `current_research.md`, check `predictions/by_topic.md` or `predictions/by_chronology.md`. Connecting external canon, comparing adaptations, and predicting canon elements is welcomed—verify specific external lore not already covered in `current_research.md` via neutral `search_web` queries (never searching for spoilers of this specific story) and keep explicit in-story facts distinct when the story diverges from canon."
          )
      step2Line =
        wrapMarkdownBullet
          78
          ( "2. Write line 1 as `<!-- TOOLS: read_file(current_chunk.md, memory.md, current_research.md, ...) -->` (adding `, search_web` only if invoked) followed by all four required sections using exact headers to `"
              <> T.pack (absSession </> "current_reader_response.md")
              <> "` via `write_file` (`Overwrite: true`):"
          )
      secBullets =
        T.intercalate
          "\n\n"
          ( map
              (wrapMarkdownBullet 78)
              [ "   - `=== COMMENTARY ===` (react in your Active Persona with 3–5 tight `>` blockquotes, weaving reactions to any prediction verdicts shown above" <> commentaryPredictionSuffix <> ")"
              , "   - `=== CHUNK SUMMARY ===` (`- **[Story | Topics: ...]** <1-line factual in-story summary, <= 250 chars>` and `- **[Entry | Topics: ...]** <1-line reaction/gag summary, <= 250 chars>`; reuse accurate `Established Topic Tags` and coin clean canonical tags only when genuinely distinct recurring characters, factions, locations, or plot threads emerge)"
              , "   - `=== PREDICTION UPDATES ===` (" <> predictionUpdatesBody <> ")"
              , "   - `=== UPDATED MEMORY ===` (" <> updatedMemoryBody <> ")"
              ]
          )
      step3Line =
        wrapMarkdownBullet
          78
          "3. Once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice ending with `[Tools: read_file(current_chunk.md, memory.md, current_research.md, ...)]` (adding `, search_web` only if invoked) and no tool calls (do not call `send_message` or re-read files, and never paste the sections into your message)."
      readerSessionBullets =
        [ "- Current Chunk File (mandatory read): " <> T.pack (absSession </> "current_chunk.md")
        , "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
        , "- Pre-Pulled Reference Packet (mandatory read): " <> T.pack (absSession </> "current_research.md")
        , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack (absSession </> "current_reader_response.md")
        ]
          ++ prevContextLines
          ++ [ "- Story Chunks Directory (on-demand `read_file`): " <> T.pack (absSession </> "chunks")
             , "- Session Directory (on-demand `entries/` & `predictions/`): " <> T.pack absSession
             , "- Session File & Index Reference (optional on-demand `read_file`): " <> T.pack sessionFilesRefPath
             ]
      promptText =
        T.unlines $
          [ "# Reading Turn Prompt — Chunk " <> jsonInt curIdx <> " of " <> jsonInt totalChunks
          , ""
          , introPara
          , ""
          , "## Session Files"
          , ""
          , T.intercalate "\n\n" (map (wrapMarkdownBullet 78) readerSessionBullets)
          ]
            ++ continuitySection
            ++ [ ""
               , "## Active Persona"
               , ""
               , wrapMarkdownParagraph 78 (expandPersonaPreset (stPersona st))
               , ""
               ]
            ++ predictionSectionLines
            ++ summaryAlertSection
            ++ inlineCriticLines
            ++ [ ""
               , "## Turn Output Contract"
               , ""
               , step1Line
               , ""
               , step2Line
               , ""
               , secBullets
               , ""
               , step3Line
               ]
  TIO.writeFile promptPath promptText
  pure promptPath

writeWrapupPromptFile :: FilePath -> SessionState -> IO FilePath
writeWrapupPromptFile sessionDir st = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let criticFeedbackPath = absSession </> "critic_feedback.md"
  hasCriticFeedback <- doesFileExist criticFeedbackPath
  rawCriticFb <-
    if hasCriticFeedback
      then readTextFileSafe criticFeedbackPath
      else pure ""
  let totalChunks = stTotalChunks st
      finaleVerdictLines = renderFinaleVerdictSection st
      inlineCriticLines =
        if hasCriticFeedback
          then extractInlineCriticSection totalChunks rawCriticFb
          else []
      extraContextLines = finaleVerdictLines ++ inlineCriticLines
      criticContext =
        if null extraContextLines
          then ""
          else "\n\n" <> T.strip (T.unlines extraContextLines)
      promptPath = sessionDir </> "current_prompt.md"
      collapseBlankLines txt =
        if "\n\n\n" `T.isInfixOf` txt
          then collapseBlankLines (T.replace "\n\n\n" "\n\n" txt)
          else txt
  tmplPath <- resolveSkillResourcePath ("resources" </> "wrapup_prompt_template.md")
  hasTmpl <- doesFileExist tmplPath
  rawTmpl <-
    if hasTmpl
      then readTextFileSafe tmplPath
      else
        pure $
          T.unlines
            [ "# Final Wrapup & Retrospective Prompt — {{TITLE}}"
            , ""
            , "All {{TOTAL_CHUNKS}} story chunks of *{{TITLE}}* have been read!"
            , "Please write your dedicated Final Wrapup & Retrospective."
            , ""
            , "## Session Files"
            , ""
            , "- Reader Memory File (mandatory read): {{MEMORY_FILE}}"
            , "- Prediction Hall of Fame & Shame (mandatory read): {{HALL_OF_FAME_FILE}}"
            , "- Pre-Pulled Reference Packet (mandatory read): {{RESEARCH_FILE}}"
            , "- Session File & Index Reference (optional on-demand `read_file`): {{SESSION_FILES_REF}}"
            , "- Output Response File (mandatory `write_file`, `Overwrite: true`): {{READER_RESPONSE_FILE}}"
            , ""
            , "## Active Persona"
            , ""
            , "{{ACTIVE_PERSONA}}"
            , ""
            , "{{CRITIC_CONTEXT}}"
            , ""
            , "## Final Wrapup Instructions"
            , ""
            , wrapMarkdownParagraph 78 "Read `memory.md`, `predictions/hall_of_fame.md`, and `current_research.md` (verifying exact original `**Clue/Anomaly**` and `**Theory**` wording and full-story timeline progression rather than reconstructing from memory), write line 1 as `<!-- TOOLS: read_file(...) -->` followed by `=== COMMENTARY ===` covering finale verdicts, whole-story retrospective, prediction scoreboard retrospective, and closing sign-off to `{{READER_RESPONSE_FILE}}` via `write_file` (`Overwrite: true`), and once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice ending with `[Tools: read_file(memory.md, predictions/hall_of_fame.md, current_research.md, ...)]` and no tool calls (do not call `send_message` or re-read files)."
            ]
  let substitutions =
        [ ("{{TOTAL_CHUNKS}}", jsonInt totalChunks)
        , ("{{TITLE}}", stTitle st)
        , ("{{SESSION_DIR}}", T.pack absSession)
        , ("{{MEMORY_FILE}}", T.pack (absSession </> "memory.md"))
        , ("{{HALL_OF_FAME_FILE}}", T.pack (absSession </> "predictions" </> "hall_of_fame.md"))
        , ("{{RESEARCH_FILE}}", T.pack (absSession </> "current_research.md"))
        , ("{{READER_RESPONSE_FILE}}", T.pack (absSession </> "current_reader_response.md"))
        , ("{{CRITIC_CONTEXT}}", criticContext)
        , ("{{CHUNKS_DIR}}", T.pack (absSession </> "chunks"))
        , ("{{ENTRIES_DIR}}", T.pack (absSession </> "entries"))
        , ("{{PREDICTIONS_DIR}}", T.pack (absSession </> "predictions"))
        , ("{{ARCHIVE_DIR}}", T.pack (absSession </> "archive"))
        , ("{{SESSION_FILES_REF}}", T.pack sessionFilesRefPath)
        , ("{{ACTIVE_PERSONA}}", wrapMarkdownParagraph 78 (expandPersonaPreset (stPersona st)))
        ]
      rendered = T.strip (collapseBlankLines (foldr (\(k, v) acc -> T.replace k v acc) rawTmpl substitutions)) <> "\n"
  TIO.writeFile promptPath rendered
  pure promptPath

writeCurrentJudgePromptFile :: FilePath -> SessionState -> IO FilePath
writeCurrentJudgePromptFile sessionDir st = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let curIdx = stCurrentIndex st
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      preds = stPredictions st
      activePreds = [pr | pr <- preds, isPredActive pr]
      needRetire = max 0 (length activePreds - 10)
      recentResolved =
        [ pr
        | pr <- preds
        , Just rm <- [predStoryResolutionMeta pr]
        , let resC = rmChunk rm
        , resC < curIdx && resC >= max 1 (curIdx - 2)
        ]
      activeBlock =
        if null activePreds
          then "- *(No active predictions to evaluate on this chunk.)*"
          else
            let hasAnyScreening = any (\pr -> case predActiveScreeningNote pr of Just _ -> True; Nothing -> False) activePreds
                sep = if hasAnyScreening then "\n\n" else "\n"
                renderOne pr =
                  let origIdx = prOriginChunk pr
                      origPad = padChunkNumber origIdx
                      pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
                      isUnjudgedProposal = stCurrentRecorded st && not (stCurrentJudged st) && origIdx == curIdx
                      detailSuffix =
                        if isUnjudgedProposal
                          then ""
                          else " ([details](" <> pPath <> "))"
                      baseLine = wrapMarkdownBullet 78 (renderRecordActiveLine pr <> detailSuffix)
                   in case predActiveScreeningNote pr of
                        Nothing -> baseLine
                        Just sNote ->
                          baseLine
                            <> "\n"
                            <> wrapMarkdownBullet 78 ("  - *Prior screening*: " <> sNote)
             in T.intercalate sep (map renderOne activePreds)
      priorNonActive =
        let ledgerClosed =
              [ ( maybe (prOriginChunk pr) rmChunk (predResolutionMeta pr)
                , prOriginChunk pr
                , predShortStatusTag pr
                , if T.null (prTheory pr) then prRawBody pr else prTheory pr
                )
              | pr <- preds
              , not (isPredActive pr)
              , prOriginChunk pr < curIdx
              ]
            priorRejected =
              [ ( prOriginChunk pr
                , prOriginChunk pr
                , "NOT ADDED"
                , if T.null (prTheory pr) then prRawBody pr else prTheory pr
                )
              | (pr, _) <- stRejectedPredictions st
              , prOriginChunk pr < curIdx
              ]
            combined = sortOn (\(closedIdx, origIdx, _, _) -> (closedIdx, origIdx)) (ledgerClosed ++ priorRejected)
         in [ (origIdx, tagTxt, theoryTxt)
            | (_, origIdx, tagTxt, theoryTxt) <- drop (max 0 (length combined - 12)) combined
            ]
      priorThesesSection =
        if null priorNonActive
          then []
          else
            [ ""
            , "## Prior Non-Active Theses (Do Not Re-Admit Recycled Variations)"
            , ""
            , wrapMarkdownParagraph
                78
                "Use `[DUPLICATE-THESIS]` (`-> NOT ADDED`) if the new prediction recycles a previously resolved, retired, or rejected thesis below without a genuinely new mechanism:"
            , ""
            ]
              ++ [ wrapMarkdownBullet
                     78
                     ( "- Chunk "
                         <> T.pack (padChunkNumber origIdx)
                         <> " ("
                         <> tagTxt
                         <> "): "
                         <> theoryTxt
                     )
                 | (origIdx, tagTxt, theoryTxt) <- priorNonActive
                 ]
      conditionalRetireSection =
        if needRetire <= 0
          then []
          else
            [ ""
            , "### Conditional 10-Cap Retirement (" <> jsonInt (length activePreds) <> " Active -> Nominate " <> jsonInt needRetire <> ")"
            , ""
            , wrapMarkdownParagraph
                78
                ( "Because "
                    <> jsonInt (length activePreds)
                    <> " predictions are currently listed (above the 10-slot cap), first evaluate EVERY prediction strictly on the merits in `=== PREDICTION JUDGMENTS ===` (using `-> NOT ADDED` if Chunk "
                    <> curPad
                    <> "'s new proposal fails screening, and never using `RETIRED` as a substitute for `DEBUNKED` when a stated trigger expired), and then append `=== CONDITIONAL RETIREMENTS ===` nominating "
                    <> jsonInt needRetire
                    <> " candidate(s) from the remaining active bets using `- **[Predicted Chunk XXXX -> RETIRED Chunk "
                    <> curPad
                    <> "]** <1-line reason, <= 200 chars>`. Prioritize mooted/overtaken subplot bets, narrower local-scene bets, or legacy `[DUPLICATE-THESIS]` / `[UNINTERESTING]` bets—never retire central-mystery or core-arc theories while narrower or mooted bets remain (`LetsRead` applies conditional retirements only if >10 remain `ACTIVE` after merit rulings and `NOT ADDED` exclusions)."
                )
            ]
      recentLines =
        if null recentResolved
          then []
          else
            [ ""
            , "## Recently Resolved Predictions"
            , ""
            , wrapMarkdownParagraph 78 "Emit an updated verdict for a recently resolved prediction below ONLY if `current_chunk.md` reveals a cliffhanger fake-out reversal:"
            , ""
            ]
              ++ [ let origPad = padChunkNumber (prOriginChunk pr)
                       pPath = T.pack ("predictions" </> ("pred_" ++ origPad ++ ".md"))
                    in renderRecordResolvedLine pr <> " ([details](" <> pPath <> "))"
                 | pr <- recentResolved
                 ]
      midSplitSection =
        case stCurrentMeta st of
          Just m
            | metaPartInChapter m < metaPartsInChapter m ->
                [ ""
                , "### Mid-Chapter Split Context"
                , ""
                , wrapMarkdownParagraph
                    78
                    ( "Chunk "
                        <> jsonInt curIdx
                        <> " is Part "
                        <> jsonInt (metaPartInChapter m)
                        <> " of "
                        <> jsonInt (metaPartsInChapter m)
                        <> " of its chapter. Reject routine, predictable next-part continuations on `Predicted Chunk "
                        <> curPad
                        <> " -> NOT ADDED` with `[UNINTERESTING]` (do not reject genuinely surprising or non-obvious predictions solely because they could resolve soon)."
                    )
                ]
          _ -> []
      judgePromptPath = sessionDir </> "current_judge_prompt.md"
      judgeRespPath = absSession </> "current_judge_response.md"
      judgePromptText =
        T.unlines $
          [ "# Prediction Judge Prompt — Chunk " <> jsonInt curIdx <> " of " <> jsonInt totalChunks
          , ""
          , wrapMarkdownParagraph
              78
              ( "Please evaluate all currently active predictions (and screen any newly proposed prediction) against Chunk "
                  <> jsonInt curIdx
                  <> " of "
                  <> jsonInt totalChunks
                  <> "."
              )
          , ""
          , "## Session Files"
          , ""
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File (mandatory context read): " <> T.pack (absSession </> "memory.md")
          , "- Predictions Directory (optional on-demand `read_file`): " <> T.pack (absSession </> "predictions")
          , "- Session File & Index Reference (optional on-demand `read_file`): " <> T.pack sessionFilesRefPath
          , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack judgeRespPath
          ]
            ++ midSplitSection
            ++ [ ""
               , "## Active Predictions to Judge on Chunk " <> curPad <> " (" <> jsonInt (length activePreds) <> " Listed)"
               , ""
               , activeBlock
               ]
            ++ recentLines
            ++ priorThesesSection
            ++ [ ""
               , "## Turn Output Contract"
               , ""
               , wrapMarkdownParagraph
                   78
                   ( "Read `current_chunk.md` and `memory.md`, and write `=== PREDICTION JUDGMENTS ===` with one bullet per listed prediction (`[Predicted Chunk XXXX -> ACTIVE]`, `[Predicted Chunk "
                       <> curPad
                       <> " -> NOT ADDED]` when screening out Chunk "
                       <> curPad
                       <> "'s new proposal, `CONFIRMED Chunk "
                       <> curPad
                       <> "`, `DEBUNKED Chunk "
                       <> curPad
                       <> "`, or `SUBVERTED Chunk "
                       <> curPad
                       <> "`; `<= 200 chars` per bullet) to `"
                       <> T.pack judgeRespPath
                       <> "` via `write_file` (`Overwrite: true`)."
                   )
               , ""
               , "### Event-Trigger and Window Expiry"
               , ""
               , wrapMarkdownParagraph
                   78
                   ( "If an active `**Theory**` ties its outcome to a specific stated event or chapter window and `current_chunk.md` unambiguously completes and moves past that trigger without the predicted effect occurring, rule it `DEBUNKED Chunk "
                       <> curPad
                       <> "` promptly rather than holding it `ACTIVE`."
                   )
               , ""
               , "### Interestingness and Admission Screening on Newly Logged Predictions"
               , ""
               , wrapMarkdownParagraph
                   78
                   ( "Admit `Predicted Chunk "
                       <> curPad
                       <> "` to the active ledger (`-> ACTIVE`) ONLY if it stakes a genuinely non-obvious, specific, falsifiable claim strictly from unlocked text and `memory.md`—with NO unflagged pass for safe, expected, or telegraphed bets. Whenever a defect applies, output `- **[Predicted Chunk "
                       <> curPad
                       <> " -> NOT ADDED]** <flag> <reason>` (`<= 200 chars`, returned to `blind-reader` as feedback only and excluded from active predictions): `[UNINTERESTING]` for expected, telegraphed, or default-trajectory bets—completing a character's stated plan, project, itinerary, or expressed wish; relabeling an ability, anomaly, or dynamic already shown on-page; routine scene/cliffhanger continuations; generic placeholders; or stock genre/relationship/career reflexes (such as a secrecy pact being breached, initial pushback before embrace, a partner tribute, an estranged figure resurfacing, or routine healing/atonement), even when packaged by pairing two explicit facts across chunks (never rejecting a genuinely surprising call solely because it comes from one subtle tell or could resolve soon); `[UNGROUNDED]` for arbitrary non-sequiturs (never penalizing story-coherent long-shots or external-canon hooks); `[DUPLICATE-THESIS]` when duplicating an active or prior thesis (naming `Chunk XXXX`); or `[HEDGED]` / `[VAGUE]` for probability hedging, multi-option menu bets (`X, Y, or Z` covering distinct actors, channels, or payoffs), or Barnum vagueness."
                   )
               ]
            ++ conditionalRetireSection
            ++ [ ""
               , "### Completion Notice"
               , ""
               , wrapMarkdownParagraph
                   78
                   "Once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice and no tool calls (do not call `send_message` or re-read files)."
               ]
  TIO.writeFile judgePromptPath judgePromptText
  pure judgePromptPath

writeCurrentFactCheckPromptFile :: FilePath -> SessionState -> Text -> Text -> IO FilePath
writeCurrentFactCheckPromptFile sessionDir st storySumTxt entrySumTxt = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let curIdx = stCurrentIndex st
      curPad = padChunkNumber curIdx
      curPadTxt = T.pack curPad
      totalChunks = stTotalChunks st
      entryPath = absSession </> "entries" </> ("chunk_" ++ curPad ++ ".md")
      factRespPath = absSession </> "current_fact_check_response.md"
      mNewPred = listToMaybe [pr | pr <- stPredictions st, prOriginChunk pr == curIdx]
      predItem =
        case mNewPred of
          Nothing -> "- New Prediction: *(None logged on this chunk)*"
          Just pr ->
            wrapMarkdownBullet
              78
              ( "- New Prediction (audit its `**Clue/Anomaly**` and chronological premise): `"
                  <> renderRecordActiveLine pr
                  <> "`"
              )
      factPromptPath = sessionDir </> "current_fact_check_prompt.md"
      step1 =
        wrapMarkdownBullet
          78
          ( "1. Read `current_chunk.md`, `entries/chunk_"
              <> curPadTxt
              <> ".md`, and `memory.md`. Never treat `memory.md` as proof for earlier-chunk claims: whenever commentary, `[Story]`/`[Entry]`, `memory.md`, or `**Clue/Anomaly**` references details, counts, or timeline facts from an earlier chunk (`XXXX < "
              <> jsonInt curIdx
              <> "`) not verbatim in `current_chunk.md`, call `read_file` on `chunks/chunk_XXXX.md` (and never cite `[OK | Source: current_chunk.md]` for earlier-chunk facts copied from `memory.md`). Connecting external canon, spotting canon characters from clues, and predicting canon elements is welcomed—flag an `[External Canon]` issue ONLY if `blind-reader` stated a false claim about the external reference work itself (verified via neutral `search_web`) OR contradicted/overwrote what this story's own text established."
          )
      step2 =
        wrapMarkdownBullet
          78
          ( "2. Write line 1 as `<!-- TOOLS: read_file(current_chunk.md, entries/chunk_"
              <> curPadTxt
              <> ".md, memory.md, ...) -->` (adding `, search_web` only if invoked) followed by both required sections to `"
              <> T.pack factRespPath
              <> "` via `write_file` (`Overwrite: true`):"
          )
      step2Subs =
        T.intercalate
          "\n\n"
          ( map
              (wrapMarkdownBullet 78)
              [ "   - `=== VERIFIED CLAIMS LOG ===` (`- [OK | Source: ...]` or `- [DISPUTED | Source: ...]`)"
              , "   - `=== DISPUTED FACTS & MEMORY CHECKS ===` (`- PASS` or receipt-backed advisory peer questions: `- **[In-Story Fact | Source: chunks/chunk_XXXX.md | Quote: \"<verbatim substring>\"]** ...` / `- **[External Canon | Source: search_web(\"<query>\") | Work: ...]** ...`)"
              ]
          )
      step3 =
        wrapMarkdownBullet
          78
          ( "3. Once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice ending with `[Tools: read_file(current_chunk.md, entries/chunk_"
              <> curPadTxt
              <> ".md, memory.md, ...)]` (adding `, search_web` only if invoked) and no tool calls (do not call `send_message` or re-read files)."
          )
      factPromptText =
        T.unlines
          [ "# Fact-Check Turn Prompt — Chunk " <> jsonInt curIdx <> " of " <> jsonInt totalChunks
          , ""
          , wrapMarkdownParagraph
              78
              ( "Please fact-check `blind-reader`'s newly recorded commentary, chunk summaries, new prediction premise, and updated memory for Chunk "
                  <> jsonInt curIdx
                  <> " of "
                  <> jsonInt totalChunks
                  <> "."
              )
          , ""
          , "## Session Files"
          , ""
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (`chunks/chunk_" <> curPadTxt <> ".md` — mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Recorded Commentary Entry (mandatory read): " <> T.pack entryPath
          , "- Updated Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          , "- Story Chunks Directory (on-demand `read_file` verification): " <> T.pack (absSession </> "chunks")
          , "- Session File & Index Reference (optional on-demand `read_file`): " <> T.pack sessionFilesRefPath
          , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack factRespPath
          , ""
          , "## Submitted Summaries and Prediction"
          , ""
          , wrapMarkdownBullet 78 ("- Story Summary (`[Story]`): `" <> storySumTxt <> "`")
          , ""
          , wrapMarkdownBullet 78 ("- Entry Summary (`[Entry]`): `" <> entrySumTxt <> "`")
          , ""
          , predItem
          , ""
          , "## Turn Output Contract"
          , ""
          , step1
          , ""
          , step2
          , ""
          , step2Subs
          , ""
          , step3
          ]
  TIO.writeFile factPromptPath factPromptText
  pure factPromptPath

writeCurrentCriticPromptFile :: FilePath -> SessionState -> IO FilePath
writeCurrentCriticPromptFile sessionDir st = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let curIdx = stCurrentIndex st
      curPad = padChunkNumber curIdx
      curPadTxt = T.pack curPad
      totalChunks = stTotalChunks st
      entryPath = absSession </> "entries" </> ("chunk_" ++ curPad ++ ".md")
      criticRespPath = absSession </> "current_critic_response.md"
      linterBlock =
        if null (stPendingLinterWarnings st)
          then "- *(None triggered.)*"
          else T.intercalate "\n\n" (map (wrapMarkdownBullet 78) (stPendingLinterWarnings st))
      criticPromptPath = sessionDir </> "current_critic_prompt.md"
      criticPromptText =
        T.unlines
          [ "# Commentary Critic Prompt — Chunk " <> jsonInt curIdx <> " of " <> jsonInt totalChunks
          , ""
          , wrapMarkdownParagraph
              78
              ( "Please write a concise editorial persona & style critique of `blind-reader`'s newly recorded commentary for Chunk "
                  <> jsonInt curIdx
                  <> " of "
                  <> jsonInt totalChunks
                  <> "."
              )
          , ""
          , "## Session Files"
          , ""
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (`chunks/chunk_" <> curPadTxt <> ".md` — mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Recorded Commentary Entry (mandatory read): " <> T.pack entryPath
          , "- Updated Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          , "- Session File & Index Reference (optional on-demand `read_file`): " <> T.pack sessionFilesRefPath
          , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack criticRespPath
          , ""
          , "## Active Reader Persona"
          , ""
          , wrapMarkdownParagraph 78 (expandPersonaPreset (stPersona st))
          , ""
          , "## Deterministic Style Linter Hits"
          , ""
          , linterBlock
          , ""
          , "## Turn Output Contract"
          , ""
          , wrapMarkdownParagraph
              78
              ( "Read `current_chunk.md`, `entries/chunk_"
                  <> curPadTxt
                  <> ".md`, and `memory.md`, write `=== PERSONA & STYLE CRITIQUE ===` (`~100-150 words`) with the three required bullets (`- **[Persona & Lens]**`, `- **[What Worked Well]**`, and `- **[Where the Voice Drifted or Felt Formulaic]**`) to `"
                  <> T.pack criticRespPath
                  <> "` via `write_file` (`Overwrite: true`), and once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice and no tool calls (do not call `send_message` or re-read files)."
              )
          ]
  TIO.writeFile criticPromptPath criticPromptText
  pure criticPromptPath

writeCurrentTopicPromptFile :: FilePath -> SessionState -> IO FilePath
writeCurrentTopicPromptFile sessionDir st = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let curIdx = stCurrentIndex st
      totalChunks = stTotalChunks st
      topicPromptPath = sessionDir </> "current_topic_prompt.md"
      topicRespPath = absSession </> "current_topic_response.md"
      (vetted, unvetted) = partitionVettedTopics st
      fmtList [] = "- *(None)*"
      fmtList xs =
        wrapMarkdownParagraph
          78
          ( T.intercalate
              ", "
              [ "**" <> disp <> "** (" <> jsonInt cnt <> ")"
              | (disp, cnt) <- xs
              ]
          )
      topicPromptText =
        T.unlines
          [ "# Topic Curation Prompt — Chunk " <> jsonInt curIdx <> " of " <> jsonInt totalChunks
          , ""
          , wrapMarkdownParagraph
              78
              ( "Please review the newly added topic tags (at Chunk "
                  <> jsonInt curIdx
                  <> " of "
                  <> jsonInt totalChunks
                  <> ") and suggest any synonym or alias merges."
              )
          , ""
          , "## Session Files"
          , ""
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          , "- Story Topic Index (optional `read_file`): " <> T.pack (absSession </> "chunks" </> "by_topic.md")
          , "- Entries Topic Index (optional `read_file`): " <> T.pack (absSession </> "entries" </> "by_topic.md")
          , "- Predictions Topic Index (optional `read_file`): " <> T.pack (absSession </> "predictions" </> "by_topic.md")
          , "- Session File & Index Reference (optional on-demand `read_file`): " <> T.pack sessionFilesRefPath
          , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack topicRespPath
          , ""
          , "## Established Topics (" <> jsonInt (length vetted) <> ")"
          , ""
          , fmtList vetted
          , ""
          , "## New Unvetted Topics (" <> jsonInt (length unvetted) <> ")"
          , ""
          , fmtList unvetted
          , ""
          , "## Turn Output Contract"
          , ""
          , wrapMarkdownParagraph
              78
              ( "Read `memory.md` (and any `by_topic.md` index if needed), write `=== TOPIC MERGES ===` with `- <Canonical Topic> <= <Alias 1>, <Alias 2>` for true synonyms, spelling variants, or overly narrow `<Entity> <Scene Action>` one-offs (preserving distinct recurring characters, factions, locations, and plot threads as separate tags, or `- NONE` if all new topics should remain distinct) to `"
                  <> T.pack topicRespPath
                  <> "` via `write_file` (`Overwrite: true`), and once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice and no tool calls (do not call `send_message` or re-read files)."
              )
          ]
  TIO.writeFile topicPromptPath topicPromptText
  pure topicPromptPath

writeFactCheckDiscussionPromptFile :: FilePath -> SessionState -> [Text] -> IO (FilePath, FilePath)
writeFactCheckDiscussionPromptFile sessionDir st peerQueries = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let curIdx = stCurrentIndex st
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      questionsPath = sessionDir </> "current_fact_check_questions.md"
      discPromptPath = sessionDir </> "current_discussion_prompt.md"
      discRespPath = absSession </> "current_discussion_response.md"
      questionsContent = T.intercalate "\n\n" (map (wrapMarkdownBullet 78) peerQueries) <> "\n"
      peerBlock = T.intercalate "\n\n" (map (wrapMarkdownBullet 78) peerQueries)
      mCurAcceptedPred = listToMaybe [pr | pr <- stPredictions st, prOriginChunk pr == curIdx]
      curPredSection =
        case mCurAcceptedPred of
          Nothing -> []
          Just pr ->
            [ ""
            , "## Prediction Logged on Chunk " <> curPad
            , ""
            , wrapMarkdownBullet 78 (renderRecordActiveLine pr)
            ]
      fcPlusClause =
        case mCurAcceptedPred of
          Just _ ->
            "(plus `=== UPDATED MEMORY ===` and/or `=== PREDICTION UPDATES ===` for `[Predicted Chunk "
              <> curPad
              <> "]` if any records need correction)"
          Nothing ->
            "(plus `=== UPDATED MEMORY ===` if any memory notes need correction)"
      discPromptText =
        T.unlines $
          [ "# Fact-Check Peer Discussion Prompt — Chunk " <> jsonInt curIdx <> " of " <> jsonInt totalChunks
          , ""
          , wrapMarkdownParagraph
              78
              ( "Before unlocking the next chunk, please review and respond to the following Fact-Check Peer Query on your Chunk "
                  <> jsonInt curIdx
                  <> "/"
                  <> jsonInt totalChunks
                  <> " entry as a `Reader Discussion` reply."
              )
          , ""
          , "## Session Files"
          , ""
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (`chunks/chunk_" <> curPad <> ".md`): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File: " <> T.pack (absSession </> "memory.md")
          , "- Story Chunks Directory (on-demand `read_file` verification): " <> T.pack (absSession </> "chunks")
          , "- Session File & Index Reference (optional on-demand `read_file`): " <> T.pack sessionFilesRefPath
          , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack discRespPath
          , ""
          , "## Active Persona"
          , ""
          , wrapMarkdownParagraph 78 (expandPersonaPreset (stPersona st))
          ]
            ++ curPredSection
            ++ [ ""
               , "## Fact-Check Peer Query"
               , ""
               , peerBlock
               , ""
               , "## Turn Output Contract"
               , ""
               , wrapMarkdownBullet
                   78
                   "1. Perform your own independent verification first by calling `read_file` on the cited `<session_dir>/chunks/chunk_XXXX.md` (or `current_chunk.md`) and/or calling `search_web` with a neutral query."
               , ""
               , wrapMarkdownBullet
                   78
                   ( "2. Write line 1 as `<!-- TOOLS: read_file(...) -->` (adding `, search_web` only if invoked) followed by your in-character reply under `=== COMMENTARY ===` (conceding if your check confirms a misread, or holding your ground with primary-source quotes if your original reading/joke/baseline was right) and `=== CHUNK SUMMARY ===` with `- **[Discussion | Topics: Topic 1, Topic 2, Topic 3]** <1-line summary, <= 250 chars>` "
                       <> fcPlusClause
                       <> " to `"
                       <> T.pack discRespPath
                       <> "` via `write_file` (`Overwrite: true`)."
                   )
               , ""
               , wrapMarkdownBullet
                   78
                   "3. Once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice ending with `[Tools: read_file(...)]` (adding `, search_web` only if invoked) and no tool calls (do not call `send_message` or re-read files)."
               ]
  TIO.writeFile questionsPath questionsContent
  TIO.writeFile discPromptPath discPromptText
  pure (questionsPath, discPromptPath)

writeUserDiscussionPromptFile :: FilePath -> SessionState -> Text -> IO (FilePath, FilePath)
writeUserDiscussionPromptFile sessionDir st userMsg = do
  absSession <- canonicalizePath sessionDir
  sessionFilesRefPath <- resolveSessionFilesRefPathIO
  let curIdx = stCurrentIndex st
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      userMsgPath = sessionDir </> "last_user_message.md"
      discPromptPath = sessionDir </> "current_discussion_prompt.md"
      discRespPath = absSession </> "current_discussion_response.md"
      isPostWrapup = curIdx >= totalChunks && stCurrentRecorded st && stCurrentJudged st
      mUserCurPred =
        if isPostWrapup
          then Nothing
          else listToMaybe [pr | pr <- stPredictions st, prOriginChunk pr == curIdx]
      curPredSection =
        case mUserCurPred of
          Nothing -> []
          Just pr ->
            [ ""
            , "## Prediction Logged on Chunk " <> curPad
            , ""
            , wrapMarkdownBullet 78 (renderRecordActiveLine pr)
            ]
      userPlusClause =
        case mUserCurPred of
          Just _ ->
            "(plus `=== UPDATED MEMORY ===` and/or `=== PREDICTION UPDATES ===` if the exchange updates a factual/timeline correction, craft/style directive, running gag, character status, or Chunk "
              <> curPad
              <> "'s prediction)"
          Nothing ->
            "(plus `=== UPDATED MEMORY ===` if the exchange updates a factual/timeline correction, craft/style directive, running gag, or character status)"
      discPromptText =
        T.unlines $
          [ "# User Discussion Prompt — Chunk " <> jsonInt curIdx <> " of " <> jsonInt totalChunks
          , ""
          , wrapMarkdownParagraph
              78
              ( "The user has replied with a comment or question on your Let's Read thread (at Chunk "
                  <> jsonInt curIdx
                  <> "/"
                  <> jsonInt totalChunks
                  <> "). Please respond in character in your Active Persona."
              )
          , ""
          , "## Session Files"
          , ""
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (`chunks/chunk_" <> curPad <> ".md`): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File: " <> T.pack (absSession </> "memory.md")
          , "- Story Chunks Directory (on-demand `read_file` verification): " <> T.pack (absSession </> "chunks")
          , "- Session File & Index Reference (optional on-demand `read_file`): " <> T.pack sessionFilesRefPath
          , "- Output Response File (mandatory `write_file`, `Overwrite: true`): " <> T.pack discRespPath
          , ""
          , "## Active Persona"
          , ""
          , wrapMarkdownParagraph 78 (expandPersonaPreset (stPersona st))
          ]
            ++ curPredSection
            ++ [ ""
               , "## User Message"
               , ""
               , T.strip userMsg
               , ""
               , "## Turn Output Contract"
               , ""
               , wrapMarkdownBullet
                   78
                   "1. If the user's message references a specific detail from an earlier chunk or external reference material, verify it via `read_file` on `chunks/chunk_XXXX.md` or neutral `search_web` first."
               , ""
               , wrapMarkdownBullet
                   78
                   ( "2. Write line 1 as `<!-- TOOLS: read_file(...) -->` (or `<!-- TOOLS: none -->` if no verification tool beyond reading this prompt was needed) followed by `=== COMMENTARY ===` (your full in-character reply) and `=== CHUNK SUMMARY ===` with `- **[Discussion | Topics: Topic 1, Topic 2, Topic 3]** <1-line summary of the discussion exchange, <= 250 chars>` "
                       <> userPlusClause
                       <> " to `"
                       <> T.pack discRespPath
                       <> "` via `write_file` (`Overwrite: true`)."
                   )
               , ""
               , wrapMarkdownBullet
                   78
                   "3. Once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice ending with `[Tools: ...]` (`[Tools: read_file(...)]` or `[Tools: none]`) and no tool calls (do not call `send_message` or re-read files)."
               ]
  TIO.writeFile userMsgPath (T.strip userMsg <> "\n")
  TIO.writeFile discPromptPath discPromptText
  pure (userMsgPath, discPromptPath)
