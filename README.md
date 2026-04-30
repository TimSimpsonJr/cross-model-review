# cross-model-review

Claude Code plugin that integrates Codex (via MCP) as an adversarial reviewer in the Superpowers workflow. Eliminates manual copy-paste between Claude and Codex during design / plan / implementation review steps. Supports overnight autonomous code-fix sessions where Claude+Codex consensus replaces user approval at code-only decision gates.

**Status:** v0.1.0

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

Then run `/cross-model-setup` to verify Codex MCP is configured and apply the global CLAUDE.md additions.

## Slash commands

| Command | Effect |
|---------|--------|
| `/cross-model-autonomous-on` | Enable autonomous mode for this session/project |
| `/cross-model-autonomous-off` | Return to interactive mode |
| `/cross-model-skip` | Suppress the next single review trigger (one-shot) |
| `/cross-model-review-now <kind>` | Manually invoke design / plan / impl review |
| `/cross-model-setup` | First-run setup; verifies Codex MCP, applies CLAUDE.md additions |
| `/cross-model-status` | Plain-language report of current review state |
| `/cross-model-reset` | Start a fresh review chain in this project |

Natural-language phrases also route to commands — see CLAUDE.md additions printed by `/cross-model-setup`.

## Requirements

- Claude Code with plugin support
- `superpowers` plugin installed (provides brainstorming, writing-plans, subagent-driven-development)
- Codex MCP server configured (`mcp__codex__codex` and `mcp__codex__codex-reply` tools available)

## What gets sent to Codex

Privacy / egress note. The plugin forwards the following to OpenAI's Codex via MCP:

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
