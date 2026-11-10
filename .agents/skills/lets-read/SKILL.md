---
name: lets-read
description: >-
  Conducts a spoiler-free, chapter-by-chapter or chunk-by-chunk "Let's Read"
  liveblog of a story (.txt, .md, .html, .epub) using a Haskell gatekeeper
  script, an isolated blind-reader subagent, an impartial prediction-judge
  subagent, a dedicated fact-checker subagent, and a persona-driven
  commentary-critic subagent. Use this skill whenever the user asks for a Let's
  Read, liveblog reaction, unspoiled first-time read, or incremental commentary
  on a story or book.
---

# Let's Read Skill (Spoiler-Free Architecture)

This skill enables a genuine, unspoiled **Let's Read** of a story or book in
`.txt`, `.md`, `.markdown`, `.html`, or `.epub` format. It solves the
fundamental problems of AI Let's Reads—accidentally reading ahead or leaking
future plot points into context, self-serving prediction grading, factual/canon
hallucinations, and persona/tone drift—by combining a **Haskell Gatekeeper**
([LetsRead.hs](./scripts/LetsRead.hs)) with four sandboxed subagents:

1. **`blind-reader`**: Reads each newly unlocked chunk, proactively verifies
   earlier-chunk details (`read_file` on `chunks/chunk_XXXX.md`) and external
   canon claims (`search_web`), reacts in character in its Active Persona
   (including reacting naturally to how the Judge ruled on its prior
   predictions and silently applying editorial coaching from
   `commentary-critic`), stakes 1 new multi-chapter prediction per chunk, and
   nominates a conditional retirement candidate when at the 10-prediction cap.

2. **`prediction-judge`**: Independently and impartially evaluates **all**
   active predictions (including the newly created prediction and any
   conditional retirement candidate) against `current_chunk.md` after
   `blind-reader`'s turn. Conditional retirement only triggers if more than 10
   predictions remain active *after* `prediction-judge` renders its verdicts.

3. **`fact-checker`** *(runs in parallel with `prediction-judge` and
   `commentary-critic`)*: Audits the concrete factual and chronological claims
   in `blind-reader`'s commentary, chunk summary, new prediction premise
   (`**Clue/Anomaly**`), and memory against the three primary sources of truth
   (`current_chunk.md`, earlier `chunks/chunk_XXXX.md` via `read_file`—never
   `memory.md` alone—and external reference/canon via neutral `search_web`
   queries). When `LetsRead.hs judge` deterministically verifies one or more
   material disputed claims, it generates
   `<session_dir>/current_discussion_prompt.md` and sets
   `"fact_check_discussion_pending": true`, gating `LetsRead.hs next` until the
   active `blind-reader` independently checks the primary source (`read_file` /
   `search_web`) and responds via `LetsRead.hs discuss` (either conceding and
   updating `memory.md`/`pred_NNNN.md` or rebutting the query with primary-source
   receipts).

4. **`commentary-critic`** *(runs in parallel with `prediction-judge` and
   `fact-checker`)*: Writes a concise editorial critique
   (`=== PERSONA & STYLE CRITIQUE ===`) on every turn evaluating how well
   `blind-reader`'s entry inhabited the session's **Active Reader Persona** (and
   any user style directives in `memory.md`), delivered via
   `<session_dir>/critic_feedback.md` for silent application on the next chunk.

---

## Mandatory Anti-Spoiler Rules

1. **NEVER Read the Source Story File Directly**:

   - Do **not** call `read_file`, `grep_search`, or `head`/`cat` on the user's
     source story file.

   - Only pass the source file path to `LetsRead.hs init`.

2. **NEVER Inspect `.vault.bin`**:

   - `LetsRead.hs init` encodes all story chunks into `<session_dir>/.vault.bin`
     (an XOR-obfuscated binary archive) so neither `grep_search` nor file
     inspection can leak future text.

3. **Do NOT Read or Inspect `LetsRead.hs`**:

   - Treat `LetsRead.hs` as a black-box tool. Run it strictly using the CLI
     commands documented below; do not read or inspect its source code.

4. **Do NOT Pass `--max-words` Unless Requested**:

   - Never pass `--max-words` when initializing sessions unless the user
     explicitly asks for a custom chunk size. Always let `LetsRead.hs` use its
     built-in default.

5. **Strict Subagent Isolation & Verified Archive Access**:

   - All reading/commentary generation, prediction judging, fact-checking, and
     persona/style coaching must be performed by dedicated `blind-reader`,
     `prediction-judge`, `fact-checker`, and `commentary-critic` subagents
     created with `EnableWriteTools: false`.

   - Never tell any subagent the path to the original source story file, and
     never allow them to inspect `<session_dir>/.vault.bin` or local workspace
     files outside `<session_dir>`.

   - **Background Lore Searches Allowed**: While subagents must never search the
     web for the *specific story being read*, they **may** use `search_web`
     (and their training knowledge) to look up background canon lore,
     source-material context (e.g., for fanfiction, crossovers, sequels, or
     adaptations), fandom theories, or historical/literary allusions.

   - Pass `blind-reader` the paths in `<session_dir>/current_prompt.md`
     (generated by `LetsRead.hs next`) or
     `<session_dir>/current_discussion_prompt.md` (generated by `LetsRead.hs
     judge` when `"fact_check_discussion_pending": true`), pass
     `prediction-judge` `<session_dir>/current_judge_prompt.md`, pass
     `fact-checker` `<session_dir>/current_fact_check_prompt.md`, and pass
     `commentary-critic` `<session_dir>/current_critic_prompt.md` (all three
     generated by `LetsRead.hs record`):

     - `<session_dir>/current_chunk.md` (current unlocked story chunk —
       mandatory read every turn)

     - `<session_dir>/memory.md` (running summary, auto-maintained archive/index
       tree, and auto-maintained active prediction slate — mandatory read for
       `blind-reader`, `fact-checker`, and `commentary-critic`, optional context
       for `prediction-judge`)

     - `<session_dir>/critic_feedback.md` (private backstage persona & style
       critique from `commentary-critic` — routed exclusively to `blind-reader`
       via `current_prompt.md` and never shown to the parent orchestrator)

     - `.agents/skills/lets-read/resources/commentary_template.md` (flexible
       commentary structure guide — allowed on-demand via `read_file`)

     - `<session_dir>/chunks/` (unlocked story chunks `chunk_0001.md` ..
       `chunk_XXXX.md`, plus auto-maintained multi-layer chronological and
       semantic topic indices `by_chronology.md`, `by_topic.md`,
       `archive/chronology/`, and `archive/topics/` — allowed on-demand via
       `read_file` to verify callbacks and quotes without hallucinating)

     - `<session_dir>/entries/` (recorded Let's Read commentary `chunk_0001.md`
       .. `chunk_XXXX.md` and `wrapup.md`, plus auto-maintained multi-layer
       chronological and semantic topic indices `by_chronology.md`,
       `by_topic.md`, `archive/chronology/`, and `archive/topics/` — allowed
       on-demand via `read_file`)

     - `<session_dir>/predictions/` (auto-indexed prediction files:
       `by_chronology.md`, `by_topic.md`, `archive/chronology/`,
       `archive/topics/`, `pred_XXXX.md`, and upon story completion
       `hall_of_fame.md` — allowed on-demand via `read_file`)

     - `<session_dir>/archive/memory/` (end-of-arc curated memory snapshots
       `curated_XXXX.md` and per-chunk full memory snapshots `chunk_XXXX.md` —
       allowed on-demand via `read_file`)

6. **NEVER Impersonate Subagents, Answer Story Questions Directly, Edit `memory.md` Directly, or Paste Chunks/Memory Inline**:

   - You (the parent orchestrator) are strictly the **session host and
     gatekeeper relay**, never the reader, judge, fact-checker, or critic.

   - Never answer a user's question, comment, or observation about the story in
     your own voice, and never call `edit_file` or `write_file` directly on
     `<session_dir>/memory.md` (all updates must flow through `LetsRead.hs
     record`, `LetsRead.hs judge`, or `LetsRead.hs discuss`).

   - **Never paste `current_chunk.md` or `memory.md` inline into prompts**,
     never improvise custom subagent prompts after context compaction, and never
     append ad-hoc memory-size or line-count nagging. Always read
     `<session_dir>/current_prompt.md` or
     `<session_dir>/current_discussion_prompt.md` (for `blind-reader`),
     `<session_dir>/current_judge_prompt.md` (for `prediction-judge`),
     `<session_dir>/current_fact_check_prompt.md` (for `fact-checker`), and
     `<session_dir>/current_critic_prompt.md` (for `commentary-critic`) and
     pass their contents verbatim.

   - Whenever presenting `blind-reader`'s commentary or discussion reply in
     chat, always prefix your message with a clear third-person host banner
     (e.g., `> **Let's Read Host** — Relaying from \`blind-reader\` (Chunk XXXX/YYYY):`)
     so the conversation history and any context compaction summaries always
     preserve the boundary between the host and `blind-reader`.

7. **NEVER Run `python`, `python3`, or Ad-Hoc Shell Scripts**:

   - Do **not** run `python`, `python3`, `node`, `perl`, or any ad-hoc
     shell/Python one-liners to extract subagent responses from
     `transcript.jsonl`, splice or pre-process `last_response.md` / `memory.md`,
     check byte/line counts, or escape multi-line strings.

   - `LetsRead.hs` handles all parsing, prediction auditing, Judge verdict
     application, Fact-Checker receipt verification, Critic feedback rendering,
     chronological/topic prediction indexing, memory merging, byte/line
     counting, and subagent transcript extraction natively in compiled Haskell.
     Use strictly `.agents/skills/lets-read/scripts/prepare.sh`,
     `.agents/skills/lets-read/.bin/lets-read` (`init`, `next`, `record`,
     `judge`, `discuss`, `status`), `read_file`, `write_file`, and
     `manage_subagents`.

---

## Directory & Resource Layout

- **Haskell Gatekeeper**: [LetsRead.hs](./scripts/LetsRead.hs)

- **Gatekeeper Build Script**: [prepare.sh](./scripts/prepare.sh)

- **Blind Reader System Prompt**: [reader_system_prompt.md](./resources/reader_system_prompt.md)

- **Prediction Judge System Prompt**: [judge_system_prompt.md](./resources/judge_system_prompt.md)

- **Fact-Checker System Prompt**: [fact_checker_system_prompt.md](./resources/fact_checker_system_prompt.md)

- **Commentary Critic System Prompt**: [critic_system_prompt.md](./resources/critic_system_prompt.md)

- **Reader Memory Template**: [memory_template.md](./resources/memory_template.md)

- **Commentary Template**: [commentary_template.md](./resources/commentary_template.md)

- **Persona Presets**: [personas.md](./references/personas.md)

---

## Workflow

### Step 1: Clarify Session Preferences (If Not Specified)

If the user has not specified their preferences, briefly check or choose
sensible defaults:

- **Mode**:

  - **Interactive Mode** *(default)*: Read one chunk (or one chapter) at a
    time, display the commentary and Judge rulings in chat, and pause so the
    user can discuss theories or say "continue".

  - **Batch Mode**: Autonomously read a specified number of chunks/chapters (or
    the entire work), recording all updates and Judge rulings into
    `<session_dir>/lets_read_log.md`.

- **Reader Persona**: See [personas.md](./references/personas.md) for presets
  (default: *Classic Forum Liveblogger*).

- **Session Directory**: Default to `./lets-read-sessions/<story-slug>/` (or a
  user-specified directory).

### Step 2: Initialize the Gatekeeper Session

Read [personas.md](./references/personas.md) if a custom tone was requested.

1. **Prepare the Gatekeeper Binary**:

   Run [prepare.sh](./scripts/prepare.sh) as a standalone command to ensure
   `.agents/skills/lets-read/.bin/lets-read` is compiled and up to date
   (rebuilding only if missing or if `LetsRead.hs` is newer):

   ```bash
   .agents/skills/lets-read/scripts/prepare.sh
   ```

2. **Initialize the Session**:

   Run `.agents/skills/lets-read/.bin/lets-read init` as a separate command:

   ```bash
   .agents/skills/lets-read/.bin/lets-read init "<source_story_path>" \
     --session "<session_dir>" \
     --persona "<chosen_persona>"
   ```

Verify the JSON output from `init`, which reports `total_chapters`,
`total_chunks`, `total_words`, `predictions_dir`, `memory_file`, and `log_file`
without revealing any future chapter titles or story text.

### Step 3: Define the `blind-reader`, `prediction-judge`, `fact-checker`, and `commentary-critic` Subagents

1. Read [reader_system_prompt.md](./resources/reader_system_prompt.md) and call
   `define_subagent`:

   - `Name`: `"blind-reader"`
   - `Description`: `"Sandboxed first-time reader that reacts to one unlocked story chunk at a time, proposes 1 new prediction per chunk, and nominates conditional retirement candidates without access to future chapters."`
   - `SystemPrompt`: The contents of [reader_system_prompt.md](./resources/reader_system_prompt.md).
   - `EnableWriteTools`: `false`
   - `EnableSubagentTools`: `false`
   - `EnableMCPTools`: `false`

2. Read [judge_system_prompt.md](./resources/judge_system_prompt.md) and call
   `define_subagent`:

   - `Name`: `"prediction-judge"`
   - `Description`: `"Impartial, unspoiled referee that evaluates all active predictions against the newly unlocked story chunk."`
   - `SystemPrompt`: The contents of [judge_system_prompt.md](./resources/judge_system_prompt.md).
   - `EnableWriteTools`: `false`
   - `EnableSubagentTools`: `false`
   - `EnableMCPTools`: `false`

3. Read [fact_checker_system_prompt.md](./resources/fact_checker_system_prompt.md)
   and call `define_subagent`:

   - `Name`: `"fact-checker"`
   - `Description`: `"Unspoiled fact-checker that verifies the blind reader's factual claims, callbacks, prediction premises, and memory against unlocked story chunks and external reference material, raising receipt-backed peer verification queries."`
   - `SystemPrompt`: The contents of [fact_checker_system_prompt.md](./resources/fact_checker_system_prompt.md).
   - `EnableWriteTools`: `false`
   - `EnableSubagentTools`: `false`
   - `EnableMCPTools`: `false`

4. Read [critic_system_prompt.md](./resources/critic_system_prompt.md) and call
   `define_subagent`:

   - `Name`: `"commentary-critic"`
   - `Description`: `"Unspoiled editorial peer reviewer that writes a concise persona and style critique of each entry against the session's Active Persona and user style directives."`
   - `SystemPrompt`: The contents of [critic_system_prompt.md](./resources/critic_system_prompt.md).
   - `EnableWriteTools`: `false`
   - `EnableSubagentTools`: `false`
   - `EnableMCPTools`: `false`

### Step 4: Unlock, React, Record, Judge/Fact-Check/Critique, and Resolve Any Fact-Check Peer Queries

For each chunk to be read:

1. **Unlock the Next Chunk (`next`)**:

   ```bash
   .agents/skills/lets-read/.bin/lets-read next --session "<session_dir>"
   ```

   This unlocks the next chunk into `<session_dir>/current_chunk.md`, writes the
   canonical reader prompt to `<session_dir>/current_prompt.md` (automatically
   linking `<session_dir>/critic_feedback.md` from the previous turn), archives a
   permanent copy into `<session_dir>/chunks/chunk_XXXX.md`, and prints
   spoiler-free metadata (`chunk_index`, `total_chunks`, `chapter_number`,
   `chapter_title`, `part_in_chapter`, `parts_in_chapter`, `word_count`,
   `subagent_prompt_file`).

   - *Guardrail*: `LetsRead.hs next` will refuse to advance if the previous
     chunk has not completed `record`, `judge`, and (when
     `"fact_check_discussion_pending": true`) `discuss`.

2. **Invoke or Message `blind-reader` (Using `<session_dir>/current_prompt.md`)**:

   - **First chunk (or at a chapter boundary when `LetsRead.hs next` returns `"rotate_reader_recommended": true`)**:
     Call `invoke_subagent` with `TypeName: "blind-reader"` and `Role: "Blind Story Reader"`.

   - **Consecutive chunks**:
     Call `send_message` to the active `blind-reader` `conversationId` so a
     single reader instance handles the entire chapter.

   - **Prompt to `blind-reader`**:
     Read `<session_dir>/current_prompt.md` and pass its exact text to
     `blind-reader` (never paste `current_chunk.md` or `memory.md` inline).

3. **Record `blind-reader`'s Commentary, New Prediction, Conditional Retirement & Memory (`record`)**:

   Pass `blind-reader`'s `logAbsoluteUri` directly via `--subagent-log`:

   ```bash
   .agents/skills/lets-read/.bin/lets-read record \
     --session "<session_dir>" \
     --subagent-log "<blind_reader_logAbsoluteUri>"
   ```

   `LetsRead.hs record` automatically:

   - Splits `=== COMMENTARY ===`, `=== CHUNK SUMMARY ===` (`[Story | Topics: ...]`
     and `[Entry | Topics: ...]`), `=== PREDICTION UPDATES ===`, and
     `=== UPDATED MEMORY ===`, and syncs the multi-layer chronological and
     semantic topic indices across `chunks/`, `entries/`, and `predictions/`.

   - Runs a deterministic style/anti-pattern linter on `=== COMMENTARY ===`.

   - Adds `blind-reader`'s new prediction as `ACTIVE`, stores any conditional
     `RETIRED` nomination in `.state.bin` (without retiring it yet), and
     generates `<session_dir>/current_judge_prompt.md` (for `prediction-judge`),
     `<session_dir>/current_fact_check_prompt.md` (for `fact-checker`), and
     `<session_dir>/current_critic_prompt.md` (for `commentary-critic`).

   - Outputs `"status": "awaiting_judge"`, `"judge_prompt_file"`,
     `"fact_check_prompt_file"`, `"critic_prompt_file"`,
     `"rotate_critic_recommended"` (every 7 chunks),
     `"rotate_fact_checker_recommended"` (every 9 chunks), and
     `"rotate_judge_recommended"` (every 11 chunks).

4. **Invoke or Message `prediction-judge`, `fact-checker`, AND `commentary-critic` in Parallel**:

   - Read `<session_dir>/current_judge_prompt.md`,
     `<session_dir>/current_fact_check_prompt.md`, and
     `<session_dir>/current_critic_prompt.md`.

   - **In the same turn**, dispatch **all three** subagents in parallel
     (rotating each independently on its own staggered schedule):

     - **`prediction-judge`**: Call `invoke_subagent` (`Role: "Impartial Prediction Judge"`)
       on Chunk 1 or when `record` returns `"rotate_judge_recommended": true`;
       otherwise call `send_message` to the active `prediction-judge`
       `conversationId`.

     - **`fact-checker`**: Call `invoke_subagent` (`Role: "Commentary Fact-Checker"`)
       on Chunk 1 or when `record` returns `"rotate_fact_checker_recommended": true`;
       otherwise call `send_message` to the active `fact-checker`
       `conversationId`.

     - **`commentary-critic`**: Call `invoke_subagent` (`Role: "Commentary Critic"`)
       on Chunk 1 or when `record` returns `"rotate_critic_recommended": true`;
       otherwise call `send_message` to the active `commentary-critic`
       `conversationId`.

   - Wait for all three subagents to finish before running `LetsRead.hs judge`.

5. **Apply Judge Verdicts, Conditional Retirement, Fact-Check Verification & Persona Critique (`judge`)**:

   Pass `prediction-judge`'s `logAbsoluteUri` via `--subagent-log`,
   `fact-checker`'s `logAbsoluteUri` via `--fact-check-log`, and
   `commentary-critic`'s `logAbsoluteUri` via `--critic-log`:

   ```bash
   .agents/skills/lets-read/.bin/lets-read judge \
     --session "<session_dir>" \
     --subagent-log "<prediction_judge_logAbsoluteUri>" \
     --fact-check-log "<fact_checker_logAbsoluteUri>" \
     --critic-log "<commentary_critic_logAbsoluteUri>"
   ```

   `LetsRead.hs judge` automatically:

   - Applies `prediction-judge`'s `CONFIRMED`, `DEBUNKED`, `SUBVERTED`, and
     `ACTIVE` verdicts to all active predictions (including any prediction
     `blind-reader` nominated for retirement).

   - **Conditionally applies `blind-reader`'s retirement nomination ONLY if more
     than 10 active predictions remain after `prediction-judge`'s verdicts**
     (skipping any candidate the Judge already resolved).

   - Processes `fact-checker`'s disputed-fact flags, `commentary-critic`'s
     persona critique, and any deterministic linter warnings:

     - Deterministically verifies every in-story quote
       (`Source: chunks/chunk_XXXX.md | Quote: "..."`) against
       `<session_dir>/chunks/chunk_XXXX.md` on disk and every `[External Canon]`
       flag against `fact-checker`'s `search_web` tool calls, stripping any
       unverified flag.

     - Rewrites verified flags into non-authoritative
       `[Peer Verification Query | ...]` bullets (keeping the verbatim excerpt
       and search query visible so `blind-reader` can inspect the receipt).

     - Writes `<session_dir>/critic_feedback.md` (containing only
       `commentary-critic`'s persona/style critique and deterministic linter
       warnings, for silent application on Chunk $N+1$) and
       `<session_dir>/archive/critic/chunk_XXXX.md` (which archives the full
       `=== VERIFIED CLAIMS LOG ===`, peer verification queries, and style
       critique).

     - If one or more verified disputed claims exist, writes
       `<session_dir>/current_fact_check_questions.md` and
       `<session_dir>/current_discussion_prompt.md`, and returns
       `"status": "awaiting_fact_check_response"` and
       `"fact_check_discussion_pending": true`.

   - Appends `> [!NOTE]\n> **Prediction Judge Rulings (Chunk XXXX)**:` to
     `<session_dir>/entries/chunk_XXXX.md` and rebuilds
     `<session_dir>/lets_read_log.md`.

   - Updates `### Latest Prediction Judge Rulings` in `<session_dir>/memory.md`
     (and `<session_dir>/archive/memory/chunk_XXXX.md`),
     `<session_dir>/predictions/pred_XXXX.md`,
     `<session_dir>/predictions/by_chronology.md`, and
     `<session_dir>/predictions/by_topic.md`.

6. **If `"fact_check_discussion_pending": true` — Resolve the Fact-Check Peer Query Before Proceeding (`discuss`)**:

   - Whenever `LetsRead.hs judge` returns `"fact_check_discussion_pending": true`
     (status `"awaiting_fact_check_response"`), **do NOT run `next` yet**:

     1. Read `<session_dir>/current_discussion_prompt.md` and send its exact
        contents via `send_message` to the **same active `blind-reader`
        `conversationId`** that just wrote Chunk $N$.

     2. `blind-reader` independently checks the cited
        `<session_dir>/chunks/chunk_XXXX.md` via `read_file` and/or runs its own
        neutral `search_web` query, and replies in character—either conceding
        and emitting updated `=== UPDATED MEMORY ===` /
        `=== PREDICTION UPDATES ===` (`[Predicted Chunk NNNN]`) /
        `=== CHUNK SUMMARY ===`, or rebutting the query with primary-source
        quotes.

     3. Record `blind-reader`'s response with `LetsRead.hs discuss`:

        ```bash
        .agents/skills/lets-read/.bin/lets-read discuss \
          --session "<session_dir>" \
          --subagent-log "<blind_reader_logAbsoluteUri>"
        ```

        This appends the exchange under `### Reader Discussion` in
        `<session_dir>/entries/chunk_XXXX.md` (labeled
        `> **Fact-Check Peer Query (Unspoiled AI Peer — Verify Against Primary Source)**:`),
        appends the `[Discussion | Topics: ...]` summary to `entries/by_chronology.md`
        and `entries/by_topic.md`, updates `memory.md`, `chunks/`, and
        `predictions/pred_XXXX.md` if amended, and clears
        `"fact_check_discussion_pending": false`.

7. **Dedicated Final Wrapup Round (After Final Story Chunk `N/N` Is Judged and Any Fact-Check Query Is Resolved)**:

   - Once `Chunk N/N` has been recorded, judged, and has
     `"fact_check_discussion_pending": false` (`"wrapup_pending": true`), run
     `next` one more time to unlock the **Final Wrapup Round**:

     ```bash
     .agents/skills/lets-read/.bin/lets-read next --session "<session_dir>"
     ```

     This outputs `"status": "wrapup_unlocked"` and writes the Final Wrapup
     prompt to `<session_dir>/current_prompt.md`.

   - Read `<session_dir>/current_prompt.md` and send it to `blind-reader` via
     `send_message` (so `blind-reader` can read
     `<session_dir>/predictions/hall_of_fame.md` and `<session_dir>/memory.md`
     and write its whole-story retrospective without diluting `Chunk N/N`'s live
     reaction).

   - Record the Final Wrapup using `record`:

     ```bash
     .agents/skills/lets-read/.bin/lets-read record \
       --session "<session_dir>" \
       --subagent-log "<blind_reader_logAbsoluteUri>"
     ```

     This writes `<session_dir>/entries/wrapup.md`, appends both the Final
     Wrapup and the **Prediction Hall of Fame & Shame** to
     `<session_dir>/lets_read_log.md`, and outputs `"status": "wrapup_recorded"`
     and `"is_finished": true`. (No `judge` step is needed after
     `wrapup_recorded`.)

### Step 5: Interactive Discussion vs. Batch Progression

- **In Interactive Mode**:

  - Present the recorded entry (`<session_dir>/entries/chunk_XXXX.md` or
    `<session_dir>/entries/wrapup.md`) to the user, always prefixed with a
    third-person host attribution banner
    (`> **Let's Read Host** — Relaying from \`blind-reader\` & \`prediction-judge\` (Chunk XXXX/YYYY):`),
    and link to `<session_dir>/lets_read_log.md`, `<session_dir>/memory.md`,
    `<session_dir>/predictions/by_chronology.md`, and
    `<session_dir>/predictions/by_topic.md` (plus
    `<session_dir>/entries/wrapup.md` and
    `<session_dir>/predictions/hall_of_fame.md` when finished). Do **not** read
    or relay `<session_dir>/critic_feedback.md` to the user unless asked—it is
    private backstage style coaching for `blind-reader`.

  - If the user replies with comments, questions, or non-spoiler discussion
    before asking for the next chunk (or after the Final Wrapup):

    1. **Never answer in your own voice**: Forward their message (scrubbed of
       any spoilers, if applicable) to the `blind-reader` subagent via
       `send_message` so the reader persona can discuss theories with the user
       like a live forum thread host. Instruct `blind-reader` to output its
       **full** reply directly in its final response text and, if the exchange
       establishes or updates a factual/timeline correction, a craft/style
       course-correction, a running gag, a character status, or a
       mystery/prediction update, to append `=== PREDICTION UPDATES ===` (if
       predictions changed) and/or a complete `=== UPDATED MEMORY ===` block
       (the 4 narrative sections) so `LetsRead.hs discuss` persists them across
       future subagent rotations.

    2. Run `LetsRead.hs discuss` (passing
       `--subagent-log "<subagent_logAbsoluteUri>"` or
       `--response-file "<session_dir>/last_response.md"`, and passing
       `--user-message "<short comment>"` or
       `--user-file "<session_dir>/last_user_message.md"`):

       ```bash
       .agents/skills/lets-read/.bin/lets-read discuss \
         --session "<session_dir>" \
         --user-file "<session_dir>/last_user_message.md" \
         --subagent-log "<subagent_logAbsoluteUri>"
       ```

    3. Present `blind-reader`'s reply to the user prefixed with the
       third-person host banner
       (`> **Let's Read Host** — Relaying discussion reply from \`blind-reader\`:`).

- **In Batch Mode**:

  - Repeat Step 4 (`next` $\rightarrow$ `blind-reader` $\rightarrow$ `record`
    $\rightarrow$ `prediction-judge` + `fact-checker` + `commentary-critic` in
    parallel $\rightarrow$ `judge` $\rightarrow$ if
    `"fact_check_discussion_pending": true`, send
    `current_discussion_prompt.md` to `blind-reader` + `discuss`, followed by
    the Final Wrapup Round `next` $\rightarrow$ `blind-reader` $\rightarrow$
    `record` after `Chunk N/N`) until the target number of chunks/chapters (or
    `"is_finished": true`) is reached.

  - Rotate each subagent independently when its respective rotation flag
    triggers (`"rotate_reader_recommended": true` from `next` at chapter
    boundaries; `"rotate_critic_recommended": true` every 7 chunks,
    `"rotate_fact_checker_recommended": true` every 9 chunks, and
    `"rotate_judge_recommended": true` every 11 chunks from `record`) so their
    context windows stay sharp without simultaneous handoffs.
