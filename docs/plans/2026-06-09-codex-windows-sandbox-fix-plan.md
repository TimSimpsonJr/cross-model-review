---
codex_thread_id: 019eb719-2f5d-7860-bba6-dc17e8a20133
codex_plan_review_status: approved
codex_plan_review_approved_hash: 6e05bcd406870d71e0c8c3b6c1b1c54c1306035dc2e91473683915a0abface1a
---

# Codex Windows Sandbox-Mode Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or
> superpowers:subagent-driven-development) to implement this plan task-by-task.

**Goal:** On Windows, make Codex reviews stop hitting `blocked by policy` rejections by
switching the OS-gated Codex sandbox from `read-only` to `workspace-write`, and replace the
factually-wrong "built-in file-reading" priming line — shipping cross-model-review v0.4.1.

**Architecture:** Markdown-only Claude Code plugin. The three review skills
(`codex-plan-review`, `codex-impl-review`, `codex-brainstorm-partner`) share two
byte-identical lockstep blocks (the universal priming string and the Step-4 launch block);
this plan edits both in lockstep and verifies with `diff`. A per-skill Step-6 launch chat
note and the `/cross-model-status` command gain an active-sandbox notice. No on-bg-completion
handler is touched. Approved design: `docs/plans/2026-06-09-codex-windows-sandbox-fix-design.md`
(Codex-approved, body hash `cec41ed0…b1e1`).

**Tech Stack:** Markdown skill/command files; Bash (`uname`, `git`, `diff`); the `codex`
CLI (0.125.0) for the live regression check. No build, no unit-test framework — verification
is structural (`diff`) plus one live Codex run.

**Guardrails (do NOT violate):**
- The **on-bg-completion handler is NOT edited** in any skill (design §6/§9.1).
- The **priming string** and the **Step-4 launch block** must stay **byte-identical** across
  all three skills (lockstep tiers 1 and 2). Verify with `diff` after every edit.
- Do **not** add `--all` to the resume command; do **not** drop the leading `cd` (cwd
  invariant). Do **not** use `danger-full-access` (opens network).

---

### Task 1: Rewrite the universal priming Windows paragraph (lockstep ×3)

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md` (priming block)
- Modify: `skills/codex-impl-review/SKILL.md` (priming block)
- Modify: `skills/codex-brainstorm-partner/SKILL.md` (priming block)

**Step 1: Replace the paragraph in all three skills.**

Find this exact paragraph (byte-identical in all three skill bodies, inside the
```` ``` ```` universal-priming fenced block):

```
Tool use on Windows: prefer your built-in file-reading capability over shell
commands when inspecting the repo. On Windows your shell invocations — including
`bash` and `rg` — get wrapped in `powershell.exe`, which the sandbox blocks, so
shell-based grep/read attempts will fail. Read files directly instead. (Harmless
on non-Windows hosts, where the shell works normally.)
```

Replace it (in each skill) with this exact paragraph:

```
File access: your only way to read the repository is via your shell — there is no
separate built-in file-reading tool. Read files with simple shell commands (for
example `Get-Content <path>` or `rg <pattern>`); they work under this session's
sandbox. If a shell command is ever rejected, reformulate it as a simpler read and
retry — do not give up or ask for file contents to be pasted unless you are truly
unable to proceed. (You may see a `failed to record rollout items` line in the logs;
it is a harmless known Codex log — ignore it.)
```

**Step 1b: Also replace the stale capability claim** (same universal-priming block,
byte-identical across all three skills). Find:
```
You have read-only access to the working directory.
```
Replace with:
```
You can read the working directory to verify claims — you are a reviewer, so inspect it but do not modify it.
```
After Task 2 switches Windows to `workspace-write`, the old "read-only access" claim is
factually wrong on Windows; this behavioral instruction is accurate on all platforms and
reinforces that Codex must not write even where it technically could.

**Step 2: Verify byte-identical across the three skills.**

Run (Git Bash):
```bash
cd "$(git rev-parse --show-toplevel)"
awk '/^```/{c++; next} c==1{print}' skills/codex-plan-review/SKILL.md > /tmp/p-plan.txt
awk '/^```/{c++; next} c==1{print}' skills/codex-impl-review/SKILL.md > /tmp/p-impl.txt
awk '/^```/{c++; next} c==1{print}' skills/codex-brainstorm-partner/SKILL.md > /tmp/p-brain.txt
diff /tmp/p-plan.txt /tmp/p-impl.txt && diff /tmp/p-plan.txt /tmp/p-brain.txt && echo "PRIMING BYTE-IDENTICAL"
```
Expected: `PRIMING BYTE-IDENTICAL` (no diff output). Also confirm the new paragraph is
present and the old "built-in file-reading capability" string is gone:
```bash
grep -rl "built-in file-reading capability" skills/ && echo "FAIL: old priming text remains" || echo "OK: old priming text removed"
grep -rl "read-only access to the working directory" skills/ && echo "FAIL: stale read-only claim remains" || echo "OK: read-only claim updated"
```
Expected: both `OK:` lines.

**Step 3: Commit.**
```bash
git add skills/*/SKILL.md
git commit -m "fix(review): correct the Windows file-access priming (no built-in read tool)"
```

---

### Task 2: OS-gate the Step-4 launch block to workspace-write on Windows (lockstep ×3)

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md` (Step 4 launch block)
- Modify: `skills/codex-impl-review/SKILL.md` (Step 4 launch block)
- Modify: `skills/codex-brainstorm-partner/SKILL.md` (Step 4 launch block)

**Step 1: Replace the launch block in all three skills.**

Find this exact block (byte-identical in all three; it begins right after the
`### Step 4: Launch via Bash with \`run_in_background: true\`` heading):

````
**Fresh thread** (attempted_thread_id null):
```bash
codex exec --sandbox read-only -C <project-toplevel> --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

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

Replace it (in each skill) with this exact block:

````
**Compute the OS-gated sandbox mode first.** Run `uname -s`. If it matches `MINGW*`,
`MSYS*`, or `CYGWIN*` (Codex is the PowerShell-wrapping Windows build, whose `read-only`
command policy rejects PowerShell shell calls), set `SANDBOX_MODE=workspace-write`.
Otherwise (`Linux` including WSL, or `Darwin`) set `SANDBOX_MODE=read-only`.
`workspace-write` clears the Windows PowerShell block while still denying network and
out-of-workspace writes; the only relaxation is in-repo writes (accepted — see the
v0.4.1 design §4.1/§4.3/§4.4). Substitute the resolved value for `$SANDBOX_MODE` below.

**Fresh thread** (attempted_thread_id null):
```bash
codex exec --sandbox $SANDBOX_MODE -C <project-toplevel> --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

**Continuation** (attempted_thread_id set):
```bash
cd <project-toplevel> && codex exec resume <attempted_thread_id> -c sandbox_mode="$SANDBOX_MODE" --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

> **cwd invariant (do not "simplify" away):** the leading `cd` is load-bearing.
> Codex records and filters sessions by cwd; the fresh-thread call above mints
> the thread from `<project-toplevel>` via `-C`, so resuming from that same
> directory is how Codex locates the session. Do not drop the `cd`, and do not
> add `--all` (which would disable cwd filtering). The fresh path keeps the
> first-class `--sandbox`/`-C` flags deliberately — they fail loud if the CLI
> changes again, whereas `-c sandbox_mode=` fails silent. `$SANDBOX_MODE` is
> `workspace-write` on Windows (Git Bash) and `read-only` elsewhere. (Design §4.)
````

**Step 2: Verify byte-identical across the three skills.**

```bash
cd "$(git rev-parse --show-toplevel)"
for f in plan impl brainstorm; do
  case $f in plan) F=codex-plan-review;; impl) F=codex-impl-review;; brainstorm) F=codex-brainstorm-partner;; esac
  awk '/### Step 4: Launch via Bash/{g=1} g{print} /cwd invariant/{inv=1} inv&&/Design §4/{exit}' "skills/$F/SKILL.md" > "/tmp/l-$f.txt"
done
diff /tmp/l-plan.txt /tmp/l-impl.txt && diff /tmp/l-plan.txt /tmp/l-brainstorm.txt && echo "LAUNCH BLOCK BYTE-IDENTICAL"
```
Expected: `LAUNCH BLOCK BYTE-IDENTICAL`. Also confirm the gating text and `$SANDBOX_MODE`
substitution are present and no stray `--sandbox read-only` literal remains in the launch
blocks:
```bash
grep -rc 'sandbox_mode="\$SANDBOX_MODE"' skills/   # expect 1 per skill (3 total)
grep -rn -- '--sandbox read-only' skills/ && echo "CHECK: read-only literal still present" || echo "OK: no hardcoded read-only in skills"
```
Expected: three matches for the resume line; `OK: no hardcoded read-only in skills`.

**Step 3: Commit.**
```bash
git add skills/*/SKILL.md
git commit -m "fix(review): use workspace-write sandbox on Windows (uname-gated) to clear PowerShell block (#9, #5)"
```

---

### Task 3: Add the active-sandbox notice to each skill's Step-6 launch chat note (per-skill, NOT lockstep)

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md` (Step 6 chat note)
- Modify: `skills/codex-impl-review/SKILL.md` (Step 6 chat note)
- Modify: `skills/codex-brainstorm-partner/SKILL.md` (Step 6 chat note)

The Step-6 note wording differs per skill, so edit each individually.

**Step 1: `codex-plan-review` — replace the Step-6 note.**

Find: `Post: *"Codex \`<this-mode>\` running in the background (typical 5–15 min at \`xhigh\` reasoning). I'll surface findings when the background job completes."*`

Replace with: `Post: *"Codex \`<this-mode>\` running in the background — sandbox \`$SANDBOX_MODE\` (on Windows this is \`workspace-write\`: Codex can write in-repo, network denied); typical 5–15 min at \`xhigh\` reasoning. I'll surface findings when the background job completes."*`

**Step 2: `codex-impl-review` — replace the Step-6 note.**

Find: `Post: *"Codex impl-review running in the background (typical 5–15 min at \`xhigh\` reasoning). I'll surface findings when the background job completes."*`

Replace with: `Post: *"Codex impl-review running in the background — sandbox \`$SANDBOX_MODE\` (on Windows this is \`workspace-write\`: Codex can write in-repo, network denied); typical 5–15 min at \`xhigh\` reasoning. I'll surface findings when the background job completes."*`

**Step 3: `codex-brainstorm-partner` — replace the Step-6 note.**

Find: `Post: *"Codex stand-in thinking about the brainstorming question (typical 1–5 min at \`xhigh\` reasoning for a single question). Will surface response when complete."*`

Replace with: `Post: *"Codex stand-in thinking about the brainstorming question — sandbox \`$SANDBOX_MODE\` (on Windows this is \`workspace-write\`: Codex can write in-repo, network denied); typical 1–5 min at \`xhigh\` reasoning for a single question. Will surface response when complete."*`

**Step 4: Verify.**
```bash
grep -rc 'sandbox `\$SANDBOX_MODE`' skills/   # expect 3 (one per skill)
```
Expected: 3 matches.

**Step 5: Commit.**
```bash
git add skills/*/SKILL.md
git commit -m "feat(review): surface active sandbox mode in each skill's launch chat note"
```

---

### Task 4: Surface the host sandbox mode in `/cross-model-status`

**Files:**
- Modify: `commands/cross-model-status.md`

**Step 1: Add a compute step.** After step 5 ("Per-rule hooks check"), add a new step 5.5:

```markdown
5.5. **Host sandbox mode (read-only display).** Run `uname -s`. If it matches
   `MINGW*` / `MSYS*` / `CYGWIN*`, the host's Codex launches use
   `workspace-write` (write-capable: in-repo writes possible, network denied);
   otherwise `read-only`. This reports the mode THIS HOST would use for a NEW
   launch right now — it is NOT a per-in-flight-review field (the in-flight slot
   schema has no sandbox field; v0.4.1 design §6/§9.2). Do not infer a running
   job's mode from it.
```

**Step 2: Add the output line to BOTH output formats.** The mode is host-derived, so it must
show even before any state file exists (plan-review finding).

In the **PERSISTED** template (step 6), immediately after the `Mode:` line, add:
```
   Sandbox (this host): WORKSPACE-WRITE (Windows; in-repo writes possible, network denied) | READ-ONLY
      Mode this host would use for a NEW Codex launch (not a running job's mode).
```

In the **NONE** template (step 6), immediately after its `Mode: — (defaults to interactive
on first stateful action)` line, add the same `Sandbox (this host):` line. This makes the
Windows `workspace-write` mode discoverable via `/cross-model-status` before first use.

**Step 3: Verify.**
```bash
grep -n "Host sandbox mode\|Sandbox (this host)" commands/cross-model-status.md
```
Expected: both strings present (the step and the template line).

**Step 4: Commit.**
```bash
git add commands/cross-model-status.md
git commit -m "feat(status): report the host's active Codex sandbox mode"
```

---

### Task 5: README — Windows sandbox note + accuracy fixes

**Files:**
- Modify: `README.md`

**Step 1: Update the version header, then fix the now-inaccurate read-only line.**

First, update the README version/status header (around `README.md:5`, currently
`**Status:** v0.3.1`) to `**Status:** v0.4.1` so the README matches the shipped version
(plan-review finding — otherwise plugin.json/CHANGELOG say 0.4.1 while the README header
still says v0.3.1).

Then find:
`- File contents Codex chooses to read via its read-only sandbox (the plugin doesn't pre-package file contents; Codex requests them).`
Replace with:
`- File contents Codex reads via its sandbox (read-only on macOS/Linux; workspace-write on Windows — see Sandbox notes). The plugin doesn't pre-package file contents; Codex reads them itself.`

**Step 2: Add a "Sandbox & platform notes" section** (place it after the Requirements
section). Content:

```markdown
## Sandbox & platform notes

Codex reviews run under a sandbox selected by the host OS (auto-detected via `uname`):

- **macOS / Linux (incl. WSL):** `read-only` — Codex can read the repo but not write or
  reach the network.
- **Windows (Git Bash):** `workspace-write`. On Windows the `read-only` command policy
  rejects Codex's PowerShell-wrapped reads (`blocked by policy`; upstream
  [openai/codex-plugin-cc#57](https://github.com/openai/codex-plugin-cc/issues/57)), which
  wastes review latency and can occasionally make Codex give up. `workspace-write` clears
  that block while still **denying network access and out-of-workspace writes**. The
  residual is that Codex *could* write inside the repo during a review (git-recoverable for
  tracked files; ignored/untracked writes — including the plugin's own `.claude/`
  state — are not). The active mode is shown in each review's launch note and in
  `/cross-model-status`.
- A `failed to record rollout items` line in Codex's stderr is a **harmless known bug**
  ([openai/codex#19475](https://github.com/openai/codex/issues/19475), fixed after 0.125.0);
  reviews and `codex exec resume` work despite it.

Once #57 is fixed upstream, Windows can return to `read-only`; upgrading Codex past 0.125.0
is recommended when that lands.
```

**Step 3: Verify.**
```bash
grep -n "Sandbox & platform notes\|workspace-write" README.md
grep -nE '\*\*Status:\*\* v0\.4\.1' README.md && echo "OK: README header is v0.4.1" || echo "FAIL: README header not updated"
grep -nE 'v0\.3\.1' README.md   # expect only historical references (Upgrading section), NOT the Status header
```
Expected: Sandbox section heading + a `workspace-write` mention; `OK: README header is v0.4.1`;
any remaining `v0.3.1` hits are only in the historical "Upgrading from v0.1 / v0.2" section.

**Step 4: Commit.**
```bash
git add README.md
git commit -m "docs(readme): document Windows workspace-write sandbox + cosmetic rollout error"
```

---

### Task 6: CHANGELOG entry + version bump

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

**Step 1: Add the v0.4.1 section** at the top of `CHANGELOG.md` (above `## 0.4.0`):

```markdown
## 0.4.1 — 2026-06-09

### Fixed
- **#9 / #5 — Windows PowerShell sandbox block.** On Windows, Codex's `read-only` command
  policy rejected its PowerShell-wrapped file reads (`blocked by policy`), wasting review
  latency and occasionally making Codex bail. The Codex sandbox is now OS-gated (via
  `uname`): **`workspace-write` on Windows** (clears the block; network + out-of-workspace
  writes still denied), `read-only` on macOS/Linux (unchanged). Investigation showed the
  other half of #9 was a misdiagnosis: `codex exec resume` works and preserves continuity,
  and `failed to record rollout items` is a cosmetic upstream bug
  ([codex#19475](https://github.com/openai/codex/issues/19475), fixed post-0.125.0).

### Changed
- **Universal priming corrected.** Replaced the v0.3.1 line that told Codex to "prefer your
  built-in file-reading capability" (no such tool exists in 0.125.0 — the shell is its only
  file access) with accurate guidance: read via simple shell commands, reformulate-and-retry
  on rejection, ignore the cosmetic rollout log.
- **Active sandbox mode is surfaced** in each review skill's launch chat note and in
  `/cross-model-status` (the mode this host would use for a new launch), so the Windows
  read-only→workspace-write broadening is visible in-product.

### Notes
- The in-repo-write residual under Windows `workspace-write` is accepted for this release;
  worktree-isolated reviews (the robust hardening) are tracked in
  [#3](https://github.com/TimSimpsonJr/cross-model-review/issues/3).
```

**Step 2: Bump the version to `0.4.1` in BOTH manifest files.** In
`.claude-plugin/plugin.json`: `"version": "0.4.0"` → `"version": "0.4.1"`. In
`.claude-plugin/marketplace.json`: its `metadata.version` is currently `"0.3.0"` (it lagged
the 0.4.0 release — plan-review finding) → set it to `"0.4.1"`.

**Step 3: Verify.**
```bash
grep -m1 '"version"' .claude-plugin/plugin.json        # expect 0.4.1
grep -n '"version"' .claude-plugin/marketplace.json    # expect 0.4.1 (was 0.3.0)
grep -n "0.4.1" CHANGELOG.md | head -1
```

**Step 4: Commit.**
```bash
git add CHANGELOG.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore: v0.4.1 — CHANGELOG + version bump (plugin + marketplace manifests)"
```

---

### Task 7: MANIFEST.md full rewrite to budget (pre-PR)

**Files:**
- Modify: `MANIFEST.md`

Per repo convention (CLAUDE.md), rewrite `MANIFEST.md` from scratch to the 50–120-line
budget before PR merge. Update specifically:
- The **Stack** "Targets Codex CLI" line: note fresh-vs-resume flags **and** that the
  sandbox is OS-gated (`workspace-write` on Windows, `read-only` elsewhere).
- The **cwd-invariant** Key-Relationships note: reference the OS-gated `$SANDBOX_MODE` value.
- Add the new `docs/plans/2026-06-09-codex-windows-sandbox-fix-{design,plan}.md` to the
  Structure index (group with the other per-phase design/plan docs).
- Keep the lockstep taxonomy accurate AND complete (do not drop tiers): **universal priming
  byte-identical across all 3 skills**; **Step-4 launch block byte-identical across all 3**;
  **verdict-contract block byte-identical across the 2 review skills** (plan-review +
  impl-review — per `MANIFEST.md:63`; do NOT lose this tier); **Step-6 launch notes** and
  **on-bg-completion handlers** remain **per-skill** (not lockstep).

**Verify:** line count within budget:
```bash
wc -l MANIFEST.md   # expect 50–120
```

**Commit:**
```bash
git add MANIFEST.md
git commit -m "docs(manifest): rewrite to budget; OS-gated sandbox + new design/plan docs"
```

---

### Task 8: Verification — lockstep diffs + live workspace-write regression

**Step 1: Re-confirm lockstep** (priming + launch block byte-identical) using the Task-1
Step-2 and Task-2 Step-2 commands. Expected: both print BYTE-IDENTICAL.

**Step 2: Live regression — the meaningful check (review-depth, both sandboxes).** The Windows
failure comes from Codex choosing PowerShell-heavy inspection shapes during a real review, so
the regression MUST exercise review depth (multi-file, repo cross-checks) — not a couple of
simple reads (which pass under `read-only` too). Reuse the design-investigation reproduction
harness: embed a design doc and ask Codex to verify claims across the three skill files with
`path:line` cross-checks, then run under BOTH sandboxes to show the delta:
```bash
cd "$(git rev-parse --show-toplevel)"; TOP=$(git rev-parse --show-toplevel)
{
  echo "[MODE: design-review]"; echo
  echo "Review-depth check: verify against the repo that skills/codex-plan-review/SKILL.md, skills/codex-impl-review/SKILL.md, and skills/codex-brainstorm-partner/SKILL.md each contain the universal-priming block AND a Step-4 launch block; confirm whether the priming and launch blocks are byte-identical across all three; and quote the resume command's exact flags in each. Cite path:line for every check. End with [VERDICT: approved] or [VERDICT: changes-requested]."
  echo; echo "===== DESIGN ====="; cat docs/plans/2026-06-09-codex-windows-sandbox-fix-design.md
} > /tmp/cmr-reg-prompt.txt
for MODE in read-only workspace-write; do
  codex exec --sandbox "$MODE" -C "$TOP" -c model_reasoning_effort=low --json \
    -o /tmp/cmr-reg-$MODE-res.txt < /tmp/cmr-reg-prompt.txt > /tmp/cmr-reg-$MODE-ev.jsonl 2> /tmp/cmr-reg-$MODE-err.txt
  echo "$MODE rejections: $(grep -ciE 'blocked by policy|rejected' /tmp/cmr-reg-$MODE-err.txt)  completed: $(test -s /tmp/cmr-reg-$MODE-res.txt && echo yes || echo no)"
done
```
Expected — **the MUST-PASS gate is `workspace-write rejections: 0  completed: yes`**; that is
the release condition. The `read-only` run is **comparative evidence only, NOT a gate**: it
usually shows rejections (>0), but the count depends on which inspection shapes Codex happens
to choose on that run, so a `read-only` run that incidentally yields 0 does **not** fail the
release (design §2.2 characterizes `read-only` as latency/noise, not a hard wall). If
`workspace-write` is not `0` with a clean completion, the fix is incomplete — do NOT proceed
to PR.

**Step 3: Gating check.** Confirm the gating logic resolves correctly:
```bash
uname -s   # MINGW*/MSYS*/CYGWIN* on this host -> workspace-write; Linux/Darwin -> read-only
```

**Step 4: No-handler-change check.** Confirm the on-bg-completion handlers were not edited:
```bash
git diff 2929a57..HEAD -- skills/ | grep -A2 -iE "On bg completion|positive evidence" | head
```
Expected: no substantive changes inside the "On bg completion" sections (only priming,
launch block, and Step-6 note changed).

---

## Out of scope for v0.4.1 (explicit)

- `commands/cross-model-setup.md` (the CLAUDE-mapping "ask codex about <X>" ad-hoc
  consultation path, ~lines 54-66) is **intentionally untouched**. v0.4.1 scopes the
  sandbox-mode fix and priming correction to the three review skills' launch blocks. The
  ad-hoc consult is a manually-invoked documented pattern (not a skill-body launch block),
  and aligning it to the OS-gated sandbox would mean editing the printed CLAUDE.md guidance
  itself — a different surface/category. Tracked as a small follow-up docs touch, not
  expanded into this bug-fix release. (Plan-review finding; accepted as out-of-scope.)

## Post-implementation: Codex impl-review + PR (autonomous closer)

After Task 8, the chain proceeds to **codex-impl-review** on the branch diff, then the
**autonomous PR closer**:
- Open the PR (merge-commit style) with summary, the three approvals, and any scope-call
  notes.
- Comment on [#9](https://github.com/TimSimpsonJr/cross-model-review/issues/9) and
  [#5](https://github.com/TimSimpsonJr/cross-model-review/issues/5) with the findings and
  close them (subsumed/fixed).
- Comment on [#3](https://github.com/TimSimpsonJr/cross-model-review/issues/3) noting
  worktree-isolated reviews as the proper hardening for the §4.4 residual.
