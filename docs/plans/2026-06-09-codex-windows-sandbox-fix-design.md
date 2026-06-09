---
codex_thread_id: null
codex_design_review_status: pending
---

# Codex Windows Sandbox-Mode Fix — Design Document

**Status:** Brainstorm complete; pending Codex design-review.
**Date:** 2026-06-09
**Type:** Bug fix + priming correction to `cross-model-review` v0.4.0
**Target version:** v0.4.1
**Issues addressed:** [#9](https://github.com/TimSimpsonJr/cross-model-review/issues/9) (primary), [#5](https://github.com/TimSimpsonJr/cross-model-review/issues/5) (subsumed)

---

## 1. Goal

On Windows, Codex reviews degrade: the read skills hit `rejected: blocked by policy` on
~6 of every review's shell commands, and in the rare tail Codex bails entirely ("please
provide the file contents"). Issue #9 attributes this to two hard failures — `codex exec
resume` not persisting threads, and the sandbox blocking all file reads — and proposes an
embed-files + fresh-thread workaround.

Empirical investigation (~20 live Codex runs on the filer's machine, codex-cli 0.125.0,
gpt-5.4) shows the diagnosis is partly wrong and the fix is far smaller than the proposed
workaround. This document specifies that smaller fix and records the evidence so the
reasoning survives.

## 2. Background — corrected root cause

All measurements below are from this machine: Windows 11, Git Bash (`uname -s` →
`MINGW64_NT-10.0-26200`), codex-cli 0.125.0, model gpt-5.4, invoked exactly as the skills
do (`codex exec --sandbox read-only -C <top> --json -o <file> < <prompt>`).

### 2.1 What #9 claims vs. what reproduces

| #9 claim | Observed |
| --- | --- |
| `codex exec resume` never persists the thread; degraded/unusable | **Resume works and preserves continuity.** Resumed a thread, it correctly recalled the prior turn. Exit 0. |
| `failed to record rollout items` breaks rounds | **Cosmetic.** Fires on every call (including brand-new threads), breaks neither reads nor resume. Known upstream bug [codex#19475](https://github.com/openai/codex/issues/19475), fixed in [PR #19630](https://github.com/openai/codex/pull/19630) (post-0.125.0). |
| Codex can't read repo files; bailed on round 0 | **Real, but tied to `--sandbox read-only` specifically, and self-recovering.** See 2.2. |

### 2.2 The read block is the read-only command policy

`read-only` is Codex's strictest *command* policy. On Windows, Codex routes file
inspection through `powershell.exe`; the read-only policy rejects complex PowerShell
shapes (`Get-Item | Format-List`, regex pipelines) with `ERROR codex_core::tools::router:
... rejected: blocked by policy`. Simple shapes (`Get-Content <path>`, plain `rg`) pass.

This is the open upstream bug [openai/codex-plugin-cc#57](https://github.com/openai/codex-plugin-cc/issues/57)
("Review mode blocks all commands on Windows: sandbox policy rejects PowerShell"), with
related native-sandbox token failures [codex#18451](https://github.com/openai/codex/issues/18451).
It is **not fixable from the plugin via config** — both documented levers were tested and
neither helped:

| Invocation (realistic multi-file design-review, n=5 each unless noted) | rejections/review | bails | completed |
| --- | --- | --- | --- |
| `--sandbox read-only` (today) | ~5.8 | 0/5 | 5/5 |
| `--sandbox read-only -c approval_policy="never"` | ~8.6 | 0/5 | 5/5 |
| `--sandbox read-only -c 'sandbox_permissions=["disk-full-read-access"]'` | ~6.6 | 0/5 | 5/5 |
| `--sandbox workspace-write` | **0** | 0/3 | 3/3 |
| `--sandbox danger-full-access` | **0** | 0/3 | 3/3 |

Key facts established:

- **`approval_policy` is the wrong layer.** Codex enforces via two independent layers —
  sandbox (what's technically allowed) and approval (when it asks). The block is the
  *sandbox* layer; `approval_policy="never"` does not touch it (and per Codex's `never`
  prompt template, it is mutually exclusive with `sandbox_permissions`).
- **`sandbox_permissions=["disk-full-read-access"]` did not help** on our `codex exec`
  path, despite being the workaround named in #57.
- **`workspace-write` eliminates the block entirely (0 rejections)** while keeping
  **network denied** (workspace-write is network-off by default) and **out-of-workspace
  writes denied**. `git status` was identical before/after every workspace-write and
  danger-full-access run — Codex never wrote anything (it is a reviewer; it only reads).
- **Reviews complete under read-only today** (0 genuine bails in 15 realistic runs); the
  catastrophic round-0 bail is a rare tail (1 genuine bail in ~12 ad-hoc probes). So the
  read-only friction is a latency/noise problem (issue #5), not a correctness wall.

### 2.3 The priming line is factually wrong

The v0.3.1 universal-priming Windows paragraph tells Codex to "prefer your built-in
file-reading capability over shell commands … shell-based grep/read attempts will fail.
Read files directly instead." codex-cli 0.125.0 has **no separate built-in read tool** —
the shell is Codex's only file access. The line describes a fiction and, at worst, steers
Codex away from the one mechanism that works.

## 3. Design summary

Five changes, all scoped to v0.4.1:

1. **Sandbox mode (core):** on Windows, switch the Codex sandbox `read-only` →
   `workspace-write`; keep `read-only` on macOS/Linux. Gate via `uname -s`. Eliminates the
   PowerShell block at the source. (§4)
2. **Hardening:** a post-review git-mutation guard. Since `workspace-write` keeps the cwd
   writable (verified: `writable_roots` cannot subtract it), detect unexpected working-tree
   mutation after each review round and surface it. (§5)
3. **Priming rewrite:** replace the fictional "built-in file-reading capability" paragraph
   with accurate guidance, lockstep across all three skills. (§6)
4. **Rollout handling:** keep v0.4.0's positive-evidence-first classification (already
   correct); document the error as cosmetic and resume as working. (§7)
5. **Docs + issue updates + version bump.** (§7, §8, §10)

## 4. Sandbox-mode change (the core fix)

### 4.1 OS gating

Before composing the launch command, the skill computes `$SANDBOX_MODE`:

- If `uname -s` matches `MINGW*` / `MSYS*` / `CYGWIN*` (Codex is the PowerShell-wrapping
  Windows build) → `workspace-write`.
- Otherwise (`Linux` incl. WSL, `Darwin`) → `read-only` (unchanged).

This keeps the stricter no-write guarantee where read-only works (non-Windows) and only
relaxes where read-only is broken (Windows). WSL reports `Linux`, so a user who runs Codex
under WSL keeps `read-only` — a no-cost escape hatch.

### 4.2 The launch blocks (lockstep across all three skills)

**Fresh thread:**

```bash
codex exec --sandbox $SANDBOX_MODE -C <project-toplevel> --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

**Continuation (resume):**

```bash
cd <project-toplevel> && codex exec resume <attempted_thread_id> -c sandbox_mode="$SANDBOX_MODE" --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

`$SANDBOX_MODE` is `workspace-write` on Windows, `read-only` elsewhere, on **both** paths.
The existing **cwd-invariant** note (resume must `cd` to the same toplevel the fresh call
used with `-C`) is unchanged and stays inline. The fresh path keeps the first-class
`--sandbox` flag (fails loud on CLI drift); the resume path keeps the `-c sandbox_mode=`
config override (the only mechanism `resume` accepts) — this asymmetry is the same one
documented in the v0.3.1 design and is preserved.

### 4.3 Why workspace-write, not danger-full-access

`danger-full-access` also gives 0 rejections but **opens network access** — unacceptable
for an autonomous, unsupervised reviewer (exfiltration risk). `workspace-write` is the
least-privilege mode that clears the block: network denied, out-of-workspace writes denied.
The only relaxation vs. read-only is in-repo writes, addressed by §5.

### 4.4 Security posture (explicit)

The plugin only ever consumes Codex's **text output** (findings + verdict); it never
executes anything Codex produces. Under `workspace-write` the residual capability is
"Codex could write inside the repo during a review." Mitigations: network is denied (no
exfiltration), out-of-workspace writes are denied, repo writes are git-recoverable, and
empirically Codex never wrote in any test run. §5 adds detection.

## 5. Hardening — post-review git-mutation guard

`workspace-write` always keeps the working directory (cwd = the repo, passed via `-C`)
writable. This was verified: `workspace-write` with
`-c 'sandbox_workspace_write.writable_roots=["<scratch>"]'` still allowed a repo write
(`writable_roots` *adds* roots; it cannot subtract the cwd). So the hardening cannot live
at the sandbox layer — it lives in the skill:

- **Before launching** a Codex review round, the skill records a pre-review snapshot of the
  working tree: `git status --porcelain` plus `git rev-parse HEAD`. (HEAD is already partly
  tracked via `impl_review_approved_sha` for impl-review.)
- **On bg-completion**, the skill re-runs `git status --porcelain` and compares. If the
  working tree gained changes **not present before the review** (i.e., attributable to the
  Codex round), the skill:
  - **Interactive:** posts a chat-note warning naming the unexpected paths, and does NOT
    proceed to route findings until acknowledged.
  - **Autonomous:** writes a halt-note (`.claude/cross-model-review/halts/<chain-stem>.md`),
    sets `chain_status = halted`, fires a notification.
- **No auto-revert.** Reverting could clobber legitimate concurrent edits (the user may be
  working in the same tree). The guard surfaces; the human decides.

This is the only change touching the bg-completion handlers. It is scoped to detect
*review-attributable* mutation only — pre-existing dirty state is captured in the snapshot
and excluded, so it does not fire on the user's own in-progress work.

## 6. Priming rewrite (lockstep across all three skills)

Replace the v0.3.1 Windows paragraph in the universal priming string. Proposed wording
(implementation may tighten):

> File access: your only way to read the repository is via your shell — there is no
> separate built-in file-reading tool. Read files with simple shell commands (e.g.
> `Get-Content <path>`, `rg <pattern>`); they work under this session's sandbox. If a
> command is ever rejected, reformulate it as a simpler read and retry — do not give up or
> ask for file contents to be pasted unless you are truly unable to proceed. (You may see a
> `failed to record rollout items` line in logs; it is a harmless known Codex log — ignore
> it.)

Rationale: states the truth (shell is the only read path), steers toward the simple command
shapes that never get blocked even under read-only (helps WSL/macOS/Linux and the rare
Windows tail), instructs retry-not-bail, and pre-empts the cosmetic rollout log. The block
about `[CHAIN-BOUNDARY]`, mode definitions, and the tag-line spec is unchanged. The string
stays byte-identical across all three skills (lockstep tier 1).

## 7. Rollout handling and documentation

- **Keep** v0.4.0's positive-evidence-first classification in the on-bg-completion handler
  (already correct — it treats a non-empty parseable result as success regardless of stderr,
  and only scans for stale-thread markers when the result is empty/corrupt). No change.
- **Document** (README, MANIFEST, CHANGELOG):
  - Windows uses `workspace-write`; macOS/Linux use `read-only`. Explain why (read-only
    blocks PowerShell on Windows; workspace-write still denies network + out-of-workspace
    writes).
  - The `failed to record rollout items` stderr is a known cosmetic Codex bug
    ([codex#19475](https://github.com/openai/codex/issues/19475), fixed post-0.125.0);
    resume works.
  - Update the inline cwd-invariant note to reference the new `sandbox_mode` value.

## 8. Issue updates (issue #9 decision 4 — upstream)

- Comment on **#9** and **#5** with the empirical findings, the `workspace-write` fix, and
  the upstream references ([#57](https://github.com/openai/codex-plugin-cc/issues/57),
  [#18451](https://github.com/openai/codex/issues/18451),
  [#19475](https://github.com/openai/codex/issues/19475)). Note that #9's resume half was a
  misdiagnosis (resume works; the rollout error is cosmetic and fixed upstream).
- This fix **closes #5** (the PowerShell rejections it describes are eliminated by
  workspace-write) and **closes #9**.
- No new upstream report is required: the block (#57/#18451) and the rollout error (#19475)
  are already tracked upstream. The README note recommends upgrading Codex past 0.125.0
  once #57 lands, at which point read-only could be revisited.

## 9. Cross-cutting concerns

### 9.1 Lockstep duplication

The edits touch the three-tier lockstep blocks (MANIFEST "three tiers"):

- **Universal priming string** (§6) — byte-identical across all three skills; edit in
  lockstep, verify by `diff`.
- **Step 4 launch block** (§4.2) — byte-identical across all three skills; the new
  `$SANDBOX_MODE` computation + both launch commands edited in lockstep, verify by `diff`.
- **On-bg-completion handler** (§5) — `codex-plan-review` and `codex-impl-review` are
  byte-identical; `codex-brainstorm-partner` is the shorter variant, so the git-mutation
  guard is *adapted* to it (it has no findings-routing, but the pre/post snapshot +
  surfacing applies). impl-review additionally already snapshots HEAD.

### 9.2 No change to chain/state model

The fix does not alter the state schema, chain tracking, dedup guards, verdict gate, or
issue-filing. The pre-review git snapshot for §5 is transient (computed per round, not
persisted beyond the in-flight slot).

## 10. Testing & verification

This is a markdown-only plugin; verification is structural plus live checks:

- **Live regression (the meaningful one):** re-run a realistic multi-file design-review
  under the new `workspace-write` invocation on Windows and confirm **0 `blocked by policy`
  rejections** in stderr and a clean `[VERDICT: ...]` completion. The reproduction harness
  built during this investigation is retained for this.
- **Gating check:** confirm the `uname` logic selects `read-only` on a non-MINGW shell and
  `workspace-write` on Git Bash.
- **Lockstep diffs:** after editing, `diff` the priming string and the launch block across
  the three skills to confirm byte-identical (§6, §4.2); manually confirm the §5 handler
  change is consistent (plan/impl identical, brainstorm adapted).
- **Mutation guard:** simulate a review-attributable working-tree change and confirm the
  guard surfaces it (interactive warning / autonomous halt-note) without auto-reverting.

## 11. Out of scope / deferred

- The upstream root cause of the PowerShell block ([#57](https://github.com/openai/codex-plugin-cc/issues/57),
  [#18451](https://github.com/openai/codex/issues/18451)) is a Codex CLI concern; not
  fixable in the plugin. Revisit read-only on Windows once #57 is fixed upstream.
- Embed-files + fresh-thread workaround (the original #9 proposal) — rejected: reviews
  complete and resume works, so it solves non-problems at high token cost and a large
  lockstep surface.
- Sandbox-level "no repo writes" hardening — not enforceable under workspace-write
  (verified); the §5 git guard is the substitute.
- Concurrent isolated chains via git worktrees ([#3](https://github.com/TimSimpsonJr/cross-model-review/issues/3))
  — untouched.

## 12. File-by-file change list (input to writing-plans)

- `skills/codex-plan-review/SKILL.md` — §4 launch block (uname-gated `$SANDBOX_MODE`, fresh
  + resume); §5 mutation guard in bootstrap (pre-snapshot) + on-bg-completion (post-check);
  §6 priming rewrite.
- `skills/codex-impl-review/SKILL.md` — same three edits (launch + priming byte-identical to
  plan-review; handler byte-identical to plan-review).
- `skills/codex-brainstorm-partner/SKILL.md` — §4 launch block; §6 priming (byte-identical);
  §5 mutation guard adapted to its shorter handler variant.
- `commands/cross-model-status.md` — optional: surface the active sandbox mode in the
  read-only status report (nice-to-have; confirm during plan).
- `README.md` — Windows `workspace-write` note + why; rollout-error-cosmetic note; upgrade
  recommendation.
- `MANIFEST.md` — full rewrite to budget before PR merge (per repo convention); update the
  `Targets Codex CLI` line + cwd-invariant relationship note for the new sandbox value.
- `CHANGELOG.md` — v0.4.1 entry (#9/#5; sandbox-mode change called out).
- `.claude-plugin/plugin.json` — version 0.4.0 → 0.4.1.
