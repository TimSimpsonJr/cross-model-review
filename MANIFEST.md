# MANIFEST

## Stack

- Claude Code plugin (markdown-driven, no runtime code)
- Targets Codex MCP (`mcp__codex__codex` / `mcp__codex__codex-reply`)
- Layers on Superpowers (`brainstorming`, `writing-plans`, `subagent-driven-development`)

## Structure

```
cross-model-review/
├── docs/
│   └── plans/
│       └── 2026-04-29-cross-model-review-design.md   # full design doc; brainstorm output
├── README.md                                          # plugin overview, requirements
├── MANIFEST.md                                        # this file
├── .gitignore                                         # OS/editor/build artifacts
└── .git/                                              # repo metadata
```

Implementation files (`.claude-plugin/`, `skills/`, `commands/`, `hooks/`, `LICENSE`, `CHANGELOG.md`) will be added during the writing-plans → subagent-driven-development phase per the design doc's Section 14.

## Key Relationships

- **Design doc → implementation plan**: `docs/plans/2026-04-29-cross-model-review-design.md` is the input to `writing-plans`. The implementation plan will reference Sections 3, 4, 7, 9, and 10 of the design doc directly.
- **Plugin-vs-runtime boundary**: this repo contains plugin package files only. Runtime artifacts (`.claude/cross-model-review.session.local.md`, `.claude/cross-model-review/decisions/`) are created in *target* repos at runtime, never in this plugin's repo.
