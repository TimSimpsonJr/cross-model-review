---
name: cross-model-status
description: Plain-language report of cross-model-review state. Read-only; does NOT create the state file.
allowed-tools: Read, Bash
---

# /cross-model-status

Diagnostic report. Reads current plugin state and surfaces it in human-readable form.

## Steps

1. **Pure-read.** Do NOT create the state file if absent.

2. Resolve state in this order (matches Block B's storage-mode detection):

   a. Read `.claude/cross-model-review.session.local.md` if present → PERSISTED state.
   b. Else, scan recent conversation transcript for the most recent `[cmr-state: ...]` marker line written by a prior skill invocation in this session → EPHEMERAL state.
   c. Else → NONE (no plugin activity yet in this project AND no in-context marker either).

2.5. **Pre-upgrade chain regime detection.** Mirrors the skill bootstrap rule
   (design §10). Runs in both PERSISTED and EPHEMERAL state — the
   `[cmr-state: ...]` marker can carry `filed_issues` just like a state
   file:
   - State source has `filed_issues` field (even if `[]`) → `regime = new`.
   - State source has NO `filed_issues` field → `regime = pre-upgrade`.
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

   - **regime = new:** for each entry in `state.filed_issues` (or the
     `filed_issues` field of the in-context marker), fetch the title:

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
     with its one-line summary. (PERSISTED only — pre-upgrade chains in
     EPHEMERAL mode surface decisions in chat per Section 6 of the
     original design and have no decisions file to read.)

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
   Used in both PERSISTED and EPHEMERAL output templates below.

6. Output the status block. Three formats based on step 2 outcome:

   **PERSISTED state with active chain:**

   ```
   Cross-Model-Review Session Status
   ─────────────────────────────────

   State storage:  PERSISTED  (.claude/cross-model-review.session.local.md)
      Frontmatter resume is SUPPRESSED while state file exists.

   Mode:           INTERACTIVE | AUTONOMOUS  (per state.autonomous)

   Codex thread:   <thread_id>  (project-scoped, durable until reset; primed at <time>)
   Active chain:   <state.active_chain_artifact>
      Status:       ⏳ IN PROGRESS | ✅ COMPLETED (PR: <url>) | ⏸️ HALTED (<reason>)
      Last call:    <state.last_invocation>  (kind: <state.last_invocation_kind>)

   Approvals (active chain only — hash-validated):
      design-review:  ✅ approved | ⚠️ STALE | — N/A | ⏳ in progress | ⏸️ blocked
      plan-review:    [same options]
      impl-review:    [same options]

   Skip flag:      NOT ARMED | ARMED  (next review trigger will be suppressed)

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

   **EPHEMERAL state (in-context marker found, no state file):**

   ```
   Cross-Model-Review Session Status
   ─────────────────────────────────

   State storage:  EPHEMERAL (in-conversation marker; no writable .claude/ directory)
      State persists only for this conversation. No cross-session continuity.
      Pre-upgrade chains: per-chain decisions files cannot be written; deferred
      items surface in chat only. New-regime chains: filed_issues are tracked
      in the marker and on GitHub (gh CLI works in ephemeral contexts).

   Mode:           INTERACTIVE | AUTONOMOUS  (per marker)

   Codex thread:   <thread_id>  (ephemeral; lives only in conversation context)
   Active chain:   <marker.active_chain_artifact, if any>
      Status:       ⏳ IN PROGRESS | ⏸️ HALTED (<reason>)  [COMPLETED rare in ephemeral]
      Last call:    <marker.last_invocation>  (kind: <marker.last_invocation_kind>)

   Approvals (active chain only):
      [same format as PERSISTED, but hash-validation may be limited if
       artifacts aren't readable]

   Skip flag:      NOT ARMED | ARMED

   Hooks: <hooks_line from step 5>

   [Filed issues / Pending decisions block — regime-dependent, pick one:]

   If regime = new (marker carries filed_issues field, even if []):

   Filed issues (this chain):
      #<num> (<kind>): <title from gh issue view>
      #<num> (<kind>): <title from gh issue view>
      ... (or "(none)" if marker.filed_issues is empty)

   If regime = pre-upgrade (marker has no filed_issues field):

   Pending decisions: surfaced in chat (no decisions file in ephemeral mode)
   ```

   **NONE (no state file AND no in-context marker — truly fresh):**

   ```
   Cross-Model-Review Session Status
   ─────────────────────────────────

   State storage:  NONE
      No persisted state file AND no in-conversation marker. No cross-model-review
      activity has occurred yet in this project / session.

      In a writable project: frontmatter resume from docs/plans/ IS available for
      the next review (auto-resume only when exactly one candidate exists).
      In a read-only / projectless context: future activity will run in EPHEMERAL
      mode automatically.

   Mode:           — (defaults to interactive on first stateful action)

   To begin: invoke any cross-model-review skill, slash command (other than
   /cross-model-status or /cross-model-setup), or trigger an auto-review by
   completing brainstorming/writing-plans/subagent-driven-development.
   ```

7. Output is the only effect. No state changes (still pure-read in all branches).
