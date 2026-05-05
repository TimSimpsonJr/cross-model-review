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

2. Bootstrap state.

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

4. **Bypass duplicate-guard and skip:**
   - Mark this invocation as `manual_invocation = true` so review skills' bootstrap skip the duplicate-guard.
   - Do NOT consume `state.skip_next_review` — it stays armed for the next AUTO-trigger.

5. Invoke the appropriate skill with the resolved artifact:
   - `design` or `plan` → `codex-plan-review` with mode set accordingly
   - `impl` → `codex-impl-review`

6. Output before invoking:

   ```
   Manually invoking codex-{kind}-review on <artifact>.

   Bypassing duplicate-trigger guard (manual invocation).
   Bypassing skip flag (manual invocation does NOT consume skip — skip stays armed for next auto-trigger).
   ```
