All {{TOTAL_CHUNKS}} story chunks of *{{TITLE}}* have been read and `prediction-judge` has rendered its final rulings! Please write your dedicated **Final Wrapup & Retrospective** for the Let's Read session.
- Reader Memory File (mandatory read — includes `### Latest Prediction Judge Rulings` from the finale): {{MEMORY_FILE}}
- Prediction Hall of Fame & Shame (mandatory read — complete final scoreboard, Major Hits, Subverted Twists, and Debunked Misses): {{HALL_OF_FAME_FILE}}
- Story Chunks Indices (`chunks/by_chronology.md` & `chunks/by_topic.md`, on-demand `read_file`): {{CHUNKS_DIR}}
- Session Commentary Entries Indices (`entries/by_chronology.md` & `entries/by_topic.md`, on-demand `read_file`): {{ENTRIES_DIR}}
- Predictions Indices (`predictions/by_chronology.md` & `predictions/by_topic.md`, on-demand `read_file`): {{PREDICTIONS_DIR}}
- Curated Memory Snapshots Archive (`archive/memory/`, on-demand `read_file`): {{ARCHIVE_DIR}}
- Output Response File (mandatory write via `write_file` with `Overwrite: true`): {{READER_RESPONSE_FILE}}
- Active Persona: {{ACTIVE_PERSONA}}
{{CRITIC_CONTEXT}}
## Final Wrapup Instructions
1. Read `memory.md` and `predictions/hall_of_fame.md` first (applying any `## Persona & Style Critique` notes above silently, plus reading any `chunks/by_chronology.md`, `entries/by_chronology.md`, or `predictions/pred_XXXX.md` files you want to reference).
2. Stay in your Active Persona as a live reader wrapping up the thread (do NOT write a stiff academic essay or use banned review jargon; do NOT start with a top `# Final Wrapup` heading as `LetsRead` prepends the section header automatically).
3. Cover these four angles naturally in `=== COMMENTARY ===`:
   - **Finale Verdicts & Immediate Aftermath**: React to `prediction-judge`'s final rulings from the last chunk (`### Latest Prediction Judge Rulings` in `memory.md`).
   - **Whole-Story & Character Retrospective**: Trace how the premise evolved from Chunk 1 to the finale, which characters (including original or supporting cast) stole the show, and how the central mysteries, themes, or canon crossovers locked together.
   - **The Corkboard Autopsy (`hall_of_fame.md`)**: Review your final prediction scoreboard with good humor—highlighting your proudest multi-chunk `CONFIRMED` hits, your favorite authorial `SUBVERTED` twists/red herrings, and your funniest `DEBUNKED` conspiracy theories or early Chunk 1–3 misconceptions.
   - **Running Gags, Lingering Hooks & Closing Sign-Off**: Call back to the thread's favorite running jokes and standout moments, note any open sequel hooks, and sign off warmly.
4. Write `=== COMMENTARY ===` (and optionally `=== CHUNK SUMMARY ===` with `- **[Entry | Topics: Wrapup, Retrospective, ...]** <1-line wrapup summary>` and `=== UPDATED MEMORY ===`; `=== PREDICTION UPDATES ===` is not needed) to `{{READER_RESPONSE_FILE}}` using `write_file` (`Overwrite: true`), and once `write_file` succeeds, immediately end your turn with ONLY a 1-line plain-text completion notice and no tool calls (do not call `send_message` or re-read files).
