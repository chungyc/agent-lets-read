{-# LANGUAGE OverloadedStrings #-}

module LetsRead.Prompts
  ( defaultPersonaText
  , expandPersonaPreset
  , resolvePersonaPresetIO
  , renderPredictionSlateNote
  , writeCurrentChunkFile
  , writeCurrentPromptFile
  , writeWrapupPromptFile
  , writeCurrentJudgePromptFile
  , writeCurrentFactCheckPromptFile
  , writeCurrentCriticPromptFile
  , writeCurrentTopicPromptFile
  , writeFactCheckDiscussionPromptFile
  , writeUserDiscussionPromptFile
  ) where

import Data.Char (isDigit, isSpace)
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LetsRead.Index (partitionVettedTopics)
import LetsRead.Predictions
  ( renderRecordActiveLine
  , renderRecordResolvedLine
  )
import LetsRead.Types
  ( Chunk (..)
  , PredictionRecord (..)
  , PredictionStatus (..)
  , SessionState (..)
  , jsonInt
  , padChunkNumber
  , readTextFileSafe
  , resolveSkillResourcePath
  )
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath ((</>))

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

renderPredictionSlateNote :: Int -> Int -> Int -> Text
renderPredictionSlateNote curIdx totalChunks activeCount
  | curIdx >= totalChunks =
      "*Prediction Slate*: Final story chunk ("
        <> jsonInt activeCount
        <> "/10 active unresolved predictions in `memory.md`). Focus `=== COMMENTARY ===` on your live reaction to this final story passage (and any `prediction-judge` rulings from the previous chunk). Output `- None (story complete!).` in `=== PREDICTION UPDATES ===`."
  | activeCount < 10 =
      let curPad = T.pack (padChunkNumber curIdx)
       in "*Prediction Slate*: "
            <> jsonInt activeCount
            <> "/10 active unresolved predictions in `memory.md`. React naturally in `=== COMMENTARY ===` to any `CONFIRMED`/`DEBUNKED`/`SUBVERTED` rulings from the previous chunk, and log 1 new non-softball, multi-chapter prediction (`<= 450 chars` total) on this chunk using `- **[Predicted Chunk "
            <> curPad
            <> " | Topics: Topic 1, Topic 2, Topic 3]** **Clue/Anomaly**: <detail, <= 120 chars, no quotes> -> **Theory**: <direct bet, <= 160 chars> (vs. **Plausible Rival**: <rival explanation, <= 120 chars>)` at the end of `=== COMMENTARY ===` and in `=== PREDICTION UPDATES ===`."
  | otherwise =
      let curPad = T.pack (padChunkNumber curIdx)
          needRetire = activeCount + 1 - 10
       in "*Prediction Slate*: "
            <> jsonInt activeCount
            <> "/10 active unresolved predictions in `memory.md` (AT 10-PREDICTION CAP). React naturally in `=== COMMENTARY ===` to any `CONFIRMED`/`DEBUNKED`/`SUBVERTED` rulings from the previous chunk, log 1 new non-softball, multi-chapter prediction (`<= 450 chars` total) using `- **[Predicted Chunk "
            <> curPad
            <> " | Topics: Topic 1, Topic 2, Topic 3]** **Clue/Anomaly**: <detail, <= 120 chars, no quotes> -> **Theory**: <direct bet, <= 160 chars> (vs. **Plausible Rival**: <rival explanation, <= 120 chars>)` at the end of `=== COMMENTARY ===` and in `=== PREDICTION UPDATES ===`, AND nominate "
            <> jsonInt needRetire
            <> " conditional retirement candidate(s) (choosing from all unresolved predictions, including your new one, the prediction(s) most likely to never be resolved or most likely to be debunked) in `=== PREDICTION UPDATES ===` using `- **[Predicted Chunk XXXX -> RETIRED Chunk "
            <> curPad
            <> "]** <reason>`."

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

writeCurrentPromptFile :: FilePath -> SessionState -> Chunk -> Int -> IO FilePath
writeCurrentPromptFile sessionDir st chunk activeCount = do
  absSession <- canonicalizePath sessionDir
  let criticFeedbackPath = absSession </> "critic_feedback.md"
  hasCriticFeedback <- doesFileExist criticFeedbackPath
  let curIdx = chunkIndex chunk
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      slatePromptLine = renderPredictionSlateNote curIdx totalChunks activeCount
      criticContextLines =
        if hasCriticFeedback
          then
            [ "- Persona & Style Critique Notes from Chunk "
                <> jsonInt (max 1 (curIdx - 1))
                <> " (MANDATORY READ — apply silently; never mention in commentary): "
                <> T.pack criticFeedbackPath
            ]
          else []
      prevContextLines =
        if curIdx <= 1
          then []
          else
            let prevPad = padChunkNumber (curIdx - 1)
                 in [ "- Previous Story Chunk (read ONLY if newly rotated or picking up mid-chapter): "
                        <> T.pack (absSession </> "chunks" </> ("chunk_" ++ prevPad ++ ".md"))
                    ]
      promptPath = sessionDir </> "current_prompt.md"
      promptText =
        T.unlines $
          [ "Please read the newly unlocked chunk (Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> ") and write your Let's Read entry."
          , "- Current Chunk File (mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          ]
            ++ criticContextLines
            ++ prevContextLines
            ++ [ "- Story Chunks Indices (`chunks/by_chronology.md` & `chunks/by_topic.md`, on-demand `read_file` for callback verification): " <> T.pack (absSession </> "chunks")
               , "- Session Entries & Predictions (`entries/` & `predictions/`, on-demand `read_file`): " <> T.pack absSession
               , "- Active Persona: " <> expandPersonaPreset (stPersona st)
               , "- " <> slatePromptLine
               , ""
               , "## Turn Output Contract"
               , "1. Read `current_chunk.md` and `memory.md` (plus `critic_feedback.md` if listed above), verify any earlier-chunk callbacks via `read_file` on `chunks/chunk_XXXX.md` and any external canon references via neutral `search_web` queries."
               , "2. Output all four required sections using exact headers:"
               , "   - `=== COMMENTARY ===` (react in your Active Persona with 3–5 tight `>` blockquotes, weave reactions to any `prediction-judge` verdicts in `memory.md`, and end with `- **[Predicted Chunk " <> curPad <> " | Topics: Topic 1, Topic 2, Topic 3]** ...`)"
               , "   - `=== CHUNK SUMMARY ===` (`- **[Story | Topics: ...]** <1-line factual in-story summary>` and `- **[Entry | Topics: ...]** <1-line reaction/gag summary>`)"
               , "   - `=== PREDICTION UPDATES ===` (`- **[Predicted Chunk " <> curPad <> " | Topics: ...]** **Clue/Anomaly**: ... -> **Theory**: ... (vs. **Plausible Rival**: ...)` plus conditional `RETIRED` if at 10/10 active)"
               , "   - `=== UPDATED MEMORY ===` (the 4 narrative sections only)"
               ]
  TIO.writeFile promptPath promptText
  pure promptPath

writeWrapupPromptFile :: FilePath -> SessionState -> IO FilePath
writeWrapupPromptFile sessionDir st = do
  absSession <- canonicalizePath sessionDir
  let criticFeedbackPath = absSession </> "critic_feedback.md"
  hasCriticFeedback <- doesFileExist criticFeedbackPath
  let totalChunks = stTotalChunks st
      criticContext =
        if hasCriticFeedback
          then
            "- Persona & Style Critique Notes from Chunk "
              <> jsonInt totalChunks
              <> " (MANDATORY READ — apply style coaching silently): "
              <> T.pack criticFeedbackPath
              <> "\n"
          else ""
      promptPath = sessionDir </> "current_prompt.md"
  tmplPath <- resolveSkillResourcePath ("resources" </> "wrapup_prompt_template.md")
  hasTmpl <- doesFileExist tmplPath
  rawTmpl <-
    if hasTmpl
      then readTextFileSafe tmplPath
      else
        pure $
          T.unlines
            [ "All {{TOTAL_CHUNKS}} story chunks of *{{TITLE}}* have been read! Please write your dedicated **Final Wrapup & Retrospective**."
            , "- Reader Memory File (mandatory read): {{MEMORY_FILE}}"
            , "- Prediction Hall of Fame & Shame (mandatory read): {{HALL_OF_FAME_FILE}}"
            , "{{CRITIC_CONTEXT}}- Active Persona: {{ACTIVE_PERSONA}}"
            , ""
            , "Read `memory.md` and `predictions/hall_of_fame.md` and output `=== COMMENTARY ===` covering finale verdicts, whole-story retrospective, corkboard autopsy, and closing sign-off."
            ]
  let substitutions =
        [ ("{{TOTAL_CHUNKS}}", jsonInt totalChunks)
        , ("{{TITLE}}", stTitle st)
        , ("{{SESSION_DIR}}", T.pack absSession)
        , ("{{MEMORY_FILE}}", T.pack (absSession </> "memory.md"))
        , ("{{HALL_OF_FAME_FILE}}", T.pack (absSession </> "predictions" </> "hall_of_fame.md"))
        , ("{{CRITIC_CONTEXT}}", criticContext)
        , ("{{CHUNKS_DIR}}", T.pack (absSession </> "chunks"))
        , ("{{ENTRIES_DIR}}", T.pack (absSession </> "entries"))
        , ("{{PREDICTIONS_DIR}}", T.pack (absSession </> "predictions"))
        , ("{{ARCHIVE_DIR}}", T.pack (absSession </> "archive"))
        , ("{{ACTIVE_PERSONA}}", expandPersonaPreset (stPersona st))
        ]
      rendered = foldr (\(k, v) acc -> T.replace k v acc) rawTmpl substitutions
  TIO.writeFile promptPath rendered
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
            PredStatusRetired _ -> False
            PredStatusActive -> False
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
                              <> "` — **Judge strictly on the merits against `current_chunk.md`** (`LetsRead` applies conditional retirement only if it remains `ACTIVE` and >10 remain active)."
                          ]
                 in baseLine : retireNote
              | pr <- activePreds
              ]
      recentLines =
        if null recentResolved
          then []
          else
            [ ""
            , "## Recently Resolved Predictions (Last 2 Chunks — Emit Only If Cliffhanger Fake-Out Reversed)"
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
          [ "Please evaluate all currently active predictions against Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> "."
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File (optional context read): " <> T.pack (absSession </> "memory.md")
          , "- Predictions Directory (optional on-demand `read_file`): " <> T.pack (absSession </> "predictions")
          , ""
          , "## Active Predictions to Judge on Chunk " <> curPad <> " (" <> jsonInt (length activePreds) <> " Active — Evaluate ALL)"
          , ""
          ]
            ++ activeLines
            ++ recentLines
            ++ [ ""
               , "## Turn Output Contract"
               , "Read `current_chunk.md` and output `=== PREDICTION JUDGMENTS ===` with one bullet per active prediction (`[Predicted Chunk XXXX -> ACTIVE]`, `CONFIRMED Chunk " <> curPad <> "`, `DEBUNKED Chunk " <> curPad <> "`, or `SUBVERTED Chunk " <> curPad <> "`; include a 1-sentence synthesis/falsifiability audit on `Predicted Chunk " <> curPad <> " -> ACTIVE`)."
               ]
  TIO.writeFile judgePromptPath judgePromptText
  pure judgePromptPath

writeCurrentFactCheckPromptFile :: FilePath -> SessionState -> Text -> Text -> IO FilePath
writeCurrentFactCheckPromptFile sessionDir st storySumTxt entrySumTxt = do
  absSession <- canonicalizePath sessionDir
  let curIdx = stCurrentIndex st
      curPad = padChunkNumber curIdx
      curPadTxt = T.pack curPad
      totalChunks = stTotalChunks st
      entryPath = absSession </> "entries" </> ("chunk_" ++ curPad ++ ".md")
      mNewPred = listToMaybe [pr | pr <- stPredictions st, prOriginChunk pr == curIdx]
      predLine =
        case mNewPred of
          Nothing -> "- Submitted New Prediction: *(None logged on this chunk)*"
          Just pr -> "- Submitted New Prediction (audit its `**Clue/Anomaly**` and chronological premise): `" <> renderRecordActiveLine pr <> "`"
      factPromptPath = sessionDir </> "current_fact_check_prompt.md"
      factPromptText =
        T.unlines
          [ "Please fact-check `blind-reader`'s newly recorded commentary, chunk summaries, new prediction premise, and updated memory for Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> "."
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (`chunks/chunk_" <> curPadTxt <> ".md` — mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Recorded Commentary Entry (mandatory read): " <> T.pack entryPath
          , "- Updated Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          , "- Unlocked Story Chunks & Indices (`chunks/by_chronology.md` & `chunks/by_topic.md` for `read_file` verification): " <> T.pack (absSession </> "chunks")
          , "- Submitted 1-Line Story Summary (`[Story]`): `" <> storySumTxt <> "`"
          , "- Submitted 1-Line Entry Summary (`[Entry]`): `" <> entrySumTxt <> "`"
          , predLine
          , ""
          , "## Turn Output Contract"
          , "1. Read `current_chunk.md`, `entries/chunk_" <> curPadTxt <> ".md`, and `memory.md`; verify any earlier-chunk callbacks/premises by calling `read_file` on `chunks/chunk_XXXX.md` and any external canon claims via neutral `search_web` queries."
          , "2. Output both required sections:"
          , "   - `=== VERIFIED CLAIMS LOG ===` (`- [OK | Source: ...]` or `- [DISPUTED | Source: ...]`)"
          , "   - `=== DISPUTED FACTS & MEMORY CHECKS ===` (`- PASS` or receipt-backed advisory peer questions: `- **[In-Story Fact | Source: chunks/chunk_XXXX.md | Quote: \"<verbatim substring>\"]** ...` / `- **[External Canon | Source: search_web(\"<query>\") | Work: ...]** ...`)"
          ]
  TIO.writeFile factPromptPath factPromptText
  pure factPromptPath

writeCurrentCriticPromptFile :: FilePath -> SessionState -> IO FilePath
writeCurrentCriticPromptFile sessionDir st = do
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
          [ "Please write a concise editorial persona & style critique of `blind-reader`'s newly recorded commentary for Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> "."
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (`chunks/chunk_" <> curPadTxt <> ".md` — mandatory read): " <> T.pack (absSession </> "current_chunk.md")
          , "- Recorded Commentary Entry (mandatory read): " <> T.pack entryPath
          , "- Updated Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          , "- Active Reader Persona: " <> expandPersonaPreset (stPersona st)
          , ""
          , "## Deterministic Style Linter Hits (`LetsRead`)"
          ]
            ++ linterLines
            ++ [ ""
               , "## Turn Output Contract"
               , "Read `current_chunk.md`, `entries/chunk_" <> curPadTxt <> ".md`, and `memory.md`, and output `=== PERSONA & STYLE CRITIQUE ===` (`~100-150 words`) with the three required bullets: `- **[Persona & Lens]**`, `- **[What Worked Well]**`, and `- **[Where the Voice Drifted or Felt Formulaic]**`."
               ]
  TIO.writeFile criticPromptPath criticPromptText
  pure criticPromptPath

writeCurrentTopicPromptFile :: FilePath -> SessionState -> IO FilePath
writeCurrentTopicPromptFile sessionDir st = do
  absSession <- canonicalizePath sessionDir
  let curIdx = stCurrentIndex st
      totalChunks = stTotalChunks st
      topicPromptPath = sessionDir </> "current_topic_prompt.md"
      (vetted, unvetted) = partitionVettedTopics st
      fmtList [] = "- *(None)*"
      fmtList xs =
        T.intercalate
          ", "
          [ "**" <> disp <> "** (" <> jsonInt cnt <> ")"
          | (disp, cnt) <- xs
          ]
      topicPromptText =
        T.unlines
          [ "Please review the newly added topic tags (at Chunk "
              <> jsonInt curIdx
              <> " of "
              <> jsonInt totalChunks
              <> ") and suggest any synonym or alias merges."
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Reader Memory File (mandatory read): " <> T.pack (absSession </> "memory.md")
          , "- Domain Topic Indexes (optional on-demand `read_file` if a tag's usage is ambiguous): "
              <> T.pack (absSession </> "chunks" </> "by_topic.md")
              <> ", "
              <> T.pack (absSession </> "entries" </> "by_topic.md")
              <> ", "
              <> T.pack (absSession </> "predictions" </> "by_topic.md")
          , ""
          , "## Established / Previously Vetted Topics (" <> jsonInt (length vetted) <> ")"
          , fmtList vetted
          , ""
          , "## New Unvetted Topics Added Since Last Curation (" <> jsonInt (length unvetted) <> ")"
          , fmtList unvetted
          , ""
          , "## Turn Output Contract"
          , "Read `memory.md` (and any `by_topic.md` index if needed) and output `=== TOPIC MERGES ===` with `- <Canonical Topic> <= <Alias 1>, <Alias 2>` for any synonymous or overly narrow one-off tags (or `- NONE` if all new topics should remain distinct)."
          ]
  TIO.writeFile topicPromptPath topicPromptText
  pure topicPromptPath

writeFactCheckDiscussionPromptFile :: FilePath -> SessionState -> [Text] -> IO (FilePath, FilePath)
writeFactCheckDiscussionPromptFile sessionDir st peerQueries = do
  absSession <- canonicalizePath sessionDir
  let curIdx = stCurrentIndex st
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      questionsPath = sessionDir </> "current_fact_check_questions.md"
      discPromptPath = sessionDir </> "current_discussion_prompt.md"
      questionsContent = T.unlines peerQueries
      discPromptText =
        T.unlines $
          [ "Before unlocking the next chunk, please review and respond to the following **Fact-Check Peer Query** on your Chunk "
              <> jsonInt curIdx
              <> "/"
              <> jsonInt totalChunks
              <> " entry as a `Reader Discussion` reply."
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (`chunks/chunk_" <> curPad <> ".md`): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File: " <> T.pack (absSession </> "memory.md")
          , "- Unlocked Story Chunks & Indices (`chunks/by_chronology.md` & `chunks/by_topic.md` for `read_file` verification): " <> T.pack (absSession </> "chunks")
          , "- Active Persona: " <> expandPersonaPreset (stPersona st)
          , ""
          , "## Fact-Check Peer Query (Unspoiled AI Peer — Verify Against Primary Source!)"
          , ""
          ]
            ++ peerQueries
            ++ [ ""
               , "## Turn Output Contract"
               , "1. Perform your own independent verification first by calling `read_file` on the cited `<session_dir>/chunks/chunk_XXXX.md` (or `current_chunk.md`) and/or calling `search_web` with a neutral query."
               , "2. Reply in character under `=== COMMENTARY ===` (conceding if your check confirms a misread, or holding your ground with primary-source quotes if your original reading/joke/AU baseline was right) and include `=== CHUNK SUMMARY ===` with `- **[Discussion | Topics: Topic 1, Topic 2, Topic 3]** <1-line summary>` (plus `=== UPDATED MEMORY ===` and/or `=== PREDICTION UPDATES ===` for `[Predicted Chunk " <> curPad <> "]` if any records need correction)."
               ]
  TIO.writeFile questionsPath questionsContent
  TIO.writeFile discPromptPath discPromptText
  pure (questionsPath, discPromptPath)

writeUserDiscussionPromptFile :: FilePath -> SessionState -> Text -> IO (FilePath, FilePath)
writeUserDiscussionPromptFile sessionDir st userMsg = do
  absSession <- canonicalizePath sessionDir
  let curIdx = stCurrentIndex st
      curPad = T.pack (padChunkNumber curIdx)
      totalChunks = stTotalChunks st
      userMsgPath = sessionDir </> "last_user_message.md"
      discPromptPath = sessionDir </> "current_discussion_prompt.md"
      discPromptText =
        T.unlines
          [ "The user has replied with a comment/question on your Let's Read thread (at Chunk "
              <> jsonInt curIdx
              <> "/"
              <> jsonInt totalChunks
              <> "). Please respond in character in your Active Persona."
          , "- Session Directory: `" <> T.pack absSession <> "`"
          , "- Current Story Chunk (`chunks/chunk_" <> curPad <> ".md`): " <> T.pack (absSession </> "current_chunk.md")
          , "- Reader Memory File: " <> T.pack (absSession </> "memory.md")
          , "- Unlocked Story Chunks & Indices (`chunks/by_chronology.md` & `chunks/by_topic.md` for `read_file` verification): " <> T.pack (absSession </> "chunks")
          , "- Active Persona: " <> expandPersonaPreset (stPersona st)
          , ""
          , "## User Message"
          , ""
          , T.strip userMsg
          , ""
          , "## Turn Output Contract"
          , "1. If the user's message references a specific detail from an earlier chunk or external canon, verify it via `read_file` on `chunks/chunk_XXXX.md` or neutral `search_web` first."
          , "2. Output `=== COMMENTARY ===` (your full in-character reply) and `=== CHUNK SUMMARY ===` with `- **[Discussion | Topics: Topic 1, Topic 2, Topic 3]** <1-line summary of the discussion exchange>`. If the exchange updates a factual/timeline correction, craft/style directive, running gag, character status, or Chunk " <> curPad <> "'s prediction, also append `=== UPDATED MEMORY ===` (the 4 narrative sections) and/or `=== PREDICTION UPDATES ===`."
          ]
  TIO.writeFile userMsgPath (T.strip userMsg <> "\n")
  TIO.writeFile discPromptPath discPromptText
  pure (userMsgPath, discPromptPath)
