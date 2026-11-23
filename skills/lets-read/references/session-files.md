# Session Files & Multi-Layer Index Reference

Shared read-only navigation reference for all **Let's Read** subagents
(`blind-reader`, `prediction-judge`, `fact-checker`, `commentary-critic`, and
`topic-curator`).

## Read & Write Boundaries

### Read Scope

Read files only inside `<session_dir>` (plus this `session-files.md` reference).
Never read `<session_dir>/.vault.bin`, `<session_dir>/.state.bin`, or any other
local file outside `<session_dir>`.

### Write Scope

Write **only** to the single `<session_dir>/current_*_response.md` path
specified in your turn prompt (`Overwrite: true`). Never write directly to
`chunks/`, `entries/`, `predictions/`, `archive/`, `memory.md`, or
`lets_read_log.md`.

## File Groups & What Each Group Is For

### Story Passages (`current_chunk.md` & `chunks/`)

Primary source of truth for all in-story text, verbatim quotes, dialogue, event
order, elapsed time, counts, titles, and prediction premises
(`**Clue/Anomaly**`).

#### `<session_dir>/current_chunk.md`

Newly unlocked story passage for the active chunk (`Chunk N`), including
chapter/part progress and mid-chapter split notices.

#### `<session_dir>/chunks/chunk_XXXX.md`

Permanent copy of each unlocked story chunk (`0001`..`NNNN`). Always verify
earlier-chunk details against `chunks/chunk_XXXX.md` rather than relying on
condensed summaries.

#### `<session_dir>/chunks/by_chronology.md` & `by_topic.md`

Chronological and semantic topic indexes (along with `chunks/archive/`) of
1-line `[Story]` summaries used to locate which `chunks/chunk_XXXX.md` file
covers a character, faction, location, prop, or event.

### Reader Working Notebook & Snapshots (`memory.md` & `archive/memory/`)

Working reader continuity notes and historical point-in-time snapshots.

#### `<session_dir>/memory.md`

Combines `blind-reader`'s four curated sections (`Story Summary So Far`,
`Characters & Relationships`, `Active Mysteries & Unanswered Questions`,
`Notable Quotes, Themes & Running Jokes`) with auto-maintained index links,
`Established Topic Tags`, `Completed L1 Story Arcs`, the last 5 chunk summaries,
and the `Active Prediction Slate`.

Aside from established canon divergences and user corrections in Bullet 1 of
`Story Summary So Far`, treat `memory.md` as a condensed working summary rather
than primary proof of earlier-chunk text.

#### `archive/memory/curated_XXXX.md` & `archive/memory/chunk_XXXX.md`

Point-in-time snapshots of the 4 curated sections (`curated_XXXX.md`) and full
`memory.md` (`chunk_XXXX.md`) recorded after `Chunk XXXX`, used to check when a
note or belief was first recorded.

### Liveblog Commentary & Discussions (`entries/` & `lets_read_log.md`)

Recorded liveblog reactions, running gags, peer verification replies, and user
discussions.

#### `<session_dir>/entries/chunk_XXXX.md`

Recorded commentary for `Chunk XXXX`, including any appended
`### Reader Discussion` exchanges and `Prediction Judge` or gatekeeper audit
callouts.

#### `<session_dir>/entries/wrapup.md`

Post-story Final Wrapup & Retrospective entry written after all story chunks are
judged.

#### `<session_dir>/entries/by_chronology.md` & `by_topic.md`

Chronological and topic indexes (along with `entries/archive/`) of `[Entry]` and
`[Discussion]` summaries used to look up prior reactions, running gags, style
patterns, or discussion exchanges.

#### `<session_dir>/lets_read_log.md`

Do **not** call `read_file` on `<session_dir>/lets_read_log.md` (the
concatenated full-session liveblog maintained for the human reader); use
`entries/by_topic.md`, `entries/by_chronology.md`, and `entries/chunk_XXXX.md`
instead.

### Predictions, Verdicts & Scoreboard (`predictions/`)

Structured `Clue/Anomaly -> Theory (vs. Plausible Rival)` prediction records,
Judge rulings, and final session scoreboard.

#### `<session_dir>/predictions/pred_XXXX.md`

Full record for the prediction logged on `Chunk XXXX`, including origin
chapter/part metadata, topic tags, structured clauses, status (`ACTIVE`,
`CONFIRMED`, `DEBUNKED`, `SUBVERTED`, `RETIRED`), and Judge explanation with
origin and resolution chunk links.

#### `<session_dir>/predictions/by_chronology.md` & `by_topic.md`

Chronological and topic indexes (along with `predictions/archive/`) across all
active and resolved predictions.

#### `<session_dir>/predictions/hall_of_fame.md`

Final prediction scoreboard and retrospective report generated once the final
story chunk is recorded and judged (read by `blind-reader` on the Final Wrapup
turn).

### Turn Prompts & Editorial Review Files

Per-turn subagent I/O files and editorial/fact-check archives.

#### `<session_dir>/current_*_prompt.md` & `current_*_response.md`

Active turn prompt input and response output for each subagent.

#### `<session_dir>/critic_feedback.md` & `archive/critic/chunk_XXXX.md`

Latest and per-chunk archived editorial style critiques and fact-check
verification logs.

## Multi-Layer Index Organization & Navigation

All three indexed domains (`<domain>` = `chunks`, `entries`, or `predictions`)
share the same two-axis index tree with byte-bounded archiving:

```text
<session_dir>/<domain>/
├── by_chronology.md
├── by_topic.md
└── archive/
    ├── chronology/
    │   ├── L1_XXXX.md        # Completed narrative arcs (~18–25 chunks)
    │   └── L2_XXXX.md        # Directory rollups (>25 nodes or >12 KB)
    └── topics/
        ├── L1_XXXX.md        # Alphabetical topic range shards (<= 12 KB)
        ├── L2_XXXX.md        # Shard directory rollups (>25 or >12 KB)
        └── topic_XXXX_L1_YYYY.md  # Older slices of one high-volume topic
```

### Resolving Relative Links for `read_file`

Every index and archive file prints `Session Directory` (`<session_dir>`) near
the top, and all Markdown links inside `memory.md` and `<domain>/` index files
are **relative to `<session_dir>`** (for example,
`[chunk_0004](chunks/chunk_0004.md)` or
`[L1_0001.md](chunks/archive/topics/L1_0001.md)`).

Prepend `<session_dir>/` to any relative link target to form the absolute `Path`
required by `read_file` (for example, `<session_dir>/chunks/chunk_0004.md`).

### Chronological Index Tree (`<domain>/by_chronology.md`)

Organizes items in story order by **Arc**, **Chapter**, and **Chunk**:

#### Completed Arc Archives (`archive/chronology/L1_XXXX.md`)

`## Completed Arc Archives` links each finished narrative arc (`Arc 1`, `Arc 2`,
..., ~18–25 chunks aligned to chapter boundaries) to
`<domain>/archive/chronology/L1_XXXX.md`. In `chunks/`, each `L1_XXXX.md` file
also appends the historical `curated_XXXX.md` reader memory snapshot from the
end of that arc. When completed arc links exceed 25 nodes or 12 KB,
intermediate `L2_XXXX.md` directory files group the `L1` links.

#### Current & Recent Arc (Inline)

`## Current & Recent Arc` lists every entry in the current unarchived arc inline
by chapter (retaining at least the 5 most recent entries inline right after an
arc boundary).

### Semantic Topic Index Tree (`<domain>/by_topic.md`)

Inverted index mapping canonical character, faction, location, artifact, and
plot-thread tags to every matching item:

#### Compact Inline Mode (`<= 16 KB` and `<= 350` Lines)

Displays an alphabetical `## Indexed Topics` table of contents followed by every
topic's full bullet list inline under `### <Topic> (<Count>)`.

#### Sharded Mode (Larger Sessions)

Once entries exceed the inline budget, `<domain>/by_topic.md` switches
automatically to two sections:

##### `## Topic Archive Shards`

Alphabetical range shards (`Topic Shard L1.K`) linking to
`<domain>/archive/topics/L1_XXXX.md` (with `L2_XXXX.md` rollups if shard links
exceed 25 nodes or 12 KB) and listing the topics and entry counts in each shard.

##### `## Recently Updated Topics (Last 3 Turns Inline)`

Shows entries from the last 3 chunks inline alongside a
`*(+N earlier entries in [L1_XXXX.md](...))*` pointer to that topic's shard.

#### High-Frequency Per-Topic Archives (`topic_XXXX_L1_YYYY.md`)

When a single recurring topic exceeds 25 entries or 6 KB, older slices of that
topic are archived in `<domain>/archive/topics/topic_XXXX_L1_YYYY.md` (with
`topic_XXXX_L2_ZZZZ.md` rollups if needed) and linked at the top of its
`### <Topic>` section while recent entries remain inline.

#### Topic Shard Freshness vs. Fixed Chronology Arcs

Completed chronological arc paths (`archive/chronology/L1_XXXX.md`) stay fixed
across turns, whereas topic shard numbers (`archive/topics/L1_XXXX.md` and
`topic_XXXX_L1_YYYY.md`) can shift as topics grow or merge. Always start topic
lookups from `<domain>/by_topic.md` on a fresh turn rather than reusing an
older turn's topic shard path.

### Standard Lookup Sequence (`read_file` Without Directory Listing)

1. Check `memory.md` first (`Recent Story Chunks` covers the last 5 chunks;
   `Active Prediction Slate` links active and recent `predictions/pred_XXXX.md`;
   `Completed L1 Story Arcs` lists `Arc K` chapter titles and links directly to
   `chunks/archive/chronology/L1_XXXX.md`).

2. Pick **one** index axis first rather than reading both unless the first
   misses: jump straight to the `chunks/archive/chronology/L1_XXXX.md` link in
   `memory.md` (or read `<domain>/by_chronology.md` for the current unarchived
   arc) when you know the arc, chapter, or timeline position; read
   `<domain>/by_topic.md` when searching by character, entity, tag, or plot
   thread in an unknown chapter.

3. If the target topic or chapter range points to an archive shard
   (`archive/topics/L1_XXXX.md`, `topic_XXXX_L1_YYYY.md`, or
   `archive/chronology/L1_XXXX.md`), follow that link by calling `read_file` on
   `<session_dir>/<relative_link>`.

4. Call `read_file` on the target leaf file
   (`<session_dir>/chunks/chunk_XXXX.md`, `entries/chunk_XXXX.md`, or
   `predictions/pred_XXXX.md`) to inspect the primary text.
