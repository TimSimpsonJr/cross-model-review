# Handoff: cross-model-review v0.1 — Subagent-Driven Development kickoff

**Date:** 2026-04-29
**Project:** `cross-model-review` Claude Code plugin (Tim Simpson's project)
**Repo:** `C:\Users\tim\OneDrive\Documents\Projects\cross-model-review\`
**Session duration:** ~Long brainstorming session preceded this handoff. This handoff is for the *next* session, which executes the implementation.

---

## You are picking up where the brainstorm left off

A long brainstorming session produced a complete design doc and a detailed implementation plan with seven rounds of cross-cutting Codex review baked in. Everything's written down. Your job in this fresh session is to **execute the plan** via `superpowers:subagent-driven-development`, dispatching fresh subagents per task with two-stage review after each (spec compliance + code quality).

**You should be able to start cold from this handoff plus the two referenced files.** All context that matters is captured.

## What this plugin is

`cross-model-review` integrates Codex (OpenAI's model, available as MCP via `mcp__codex__codex` and `mcp__codex__codex-reply`) into Claude Code's Superpowers workflow as an adversarial reviewer. Three lifecycle moments:

1. **Design review** — after `brainstorming` writes a design doc, before `writing-plans` runs.
2. **Plan review** — after `writing-plans` saves an implementation plan; checks drift from design.
3. **Implementation review** — after `subagent-driven-development` completes; reviews diff against approved plan.

Plus opt-in `codex-brainstorm-partner` mode (Codex stands in for Tim during brainstorming) and ad-hoc consultations.

Autonomous mode lets Claude+Codex consensus replace user approval at code-only gates for overnight runs.

## Read these two files first

In order:

1. `docs/plans/2026-04-29-cross-model-review-design.md` — the design doc. ~14 sections covering plugin architecture, session state schema, skill flows, trigger system, slash commands, code-detection heuristic, autonomous mode behaviors, CLAUDE.md additions.

2. `docs/plans/2026-04-29-cross-model-review-plan.md` — the implementation plan. **19 tasks**, each with full file contents, verification steps, and commit messages.

The plan references three reusable content blocks (Block A: universal Codex priming, Block B: review-skill bootstrap, Block C: MCP invocation pattern, Block D: response handling). Skill bodies inline these per Approach 1 (lean architecture, no shared `prompts/` directory).

## Decisions Made (locked, do not re-litigate)

- **Plugin location:** own repo at `C:\Users\tim\OneDrive\Documents\Projects\cross-model-review\`. Future GitHub URL: `https://github.com/TimSimpsonJr/cross-model-review` (not pushed yet).
- **Architecture: Approach 1 — lean, three self-contained skills.** No shared prompts directory; each skill is one ~80-line `SKILL.md` file with inlined content.
- **Memory model: per-project, durable until reset.** State file is durable across Claude sessions. ONE Codex thread shared across all invocations per-project until `/cross-model-reset`. NOT per-session as originally framed.
- **Codex sandbox: `read-only`.** Static tracing only; no dynamic execution.
- **Autonomous mode: per-session opt-in, mid-session toggleable.** Three outcomes per decision: resolve internally / defer with default / halt.
- **Codex acts as user stand-in (silent framing in brainstorm-partner; explicit reviewer framing in design/plan/impl review).** All sent with `[MODE: <kind>]` tags.
- **Single Codex thread per project.** Universal priming sent once; bare content + mode tag thereafter. `[CHAIN-BOUNDARY]` markers when active_chain_artifact updates mid-session.
- **No push notifications in v0.1.** Chat output only. Cross-device webhook deferred to v0.2.
- **No JSON config files.** Per-project CLAUDE.md notes are the configuration mechanism for mixed-content repos.
- **No CLAUDE.md self-gating preamble** (per Tim's preference).
- **Hash-based approval invalidation** — body content hashed (frontmatter stripped) at approval; downstream approvals cascade-stale when upstream artifacts change.
- **State schema: 10 fields, flat YAML.** See design doc Section 4.

## Current State

**Repo state:** Six commits on `main` branch. No remote configured yet.

```
b9bc87f  initial design + repo scaffolding
3cb272c  five cross-cutting design fixes
f88a7fe  reset + frontmatter resume tightening
4192ccf  v0.1 implementation plan (19 tasks)
9cd4259  five plan blocker fixes
c56f630  final two plan fixes (late-bound resume, ephemeral status)
```

**Files present:**
- `.gitignore`, `README.md` (placeholder, will be expanded by Task 3), `MANIFEST.md` (initial, expanded by Task 17)
- `docs/plans/2026-04-29-cross-model-review-design.md`
- `docs/plans/2026-04-29-cross-model-review-plan.md`
- `docs/handoffs/2026-04-29-cross-model-review-sdd-handoff.md` (this file)

**Not yet present (will be created by the 19 tasks):**
- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
- `skills/codex-plan-review/SKILL.md`, `skills/codex-impl-review/SKILL.md`, `skills/codex-brainstorm-partner/SKILL.md`
- `commands/cross-model-{autonomous-on,autonomous-off,skip,review-now,setup,status,reset}.md` (7 files)
- `hooks/hooks.json` (or equivalent hookify rules — see Task 16 for branching logic)
- `LICENSE`, `CHANGELOG.md`
- Updated README.md and MANIFEST.md

## What Remains

### Setup (do first)

1. Confirm you're in the repo: `pwd` should show `/c/Users/tim/OneDrive/Documents/Projects/cross-model-review`.
2. Read both plan files (design doc first, then implementation plan).
3. **Branch decision: Tim chose to work on main directly.** Don't create a feature branch. The repo is fresh and dedicated to this plugin — the implementation IS the entire repo's content. Each task commits directly to main.
4. Verify Codex MCP is available in the session by checking that `mcp__codex__codex` appears in the tool list. (If not, the plugin's primary integration won't work, but the plan's tasks don't *require* Codex during implementation — only at runtime once installed.)

### Execute the 19 tasks via subagent-driven-development

Invoke `superpowers:subagent-driven-development`. The skill will:
- Have you read the plan file and extract all 19 tasks (already done — they're sequential and well-numbered).
- Create a TodoWrite with all 19 tasks.
- Dispatch fresh implementer subagent per task with the task's full text + relevant block references from the plan.
- After each task: dispatch spec compliance reviewer, then code quality reviewer.
- Loop until all 19 are complete.

**Tasks at a glance:**

1. Plugin manifest (`.claude-plugin/plugin.json`)
2. Marketplace entry (`.claude-plugin/marketplace.json`)
3. README expansion (replaces placeholder)
4. LICENSE (MIT)
5. CHANGELOG.md
6. Skill: `codex-plan-review` (handles design-review + plan-review modes)
7. Skill: `codex-impl-review`
8. Skill: `codex-brainstorm-partner`
9–15. Seven slash commands (autonomous-on, -off, skip, review-now, setup, status, reset)
16. Hooks (with native-vs-hookify-vs-disabled decision branch — see plan)
17. MANIFEST.md update
18. (User manual step — appending CLAUDE.md additions; covered by `/cross-model-setup` slash command)
19. Manual smoke test

### After tasks complete

- Dispatch final code reviewer subagent for the entire implementation (per the SDD skill's flow).
- Then `superpowers:finishing-a-development-branch`.
- Manual smoke test (Task 19) is for Tim to run; it requires installing the plugin into a sandbox project and walking through a synthetic flow.

## Open Questions

None substantive. Brainstorming closed all open issues across seven rounds of Codex review. The remaining "judgment calls" during implementation:

- **Task 16 hook schema:** the plan specifies a behavioral acceptance gate. The implementer must verify Claude Code's native hooks schema before writing `hooks/hooks.json`. If schema doesn't support the matchers used, fall back to hookify rules in `/cross-model-setup`. If neither path works, ship with hooks-disabled and document as known limitation. Don't block the rest of the plan on this.

- **Frontmatter field name conventions:** the plan uses `codex_design_review_status`, `codex_design_review_approved_hash`, `codex_thread_id`. If during implementation you find that one of the upstream skills (writing-plans, brainstorming) uses a colliding field name, namespace differently. Unlikely but possible.

## Context to Reload

### Tim's setup

- Windows 11 with bash via Git Bash. Forward slashes work in path arguments to bash tools.
- Python 3.12 at `C:\Users\tim\AppData\Local\Programs\Python\Python312\python.exe` — not on PATH in bash; use full path or `python -c` via PowerShell if needed. Probably not needed for this implementation since it's all markdown.
- Node.js at `C:\Program Files\nodejs\node.exe` — not on PATH in bash. Probably not needed.
- `jq` may or may not be installed. If `jq . file.json` fails, fall back to `python -m json.tool < file.json` via the full Python path.
- The user's email is `tim@timsimpsonjr.com`. Git config in this repo is already set.

### Plugin doctrine reminders (Tim's global CLAUDE.md preferences)

- **Coding-task artifacts (design docs, plans, in-repo docs) do NOT need prose-craft.** Em-dashes and technical phrasing are fine. The design doc and plan are coding-task artifacts.
- **MANIFEST.md is required for owned repos.** Cross-model-review is owned (`TimSimpsonJr` namespace), so keep MANIFEST.md current. Task 17 explicitly updates it.
- **Don't modify upstream Superpowers skills.** The whole design respects this — `cross-model-review` layers via skill descriptions, CLAUDE.md additions, and hooks. No changes to brainstorming/writing-plans/subagent-driven-development upstream.

### Codex feedback rhythm

The brainstorming session ran with Tim copy-pasting Claude's section outputs to Codex (in Codex's own ChatGPT/CLI session) and pasting Codex's feedback back. Codex caught real issues at every section. **For this implementation phase, Codex review is NOT required at every task** — the plan was already vetted through seven rounds. Just execute.

If Tim wants Codex to review specific tasks during implementation, he'll ask explicitly. Don't proactively engage Codex for individual implementation tasks unless asked.

### Ad-hoc gotchas already discovered

- Markdown skills don't have unit tests in the traditional sense. The plan's "verification" steps use `jq`, `head`, and visual frontmatter inspection — adapted from TDD principles.
- Block C's MCP invocation includes a **late-bound frontmatter resume check**: when `state.codex_thread_id` is null, look at the artifact's frontmatter for a thread_id BEFORE creating a new thread. This makes the manual recovery path work after multi-candidate ambiguity. Don't lose this when you write the skill bodies.
- Block B's bootstrap has explicit PERSISTED-vs-EPHEMERAL branching at the top. Read-only / projectless contexts use in-conversation markers; only writable contexts touch disk. This is required for graceful degradation.
- Active-chain anti-flip-flop guard must compute heuristic FIRST, then override BEFORE early exit. Order matters.
- `chain_status: "completed"` only after `gh pr create` succeeds in autonomous mode. Failed PR creation transitions to `halted`.

### Useful commands during implementation

```bash
# verify a JSON file
jq . path/to/file.json

# fallback if jq missing
"/c/Users/tim/AppData/Local/Programs/Python/Python312/python.exe" -m json.tool < path/to/file.json

# inspect frontmatter
head -20 path/to/SKILL.md

# git history
cd /c/Users/tim/OneDrive/Documents/Projects/cross-model-review
git log --oneline
```

### When in doubt

- **Defer to the plan.** The plan has full content for every file. Where a task says "[Block X: see implementation plan reference]", inline the corresponding Block from the top of the plan into the actual file body.
- **Defer to the design doc** for any nuance the plan doesn't fully spell out. The plan references design doc sections by number throughout.
- **Don't add features.** v0.1 scope is locked. Forward-looking ideas go in CHANGELOG's "future work" notes, not into v0.1 files.

## Kickoff command for the new session

After reading this handoff and the two plan files, start with:

```
I'm picking up the cross-model-review plugin implementation. Brainstorm and plan are complete (commits b9bc87f through c56f630). Working on main directly, no feature branch. About to invoke superpowers:subagent-driven-development to execute the 19-task plan at docs/plans/2026-04-29-cross-model-review-plan.md.

[Then invoke the SDD skill]
```

That's it. Good luck.
