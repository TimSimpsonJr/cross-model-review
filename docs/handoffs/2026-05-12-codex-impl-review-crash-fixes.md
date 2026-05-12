# Handoff: Codex impl-review crash fixes

**Date:** 2026-05-12
**Project:** cross-model-review plugin
**Source session ran from:** `dc-v1-onboarding` (the repo where the crash happened)

---

## What We Did

Diagnosed why Claude Code sessions stop responding when `codex-impl-review` is invoked on large PRs. Identified the root cause and aligned on a four-change patch to `skills/codex-impl-review/SKILL.md` plus a one-change patch to `skills/codex-plan-review/SKILL.md`. No code was written this session — this is purely a design-and-handoff.

## Root cause

The crash that surfaced this work was an `impl-review` invocation against `TimSimpsonJr/dc-v1-onboarding` branch `fix/apex-realign` (PR #2, the `canonical-shadcn` chain). The session state file there showed `last_gate: impl-review-in-progress` — the loop died mid-call.

Payload size for that invocation:

| Component | Lines |
|-----------|-------|
| Plan doc (`docs/superpowers/plans/2026-05-11-canonical-shadcn.md`) | 1,487 |
| `git diff master..HEAD` | 5,634 |
| Universal priming block | ~78 |
| Prior thread context (design-review + plan-review approvals on same thread `019e18f9-...`) | accumulated |

That's ~7,200+ lines of fresh content in a single `mcp__codex__codex-reply` call, on top of an already-warm thread. The current `Response handling loop` re-sends the full diff on every loop pass when applying revisions, and there is **no iteration cap** anywhere in the skill. Two passes of critique-and-revise effectively doubles the diff content in the host's context window. The Claude session OOMs / hangs / dies somewhere around iteration 1–2.

The PR was already opened (PR #2 on `dc-v1-onboarding`) and all 27 tasks of the canonical-shadcn chain were complete. The user worked around the immediate problem by skipping the impl-review for that PR. This handoff is the durable fix.

## Decisions Made

- **Halt cleanly on oversized payloads rather than auto-chunking.** Chunking is the right long-term answer but it's a v0.2 feature — splitting a diff sensibly across modules requires design work (where do CHAIN-BOUNDARY markers fit? does Codex carry findings across chunks? how is final approval recorded?). For now, the size guard halts with clear guidance so the human can scope the review manually via `/cross-model-review-now impl <subset>`. Better to halt loudly than crash silently.
- **Iteration cap is 5 rounds.** This matches the order-of-magnitude where existing review chains tend to converge in practice (Codex usually settles in 2–3 rounds; 5 leaves headroom for genuinely contested reviews). On hitting the cap, force-exit and reclassify remaining open items as MINOR with a `noted, deferred` PR note — mirrors the existing handling for MINOR severity. Do NOT auto-approve at the cap.
- **Don't re-send the full diff on loop iteration ≥ 2.** Codex already has read-only sandbox access (per the universal priming). After the first round, send only: (a) a summary of which findings were addressed and by whom (subagent name / commit-stub), and (b) the list of files Codex should re-read. Codex verifies fixes by reading the working tree, not by re-receiving the diff. This change alone removes the multiplicative context blowup.
- **Apply iteration cap to `codex-plan-review` too** (just the cap, not the size guard or the re-send change). Plan-review payloads are small (~1,500-line plan docs at most) so the size guard isn't load-bearing, but the loop pattern is identical and the cap is a one-line guard that prevents the same crash class on adversarial plan reviews.
- **Scope: skill files only.** No design-doc changes, no MCP/tool changes, no host-project state-schema changes. The semantics of `state.codex_thread_id`, `chain_just_changed`, `[CHAIN-BOUNDARY]`, etc. all remain the same.

## Current State

Nothing in the plugin repo has changed yet. The diagnosis was done by reading skills + design doc; no edits, no branches, no commits. The marketplace clone at `C:\Users\tim\.claude\plugins\marketplaces\cross-model-review\` has already been synced by the user before this handoff was written, so working-tree state in either location should be clean (or contain only the user's own in-flight work).

Files to be edited next session:
- `skills/codex-impl-review/SKILL.md` — four changes (see below)
- `skills/codex-plan-review/SKILL.md` — one change (iteration cap only)
- `CHANGELOG.md` — bump (likely a 0.x patch entry, "prevent context-exhaustion crashes on large-diff impl-review")
- `MANIFEST.md` — regenerate per the user's MANIFEST doctrine (owned repo, included in PR)

## What Remains

The actual implementation, in this order:

1. **Branch off `main`.** Suggested name: `fix/impl-review-context-exhaustion`.
2. **Patch `skills/codex-impl-review/SKILL.md`** — four changes:
   - **Bootstrap size guard.** After current step 5 (code-detection heuristic), add a new step that computes `diff_lines + plan_lines`. If total > 4,000 lines:
     - INTERACTIVE: post a chat note describing payload size, the risk, and suggest the user invoke `/cross-model-review-now impl <subset-path>` to chunk manually, or `/cross-model-skip` to skip. Exit skill.
     - AUTONOMOUS: HALT per design doc § 9.6; write halt note to `.claude/cross-model-review/decisions/<basename>.md` with payload size; surface in chat with the same chunk/skip guidance. Set `chain_status = "halted"`.
     - Threshold rationale: empirically the crash hits around ~7K lines combined; 4K leaves margin for the thread to already be warm. Treat as a tunable constant; pick one place at the top of the section.
   - **Iteration cap in Response handling loop.** Initialize `loop_iteration = 0` before the loop. Increment at the top of each iteration. After increment, if `loop_iteration > 5`: force-exit. Force-exit behavior: post chat note "Codex review hit iteration cap (5) without convergence. Remaining open findings logged as MINOR — see decisions file. Manual review needed before approving." Write open findings to decisions file. Do NOT write `state.impl_review_approved_sha`. Do NOT advance `chain_status` to completed. Leave the chain in an explicit `halted` state.
   - **Don't re-send full diff on iterations ≥ 2.** In branch 3 (substantive critique) of the response handling loop: on first revision (loop_iteration == 1), the loop-back sends the same way as today (revised diff + plan if chain has one). On loop_iteration ≥ 2: send only "Round N revisions: <bullet list of finding → subagent → commit stub>. Files updated since last round: <git diff --name-only HEAD~N..HEAD>. Use your read-only sandbox to verify fixes; no diff attached this round." This relies on Codex's documented sandbox capability per the universal priming.
   - **Document the new behavior in the skill's preamble.** Add a one-sentence note near "Priming for Claude" explaining that the loop is capped at 5 rounds and that large payloads halt at bootstrap. Keep it short — the implementation details live in the bootstrap / loop sections.
3. **Patch `skills/codex-plan-review/SKILL.md`** — single change:
   - Iteration cap, same shape as impl-review's: 5-round cap, force-exit posts chat note + writes open findings to decisions file + leaves `chain_status = "halted"`. No `codex_plan_review_status: approved` written on cap-exit.
4. **Update `CHANGELOG.md`** with an entry describing the three guards and the deferred-chunking note.
5. **Regenerate `MANIFEST.md`** to reflect any structural changes (probably none — just skill body edits — but the user's MANIFEST doctrine requires regeneration before PR merge in owned repos).
6. **Open a PR to `main`.** Title: `fix: prevent context-exhaustion crashes on large impl-reviews`. Body should explain the root cause (with the canonical-shadcn anecdote anonymized to "a large PR with ~5.6K-line diff + ~1.5K-line plan") and the three guards.
7. **Test plan in the PR body** — be honest that this is hard to integration-test without a real MCP Codex thread and a large repo to run against. Suggest the user dogfoods the fix by running the next real impl-review and confirming the size guard fires (or doesn't) appropriately.

## Open Questions

- **Should the size threshold be configurable?** The patch ships a hardcoded 4,000-line cap. Configurability could come via `state.size_guard_threshold` or a plugin-level setting. The user's call — recommend hardcoding for v0.1 and revisiting only if it misfires in practice.
- **Should the iteration cap differ between modes?** Plan-review and impl-review both get 5 in this proposal. Plan-review tends to converge faster (smaller artifact) so 3 might be enough there, but a uniform cap is simpler to reason about. Leaving uniform unless the user prefers tuned.
- **What about `codex-brainstorm-partner`?** Not patched here. Brainstorming naturally converges (user-driven) so unbounded loops are less of a risk, but if a brainstorm goes adversarial and circular, the same crash class applies. Out of scope for this handoff — file a separate issue if you want to address it.
- **Should design-doc § 9.x get a new subsection documenting the size guard / iteration cap?** The design doc currently doesn't reference iteration limits anywhere. Adding a "§ 9.8 Resource limits" section would keep the design honest. Recommend doing this as part of the same PR.

## Context to Reload

- **Repo:** `TimSimpsonJr/cross-model-review` — owned by the user, so the labeling rule applies (`autonomous-safe` for this code-only fix). Once the issue/PR is filed, label `autonomous-safe`.
- **The user develops the plugin at `C:\Users\tim\OneDrive\Documents\Projects\cross-model-review`** and syncs to `C:\Users\tim\.claude\plugins\marketplaces\cross-model-review` (the runtime install) manually. Edits to skills here take effect immediately on next plugin invocation — useful for dogfooding.
- **The dc-v1-onboarding session that crashed is unblocked** — the user worked around it by skipping the impl-review for PR #2. Don't worry about restoring or fixing that thread; the canonical-shadcn chain was already complete and merged (or about to be).
- **The plugin uses itself for its own design/review cycle.** Don't break it mid-session — i.e., don't invoke `/cross-model-review-now` against the in-progress PR for this fix without first confirming the new size guard tolerates the plugin's own diff. The skill edits here are small (~50 lines per file) so this should be fine, but worth checking.
- **Don't touch `mcp__codex__codex` or `mcp__codex__codex-reply` invocation shapes.** They're external MCP tools; the plugin just calls them. All fixes are in the prompt assembly / loop control layer.
- **Design doc cross-references** to know about while editing:
  - § 5.4 (anchorless impl-review) — referenced by the impl-review bootstrap; don't break this path.
  - § 9.2 (chain stem-matching) — referenced by the chain-update logic; don't break.
  - § 9.6 (autonomous halt semantics) — your halt paths should match this.
  - § 9.7 (approval frontmatter schema) — impl-review doesn't write to artifact frontmatter; don't accidentally start.
- **The CHAIN-BOUNDARY marker mechanism is unrelated to these fixes** — don't conflate "thread accumulation" (which CHAIN-BOUNDARY addresses) with "single-call payload size" (what this fix addresses). They're different failure modes.
