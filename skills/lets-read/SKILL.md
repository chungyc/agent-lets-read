---
name: lets-read
description: >-
  Conducts a spoiler-free, chapter-by-chapter or chunk-by-chunk "Let's Read"
  liveblog of a story (.txt, .md, .html, .epub) using a Haskell gatekeeper
  script, a stateless script-writer subagent, a continuity/canon researcher
  subagent, an isolated blind-reader subagent, an impartial prediction-judge
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

This skill conducts an unspoiled **Let's Read** of a story or book in `.txt`,
`.md`, `.markdown`, `.html`, or `.epub` format by combining a **Haskell
Gatekeeper** ([LetsRead.hs](./scripts/LetsRead.hs)) with seven isolated leaf
subagents that exchange data via `<session_dir>` files.

## Subagent Architecture

### `script-writer`

Stateless one-shot subagent dispatched after `lets-read next` (on every chunk
`1..N` and on the Final Wrapup Round). Reads `current_script_prompt.md` and its
listed turn inputs, writes an unresearched in-persona draft to
`current_script_response.md`, and ends with a 1-line `[Tools: ...]` notice.
`lets-read script` embeds the draft into `current_research_prompt.md` and
deletes all script files immediately so `blind-reader` stays completely blind to
it.

### `researcher`

Stateless one-shot subagent dispatched after `lets-read script`. Reads
`current_research_prompt.md`, pulls verbatim excerpts from
`chunks/chunk_XXXX.md`, `entries/chunk_XXXX.md`, and `predictions/pred_XXXX.md`
plus verified external canon notes via neutral `search_web` queries relevant to
the draft (never mentioning the draft), and writes
`current_research_response.md` (with a `[Tools: ...]` receipt) for
`lets-read research` to verify into `current_research.md`.

### `blind-reader`

Reads `current_prompt.md`, `current_chunk.md`, `memory.md`, and
`current_research.md` (blind to `script-writer`'s draft), reacts in the Active
Persona, stakes 1 specific, non-obvious prediction per non-final chunk, writes
`current_reader_response.md` (or `current_discussion_response.md`), and ends
with a 1-line `[Tools: ...]` notice.

### `prediction-judge`

Reads `current_judge_prompt.md`, evaluates all active predictions against
`current_chunk.md`, screens newly proposed predictions so flagged
uninteresting/hedged/duplicate/ungrounded proposals return strictly as reader
feedback rather than entering the active ledger (plus conditional 10-cap
retirements when `> 10` remain active), and writes verdicts to
`current_judge_response.md`.

### `fact-checker`

Runs in parallel with `prediction-judge` and `commentary-critic`. Reads
`current_fact_check_prompt.md`, audits factual and chronological claims against
primary sources (`current_chunk.md`, `chunks/chunk_XXXX.md`, and neutral
`search_web`), and writes `current_fact_check_response.md` (with a
`[Tools: ...]` receipt). Verified disputes set
`"fact_check_discussion_pending": true` and gate `lets-read next` until
resolved via `lets-read discuss`.

### `commentary-critic`

Runs in parallel with `prediction-judge` and `fact-checker`. Reads
`current_critic_prompt.md` and evaluates how well the entry inhabited the Active
Persona and user style directives, writing notes to `current_critic_response.md`
for silent uptake on the next chunk.

### `topic-curator`

Dispatched in parallel when `record` returns `"topic_curation_needed": true`.
Reads `current_topic_prompt.md` and writes synonym or alias merges
(`=== TOPIC MERGES ===`) to `current_topic_response.md` for `lets-read judge`.

In **Batch Mode**, the host delegates sequential slices of ~7–8 chunks to fresh
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

The seven leaf subagents in [agents/](../../agents/) run with `subagent: true`,
`mainAgent: false`, and explicit `tools` lists (`write_file` + `read_file`, plus
`search_web` only for `researcher`, `blind-reader`, and `fact-checker`). Leaf
subagents read only inside `<session_dir>` (plus
[references/session-files.md](./references/session-files.md)), write only to
their designated `<session_dir>/current_*_response.md` via `write_file`
(`Overwrite: true`), never call `run_command`, `edit_file`, or `send_message`,
and use `search_web` solely for neutral background lore or reference checks
(never for the story being read).

#### Sandbox-Compatible Tool Receipts (`[Tools: ...]` & `<!-- TOOLS: ... -->`)

Because Standard Sandbox isolates sibling `<brain>/<child_id>/` subagent
transcripts from `run_command`, `script-writer`, `researcher`, `blind-reader`,
and `fact-checker` record compact tool receipts in two places: a
`<!-- TOOLS: ... -->` comment on line 1 of their `current_*_response.md` file
(stripped automatically by `LetsRead`), plus a `[Tools: ...]` suffix on their
1-line completion notice. `LetsRead` uses `--*-log` parsing when accessible and
falls back automatically to these receipts in Standard Sandbox.

### 1-Line Notifications, Step Boundaries & No Polling

- Act strictly as the **session host and gatekeeper relay**. Never answer story
  questions in your own voice, and never call `edit_file` or `write_file`
  directly on `<session_dir>/memory.md`.

- Never read or paste `current_*_prompt.md`, `current_chunk.md`,
  `current_research.md`, or `memory.md` into `invoke_subagent` or
  `send_message`. Send **only a 1-line notification** naming the prompt file to
  read and the response file to write:

  ```text
  Chunk XXXX/YYYY ready: read <session_dir>/current_prompt.md via read_file and write your response to <session_dir>/current_reader_response.md.
  ```

- Never bundle `run_command` (`lets-read next`, `script`, `research`, `record`,
  `judge`, `discuss`, or `discuss-prompt`) with `invoke_subagent` or
  `send_message` in the same step. Always wait for the CLI command to exit `0`
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

**NEVER** emit `run_command` (`lets-read script`, `lets-read research`,
`lets-read record`, `lets-read judge`, or `lets-read discuss`) in the same
response where you state you are waiting for a subagent (never output
`"Waiting for <subagent>..."` alongside a tool call).

Count delivered idle completion notices strictly before advancing: if **fewer
than all** dispatched subagents for the current phase have sent their idle
completion notice (`< 1` `script-writer` before `script`, `< 1` `researcher`
before `research`, `< 1` `blind-reader` before `record` or `discuss`, `< 3`
reviewers before `judge`, or `< 4` when `topic-curator` was dispatched), **end
your turn immediately with ZERO tool calls**.

### CLI Whitelist Only — No `python`, `ls`/`cat`, or Ad-Hoc Shell Commands

`<skill_dir>/.bin/lets-read` (where `<skill_dir>` is the directory containing
this `SKILL.md`) handles all parsing, quarantine cleanup, receipt verification,
indexing, and state management in compiled Haskell. Use strictly
`<skill_dir>/scripts/prepare.sh`, `<skill_dir>/.bin/lets-read` (`init`, `next`,
`script`, `research`, `record`, `judge`, `discuss-prompt`, `discuss`, `status`),
`read_file`, `write_file`, `invoke_subagent`, `send_message`, and
`manage_subagents`.

**Never** run `python`, `python3`, `ls`, `cat`, `head`, `tail`, `find`, or
`grep` to inspect `<session_dir>` or `<session_dir>/state.json`, and never
guess binary paths. To check session state, run
`<skill_dir>/.bin/lets-read status --session "<session_dir>"`.

## Directory & Resource Layout

Let `<skill_dir>` denote the directory containing this `SKILL.md` file:

- Gatekeeper CLI: [LetsRead.hs](./scripts/LetsRead.hs) (`scripts/LetsRead/`)

- Build script: [prepare.sh](./scripts/prepare.sh)

- Script Writer: [script-writer.md](../../agents/script-writer.md)

- Researcher: [researcher.md](../../agents/researcher.md)

- Blind Reader: [blind-reader.md](../../agents/blind-reader.md)

- Prediction Judge: [prediction-judge.md](../../agents/prediction-judge.md)

- Fact-Checker: [fact-checker.md](../../agents/fact-checker.md)

- Commentary Critic: [commentary-critic.md](../../agents/commentary-critic.md)

- Topic Curator: [topic-curator.md](../../agents/topic-curator.md)

- Wrapup: [wrapup_prompt_template.md](./resources/wrapup_prompt_template.md)

- Banned jargon list: [banned_jargon.txt](./resources/banned_jargon.txt)

- Persona presets: [personas.md](./references/personas.md)

- Session & index layout: [session-files.md](./references/session-files.md)

## Workflow

### Step 1: Clarify Session Preferences (If Not Specified)

If not specified by the user, check briefly or use defaults:

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

Run [prepare.sh](./scripts/prepare.sh) as a standalone command:

```bash
<skill_dir>/scripts/prepare.sh
```

#### 2. Initialize or Resume the Session

Initialize a new session:

```bash
<skill_dir>/.bin/lets-read init "<source_story_path>" \
  --session "<session_dir>" \
  --persona "<chosen_persona>"
```

Or inspect/resume an existing session:

```bash
<skill_dir>/.bin/lets-read status --session "<session_dir>"
```

### Step 3: Verify the Seven Subagents Are Available

When the `lets-read` plugin is installed and enabled, its seven leaf subagents
are registered in `<subagents>`:

1. [script-writer.md](../../agents/script-writer.md)
   (`Name: "script-writer"`, `Role: "Unresearched Script Writer"`)

2. [researcher.md](../../agents/researcher.md)
   (`Name: "researcher"`, `Role: "Continuity & Canon Researcher"`)

3. [blind-reader.md](../../agents/blind-reader.md)
   (`Name: "blind-reader"`, `Role: "Blind Story Reader"`)

4. [prediction-judge.md](../../agents/prediction-judge.md)
   (`Name: "prediction-judge"`, `Role: "Impartial Prediction Judge"`)

5. [fact-checker.md](../../agents/fact-checker.md)
   (`Name: "fact-checker"`, `Role: "Commentary Fact-Checker"`)

6. [commentary-critic.md](../../agents/commentary-critic.md)
   (`Name: "commentary-critic"`, `Role: "Commentary Critic"`)

7. [topic-curator.md](../../agents/topic-curator.md)
   (`Name: "topic-curator"`, `Role: "Topic Index Curator"`)

If running from an uninstalled checkout where they do not yet appear in
`<subagents>`, read each file under [agents/](../../agents/) and call
`define_subagent` (`EnableWriteTools: true`, `EnableSubagentTools: false`,
`EnableMCPTools: false`).

### Step 4: Per-Chunk Loop

For each chunk (`next`, `script`, `research`, `record`, `judge`, optional
`discuss`), follow these steps in strict sequence:

#### 1. Unlock Chunk (`next`) & Dispatch Stateless `script-writer`

```bash
<skill_dir>/.bin/lets-read next --session "<session_dir>"
```

Writes `current_chunk.md`, `chunks/chunk_XXXX.md`, and
`current_script_prompt.md`, returning `"status": "awaiting_script"`.

- After `next` exits `0`, call `invoke_subagent` (`TypeName: "script-writer"`,
  `Role: "Unresearched Script Writer"`) with a **1-line notification** to read
  `<session_dir>/current_script_prompt.md` and write
  `<session_dir>/current_script_response.md` (`Overwrite: true`).

- End your turn with **ZERO tool calls** until `script-writer` sends its idle
  notice (`1/1`).

#### 2. Quarantine Draft (`script`), Kill `script-writer` & Invoke `researcher`

Run `script` **only after** `script-writer`'s idle notice arrives:

```bash
<skill_dir>/.bin/lets-read script \
  --session "<session_dir>" \
  --subagent-log "<script_writer_logAbsoluteUri>"
```

Embeds the stripped draft into `current_research_prompt.md` and **immediately
deletes `current_script_prompt.md` and `current_script_response.md`**.

- In the same turn after `script` exits `0`:

  1. **Kill the finished one-shot `script-writer` immediately** via
     `manage_subagents` (`Action: "kill"`).

  2. Invoke a fresh one-shot `researcher` via `invoke_subagent`
     (`TypeName: "researcher"`, `Role: "Continuity & Canon Researcher"`) with a
     **1-line notification** to read `current_research_prompt.md` and write
     `current_research_response.md` (`Overwrite: true`).

- End your turn with **ZERO tool calls** until `researcher` sends its idle
  notice (`1/1`).

#### 3. Verify Research (`research`), Kill `researcher` & Notify `blind-reader`

Run `research` **only after** `researcher`'s idle notice arrives:

```bash
<skill_dir>/.bin/lets-read research \
  --session "<session_dir>" \
  --subagent-log "<researcher_logAbsoluteUri>"
```

Verifies verbatim quotes and `search_web` receipts, **deletes
`current_research_prompt.md` and `current_research_response.md`**, writes
`current_research.md` and `current_prompt.md`, and returns
`"status": "unlocked"` and `"rotate_reader_recommended"`.

- In the same turn after `research` exits `0`:

  1. **Kill the finished one-shot `researcher` immediately** via
     `manage_subagents` (`Action: "kill"`).

  2. On the first chunk of a session/batch or when
     `"rotate_reader_recommended": true` (killing any prior `blind-reader` via
     `manage_subagents` with `Action: "kill"`), call `invoke_subagent`
     (`TypeName: "blind-reader"`, `Role: "Blind Story Reader"`). Otherwise call
     `send_message` to the active `blind-reader` `conversationId`.

- Send **only a 1-line notification** to read `current_prompt.md` and write
  `current_reader_response.md` (`Overwrite: true`), then end your turn with
  **ZERO tool calls** until `blind-reader`'s idle notice (`1/1`) arrives.

#### 4. Record `blind-reader`'s Turn (`record`)

Run `record` **only after** `blind-reader`'s idle notice arrives:

```bash
<skill_dir>/.bin/lets-read record \
  --session "<session_dir>" \
  --subagent-log "<blind_reader_logAbsoluteUri>"
```

Records the entry, updates predictions and indices, writes reviewer prompts,
and returns `"rotate_*_recommended"` and `"topic_curation_needed"`.

#### 5. Notify Reviewers in Parallel (1-Line Messages Only)

- After `record` exits `0`, do **not** read `current_*_prompt.md`. Dispatch all
  post-record reviewers **in parallel in the same turn** with 1-line
  notifications:

  - For `prediction-judge`, `fact-checker`, and `commentary-critic`, call
    `invoke_subagent` on the first chunk of a session/batch or when
    `"rotate_<role>_recommended": true` (killing the prior instance via
    `manage_subagents` with `Action: "kill"`); otherwise call `send_message` to
    the active `conversationId`.

  - When `"topic_curation_needed": true`, also call `invoke_subagent` for
    one-shot `topic-curator` (`Role: "Topic Index Curator"`) to read
    `current_topic_prompt.md` and write `current_topic_response.md`.

- Obey the **Hard Anti-Race Barrier**: end the post-dispatch turn—and any
  staggered wakeup turn where `< 3` reviewers (or `< 4` with `topic-curator`)
  have sent idle notices—with **ZERO tool calls**.

#### 6. Apply Verdicts, Fact-Check, Persona Critique & Topic Merges (`judge`)

Run `judge` **only after** all `3/3` dispatched reviewers (or `4/4` with
`topic-curator`) have delivered idle completion notices:

```bash
<skill_dir>/.bin/lets-read judge \
  --session "<session_dir>" \
  --subagent-log "<prediction_judge_logAbsoluteUri>" \
  --fact-check-log "<fact_checker_logAbsoluteUri>" \
  --critic-log "<commentary_critic_logAbsoluteUri>" \
  [--topic-log "<topic_curator_logAbsoluteUri>"]
```

##### Immediate One-Shot `topic-curator` Cleanup

Whenever `topic-curator` was dispatched (`"topic_curation_needed": true`),
**kill the finished `topic-curator` immediately via `manage_subagents`
(`Action: "kill"`) right after `lets-read judge` completes**.

#### 7. Resolve Pending Fact-Check Peer Queries (`discuss`)

Whenever `judge` returns `"fact_check_discussion_pending": true`
(`"awaiting_fact_check_response"`), **do NOT run `next` yet**:

1. Send a 1-line notification to `blind-reader` (via `send_message`, or
   `invoke_subagent` if resuming without an active `blind-reader`) to read
   `current_discussion_prompt.md` and write `current_discussion_response.md`
   (`Overwrite: true`), then end your turn with **ZERO tool calls**.

2. Only after `blind-reader`'s idle notice arrives, record the reply:

   ```bash
   <skill_dir>/.bin/lets-read discuss \
     --session "<session_dir>" \
     --subagent-log "<blind_reader_logAbsoluteUri>"
   ```

### Step 5: Interactive Discussion vs. Batch Progression

#### Interactive Mode

Read and present `<session_dir>/entries/chunk_XXXX.md` under the third-person
host banner, and link to `lets_read_log.md`, `memory.md`,
`predictions/by_chronology.md`, and `predictions/by_topic.md` (plus
`predictions/hall_of_fame.md` once chunk `N/N` is judged). Do **not** relay
`critic_feedback.md` unless asked.

If the user replies with comments, questions, or non-spoiler discussion:

1. Generate `current_discussion_prompt.md` using `discuss-prompt` (or
   `--user-file "<session_dir>/last_user_message.md"`):

   ```bash
   <skill_dir>/.bin/lets-read discuss-prompt \
     --session "<session_dir>" \
     --user-message "<user_message>"
   ```

2. Send a 1-line notification to `blind-reader` (via `send_message`, or
   `invoke_subagent` if no `blind-reader` is active in this conversation) to
   read `current_discussion_prompt.md` and write
   `current_discussion_response.md`, then end your turn with **ZERO tool
   calls**.

3. Only after `blind-reader`'s idle notice arrives, record the response:

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

Delegate long read-throughs in sequential batches of **~7–8 chunks** (`1..8`,
`9..16`, etc.; if $\le 3$ chunks would remain after a batch, fold them into
the current batch so chunk `N/N` and the Final Wrapup finish together):

1. Call `invoke_subagent` (`TypeName: "self"`,
   `Role: "Batch Read-Through Driver"`), passing `<skill_dir>`,
   `<skill_dir>/.bin/lets-read`, `<skill_dir>/SKILL.md`, `<session_dir>`, and
   `<start_chunk>..<end_chunk>`, and instruct the driver to:

   - Read `<skill_dir>/SKILL.md` in full first; check state via
     `<skill_dir>/.bin/lets-read status --session "<session_dir>"` (**never**
     `ls`, `cat state.json`, `head`, `tail`, or guessed binary paths).

   - Execute **Step 4** for each assigned chunk (plus **Step 6** Final Wrapup if
     completing chunk `N/N`), strictly honoring the **Hard Anti-Race Barrier**
     (`< 1` `script-writer`, `researcher`, or `blind-reader` or `< 3` / `< 4`
     reviewers idle means **ZERO tool calls**; never emit `"Waiting for..."`
     alongside `run_command`) and killing one-shot `script-writer` after
     `lets-read script`, one-shot `researcher` after `lets-read research`, and
     one-shot `topic-curator` after `lets-read judge` via
     `manage_subagents(Action: "kill")`.

   - Before returning, call `manage_subagents` (`Action: "kill_all"`) to
     terminate all remaining leaf subagents spawned during its batch.

   - Return a **concise 1-line plain-text summary** (no multi-line lists):

     ```text
     Batch complete: completed_range=<A..B>, chunk_index=<N>/<Total>, active_predictions_count=<K>, is_finished=<true|false>.
     ```

2. When the `self` batch driver returns its 1-line summary, terminate it via
   `manage_subagents` (`Action: "kill"`).

3. If more chunks remain before the user's target or `"is_finished": true`,
   invoke a **new** `self` subagent (`Role: "Batch Read-Through Driver"`) for
   the next ~7–8-chunk batch.

### Step 6: Dedicated Final Wrapup Round (When `"wrapup_pending": true`)

- Run the same pre-`record` pipeline (`next` → `script` → `research`) to unlock
  the **Final Wrapup Round**:

  1. Run `<skill_dir>/.bin/lets-read next --session "<session_dir>"`
     (`"status": "awaiting_script"`, `"is_wrapup": true`), call
     `invoke_subagent` (`TypeName: "script-writer"`,
     `Role: "Unresearched Script Writer"`) to read `current_script_prompt.md`
     and write `current_script_response.md`, and wait for its idle notice
     (`ZERO tool calls`).

  2. Run `lets-read script` (passing `--session "<session_dir>"` and
     `--subagent-log "<script_writer_logAbsoluteUri>"`), kill `script-writer`
     via `manage_subagents(Action: "kill")`, invoke a fresh one-shot
     `researcher` via `invoke_subagent` (`TypeName: "researcher"`,
     `Role: "Continuity & Canon Researcher"`) to read
     `current_research_prompt.md` and write `current_research_response.md`, and
     wait for its idle notice (`ZERO tool calls`).

  3. Run `lets-read research` (passing `--session "<session_dir>"` and
     `--subagent-log "<researcher_logAbsoluteUri>"`, returning
     `"status": "wrapup_unlocked"`), kill `researcher` via
     `manage_subagents(Action: "kill")`, send a 1-line notification to
     `blind-reader` (via `send_message`, or `invoke_subagent` if no
     `blind-reader` is active in this conversation) to read `current_prompt.md`
     and write `current_reader_response.md`, and wait for its idle notice
     (`ZERO tool calls`).

- Only after `blind-reader`'s idle notice arrives, record the Final Wrapup (no
  `judge` or `fact-checker` step runs after `"wrapup_recorded"`):

  ```bash
  <skill_dir>/.bin/lets-read record \
    --session "<session_dir>" \
    --subagent-log "<blind_reader_logAbsoluteUri>"
  ```

- In **Interactive Mode**, read and present `<session_dir>/entries/wrapup.md`
  under the third-person host banner alongside links to
  `predictions/hall_of_fame.md`, `lets_read_log.md`, `memory.md`,
  `predictions/by_chronology.md`, and `predictions/by_topic.md`.
