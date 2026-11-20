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
`.txt`, `.md`, `.markdown`, `.html`, or `.epub` format by combining a **Haskell
Gatekeeper** ([LetsRead.hs](./scripts/LetsRead.hs)) with five isolated leaf
subagents that exchange bulk data via predetermined `<session_dir>` files.

## Subagent Architecture

### `blind-reader`

Reads `<session_dir>/current_prompt.md` and `current_chunk.md`, reacts in the
session's Active Persona, stakes 1 multi-chapter prediction per chunk (plus 1
conditional retirement candidate when at the 10-prediction cap), writes
`<session_dir>/current_reader_response.md` (or `current_discussion_response.md`
on discussion turns), and ends its turn with a 1-line completion notice ending
in a `[Tools: ...]` receipt.

### `prediction-judge`

Reads `<session_dir>/current_judge_prompt.md` and independently evaluates all
active predictions against `current_chunk.md`, writing verdicts to
`<session_dir>/current_judge_response.md`.

### `fact-checker`

Runs in parallel with `prediction-judge` and `commentary-critic`. Reads
`<session_dir>/current_fact_check_prompt.md`, audits concrete factual and
chronological claims against primary sources (`current_chunk.md`,
`chunks/chunk_XXXX.md`, and neutral `search_web` queries), and writes
`<session_dir>/current_fact_check_response.md` (with a `[Tools: ...]` receipt).
Verified material disputes set `"fact_check_discussion_pending": true` and gate
`lets-read next` until `blind-reader` responds via `lets-read discuss`.

### `commentary-critic`

Runs in parallel with `prediction-judge` and `fact-checker`. Reads
`<session_dir>/current_critic_prompt.md` and evaluates how well the entry
inhabited the Active Persona and user style directives, writing notes to
`<session_dir>/current_critic_response.md` for silent uptake on the next chunk.

### `topic-curator`

Dispatched in parallel when `record` returns `"topic_curation_needed": true`.
Reads `<session_dir>/current_topic_prompt.md` and writes synonym or alias
merges (`=== TOPIC MERGES ===`) to `<session_dir>/current_topic_response.md`
for `lets-read judge` to apply.

In **Batch Mode**, the host delegates sequential slices of ~10 chunks to fresh
instances of the built-in **`self`** subagent (`Role: "Batch Read-Through
Driver"`) so the parent host's context window stays bounded across long works.

## Mandatory Anti-Spoiler & Orchestrator Rules

### NEVER Read the Source Story File Directly

Do **not** call `read_file`, `grep_search`, or `head`/`cat` on the user's
source story file. Only pass its path to `lets-read init`.

### NEVER Inspect `.vault.bin` or Gatekeeper Source Code

`<session_dir>/.vault.bin` is an XOR-obfuscated binary archive of all story
chunks. Treat `.bin/lets-read` as a black-box CLI tool.

### Do NOT Pass `--max-words` Unless Requested

Always let `lets-read init` use its built-in default unless the user explicitly
asks for a custom chunk size.

### Strict Subagent Isolation & Sandbox-Safe Tool Receipts

#### File-Based Data Exchange

The five leaf subagents are defined in [agents/](../../agents/) with
`subagent: true`, `mainAgent: false`, and explicit `tools` lists (`write_file`
+ `read_file`, plus `search_web` only for `blind-reader` and `fact-checker`).
Leaf subagents read only inside `<session_dir>` (plus the shared session-file
and multi-layer index reference at
[references/session-files.md](./references/session-files.md)), write only to
their designated `<session_dir>/current_*_response.md` file via `write_file`
(`Overwrite: true`), never call `run_command`, `edit_file`, or `send_message`,
and use `search_web` solely for neutral background lore or reference checks
(never for the story being read).

#### Sandbox-Compatible Tool Receipts (`[Tools: ...]` & `<!-- TOOLS: ... -->`)

Because Standard Sandbox isolates sibling `<brain>/<child_id>/` subagent
transcripts from `run_command`, `blind-reader` and `fact-checker` record
compact tool receipts in two places: a `<!-- TOOLS: ... -->` comment on line 1
of `current_reader_response.md`, `current_discussion_response.md`, and
`current_fact_check_response.md` (stripped automatically by `LetsRead`), plus a
`[Tools: ...]` suffix on their 1-line completion notice (visible in the
orchestrator's mounted `<brain>/<caller_id>/` inbox and transcript). `LetsRead`
uses direct `--*-log` parsing when accessible and falls back automatically to
these receipts in Standard Sandbox without needing `BypassSandbox: true`.

### 1-Line Notifications, Step Boundaries & No Polling

- Act strictly as the **session host and gatekeeper relay**. Never answer story
  questions in your own voice, and never call `edit_file` or `write_file`
  directly on `<session_dir>/memory.md`.

- Never read or paste `current_*_prompt.md`, `current_chunk.md`, or `memory.md`
  into `invoke_subagent` or `send_message`. Send **only a 1-line notification**
  naming the prompt file to read and the response file to write:

  ```text
  Chunk XXXX/YYYY ready: read <session_dir>/current_prompt.md via read_file and write your response to <session_dir>/current_reader_response.md.
  ```

- Never bundle `run_command` (`lets-read next`, `record`, `judge`, `discuss`,
  or `discuss-prompt`) with `invoke_subagent` or `send_message` in the same
  step. Always wait for the CLI command to exit `0` and write its prompt files
  before dispatching subagents.

- Once `invoke_subagent` or `send_message` returns, end your turn immediately
  with **ZERO tool calls**. Never re-send duplicate notifications or poll with
  `manage_subagents(Action: "list")`.

- When relaying `blind-reader`'s commentary or discussion reply in chat, read
  `<session_dir>/entries/chunk_XXXX.md` (or `entries/wrapup.md`) and prefix
  your message with a third-person host banner:

  ```markdown
  > **Let's Read Host** — Relaying from `blind-reader` (Chunk XXXX/YYYY):
  ```

### Hard Anti-Race Barrier (Zero Tool Calls While Waiting)

**NEVER** emit `run_command` (`lets-read record`, `lets-read judge`, or
`lets-read discuss`) in the same response where you state you are waiting for a
subagent (for example, never output `"Waiting for <subagent>..."` alongside a
tool call).

Count delivered idle completion notices strictly before advancing: if **fewer
than all** dispatched subagents for the current phase have sent their idle
completion notice (`< 1` `blind-reader` before `record` or `discuss`, `< 3`
reviewers before `judge`, or `< 4` when `topic-curator` was dispatched), you
**MUST end your turn immediately with ZERO tool calls**.

### CLI Whitelist Only — No `python`, `ls`/`cat`, or Ad-Hoc Shell Commands

`<skill_dir>/.bin/lets-read` (where `<skill_dir>` is the directory containing
this `SKILL.md` file) handles all parsing, receipt verification, indexing, and
state management natively in compiled Haskell. Use strictly
`<skill_dir>/scripts/prepare.sh`, `<skill_dir>/.bin/lets-read` (`init`, `next`,
`record`, `judge`, `discuss-prompt`, `discuss`, `status`), `read_file`,
`write_file`, `invoke_subagent`, `send_message`, and `manage_subagents`.

**Never** run `python`, `python3`, `ls`, `cat`, `head`, `tail`, `find`, or
`grep` to inspect `<session_dir>` or `<session_dir>/state.json`, and never
guess binary paths. Whenever checking session state, run
`<skill_dir>/.bin/lets-read status --session "<session_dir>"`.

## Directory & Resource Layout

Let `<skill_dir>` denote the directory containing this `SKILL.md` file:

- Gatekeeper CLI: [LetsRead.hs](./scripts/LetsRead.hs) (`scripts/LetsRead/`)
- Build script: [prepare.sh](./scripts/prepare.sh)
- Blind Reader: [blind-reader.md](../../agents/blind-reader.md)
- Prediction Judge: [prediction-judge.md](../../agents/prediction-judge.md)
- Fact-Checker: [fact-checker.md](../../agents/fact-checker.md)
- Commentary Critic: [commentary-critic.md](../../agents/commentary-critic.md)
- Topic Curator: [topic-curator.md](../../agents/topic-curator.md)
- Wrapup: [wrapup_prompt_template.md](./resources/wrapup_prompt_template.md)
- Banned jargon list: [banned_jargon.txt](./resources/banned_jargon.txt)
- Persona presets: [personas.md](./references/personas.md)
- Session files & index layout: [session-files.md](./references/session-files.md)

## Workflow

### Step 1: Clarify Session Preferences (If Not Specified)

If the user has not specified their preferences, check briefly or use defaults:

#### Mode

##### Interactive Mode (Default)

Read one chunk at a time, relay commentary and Judge rulings in chat, and pause
so the user can discuss theories or say "continue".

##### Batch Mode

Autonomously read a requested chunk/chapter span (or the full work) into
`<session_dir>/lets_read_log.md`.

#### Reader Persona

See [personas.md](./references/personas.md) for presets (default: *Classic
Forum Liveblogger*).

#### Session Directory

Default to `./lets-read-sessions/<story-slug>/` (or a user-specified path).

### Step 2: Initialize the Gatekeeper Session

Read [personas.md](./references/personas.md) if a custom tone or preset was
requested.

#### 1. Prepare the Gatekeeper Binary

Run [prepare.sh](./scripts/prepare.sh) as a standalone command to compile
`<skill_dir>/.bin/lets-read` if missing or out of date:

```bash
<skill_dir>/scripts/prepare.sh
```

#### 2. Initialize or Resume the Session

Run `<skill_dir>/.bin/lets-read init` as a separate command:

```bash
<skill_dir>/.bin/lets-read init "<source_story_path>" \
  --session "<session_dir>" \
  --persona "<chosen_persona>"
```

If resuming or inspecting an existing session instead of initializing, run
`status`:

```bash
<skill_dir>/.bin/lets-read status --session "<session_dir>"
```

### Step 3: Verify the Five Subagents Are Available

When the `lets-read` plugin is installed and enabled, its five leaf subagents
are registered in `<subagents>`:

1. [blind-reader.md](../../agents/blind-reader.md)
   (`Name: "blind-reader"`, `Role: "Blind Story Reader"`)

2. [prediction-judge.md](../../agents/prediction-judge.md)
   (`Name: "prediction-judge"`, `Role: "Impartial Prediction Judge"`)

3. [fact-checker.md](../../agents/fact-checker.md)
   (`Name: "fact-checker"`, `Role: "Commentary Fact-Checker"`)

4. [commentary-critic.md](../../agents/commentary-critic.md)
   (`Name: "commentary-critic"`, `Role: "Commentary Critic"`)

5. [topic-curator.md](../../agents/topic-curator.md)
   (`Name: "topic-curator"`, `Role: "Topic Index Curator"`)

If running from an uninstalled checkout where they do not yet appear in
`<subagents>`, read each file under [agents/](../../agents/) and call
`define_subagent` (`EnableWriteTools: true`, `EnableSubagentTools: false`,
`EnableMCPTools: false`).

### Step 4: Per-Chunk Loop (`next`, `record`, `judge`, optional `discuss`)

For each chunk to be read, follow these steps in strict sequence:

#### 1. Unlock the Next Chunk (`next`)

```bash
<skill_dir>/.bin/lets-read next --session "<session_dir>"
```

Writes `current_chunk.md`, `chunks/chunk_XXXX.md`, and `current_prompt.md`,
cleans up stale `current_reader_response.md`, and returns JSON metadata
including `"rotate_reader_recommended"`.

#### 2. Notify `blind-reader` (1-Line Message Only)

- After `lets-read next` exits `0`, on the first chunk of a session/batch or
  when `"rotate_reader_recommended": true` (killing any prior `blind-reader`
  via `manage_subagents` with `Action: "kill"`), call `invoke_subagent`
  (`TypeName: "blind-reader"`, `Role: "Blind Story Reader"`). Otherwise call
  `send_message` to the active `blind-reader` `conversationId`.

- Send **only a 1-line notification** to read `<session_dir>/current_prompt.md`
  and write `<session_dir>/current_reader_response.md` (`Overwrite: true`).

- Once `invoke_subagent` or `send_message` returns, obey the **Hard Anti-Race
  Barrier**: end your turn with **ZERO tool calls** and wait for
  `blind-reader`'s idle completion notice (`1/1`) before calling `record`.

#### 3. Record `blind-reader`'s Turn (`record`)

Run `record` **only after** `blind-reader`'s idle completion notice arrives
(`< 1` reader finished means **ZERO tool calls**):

```bash
<skill_dir>/.bin/lets-read record \
  --session "<session_dir>" \
  --subagent-log "<blind_reader_logAbsoluteUri>"
```

Reads `current_reader_response.md` (auditing rotation/callback `read_file`
receipts via `--subagent-log` or `[Tools: ...]` / `<!-- TOOLS: ... -->`),
records the entry, updates predictions and indices, writes reviewer prompts,
and returns `"rotate_*_recommended"` and `"topic_curation_needed"`.

#### 4. Notify Reviewers in Parallel (1-Line Messages Only)

- After `lets-read record` exits `0`, do **not** read `current_*_prompt.md`.
  Dispatch all post-record reviewers **in parallel in the same turn** with
  1-line notifications:

  - For `prediction-judge`, `fact-checker`, and `commentary-critic`, call
    `invoke_subagent` on the first chunk of a session/batch or when
    `"rotate_<role>_recommended": true` (killing the prior instance via
    `manage_subagents` with `Action: "kill"`); otherwise call `send_message` to
    the active `conversationId`.

  - When `"topic_curation_needed": true`, also call `invoke_subagent` for
    one-shot `topic-curator` (`Role: "Topic Index Curator"`) to read
    `current_topic_prompt.md` and write `current_topic_response.md`.

- Obey the **Hard Anti-Race Barrier**: end the post-dispatch turn—and any
  staggered wakeup turn where `< 3` reviewers (or `< 4` when `topic-curator`
  was dispatched) have sent idle completion notices—with **ZERO tool calls**.

#### 5. Apply Verdicts, Fact-Check, Persona Critique & Topic Merges (`judge`)

Run `judge` **only after** all `3/3` dispatched reviewers (or `4/4` when
`topic-curator` was dispatched) have delivered their idle completion notices:

```bash
<skill_dir>/.bin/lets-read judge \
  --session "<session_dir>" \
  --subagent-log "<prediction_judge_logAbsoluteUri>" \
  --fact-check-log "<fact_checker_logAbsoluteUri>" \
  --critic-log "<commentary_critic_logAbsoluteUri>" \
  [--topic-log "<topic_curator_logAbsoluteUri>"]
```

Reads `current_judge_response.md`, `current_fact_check_response.md`,
`current_critic_response.md`, and (when triggered) `current_topic_response.md`,
verifying tool usage via `--*-log` or sandbox-safe `[Tools: ...]` and
`<!-- TOOLS: ... -->` receipts.

##### Immediate One-Shot `topic-curator` Cleanup

Whenever `topic-curator` was dispatched on this chunk
(`"topic_curation_needed": true`), **kill the finished `topic-curator`
immediately via `manage_subagents` (`Action: "kill"`) right after
`lets-read judge` completes** rather than leaving it parked until batch end.

#### 6. Resolve Pending Fact-Check Peer Queries (`discuss`)

Whenever `lets-read judge` returns `"fact_check_discussion_pending": true`
(`"awaiting_fact_check_response"`), **do NOT run `next` yet**:

1. Send a 1-line notification via `send_message` to `blind-reader` to read
   `<session_dir>/current_discussion_prompt.md` and write
   `<session_dir>/current_discussion_response.md` (`Overwrite: true`), then end
   your turn with **ZERO tool calls**.

2. Only after `blind-reader`'s idle completion notice arrives, record the reply
   (verifying tool usage via `--subagent-log` or `[Tools: ...]` /
   `<!-- TOOLS: ... -->` receipts):

   ```bash
   <skill_dir>/.bin/lets-read discuss \
     --session "<session_dir>" \
     --subagent-log "<blind_reader_logAbsoluteUri>"
   ```

#### 7. Dedicated Final Wrapup Round (When `"wrapup_pending": true`)

- Once chunk `N/N` is judged and `"fact_check_discussion_pending"` is `false`,
  run `next` one more time to unlock the **Final Wrapup Round**
  (`"status": "wrapup_unlocked"`).

- Send a 1-line notification to `blind-reader` to read `current_prompt.md` and
  write `current_reader_response.md`, then end your turn with **ZERO tool
  calls**.

- Only after `blind-reader`'s idle completion notice arrives, record the Final
  Wrapup (no `judge` step is needed after `"wrapup_recorded"`):

  ```bash
  <skill_dir>/.bin/lets-read record \
    --session "<session_dir>" \
    --subagent-log "<blind_reader_logAbsoluteUri>"
  ```

### Step 5: Interactive Discussion vs. Batch Progression

#### Interactive Mode

Read and present `<session_dir>/entries/chunk_XXXX.md` (or `entries/wrapup.md`)
under the third-person host banner, and link to `lets_read_log.md`,
`memory.md`, `predictions/by_chronology.md`, and `predictions/by_topic.md`
(plus `entries/wrapup.md` and `predictions/hall_of_fame.md` when finished). Do
**not** relay `critic_feedback.md` unless asked.

If the user replies with comments, questions, or non-spoiler discussion:

1. Generate `<session_dir>/current_discussion_prompt.md` using `discuss-prompt`
   (or pass `--user-file "<session_dir>/last_user_message.md"`):

   ```bash
   <skill_dir>/.bin/lets-read discuss-prompt \
     --session "<session_dir>" \
     --user-message "<user_message>"
   ```

2. Send a 1-line notification to `blind-reader` via `send_message` to read
   `current_discussion_prompt.md` and write `current_discussion_response.md`,
   then end your turn with **ZERO tool calls**.

3. Only after `blind-reader`'s idle completion notice arrives, record the
   response:

   ```bash
   <skill_dir>/.bin/lets-read discuss \
     --session "<session_dir>" \
     --user-message "<user_message>" \
     --subagent-log "<blind_reader_logAbsoluteUri>"
   ```

4. Read the appended `### Reader Discussion` section from
   `<session_dir>/entries/chunk_XXXX.md` (or `entries/wrapup.md`) and relay it
   under the third-person host banner.

#### Batch Mode

Delegate long read-throughs in sequential batches of **~10 chunks** (`1..10`,
`11..20`, etc.; if $\le 3$ chunks would remain after a batch, fold them into
the current batch so chunk `N/N` and the Final Wrapup finish together):

1. Call `invoke_subagent` (`TypeName: "self"`,
   `Role: "Batch Read-Through Driver"`), passing the exact paths `<skill_dir>`,
   `<skill_dir>/.bin/lets-read`, `<skill_dir>/SKILL.md`, `<session_dir>`, and
   the target chunk range (`<start_chunk>..<end_chunk>`), and instruct the
   driver to:

   - Read `<skill_dir>/SKILL.md` in full first; if checking session state, run
     `<skill_dir>/.bin/lets-read status --session "<session_dir>"` (**never**
     run `ls`, `cat state.json`, `head`, `tail`, or guessed binary paths).

   - Execute **Step 4** using `<skill_dir>/.bin/lets-read` for each assigned
     chunk (plus Step 4.7 Final Wrapup if completing chunk `N/N`), strictly
     honoring the **Hard Anti-Race Barrier** (`< 1` reader or `< 3` / `< 4`
     reviewers idle means **ZERO tool calls**; never emit `"Waiting for..."`
     alongside `run_command`) and killing one-shot `topic-curator` via
     `manage_subagents(Action: "kill")` right after `lets-read judge`.

   - Before returning, call `manage_subagents` (`Action: "kill_all"`) to
     terminate all remaining leaf subagents spawned during its batch.

   - Return a **concise 1-line plain-text summary** (no multi-line lists):

     ```text
     Batch complete: completed_range=<A..B>, chunk_index=<N>/<Total>, active_predictions_count=<K>, is_finished=<true|false>.
     ```

2. When the `self` batch driver returns its 1-line summary, terminate that
   finished driver via `manage_subagents` (`Action: "kill"`).

3. If more chunks remain before the user's target or `"is_finished": true`,
   invoke a **new** `self` subagent (`Role: "Batch Read-Through Driver"`) for
   the next ~10-chunk batch.
