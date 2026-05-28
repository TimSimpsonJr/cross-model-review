---
codex_thread_id: null
codex_design_review_status: informal-consult
codex_design_review_note: "Ad-hoc Codex consult (thread 019e6f99-81d9-7e31-bea1-7f11c83c6ab1) informed this design; that thread hit a rollout-recording error mid-run and is treated as compromised, so codex_thread_id is left null to keep bootstrap from resuming it. No formal design-review gate was run."
---

# Codex CLI 0.125.0 Compatibility Fixes — Design Document

**Status:** Brainstorm complete; informed by an ad-hoc Codex consult.
**Date:** 2026-05-28
**Type:** Bug fixes + minor hardening to `cross-model-review` v0.3.0
**Target version:** v0.3.1
**Issues addressed:** [#4](https://github.com/TimSimpsonJr/cross-model-review/issues/4), [#5](https://github.com/TimSimpsonJr/cross-model-review/issues/5), [#6](https://github.com/TimSimpsonJr/cross-model-review/issues/6)

---

## 1. Goal

The Codex CLI updated to 0.125.0 and changed its subcommand flag shape: `codex exec resume` no longer accepts `--sandbox` or `-C/--cd` (both remain valid on the parent `codex exec`). This breaks the continuation path (round 2+) of every review chain — the plugin's resume invocation is rejected with `error: unexpected argument '--sandbox' found`. The fresh-thread path is unaffected.

Fix the resume invocation, and fold in two adjacent Windows-surfaced issues that live in the same skill files (#5, #6). Ship as v0.3.1.

## 2. Background — the three issues

All three were filed from a single flight-deck review session on Windows (Codex CLI 0.125.0) and all touch the three review skill bodies (`codex-plan-review`, `codex-impl-review`, `codex-brainstorm-partner`).

- **#4 (CLI shape change):** `codex exec resume <id> --sandbox read-only -C <top> ...` is rejected. Confirmed against the installed 0.125.0 binary via `codex exec resume --help`: `resume` exposes `-c, --config <key=value>` but not `--sandbox`/`-C`. The parent `codex exec` still has `-s, --sandbox <read-only|workspace-write|danger-full-access>` and `-C, --cd <DIR>`.
- **#5 (PowerShell sandbox rejections on Windows):** Codex's Windows shell tool wraps shell calls in `powershell.exe -Command "..."`, and Codex's own sandbox policy blocks `powershell.exe`, producing `rejected: blocked by policy`. Reviews still complete because Codex falls back to direct file reads, but the blocked attempts waste latency.
- **#6 (rollout-recording error misclassified as stale thread):** Codex can emit `failed to record rollout items: thread <id> not found` mid-run while the review *succeeds*. The skill's stale-thread detector scans stderr for the substring `"thread not found"`, so a successful review substring-matches the stale-thread pattern — a false positive.

### 2.1 Dogfooding evidence (this design's own Codex consult)

The ad-hoc Codex consult run for this design (a fresh `codex exec` call) reproduced **both** #5 and #6 live, and the evidence reshaped the #5 and #6 fixes:

- **#5:** ~10 `rejected: blocked by policy` lines. Codex wrapped not just `Select-String`/`Get-Content` but also `bash -lc '...'` and `rg -n ...` inside `powershell.exe -Command`, all blocked. **Implication:** a priming nudge toward "prefer bash/rg" does not help — bash/rg are themselves wrapped in `powershell.exe`. The effective lever is to push Codex toward its built-in file reading and away from the shell tool on Windows.
- **#6:** `failed to record rollout items: thread 019e6f99-81d9-7e31-bea1-7f11c83c6ab1 not found` fired on the **brand-new thread minted by that very run** (~9 minutes old), and the review still returned a complete result. **Implication:** the rollout error is not a long-lived-thread phenomenon (as #6 hypothesized), so a "force a fresh thread next time" mitigation would not prevent recurrence. The real bug is purely the misclassification.

## 3. Design summary

Three changes plus docs, all scoped to v0.3.1:

1. **#4 — Resume invocation fix.** Drop `--sandbox`/`-C` from the `resume` continuation; `cd` to the project toplevel and pin the sandbox via the config override `-c sandbox_mode="read-only"`. Fresh path unchanged.
2. **#5 — Re-scoped priming nudge.** One line in the universal priming string steering Codex to read files directly rather than via the shell tool on Windows.
3. **#6 — Stale-thread matcher reorder.** Decide review success by positive evidence (non-empty, parseable result) *first*; only scan stderr for stale-thread markers when the result is empty/corrupt. Drop the `rollout_recording_failed` status, the `/cross-model-status` enum change, and the `force_fresh_thread_next_call` flag that an earlier draft proposed.
4. **Docs/version.** Bump to v0.3.1; CHANGELOG entry; reconcile the existing README `≥ 0.125.0` requirement; MANIFEST notes (cwd invariant + lockstep duplication).

## 4. #4 — Resume invocation fix

### 4.1 The change

In each of the three skills' **Step 4: Launch** block, the **Fresh thread** path is unchanged:

```bash
codex exec --sandbox read-only -C <project-toplevel> --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

The **Continuation** path changes from:

```bash
codex exec resume <attempted_thread_id> --sandbox read-only -C <project-toplevel> --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

to:

```bash
cd <project-toplevel> && codex exec resume <attempted_thread_id> -c sandbox_mode="read-only" --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

- `-c sandbox_mode="read-only"` replicates `--sandbox read-only` through the TOML config-override mechanism. `sandbox_mode` is the config.toml key the `--sandbox` flag maps to; values match (`read-only`/`workspace-write`/`danger-full-access`). This was validated in the Codex consult (finding 6) against the OpenAI Codex prompting guide and the installed binary's `-c` help text.
- `cd <project-toplevel>` replaces `-C`.

### 4.2 Why the fresh path stays on first-class flags

The fresh path keeps `--sandbox`/`-C` because they are first-class flags that fail *loud* (a hard CLI error) if Codex changes them again — early warning. The config-override `-c sandbox_mode=...` fails *silent* (an unknown key would be ignored, falling back to the default sandbox). The resume path is forced onto the silent mechanism because the loud flags were removed from that subcommand; the fresh path is not, so it keeps the safer mechanism. Minor asymmetry between the two paths is accepted in exchange for fail-loud behavior where it is still available.

### 4.3 cwd invariant (Codex finding 4)

`cd <project-toplevel>` on resume is correct only because the fresh launch always mints the thread from the repo root (`-C <project-toplevel>`), and Codex records/filters sessions by cwd. Since every plugin-created thread is recorded under the repo root, resuming from that same root matches. We do **not** add `--all` (which disables cwd filtering) — it is unnecessary for plugin-minted threads and would broaden session matching. A one-line note documenting this invariant is added next to the resume block so a future maintainer does not "simplify" the `cd` away. (Cross-machine resume via frontmatter `codex_thread_id` is unaffected: Codex's session store is per-machine, so a migrated thread id that does not exist locally falls through to stale-thread handling regardless.)

## 5. #5 — Re-scoped priming nudge

Add one line to the universal priming string (the block sent verbatim to Codex on the fresh call; byte-identical across all three skills), placed as a general operating note near the existing read-only-access instruction. Proposed wording (impl may tighten):

> Tool use on Windows: prefer your built-in file-reading capability over shell commands when inspecting the repo. On Windows your shell invocations — including `bash` and `rg` — get wrapped in `powershell.exe`, which the sandbox blocks, so shell-based grep/read attempts will fail. Read files directly instead. (Harmless on non-Windows hosts, where the shell works normally.)

This is **best-effort**. The root cause is Codex's Windows tool-router defaulting to a `powershell.exe` wrapper plus its sandbox policy blocking it — an upstream Codex concern the priming string cannot fully control. The nudge may reduce wasted blocked attempts by steering Codex to its direct file-read path (which is how it recovers today); it is not claimed to eliminate the rejections. If a future Codex release stops wrapping shell calls in PowerShell, the line becomes a harmless no-op.

## 6. #6 — Stale-thread matcher reorder

### 6.1 The change

In the **On bg completion** handler of all three skills, reorder the success/failure decision so positive evidence is checked first:

1. Read `result_file`. If it is **non-empty and parseable as findings → treat as SUCCESS** and route findings, *regardless of any stderr substrings*. If stderr additionally contains `failed to record rollout items`, append a soft chat-note warning (this thread's last turn may not have been recorded; a future resume of this thread could be degraded) — but take **no state action**.
2. Only if `result_file` is empty or corrupt do we scan `result_file`/`jsonl_file`/`stderr_file` for the stale-thread markers (`"Session not found for thread_id"`, `"thread not found"`) and classify stale-thread vs. generic failure exactly as v0.3.0 does today.

Because the rollout-error-but-succeeded case produces a non-empty result, step 1 classifies it as success and step 2 never runs — the false positive is structurally impossible. This satisfies Codex finding 5: success is decided by positive result evidence, not by substring-match ordering.

### 6.2 What is explicitly dropped (and why)

An earlier draft of #6 proposed a `rollout_recording_failed` slot status, a `/cross-model-status` enum addition, and a persisted `state.force_fresh_thread_next_call` flag. All three are dropped:

- **`force_fresh_thread_next_call` flag** — Codex findings 1 (critical) and 2 (important): as specified it would not actually force a fresh call (a thread id can be rehydrated from artifact *frontmatter*, not just `state.codex_thread_id`; clearing the flag before a fresh `thread.started` succeeds re-arms the old id), and a repo-global flag would corrupt continuity for unrelated concurrent per-branch chains. Combined with the dogfooding evidence (fresh threads also hit the rollout error, so forcing fresh prevents nothing), the mechanism is both buggy-as-specified and low-value. Dropped per YAGNI.
- **`rollout_recording_failed` status + `/cross-model-status` enum** — Codex finding 3: completed slots are removed from `state.codex_reviews_in_progress`, and `/cross-model-status` renders only in-flight reviews, so a terminal status on a deleted slot is never observable. The user-facing signal is the soft chat-note warning at completion time; no persisted status is needed.

The thread-continuity concern (resuming a thread whose last turn was not recorded) is left to the existing stale-thread handling: if a later resume of that thread fails, v0.3.0's stale-thread path already starts fresh. The soft warning tells the user it may happen.

## 7. Cross-cutting concerns

### 7.1 Lockstep duplication (Codex finding 8)

The edits touch blocks that are duplicated across the three skill bodies with no automated guard:

- **Universal priming string** (#5) — byte-identical across all three; edit in lockstep, verify by `diff`.
- **Step 4 launch block** (#4) — byte-identical across all three; edit in lockstep, verify by `diff`.
- **On bg completion handler** (#6) — `codex-plan-review` and `codex-impl-review` are byte-identical; `codex-brainstorm-partner` is a materially shorter variant, so its #6 change is *adapted*, not copied (it feeds Codex's reply to the brainstorm flow rather than routing findings; the same positive-evidence-first reorder applies).

MANIFEST currently blesses only the issue-filing helper as verified-by-diff duplication. Add a line extending that discipline to the priming string and launch block.

### 7.2 Version and docs (Codex finding 9)

- Bump `plugin.json` 0.3.0 → **0.3.1** (bug fixes + a behavioral reorder; no new capability boundary; SemVer patch).
- CHANGELOG: new v0.3.1 section summarizing #4/#5/#6.
- README already states a `Codex CLI ≥ 0.125.0` requirement. Do **not** add a redundant "Tested with 0.125.0" line. Instead, reconcile: the resume invocation now targets the 0.125.0 CLI shape, which makes the existing `≥ 0.125.0` requirement consistent (previously the requirement and the pre-0.125.0 resume flags contradicted each other). Update the surrounding README/MANIFEST prose to reflect the `codex exec` vs. `codex exec resume` flag distinction.

## 8. Testing & verification

This is a markdown-only plugin; verification is structural plus one live check:

- **Lockstep diffs:** after editing, `diff` the priming string and the launch block across the three skills to confirm the #4/#5 edits are byte-identical; manually confirm the #6 reorder is consistent (plan/impl identical, brainstorm adapted).
- **One live integration check (#4):** run an actual `codex exec resume <throwaway-thread> -c sandbox_mode="read-only" --json -o ... < ... > ... 2> ...` from the repo root and confirm (a) it launches without the `unexpected argument` flag-rejection, and (b) the read-only sandbox still holds (a Codex-attempted write is refused). This is the meaningful regression test for the breakage.
- **#6 reorder** is pure decision-tree logic with no live trigger we can force (the rollout error is non-deterministic); it is verified by code review against the decision tree in §6.1.
- **#5** has no deterministic test; the nudge is best-effort and verified by inspection.

## 9. Out of scope / deferred

- The upstream root cause of #5 (Codex's Windows shell tool wrapping commands in `powershell.exe` + its sandbox blocking PowerShell) is a Codex CLI concern, not fixable inside this plugin. Keep issue #5 open with the dogfooding evidence appended for the upstream angle even after the priming nudge ships.
- Concurrent isolated chains via git worktrees ([#3](https://github.com/TimSimpsonJr/cross-model-review/issues/3), `design-input-needed`) is untouched; finding 2's concurrency observation is relevant context for it but not addressed here.

## 10. File-by-file change list (input to writing-plans)

- `skills/codex-plan-review/SKILL.md` — #4 launch block (continuation); #5 priming line; #6 handler reorder.
- `skills/codex-impl-review/SKILL.md` — same three edits (launch + priming byte-identical to plan-review; handler byte-identical to plan-review).
- `skills/codex-brainstorm-partner/SKILL.md` — #4 launch block; #5 priming line (byte-identical); #6 handler reorder *adapted* to its shorter variant.
- `commands/cross-model-status.md` — **no change** (enum addition dropped).
- `README.md` — reconcile `≥ 0.125.0` wording + flag distinction.
- `MANIFEST.md` — cwd-invariant note; lockstep-duplication line; `Targets Codex CLI` line refined for the resume flag distinction.
- `CHANGELOG.md` — v0.3.1 entry.
- `.claude-plugin/plugin.json` — version 0.3.0 → 0.3.1.
