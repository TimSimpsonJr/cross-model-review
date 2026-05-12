---
name: cross-model-reset
description: Start a fresh cross-model-review chain in this project. Writes default-state file (overwrites existing). Does NOT touch design / plan doc content.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-reset

Reset the cross-model-review chain to start fresh.

## Steps

1. Bootstrap state (read or create).

2. Capture the previous `codex_thread_id` for the chat note (will be released). If a prior state file exists, also capture its `context_limit_tokens` value so step 3 can preserve it across the reset.

2.5. **In-flight Codex reviews handling (v0.3.0).** Check `state.codex_reviews_in_progress` for entries with `status: in_progress`. If any exist, do NOT silently clear them — they correspond to live Codex bg jobs.

   Interactively ask the user:

   ```
   /cross-model-reset called with N in-flight Codex review(s):
     - <kind> on <chain_artifact> (branch <branch>, elapsed <Hh Mm>, bg_id <bash_id>)
     - (repeat)

   v0.3.0 does NOT support cancel-and-kill. Reset will:
     1. Mark each in-flight entry as status: detached
     2. Leave the bg jobs running to natural disk completion
     3. When they finish later, surface a "Detached <kind> completed"
        chat note (no findings routed; the result file location will
        be reported for manual review).
     4. orphan codex.exe processes will exist until Codex finishes
        naturally.

   Proceed? [Y/n]
   ```

   If user confirms: mark each in-flight entry's `status: "detached"` (do NOT remove the entries; the on-bg-completion handler in each skill body recognizes detached status). Continue to step 3.

   If user declines: abort the reset entirely; no state changes; exit.

3. Overwrite the state file with defaults — **preserving any detached entries from step 2.5** in `codex_reviews_in_progress`. Reset **preserves `context_limit_tokens`** (user-tuned project config) and sets **`filed_issues: []`** (reset establishes a fresh new-regime chain — the field is set, not omitted, per the writer contract in design §6.1):

   ```yaml
   ---
   autonomous: false
   codex_thread_id: null
   active_chain_artifact: null
   active_chain_branch: null
   chain_status: null
   skip_next_review: false
   last_invocation: null
   last_invocation_kind: null
   impl_review_approved_sha: null
   filed_issues: []
   codex_reviews_in_progress: [<detached entries from step 2.5, if any>]
   context_limit_tokens: 200000
   session_start: <current ISO timestamp>
   ---

   # Cross-Model-Review Session State

   Auto-managed by the cross-model-review plugin. To reset, run `/cross-model-reset`.
   ```

   The `200000` shown above is the fallback for a true fresh start. If a prior state file existed (captured in step 2), **preserve its `context_limit_tokens` value verbatim** — substitute it for `200000`. Only `filed_issues: []` and the detached-entry preservation are unconditional.

4. **Do NOT touch design or plan doc frontmatter.** Their `codex_thread_id` and approval fields persist as fallback for *new* installs without state files; they won't be consulted while the post-reset state file exists.

5. Output:

   ```
   /cross-model-reset done.

   Session state reset to defaults. Active codex_thread_id was <previous_id> — now released.

   Next Codex invocation in this project will:
     - Start a fresh thread with the universal priming
     - NOT resume from any design / plan doc's codex_thread_id frontmatter
       (state file is present, marking active session)

   Frontmatter resume stays suppressed as long as the state file exists. To
   re-enable frontmatter resume (rare): manually delete
   .claude/cross-model-review.session.local.md.

   For a fresh start in a different chain: edit your design doc, or invoke
   /cross-model-review-now <kind> on the new artifact.
   ```
