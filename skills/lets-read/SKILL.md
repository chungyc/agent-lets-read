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
  Requires bash and GHC (Glasgow Haskell Compiler, presumed version 9.10.3; the
  Haskell code does not build on certain other GHC versions) with standard boot
  packages (base, binary, bytestring, containers, directory, filepath, process,
  text) and zlib to compile the gatekeeper binary.
---

# Let's Read Skill (Spoiler-Free Architecture)

This skill conducts a genuine, unspoiled **Let's Read** of a story or book in
`.txt`, `.md`, `.markdown`, `.html`, or `.epub` format by combining a
**Haskell Gatekeeper** ([LetsRead.hs](./scripts/LetsRead.hs)) with five
isolated leaf subagents that exchange bulk data via `<session_dir>` files and use
messages strictly as 1-line notifications:

1. **`blind-reader`**: Reads `<session_dir>/current_prompt.md` and the newly
   unlocked chunk (`current_chunk.md`), reacts in character in the session's
   Active Persona, stakes 1 new multi-chapter prediction per chunk, nominates a
   conditional retirement candidate when at the 10-prediction cap, writes its
   response to `<session_dir>/current_reader_response.md` (or
   `<session_dir>/current_discussion_response.md` on discussion turns), and
   replies with a 1-line completion notice.

2. **`prediction-judge`**: Reads `<session_dir>/current_judge_prompt.md` and
   independently evaluates all active predictions against `current_chunk.md`
   after `blind-reader`'s turn, writing verdicts to
   `<session_dir>/current_judge_response.md`.

3. **`fact-checker`** *(runs in parallel with `prediction-judge` and
   `commentary-critic`)*: Reads `<session_dir>/current_fact_check_prompt.md` and
   audits concrete factual and chronological claims in `blind-reader`'s turn
   against primary sources (`current_chunk.md`, `chunks/chunk_XXXX.md`, and
   neutral `search_web` queries), writing its audit to
   `<session_dir>/current_fact_check_response.md`. When `lets-read judge`
   deterministically verifies one or more material disputed claims, it generates
   `<session_dir>/current_discussion_prompt.md` and sets
   `"fact_check_discussion_pending": true`, gating `lets-read next` until
   `blind-reader` responds via `lets-read discuss`.

4. **`commentary-critic`** *(runs in parallel with `prediction-judge` and
   `fact-checker`)*: Reads `<session_dir>/current_critic_prompt.md` and
   evaluates how well `blind-reader`'s entry inhabited the session's Active
   Persona and user style directives, writing its critique to
   `<session_dir>/current_critic_response.md` (which `lets-read judge` verifies
   and writes to `<session_dir>/critic_feedback.md` for silent application on
   the next chunk).

5. **`topic-curator`** *(dispatched in parallel when `record` returns
   `"topic_curation_needed": true`)*: Reads
   `<session_dir>/current_topic_prompt.md`, reviews newly added unvetted topic
   tags against established session topics, and writes synonym/alias merges
   (`=== TOPIC MERGES ===`) to `<session_dir>/current_topic_response.md` for
   `lets-read judge` to apply.

In **Batch Mode**, the host delegates sequential slices of ~10 chunks to fresh
instances of the built-in **`self`** subagent (`Role: "Batch Read-Through
Driver"`) so the parent session host's context window stays bounded across
book-length works.

## Mandatory Anti-Spoiler & Orchestrator Rules

### NEVER Read the Source Story File Directly

- Do **not** call `read_file`, `grep_search`, or `head`/`cat` on the user's
  source story file. Only pass its path to `lets-read init`.

### NEVER Inspect `.vault.bin` or Gatekeeper Source Code

- `<session_dir>/.vault.bin` is an XOR-obfuscated binary archive of all story
  chunks. Treat `.bin/lets-read` as a black-box CLI tool.

### Do NOT Pass `--max-words` Unless Requested

- Always let `lets-read init` use its built-in default unless the user
  explicitly asks for a custom chunk size.

### Strict Subagent Isolation (`<session_dir>` File-Based Data Exchange)

- The five leaf subagents (`blind-reader`, `prediction-judge`, `fact-checker`,
  `commentary-critic`, and `topic-curator`) are defined in [agents/](../../agents/)
  with `subagent: true`, `mainAgent: false`, and explicit `tools` lists
  (`write_file` + `read_file`, plus `search_web` only for `blind-reader` and
  `fact-checker`). When the `lets-read` plugin is installed and enabled, they
  are registered automatically; if running from an uninstalled checkout where
  they are not yet listed in `<subagents>`, define them via
  `define_subagent` using the files in [agents/](../../agents/).
- Leaf subagents only read files inside `<session_dir>`, write only to their
  designated `<session_dir>/current_*_response.md` file via `write_file`
  (`Overwrite: true`), never call `run_command` or `edit_file`, and may use
  `search_web` solely for neutral background lore or canon context (never for
  the specific story being read).

### Use Messages ONLY as 1-Line Notifications — Strict Step Boundaries & No Duplicate Sends

- You (the parent orchestrator) are strictly the **session host and
  gatekeeper relay**, never the reader, judge, fact-checker, critic, or
  topic curator.

- Never answer a user's question about the story in your own voice, and never
  call `edit_file` or `write_file` directly on `<session_dir>/memory.md`.

- **Never read or paste `current_*_prompt.md`, `current_chunk.md`, or
  `memory.md` into `invoke_subagent` or `send_message`**. Keep all bulk data
  in `<session_dir>` files and send **only a 1-line notification message**
  naming the prompt file to read and the response file to write (e.g.,
  `"Chunk XXXX/YYYY ready: read <session_dir>/current_prompt.md via read_file and write your response to <session_dir>/current_reader_response.md."`).

- **Never bundle `run_command` (`lets-read next`, `record`, or `discuss-prompt`)
  with `invoke_subagent` or `send_message` in the same step**: Always run the
  `lets-read` CLI command first and wait for it to exit `0` and write the
  `<session_dir>/current_*_prompt.md` files (and report `"topic_curation_needed"`
  and `"rotate_*_recommended"`) before calling `invoke_subagent` or
  `send_message`.

- **Never send duplicate notifications or poll**: Once `invoke_subagent` or
  `send_message` returns `"Message sent to ..."` or `"Created the following
  subagent"`, end your turn immediately with **zero tool calls**—never call
  `send_message` a second time in the post-tool response step and never poll
  with `manage_subagents(Action: "list")`.

- **Wait for ALL dispatched reviewers before calling `lets-read judge`**:
  When one reviewer's completion notice arrives while any other dispatched
  reviewer (`prediction-judge`, `fact-checker`, `commentary-critic`, or
  `topic-curator`) is still running, end your turn with **zero tool calls**;
  only invoke `lets-read judge` after every dispatched reviewer has sent its
  completion notice.

- Whenever presenting `blind-reader`'s commentary or discussion reply in
  chat, read `<session_dir>/entries/chunk_XXXX.md` (or `entries/wrapup.md`)
  and prefix your message with a clear third-person host banner (e.g.,
  `> **Let's Read Host** — Relaying from \`blind-reader\` (Chunk XXXX/YYYY):`).

### NEVER Run `python`, `python3`, or Ad-Hoc Shell Scripts

- `<skill_dir>/.bin/lets-read` (where `<skill_dir>` is the directory
  containing this `SKILL.md` file) handles all transcript parsing, delimiter
  splitting, receipt verification, indexing, and state management natively in
  compiled Haskell. Use strictly `<skill_dir>/scripts/prepare.sh`,
  `<skill_dir>/.bin/lets-read` (`init`, `next`, `record`, `judge`,
  `discuss-prompt`, `discuss`, `status`), `read_file`, `write_file`,
  `invoke_subagent`, `send_message`, and `manage_subagents`.

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

#### 1. Prepare the Gatekeeper Binary

Run [prepare.sh](./scripts/prepare.sh) as a standalone command to compile
`<skill_dir>/.bin/lets-read` if missing or out of date:

```bash
<skill_dir>/scripts/prepare.sh
```

#### 2. Initialize the Session

Run `<skill_dir>/.bin/lets-read init` as a separate command:

```bash
<skill_dir>/.bin/lets-read init "<source_story_path>" \
  --session "<session_dir>" \
  --persona "<chosen_persona>"
```

### Step 3: Verify the Five Subagents Are Available

When the `lets-read` plugin is installed and enabled, its five leaf subagents
(`write_file` + `read_file`, with `run_command` and `edit_file` omitted) are
already registered in `<subagents>`:

1. [blind-reader.md](../../agents/blind-reader.md) (`Name: "blind-reader"`, `Role: "Blind Story Reader"`)
2. [prediction-judge.md](../../agents/prediction-judge.md) (`Name: "prediction-judge"`, `Role: "Impartial Prediction Judge"`)
3. [fact-checker.md](../../agents/fact-checker.md) (`Name: "fact-checker"`, `Role: "Commentary Fact-Checker"`)
4. [commentary-critic.md](../../agents/commentary-critic.md) (`Name: "commentary-critic"`, `Role: "Commentary Critic"`)
5. [topic-curator.md](../../agents/topic-curator.md) (`Name: "topic-curator"`, `Role: "Topic Index Curator"`)

*(Fallback for uninstalled checkouts: if those five subagents do not yet appear
in `<subagents>`, read each file under [agents/](../../agents/) and call
`define_subagent` with `EnableWriteTools: true`, `EnableSubagentTools: false`,
and `EnableMCPTools: false`.)*

### Step 4: Per-Chunk Execution Loop (`next` → `record` → `judge` → optional `discuss`)

For each chunk to be read:

#### 1. Unlock the Next Chunk (`next`)

```bash
<skill_dir>/.bin/lets-read next --session "<session_dir>"
```

This writes `<session_dir>/current_chunk.md`, `<session_dir>/chunks/chunk_XXXX.md`,
and `<session_dir>/current_prompt.md`, cleans up any stale
`<session_dir>/current_reader_response.md`, and returns JSON metadata
including `"subagent_prompt_file"`, `"reader_response_file"`, and
`"rotate_reader_recommended"`.

#### 2. Notify `blind-reader` (1-Line Message Only — Do NOT Read `current_prompt.md`)

- After `lets-read next` exits `0` (never in the same tool-call step as `next`),
  on the first chunk of a session or batch (when no active `blind-reader`
  exists yet) or when `"rotate_reader_recommended": true` (killing any
  previous `blind-reader` instance via `manage_subagents` with
  `Action: "kill"`), call `invoke_subagent` (`TypeName: "blind-reader"`,
  `Role: "Blind Story Reader"`). Otherwise, call `send_message` to the
  active `blind-reader` `conversationId`.

- Pass **only a 1-line notification** telling `blind-reader` to read
  `<session_dir>/current_prompt.md` via `read_file`, write its output to
  `<session_dir>/current_reader_response.md` via `write_file`
  (`Overwrite: true`), and reply with a 1-line completion notice.

- Once `invoke_subagent` or `send_message` returns, **end your turn with no
  tool calls** and wait for `blind-reader`'s completion notice (never send a
  second notification).

#### 3. Record `blind-reader`'s Turn (`record`)

```bash
<skill_dir>/.bin/lets-read record \
  --session "<session_dir>" \
  --subagent-log "<blind_reader_logAbsoluteUri>"
```

This reads `<session_dir>/current_reader_response.md` (with automatic
fallback to `--subagent-log`), records the entry, updates predictions and
indices, writes `current_judge_prompt.md`, `current_fact_check_prompt.md`,
and `current_critic_prompt.md` (plus `current_topic_prompt.md` when
`"topic_curation_needed": true`), and returns `"rotate_judge_recommended"`,
`"rotate_fact_checker_recommended"`, `"rotate_critic_recommended"`, and
`"topic_curation_needed"`.

#### 4. Notify `prediction-judge`, `fact-checker`, `commentary-critic` (and `topic-curator` When Triggered) in Parallel (1-Line Messages Only)

- After `lets-read record` exits `0` (never in the same tool-call step as
  `record`), do **not** call `read_file` on `current_judge_prompt.md`,
  `current_fact_check_prompt.md`, `current_critic_prompt.md`, or
  `current_topic_prompt.md`.

- **In the same turn**, dispatch the post-record subagents in parallel with
  **1-line notification messages**:

  - For `prediction-judge`, `fact-checker`, and `commentary-critic`, on the
    first chunk of a session or batch (when no active instance of that role
    exists yet) or when its corresponding `"rotate_<role>_recommended": true`
    flag is set (killing any previous instance via `manage_subagents` with
    `Action: "kill"`), call `invoke_subagent`; otherwise call `send_message`
    to its active `conversationId`. Instruct each subagent in 1 line to read
    its `<session_dir>/current_<role>_prompt.md` via `read_file`, write its
    output to `<session_dir>/current_<role>_response.md` via `write_file`
    (`Overwrite: true`), and reply with a 1-line completion notice.

  - If `"topic_curation_needed": true`, also call `invoke_subagent` for
    `topic-curator` (`Role: "Topic Index Curator"`) with a 1-line
    notification to read `<session_dir>/current_topic_prompt.md` and write
    `<session_dir>/current_topic_response.md` (and kill the finished
    `topic-curator` via `manage_subagents` after `judge` completes).

- Once the notifications return, **end your turn with no tool calls** (never
  re-send notifications or poll with `manage_subagents`). Whenever an
  individual reviewer finishes while other dispatched reviewers are still
  running, end that wakeup turn with **no tool calls**; only run `judge`
  after **all** dispatched reviewers have sent their completion notices.

#### 5. Apply Verdicts, Fact-Check Verification, Persona Critique & Topic Merges (`judge`)

```bash
<skill_dir>/.bin/lets-read judge \
  --session "<session_dir>" \
  --subagent-log "<prediction_judge_logAbsoluteUri>" \
  --fact-check-log "<fact_checker_logAbsoluteUri>" \
  --critic-log "<commentary_critic_logAbsoluteUri>" \
  [--topic-log "<topic_curator_logAbsoluteUri>"]
```

*(Reads `<session_dir>/current_judge_response.md`,
`current_fact_check_response.md`, `current_critic_response.md`, and
`current_topic_response.md`, while using `--fact-check-log` / `--*-log` for
tool-call verification and fallback. Pass `--topic-log` whenever
`"topic_curation_needed": true` was triggered on this chunk).*

#### 6. If `"fact_check_discussion_pending": true` — Resolve the Fact-Check Peer Query (`discuss`)

Whenever `lets-read judge` returns `"fact_check_discussion_pending": true`
(status `"awaiting_fact_check_response"`), **do NOT run `next` yet**:

1. Send a **1-line notification** via `send_message` to the active
   `blind-reader` `conversationId` instructing it to read
   `<session_dir>/current_discussion_prompt.md`, write its discussion reply
   to `<session_dir>/current_discussion_response.md` via `write_file`
   (`Overwrite: true`), and reply with a 1-line completion notice.
2. Record `blind-reader`'s response:

   ```bash
   <skill_dir>/.bin/lets-read discuss \
     --session "<session_dir>" \
     --subagent-log "<blind_reader_logAbsoluteUri>"
   ```

#### 7. Dedicated Final Wrapup Round (When `"wrapup_pending": true`)

- Once the final story chunk `N/N` is judged and `"fact_check_discussion_pending"`
  is `false`, run `next` one more time to unlock the **Final Wrapup Round**
  (`"status": "wrapup_unlocked"`).

- Send a **1-line notification** to `blind-reader` via `send_message` to read
  `<session_dir>/current_prompt.md` and write its Final Wrapup response to
  `<session_dir>/current_reader_response.md`.

- Record the Final Wrapup with
  `<skill_dir>/.bin/lets-read record --session "<session_dir>" --subagent-log "<blind_reader_logAbsoluteUri>"`.
  (No `judge` step is needed after `wrapup_recorded`.)

### Step 5: Interactive Discussion vs. Batch Progression

#### Interactive Mode

- Read and present the recorded entry (`<session_dir>/entries/chunk_XXXX.md` or
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

     *(Or write the user message to `<session_dir>/last_user_message.md` and
     pass `--user-file "<session_dir>/last_user_message.md"`).*

  2. Send a **1-line notification** to the active `blind-reader`
     `conversationId` via `send_message` instructing it to read
     `<session_dir>/current_discussion_prompt.md` and write its reply to
     `<session_dir>/current_discussion_response.md`.

  3. Record `blind-reader`'s response using `discuss`:

     ```bash
     <skill_dir>/.bin/lets-read discuss \
       --session "<session_dir>" \
       --user-message "<user_message>" \
       --subagent-log "<blind_reader_logAbsoluteUri>"
     ```

  4. Read the newly appended `### Reader Discussion` section from
     `<session_dir>/entries/chunk_XXXX.md` (or `entries/wrapup.md`) and
     present `blind-reader`'s reply to the user prefixed with the host banner
     (`> **Let's Read Host** — Relaying discussion reply from \`blind-reader\`:`).

#### Batch Mode

Instead of driving every chunk in the main agent's context window, delegate
the read-through in sequential batches of **~10 chunks** (e.g., `1..10`,
`11..20`, etc.; if $\le 3$ chunks would remain after a batch, include them
in the current batch so the story and Final Wrapup Round finish together):

1. Call `invoke_subagent` (`TypeName: "self"`,
   `Role: "Batch Read-Through Driver"`), passing `<skill_dir>`, `<session_dir>`,
   `<skill_dir>/SKILL.md`, and the target ending chunk for this batch. Instruct
   the `self` subagent to:

   - Read `<skill_dir>/SKILL.md` and follow the **Mandatory Anti-Spoiler &
     Orchestrator Rules** and **Step 4: Per-Chunk Execution Loop** for each
     chunk in its assigned batch (including the Final Wrapup Round in
     Step 4.7 if it completes the final chunk `N/N`).

   - Before returning, call `manage_subagents` (`Action: "kill_all"`) to
     terminate all leaf subagents (`blind-reader`, `prediction-judge`,
     `fact-checker`, `commentary-critic`, `topic-curator`) spawned during
     its batch.

   - Return a concise batch summary (`completed_range`, `chunk_index` /
     `total_chunks`, `active_predictions_count`, and `is_finished`).

2. When the `self` batch driver finishes and returns its summary, terminate
   that finished driver via `manage_subagents` (`Action: "kill"`).

3. If more chunks remain before the user's target or `"is_finished": true`,
   invoke a **new** `self` subagent (`Role: "Batch Read-Through Driver"`)
   for the next batch of ~10 chunks.
