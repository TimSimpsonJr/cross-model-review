# Codex Review Convergence + Depth Calibration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the open-ended plan/design review loop with a parseable per-round verdict gate, per-mode depth calibration, and a subagent-first impl-review minor path, so Codex reviews converge in a few rounds again without losing the deeper repo-aware review.

**Architecture:** Markdown-driven Claude Code plugin — behavior lives in three skill bodies (`codex-plan-review`, `codex-impl-review`, `codex-brainstorm-partner`). The universal priming is byte-identical (lockstep) across all three; the verdict-contract block is byte-identical across the two review skills; depth headers are mode-specific. No runtime code, no test harness — verification is Grep/diff checks that edits landed and lockstep blocks stayed identical, plus a final dogfood review.

**Tech Stack:** Markdown skills; Codex CLI (`codex exec`); git; gh.

**Source of truth:** `docs/plans/2026-06-01-codex-review-convergence-design.md` (this branch, `feat/review-verdict-gate`).

---

## Conventions for this plan

- **No pytest.** Each task ends with a verification step using Grep/diff and a commit.
- Two reusable blocks are defined verbatim in **Appendix A** (priming bullet) and **Appendix B** (verdict contract). Paste them byte-for-byte where referenced; never retype them.
- After any edit to the **priming** block, re-run the lockstep diff (Task 8 helper) before committing the lockstep set together.
- Read the design doc first; it is the rationale for every task here.

---

### Task 1: Generalize the shared priming bullet (lockstep — all three skills)

Removes the one-size-fits-all "verify against actual code / cite file paths and line numbers" directive and the fuzzy "Signal convergence with 'looks good'" line; points depth + verdict to the per-turn prompt. Applied **identically** to all three skills.

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md:71-78`
- Modify: `skills/codex-impl-review/SKILL.md` (same bullet, ~ll. 71-78)
- Modify: `skills/codex-brainstorm-partner/SKILL.md` (same bullet, ~ll. 60-67)

**Step 1: Replace the bullet text in `codex-plan-review`.**

Old (exact):
```
   When returning findings, start each finding with a parseable tag line of
```
— leave that and everything after it unchanged. Replace ONLY the prose from `2. Design / plan / diff review:` through `concerns.` with **Appendix A**.

**Step 2: Apply the identical replacement** in `codex-impl-review` and `codex-brainstorm-partner`.

**Step 3: Verify byte-identical priming across the three.**

Run:
```bash
for f in codex-plan-review codex-impl-review codex-brainstorm-partner; do
  awk '/^## / { if (b) exit; if ($0 ~ /Universal Codex priming/) b=1 } b {print}' "skills/$f/SKILL.md" > "/tmp/p-$f.txt"
done
diff /tmp/p-codex-plan-review.txt /tmp/p-codex-impl-review.txt && \
diff /tmp/p-codex-plan-review.txt /tmp/p-codex-brainstorm-partner.txt && echo "PRIMING IDENTICAL"
```
Expected: `PRIMING IDENTICAL`.

**Step 4: Verify the deleted phrases are gone (all three).**

Run:
```bash
grep -rn "Cite file paths and line numbers\|Signal" skills/*/SKILL.md
```
Expected: no matches inside the priming blocks (the only "cite line numbers" guidance now lives in the per-turn depth headers added in Task 2).

**Step 5: Commit.**
```bash
git add skills/codex-plan-review/SKILL.md skills/codex-impl-review/SKILL.md skills/codex-brainstorm-partner/SKILL.md
git commit -m "feat(priming): generalize review bullet; depth+verdict move to per-turn prompt"
```

---

### Task 2: Add depth header + verdict contract to `codex-plan-review` per-turn prompt

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md` Step 2 (`### Step 2: Compose the prompt`, ll. 251-290)

**Step 1: Define the mode-specific depth headers.** Immediately before the **True-fresh content** block, add:

```markdown
**Depth header** (`<depth-header>` below) — choose by mode:

- `design-review`:
  > You are reviewing a DESIGN DOCUMENT at the architecture level. Read the
  > repo only to check whether the design's assumptions about existing code
  > hold (e.g. a module it relies on already works differently than assumed).
  > Do NOT cite line numbers, nitpick naming, or raise implementation-level
  > detail — that belongs at the implementation-plan gate, not here.

- `plan-review`:
  > You are reviewing an IMPLEMENTATION PLAN. Verify it in detail against the
  > actual repo: confirm referenced symbols exist and behave as the plan
  > claims, check file paths, and flag any drift from the previously-approved
  > design.

`<verdict-contract>` below is the block in **Appendix B**, sent verbatim every round.
```

**Step 2: Insert `<depth-header>` and `<verdict-contract>` into the True-fresh block.** Change it to:
```text
<full universal priming text from the Universal Codex priming section>

[MODE: <this-mode>]

<depth-header>

<verdict-contract>

<artifact content>
```

**Step 3: Insert the same two placeholders into the Continuation block:**
```text
[CHAIN-BOUNDARY] starting new task: <stem>; previous task: <old-stem>   ← only if chain_just_changed

[MODE: <this-mode>]

<depth-header>

<verdict-contract>

<artifact content>
```

**Step 4: Verify.**
```bash
grep -n "depth-header\|verdict-contract\|VERDICT: approved" skills/codex-plan-review/SKILL.md
```
Expected: depth-header + verdict-contract referenced in both the True-fresh and Continuation blocks; Appendix B's literal present.

**Step 5: Commit.**
```bash
git add skills/codex-plan-review/SKILL.md
git commit -m "feat(plan-review): per-turn depth header + verdict contract"
```

---

### Task 3: Add the verdict contract to `codex-impl-review` per-turn prompt

impl-review keeps its existing depth instruction (`Review this implementation against the approved plan…`); the verdict contract is appended after it in **both** prompt variants.

**Files:**
- Modify: `skills/codex-impl-review/SKILL.md:265` and `:279`

**Step 1:** In the True-fresh block, after the line
`Review this implementation against the approved plan. Categorize findings as CRITICAL / IMPORTANT / MINOR per universal priming.`
add a blank line and then the **Appendix B** verdict contract (verbatim).

**Step 2:** Apply the identical addition in the Continuation block (l. 279).

**Step 3: Verify the verdict-contract block is byte-identical to plan-review's.** Extract both skills' Appendix-B insertions and diff:
```bash
grep -n "End your review with a verdict" skills/codex-plan-review/SKILL.md skills/codex-impl-review/SKILL.md
```
Then visually confirm the block text matches Appendix B in both. (Task 8 re-checks this mechanically.)

**Step 4: Commit.**
```bash
git add skills/codex-impl-review/SKILL.md
git commit -m "feat(impl-review): append verdict contract to per-turn prompt"
```

---

### Task 4: Rewrite `codex-plan-review` routing (verdict-driven + fix-before-moving-on)

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md` Routing section (ll. 427-480) and convergence detection (l. 433)

**Step 1: Replace the Routing entry sequence** so it parses the verdict instead of fuzzy-matching. Replace the current item 1 (`**Convergence signal**` …) and item 3 (`**Substantive critique**` …) with:

```markdown
1. **Parse the verdict from the final non-empty line** (trimmed), requiring
   exact equality to `[VERDICT: approved]` or `[VERDICT: changes-requested]`;
   ignore any earlier occurrence (e.g. Codex quoting the contract). A literal
   token appearing anywhere but the final line is treated as ambiguous.
   - `[VERDICT: approved]` → **APPROVAL.** Apply any `Non-blocking notes:` as a
     single final polish edit (§4 of the design), THEN compute the approval
     hash on the post-edit body, write `codex_<kind>_status: approved` +
     `codex_<kind>_approved_hash: <sha256>` and `codex_thread_id` to the
     artifact frontmatter, post "Codex approved <kind> after N rounds.", exit loop.
   - `[VERDICT: changes-requested]` → go to the entry check, then revise.
   - **Final line is not an exact literal** (missing / reworded / wrapped) →
     regenerate once; still no clean token → treat as `changes-requested`; if
     there are also no actionable items, use the existing garbage→retry→
     unavailable path (Errors section).

2. **User-input check (unchanged)** — a "this is a user decision" flag outranks
   the verdict and routes to the user (interactive) or a `design-input-needed`
   issue (autonomous).

3. **Address blocking items.** Edit the artifact to resolve ONLY the actionable
   blocking items Codex listed, plus any `Non-blocking notes:` raised this round
   (fixed alongside, re-reviewed for free). At `plan-review`, still flag changes
   contradicting the approved design as drift. Loop back to the Codex async CLI
   call for the next verdict.
```

**Step 2: Delete the stale fuzzy-convergence wording.** Ensure the old "looks good / approved / no further concerns" string-scan at l. 433 is gone (replaced by the verdict parse above).

**Step 3: Verify.**
```bash
grep -n "final non-empty line\|VERDICT: approved\|Non-blocking notes" skills/codex-plan-review/SKILL.md
grep -n "looks good" skills/codex-plan-review/SKILL.md
```
Expected: verdict routing present; no remaining `looks good` convergence scan (the only matches, if any, are inside the priming's brainstorm bullet — confirm none are in the plan/design routing).

**Step 4: Commit.**
```bash
git add skills/codex-plan-review/SKILL.md
git commit -m "feat(plan-review): verdict-driven routing; fix-before-moving-on minors"
```

---

### Task 5: Update `codex-impl-review` routing (verdict parse + §3b subagent-first + approval condition)

**Files:**
- Modify: `skills/codex-impl-review/SKILL.md:489` (convergence → verdict parse), `:527-535` (§3b), `:552-554` (approval condition)

**Step 1: Convergence → verdict parse.** Replace item 1's trigger (`**Convergence signal** ("looks good", …)`) with:
```markdown
1. **Parse the verdict from the final non-empty line** (exact literal, per the
   verdict contract; ignore earlier occurrences). `[VERDICT: approved]` →
   APPROVAL: write `state.impl_review_approved_sha = <git HEAD sha>` (no
   frontmatter — impl-review has none), post "Codex approved impl-review after
   N rounds.", exit loop. A non-literal final line → regenerate once, then treat
   as `changes-requested`.
```
Keep the existing approval bookkeeping bullets (no `codex_impl_review_status`, etc.).

**Step 2: Rewrite §3b** (the budget gate) to subagent-first:
```markdown
   **3b. Non-blocking minor (code-only — UI/UX minor was caught by the entry check above):**
   - **Trivial + comfortable context** (small scope AND the main session has
     room) → inline fix.
   - **Otherwise → subagent fix.** The default. A subagent fixes in its own
     context window, so large `scope` (lots to load) and high `pct` (loaded main
     session) are reasons to *dispatch a subagent*, NOT to defer. Group by
     `cluster`; one subagent per cluster.
   - **Defer to an `autonomous-safe` issue ONLY when the fix is not cleanly
     subagent-dispatchable** — it needs cross-cutting / multi-file work, or is
     large/risky enough to deserve its own reviewed PR. (Design-judgment cases
     already routed to `design-input-needed` via the entry check above.)

   The context-budget probe still informs the **inline-vs-subagent** choice
   (high `pct` → prefer subagent); `pct` and `scope` no longer trigger deferral
   on their own.
```

**Step 3: Update the approval-condition note** (l. 552-554) so MINOR routing matches §3b (subagent/inline by default; deferral the exception). Keep "approve OR all CRITICAL/IMPORTANT fixed; MINOR does not block."

**Step 4: Verify.**
```bash
grep -n "subagent-dispatchable\|prefer subagent\|VERDICT: approved" skills/codex-impl-review/SKILL.md
grep -n "batch-defer to an .autonomous-safe. issue" skills/codex-impl-review/SKILL.md
```
Expected: subagent-first §3b present; the old `pct >= 85% / scope==large → defer` catch-all gone.

**Step 5: Commit.**
```bash
git add skills/codex-impl-review/SKILL.md
git commit -m "feat(impl-review): verdict parse; subagent-first minor routing"
```

---

### Task 6: Autonomous non-convergence safety valve (N=6)

A per-chain round counter halts an autonomous run that will not converge.

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md` (state writer contract, duplicate-in-flight guard, Step 3, routing cap)
- Modify: `skills/codex-impl-review/SKILL.md` (same four touchpoints)
- Modify: `commands/cross-model-reset.md` (default-state YAML) and the other state-writing commands (`cross-model-autonomous-on/off.md`, `cross-model-skip.md`, `cross-model-review-now.md`) — propagate the field.

**Step 1: Add the state field.** In each skill's state-writer contract, every fresh state write also emits `review_round_count: 0`; updates preserve it. Propagate the same into the state-writing commands (reset's default-state YAML; the `Preserve … verbatim` instructions and fresh-create snippets in autonomous-on/off, skip, review-now).

**Step 2: Reset at fresh-loop start.** In the Duplicate-in-flight guard (end of Chain update), when NO in-flight entry exists for this chain (a fresh review loop is beginning), set `state.review_round_count = 0`. Do NOT gate on `chain_just_changed` — impl-review never changes the chain, so a chain-change gate would never fire for it. Mid-loop rounds (2+) re-enter via On-bg-completion and bypass this guard, so the reset fires exactly once per loop.

**Step 3: Increment per round.** In the Codex async CLI call Step 3 (pre-write state slot), increment `state.review_round_count` by 1 on every launch.

**Step 4: Halt check.** In the routing, on a `changes-requested` verdict: if **autonomous mode** AND `state.review_round_count >= 6` → do NOT loop; write a halt note (existing autonomous halt mechanism — `.claude/cross-model-review/halts/<chain-stem>.md` for regime=new), set `state.chain_status = halted`, post a chat note naming non-convergence, fire notification. **Interactive mode is uncapped.** No separate reset-on-approval is needed: the fresh-loop reset (Step 2) zeroes the counter at the next loop, and On-bg-completion removes the in-flight slot before the halt, so a re-invocation after a halt finds no in-flight entry and resets.

**Step 5: Verify.**
```bash
grep -n "review_round_count" skills/codex-plan-review/SKILL.md skills/codex-impl-review/SKILL.md
```
Expected: field appears in the writer contract, reset, increment, and halt-check in both skills.

**Step 6: Commit.**
```bash
git add skills/codex-plan-review/SKILL.md skills/codex-impl-review/SKILL.md
git commit -m "feat(review): N=6 autonomous non-convergence safety valve"
```

---

### Task 7: Docs — MANIFEST, CHANGELOG, version bump

**Files:**
- Modify: `MANIFEST.md:61` (refined lockstep note)
- Modify: `CHANGELOG.md` (new entry)
- Modify: `.claude-plugin/plugin.json` (version)

**Step 1: MANIFEST lockstep note.** Update the "Priming string and launch block are lockstep-duplicated…" relationship to record the three-tier discipline from design §7: universal priming byte-identical across all three; verdict-contract block identical across the two review skills; depth header mode-specific (not lockstep).

**Step 2: CHANGELOG.** Add an entry (next minor version, e.g. `0.4.0`) summarizing: per-round verdict gate, per-mode depth calibration, fix-before-moving-on minors, impl-review subagent-first minor routing, N=6 safety valve. Reference the regression it fixes.

**Step 3: Version bump** in `.claude-plugin/plugin.json` to match the CHANGELOG (`0.4.0`).

**Step 4: Verify.**
```bash
grep -n "verdict-contract block\|depth header" MANIFEST.md
grep -n "0.4.0" CHANGELOG.md .claude-plugin/plugin.json
```

**Step 5: Commit.**
```bash
git add MANIFEST.md CHANGELOG.md .claude-plugin/plugin.json
git commit -m "docs: v0.4.0 changelog, version bump, MANIFEST lockstep note"
```

---

### Task 8: Final lockstep verification + dogfood

**Step 1: Re-verify all lockstep blocks.**
```bash
# Priming identical across three:
for f in codex-plan-review codex-impl-review codex-brainstorm-partner; do
  awk '/^## / { if (b) exit; if ($0 ~ /Universal Codex priming/) b=1 } b {print}' "skills/$f/SKILL.md" > "/tmp/p-$f.txt"
done
diff /tmp/p-codex-plan-review.txt /tmp/p-codex-impl-review.txt && \
diff /tmp/p-codex-plan-review.txt /tmp/p-codex-brainstorm-partner.txt && echo "PRIMING OK"
```
Manually diff the verdict-contract block between `codex-plan-review` and `codex-impl-review` (must be byte-identical).

**Step 2: Confirm brainstorm-partner is behaviorally unchanged** — it has the priming edit only; no verdict contract, no depth header, no round counter:
```bash
grep -n "VERDICT\|depth-header\|review_round_count" skills/codex-brainstorm-partner/SKILL.md
```
Expected: no matches.

**Step 3: Dogfood.** Run this very plan through the NEW `plan-review` (a manual `/cross-model-review-now plan docs/plans/2026-06-01-codex-review-convergence-plan.md`, or the natural trigger). Confirm: it converges in a small number of rounds and ends with a clean `[VERDICT: approved]`; the per-turn prompt carried the deep plan-review depth header. Capture the round count in the PR description.

**Step 4: Open the PR.**
```bash
gh pr create --title "feat: verdict-gated, depth-calibrated Codex reviews (v0.4.0)" --body "<summary + dogfood round count + design/plan links>"
```

---

## Appendix A — canonical priming bullet (paste verbatim in Task 1)

```
2. Design / plan / diff review: Claude sends you a design doc, plan
   document, or code diff for adversarial review. Find bugs, missing edge
   cases, ambiguous specifications, design flaws, plan deviations, or
   claims that don't match the actual repo. You have read-only access to
   the working directory. The depth and focus expected of you — and whether
   to cite specific file paths and line numbers — depend on the mode and are
   specified in each per-turn prompt; follow those instructions. Be specific
   and avoid generic praise. Each review turn ends with a single
   machine-parseable verdict line per the per-turn prompt's instructions.
```

(Everything from `When returning findings, start each finding with a parseable tag line…` onward is unchanged.)

## Appendix B — canonical verdict-contract block (paste verbatim in Tasks 2 & 3)

```
End your review with a verdict on its own line, as the final non-empty line of
your response, exactly one of:
  [VERDICT: approved]
  [VERDICT: changes-requested]

- approved = no blocking (critical or important) concerns remain.
- changes-requested = at least one blocking concern. List ONLY the blocking
  items, each as a concrete, actionable change Claude can make to earn approval
  next round (with the [severity:…, scope:…, cluster:…] tag-line). Put any
  non-blocking observations under a separate "Non-blocking notes:" heading;
  they do NOT affect the verdict.

Emit the token exactly once, unwrapped (no code block or bullet), spelled
literally, with nothing after it. Decide the verdict at the end from your
settled judgment.
```
