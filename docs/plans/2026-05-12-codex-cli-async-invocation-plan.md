---
name: 2026-05-12 codex CLI async invocation (v0.3.0)
description: Replace synchronous MCP-based Codex invocation with async CLI invocation (`codex exec` via Bash `run_in_background`) across ALL four Codex paths (plan-review, impl-review, brainstorm-partner, ad-hoc) to bypass Claude Code's UI watchdog that kills long-running MCP tool calls. Investigation handoff lives at docs/handoffs/2026-05-12-codex-impl-review-crash-fixes.md; this plan supersedes it.
---

# Codex CLI async invocation (v0.3.0)

**Investigation source:** [`docs/handoffs/2026-05-12-codex-impl-review-crash-fixes.md`](../handoffs/2026-05-12-codex-impl-review-crash-fixes.md) and the in-session debugging chain that supersedes it. The handoff's "size guards" diagnosis was wrong — the actual root cause is Claude Code's UI watchdog declaring the worker process dead after ~10–12 min of synchronous MCP call blocking. Filed upstream as [anthropics/claude-code#58480](https://github.com/anthropics/claude-code/issues/58480).

**Goal:** every Codex invocation across all four paths in the plugin uses Bash-async CLI (`codex exec` with `run_in_background: true`) instead of MCP tool calls. MCP dependency drops entirely from the plugin.

**Validated** in this session: a multi-file plan-review at `xhigh` reasoning that previously hung MCP completed cleanly via the async CLI pattern in 14:44 wall time, exit 0, 5 KB structured review, 7 categorized findings. Process exited cleanly; no orphan; no watchdog error. The same pattern dogfooded successfully on two rounds of review of this very plan.

**Scope:** all four skill/path bodies + setup/status/skip/review-now/reset commands + design doc + README + CHANGELOG + version bump + package metadata strings.

**Bump:** v0.2.0 → v0.3.0 (minor — substantial internal architecture change, user-facing review contract preserved).

---

## Approach

### New invocation shape (replaces "Codex MCP call" sections)

For each Codex call the skill currently makes:

1. **Pre-generate identifiers and file paths**. Generate a `launch_uuid` (UUID v4) before any I/O. Compute deterministic paths from it:
   - `result_file  = /tmp/cmr-<launch_uuid>-result.txt`
   - `jsonl_file   = /tmp/cmr-<launch_uuid>-events.jsonl`
   - `prompt_file  = /tmp/cmr-<launch_uuid>-prompt.txt`
   - `stderr_file  = /tmp/cmr-<launch_uuid>-stderr.txt`

2. **Compose the prompt content** to `prompt_file` (universal priming on fresh thread + `[MODE: <kind>]` + chain-boundary marker if applicable + artifact content + framing).

3. **Pre-write the state slot** to `state.codex_reviews_in_progress` with `bg_id: "pending"`, `launch_uuid`, `kind`, `branch` (captured from `git rev-parse --abbrev-ref HEAD`), `chain_artifact`, `attempted_thread_id` (the thread_id we're about to resume from, or `null` for fresh threads), `result_file`, `jsonl_file`, `stderr_file`, `started_at`, `status: "in_progress"`. **This commit happens BEFORE the bg launch — narrows the race-window dramatically.** If the state write fails (disk error, permission, etc.), **abort the launch** — post a chat note explaining the failure and exit without invoking Bash. Do NOT launch a bg job we can't track.

4. **Launch via Bash with `run_in_background: true`:**
   - Fresh thread: `codex exec --sandbox read-only --json -C <project-toplevel> -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>`
   - Continuation: same but with `codex exec resume <attempted_thread_id>` instead of `codex exec`
   - Capture the `bash_id` returned by Bash.

5. **Update the state slot** to fill in the captured `bg_id`. If the bg already completed before this write commits, the eventual completion notification can fall back to scanning entries with `bg_id: "pending"` whose `result_file` is now populated on disk.

6. **Post chat note**: *"Codex `<kind>` running in background (typical 5–15 min at `xhigh`). I'll surface findings when complete."*

7. **End the turn.**

### On bg completion (next-turn handling)

When the Bash bg job's completion notification arrives:

1. **Look up the slot** in `state.codex_reviews_in_progress` by `bash_id`. If found, proceed to step 4.
2. **Fallback for the race**: if no direct match, scan slots where `bg_id == "pending"` AND `result_file` exists on disk. If exactly one matches, use it. If multiple match, choose the oldest by `started_at`.
3. If still no match: this notification is for an unrelated bg job (e.g., user's own Bash). Ignore.
4. **Branch on `status`:**
   - `status == "detached"` (user ran `/cross-model-reset` mid-review): check the result file's state — there are four cases to handle, with distinct chat notes for each:
     - **Result file exists and is non-empty + no stale-thread markers in jsonl/stderr** → post chat note *"Detached `<kind>` review for `<chain-artifact>` completed; result at `<result_file>`. Findings NOT routed automatically — review manually if useful."*
     - **Result file missing or empty** → post chat note *"Detached `<kind>` review for `<chain-artifact>` ended with no usable result. See stderr at `<stderr_file>`."*
     - **Stale-thread error in jsonl/stderr** → post chat note *"Detached `<kind>` review for `<chain-artifact>` failed: Codex thread `<attempted_thread_id>` expired. No action needed."*
     - **Result file appears corrupt (non-empty but unparseable)** → post chat note *"Detached `<kind>` review for `<chain-artifact>` completed with corrupt output at `<result_file>`. See stderr at `<stderr_file>`."*
     In all four detached cases: remove the slot from `codex_reviews_in_progress` after the chat note. Do NOT route findings — the user reset specifically to walk away from this review.
   - `status == "in_progress"`: proceed to step 5.
5. **Check for stale-thread error (best-effort).** Scan `result_file`, `jsonl_file`, and `stderr_file` via allowlisted substring matching for the patterns Codex emits when `codex exec resume <attempted_thread_id>` fails — currently observed: `"Session not found for thread_id"` and `"thread not found"`. (The Codex CLI does not document a stable machine-readable error contract for this case as of v0.125.0; treat as a fuzzy signal subject to drift across Codex releases.) If detected, post chat note *"Codex thread `<attempted_thread_id>` has expired. Start a fresh review with `/cross-model-review-now <kind>` (the plugin will create a new thread)."* Set slot's `status: "stale_thread_error"` so `/cross-model-status` can explain; do not auto-recover in v0.3.0. If neither pattern matches but the result is still empty/corrupt, fall through to generic failure handling rather than asserting stale-thread.
6. **Read `result_file`** — Codex's final structured review.
7. **Extract `thread_id`** from `jsonl_file`'s `thread.started` event (only present on fresh-thread calls; on resume calls the thread_id is unchanged from `attempted_thread_id`).
8. **Persist `thread_id`** to the relevant artifact's frontmatter and to `state.codex_thread_id` if this was the first review for the chain. Existing singleton fields (`codex_thread_id`, `active_chain_artifact`, `active_chain_branch`) keep their existing semantics: they represent the *most-recently-completed* chain, not in-flight state.
9. **Remove the slot** from `codex_reviews_in_progress`.
10. **Parse findings** per the existing tag-line spec.
11. **Route findings** per existing routing logic (severity → fix-loop / defer; user-input-flagged → batch-defer; etc.).
12. **If the loop continues**, the next iteration is another async-CLI call via the Approach above.

### Concurrency model (multi-slot)

The plugin tracks all in-flight Codex reviews as a list — multiple can run concurrently across branches, kinds, or even within the same branch with different artifacts. The model **narrows** but does not eliminate the bg-correlation race: under typical operation (one Claude session per project, sequential turns) the pre-write-then-launch sequence makes the race impossible, but concurrent Claude turns on the same project's state file are not fully serialized. The race window is small enough to ship; **state-file locking / CAS discipline is deferred to future work.** State schema:

```yaml
codex_reviews_in_progress:
  - launch_uuid: <uuid v4>             # pre-generated; primary correlation key
    bg_id: <bash_id_or_"pending">      # filled after Bash returns; may briefly be "pending"
    status: in_progress                # in_progress | detached | stale_thread_error
    kind: plan-review                  # plan-review | design-review | impl-review | brainstorm-partner | ad-hoc
    branch: fix/foo                    # capture HEAD branch at launch
    chain_artifact: docs/plans/2026-05-12-foo-plan.md  # or "branch:<branch>" for anchorless impl
    attempted_thread_id: <thread_id or null>  # which thread we tried to resume; null for fresh
    result_file: /tmp/cmr-<uuid>-result.txt
    jsonl_file:  /tmp/cmr-<uuid>-events.jsonl
    stderr_file: /tmp/cmr-<uuid>-stderr.txt
    started_at: 2026-05-12T19:30:00Z
```

### Concurrency control: duplicate-rejection key

In `/cross-model-review-now`, before launching a new review: check `state.codex_reviews_in_progress` for an entry with the same raw `(chain_artifact, branch)` string-pair (any kind). If one exists with `status: in_progress`, reject. Same-chain different-kind launches with identical artifact paths are caught; reviews of different chain artifacts in the same project, or the same artifact on different branches, are legitimately concurrent and allowed.

**v0.3.0 dedup limitation (footgun, documented).** The dedup compares raw artifact paths — it does NOT apply stem-matching (design doc § 9.2). So a plan-review on `docs/plans/foo-plan.md` and a concurrent `/cross-model-review-now impl` (which resolves to `branch:<branch>`) target the same logical chain but have *different* `chain_artifact` strings, so dedup misses the conflict. The user-visible failure mode is **split continuity**: the two reviews run on separate Codex threads instead of sharing one, and downstream resume behavior depends on which thread finishes last. Treat this as a known limitation users can work around manually (don't launch impl while plan is in flight on the same chain); stem-matching dedup is future refinement.

Skills launched via auto-trigger (not `/cross-model-review-now`) apply the same raw-key check during bootstrap — if an in-flight review exists for the same `(chain_artifact, branch)`, the auto-trigger silently dedupes.

### Detach semantics (not cancel)

The plugin does NOT support cancelling in-flight Codex calls in v0.3.0. Killing background processes from the plugin layer is non-trivial on Windows + adds error-handling complexity that isn't worth it for the watchdog-fix release.

`/cross-model-reset` mid-review uses **detach** semantics: in-flight slots are marked `status: detached` (not removed); the bg jobs continue to disk completion; their eventual notifications are recognized via step 4 in the completion flow and surface a "detached completed" chat note rather than being silently dropped.

This explicitly leaks resources: `codex.exe` processes continue running, eventually exit cleanly when Codex finishes (or stay alive if reasoning never converges). Acceptable for v0.3.0 — the same orphan pattern exists today under MCP and is what motivated the upstream issue.

### Stale-thread fallback (regression vs. MCP)

The current MCP-based skills auto-recover from expired Codex threads: try `mcp__codex__codex-reply`; on "Session not found" error, fall back to fresh thread + universal priming + recovery handoff. v0.3.0's async path surfaces the error to the user instead, requiring manual retry via `/cross-model-review-now <kind>`. This is a documented regression — implementing async auto-recovery requires chaining multiple bg launches within one logical review and tracking the original chain across bg_id changes, which is complexity that doesn't materially improve the first-launch case for most users (thread expiry is rare in active sessions).

Future refinement: implement async auto-recovery (slot transitions through bg_ids on stale-thread retry).

### Multi-project / concurrent sessions

Naturally supported:
- Each `codex exec` invocation creates its own session under `~/.codex/sessions/<date>/rollout-...jsonl`.
- Sessions filter by `cwd` on `codex exec resume` by default.
- Per-project state file isolates one project's `codex_reviews_in_progress` from another's.
- Multi-branch on the same project: distinct `branch` field per slot, distinct dedup key, no false rejections.

### Thread continuation

`codex exec resume <SESSION_ID|--last> <new prompt>` is the CLI equivalent of `mcp__codex__codex-reply`. Same threading semantics:
- Loads full prior session state
- Appends new turn
- Per-turn input grows with conversation length; cache (`cached_input_tokens`) mitigates cost
- On expiry: returns error (handled per Stale-thread fallback above)

### Sandbox + config overrides

Same controls as MCP:
- `--sandbox read-only` (matches MCP `sandbox` param)
- `-C <dir>` for working directory (matches MCP `cwd`)
- `-c key=value` for per-call config overrides (matches MCP `config` param)

### Brainstorm-partner integration caveat (with no-op fallback)

`codex-brainstorm-partner` is invoked from inside `superpowers:brainstorming`. Async behavior works because brainstorming pauses for "the user's response" at turn boundaries — brainstorm-partner launches a bg job and ends the turn; brainstorming is already waiting for input across the boundary; on completion next turn, Claude reads Codex's response and feeds it to brainstorming as if the user typed it.

**This integration depends on `superpowers:brainstorming` maintaining its turn-boundary-pause behavior.** If a future version of that upstream skill changes those semantics (e.g., expects synchronous responses within one turn), brainstorm-partner needs revisiting.

**No-op fallback rule (defensive):** before launching the async call, the skill checks for a minimal contract signal — if the brainstorming flow shows evidence that turn-boundary pauses no longer apply (e.g., Claude is expected to produce additional output in the same turn, or the parent skill has signaled non-pausing behavior), brainstorm-partner posts a chat note *"Brainstorming flow does not appear to support async stand-in. Falling back to Claude-only brainstorming for this question."* and exits without launching. Better to skip stand-in than to corrupt the brainstorming flow. Concrete detection heuristic is specified in the skill body (Task 3).

Documented in the skill body preamble + CHANGELOG.

### Ephemeral mode (not supported for async in v0.3.0)

Current plugin documents an "EPHEMERAL mode" fallback for read-only/projectless contexts using in-transcript markers (`[cmr-state: ...]`). The async pattern needs persistent breadcrumbs across turns; the marker mechanism would technically work but is fragile.

v0.3.0 declares ephemeral-mode async reviews **explicitly halted at bootstrap, not silently bypassed**. The bootstrap rule in each skill body becomes:

> If `.claude/` is not writable AND this skill is about to launch a Codex review: post chat note *"This project's `.claude/` directory is not writable. v0.3.0 requires persisted state for async Codex reviews. To proceed, ensure `.claude/` is writable for this project."* Then exit the skill without launching. No MCP fallback in v0.3.0.

All four skill bodies (Tasks 1–3) need this bootstrap rule explicitly added — replacing or augmenting the current EPHEMERAL execution path that relies on in-transcript markers. `commands/cross-model-status.md` (Task 5) must also update its NONE block (which currently promises EPHEMERAL-mode auto-fallback) to reflect the halt-at-bootstrap behavior. Design doc (Task 9) must update its projectless/read-only fallback section similarly.

Re-enabling ephemeral with marker-based breadcrumbs is future refinement.

### What stays the same

- Universal priming text content (`[MODE: <kind>]` tag still drives Codex's behavior).
- `[CHAIN-BOUNDARY]` marker mechanism.
- Tag-line spec for findings.
- Routing logic.
- Existing singleton state fields (`codex_thread_id`, `active_chain_artifact`, `active_chain_branch`) — semantics preserved: they represent the *most-recently-completed* chain; multi-slot list is the new home for in-flight state.
- Issue-filing helper (`gh issue create`).
- Slash commands' core purposes — semantics extended per Tasks 4–8 for in-flight handling.

---

## Tasks

### Task 1: Patch `skills/codex-plan-review/SKILL.md`

**Files:** Modify: `skills/codex-plan-review/SKILL.md`

**Step 1: Verification**

After edits: "Codex MCP call" → "Codex async CLI call" rewritten per Approach; "Response handling loop" gains "On bg completion (next-turn handling)" preamble with the 12-step recovery flow; bootstrap section explicitly halts on non-writable `.claude/` (replacing the prior EPHEMERAL-mode execution path); frontmatter intact; no `mcp__codex__codex*` references remain.

**Step 2: Edits**

A. Replace **Codex MCP call** section with **Codex async CLI call** per Approach. Include exact Bash command shape, file naming via `launch_uuid`, pre-write-then-launch ordering with abort-on-state-write-failure, and the bg_id-update-after step.

B. Add **On bg completion (next-turn handling)** subsection at the top of **Response handling loop**, documenting the 12-step recovery flow including the race-fallback path, detached-status handling with all four result-file states (existing-non-empty / missing-or-empty / stale-thread / corrupt), and stale-thread-error surfacing.

C. **Replace the existing EPHEMERAL execution path in the bootstrap section.** The current "EPHEMERAL: read in-conversation state marker..." path becomes the halt rule from §Approach (Ephemeral mode), **firing immediately after the storage-mode-detection step (current step 1) and before state load / pre-upgrade detection / skip flag check / duplicate-trigger guard / code-detection heuristic / anti-flip-flop guard**. The PERSISTED-mode path remains as today (now also writes/reads `codex_reviews_in_progress`).

D. Update remaining `mcp__codex__codex*` references throughout to CLI equivalents.

**Step 3: Verify**

```bash
grep -c "codex exec" skills/codex-plan-review/SKILL.md      # expect ≥ 3
grep -c "run_in_background" skills/codex-plan-review/SKILL.md  # expect ≥ 1
grep -c "codex_reviews_in_progress" skills/codex-plan-review/SKILL.md  # expect ≥ 2
grep -c "launch_uuid" skills/codex-plan-review/SKILL.md  # expect ≥ 2
grep -c "mcp__codex__codex" skills/codex-plan-review/SKILL.md  # expect 0
```

**Step 4: Commit:** `feat(plan-review): switch to async CLI invocation to bypass watchdog`

---

### Task 2: Patch `skills/codex-impl-review/SKILL.md`

Same shape as Task 1, including: (A) MCP→CLI section replacement, (B) On-bg-completion handler with detached-status case-splitting, (C) explicit EPHEMERAL halt replacing the existing execution path, (D) `mcp__codex__codex*` reference cleanup. Same verify checks. Commit: `feat(impl-review): switch to async CLI invocation to bypass watchdog`.

---

### Task 3: Patch `skills/codex-brainstorm-partner/SKILL.md`

Same shape as Task 1, simpler (no iteration loop). Additional changes specific to this skill:

A. Add the brainstorm-partner integration caveat to skill preamble (parent-skill turn-boundary-pause dependency).

B. **Add the no-op fallback rule**: before launching the async call, the skill checks a minimal heuristic for "is the parent brainstorming flow still in turn-pause mode?" — a concrete check based on the current turn's context (the skill body specifies the exact signal to look for — e.g., the presence of a `superpowers:brainstorming` skill_listing marker for the current invocation, or an in-flight brainstorming state file). If the check fails, post the fallback chat note (per Approach §Brainstorm-partner caveat) and exit without launching.

C. EPHEMERAL halt replacement (per Task 1.C).

D. MCP→CLI section replacement.

Same verify checks. Commit: `feat(brainstorm-partner): switch to async CLI invocation`.

---

### Task 4: Update `commands/cross-model-setup.md`

Replace MCP-server-registration verification with CLI installation verification:

```bash
which codex || { echo "ERROR: codex CLI not found on PATH. Install via: npm install -g @openai/codex"; exit 1; }
codex --version
```

Update surrounding chat-note text. Remove `mcp__codex__codex` references from the ad-hoc documentation; replace with the CLI invocation example (`codex exec` via Bash `run_in_background`). Commit: `feat(setup): verify codex CLI instead of MCP server registration`.

---

### Task 5: Update `commands/cross-model-status.md`

Three changes:

A. **Surface in-flight reviews.** If `state.codex_reviews_in_progress` is non-empty, list each entry with: `kind`, `chain_artifact`, `branch`, elapsed time since `started_at`, `bg_id`, and `status` (`in_progress` / `detached` / `stale_thread_error`).

B. **Update EPHEMERAL documentation.** The command's existing EPHEMERAL-mode description (and any "projectless/read-only future activity" copy) needs to note that async reviews are unsupported in ephemeral mode in v0.3.0; users in those contexts get a chat-note halt rather than auto-fallback.

C. **Rewrite the NONE block.** The status command's NONE block (which today promises EPHEMERAL-mode auto-fallback for future activity in projectless/read-only contexts) becomes: "No `.claude/` state file present in this project. If you invoke a Codex review skill here, it will halt with a chat note explaining the persisted-mode requirement. Either run `/cross-model-setup` to initialize state, or use this plugin from a project context with a writable `.claude/`."

Commit: `feat(status): surface in-flight reviews + halt-on-ephemeral documentation`.

---

### Task 6: Update `commands/cross-model-skip.md`

Document: `/cross-model-skip` queues the skip for the next review trigger; does NOT cancel any in-flight review in `codex_reviews_in_progress`. If the user wants to **detach** from a running review (let it complete to disk but stop tracking), use `/cross-model-reset`. **There is no cancel-and-kill mechanism in v0.3.0.** Commit: `docs(skip): clarify skip is for the next trigger, not in-flight reviews`.

---

### Task 7: Update `commands/cross-model-review-now.md`

Before launching, check `state.codex_reviews_in_progress` for any entry with matching `(chain_artifact, branch)` (any kind) AND `status: in_progress`. If found, reject with a chat note: *"A `<existing-kind>` review for `<chain-artifact>` on branch `<branch>` is already in progress (bg_id `<bash_id>`, started `<ts>`). Same-chain reviews are sequential — wait for it to complete, or run `/cross-model-reset` to detach."* Reviews of different chain artifacts (or same artifact on different branches) proceed in parallel without rejection.

**Note on dedup precision (v0.3.0 limitation):** the dedup key is raw `(chain_artifact, branch)`. The existing stem-matching algorithm (design doc § 9.2) would catch additional edge cases — e.g., plan-review on `docs/plans/foo-plan.md` and impl-review on `branch:<branch>` are technically the same logical chain. v0.3.0 ships with raw-key dedup; stem-matching dedup is a future refinement. Document the limitation in the command's chat-note text.

Commit: `feat(review-now): reject same-chain in-flight launches with raw-key dedup`.

---

### Task 8: Update `commands/cross-model-reset.md`

If `state.codex_reviews_in_progress` has any entry with `status: in_progress` when reset is invoked: warn the user with the list of in-flight reviews and require interactive confirmation. On confirmation, mark each `status: detached` (do NOT remove; do NOT kill the bg job). When the bg job later completes, the completion-handler step 4 will recognize the detached status and surface a "detached completed" chat note.

Document that detached reviews still hold a `codex.exe` process until Codex finishes naturally. **No cancel in v0.3.0.** Commit: `feat(reset): use detach semantics for in-flight reviews with user confirmation`.

---

### Task 9: Update design doc § 5.7 + § 5.9 + projectless/read-only section

**Files:** Modify: `docs/plans/2026-04-29-cross-model-review-design.md`

A. **§ 5.7 universal priming** — content unchanged; add one-line note that priming is passed via the CLI prompt file rather than an MCP parameter.

B. **§ 5.9 invocation contract** — rewrite to describe async CLI pattern: prompt file → `codex exec` with `run_in_background` → result/jsonl/stderr files → multi-slot state → on-completion lookup with bg_id direct match + pending fallback → detach handling → stale-thread surfacing. Add the schema for `codex_reviews_in_progress` slots.

C. **Projectless/read-only section** (search for existing EPHEMERAL coverage) — update to note that async reviews are unsupported in those modes in v0.3.0; persisted mode required.

Commit: `docs(design): document async CLI invocation in § 5.7 / § 5.9 + ephemeral limitation`.

---

### Task 10: Update `README.md`

Add to Requirements: "Codex CLI ≥ 0.125.0 on PATH (`npm install -g @openai/codex`). The plugin invokes Codex via the CLI; the MCP server is no longer used."

Migration note: v0.1/v0.2 used MCP; v0.3.0+ requires the CLI installed (most users have it from the npm package).

Commit: `docs(readme): note codex CLI dependency for v0.3.0`.

---

### Task 11: CHANGELOG `## 0.3.0 — 2026-05-12` entry

Insert after the title preamble, before `## 0.2.0`:

```markdown
## 0.3.0 — 2026-05-12

### Changed
- **All Codex invocation now uses async CLI (`codex exec` via Bash `run_in_background`) instead of synchronous MCP tool calls.** Sidesteps Claude Code's UI watchdog that declared the worker dead after ~10–12 min of MCP-call blocking (see [anthropics/claude-code#58480](https://github.com/anthropics/claude-code/issues/58480)). Same Codex review workload that previously triggered the watchdog now completes cleanly in 10–15 min at `xhigh` reasoning.
- MCP dependency removed. All four Codex paths (plan-review, impl-review, brainstorm-partner, ad-hoc) migrated.
- State file gains `codex_reviews_in_progress` list field — supports multi-branch concurrent reviews within the same project. Each slot tracks `launch_uuid`, `bg_id`, `status` (`in_progress` / `detached` / `stale_thread_error`), `kind`, `branch`, `chain_artifact`, `attempted_thread_id`, file paths, and `started_at`.
- `/cross-model-setup` verifies CLI installation instead of MCP server registration.
- `/cross-model-status` surfaces in-flight reviews; documents EPHEMERAL mode async limitation.
- `/cross-model-review-now` rejects duplicate launches on `(chain_artifact, branch)` match (any kind — same-chain reviews are sequential by design and share one Codex thread).
- `/cross-model-reset` uses **detach** semantics — marks in-flight slots `detached` and surfaces a chat note on eventual completion rather than silently dropping results.

### Caveats / known regressions vs. MCP
- **No cancel-and-kill for in-flight reviews.** v0.3.0 supports detach only. Codex processes continue until they finish naturally. Future refinement.
- **No auto-recovery from expired Codex threads.** Async path surfaces the "Session not found" error and asks the user to retry; MCP version auto-fell-back. Implementing async fallback requires multi-bg chaining; future refinement.
- **EPHEMERAL mode (read-only filesystem / projectless context) is unsupported for async reviews.** Use a normal persisted project context.
- **`codex-brainstorm-partner`'s async behavior depends on `superpowers:brainstorming` pausing at turn boundaries** for stand-in input. If that upstream skill changes semantics, brainstorm-partner needs revisiting.

### Out of scope (deferred)
- Iteration cap, composite size guard, no-re-send-on-iter-≥-2 — proposed in the original investigation handoff but addressed the wrong root cause and are not needed with the watchdog issue resolved at the invocation layer.
- Async auto-recovery on stale Codex threads.
- Cancel-and-kill in-flight reviews.
- Marker-based breadcrumbs for ephemeral-mode async.
```

Commit: `docs(changelog): 0.3.0 entry for async CLI invocation switch`.

---

### Task 12: Version bump + metadata strings

**Files:** Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`

Set `"version": "0.3.0"` in both (re-aligning marketplace.json from drifted 0.1.0). Update description strings from "Codex MCP integration..." to "Codex integration via async CLI invocation..." or similar. Verify with `jq`. Commit: `chore: bump version 0.3.0 and refresh package metadata strings`.

---

### Task 13: Regenerate `MANIFEST.md`

Two changes:
1. Stack section's "Targets Codex MCP" → "Targets Codex CLI (`codex exec` via Bash `run_in_background`)".
2. File tree unchanged unless something else shifted.

Commit (only if changed): `chore(manifest): regenerate for v0.3.0`.

---

### Task 14: Open PR

```bash
git push -u origin fix/impl-review-context-exhaustion

gh pr create --title "feat: switch Codex invocation from MCP to async CLI to bypass Claude Code watchdog" \
  --label "autonomous-safe" \
  --body "<PR body with summary, root cause referencing #58480, validated workaround evidence, what's NOT in this PR (abandoned size-guard work + listed regressions), test plan>"
```

---

## Out of scope (explicit)

- Size guards / iteration cap / no-re-send / MCP overflow handler — wrong root cause; not needed.
- Marker-based ephemeral-mode async — future refinement.
- Bg-job-killing on `/cross-model-reset` — detach only in v0.3.0.
- Async auto-recovery on stale Codex threads — surface to user only in v0.3.0.
- `superpowers:brainstorming` upstream changes — out of our control; caveat documented.

## Self-review note

This PR's own diff: ~3 skill body edits + 5 command updates + design doc + README + CHANGELOG + version bump + manifest. Diff is well within any size threshold that would matter. impl-review of this PR will use the new async mechanism — natural integration test.
