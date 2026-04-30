---
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

3. Compute approval state per design doc Section 9.7:
   - For active chain (or anchorless impl-only chain), check artifact frontmatter for approval status + hash.
   - Compute current artifact body hash. If matches recorded → approved. Else → STALE.
   - Cascade staleness: design stale → plan + impl stale; plan stale → impl stale.

4. Compute pending decisions count: read per-chain `decisions-<basename>.md` if exists, count entries with format `## decision-...`.

5. Output the status block. Three formats based on step 2 outcome:

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
      Pending-decisions and per-chain files cannot be written; deferred items
      surface in chat only.

   Mode:           INTERACTIVE | AUTONOMOUS  (per marker)

   Codex thread:   <thread_id>  (ephemeral; lives only in conversation context)
   Active chain:   <marker.active_chain_artifact, if any>
      Status:       ⏳ IN PROGRESS | ⏸️ HALTED (<reason>)  [COMPLETED rare in ephemeral]
      Last call:    <marker.last_invocation>  (kind: <marker.last_invocation_kind>)

   Approvals (active chain only):
      [same format as PERSISTED, but hash-validation may be limited if
       artifacts aren't readable]

   Skip flag:      NOT ARMED | ARMED

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

6. Output is the only effect. No state changes (still pure-read in all branches).
