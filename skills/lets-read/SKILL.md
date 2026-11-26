---
name: lets-read
description: >-
  Conducts a spoiler-free, chapter-by-chapter or chunk-by-chunk "Let's Read"
  liveblog of a story (.txt, .md, .html, .epub) using a Haskell gatekeeper, two
  mode drivers (lets-read-interactive-driver and lets-read-batch-driver), and
  seven isolated leaf subagents (lets-read-script-writer, lets-read-researcher,
  lets-read-blind-reader, lets-read-prediction-judge, lets-read-fact-checker,
  lets-read-commentary-critic, and lets-read-topic-curator). Use this skill
  whenever the user asks for a Let's Read, liveblog reaction, unspoiled
  first-time read, or incremental commentary on a story or book.
compatibility: >-
  Requires bash and GHC (Glasgow Haskell Compiler, presumed version 9.10.3; the
  Haskell code does not build on certain other GHC versions) with standard boot
  packages (base, binary, bytestring, containers, directory, filepath, process,
  text) and zlib to compile the gatekeeper binary.
---

# Let's Read Skill (Spoiler-Free Architecture)

This skill conducts an unspoiled **Let's Read** of a story or book in `.txt`,
`.md`, `.markdown`, `.html`, or `.epub` format by combining a compiled **Haskell
Gatekeeper** (`<skill_dir>/.bin/lets-read`, where `<skill_dir>` is the directory
containing this `SKILL.md`) with two orchestrator **Mode Drivers** (sharing
[driver-pipeline.md]) and seven isolated **Leaf Subagents** that exchange data
strictly via `<session_dir>` files:

- `lets-read-interactive-driver` (*Interactive Driver*, `Model: "inherit"`):
  Executes strictly one interactive turn per request (`ADVANCE` for one chunk or
  Final Wrapup, or `DISCUSS` for a user comment/question), keeping persistent
  leaf subagents warm across turns while returning a 1-line `[DRIVER_DONE | ...]`
  file pointer to this host.

- `lets-read-batch-driver` (*Batch Driver*, `Model: "inherit"`): Autonomously
  drives an assigned slice of ~7–8 chunks (plus Final Wrapup when finishing the
  final chunk) and terminates its child leaf subagents via `kill_all` before
  returning a 1-line `[DRIVER_DONE | Batch ...]` summary.

- `lets-read-script-writer`, `lets-read-researcher`, `lets-read-blind-reader`,
  `lets-read-prediction-judge`, `lets-read-fact-checker`,
  `lets-read-commentary-critic`, and `lets-read-topic-curator`: Isolated leaf
  subagents orchestrated exclusively by the active mode driver according to
  [driver-pipeline.md].

[driver-pipeline.md]: ./references/driver-pipeline.md

## Mandatory Anti-Spoiler & Host Rules

### Never Read the Source Story File Directly

Do **not** call `read_file`, `grep_search`, or `head`/`cat` on the user's source
story file. Only pass its path to `lets-read init`.

### Never Inspect `.vault.bin` or Gatekeeper Source Code

`<session_dir>/.vault.bin` is an XOR-obfuscated binary archive of all story
chunks. Treat `.bin/lets-read` as a black-box CLI tool.

### Do Not Pass `--max-words` Unless Requested

Always let `lets-read init` use its built-in default unless the user explicitly
asks for a custom chunk size.

### Delegate All Chunk & Discussion Execution to the Mode Drivers

- Act strictly as the **user-facing session host**. Never answer story questions
  in your own voice, never call `edit_file` or `write_file` on
  `<session_dir>/memory.md`, and never invoke the seven leaf subagents or run
  per-chunk gatekeeper subcommands (`next`, `script`, `research`, `record`,
  `judge`, `discuss-prompt`, `discuss`) directly from this main conversation.

- Never paste story passages, prompts, or commentary into `invoke_subagent` or
  `send_message`—send **only a 1-line request** to
  `lets-read-interactive-driver` or `lets-read-batch-driver` (writing user
  discussion messages to `<session_dir>/last_user_message.md` via `write_file`
  first).

- Once `invoke_subagent` or `send_message` to a driver returns, immediately park
  your turn with **ZERO tool calls**, outputting **only**:

  ```text
  [HOST_WAIT | <mode> | <action> | 0/1 idle | pending: <driver>]
  ```

  Wait until the driver's `[DRIVER_DONE | ...]` completion notice arrives before
  proceeding. Never re-send duplicate notifications or poll with
  `manage_subagents(Action: "list")`.

- When relaying `lets-read-blind-reader`'s commentary or discussion reply in
  chat, call `read_file` on `<session_dir>/entries/chunk_XXXX.md` (or
  `entries/wrapup.md`) and prefix your message with a third-person host banner:

  ```markdown
  > **Let's Read Host** — Relaying from Blind Reader (Chunk XXXX/YYYY):
  ```

### CLI Whitelist Only — No `python`, `ls`/`cat`, or Ad-Hoc Shell Commands

In the main host conversation, use strictly `<skill_dir>/scripts/prepare.sh`,
`<skill_dir>/.bin/lets-read` (`init`, `status`), `read_file`, `write_file`,
`invoke_subagent`, `send_message`, and `manage_subagents` (plus
`define_subagent` only for uninstalled checkouts). **Never** run `python`,
`python3`, `ls`, `cat`, `head`, `tail`, `find`, or `grep` to inspect
`<session_dir>` or `state.json`. To check session state, run
`<skill_dir>/.bin/lets-read status --session "<session_dir>"`.

## Workflow

### Step 1: Clarify Session Preferences (If Not Specified)

If not specified by the user, check briefly or use defaults:

#### Mode

##### Interactive Mode (Default)

Read one chunk at a time via `lets-read-interactive-driver`, relay commentary
and Judge rulings in chat, and pause so the user can discuss theories or say
"continue".

##### Batch Mode

Autonomously read a requested chunk/chapter span (or the full work) into
`<session_dir>/lets_read_log.md` via sequential `lets-read-batch-driver` slices.

#### Reader Persona

See [personas.md] for presets (default: *Classic Forum Liveblogger*).

#### Session Directory

Default to `./lets-read-sessions/<story-slug>/` (or a user-specified path).

### Step 2: Initialize the Gatekeeper Session

Read [personas.md] if a custom tone or preset was requested.

#### 1. Prepare the Gatekeeper Binary

Run [prepare.sh] as a standalone command:

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

[prepare.sh]: ./scripts/prepare.sh

### Step 3: Verify the Nine Subagents Are Available

When the `lets-read` plugin is installed and enabled, all nine `lets-read-*`
subagents are registered in `<subagents>`:

- Mode Drivers (`EnableWriteTools: true`, `EnableSubagentTools: true`,
  `EnableMCPTools: false` when defining from an uninstalled checkout):

  - [lets-read-interactive-driver.md] (`Name: "lets-read-interactive-driver"`,
    `Role: "Interactive Read-Through Driver"`, `Model: "inherit"`)

  - [lets-read-batch-driver.md] (`Name: "lets-read-batch-driver"`,
    `Role: "Batch Read-Through Driver"`, `Model: "inherit"`)

- Leaf Subagents (`EnableWriteTools: true`, `EnableSubagentTools: false`,
  `EnableMCPTools: false` when defining from an uninstalled checkout):

  - [lets-read-script-writer.md] (`Name: "lets-read-script-writer"`,
    `Role: "Unresearched Script Writer"`, `Model: "flash"`)

  - [lets-read-researcher.md] (`Name: "lets-read-researcher"`,
    `Role: "Continuity & Canon Researcher"`, `Model: "flash"`)

  - [lets-read-blind-reader.md] (`Name: "lets-read-blind-reader"`,
    `Role: "Blind Story Reader"`, `Model: "inherit"`)

  - [lets-read-prediction-judge.md] (`Name: "lets-read-prediction-judge"`,
    `Role: "Impartial Prediction Judge"`, `Model: "inherit"`)

  - [lets-read-fact-checker.md] (`Name: "lets-read-fact-checker"`,
    `Role: "Commentary Fact-Checker"`, `Model: "inherit"`)

  - [lets-read-commentary-critic.md] (`Name: "lets-read-commentary-critic"`,
    `Role: "Commentary Critic"`, `Model: "inherit"`)

  - [lets-read-topic-curator.md] (`Name: "lets-read-topic-curator"`,
    `Role: "Topic Index Curator"`, `Model: "flash_lite"`)

If running from an uninstalled checkout where they do not yet appear in
`<subagents>`, read each file under `agents/` and call `define_subagent` with
the tool flags above.

[lets-read-interactive-driver.md]: ../../agents/lets-read-interactive-driver.md
[lets-read-batch-driver.md]: ../../agents/lets-read-batch-driver.md
[lets-read-script-writer.md]: ../../agents/lets-read-script-writer.md
[lets-read-researcher.md]: ../../agents/lets-read-researcher.md
[lets-read-blind-reader.md]: ../../agents/lets-read-blind-reader.md
[lets-read-prediction-judge.md]: ../../agents/lets-read-prediction-judge.md
[lets-read-fact-checker.md]: ../../agents/lets-read-fact-checker.md
[lets-read-commentary-critic.md]: ../../agents/lets-read-commentary-critic.md
[lets-read-topic-curator.md]: ../../agents/lets-read-topic-curator.md

### Step 4: Driving the Session

#### Interactive Mode

##### 1. Lazy Driver Rotation Before `ADVANCE`

Keep the active `lets-read-interactive-driver` idle while waiting for user
discussion so follow-up questions talk to the warm `lets-read-blind-reader`.
Before sending a new `ADVANCE` request (**never** before `DISCUSS` and **never**
when `wrapup_pending=true`), if an active `lets-read-interactive-driver`
reported `chunks_in_driver >= 8`—or `chunks_in_driver >= 6` with
`is_chapter_end=true`—terminate that driver via
`manage_subagents(Action: "kill")` (which automatically terminates its
descendant leaf subagents) so a fresh driver starts cleanly on the next chunk.

##### 2. Advancing One Chunk or Final Wrapup (`ADVANCE`)

- Call `invoke_subagent` (`TypeName: "lets-read-interactive-driver"`,
  `Role: "Interactive Read-Through Driver"`, `Model: "inherit"`) when no
  interactive driver is active, or `send_message` to the active
  `lets-read-interactive-driver` `conversationId`, sending **only** this 1-line
  request:

  ```text
  ADVANCE: skill_dir=<skill_dir>, session_dir=<session_dir> — complete the next chunk (or Final Wrapup if wrapup_pending is true).
  ```

- Park with **ZERO tool calls** outputting **only**
  `[HOST_WAIT | Interactive | advance | 0/1 idle | pending: lets-read-interactive-driver]`
  until `[DRIVER_DONE | ... | lets-read-interactive-driver]` arrives.

- Call `read_file` on the reported `entry_file`
  (`<session_dir>/entries/chunk_XXXX.md` or `<session_dir>/entries/wrapup.md`),
  present it under the third-person host banner, and link to `lets_read_log.md`,
  `memory.md`, `predictions/by_chronology.md`, and `predictions/by_topic.md`
  (plus `predictions/hall_of_fame.md` once chunk `N/N` is judged). Do **not**
  relay `critic_feedback.md` unless asked.

##### 3. Handling User Discussion (`DISCUSS`)

Whenever the user replies with comments, questions, or non-spoiler theories:

1. Write the user's message verbatim to `<session_dir>/last_user_message.md` via
   `write_file` (`Overwrite: true`).

2. Send **only** this 1-line request to `lets-read-interactive-driver` (via
   `send_message`, or `invoke_subagent` with `Model: "inherit"` if resuming a
   session without an active interactive driver):

   ```text
   DISCUSS: skill_dir=<skill_dir>, session_dir=<session_dir> — user message written to <session_dir>/last_user_message.md; run discuss-prompt and discuss.
   ```

3. Park with **ZERO tool calls** outputting **only**
   `[HOST_WAIT | Interactive | discuss | 0/1 idle | pending: lets-read-interactive-driver]`
   until `[DRIVER_DONE | ... (Discuss) | lets-read-interactive-driver]` arrives.

4. Call `read_file` on `entry_file` and relay the newly appended
   `### Reader Discussion` section under the third-person host banner.

##### 4. Switching Mid-Session to Batch Mode

If the user switches from Interactive Mode to Batch Mode mid-session, terminate
any active `lets-read-interactive-driver` via `manage_subagents(Action: "kill")`
before starting Batch Mode.

#### Batch Mode

Delegate long read-throughs in sequential slices of **~7–8 chunks** (`1..8`,
`9..16`, etc.; if $\le 3$ chunks would remain after a slice, fold them into the
current slice so chunk `N/N` and the Final Wrapup finish together):

1. Call `invoke_subagent` (`TypeName: "lets-read-batch-driver"`,
   `Role: "Batch Read-Through Driver"`, `Model: "inherit"`) with **only** this
   1-line request:

   ```text
   BATCH <start_chunk>..<end_chunk>: skill_dir=<skill_dir>, session_dir=<session_dir> — complete chunks <start_chunk>..<end_chunk> (plus Final Wrapup if finishing chunk N/N).
   ```

2. Park with **ZERO tool calls** outputting **only**
   `[HOST_WAIT | Batch | slice | 0/1 idle | pending: lets-read-batch-driver]`
   until `[DRIVER_DONE | Batch <A>..<B> | lets-read-batch-driver]` arrives, then
   terminate the finished driver via `manage_subagents(Action: "kill")`.

3. If `is_finished=false` and more chunks remain before the user's target,
   invoke a **new** `lets-read-batch-driver` (`Model: "inherit"`) for the next
   ~7–8 chunk slice; once complete, present a concise summary alongside links to
   `lets_read_log.md`, `memory.md`, `predictions/by_chronology.md`, and
   `predictions/by_topic.md` (plus `predictions/hall_of_fame.md` when finished).

[personas.md]: ./references/personas.md
