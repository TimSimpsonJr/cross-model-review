# MANIFEST

## Stack

- Claude Code plugin (markdown-driven, no runtime code)
- Targets Codex CLI (`codex exec` / `codex exec resume` via Bash `run_in_background: true`); MCP retired v0.3.0. Sandbox is OS-gated via `uname`: `workspace-write` on Windows (Git Bash), `read-only` on macOS/Linux. Fresh calls pass `--sandbox $SANDBOX_MODE -C <top>`; resume calls (0.125.0 dropped those flags) use `cd <top> && ... -c sandbox_mode="$SANDBOX_MODE"`.
- Layers on Superpowers (`brainstorming`, `writing-plans`, `subagent-driven-development`)

## Structure

```
cross-model-review/
├── .claude-plugin/
│   ├── plugin.json                                # plugin manifest (name, version 0.4.1, author, repo)
│   └── marketplace.json                           # marketplace entry (version 0.4.1)
├── skills/
│   ├── codex-plan-review/SKILL.md                 # design-review + plan-review modes
│   ├── codex-impl-review/SKILL.md                 # post-impl diff review against approved plan
│   └── codex-brainstorm-partner/SKILL.md          # Codex stands in for user during brainstorm
├── commands/                                      # 7 slash commands:
│   ├── cross-model-autonomous-on.md / -off.md     # toggle autonomous mode
│   ├── cross-model-skip.md                        # one-shot suppress next review
│   ├── cross-model-review-now.md                  # manual force-invoke a review
│   ├── cross-model-setup.md                       # first-run setup; env + CLAUDE.md + hookify rules
│   ├── cross-model-status.md                      # state report (read-only; shows host sandbox mode)
│   └── cross-model-reset.md                       # fresh chain in this project
├── docs/
│   ├── plans/                                     # per-version design+plan pairs:
│   │   ├── 2026-06-09-codex-windows-sandbox-fix-design.md   # v0.4.1 design (#9/#5)
│   │   ├── 2026-06-09-codex-windows-sandbox-fix-plan.md     # v0.4.1 implementation plan
│   │   └── …earlier pairs: v0.1 cross-model-review, v0.2 autonomous-issue-filing,
│   │        v0.3.0 async-CLI, v0.3.1 cli-compat-fixes, v0.4.0 review-convergence
│   └── handoffs/                                  # 2 session handoffs (SDD kickoff; impl-review crash investigation)
├── scripts/
│   └── bulk-create-labels.sh                      # one-shot label creation across owned repos (v0.2 §7.2)
├── README.md                                      # install + usage + sandbox/platform notes + privacy
├── CHANGELOG.md
├── MANIFEST.md                                    # this file
├── LICENSE                                        # MIT
└── .gitignore
```

(No static `hooks/` directory: backup-nudge rules are emitted dynamically by `/cross-model-setup` via the hookify plugin — see "Hookify rule delivery" below.)

## Key Relationships

- **Design doc → implementation plan**: each `docs/plans/<date>-<topic>-design.md` is the input to writing-plans; the paired `-plan.md` is the output and references design sections by number. Stem-matched (strip date prefix + `-design`/`-plan` suffix) so the review chain pairs them.
- **Plugin-vs-runtime boundary**: this repo contains plugin package files only. Runtime artifacts (`.claude/cross-model-review.session.local.md`, `.claude/cross-model-review/{decisions,halts}/`) are created in *target* repos at runtime, never committed here (gitignored).
- **OS-gated Codex sandbox (v0.4.1)**: each skill's Step-4 launch block computes `$SANDBOX_MODE` from `uname` — `workspace-write` on Windows to clear the read-only PowerShell block (upstream codex-plugin-cc#57), `read-only` elsewhere. The active mode is surfaced in each skill's Step-6 launch note and in `/cross-model-status`. The in-repo-write residual under workspace-write is accepted; worktree isolation is deferred (#3).
- **cwd invariant**: `codex exec resume` must `cd` to the same toplevel the fresh call used with `-C` (Codex filters sessions by cwd). Both paths pass the OS-gated `$SANDBOX_MODE` (`workspace-write` on Windows, `read-only` elsewhere): the fresh path via the first-class `--sandbox $SANDBOX_MODE` flag (fails loud on CLI drift), resume via the `-c sandbox_mode="$SANDBOX_MODE"` override (fails silent). Documented inline in all 3 launch blocks.
- **Frontmatter persistence as cross-machine bridge**: design/plan doc frontmatter stores `codex_thread_id`, approval status, and approval hashes — lets a fresh install on a new machine resume the chain.
- **Hookify rule delivery (no static `hooks/`)**: native Stop hooks don't support transcript-pattern matching, so `/cross-model-setup` writes hookify-format rules into the host project's `.claude/` at install time. The plugin works without hookify (Layers 1+2 = skill bodies + CLAUDE.md carry the load; hookify Layer 3 is a backup nudge).
- **Hookify rule list duplicated across setup + status**: `cross-model-setup.md` step 8 and `cross-model-status.md` step 5 enumerate the planned rule files; keep in lockstep.
- **Lockstep-duplicated blocks across the review skills** (edited together, verified by `diff`): byte-identical across **all 3** skills — the **universal priming** and the **Step-4 launch block** (OS-gated); byte-identical across the **2 review skills** (`codex-plan-review`, `codex-impl-review`) — the **per-turn verdict-contract block** (brainstorm has no verdict gate) and the **`## Issue filing`** section. NOT lockstep (per-skill): the per-turn **depth header** (mode-specific), the **Step-6 launch note** (per-skill wording), and the **on-bg-completion handler** (parallel-but-not-identical — plan persists `thread_id` to frontmatter, impl updates state only, brainstorm is a shorter variant).
