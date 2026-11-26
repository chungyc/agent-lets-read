# Final Wrapup & Retrospective Prompt — {{TITLE}}

All {{TOTAL_CHUNKS}} story chunks of *{{TITLE}}* have been read and
`lets-read-prediction-judge` has rendered its final rulings! Please write your
dedicated **Final Wrapup & Retrospective** for the Let's Read session.

## Session Files & Context

- Reader Memory (`memory.md`, mandatory read — curated summary, cast, and
  running gags): {{MEMORY_FILE}}

- Prediction Hall of Fame & Shame (mandatory read — final scoreboard, Confirmed
  Hits, Subverted Twists, and Debunked Misses): {{HALL_OF_FAME_FILE}}

- Pre-Pulled Reference Packet (mandatory read — verified story, entry,
  prediction, and canon excerpts): {{RESEARCH_FILE}}

- Story Chronological Index (mandatory read — arc & chapter progression):
  {{CHUNKS_CHRON_FILE}}

- Commentary Chronological Index (mandatory read — prior entries &
  discussions): {{ENTRIES_CHRON_FILE}}

- Story Chunks Directory & Topic Index (`chunks/by_topic.md`, on-demand
  `read_file`): {{CHUNKS_DIR}}

- Commentary Entries Directory & Topic Index (`entries/by_topic.md`,
  on-demand `read_file`): {{ENTRIES_DIR}}

- Predictions Indices (`predictions/by_chronology.md` &
  `predictions/by_topic.md`, on-demand `read_file`): {{PREDICTIONS_DIR}}

- Curated Memory Archive (`archive/memory/`, on-demand `read_file`):
  {{ARCHIVE_DIR}}

- Session File & Index Reference (optional on-demand `read_file` for file
  groups & sharded index layout):
  {{SESSION_FILES_REF}}

- Output Response File (mandatory write via `write_file` with
  `Overwrite: true`): {{READER_RESPONSE_FILE}}

## Active Persona

{{ACTIVE_PERSONA}}

{{CRITIC_CONTEXT}}

## Final Wrapup Instructions

### 1. Mandatory Reads & Pre-Writing Verification

Read `memory.md`, `predictions/hall_of_fame.md`, `current_research.md`,
`chunks/by_chronology.md`, and `entries/by_chronology.md` in parallel first
(applying any `## Persona & Style Critique` notes above silently, and using
`current_research.md` and the chronological indexes selectively without
forcing callbacks). Because your subagent instance may have rotated in late
in the story, do **NOT** reconstruct earlier prediction wording or
multi-chapter chronology from memory, 1-line index summaries, or fanon
alone:

- Check the **exact original `**Clue/Anomaly**` and `**Theory**` text** in
  `predictions/hall_of_fame.md` (or via `read_file` on
  `predictions/pred_XXXX.md` / `predictions/by_chronology.md`) whenever
  discussing specific bets. Never embellish or rewrite what you originally
  predicted using hindsight details from `lets-read-prediction-judge`'s later
  outcome summary.

- Cross-check **overall story chronology, elapsed-time spans, and baseline
  facts** against Bullet 1 (`Core Premise, Timeline & Baseline Facts
  (Persistent)`) of `memory.md` and `chunks/by_chronology.md` (calling
  `read_file` on `chunks/chunk_XXXX.md` or `entries/chunk_XXXX.md` whenever
  quoting or citing specific earlier scene details not already verbatim in
  `current_research.md`). Never conflate a local timeframe from a single
  scene with the overall span of the story.

### 2. Persona & Voice

Stay in your Active Persona as a live reader wrapping up the thread. Do NOT
write a stiff academic essay or use banned review jargon, and do NOT start with
a top `# Final Wrapup` heading (`LetsRead` prepends the section header
automatically).

### 3. Four Retrospective Angles to Cover Naturally in `=== COMMENTARY ===`

#### Finale Verdicts & Immediate Aftermath

React to `lets-read-prediction-judge`'s final rulings from the last chunk (shown
above if any resolved on the final chunk, and collected in
`predictions/hall_of_fame.md`).

#### Whole-Story & Character Retrospective

Trace how the premise evolved across the verified chronology from Chunk 1 to the
finale, which characters (including original or supporting cast) stole the show,
and how the central mysteries, themes, or plot threads locked together.

#### Prediction Scoreboard Retrospective (`hall_of_fame.md`)

Review your final prediction scoreboard with good humor—highlighting your
proudest `CONFIRMED` hits (summarizing their actual original `**Theory**`
accurately), your favorite authorial `SUBVERTED` twists/red herrings, and your
funniest or wildest `DEBUNKED` theories and early Chunk 1–3 misconceptions.

#### Running Gags, Lingering Hooks & Closing Sign-Off

Call back to the thread's favorite running jokes and standout moments, note any
open sequel hooks, and sign off warmly.

### 4. Output Format & Tool Receipt

Write line 1 as `<!-- TOOLS: read_file(...) -->` followed by
`=== COMMENTARY ===` (and optionally `=== CHUNK SUMMARY ===` with
`- **[Entry | Topics: Wrapup, Retrospective, ...]** <1-line wrapup summary>` and
`=== UPDATED MEMORY ===`; `=== PREDICTION UPDATES ===` is not needed) to
`{{READER_RESPONSE_FILE}}` using `write_file` (`Overwrite: true`). Once
`write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text
completion notice starting with
`[SUBAGENT_DONE | Wrapup | lets-read-blind-reader]` followed by
`wrote current_reader_response.md` and `[Tools: read_file(...)]` listing
`memory.md`, `predictions/hall_of_fame.md`, `current_research.md`,
`chunks/by_chronology.md`, `entries/by_chronology.md`, and any other files
read, with no tool calls.
