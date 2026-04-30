# MANIFEST

## Stack

- Claude Code plugin (markdown-driven, no runtime code)
- Targets Codex MCP (`mcp__codex__codex` / `mcp__codex__codex-reply`)
- Layers on Superpowers (`brainstorming`, `writing-plans`, `subagent-driven-development`)

## Structure

```
cross-model-review/
├── .claude-plugin/
│   ├── plugin.json                                # plugin manifest (name, version, author, repo)
│   └── marketplace.json                           # marketplace entry (Tim's plugin marketplace)
├── skills/
│   ├── codex-plan-review/SKILL.md                 # design-review + plan-review modes
│   ├── codex-impl-review/SKILL.md                 # post-impl diff review against approved plan
│   └── codex-brainstorm-partner/SKILL.md          # Codex stands in for user during brainstorm
├── commands/
│   ├── cross-model-autonomous-on.md               # enable autonomous mode
│   ├── cross-model-autonomous-off.md              # return to interactive mode
│   ├── cross-model-skip.md                        # one-shot suppress next review
│   ├── cross-model-review-now.md                  # manual force-invoke a review
│   ├── cross-model-setup.md                       # first-run setup; verifies env + applies CLAUDE.md + installs hookify rules
│   ├── cross-model-status.md                      # plain-language state report (read-only)
│   └── cross-model-reset.md                       # fresh chain in this project
├── docs/
│   ├── plans/
│   │   ├── 2026-04-29-cross-model-review-design.md   # full design doc
│   │   └── 2026-04-29-cross-model-review-plan.md     # this implementation plan
│   └── handoffs/
│       └── 2026-04-29-cross-model-review-sdd-handoff.md  # SDD kickoff handoff for fresh session
├── README.md                                      # install + usage + privacy note
├── CHANGELOG.md
├── MANIFEST.md                                    # this file
├── LICENSE                                        # MIT
└── .gitignore
```

(No static `hooks/` directory: backup-nudge rules are emitted dynamically by `/cross-model-setup` via the hookify plugin — see "Hookify rule delivery" below.)

## Key Relationships

- **Design doc → implementation plan**: `docs/plans/2026-04-29-cross-model-review-design.md` is the input to writing-plans; `docs/plans/2026-04-29-cross-model-review-plan.md` is the output and references design doc sections by number.
- **Plugin-vs-runtime boundary**: this repo contains plugin package files only. Runtime artifacts (`.claude/cross-model-review.session.local.md`, `.claude/cross-model-review/decisions/`) are created in *target* repos at runtime, never in this plugin's repo.
- **Skill bodies share three reference blocks**: bootstrap snippet (Block B), MCP invocation pattern (Block C), response handling (Block D). All three are inlined per skill (per Approach 1 lean architecture); no shared `prompts/` directory.
- **Frontmatter persistence as cross-machine bridge**: design doc and plan doc frontmatter store `codex_thread_id`, approval status, and approval hashes. These let a fresh install on a new machine resume the chain by reading frontmatter.
- **Hookify rule delivery (no static `hooks/` directory)**: native Claude Code hooks don't support transcript-pattern matching at Stop events, so the plugin ships no static `hooks/hooks.json`. Instead, `/cross-model-setup` writes hookify-format rules into the host project's `.claude/` directory at install time. The plugin works without hookify installed — Layers 1+2 (skill bodies + CLAUDE.md) carry the load and the hookify Layer 3 is a backup nudge only.
- **Hooks are advisory-only**: hookify-emitted rules never mutate state — they only inject reminder prompts when transcript patterns match. Skip-flag respect lives inside the prompt body itself (soft enforcement: the hookify message tells the model to honor the skip flag, but doesn't itself check filesystem state). Skill bodies and CLAUDE.md are the load-bearing layers.
