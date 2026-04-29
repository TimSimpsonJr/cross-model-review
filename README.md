# cross-model-review

Claude Code plugin that integrates Codex (via MCP) as an adversarial reviewer in the Superpowers workflow. Eliminates manual copy-paste between Claude and Codex during design/plan/implementation review steps. Supports overnight autonomous code-fix sessions.

**Status:** v0.1 in design. Brainstorm complete; implementation plan pending.

## What it does

Three review checkpoints fire automatically for code-touching work:

1. **Design review** — after brainstorming writes a design doc, before writing-plans is invoked.
2. **Plan review** — after writing-plans saves an implementation plan; checks for drift from the design.
3. **Implementation review** — after subagent-driven-development completes; reviews the diff against the approved plan.

Plus an opt-in Codex-as-brainstorming-partner mode, and ad-hoc consultations.

For overnight runs, autonomous mode lets Claude+Codex consensus replace user approval at code-only decision gates. UI/UX questions get queued for review, not auto-resolved.

## Design document

See [`docs/plans/2026-04-29-cross-model-review-design.md`](docs/plans/2026-04-29-cross-model-review-design.md) for the full design covering:

- Plugin file structure
- Session state schema
- Three skill flows (plan-review, impl-review, brainstorm-partner) plus ad-hoc
- Trigger system (skill descriptions + CLAUDE.md + hooks)
- Slash command surface
- Code-detection heuristic
- Autonomous mode behaviors
- CLAUDE.md additions

## Requirements

- Claude Code with plugin support
- `superpowers` plugin (provides brainstorming, writing-plans, subagent-driven-development)
- Codex MCP server configured (provides `mcp__codex__codex` and `mcp__codex__codex-reply` tools)

## License

MIT
