# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-04-29

### Added

- Three skills:
  - `codex-plan-review` (handles design-review and plan-review modes).
  - `codex-impl-review` (post-implementation diff review).
  - `codex-brainstorm-partner` (Codex stands in for user during brainstorming).
- Seven slash commands: `cross-model-autonomous-on`, `-autonomous-off`,
  `-skip`, `-review-now`, `-setup`, `-status`, `-reset`.
- Two Stop-event hooks for backup nudging when lifecycle moments pass
  without the corresponding skill firing.
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
