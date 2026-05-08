# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
