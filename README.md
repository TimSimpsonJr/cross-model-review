# cross-model-review

Claude Code plugin that integrates Codex as an adversarial reviewer in the Superpowers workflow. Eliminates manual copy-paste between Claude and Codex during design / plan / implementation review steps. Supports overnight autonomous code-fix sessions where Claude+Codex consensus replaces user approval at code-only decision gates.

**Status:** v0.3.0

**v0.3.0 architecture note:** the plugin invokes Codex via the `codex exec` CLI through Bash with `run_in_background: true`, NOT via the Codex MCP server (which v0.1/v0.2 used). The change is to sidestep Claude Code's UI watchdog, which kills synchronous MCP tool calls that block its worker for ~10–12 min — below what reasoning-heavy Codex calls realistically need at `xhigh` reasoning effort. See [anthropics/claude-code#58480](https://github.com/anthropics/claude-code/issues/58480).

## What it does

Three review checkpoints fire automatically for code-touching work:

1. **Design review** — after brainstorming writes a design doc, before writing-plans is invoked.
2. **Plan review** — after writing-plans saves an implementation plan; checks for drift from the design.
3. **Implementation review** — after subagent-driven-development completes; reviews the diff against the approved plan.

Plus an opt-in Codex-as-brainstorming-partner mode, and ad-hoc consultations.

For overnight runs, autonomous mode lets Claude+Codex consensus replace user approval at code-only decision gates. UI/UX questions queue for review (per-chain `decisions-pending.md`), not auto-resolved.

## Install

```bash
/plugin marketplace add TimSimpsonJr/cross-model-review
/plugin install cross-model-review@cross-model-review
```

Then run `/cross-model-setup` to verify the Codex CLI is installed, apply the global CLAUDE.md additions, and (optionally) install the hookify backup-nudge rules into the current project.

## Upgrading from v0.1 / v0.2

**v0.2 → v0.3 upgrade** (architectural — async CLI instead of MCP):

- The plugin no longer uses the Codex MCP server. It uses the `codex` CLI directly via Bash's `run_in_background: true`. Install or upgrade Codex CLI via `npm install -g @openai/codex` (you likely already have it — the MCP server was bundled with the same package).
- If you previously configured Codex as an MCP server in `~/.claude/mcp_servers.json` or per-project `.mcp.json`, you can leave that entry alone (it's unused but not harmful) or remove it.
- Re-run `/cross-model-setup` after upgrading — the verification step now checks for the CLI instead of the MCP server.
- **Known regressions vs. v0.2:** no auto-recovery from expired Codex threads (user manually retries via `/cross-model-review-now <kind>` on "Session not found" errors); no cancel-and-kill for in-flight reviews (`/cross-model-reset` uses detach semantics instead); ephemeral / read-only-filesystem mode is no longer supported for async reviews (use a normal persisted project context). See CHANGELOG for details.

**v0.1 → v0.2 changes** (issue-filing for autonomous defers): pre-upgrade chains (those started before v0.2 landed) continue on v0.1 behavior — the per-chain decisions file is still written and pasted into PR descriptions for those chains. New chains created after upgrade use the v0.2 issue-filing mechanism. No mid-chain switching; no auto-migration.

## Slash commands

| Command | Effect |
|---------|--------|
| `/cross-model-autonomous-on` | Enable autonomous mode for this session/project |
| `/cross-model-autonomous-off` | Return to interactive mode |
| `/cross-model-skip` | Suppress the next single review trigger (one-shot) |
| `/cross-model-review-now <kind>` | Manually invoke design / plan / impl review |
| `/cross-model-setup` | First-run setup; verifies Codex CLI installation, applies CLAUDE.md additions |
| `/cross-model-status` | Plain-language report of current review state |
| `/cross-model-reset` | Start a fresh review chain in this project |

Natural-language phrases also route to commands — see CLAUDE.md additions printed by `/cross-model-setup`.

## Requirements

- Claude Code with plugin support
- `superpowers` plugin installed (provides brainstorming, writing-plans, subagent-driven-development)
- Codex CLI ≥ 0.125.0 on `PATH` (`npm install -g @openai/codex`)
- Writable `.claude/` directory in your project (v0.3.0 requires persisted state for async reviews; ephemeral / projectless mode is unsupported)
- *Optional:* `hookify` plugin — enables Layer 3 backup nudges at Stop events. The plugin works without it; skill bodies and CLAUDE.md routing (Layers 1+2) still carry the load.

## What gets sent to Codex

Privacy / egress note. The plugin forwards the following to OpenAI's Codex via the `codex exec` CLI invocation:

- Design doc content during design-review.
- Implementation plan content during plan-review.
- `git diff` content during impl-review.
- Conversation context for the active Codex thread (cumulative within a project).
- File contents Codex chooses to read via its read-only sandbox (the plugin doesn't pre-package file contents; Codex requests them).

To disable Codex involvement temporarily: `/cross-model-skip` (one-shot). To uninstall: `/plugin uninstall cross-model-review`.

## Per-project CLAUDE.md notes (for mixed-content repos)

Some repos have both code work and content work (e.g., a website repo with blog posts). Add a section like this to that repo's `CLAUDE.md` to tune the auto-trigger heuristic:

```markdown
## Cross-Model-Review notes for this repo

Code work lives in: src/components/, src/layouts/, src/lib/, scripts/
Content (skip Codex review) lives in: src/content/posts/, src/content/articles/
Always trigger Codex for: package.json, astro.config.*, tsconfig.json
```

The plugin reads these notes during code-detection (no parser; plain English Claude interprets). See [design doc Section 8.4](docs/plans/2026-04-29-cross-model-review-design.md) for full heuristic details.

## Design document

[`docs/plans/2026-04-29-cross-model-review-design.md`](docs/plans/2026-04-29-cross-model-review-design.md) — full design covering plugin architecture, session state schema, skill flows, trigger system, slash commands, code-detection heuristic, autonomous mode behaviors, and CLAUDE.md additions.

## License

MIT
