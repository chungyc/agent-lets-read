---
name: lets-read
description: >-
  Conducts a spoiler-free, chapter-by-chapter or chunk-by-chunk "Let's Read"
  liveblog of a story (.txt, .md, .html, .epub) using a Haskell gatekeeper
  script, an isolated blind-reader subagent, an impartial prediction-judge
  subagent, a dedicated fact-checker subagent, a persona-driven
  commentary-critic subagent, and an on-demand topic-curator subagent. Use this
  skill whenever the user asks for a Let's Read, liveblog reaction, unspoiled
  first-time read, or incremental commentary on a story or book.
compatibility: >-
  Requires bash and GHC (Glasgow Haskell Compiler) with standard boot packages
  (base, binary, bytestring, containers, directory, filepath, process, text) and
  zlib to compile the gatekeeper binary.
---

# Let's Read Skill (Spoiler-Free Architecture)

This skill conducts a genuine, unspoiled **Let's Read** of a story or book in
`.txt`, `.md`, `.markdown`, `.html`, or `.epub` format by combining a
**Haskell Gatekeeper** ([LetsRead.hs](./scripts/LetsRead.hs)) with five
sandboxed, read-only subagents:

1. **`blind-reader`**: Reads each newly unlocked chunk (`current_chunk.md`),
   reacts in character in the session's Active Persona, stakes 1 new
   multi-chapter prediction per chunk, nominates a conditional retirement
   candidate when at the 10-prediction cap, and updates `memory.md` and the
   multi-layer indices.
2. **`prediction-judge`**: Independently and impartially evaluates all active
   predictions against `current_chunk.md` after `blind-reader`'s turn.
3. **`fact-checker`** *(runs in parallel with `prediction-judge` and
   `commentary-critic`)*: Audits concrete factual and chronological claims in
   `blind-reader`'s turn against primary sources (`current_chunk.md`,
   `chunks/chunk_XXXX.md`, and neutral `search_web` queries). When
   `lets-read judge` deterministically verifies one or more material disputed
   claims, it generates `<session_dir>/current_discussion_prompt.md` and sets
   `"fact_check_discussion_pending": true`, gating `lets-read next` until
   `blind-reader` responds via `lets-read discuss`.
4. **`commentary-critic`** *(runs in parallel with `prediction-judge` and
   `fact-checker`)*: Evaluates how well `blind-reader`'s entry inhabited the
   session's Active Persona and user style directives, delivered via
   `<session_dir>/critic_feedback.md` for silent application on the next chunk.
5. **`topic-curator`** *(dispatched in parallel when `record` returns
   `"topic_curation_needed": true`)*: Reviews newly added unvetted topic tags
   against established session topics and outputs synonym/alias merges
   (`=== TOPIC MERGES ===`) applied by `lets-read judge`.

---

## Mandatory Anti-Spoiler & Orchestrator Rules

1. **NEVER Read the Source Story File Directly**:
   - Do **not** call `read_file`, `grep_search`, or `head`/`cat` on the user's
     source story file. Only pass its path to `lets-read init`.
2. **NEVER Inspect `.vault.bin` or Gatekeeper Source Code**:
   - `<session_dir>/.vault.bin` is an XOR-obfuscated binary archive of all story
     chunks. Treat `.bin/lets-read` as a black-box CLI tool.
3. **Do NOT Pass `--max-words` Unless Requested**:
   - Always let `lets-read init` use its built-in default unless the user
     explicitly asks for a custom chunk size.
4. **Strict Subagent Isolation (`<session_dir>` Hermetic Sandbox)**:
   - The five subagents (`blind-reader`, `prediction-judge`, `fact-checker`,
     `commentary-critic`, and `topic-curator`) are defined in [agents/](../../agents/)
     with `enable_write_tools: false`, `enable_subagent_tools: false`, and
     `enable_mcp_tools: false`. When the `lets-read` plugin is installed and
     enabled, they are registered automatically; if running from an uninstalled
     checkout where they are not yet listed in `<subagents>`, define them via
     `define_subagent` using the files in [agents/](../../agents/).
   - Subagents only read files inside `<session_dir>` and may use `search_web`
     solely for neutral background lore or canon context (never for the specific
     story being read).
5. **NEVER Impersonate Subagents, Edit `memory.md` Directly, or Improvise Prompts**:
   - You (the parent orchestrator) are strictly the **session host and
     gatekeeper relay**, never the reader, judge, fact-checker, critic, or
     topic curator.
   - Never answer a user's question about the story in your own voice, and never
     call `edit_file` or `write_file` directly on `<session_dir>/memory.md`.
   - **Never paste `current_chunk.md` or `memory.md` inline into prompts** or
     improvise custom subagent instructions. Always read the gatekeeper-generated
     prompt files (`current_prompt.md`, `current_judge_prompt.md`,
     `current_fact_check_prompt.md`, `current_critic_prompt.md`,
     `current_topic_prompt.md`, `current_discussion_prompt.md`) and pass their
     contents verbatim.
   - Whenever presenting `blind-reader`'s commentary or discussion reply in
     chat, prefix your message with a clear third-person host banner (e.g.,
     `> **Let's Read Host** — Relaying from \`blind-reader\` (Chunk XXXX/YYYY):`).
6. **NEVER Run `python`, `python3`, or Ad-Hoc Shell Scripts**:
   - `<skill_dir>/.bin/lets-read` (where `<skill_dir>` is the directory
     containing this `SKILL.md` file) handles all transcript parsing, delimiter
     splitting, receipt verification, indexing, and state management natively in
     compiled Haskell. Use strictly `<skill_dir>/scripts/prepare.sh`,
     `<skill_dir>/.bin/lets-read` (`init`, `next`, `record`, `judge`,
     `discuss-prompt`, `discuss`, `status`), `read_file`, `write_file`, and
     `manage_subagents`.

---

## Directory & Resource Layout

Let `<skill_dir>` denote the directory containing this `SKILL.md` file (e.g.,
`skills/lets-read` in the plugin repository or `<plugin_dir>/skills/lets-read`
when installed):

- **Gatekeeper Entrypoint & CLI**: [LetsRead.hs](./scripts/LetsRead.hs) (with submodules under [scripts/LetsRead/](./scripts/LetsRead/))
- **Gatekeeper Build Script**: [prepare.sh](./scripts/prepare.sh)
- **Subagent Definitions** (bundled in plugin [agents/](../../agents/)):
  - **Blind Reader**: [blind-reader.md](../../agents/blind-reader.md)
  - **Prediction Judge**: [prediction-judge.md](../../agents/prediction-judge.md)
  - **Fact-Checker**: [fact-checker.md](../../agents/fact-checker.md)
  - **Commentary Critic**: [commentary-critic.md](../../agents/commentary-critic.md)
  - **Topic Curator**: [topic-curator.md](../../agents/topic-curator.md)
- **Final Wrapup Prompt Template**: [wrapup_prompt_template.md](./resources/wrapup_prompt_template.md)
- **Banned Jargon Linter List**: [banned_jargon.txt](./resources/banned_jargon.txt)
- **Persona Presets**: [personas.md](./references/personas.md)

---

## Workflow

### Step 1: Clarify Session Preferences (If Not Specified)

If the user has not specified their preferences, briefly check or choose sensible defaults:

- **Mode**:
  - **Interactive Mode** *(default)*: Read one chunk (or one chapter) at a time,
    display the commentary and Judge rulings in chat, and pause so the user can
    discuss theories or say "continue".
  - **Batch Mode**: Autonomously read a specified number of chunks/chapters (or
    the entire work), recording all updates and Judge rulings into
    `<session_dir>/lets_read_log.md`.
- **Reader Persona**: See [personas.md](./references/personas.md) for presets
  (default: *Classic Forum Liveblogger*).
- **Session Directory**: Default to `./lets-read-sessions/<story-slug>/` (or a
  user-specified directory).

### Step 2: Initialize the Gatekeeper Session

Read [personas.md](./references/personas.md) if a custom tone or preset was requested.

1. **Prepare the Gatekeeper Binary**:
   Run [prepare.sh](./scripts/prepare.sh) as a standalone command to compile
   `<skill_dir>/.bin/lets-read` if missing or out of date:

   ```bash
   <skill_dir>/scripts/prepare.sh
   ```

2. **Initialize the Session**:
   Run `<skill_dir>/.bin/lets-read init` as a separate command:

   ```bash
   <skill_dir>/.bin/lets-read init "<source_story_path>" \
     --session "<session_dir>" \
     --persona "<chosen_persona>"
   ```

### Step 3: Verify the Five Subagents Are Available

When the `lets-read` plugin is installed and enabled, the five subagents are
already registered in `<subagents>`:

1. [blind-reader.md](../../agents/blind-reader.md) (`Name: "blind-reader"`, `Role: "Blind Story Reader"`)
2. [prediction-judge.md](../../agents/prediction-judge.md) (`Name: "prediction-judge"`, `Role: "Impartial Prediction Judge"`)
3. [fact-checker.md](../../agents/fact-checker.md) (`Name: "fact-checker"`, `Role: "Commentary Fact-Checker"`)
4. [commentary-critic.md](../../agents/commentary-critic.md) (`Name: "commentary-critic"`, `Role: "Commentary Critic"`)
5. [topic-curator.md](../../agents/topic-curator.md) (`Name: "topic-curator"`, `Role: "Topic Index Curator"`)

*(Fallback for uninstalled checkouts: if those five subagents do not yet appear
in `<subagents>`, read each file under [agents/](../../agents/) and call
`define_subagent` with `EnableWriteTools: false`, `EnableSubagentTools: false`,
and `EnableMCPTools: false`.)*

### Step 4: Per-Chunk Execution Loop (`next` → `record` → `judge` → optional `discuss`)

For each chunk to be read:

1. **Unlock the Next Chunk (`next`)**:

   ```bash
   <skill_dir>/.bin/lets-read next --session "<session_dir>"
   ```

   This writes `<session_dir>/current_chunk.md`, `<session_dir>/chunks/chunk_XXXX.md`,
   and `<session_dir>/current_prompt.md`, and returns JSON metadata including
   `"subagent_prompt_file"` and `"rotate_reader_recommended"`.

2. **Dispatch `blind-reader`**:
   - Read `<session_dir>/current_prompt.md`.
   - On Chunk 1 or when `"rotate_reader_recommended": true`, call
     `invoke_subagent` (`TypeName: "blind-reader"`, `Role: "Blind Story Reader"`).
     Otherwise, call `send_message` to the active `blind-reader` `conversationId`.
   - Pass the exact contents of `current_prompt.md`.

3. **Record `blind-reader`'s Turn (`record`)**:

   ```bash
   <skill_dir>/.bin/lets-read record \
     --session "<session_dir>" \
     --subagent-log "<blind_reader_logAbsoluteUri>"
   ```

   This records the entry, updates predictions and indices, writes
   `current_judge_prompt.md`, `current_fact_check_prompt.md`, and
   `current_critic_prompt.md` (plus `current_topic_prompt.md` when
   `"topic_curation_needed": true`), and returns `"rotate_judge_recommended"`,
   `"rotate_fact_checker_recommended"`, `"rotate_critic_recommended"`, and
   `"topic_curation_needed"`.

4. **Dispatch `prediction-judge`, `fact-checker`, `commentary-critic` (and `topic-curator` When Triggered) in Parallel**:
   - Read `current_judge_prompt.md`, `current_fact_check_prompt.md`, and
     `current_critic_prompt.md` (plus `current_topic_prompt.md` if
     `"topic_curation_needed": true`).
   - **In the same turn**, dispatch the post-record subagents in parallel:
     - For `prediction-judge`, `fact-checker`, and `commentary-critic`, call
       `invoke_subagent` on Chunk 1 or when its corresponding
       `"rotate_<role>_recommended": true` flag is set; otherwise call
       `send_message` to its active `conversationId`.
     - If `"topic_curation_needed": true`, also call `invoke_subagent` for
       `topic-curator` (`Role: "Topic Index Curator"`) with the contents of
       `current_topic_prompt.md`.
   - Wait for all dispatched subagents to finish before running `judge`.

5. **Apply Verdicts, Fact-Check Verification, Persona Critique & Topic Merges (`judge`)**:

   ```bash
   <skill_dir>/.bin/lets-read judge \
     --session "<session_dir>" \
     --subagent-log "<prediction_judge_logAbsoluteUri>" \
     --fact-check-log "<fact_checker_logAbsoluteUri>" \
     --critic-log "<commentary_critic_logAbsoluteUri>" \
     [--topic-log "<topic_curator_logAbsoluteUri>"]
   ```
   *(Pass `--topic-log` whenever `"topic_curation_needed": true` was triggered on this chunk).*

6. **If `"fact_check_discussion_pending": true` — Resolve the Fact-Check Peer Query (`discuss`)**:
   - Whenever `lets-read judge` returns `"fact_check_discussion_pending": true`
     (status `"awaiting_fact_check_response"`), **do NOT run `next` yet**:
     1. Read `<session_dir>/current_discussion_prompt.md` and send its exact
        contents via `send_message` to the active `blind-reader` `conversationId`.
     2. Record `blind-reader`'s response:

        ```bash
        <skill_dir>/.bin/lets-read discuss \
          --session "<session_dir>" \
          --subagent-log "<blind_reader_logAbsoluteUri>"
        ```

7. **Dedicated Final Wrapup Round (When `"wrapup_pending": true`)**:
   - Once the final story chunk `N/N` is judged and `"fact_check_discussion_pending"`
     is `false`, run `next` one more time to unlock the **Final Wrapup Round**
     (`"status": "wrapup_unlocked"`).
   - Read `<session_dir>/current_prompt.md` and send it to `blind-reader` via
     `send_message`.
   - Record the Final Wrapup with `<skill_dir>/.bin/lets-read record --session "<session_dir>" --subagent-log "<blind_reader_logAbsoluteUri>"`.
     (No `judge` step is needed after `wrapup_recorded`.)

### Step 5: Interactive Discussion vs. Batch Progression

- **In Interactive Mode**:
  - Present the recorded entry (`<session_dir>/entries/chunk_XXXX.md` or
    `<session_dir>/entries/wrapup.md`) prefixed with the third-person host banner
    (`> **Let's Read Host** — Relaying from \`blind-reader\` & \`prediction-judge\` (Chunk XXXX/YYYY):`),
    and link to `<session_dir>/lets_read_log.md`, `<session_dir>/memory.md`,
    `<session_dir>/predictions/by_chronology.md`, and
    `<session_dir>/predictions/by_topic.md` (plus `entries/wrapup.md` and
    `predictions/hall_of_fame.md` when finished). Do **not** read or relay
    `critic_feedback.md` unless asked.
  - If the user replies with comments, questions, or non-spoiler discussion:
    1. Generate `<session_dir>/current_discussion_prompt.md` using
       `discuss-prompt` (scrubbing any spoilers from the user's message if
       applicable):

       ```bash
       <skill_dir>/.bin/lets-read discuss-prompt \
         --session "<session_dir>" \
         --user-message "<user_message>"
       ```
       *(Or write the user message to `<session_dir>/last_user_message.md` and pass `--user-file "<session_dir>/last_user_message.md"`).*

    2. Read `<session_dir>/current_discussion_prompt.md` and send its exact
       contents to the active `blind-reader` `conversationId` via `send_message`.
    3. Record `blind-reader`'s response using `discuss`:

       ```bash
       <skill_dir>/.bin/lets-read discuss \
         --session "<session_dir>" \
         --user-message "<user_message>" \
         --subagent-log "<blind_reader_logAbsoluteUri>"
       ```

    4. Present `blind-reader`'s reply to the user prefixed with the host banner
       (`> **Let's Read Host** — Relaying discussion reply from \`blind-reader\`:`).

- **In Batch Mode**:
  - Repeat Step 4 (`next` → `blind-reader` → `record` → `prediction-judge` +
    `fact-checker` + `commentary-critic` (+ `topic-curator` when triggered) in
    parallel → `judge` → optional `discuss`, followed by the Final Wrapup Round
    after Chunk `N/N`) until the target number of chunks/chapters or
    `"is_finished": true` is reached, rotating each subagent whenever its
    `"rotate_<role>_recommended": true` flag is set.
