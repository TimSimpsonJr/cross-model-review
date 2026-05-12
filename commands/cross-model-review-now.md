---
name: cross-model-review-now
description: Manually invoke a Codex review (design / plan / impl). Bypasses duplicate-trigger guard. Bypasses skip flag without consuming it. Requires unambiguous artifact target.
allowed-tools: Read, Write, Edit, Bash
argument-hint: design|plan|impl [optional path]
---

# /cross-model-review-now

Manually invoke a Codex review. Useful when auto-triggers misfire or when you want to force a review on a specific artifact.

**Usage:**
- `/cross-model-review-now design` — review the active design doc
- `/cross-model-review-now plan` — review the active plan doc
- `/cross-model-review-now impl` — review the current branch's diff vs base
- `/cross-model-review-now <kind> <path>` — explicit artifact path

## Steps

1. Parse the `<kind>` argument. If missing or invalid, output: "Usage: /cross-model-review-now <design|plan|impl> [path]" and exit.

2. Bootstrap state. If the state file is missing, fresh-create with defaults (writer contract, design §6.1) including:

   ```yaml
   filed_issues: []
   context_limit_tokens: 200000
   ```

   alongside the other v0.1 defaults. If the state file exists, **preserve `filed_issues` and `context_limit_tokens` verbatim** on any subsequent write from this command.

3. Resolve the artifact per design doc Section 7.1:

   **For `design`:**
   - If `state.active_chain_artifact` matches `docs/plans/*-design.md` → use it.
   - Else if explicit path passed → use it; verify exists.
   - Else search `docs/plans/` for the most recent `*-design.md` on the current branch within last 24h. If exactly one → use it. Zero or many → ask (interactive) / halt + log (autonomous).

   **For `plan`:**
   - If explicit path passed → use it.
   - Else if `state.active_chain_artifact` matches `*-design.md` → derive plan path: strip `-design`, look for `<stem>.md` or `<stem>-plan.md`. If exactly one exists → use it.
   - Else if `state.active_chain_artifact` matches a plan doc → use it directly.
   - Else if `state.active_chain_artifact` is `branch:<branch-name>` → error: "Anchorless impl-only chain — no plan doc to review. Use `/cross-model-review-now impl` instead."
   - Else search; same disambiguation as design.

   **For `impl`:**
   - Must be on a feature branch.
   - Use `git diff <branch-base>..HEAD`.
   - Default branch → ask / halt.
   - Branch-base undeterminable → halt with note.

4. **In-flight duplicate check (v0.3.0).** Before launching, scan `state.codex_reviews_in_progress` for an entry with the same raw `(chain_artifact, branch)` pair (any kind) AND `status: in_progress`. If found, REJECT with chat note:

   ```
   A `<existing-kind>` review for `<chain-artifact>` on branch `<branch>` is
   already in progress (bg_id `<bash_id>`, started `<ts>`).

   Same-chain reviews are sequential — wait for it to complete, or run
   `/cross-model-reset` to detach (the bg job continues to disk completion
   but the plugin stops tracking it; no cancel-and-kill in v0.3.0).
   ```

   Note: the dedup is raw `(chain_artifact, branch)` string-pair, NOT stem-matched. Edge case (documented limitation, see v0.3.0 CHANGELOG): plan-review on `docs/plans/foo-plan.md` and a concurrent `/cross-model-review-now impl` (which resolves to `branch:<branch>`) target the same logical chain but have different `chain_artifact` strings, so dedup misses the conflict. The user-visible failure mode is split continuity: two Codex threads for one logical chain. Stem-matching dedup is future refinement.

   Reviews of DIFFERENT chain artifacts in the same project, or the same artifact on different branches, are legitimately concurrent and proceed in parallel.

5. **Bypass duplicate-guard and skip:**
   - Mark this invocation as `manual_invocation = true` so review skills' bootstrap skip the duplicate-trigger guard (the time-based one).
   - Do NOT consume `state.skip_next_review` — it stays armed for the next AUTO-trigger.
   - Note: the in-flight duplicate check in step 4 is NOT bypassed by manual invocation — two reviews for the same chain conflict regardless of trigger source.

6. Invoke the appropriate skill with the resolved artifact:
   - `design` or `plan` → `codex-plan-review` with mode set accordingly
   - `impl` → `codex-impl-review`

7. Output before invoking:

   ```
   Manually invoking codex-{kind}-review on <artifact>.

   Bypassing duplicate-trigger guard (manual invocation).
   Bypassing skip flag (manual invocation does NOT consume skip — skip stays armed for next auto-trigger).
   ```
