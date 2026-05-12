# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.3.0 — 2026-05-12

### Changed
- **All Codex invocation now uses async CLI (`codex exec` via Bash `run_in_background: true`) instead of synchronous MCP tool calls.** Sidesteps Claude Code's UI watchdog, which declared the worker dead after ~10–12 min of MCP-call blocking (see [anthropics/claude-code#58480](https://github.com/anthropics/claude-code/issues/58480)). The same Codex review workload that previously triggered the watchdog now completes cleanly in 10–15 min at `xhigh` reasoning effort.
- MCP dependency removed. All four Codex paths (plan-review, impl-review, brainstorm-partner, ad-hoc) migrated to CLI.
- State file gains a `codex_reviews_in_progress` list field — supports multi-branch concurrent reviews within the same project. Each slot tracks `launch_uuid`, `bg_id` (or `"pending"` during the brief launch-to-state-write window), `status` (`in_progress` / `detached` / `stale_thread_error`), `kind`, `branch`, `chain_artifact`, `attempted_thread_id`, file paths (result / jsonl / stderr), and `started_at`.
- `/cross-model-setup` verifies Codex CLI installation (`which codex` + version check) instead of MCP server registration.
- `/cross-model-status` surfaces in-flight reviews and documents the ephemeral-mode async limitation.
- `/cross-model-review-now` rejects duplicate launches on `(chain_artifact, branch)` raw match (any kind — same-chain reviews are sequential by design and share one Codex thread).
- `/cross-model-reset` uses **detach** semantics — marks in-flight slots `detached`, preserves them across the state rewrite, surfaces a "detached completed" chat note on eventual bg completion instead of silently dropping the result. Requires interactive confirmation when in-flight reviews exist.
- `/cross-model-skip` documentation clarifies it does NOT cancel in-flight reviews (skip queues for the next trigger only).

### Caveats / known regressions vs. v0.2
- **No cancel-and-kill for in-flight reviews.** v0.3.0 supports detach only. `codex.exe` processes continue until they finish naturally. Future refinement.
- **No auto-recovery from expired Codex threads.** v0.1/v0.2 auto-fell-back to a fresh thread + recovery handoff on "Session not found" errors. v0.3.0 surfaces the error and asks the user to retry via `/cross-model-review-now <kind>`. Implementing async fallback requires multi-bg chaining within one logical review; future refinement.
- **Ephemeral mode (read-only filesystem / projectless context) is unsupported for async reviews.** Bootstrap halts with a chat note explaining the requirement; use a normal persisted project context.
- **`codex-brainstorm-partner`'s async behavior depends on `superpowers:brainstorming` pausing at turn boundaries** for stand-in input. If that upstream skill changes semantics, brainstorm-partner needs revisiting. A defensive no-op fallback guards against the most obvious failure mode (double-launch) but does not catch all possible upstream regressions.
- **Stale-thread detection is best-effort substring matching** of Codex CLI error patterns (`"Session not found for thread_id"`, `"thread not found"`) — there is no documented stable error contract from Codex CLI as of v0.125.0. Subject to drift across Codex releases.
- **Raw-key duplicate-rejection.** `/cross-model-review-now` and auto-trigger dedup compare raw `(chain_artifact, branch)` string-pairs. A plan-review on `docs/plans/foo-plan.md` and a concurrent `/cross-model-review-now impl` (which resolves to `branch:<branch>`) target the same logical chain but have different `chain_artifact` strings, so dedup misses the conflict — split continuity. Stem-matching dedup is future refinement.

### Out of scope (deferred)
- Iteration cap, composite size guard, no-re-send-on-iter-≥-2 — proposed in the original investigation handoff (`docs/handoffs/2026-05-12-codex-impl-review-crash-fixes.md`) but addressed the wrong root cause and are not needed with the watchdog issue resolved at the invocation layer.
- Async auto-recovery on stale Codex threads.
- Cancel-and-kill in-flight reviews.
- Marker-based breadcrumbs for ephemeral-mode async.
- Stem-matching dedup.

## 0.2.0 — 2026-05-08

### Added
- Structured GitHub issue filing for deferred items, replacing the
  per-chain decisions-file → PR-description-paste mechanism. Two labels:
  `autonomous-safe` (code-only follow-ups) and `design-input-needed`
  (user-judgment items).
- In-skill context-budget probe at impl-review fix-vs-defer decisions.
  Reads transcript size for the current project; routes minor findings
  to inline fix / subagent fix / autonomous-safe issue based on
  estimated context %.
- `state.filed_issues` schema: list of `{number, cluster, kind}` records
  scoped to the active chain.
- `state.context_limit_tokens` field: project-level, default 200000;
  user sets 1000000 for the 1M-context tier.
- `scripts/bulk-create-labels.sh`: one-shot script to create the two
  plugin labels across all owned repos with proper error filtering
  (set -euo pipefail, separate producer call, failures accumulator,
  documented exit codes 0/2/3/4).
- Three-precondition defer-path check (ownership + gh auth + gh issue
  list) at issue-filing time.
- Cluster-based re-flag prevention so deferred-but-unfixed items don't
  trigger Codex's adversarial re-surfacing.

### Changed
- Routing rule restructured: user-input check now outranks severity. A
  CRITICAL UI judgment call defers to a `design-input-needed` issue
  rather than being force-fixed.
- Codex universal priming: parseable tag-line spec
  (`[severity:..., scope:..., cluster:...]`) at the start of each
  finding so the skill body can route reliably.
- `/cross-model-setup` adds new step 3 (gh validation + ownership check)
  and new step 7 (label creation in owned repos). Existing hookify-rule
  install (now step 8) refactored to per-rule check so future rule
  additions land on existing installs.
- `/cross-model-status` shows filed-issues block (new chains) or
  pending-decisions (pre-upgrade chains), plus a one-line hooks-installed
  summary.
- PR description's "Filed for follow-up" section replaces "Decisions
  deferred to your review" for new chains. Bidirectional cross-link:
  each filed issue gets a `gh issue comment` pointing back to the PR.

### Pre-upgrade compatibility
- Chains established under v0.1 (state file lacks `filed_issues` field)
  complete on old behavior — decisions file still written/read,
  PR-description-paste preserved. New chains use new behavior. No
  auto-migration; chains commit to one regime at first establishment.

### Design doc
- `docs/plans/2026-05-08-autonomous-issue-filing-design.md`
  (Codex-approved, hash `38a350fc…3260` in frontmatter)

## [0.1.0] - 2026-04-29

### Added

- Three skills:
  - `codex-plan-review` (handles design-review and plan-review modes).
  - `codex-impl-review` (post-implementation diff review).
  - `codex-brainstorm-partner` (Codex stands in for user during brainstorming).
- Seven slash commands: `cross-model-autonomous-on`, `-autonomous-off`,
  `-skip`, `-review-now`, `-setup`, `-status`, `-reset`.
- Two Stop-event backup-nudge rules for lifecycle moments where the
  corresponding skill failed to fire. Delivered as hookify rule files
  (`.claude/hookify.cross-model-{plan,impl}-review.local.md`) installed
  into the host project by `/cross-model-setup`. Native Claude Code Stop
  hooks don't support transcript-pattern matchers, so hookify is the
  Layer 3 carrier; the plugin works without it (Layers 1+2 still
  operate), but backup nudging requires hookify to be installed.
- Per-project durable session state at `.claude/cross-model-review.session.local.md`.
- Per-chain decisions log at `.claude/cross-model-review/decisions/<artifact-basename>.md`.
- Design / plan doc frontmatter as cross-machine resume bridge
  (`codex_thread_id`, approval status, approval hashes).
- Universal Codex priming sent once per project.
- `[MODE: <kind>]` and `[CHAIN-BOUNDARY]` markers for clean role-switching
  inside long-lived Codex threads.
- Trigger-biased code-detection heuristic with per-project CLAUDE.md
  override notes for mixed-content repos.
- Autonomous mode with three-outcome decision model (resolve / defer / halt).
- Hash-based approval invalidation that downgrades downstream approvals
  when artifacts are edited.
