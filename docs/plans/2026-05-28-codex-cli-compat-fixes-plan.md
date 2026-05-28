# Codex CLI 0.125.0 Compatibility Fixes — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the broken `codex exec resume` invocation (#4) and fold in two adjacent Windows-surfaced issues (#5 priming nudge, #6 stale-thread misclassification) across the three review skills, shipping as v0.3.1.

**Architecture:** Markdown-only Claude Code plugin — no runtime code, no test harness. "Tests" are structural: `grep`/`diff` to confirm byte-identical edits stayed in lockstep, plus one live `codex exec resume` integration check for #4. Edits are grouped into one commit per issue so the branch tells a reviewable story.

**Tech Stack:** Markdown skill bodies; Codex CLI 0.125.0; Git Bash on Windows.

**Source design:** `docs/plans/2026-05-28-codex-cli-compat-fixes-design.md` (committed `bc8898d`). Section numbers below reference it.

---

## Preflight: branch

The design doc is already committed to `main`. Create a feature branch for the implementation:

```bash
git switch -c fix/codex-cli-0125-compat
```

All task commits land on this branch; PR at the end.

**Note — correction to design §7.1:** the on-bg-completion handler is **not** byte-identical between `codex-plan-review` and `codex-impl-review` (they differ in the stale-thread chat-note wording and a parenthetical). Treat #6 as three per-skill adapted edits, not one shared block. The **launch block** (#4) and **priming string** (#5) *are* byte-identical across all three skills.

---

## Task 1: #4 — Resume invocation fix (all 3 skills)

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md:315`
- Modify: `skills/codex-impl-review/SKILL.md:317`
- Modify: `skills/codex-brainstorm-partner/SKILL.md:203`

**Step 1: Confirm the target block is byte-identical across all three**

Run:
```bash
grep -n "codex exec resume <attempted_thread_id> --sandbox read-only -C" \
  skills/codex-plan-review/SKILL.md \
  skills/codex-impl-review/SKILL.md \
  skills/codex-brainstorm-partner/SKILL.md
```
Expected: exactly one match per file (3 total), identical text.

**Step 2: Apply the same edit to each of the three files**

In each file, replace this exact block:

````text
**Continuation** (attempted_thread_id set):
```bash
codex exec resume <attempted_thread_id> --sandbox read-only -C <project-toplevel> --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```
````

with:

````text
**Continuation** (attempted_thread_id set):
```bash
cd <project-toplevel> && codex exec resume <attempted_thread_id> -c sandbox_mode="read-only" --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

> **cwd invariant (do not "simplify" away):** the leading `cd` is load-bearing.
> Codex records and filters sessions by cwd; the fresh-thread call above mints
> the thread from `<project-toplevel>` via `-C`, so resuming from that same
> directory is how Codex locates the session. Do not drop the `cd`, and do not
> add `--all` (which would disable cwd filtering). The fresh path keeps the
> first-class `--sandbox`/`-C` flags deliberately — they fail loud if the CLI
> changes again, whereas `-c sandbox_mode=` fails silent. (Design §4.2–4.3.)
````

The fresh-thread block immediately above it is **unchanged**.

**Step 3: Verify the edit landed identically in all three**

Run:
```bash
grep -n 'cd <project-toplevel> && codex exec resume <attempted_thread_id> -c sandbox_mode="read-only"' \
  skills/codex-plan-review/SKILL.md \
  skills/codex-impl-review/SKILL.md \
  skills/codex-brainstorm-partner/SKILL.md
grep -rn "resume <attempted_thread_id> --sandbox" skills/ || echo "OK: no old resume invocation remains"
```
Expected: 3 matches for the new line; "OK: no old resume invocation remains".

**Step 4: Confirm the fresh path was NOT touched**

Run:
```bash
grep -c "codex exec --sandbox read-only -C <project-toplevel> --json" \
  skills/codex-plan-review/SKILL.md \
  skills/codex-impl-review/SKILL.md \
  skills/codex-brainstorm-partner/SKILL.md
```
Expected: `1` for each file (the fresh block survives intact).

**Step 5: Commit**

```bash
git add skills/codex-plan-review/SKILL.md skills/codex-impl-review/SKILL.md skills/codex-brainstorm-partner/SKILL.md
git commit -m "fix(#4): use cd + -c sandbox_mode on codex exec resume (0.125.0 dropped --sandbox/-C)"
```

---

## Task 2: #5 — Re-scoped priming nudge (all 3 skills)

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md:50`
- Modify: `skills/codex-impl-review/SKILL.md:49`
- Modify: `skills/codex-brainstorm-partner/SKILL.md:39`

**Step 1: Confirm the anchor line is present once per file**

Run:
```bash
grep -n "Adapt to the tagged mode immediately. The tag is authoritative." \
  skills/codex-plan-review/SKILL.md \
  skills/codex-impl-review/SKILL.md \
  skills/codex-brainstorm-partner/SKILL.md
```
Expected: exactly one match per file.

**Step 2: Apply the same insertion to each of the three files**

Replace this exact line:

```text
Adapt to the tagged mode immediately. The tag is authoritative.
```

with:

```text
Adapt to the tagged mode immediately. The tag is authoritative.

Tool use on Windows: prefer your built-in file-reading capability over shell
commands when inspecting the repo. On Windows your shell invocations — including
`bash` and `rg` — get wrapped in `powershell.exe`, which the sandbox blocks, so
shell-based grep/read attempts will fail. Read files directly instead. (Harmless
on non-Windows hosts, where the shell works normally.)
```

This stays inside the fenced universal-priming block, so it ships verbatim to Codex.

**Step 3: Verify identical insertion across all three**

Run:
```bash
grep -c "prefer your built-in file-reading capability" \
  skills/codex-plan-review/SKILL.md \
  skills/codex-impl-review/SKILL.md \
  skills/codex-brainstorm-partner/SKILL.md
```
Expected: `1` for each file.

**Step 4: Lockstep diff of the priming blocks**

Extract each skill's priming block (the fenced block under "## Universal Codex priming") and diff them pairwise to confirm they remain byte-identical:
```bash
# crude but sufficient: compare the priming region between the two reviewers
diff <(sed -n '/^## Universal Codex priming/,/^## Bootstrap/p' skills/codex-plan-review/SKILL.md) \
     <(sed -n '/^## Universal Codex priming/,/^## Bootstrap/p' skills/codex-impl-review/SKILL.md) \
  && echo "OK: plan/impl priming identical"
```
Expected: "OK: plan/impl priming identical" (brainstorm-partner's surrounding section headers differ, so eyeball that the inserted paragraph matches there).

**Step 5: Commit**

```bash
git add skills/codex-plan-review/SKILL.md skills/codex-impl-review/SKILL.md skills/codex-brainstorm-partner/SKILL.md
git commit -m "fix(#5): nudge Codex to direct file reads over powershell-wrapped shell on Windows"
```

---

## Task 3: #6 — Stale-thread matcher reorder (all 3 skills, per-skill adapted)

Decide success by positive result evidence **first**; scan stderr for stale-thread markers **only** when the result is empty/corrupt; treat a co-occurring `failed to record rollout items` as a soft warning, not a failure. No new status, no new state field. (Design §6.)

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md:363-364`
- Modify: `skills/codex-impl-review/SKILL.md:418-419`
- Modify: `skills/codex-brainstorm-partner/SKILL.md:229-230`

**Step 1 (plan-review): replace step 5 + step-6 head**

Replace exactly:

```text
5. **Check for stale-thread error (best-effort).** Scan `result_file`, `jsonl_file`, and `stderr_file` via allowlisted substring matching for patterns Codex emits when `codex exec resume` fails — currently observed: `"Session not found for thread_id"` and `"thread not found"`. (The Codex CLI does not document a stable machine-readable error contract for this case as of v0.125.0; treat as a fuzzy signal subject to drift.) If detected, post chat note *"Codex thread `<attempted_thread_id>` has expired. Start a fresh review with `/cross-model-review-now <kind>` (the plugin will create a new thread)."* Set slot's `status: "stale_thread_error"` so `/cross-model-status` can explain. Do NOT auto-recover in v0.3.0. If neither pattern matches but the result is still empty/corrupt, fall through to generic failure handling rather than asserting stale-thread.
6. **Read `result_file`** — Codex's final structured review.
```

with:

```text
5. **Classify the outcome by positive evidence first.** Read `result_file`.
   - **If `result_file` is non-empty and parseable as findings → treat as SUCCESS,** regardless of any stderr substrings. Additionally, if `stderr_file` contains `"failed to record rollout items"`, post a soft chat note: *"Codex emitted a rollout-recording error during this review (`failed to record rollout items`). The findings are complete, but this Codex thread's last turn may not have been persisted, so a later resume of it could be degraded."* Take NO state action. Proceed to step 6.
   - **Only if `result_file` is empty or unparseable as findings:** scan `result_file`, `jsonl_file`, and `stderr_file` via allowlisted substring matching for stale-thread patterns Codex emits when `codex exec resume` fails — currently observed: `"Session not found for thread_id"` and `"thread not found"`. (The Codex CLI does not document a stable machine-readable error contract for this case as of v0.125.0; treat as a fuzzy signal subject to drift.) If detected, post chat note *"Codex thread `<attempted_thread_id>` has expired. Start a fresh review with `/cross-model-review-now <kind>` (the plugin will create a new thread)."* Set slot's `status: "stale_thread_error"` so `/cross-model-status` can explain. Do NOT auto-recover in v0.3.0. If no stale-thread pattern matches either, fall through to generic failure handling.
6. **Read `result_file`** — Codex's final structured review. (On the success path it was already read in step 5; this step parses/uses that content.)
```

**Step 2 (impl-review): replace step 5 + step-6 head**

Replace exactly:

```text
5. **Check for stale-thread error (best-effort).** Scan `result_file`, `jsonl_file`, and `stderr_file` via allowlisted substring matching for patterns Codex emits when `codex exec resume` fails — currently observed: `"Session not found for thread_id"` and `"thread not found"`. (Treat as fuzzy signal subject to drift across Codex releases.) If detected, post chat note *"Codex thread `<attempted_thread_id>` has expired. Start a fresh review with `/cross-model-review-now impl` (the plugin will create a new thread)."* Set slot's `status: "stale_thread_error"`. Do NOT auto-recover in v0.3.0. If neither pattern matches but result is empty/corrupt, fall through to generic failure handling.
6. **Read `result_file`** — Codex's final structured review.
```

with:

```text
5. **Classify the outcome by positive evidence first.** Read `result_file`.
   - **If `result_file` is non-empty and parseable as findings → treat as SUCCESS,** regardless of any stderr substrings. Additionally, if `stderr_file` contains `"failed to record rollout items"`, post a soft chat note: *"Codex emitted a rollout-recording error during this review (`failed to record rollout items`). The findings are complete, but this Codex thread's last turn may not have been persisted, so a later resume of it could be degraded."* Take NO state action. Proceed to step 6.
   - **Only if `result_file` is empty or unparseable as findings:** scan `result_file`, `jsonl_file`, and `stderr_file` via allowlisted substring matching for stale-thread patterns Codex emits when `codex exec resume` fails — currently observed: `"Session not found for thread_id"` and `"thread not found"`. (Treat as fuzzy signal subject to drift across Codex releases.) If detected, post chat note *"Codex thread `<attempted_thread_id>` has expired. Start a fresh review with `/cross-model-review-now impl` (the plugin will create a new thread)."* Set slot's `status: "stale_thread_error"`. Do NOT auto-recover in v0.3.0. If no stale-thread pattern matches either, fall through to generic failure handling.
6. **Read `result_file`** — Codex's final structured review. (On the success path it was already read in step 5; this step parses/uses that content.)
```

**Step 3 (brainstorm-partner): replace step 5 + step-6 head (shorter variant)**

Replace exactly:

```text
5. **Check for stale-thread error (best-effort).** Scan `result_file`, `jsonl_file`, `stderr_file` for `"Session not found for thread_id"` / `"thread not found"`. If detected, post chat note *"Codex thread `<attempted_thread_id>` has expired. Brainstorming continues with Claude only for this question."* Set slot's `status: "stale_thread_error"`. Remove the slot. Do NOT auto-recover.
6. **Read `result_file`** — Codex's reply, formatted as if it were the user's response.
```

with:

```text
5. **Classify the outcome by positive evidence first.** Read `result_file`.
   - **If `result_file` is non-empty and usable as a reply → treat as SUCCESS,** regardless of any stderr substrings. If `stderr_file` also contains `"failed to record rollout items"`, post a soft chat note: *"Codex emitted a rollout-recording error during this turn; its reply is complete, but a later resume of this thread could be degraded."* Take NO state action. Proceed to step 6.
   - **Only if `result_file` is empty or unusable:** scan `result_file`, `jsonl_file`, `stderr_file` for `"Session not found for thread_id"` / `"thread not found"`. If detected, post chat note *"Codex thread `<attempted_thread_id>` has expired. Brainstorming continues with Claude only for this question."* Set slot's `status: "stale_thread_error"`, remove the slot, and continue with Claude only. Do NOT auto-recover.
6. **Read `result_file`** — Codex's reply, formatted as if it were the user's response.
```

**Step 4: Verify the reorder landed and nothing references a force-fresh flag or new status**

Run:
```bash
grep -rn "Classify the outcome by positive evidence first" skills/   # expect 3
grep -rn "failed to record rollout items" skills/                    # expect 3
grep -rn "force_fresh_thread_next_call\|rollout_recording_failed" skills/ commands/ \
  || echo "OK: no dropped-mechanism references introduced"
```
Expected: 3, 3, and "OK: no dropped-mechanism references introduced".

**Step 5: Commit**

```bash
git add skills/codex-plan-review/SKILL.md skills/codex-impl-review/SKILL.md skills/codex-brainstorm-partner/SKILL.md
git commit -m "fix(#6): decide review success by result first, scan stale-thread only on empty result"
```

---

## Task 4: Docs + version bump

**Files:**
- Modify: `.claude-plugin/plugin.json:3`
- Modify: `CHANGELOG.md:7` (insert new section before `## 0.3.0`)
- Modify: `README.md:5`
- Modify: `MANIFEST.md:6` and Key Relationships

**Step 1: Bump plugin version**

In `.claude-plugin/plugin.json` replace `"version": "0.3.0",` with `"version": "0.3.1",`.

**Step 2: README status line**

In `README.md` replace `**Status:** v0.3.0` with `**Status:** v0.3.1`. Do **NOT** add a "Tested with 0.125.0" line — the existing `Codex CLI ≥ 0.125.0` requirement at `README.md:59` already covers it (design §7.2 / finding 9). Leave line 59 as-is.

**Step 3: CHANGELOG entry**

Insert immediately before the `## 0.3.0 — 2026-05-12` line:

```text
## 0.3.1 — 2026-05-28

### Fixed
- **#4 — `codex exec resume` invocation updated for Codex CLI 0.125.0.** The `resume` subcommand dropped `--sandbox` and `-C`; the continuation path now does `cd <project-toplevel> && codex exec resume <id> -c sandbox_mode="read-only" ...`. The fresh-thread path keeps the first-class `--sandbox`/`-C` flags (they fail loud if the CLI shifts again). Round 2+ of review chains works again.
- **#6 — rollout-recording errors no longer misclassified as expired threads.** The on-bg-completion handler now decides success by positive result evidence first; the stale-thread substring scan runs only when the result is empty/corrupt. A co-occurring `failed to record rollout items` surfaces a soft warning instead of a false "thread expired". Supersedes the caveat noted in 0.3.0 about best-effort substring matching producing false positives.

### Changed
- **#5 — universal priming nudges Codex toward direct file reads on Windows.** On Windows, Codex wraps shell calls (including `bash`/`rg`) in `powershell.exe`, which its sandbox blocks; the priming now steers it to its built-in file reading. Best-effort — the root cause is upstream in the Codex CLI.

### Notes
- The cwd invariant for `codex exec resume` (must `cd` to the same toplevel the fresh call used with `-C`) is documented inline in the three skill bodies.
```

**Step 4: MANIFEST notes**

In `MANIFEST.md`, update the Stack line (line 6) to note the flag distinction:

Replace:
```text
- Targets Codex CLI (`codex exec` / `codex exec resume` via Bash `run_in_background: true`); MCP-based invocation retired in v0.3.0
```
with:
```text
- Targets Codex CLI (`codex exec` / `codex exec resume` via Bash `run_in_background: true`); MCP-based invocation retired in v0.3.0. Fresh calls use `--sandbox read-only -C <top>`; resume calls (0.125.0 dropped those flags) use `cd <top> && ... -c sandbox_mode="read-only"`.
```

Add to the Key Relationships section a note extending the lockstep-duplication discipline (design §7.1):
```text
- **Priming string and launch block are lockstep-duplicated across all three review skills** (`codex-plan-review`, `codex-impl-review`, `codex-brainstorm-partner`) and must be edited together and verified by `diff` — same discipline as the issue-filing helper. The on-bg-completion handler is parallel-but-not-identical across the three (plan/impl differ in chat-note wording; brainstorm-partner is a shorter variant), so handler edits are applied per-skill.
```

**Step 5: Commit**

```bash
git add .claude-plugin/plugin.json CHANGELOG.md README.md MANIFEST.md
git commit -m "docs: v0.3.1 changelog, version bump, README/MANIFEST reconciliation"
```

---

## Task 5: Live integration check for #4 (the real regression test)

This is the one behavioral check. It costs ~2 short Codex calls. Run from the repo root in Git Bash.

**Step 1: Mint a throwaway fresh thread and capture its thread_id**

Use stdin redirection from a prompt file (the plugin's own pattern), not a pipe into `cd`:

```bash
TOP="C:/Users/tim/OneDrive/Documents/Projects/cross-model-review"
printf 'Reply with only the word READY.\n' > /tmp/cmr-test-fresh-prompt.txt
codex exec --sandbox read-only -C "$TOP" --json \
  -o /tmp/cmr-test-fresh-result.txt \
  < /tmp/cmr-test-fresh-prompt.txt \
  > /tmp/cmr-test-fresh-events.jsonl 2> /tmp/cmr-test-fresh-stderr.txt
grep -o '"thread_id":"[^"]*"' /tmp/cmr-test-fresh-events.jsonl | head -1   # from the thread.started event
```
Expected: a `thread.started` event carrying a thread_id. Copy it.

**Step 2: Resume that thread with the NEW invocation and probe the sandbox**

```bash
TID="<thread_id from step 1>"
rm -f /tmp/cmr-codex-write-probe.txt
printf 'Create a file at /tmp/cmr-codex-write-probe.txt containing the word HELLO, then tell me whether the write succeeded or was blocked.\n' > /tmp/cmr-test-resume-prompt.txt
cd "$TOP" && codex exec resume "$TID" -c sandbox_mode="read-only" --json \
  -o /tmp/cmr-test-resume-result.txt \
  < /tmp/cmr-test-resume-prompt.txt \
  > /tmp/cmr-test-resume-events.jsonl 2> /tmp/cmr-test-resume-stderr.txt
```

**Step 3: Verify (a) no flag rejection, (b) sandbox held**

```bash
grep -i "unexpected argument" /tmp/cmr-test-resume-stderr.txt && echo "FAIL: flag rejected" || echo "OK: resume launched, no flag rejection"
test -f /tmp/cmr-codex-write-probe.txt && echo "FAIL: sandbox did NOT hold (file created)" || echo "OK: write refused, read-only sandbox held"
cat /tmp/cmr-test-resume-result.txt
```
Expected: "OK: resume launched, no flag rejection" AND "OK: write refused, read-only sandbox held". The result text should report the write was blocked.

**Step 4: Clean up temp files**

```bash
rm -f /tmp/cmr-test-* /tmp/cmr-codex-write-probe.txt
```

If step 3 fails on the sandbox check, STOP — `-c sandbox_mode="read-only"` is not enforcing read-only on resume, and #4 needs rework (revisit design §4.1). Do not open the PR.

---

## Task 6: Final lockstep sweep, MANIFEST check, and PR

**Step 1: Full lockstep sweep**

```bash
grep -rn "resume <attempted_thread_id> --sandbox" skills/ || echo "OK #4: no old resume invocation"
grep -c 'cd <project-toplevel> && codex exec resume' skills/codex-*/SKILL.md skills/codex-brainstorm-partner/SKILL.md
grep -c "prefer your built-in file-reading capability" skills/codex-*/SKILL.md skills/codex-brainstorm-partner/SKILL.md
grep -rc "Classify the outcome by positive evidence first" skills/
```
Expected: clean #4 message; `1` per file for the new resume line and the #5 nudge; `1` per skill for the #6 reorder.

**Step 2: Confirm MANIFEST structure still accurate**

No files were added or removed, so the MANIFEST Structure tree is unchanged. Confirm the Stack line and the new Key-Relationships note from Task 4 are present.

**Step 3: Push and open the PR**

```bash
git push -u origin fix/codex-cli-0125-compat
gh pr create --title "Codex CLI 0.125.0 compat fixes (#4, #5, #6)" --body "$(cat <<'BODY'
## Summary
- **#4**: `codex exec resume` no longer accepts `--sandbox`/`-C` in Codex CLI 0.125.0. Continuation path now uses `cd <top> && ... -c sandbox_mode="read-only"`; fresh path unchanged. Round 2+ of review chains works again.
- **#5**: priming nudge steering Codex to direct file reads over powershell-wrapped shell on Windows (best-effort; root cause is upstream).
- **#6**: on-bg handler decides success by result-first, scans stale-thread markers only on empty/corrupt result — fixes the rollout-error false positive.

Design: `docs/plans/2026-05-28-codex-cli-compat-fixes-design.md`. Plan: `docs/plans/2026-05-28-codex-cli-compat-fixes-plan.md`. Design was informed by an ad-hoc Codex consult that live-reproduced #5 and #6.

## Test plan
- [ ] Lockstep grep sweep (Task 6 step 1) passes
- [ ] Live `codex exec resume -c sandbox_mode="read-only"` check: launches without flag rejection AND read-only sandbox holds (Task 5)
- [ ] #6 reorder reviewed against design §6.1 decision tree
BODY
)"
```

**Step 4: Link issues**

After the PR is created, comment on #4/#5/#6 linking the PR, and note in #5 that the priming nudge is a partial/best-effort fix and the upstream Codex powershell-wrapping behavior remains the root cause (so #5 stays open for the upstream angle per design §9).

---

## Notes on what was deliberately NOT built

Per the Codex consult (design §6.2): no `force_fresh_thread_next_call` state field, no `rollout_recording_failed` slot status, no `/cross-model-status` enum change. These were in an earlier #6 draft but are buggy-as-specified and low-value (fresh threads also hit the rollout error). Do not add them.
