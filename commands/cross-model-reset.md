---
name: cross-model-reset
description: Start a fresh cross-model-review chain in this project. Writes default-state file (overwrites existing). Does NOT touch design / plan doc content.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-reset

Reset the cross-model-review chain to start fresh.

## Steps

1. Bootstrap state (read or create).

2. Capture the previous `codex_thread_id` for the chat note (will be released).

3. Overwrite the state file with defaults:

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
   session_start: <current ISO timestamp>
   ---

   # Cross-Model-Review Session State

   Auto-managed by the cross-model-review plugin. To reset, run `/cross-model-reset`.
   ```

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
