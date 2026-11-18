---
name: cross-model-status
description: Plain-language report of cross-model-review state. Read-only; does NOT create the state file.
allowed-tools: Read, Bash
---

# /cross-model-status

Diagnostic report. Reads current plugin state and surfaces it in human-readable form.

## Steps

1. **Pure-read.** Do NOT create the state file if absent.

2. Resolve state in this order:

   a. Read `.claude/cross-model-review.session.local.md` if present → PERSISTED state.
   b. Else → NONE (no plugin activity yet in this project, OR `.claude/` is not writable — v0.3.0 does not run review skills in non-persisted contexts; see step 6's NONE block).

2.5. **Pre-upgrade chain regime detection.** Mirrors the skill bootstrap rule
   (design §10). Only applies to PERSISTED state:
   - State file has `filed_issues` field (even if `[]`) → `regime = new`.
   - State file has NO `filed_issues` field → `regime = pre-upgrade`.
   - NONE state → `regime` is undefined (no chain yet; nothing to display
     either way).

   This is read-only: do NOT add the field if it's missing — its absence
   is the durable marker. Status reports the chain as it stands, never
   mutates it.

3. Compute approval state per design doc Section 9.7:
   - For active chain (or anchorless impl-only chain), check artifact frontmatter for approval status + hash.
   - Compute current artifact body hash. If matches recorded → approved. Else → STALE.
   - Cascade staleness: design stale → plan + impl stale; plan stale → impl stale.

4. **Filed issues / pending decisions** (regime-dependent — pick exactly one):

   - **regime = new:** for each entry in `state.filed_issues`, fetch the title:

     ```bash
     gh issue view <number> --json title --jq .title
     ```

     Format as `   #<number> (<kind>): <title>`. If `gh` fails for any
     issue (deleted, repo unreachable, network error, etc.), emit
     `   #<number> (<kind>): (title unavailable)` for that entry and
     continue. Do NOT halt the status command — it is informational, and
     a single title-fetch failure shouldn't break the whole report. If
     `state.filed_issues` is empty, emit `   (none)`.
   - **regime = pre-upgrade:** read per-chain
     `.claude/cross-model-review/decisions/<basename>.md` if exists,
     count entries with format `## decision-...`, and list each handle
     with its one-line summary.

4.5. **In-flight Codex reviews.** Read `state.codex_reviews_in_progress` (v0.3.0+ field; absent in pre-upgrade chains). For each entry, compute elapsed time from `started_at` to now. Format the section in step 6's PERSISTED output below. If the field is absent or empty, omit the section.

5. **Per-rule hooks check.** Enumerate the planned rule list and count
   how many are installed. Mirrors the per-rule install pattern from
   `/cross-model-setup` step 8 (design §9.4).

   **NOTE for maintainers:** the PLANNED list below MUST stay in sync
   with the rule files written by `/cross-model-setup` step 8. If you
   add a third hookify rule (or any future rule type), update both
   files in lockstep — otherwise this report will be wrong-by-one and
   setup will quietly stop installing the new rule.

   ```bash
   PLANNED=(
     ".claude/hookify.cross-model-plan-review.local.md"
     ".claude/hookify.cross-model-impl-review.local.md"
   )
   installed=0
   for f in "${PLANNED[@]}"; do
     [ -f "$f" ] && installed=$((installed + 1))
   done
   total=${#PLANNED[@]}

   if [ "$installed" -eq "$total" ]; then
     hooks_line="Hooks: $total of $total installed."
   else
     hooks_line="Hooks: $installed of $total installed (re-run /cross-model-setup to add missing)."
   fi
   ```

   The "(re-run /cross-model-setup …)" suffix only appears when N < M.
   Used in the PERSISTED output template below.

5.5. **Host sandbox mode (read-only display).** Run `uname -s`. If it matches
   `MINGW*` / `MSYS*` / `CYGWIN*`, the host's Codex launches use
   `workspace-write` (write-capable: in-repo writes possible, network denied);
   otherwise `read-only`. This reports the mode THIS HOST would use for a NEW
   launch right now — it is NOT a per-in-flight-review field (the in-flight slot
   schema has no sandbox field; v0.4.1 design §6/§9.2). Do not infer a running
   job's mode from it.

6. Output the status block. Two formats based on step 2 outcome:

   **PERSISTED state with active chain:**

   ```
   Cross-Model-Review Session Status
   ─────────────────────────────────

   State storage:  PERSISTED  (.claude/cross-model-review.session.local.md)
      Frontmatter resume is SUPPRESSED while state file exists.

   Mode:           INTERACTIVE | AUTONOMOUS  (per state.autonomous)
   Sandbox (this host): WORKSPACE-WRITE (Windows; in-repo writes possible, network denied) | READ-ONLY
      Mode this host would use for a NEW Codex launch (not a running job's mode).

   Codex thread:   <thread_id>  (most-recently-completed chain; in-flight threads tracked below)
   Active chain:   <state.active_chain_artifact>
      Status:       ⏳ IN PROGRESS | ✅ COMPLETED (PR: <url>) | ⏸️ HALTED (<reason>)
      Last call:    <state.last_invocation>  (kind: <state.last_invocation_kind>)

   Approvals (active chain only — hash-validated):
      design-review:  ✅ approved | ⚠️ STALE | — N/A | ⏳ in progress | ⏸️ blocked
      plan-review:    [same options]
      impl-review:    [same options]

   Skip flag:      NOT ARMED | ARMED  (next review trigger will be suppressed)

   In-flight Codex reviews (if state.codex_reviews_in_progress is non-empty):
      - <kind> on <chain_artifact> (branch <branch>, elapsed <Hh Mm Ss>, bg_id <bash_id>, status <in_progress|detached|stale_thread_error|usage_limit>)
      - (repeat per entry)
      For a failed entry, add one line under it explaining the status:
        stale_thread_error → "Codex thread expired. Start a fresh review with /cross-model-review-now <kind>."
        usage_limit        → "Codex hit its usage limit; the thread is fine. Retry with /cross-model-review-now <kind> once the limit resets."

   Hooks: <hooks_line from step 5>

   [Filed issues / Pending decisions block — regime-dependent, pick one:]

   If regime = new:

   Filed issues (this chain):
      #<num> (<kind>): <title from gh issue view>
      #<num> (<kind>): <title from gh issue view>
      ... (or "(none)" if state.filed_issues is empty)

   If regime = pre-upgrade:

   Pending decisions: N items in .claude/cross-model-review/decisions/<basename>.md
      <handle>: <one-line summary>
      <handle>: <one-line summary>
   ```

   **NONE (no state file present):**

   ```
   Cross-Model-Review Session Status
   ─────────────────────────────────

   State storage:  NONE
      No persisted state file present. Either no cross-model-review activity has
      occurred yet in this project, OR `.claude/` is not writable.

      If `.claude/` is writable, frontmatter resume from docs/superpowers/specs/,
      docs/superpowers/plans/, or legacy docs/plans/ is available for the next
      review (auto-resume when exactly one candidate exists).

      If `.claude/` is NOT writable, invoking a cross-model-review skill here will
      halt with a chat note explaining the persisted-mode requirement. v0.3.0 does
      not run async Codex reviews in non-persisted (ephemeral) contexts. Either
      run `/cross-model-setup` to initialize state in a writable project, or
      invoke this plugin from a normal project context.

   Mode:           — (defaults to interactive on first stateful action)
   Sandbox (this host): WORKSPACE-WRITE (Windows; in-repo writes possible, network denied) | READ-ONLY
      Mode this host would use for a NEW Codex launch (not a running job's mode).

   To begin: invoke any cross-model-review skill, slash command (other than
   /cross-model-status or /cross-model-setup), or trigger an auto-review by
   completing brainstorming/writing-plans/subagent-driven-development.
   ```

7. Output is the only effect. No state changes (still pure-read in all branches).
