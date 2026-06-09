---
codex_thread_id: 019ead25-41cc-7583-83d0-9adb9a0b336d
codex_design_review_status: approved
codex_design_review_approved_hash: cec41ed06db99d84fa36f5cd949a52e15244b50b41392d7bb597376d1a61b1e1
---

# Codex Windows Sandbox-Mode Fix — Design Document

**Status:** Brainstorm complete; in Codex design-review (round 1 returned changes; guard dropped).
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
  catastrophic round-0 bail is a rare tail (1 genuine bail in ~12 ad-hoc probes). The
  round-1 Codex design-review of *this very document* reproduced it live: 16 `blocked by
  policy` rejections, and the review still completed with accurate `file:line` citations.
  So the read-only friction is a latency/noise problem (issue #5), not a correctness wall.

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
2. **Priming rewrite:** replace the fictional "built-in file-reading capability" paragraph
   with accurate guidance, lockstep across all three skills. (§5)
3. **Rollout handling:** keep v0.4.0's positive-evidence-first classification (already
   correct, and **untouched** by this fix); document the error as cosmetic and resume as
   working. (§6)
4. **Runtime surfacing (two surfaces):** each review skill's launch chat note states the
   active sandbox mode at the moment a review is launched (proactive notice of the
   broadening), and `/cross-model-status` reports the mode this host would use for a new
   launch (pull-discoverable). (§6)
5. **Docs + issue updates + version bump.** (§6, §7, §9)

A post-review git-mutation hardening guard was considered and **dropped** after round-1
Codex design-review (see §4.4 and §10).

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
The only relaxation vs. read-only is in-repo writes (see §4.4).

### 4.4 Security posture (explicit)

The plugin only ever consumes Codex's **text output** (findings + verdict); it never
executes anything Codex produces. Under `workspace-write` the residual capability is
"Codex could write inside the repo during a review."

This residual is **accepted and documented** for v0.4.1, on these grounds: network is
denied (no exfiltration), out-of-workspace writes are denied, writes to *tracked* files are
git-recoverable, and empirically Codex never wrote in any of ~20 test runs (including the
round-1 review of this document). The residual **explicitly includes writes to
ignored/untracked paths** — notably the plugin's own runtime state under
`.claude/cross-model-review*` (`.gitignore:29-33`), which are **not** git-recoverable; this
is part of what the §6 `/cross-model-status` surfacing makes visible. A sandbox-level "no
repo writes" hardening is **not
achievable** under workspace-write — verified: `-c
'sandbox_workspace_write.writable_roots=["<scratch>"]'` still allowed a repo write, because
`writable_roots` *adds* roots and cannot subtract the cwd.

A post-review git-mutation guard (snapshot `git status` before, compare after) was the
candidate substitute. Round-1 Codex design-review found it unsound: a before/after snapshot
cannot attribute a change to Codex vs. the user's own concurrent edits during a 1–15 min
async review (it would false-halt on legitimate work), it misses gitignored writes —
including the plugin's own state at `.claude/cross-model-review*` (`.gitignore:29-33`) — and
it would require persisting the snapshot across the launch→completion turn boundary
(contradicting "no schema change"). The only mechanism that actually fixes attribution is
running each review in an isolated worktree/copy, which overlaps the unresolved
[#3](https://github.com/TimSimpsonJr/cross-model-review/issues/3) and is out of scope for a
bug fix. The guard is therefore **dropped**; worktree-isolated reviews are filed as a
follow-up (§10).

## 5. Priming rewrite (lockstep across all three skills)

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

## 6. Rollout handling, documentation, and runtime surfacing

- **Keep, unchanged,** v0.4.0's positive-evidence-first classification in the
  on-bg-completion handler (it treats a non-empty parseable result as success regardless of
  stderr, and only scans for stale-thread markers when the result is empty/corrupt). This
  fix does **not** touch the on-bg-completion handler in any skill.
- **Document** (README, MANIFEST, CHANGELOG):
  - Windows uses `workspace-write`; macOS/Linux use `read-only`. Explain why (read-only
    blocks PowerShell on Windows; workspace-write still denies network + out-of-workspace
    writes; the residual in-repo-write capability is accepted per §4.4).
  - The `failed to record rollout items` stderr is a known cosmetic Codex bug
    ([codex#19475](https://github.com/openai/codex/issues/19475), fixed post-0.125.0);
    resume works.
  - Update the inline cwd-invariant note to reference the new `sandbox_mode` value.
- **Surface the active sandbox mode at two points (required, not optional):**
  - **Proactive, at launch:** each review skill's Step 6 launch chat note (in
    `codex-plan-review`, `codex-impl-review`, and `codex-brainstorm-partner`) gains the
    active sandbox mode and, on Windows, a `write-capable (in-repo writes possible; network
    denied)` note. The auto-triggered launch is the moment the read-only→workspace-write
    broadening actually happens, so the notice must ride that launch note — `/cross-model-status`
    alone (pull-only) would miss it.
  - **Pull-discoverable:** `/cross-model-status` reports **the sandbox mode this host would
    use for a new launch right now** (computed from `uname` per §4.1) — explicitly NOT a
    per-in-flight-review field. Because §9.2 keeps the in-flight slot schema unchanged (no
    sandbox field), status cannot truthfully report an already-running job's mode; it states
    the host's current-launch mode to avoid overclaiming. Display-only, read-only command.

## 7. Issue updates (issue #9 decision 4 — upstream)

- Comment on **#9** and **#5** with the empirical findings, the `workspace-write` fix, and
  the upstream references ([#57](https://github.com/openai/codex-plugin-cc/issues/57),
  [#18451](https://github.com/openai/codex/issues/18451),
  [#19475](https://github.com/openai/codex/issues/19475)). Note that #9's resume half was a
  misdiagnosis (resume works; the rollout error is cosmetic and fixed upstream).
- This fix **closes #5** (the PowerShell rejections it describes are eliminated by
  workspace-write) and **closes #9**.
- Record **worktree-isolated Codex reviews** (the proper hardening for the §4.4 residual)
  by commenting on the existing worktree issue
  [#3](https://github.com/TimSimpsonJr/cross-model-review/issues/3) — **not** a new
  `design-input-needed` issue. Per the repo label taxonomy (`commands/cross-model-setup.md:83-87`),
  `design-input-needed` means a user decision blocks work; this is engineering hardening with
  no blocking user decision, so it folds into #3 (or a plain tracking issue) instead.
- No new upstream report is required: the block (#57/#18451) and the rollout error (#19475)
  are already tracked upstream. The README note recommends upgrading Codex past 0.125.0
  once #57 lands, at which point read-only could be revisited.

## 8. (reserved)

*(Section intentionally removed — the post-review mutation guard previously specified here
was dropped per §4.4.)*

## 9. Cross-cutting concerns

### 9.1 Lockstep duplication

The edits touch only the lockstep blocks that are genuinely byte-identical across skills:

- **Universal priming string** (§5) — byte-identical across all three skills; edit in
  lockstep, verify by `diff`.
- **Step 4 launch block** (§4.2) — byte-identical across all three skills; the new
  `$SANDBOX_MODE` computation + both launch commands edited in lockstep, verify by `diff`.

The **Step 6 launch chat note** (§6 surfacing) is **per-skill wording, NOT byte-identical**
(plan/impl/brainstorm phrase their launch notes differently), so the active-sandbox notice
is added to each skill individually — not as a lockstep block.

The **on-bg-completion handler is NOT edited by this fix.** (Per `MANIFEST.md:63` it is
"parallel-but-not-identical" across the three skills anyway — plan-review persists
`thread_id` to artifact frontmatter, impl-review updates state only, brainstorm is a shorter
variant — so it must never be treated as byte-identical. Since this fix leaves it untouched,
that distinction does not come into play here.)

### 9.2 No state/schema change

With the mutation guard dropped, the fix introduces no new persisted state, no new slot
fields, and no temp-file lifecycle. The state schema, chain tracking, dedup guards, verdict
gate, and issue-filing are unchanged.

## 10. Testing & verification

This is a markdown-only plugin; verification is structural plus live checks:

- **Live regression (the meaningful one):** re-run a realistic multi-file design-review
  under the new `workspace-write` invocation on Windows and confirm **0 `blocked by policy`
  rejections** in stderr and a clean completion. The reproduction harness built during this
  investigation is retained for this.
- **Gating check:** confirm the `uname` logic selects `read-only` on a non-MINGW shell and
  `workspace-write` on Git Bash.
- **Lockstep diffs:** after editing, `diff` the priming string and the launch block across
  the three skills to confirm byte-identical (§5, §4.2).
- **No-handler-change check:** confirm the on-bg-completion handlers are unchanged by this
  fix (the §4.4 guard was dropped).

## 11. Out of scope / deferred

- The upstream root cause of the PowerShell block ([#57](https://github.com/openai/codex-plugin-cc/issues/57),
  [#18451](https://github.com/openai/codex/issues/18451)) is a Codex CLI concern; not
  fixable in the plugin. Revisit read-only on Windows once #57 is fixed upstream.
- Embed-files + fresh-thread workaround (the original #9 proposal) — rejected: reviews
  complete and resume works, so it solves non-problems at high token cost and a large
  lockstep surface.
- **Worktree-isolated Codex reviews** — the proper hardening for the §4.4 in-repo-write
  residual (the only mechanism that fixes attribution + coverage). Folded into
  [#3](https://github.com/TimSimpsonJr/cross-model-review/issues/3) (§7).
- Sandbox-level "no repo writes" hardening — not enforceable under workspace-write
  (verified); see §4.4.

## 12. File-by-file change list (input to writing-plans)

- `skills/codex-plan-review/SKILL.md` — §4 launch block (uname-gated `$SANDBOX_MODE`, fresh
  + resume); §5 priming rewrite; §6 Step 6 chat-note sandbox notice (per-skill wording).
  **On-bg-completion handler: no change.**
- `skills/codex-impl-review/SKILL.md` — same launch + priming edits (byte-identical to
  plan-review) + its own Step 6 chat-note notice. **On-bg-completion handler: no change.**
- `skills/codex-brainstorm-partner/SKILL.md` — §4 launch block; §5 priming (byte-identical);
  its own Step 6 chat-note notice. **On-bg-completion handler: no change.**
- `commands/cross-model-status.md` — **required:** surface the active Codex sandbox mode +
  Windows write-capability in the read-only status report (per §6; round-2 review finding).
- `README.md` — Windows `workspace-write` note + why (incl. the accepted residual); rollout-
  error-cosmetic note; upgrade recommendation.
- `MANIFEST.md` — full rewrite to budget before PR merge (per repo convention); update the
  `Targets Codex CLI` line + cwd-invariant relationship note for the new sandbox value.
- `CHANGELOG.md` — v0.4.1 entry (#9/#5; sandbox-mode change called out).
- `.claude-plugin/plugin.json` — version 0.4.0 → 0.4.1.
