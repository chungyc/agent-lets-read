# Let's Read Driver Pipeline Reference

Shared gatekeeper and leaf-subagent execution protocol for both
`lets-read-interactive-driver` (*Interactive Driver*) and
`lets-read-batch-driver` (*Batch Driver*).

## Mandatory Anti-Spoiler & Driver Rules

### Never Read Sealed or Source Files

Do **not** read the original source story file, `<session_dir>/.vault.bin`,
`<session_dir>/.state.bin`, or the gatekeeper Haskell source code. Never answer
story questions in your own voice, never impersonate leaf subagents, and never
call `edit_file` or `write_file` on `<session_dir>/memory.md`,
`current_turn.md`, `last_discussion_exchange.md`, `entries/`, `chunks/`, or
`predictions/`.

### CLI Whitelist Only

Use strictly `<plugin_dir>/.bin/lets-read` (`status`, `next`, `script`,
`research`, `record`, `judge`, `discuss-prompt`, `discuss`), `read_file`,
`invoke_subagent`, `send_message`, and `manage_subagents`. **Never** run
`python`, `python3`, `ls`, `cat`, `head`, `tail`, `find`, or `grep` to inspect
`<session_dir>` or `state.json`.

### 1-Line Notifications Only

Never read or paste `current_*_prompt.md`, `current_chunk.md`,
`current_research.md`, `memory.md`, `current_turn.md`,
`last_discussion_exchange.md`, or `entries/chunk_XXXX.md` into `invoke_subagent`
or `send_message`. Send **only a 1-line notification** naming the prompt file to
read and the response file to write (`Overwrite: true`):

```text
Chunk XXXX/YYYY ready: read <session_dir>/current_prompt.md via read_file and write your response to <session_dir>/current_reader_response.md.
```

Never bundle `run_command` (`lets-read next`, `script`, `research`, `record`,
`judge`, `discuss`, or `discuss-prompt`) with `invoke_subagent` or
`send_message` in the same step—always wait for the CLI command to exit `0`
before dispatching leaf subagents, and always pass each leaf subagent's
`logAbsoluteUri` (`--subagent-log`, `--fact-check-log`, `--critic-log`,
`--topic-log`) to `lets-read`.

### Hard Anti-Race Barrier (`[HOST_WAIT | ...]` With Zero Tool Calls)

**NEVER** call `lets-read script`, `lets-read research`, `lets-read record`,
`lets-read judge`, or `lets-read discuss` before **all** dispatched leaf
subagents for the current `<round>` (`Chunk NNNN`, `Chunk NNNN (Discuss)`,
`Wrapup`, or `Wrapup (Discuss)`) have delivered their matching
`[SUBAGENT_DONE | <round> | <role>]` completion notice.

Immediately after dispatching leaf subagents—and on any intermediate wakeup turn
where fewer than all dispatched leaf subagents for the current phase have
reported (`< 1` `lets-read-script-writer` before `script`, `< 1`
`lets-read-researcher` before `research`, `< 1` `lets-read-blind-reader` before
`record` or `discuss`, `< 3` reviewers before `judge`, or `< 4` when
`lets-read-topic-curator` was dispatched)—**end your turn immediately with ZERO
tool calls**, outputting **only**:

```text
[HOST_WAIT | <round> | <phase> | <k>/<total> idle | pending: <remaining_roles>]
```

Never re-send duplicate notifications or poll with
`manage_subagents(Action: "list")`.

## Leaf Subagent Roster & Model Tiers

Always pass the designated `Model` tier whenever calling `invoke_subagent`:

- `lets-read-script-writer` (`Role: "Unresearched Script Writer"`,
  `Model: "flash"`): one-shot; kill immediately after `lets-read script`.

- `lets-read-researcher` (`Role: "Continuity & Canon Researcher"`,
  `Model: "flash"`): one-shot; kill immediately after `lets-read research`.

- `lets-read-blind-reader` (`Role: "Blind Story Reader"`, `Model: "inherit"`):
  persistent across chunks in this driver until
  `"rotate_reader_recommended": true`.

- `lets-read-prediction-judge` (`Role: "Impartial Prediction Judge"`,
  `Model: "inherit"`): persistent across chunks in this driver until
  `"rotate_judge_recommended": true`.

- `lets-read-fact-checker` (`Role: "Commentary Fact-Checker"`,
  `Model: "inherit"`): persistent across chunks in this driver until
  `"rotate_fact_checker_recommended": true`.

- `lets-read-commentary-critic` (`Role: "Commentary Critic"`,
  `Model: "inherit"`): persistent across chunks in this driver until
  `"rotate_critic_recommended": true`.

- `lets-read-topic-curator` (`Role: "Topic Index Curator"`,
  `Model: "flash_lite"`): one-shot when `"topic_curation_needed": true`; kill
  immediately after `lets-read judge`.

## Mid-Chunk Resume Check (`lets-read status`)

If `lets-read status --session "<session_dir>"` shows an already-unlocked turn
in progress (from an interrupted prior session), resume from the active phase
rather than calling `lets-read next`:

- `"awaiting_script": true` -> dispatch `lets-read-script-writer` (Step 1 of
  Single Reading Chunk or Final Wrapup).

- `"awaiting_research": true` -> dispatch `lets-read-researcher` (Step 2).

- `"awaiting_reader": true` -> dispatch `lets-read-blind-reader` (Step 3).

- `"current_recorded": true` and `"current_judged": false` -> dispatch the
  post-record reviewers (Step 5).

- `"fact_check_discussion_pending": true` -> resolve the pending fact-check peer
  query (Step 7).

## Procedure 1: Single Reading Chunk

### 1. Unlock Chunk (`next`) & Invoke `lets-read-script-writer`

```bash
<plugin_dir>/.bin/lets-read next --session "<session_dir>"
```

After `next` exits `0`, call `invoke_subagent`
(`TypeName: "lets-read-script-writer"`, `Role: "Unresearched Script Writer"`,
`Model: "flash"`) with a 1-line notification to read `current_script_prompt.md`
and write `current_script_response.md` (`Overwrite: true`), then park with
`ZERO tool calls` outputting **only**:

```text
[HOST_WAIT | Chunk NNNN | script | 0/1 idle | pending: lets-read-script-writer]
```

### 2. Quarantine Draft (`script`), Kill Script Writer & Invoke `lets-read-researcher`

Run `script` **only after**
`[SUBAGENT_DONE | Chunk NNNN | lets-read-script-writer]` arrives:

```bash
<plugin_dir>/.bin/lets-read script \
  --session "<session_dir>" \
  --subagent-log "<script_writer_logAbsoluteUri>"
```

After `script` exits `0`, kill the finished `lets-read-script-writer` via
`manage_subagents(Action: "kill")`, invoke a fresh one-shot
`lets-read-researcher` (`Role: "Continuity & Canon Researcher"`,
`Model: "flash"`) with a 1-line notification to read
`current_research_prompt.md` and write `current_research_response.md`
(`Overwrite: true`), and park with `ZERO tool calls` outputting **only**:

```text
[HOST_WAIT | Chunk NNNN | research | 0/1 idle | pending: lets-read-researcher]
```

### 3. Verify Research (`research`), Kill Researcher & Notify `lets-read-blind-reader`

Run `research` **only after**
`[SUBAGENT_DONE | Chunk NNNN | lets-read-researcher]` arrives:

```bash
<plugin_dir>/.bin/lets-read research \
  --session "<session_dir>" \
  --subagent-log "<researcher_logAbsoluteUri>"
```

After `research` exits `0`, kill the finished `lets-read-researcher` via
`manage_subagents(Action: "kill")`. When no `lets-read-blind-reader` is active
yet in this driver conversation or `"rotate_reader_recommended": true` (killing
any prior `lets-read-blind-reader` via `manage_subagents` with
`Action: "kill"`), call `invoke_subagent`
(`TypeName: "lets-read-blind-reader"`, `Role: "Blind Story Reader"`,
`Model: "inherit"`); otherwise call `send_message` to the active
`lets-read-blind-reader` `conversationId` with a 1-line notification to read
`current_prompt.md` and write `current_reader_response.md` (`Overwrite: true`).
Park with `ZERO tool calls` outputting **only**:

```text
[HOST_WAIT | Chunk NNNN | record | 0/1 idle | pending: lets-read-blind-reader]
```

### 4. Record Reader Turn (`record`)

Run `record` **only after**
`[SUBAGENT_DONE | Chunk NNNN | lets-read-blind-reader]` arrives:

```bash
<plugin_dir>/.bin/lets-read record \
  --session "<session_dir>" \
  --subagent-log "<blind_reader_logAbsoluteUri>"
```

### 5. Dispatch Post-Record Reviewers in Parallel

After `record` exits `0`, dispatch all reviewers **in parallel in the same
turn** with 1-line notifications:

- For `lets-read-prediction-judge`, `lets-read-fact-checker`, and
  `lets-read-commentary-critic`, call `invoke_subagent` (`Model: "inherit"`)
  when no active instance exists yet in this driver conversation or when its
  `"rotate_<role>_recommended": true` flag is set (killing the prior instance
  via `manage_subagents` with `Action: "kill"`); otherwise call `send_message`
  to the active `conversationId`.

- When `"topic_curation_needed": true`, also call `invoke_subagent` for
  one-shot `lets-read-topic-curator` (`Role: "Topic Index Curator"`,
  `Model: "flash_lite"`) to read `current_topic_prompt.md` and write
  `current_topic_response.md`.

Park with `ZERO tool calls` outputting **only**
`[HOST_WAIT | Chunk NNNN | judge | <k>/<total> idle | pending: <remaining_roles>]`
until all `3/3` (or `4/4` with `lets-read-topic-curator`)
`[SUBAGENT_DONE | Chunk NNNN | <role>]` notices arrive.

### 6. Apply Verdicts, Fact-Check, Critique & Topic Merges (`judge`)

Run `judge` **only after** all dispatched reviewers have reported:

```bash
<plugin_dir>/.bin/lets-read judge \
  --session "<session_dir>" \
  --subagent-log "<prediction_judge_logAbsoluteUri>" \
  --fact-check-log "<fact_checker_logAbsoluteUri>" \
  --critic-log "<commentary_critic_logAbsoluteUri>" \
  [--topic-log "<topic_curator_logAbsoluteUri>"]
```

Whenever `lets-read-topic-curator` was dispatched, kill the finished
`lets-read-topic-curator` immediately via `manage_subagents(Action: "kill")`
right after `judge` exits `0`.

### 7. Resolve Pending Fact-Check Peer Queries (`discuss`)

Whenever `judge` returns `"fact_check_discussion_pending": true`
(`"awaiting_fact_check_response"`), resolve it **before** ending the chunk or
running `next`:

1. Notify `lets-read-blind-reader` (via `send_message`, or `invoke_subagent`
   with `Model: "inherit"` if none is active) with a 1-line message to read
   `current_discussion_prompt.md` and write `current_discussion_response.md`
   (`Overwrite: true`), then park with `ZERO tool calls` outputting **only**:

   ```text
   [HOST_WAIT | Chunk NNNN (Discuss) | discuss | 0/1 idle | pending: lets-read-blind-reader]
   ```

2. Only after `[SUBAGENT_DONE | Chunk NNNN (Discuss) | lets-read-blind-reader]`
   arrives, record the reply:

   ```bash
   <plugin_dir>/.bin/lets-read discuss \
     --session "<session_dir>" \
     --subagent-log "<blind_reader_logAbsoluteUri>"
   ```

## Procedure 2: Final Wrapup Round (`"wrapup_pending": true`)

1. Run `<plugin_dir>/.bin/lets-read next --session "<session_dir>"`
   (`"is_wrapup": true`), invoke `lets-read-script-writer` (`Model: "flash"`),
   and wait with `ZERO tool calls` (`[HOST_WAIT | Wrapup | script | 0/1 idle |
   pending: lets-read-script-writer]`) for
   `[SUBAGENT_DONE | Wrapup | lets-read-script-writer]`.

2. Run `lets-read script` (`--subagent-log`), kill `lets-read-script-writer` via
   `manage_subagents(Action: "kill")`, invoke `lets-read-researcher`
   (`Model: "flash"`), and wait with `ZERO tool calls`
   (`[HOST_WAIT | Wrapup | research | 0/1 idle | pending: lets-read-researcher]`)
   for `[SUBAGENT_DONE | Wrapup | lets-read-researcher]`.

3. Run `lets-read research` (`--subagent-log`, `"status": "wrapup_unlocked"`),
   kill `lets-read-researcher` via `manage_subagents(Action: "kill")`, notify
   `lets-read-blind-reader` (via `send_message`, or `invoke_subagent` with
   `Model: "inherit"` if none is active) to read `current_prompt.md` and write
   `current_reader_response.md`, and wait with `ZERO tool calls`
   (`[HOST_WAIT | Wrapup | record | 0/1 idle | pending: lets-read-blind-reader]`)
   for `[SUBAGENT_DONE | Wrapup | lets-read-blind-reader]`.

4. Record the Final Wrapup (no `judge` step runs after `"wrapup_recorded"`):

   ```bash
   <plugin_dir>/.bin/lets-read record \
     --session "<session_dir>" \
     --subagent-log "<blind_reader_logAbsoluteUri>"
   ```

## Procedure 3: User Discussion Turn (`DISCUSS`)

1. Generate `current_discussion_prompt.md` from `<session_dir>/last_user_message.md`:

   ```bash
   <plugin_dir>/.bin/lets-read discuss-prompt \
     --session "<session_dir>" \
     --user-file "<session_dir>/last_user_message.md"
   ```

2. Notify `lets-read-blind-reader` (via `send_message`, or `invoke_subagent`
   with `Model: "inherit"` if no `lets-read-blind-reader` is active in this
   driver conversation) with a 1-line message to read
   `current_discussion_prompt.md` and write `current_discussion_response.md`
   (`Overwrite: true`), then park with `ZERO tool calls` outputting **only**
   `[HOST_WAIT | Chunk NNNN (Discuss) | discuss | 0/1 idle | pending: lets-read-blind-reader]`
   (or `Wrapup (Discuss)` after wrapup).

3. Only after `[SUBAGENT_DONE | Chunk NNNN (Discuss) | lets-read-blind-reader]`
   (or `Wrapup (Discuss)`) arrives, record the reply:

   ```bash
   <plugin_dir>/.bin/lets-read discuss \
     --session "<session_dir>" \
     --user-file "<session_dir>/last_user_message.md" \
     --subagent-log "<blind_reader_logAbsoluteUri>"
   ```
