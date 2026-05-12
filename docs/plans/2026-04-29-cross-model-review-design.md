# Cross-Model-Review Plugin — Design Document

**Status:** Brainstorm complete; ready for writing-plans phase.
**Date:** 2026-04-29
**Plugin name:** `cross-model-review`
**Repo:** `https://github.com/TimSimpsonJr/cross-model-review` (to be created)
**Local path:** `C:\Users\tim\OneDrive\Documents\Projects\cross-model-review\`

---

> **Note (post-implementation):** Task 16 took the hookify fallback path — backup-nudge rules ship via `/cross-model-setup` writing `.claude/hookify.cross-model-{plan,impl}-review.local.md` files into the host project. Native Claude Code hooks don't support transcript-pattern matching at Stop events, so any references below to `hooks/hooks.json` (e.g., Section 6, Section 11's layer summary, Section 14's implementation entry point) describe the original design intent. The shipped implementation routes Layer 3 through hookify rule files instead. See MANIFEST.md "Hookify rule delivery" bullet for details.

---

## 1. Goal

Integrate Codex (OpenAI's coding model, invoked via the `codex` CLI in v0.3.0+; previously via MCP in v0.1/v0.2) into the Superpowers workflow as an adversarial reviewer at three lifecycle moments and as an opt-in brainstorming partner. Eliminate the manual copy-paste handoff currently required between Claude and Codex during design and review steps. Enable overnight autonomous code-fix sessions where Claude+Codex consensus replaces user approval for code-only decisions.

The plugin layers on top of Superpowers (`brainstorming`, `writing-plans`, `subagent-driven-development`) without modifying upstream skills.

## 2. Memory model

Per-project, durable until reset. NOT per-Claude-session.

```
Within a Claude session:    one Codex thread, all invocations share it
Across sessions, same project: state file persists; same Codex thread continues
After /cross-model-reset:   fresh thread on next call
Across projects:            entirely separate threads (different state files)
```

Trade-off: Codex's thread accumulates context across multiple tasks unless reset. Mitigated by `[CHAIN-BOUNDARY]` markers and user-controlled `/cross-model-reset`.

## 3. Plugin architecture

### A. Plugin package (ships in the cross-model-review repo)

```
cross-model-review/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── skills/
│   ├── codex-plan-review/SKILL.md
│   ├── codex-impl-review/SKILL.md
│   └── codex-brainstorm-partner/SKILL.md
├── commands/
│   ├── cross-model-autonomous-on.md
│   ├── cross-model-autonomous-off.md
│   ├── cross-model-skip.md
│   ├── cross-model-review-now.md
│   ├── cross-model-setup.md
│   ├── cross-model-status.md
│   └── cross-model-reset.md
├── hooks/
│   └── hooks.json
├── docs/
│   └── plans/
│       └── 2026-04-29-cross-model-review-design.md  (this file)
├── README.md
├── CHANGELOG.md
├── MANIFEST.md
├── .gitignore
└── LICENSE
```

### B. Host-project runtime artifacts (created at runtime in target repos)

```
.claude/cross-model-review.session.local.md            # session state (durable)
.claude/cross-model-review/decisions/                  # per-chain decision logs
   <artifact-basename-without-ext>.md                  # e.g. 2026-04-29-foo-design.md
   branch--<branch-name>--impl-only.md                 # for anchorless impl-review
```

Auto-added to `.gitignore` (owned repos) or `.git/info/exclude` (non-owned), per Tim's MANIFEST.md doctrine.

### C. User's global Claude config

```
~/.claude/CLAUDE.md additions   # ~25 lines, natural-language intent mapping only
```

## 4. Session state schema

**Path:** `.claude/cross-model-review.session.local.md`

**Schema (10 fields):**

```yaml
---
autonomous: false
codex_thread_id: null
active_chain_artifact: null            # path or "branch:<branch-name>" for anchorless impl
active_chain_branch: null              # branch where chain was established
chain_status: null                     # in_progress | completed | halted | null
skip_next_review: false
last_invocation: null                  # ISO timestamp
last_invocation_kind: null             # plan-review | impl-review | brainstorm-partner | ad-hoc | null
impl_review_approved_sha: null         # git HEAD sha at impl-review approval
session_start: 2026-04-29T10:23:00Z
---

# Cross-Model-Review Session State

Auto-managed by the cross-model-review plugin. To reset, run `/cross-model-reset`.
```

**State file is durable.** Loaded on every bootstrap; persists across Claude sessions. Cleared by `/cross-model-reset` (which writes default values; file remains).

### Bootstrap rules

- File created by: state-changing commands (`autonomous-on/off`, `skip`, `reset`, `review-now`), review/brainstorm-partner skill invocations, OR first ad-hoc Codex consultation.
- File NOT created by: `/cross-model-status`, `/cross-model-setup`.
- Frontmatter resume from design/plan doc only consulted when state file is **absent** (truly fresh project, no prior interactions).
- If state file exists, it's authoritative — frontmatter not consulted.

### Chain lifecycle field transitions

The two chain-tracking fields (`chain_status` and `active_chain_branch`) follow these explicit rules. Implementation must wire each transition:

**`chain_status` transitions:**

| From → To | Trigger |
|-----------|---------|
| `null` → `in_progress` | First review of a chain fires (design-review, plan-review, OR impl-review — whichever establishes the chain) |
| `in_progress` → `completed` | impl-review approves AND PR is opened (or branch is merged, detected via `gh pr list --head <branch>` if available) |
| `in_progress` → `halted` | Autonomous-mode halt occurs (Section 9.6 conditions) |
| `halted` → `in_progress` | User invokes `/cross-model-review-now <kind>` to resume the halted chain |
| any → `null` | `active_chain_artifact` updates to a new chain (Section 9.2 transitions) OR `/cross-model-reset` invoked |

**`active_chain_branch` transitions:**

| From → To | Trigger |
|-----------|---------|
| `null` → `<current-branch>` | First review of a chain fires; record `git rev-parse --abbrev-ref HEAD` |
| `<old-branch>` → `<new-branch>` | New chain established on a different branch (per Section 9.2 chain-update rules) |
| any → `null` | `/cross-model-reset` invoked OR `active_chain_artifact` cleared |

Boundary detection in Section 9.2 (branch-switch invalidates chain) reads `active_chain_branch` and compares to current branch. If different → clear chain; next review re-establishes.

### Pre-session activation precedence (autonomous mode)

```
explicit slash command in current message
  > env var (CROSS_MODEL_AUTONOMOUS=true|false)
  > kickoff frontmatter (cross_model_autonomous: true|false)
  > default (autonomous: false)
```

Explicit "off" beats scheduled "on" at every level.

### Projectless / read-only fallback

**v0.1 / v0.2 behavior (retired in v0.3.0):** in contexts without a writable `.claude/` directory, the plugin used ephemeral in-session state via an in-context `[cmr-state: ...]` active-session marker. Frontmatter resume was gated on "no active-session signal at all."

**v0.3.0 behavior:** the async CLI invocation pattern requires persistent breadcrumbs across turns, which the in-transcript marker mechanism cannot reliably carry. v0.3.0 therefore **halts at bootstrap** in non-writable contexts — invoking any review skill in such a project posts a chat note explaining the requirement and exits. There is no MCP fallback path. See § 5.9's "Projectless / read-only filesystems" block for the canonical statement. Re-enabling ephemeral with marker-based async breadcrumbs is possible future work.

## 5. The three skills + ad-hoc

### 5.1 Shared patterns (review skills)

```
1. Bootstrap: read state file (HALT if .claude/ not writable — v0.3.0 has
   no ephemeral fallback; see § 5.9 "Projectless / read-only" block)
2. Check skip_next_review → if set, clear and exit
3. Check duplicate-trigger guard (time-based):
   if last_invocation_kind == this_kind
      AND (now - last_invocation) < 5 seconds
      AND not manual_invocation:
          exit early (duplicate)
4. Chain update: compute new active_chain_artifact
5. Duplicate-in-flight guard: if state.codex_reviews_in_progress has an
   entry with raw (active_chain_artifact, branch) match and
   status: in_progress → silently dedupe (auto-trigger) OR surface chat
   note (manual via /cross-model-review-now).
6. Pre-generate launch_uuid + result/jsonl/stderr/prompt file paths.
7. Compose prompt to prompt_file:
   - Fresh thread: universal priming + [MODE: <kind>] + chain content
   - Continuation: [CHAIN-BOUNDARY] marker if chain_just_changed +
     [MODE: <kind>] + chain content
8. Pre-write state slot (bg_id=pending) BEFORE Bash launch. Abort
   if state write fails.
9. Launch codex exec [resume <thread_id>] via Bash with
   run_in_background: true; capture bash_id; update slot.bg_id.
10. End turn with chat note. Wait for completion notification.
11. On bg completion (next-turn handler): match slot by bg_id (or
    scan pending slots if race), branch on status (in_progress /
    detached / stale_thread_error), parse findings, route per
    severity / cluster, loop or terminate.
```

### 5.2 Brainstorm-partner bootstrap (different — no skip / no duplicate-trigger guard)

```
1. Bootstrap: HALT if .claude/ not writable (same rule as review skills)
2. Load state. Pre-upgrade chain regime detection.
3. No-op fallback: if state.codex_reviews_in_progress already has a
   brainstorm-partner entry for this branch with status: in_progress,
   exit (parent brainstorming hasn't paused for the prior stand-in yet).
4. Pre-generate launch_uuid + file paths.
5. Compose prompt: [MODE: brainstorm-partner] + Claude's question
   (universal priming on first call).
6. Pre-write state slot.
7. Launch codex exec via Bash run_in_background: true; capture bash_id;
   update slot.bg_id.
8. End turn. Parent superpowers:brainstorming flow pauses at its turn
   boundary waiting for "user input."
9. On bg completion: read result, feed it to brainstorming as the
   user's response. Remove slot.
```

### 5.3 `codex-plan-review` (handles design-review AND plan-review)

**Triggers (two distinct points):**
- 5.3a: After brainstorming writes design doc to `docs/plans/`, before invoking writing-plans → mode tag `[MODE: design-review]`.
- 5.3b: After writing-plans saves implementation plan → mode tag `[MODE: plan-review]`.

Both share the same Codex thread, so plan-review can reference the design discussion.

### 5.4 `codex-impl-review`

**Trigger:** After subagent-driven-development completes its final code-reviewer step → mode tag `[MODE: impl-review]`.

**Special case — anchorless impl-review:** If invoked without a prior design or plan in the chain, anchors to `branch:<branch-name>`. Decisions file becomes `branch--<branch-name>--impl-only.md`.

**Findings handled outcome-based:** Group related CRITICAL/IMPORTANT findings; dispatch fix subagents per group (not per finding). MINOR findings logged in PR description as deferred.

### 5.5 `codex-brainstorm-partner`

**Trigger:** Explicit user opt-in ("let codex take over", "let's brainstorm with codex") OR autonomous mode active during brainstorming → mode tag `[MODE: brainstorm-partner]`.

**Silent framing:** Claude doesn't get any plan-review-style priming. Codex's responses arrive as conversational input to Claude's brainstorm flow. Universal priming (sent once on first Codex call in project) tells Codex how to play user-stand-in.

**Termination:** Implicit — when user provides direct chat response or says "I'll take it from here," brainstorm-partner stops being invoked. No state flag.

### 5.6 Ad-hoc consultation

**Owner:** CLAUDE.md routing + direct async CLI call (`codex exec` via Bash `run_in_background`). NOT a skill.

**Trigger:** User says "ask codex about X" / "what does codex think" → Claude composes a prompt file with `[MODE: ad-hoc]` + the question and launches `codex exec resume <state.codex_thread_id>` (or fresh `codex exec` with universal priming if no thread yet) via Bash with `run_in_background: true`, per the **Codex async CLI invocation** pattern in §5.9. On bg completion, Claude surfaces Codex's reply to the user.

**Strictly one-shot:**
- Shares session thread.
- Updates `last_invocation` / `last_invocation_kind = ad-hoc`.
- Does NOT clear `skip_next_review`.
- Does NOT trigger duplicate-guard for review flows.
- Does NOT advance, terminate, or affect any review lifecycle.
- First ad-hoc creates state file (seeds session continuity).

### 5.7 Universal priming (sent once per project, on first Codex call)

In v0.3.0+, the priming is written into the prompt file that `codex exec` reads from stdin, not passed as an MCP `prompt` parameter (which is what v0.1/v0.2 did). The content is unchanged; only the transport differs.

```
You are participating as a second model in a software design and review
session conducted by another model (Claude). Throughout this session, Claude
will send you content at various points — design discussions, plan documents,
code diffs, brainstorming questions. Your role across all of these is to be
a critically-engaged collaborator with strong opinions.

Each message Claude sends you will begin with a [MODE: <kind>] tag indicating
which role to play for that turn. The kinds are:
- brainstorm-partner: respond as the user (Tim) would, with critic
  disposition.
- design-review: adversarial review of a design doc.
- plan-review: adversarial review of an implementation plan, with specific
  attention to drift from the previously-reviewed design.
- impl-review: adversarial review of a code diff against the plan.
- ad-hoc: single-question consultation requested by the user.

Adapt to the tagged mode immediately. The tag is authoritative.

Occasionally Claude will send a [CHAIN-BOUNDARY] marker indicating a new
task has begun. When you see this, treat the upcoming review as a fresh
task — older discussions are background context only.

Modes details:

1. Brainstorming partner: Claude is in a design discussion and asks
   questions. The actual user (Tim) is observing but has asked you to stand
   in. Respond as Tim would: with critic disposition, specific opinions,
   push-back where warranted. Don't just agree. When the brainstorm has
   converged on a design you'd be ready to commit to, signal so explicitly
   ('looks good, write the plan' or similar).

2. Design / plan / diff review: Claude sends you a design doc, plan
   document, or code diff for adversarial review. Find bugs, missing edge
   cases, ambiguous specifications, design flaws, plan deviations, or
   claims that don't match the actual repo. You have read-only access to
   the working directory — verify claims against actual code. Be specific.
   Cite file paths and line numbers. Avoid generic praise. Signal
   convergence with 'looks good' or 'approved' when no further substantive
   concerns.

3. UI/UX surfacing: When you encounter a question that's genuinely a user
   judgment call (visual design, copy, interaction patterns,
   brand-relevant defaults), don't decide it yourself. Surface it: 'this
   is a user decision: <question>'.

If at any point you're missing critical context to give a good response,
say so explicitly and ask Claude to provide what you need.
```

### 5.8 Stale thread fallback

If `codex exec resume <thread_id>` fails (thread not found, expired, rotated):

**v0.1 / v0.2 behavior (MCP-based, retained for documentation):** The skill caught the error, created a new thread via `mcp__codex__codex` with universal priming + compact recovery handoff (active chain, branch, last invocation kind, approval state from artifacts, pending decisions count), updated state, posted chat note explaining the fallback.

**v0.3.0 behavior (async CLI, current):** Stale-thread detection happens in the on-bg-completion handler (each skill's "Response handling loop → On bg completion" subsection) via best-effort substring matching of `"Session not found for thread_id"` / `"thread not found"` in result/jsonl/stderr files. On detection: the slot is marked `status: "stale_thread_error"`, a chat note surfaces the failure with retry guidance, and `/cross-model-status` can explain. **Auto-recovery is NOT implemented in v0.3.0** — the user manually retries via `/cross-model-review-now <kind>` to create a fresh thread. This is a documented regression from v0.1/v0.2's auto-fallback; implementing async auto-recovery requires chaining multiple bg launches within one logical review and tracking the original chain across bg_id changes. Future refinement.

### 5.9 Codex async CLI invocation (v0.3.0)

v0.3.0 invokes Codex via `codex exec` CLI through Bash with `run_in_background: true`, instead of the synchronous `mcp__codex__codex` / `mcp__codex__codex-reply` MCP tools used in v0.1/v0.2. The reason is documented in the original investigation handoff (`docs/handoffs/2026-05-12-codex-impl-review-crash-fixes.md`) and the upstream issue [anthropics/claude-code#58480](https://github.com/anthropics/claude-code/issues/58480): Claude Code's UI watchdog kills the worker after ~10–12 min of synchronous MCP tool-call blocking, which is below what reasoning-heavy Codex calls realistically need at `xhigh` reasoning effort.

**Invocation pattern (replaces v0.1/v0.2's MCP shape):**

1. Skill generates a `launch_uuid` (UUID v4) and computes deterministic file paths for prompt, result, jsonl events, and stderr.
2. Skill composes the prompt content into `prompt_file` — universal priming (on fresh thread) + `[MODE: <kind>]` + chain-boundary marker (if applicable) + artifact content + framing.
3. Skill pre-writes a new entry to `state.codex_reviews_in_progress` with `bg_id: "pending"`, `status: "in_progress"`, `kind`, `branch`, `chain_artifact`, `attempted_thread_id`, file paths, and `started_at`. **Pre-writing BEFORE the bg launch narrows the bg-correlation race.** If the state write fails, the skill aborts the launch.
4. Skill invokes Bash with `run_in_background: true`:
   - Fresh thread: `codex exec --sandbox read-only -C <project> --json -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>`
   - Continuation: `codex exec resume <thread_id> --sandbox read-only -C <project> --json -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>`
5. Skill updates the slot's `bg_id` with the actual `bash_id` returned by Bash, posts a chat note, and ends the turn.
6. On bg completion notification (subsequent turn): the on-bg-completion handler looks up the slot by `bash_id` (or falls back to scanning pending slots whose result_file exists, for the rare race case), reads the result file, parses findings, and routes them per the skill's normal flow. See § 5.8 for stale-thread error handling.

**Multi-slot concurrency:** `state.codex_reviews_in_progress` is a list, supporting multiple in-flight reviews per project (across branches, kinds, or artifacts). Duplicate launches for the same `(chain_artifact, branch)` raw string-pair are rejected by `/cross-model-review-now` and auto-trigger dedup paths. Raw-key dedup is a v0.3.0 limitation; stem-matching is future refinement (see CHANGELOG).

**Detach (no cancel):** `/cross-model-reset` marks in-flight slots `status: "detached"` rather than removing them. The bg jobs continue to disk completion; their eventual notifications surface a "detached completed" chat note. v0.3.0 has no cancel-and-kill mechanism.

**Sandbox + config controls (unchanged from v0.1/v0.2's MCP shape):**
- `cwd` (via `-C <dir>`): project root from `git rev-parse --show-toplevel`.
- `sandbox` (via `--sandbox read-only`): Codex can read files, run grep/git/find; cannot write or run mutating commands.
- Per-call config overrides (via `-c key=value`): same capability as MCP's `config` parameter (e.g., `-c model_reasoning_effort=medium` for plugin calls if needed in the future).

**Projectless / read-only filesystems (no async support in v0.3.0):** The async pattern requires persistent breadcrumbs across turns, which depend on a writable `.claude/`. The earlier "EPHEMERAL mode" fallback documented in v0.1/v0.2 (in-transcript markers) is **explicitly halted at bootstrap** in v0.3.0 — invoking a review skill in such a context posts a chat note explaining the limitation and exits. Re-enabling ephemeral with marker-based async breadcrumbs is possible future work.

## 6. Trigger system

### 6.1 Three layers

1. **Layer 1 — Skill descriptions (primary).** Each skill's `description` frontmatter is written so `using-superpowers` picks it up at the right moments.
2. **Layer 2 — CLAUDE.md (natural-language intent).** ~25-line addition for routing user phrases to commands. Does NOT restate skill behavior.
3. **Layer 3 — Hooks (backup nudges).** Two Stop-event hooks in `hooks/hooks.json`. Inject reminder context if a lifecycle moment passes without the corresponding skill firing. Never mutate state.

### 6.2 Hook contracts

- **Hook A:** detects "saved to docs/plans/" patterns; nudges if `cross-model-review:codex-plan-review` wasn't invoked since.
- **Hook B:** detects subagent-driven-development completion; nudges if `cross-model-review:codex-impl-review` wasn't invoked since.
- Both check `state.skip_next_review` before injecting; stay silent if set.
- Both are best-effort — depend on transcript regex matching; advisory only. Layers 1 and 2 carry primary load.

### 6.3 Failure modes

| Failure | Behavior |
|---------|----------|
| Skill description + hook both fire (double trigger) | Same-kind + 5-second window dedupe; second invocation exits early. |
| Claude forgets to invoke (all three layers miss) | User invokes `/cross-model-review-now <kind>` manually. |
| False positive (writing-plans for non-code plan) | Code-detection heuristic in skill body catches; exits with chat note. |
| Codex CLI unavailable (`which codex` fails, Bash launch errors, etc.) | Skill posts chat note; in interactive mode, continues without review; in autonomous mode during a review gate, **halts** (Section 9.6). |
| User skipped, then asks why | `/cross-model-status` shows skip flag was honored. |
| Skip + paired triggers (3.2a/3.2b) | Skip applies to whichever fires next; Claude announces what's skipped vs still armed. |

## 7. Slash commands

Seven commands. All bootstrap state on first stateful action. Status and setup are pure-read (do not create state file).

| Command | Effect |
|---------|--------|
| `/cross-model-autonomous-on` | `state.autonomous = true` |
| `/cross-model-autonomous-off` | `state.autonomous = false` |
| `/cross-model-skip` | `state.skip_next_review = true`. Announce what's armed. One-shot. |
| `/cross-model-review-now <kind>` | Manually invoke named flow. `<kind>` ∈ {design, plan, impl}. Bypasses duplicate-guard; bypasses skip without consuming it. Requires unambiguous artifact target. |
| `/cross-model-setup` | First-run install: verify Codex CLI installation (`which codex`, version ≥ 0.125.0), print/apply CLAUDE.md additions, idempotent. |
| `/cross-model-status` | Plain-language state report (Section 9.5). Read-only. |
| `/cross-model-reset` | Write fresh-defaults state file. Frontmatter resume stays suppressed as long as the state file exists — including after this reset (the file remains, just with default values). The only path to re-enable frontmatter resume is **manual deletion of the state file**, which is rarely needed: typical users either let the existing state continue or invoke `/cross-model-reset` again to start a fresh chain in-place. Does not touch design/plan doc content; their `codex_thread_id` frontmatter persists as a fallback for *new* installs/projects without state files but won't be consulted while any state file exists locally. |

### 7.1 `/cross-model-review-now` resolver

`active_chain_artifact` typically anchors to the *design* doc, but the three review kinds need different artifacts. Use this deterministic resolver to find the target artifact for each kind:

**For `design`:**
1. If `state.active_chain_artifact` matches `docs/plans/*-design.md` → use it.
2. Else if explicit path passed (`/cross-model-review-now design <path>`) → use it; verify exists.
3. Else search `docs/plans/` for the most recent `*-design.md` on the current branch; if exactly one in last 24h → use it. If zero or many → ask (interactive) / halt + log (autonomous).

**For `plan`:**
1. If explicit path passed → use it; verify exists.
2. Else if `state.active_chain_artifact` matches `docs/plans/*-design.md` → derive plan path by stripping `-design` suffix. Look for `<stem>.md` or `<stem>-plan.md`. If exactly one exists → use it.
3. Else if `state.active_chain_artifact` matches a plan doc (`*.md` without `-design` suffix, or `*-plan.md`) → use it directly (it is the plan).
4. Else if `state.active_chain_artifact` is `branch:<branch-name>` → plan-review is N/A for anchorless chains; error: *"Anchorless impl-only chain — no plan doc to review. Use `/cross-model-review-now impl` instead."*
5. Else search `docs/plans/` for the most recent plan-shaped doc; same disambiguation as design above.

**For `impl`:**
1. Must be on a feature branch (not default branch).
2. Use `git diff <branch-base>..HEAD` (Section 6: branch-base = merge-base with default branch).
3. If on default branch → ask (interactive) / halt + log (autonomous).
4. If branch-base undeterminable → halt with note.

**General rules:**
- Manual invocation always bypasses duplicate-trigger guard.
- Manual invocation does NOT consume `skip_next_review`.
- Multiple candidates with no clear best → ask in interactive mode; halt + log in autonomous mode.

## 8. Code-detection heuristic

Trigger-biased: skip only when reasonably certain the work is non-code.

### 8.1 Precedence stack

```
1. Manual commands (skip, review-now)
2. Per-artifact frontmatter (cross_model_review: false)
3. Active-chain anti-flip-flop guard (if state.active_chain_artifact is set
   and current trigger is for an artifact in that chain → trigger regardless
   of heuristic outcome)
4. Project CLAUDE.md explicit rules
5. Default heuristic (8.2 below)
```

### 8.2 Default heuristic (Layer 1)

**Content-path globs (treat as content even with code extensions):**
- `**/content/**`, `**/posts/**`, `**/_posts/**`, `**/blog/**`, `**/articles/**`, `**/drafts/**`

**Code-extension allowlist:**
- Source: `.py`, `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.go`, `.rs`, `.rb`, `.java`, `.kt`, `.swift`, `.cs`, `.cpp`, `.c`, `.h`, `.hpp`, `.dart`, `.scala`, `.lua`
- Shell: `.sh`, `.bash`, `.zsh`
- UI frameworks: `.svelte`, `.astro`, `.vue`
- Build: `Dockerfile`, `*.dockerfile`

**Plugin-source paths (drives plugin behavior):**
- `.claude/skills/*/SKILL.md`, `.claude/agents/*.md`, `.claude-plugin/`, `commands/*.md`, `agents/*.md`, `hooks/*.json`, `skills/*/SKILL.md`

**NOT included** (per user decision): `CLAUDE.md`, `AGENTS.md`, `.cursorrules`, `.windsurfrules`, generic `.md` under `.claude/`. Behavior-changing instruction file changes don't auto-trigger; user invokes manually if review is wanted.

**Project markers (config-as-code):**
- `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `*.csproj`, `Gemfile`, `requirements.txt`, `.claude-plugin/plugin.json`, `tsconfig.json`, `astro.config.*`, `next.config.*`, `vite.config.*`, `webpack.config.*`

### 8.3 Decision algorithm

For each file in plan/diff:

1. Matches content-path glob → CONTENT
2. Matches code extension → CODE
3. Matches plugin-source path → CODE
4. Matches project-marker → CODE-CONFIG
5. Else → AMBIGUOUS

| Composition | Outcome |
|-------------|---------|
| Any CODE / CODE-CONFIG | TRIGGER |
| All CONTENT | SKIP |
| Mix CONTENT + AMBIGUOUS | Check project CLAUDE.md; default TRIGGER |
| All AMBIGUOUS | TRIGGER |
| Empty file list, plan-review | TRIGGER (let Codex assess malformed plan) |
| Empty file list, impl-review | SKIP (no changes to review) |

### 8.4 Project-level overrides (Layer 2)

User adds plain-English notes to project CLAUDE.md. Example for a mixed-content repo:

```markdown
## Cross-Model-Review notes for this repo

Code work lives in: src/components/, src/layouts/, src/lib/, scripts/
Content (skip Codex review) lives in: src/content/posts/, src/content/articles/
Always trigger Codex for: package.json, astro.config.*, tsconfig.json
```

Plugin reads notes and applies during heuristic evaluation. No parser; Claude interprets prose.

### 8.5 Manual overrides (Layer 3)

- `/cross-model-skip` — one-shot suppress.
- `/cross-model-review-now <kind>` — force-invoke.
- Per-artifact frontmatter `cross_model_review: false` — opts that single artifact out of review. Works on **both** design docs (suppresses design-review for that doc) **and** plan docs (suppresses plan-review for that plan). Does not propagate up or down the chain — to opt the whole chain out, set the flag on each artifact independently and use `/cross-model-skip` for impl-review (which has no artifact frontmatter).

### 8.6 Autonomous-mode fallbacks

In autonomous mode, the heuristic never blocks for clarification:
- Mix CONTENT + AMBIGUOUS, no project guidance → TRIGGER + log to decisions-pending.
- Files outside project root → TRIGGER + log decision.
- Ambiguous project guidance → TRIGGER + log "consider clarifying CLAUDE.md."

## 9. Autonomous mode behaviors

### 9.1 What "autonomous" means

Three outcomes per decision point:

1. **Resolve internally** — code-only decisions, technical revisions, plan implementation. Continue without user input.
2. **Defer with defensible default** — UI/UX questions Codex tags or Claude classifies. Pick most defensible default, log to `decisions-pending` with handle and reasoning, continue.
3. **Halt** — hard errors with no defensible default. Stop, write halt note, open draft PR if useful work was done, fire notification.

Faking progress is worse than halting.

### 9.2 New-chain detection

Active chain updates (per Section 7.2):

| Trigger | Effect on `active_chain_artifact` |
|---------|-----------------------------------|
| design-review on doc D | Always set to D |
| plan-review on doc P, no chain set | Set to P |
| plan-review on doc P, chain set to A | Stem-match: match → preserve A; mismatch → set to P (new chain) |
| impl-review fires | Never changes chain |
| Branch checked out, different from `active_chain_branch` | Clear chain; next review re-establishes |
| `/cross-model-reset` | Clear chain |

**Stem-matching algorithm:**

```
stem(path) = filename stripped of:
  - leading YYYY-MM-DD- date prefix
  - trailing -design, -plan, -impl suffixes
  - .md extension

stems_match(a, b) = stem(a) == stem(b)
```

When chain updates mid-session, the next Codex call prefixes content with `[CHAIN-BOUNDARY]` marker.

### 9.3 Pending decisions log

**Path:** `.claude/cross-model-review/decisions/<artifact-basename-without-ext>.md` (per active chain). Anchorless impl chains use `branch--<branch-name>--impl-only.md`.

**Entry format:**

```markdown
## decision-2026-04-29-1123-a7b3 — codex-plan-review

**Context:** ...
**Question:** ...
**Default chosen:** ...
**Reasoning:** ...
**Logged at:** 2026-04-29 11:23 EDT

---
```

**Stable handle:** `decision-<YYYY-MM-DD>-<HHMM>-<4char-hash-of-question>`. Used by Claude to identify items the user resolves.

**Lifecycle:**
- Append on deferral.
- Remove on resolution (Claude parses user reply, matches by handle, rewrites file).
- File deleted when empty.
- Contents pasted verbatim into PR description on PR creation.

### 9.4 PR creation flow

When impl-review concludes successfully in autonomous mode:

```bash
gh pr create
```

PR description includes:

```markdown
## Summary
<from plan's goal/architecture sections>

## Codex review status
- design-review: ✅ approved (N rounds)
- plan-review:   ✅ approved (N rounds)
- impl-review:   ✅ approved (N rounds, M findings fixed)

## Decisions deferred to your review
<verbatim contents of per-chain decisions file, or "(none)">

## Codex review limitations
<any error notes — Codex unavailable moments, etc., or "(none)">

## Test plan
<from plan>

🤖 Generated with cross-model-review (Claude + Codex)
```

State transition: `chain_status: in_progress` → `chain_status: completed`.

**Halt-path PRs are draft:** `gh pr create --draft` with explicit "AUTONOMOUS RUN HALTED" header. Distinguishes incomplete work from successful runs.

### 9.5 `/cross-model-status` output

Plain-language report. Anchors to active chain only (no historical approvals).

```
Cross-Model-Review Session Status
─────────────────────────────────

State storage:  PERSISTED  (.claude/cross-model-review.session.local.md)

Mode:           INTERACTIVE  (autonomous mode OFF)

Codex thread:   thread_abc123  (project-scoped, durable until reset; primed at 10:23 on 2026-04-29)
Active chain:   docs/plans/2026-04-29-search-feature-design.md
   Status:       ⏳ IN PROGRESS
   Last call:    11:45  (kind: plan-review)

Approvals (active chain only — hash-validated):
   design-review:  ✅ approved (hash matches)
   plan-review:    ⚠️ STALE (plan doc edited since approval; needs re-review)
   impl-review:    ⏸️ blocked (depends on plan-review)

Skip flag:      NOT ARMED
Pending decisions: 2 items
```

### 9.6 Critical gates and halt rules

**Codex unavailable during any review (design, plan, impl) → HALT in autonomous mode.** Reviews are the autonomous gate; without Codex, no defensible default exists.

| Codex unavailability scope | Autonomous mode | Interactive mode |
|----------------------------|-----------------|------------------|
| brainstorm-partner | Continue without Codex | Continue without Codex |
| ad-hoc | Skip consultation | Skip consultation |
| design/plan/impl review | **HALT** | Post chat note; user decides |

Other halt scenarios (autonomous):
- Git in dirty state at impl-review start.
- subagent-driven-development task fails after retries.
- Branch-base undeterminable.
- Multiple ambiguous artifacts for `/cross-model-review-now`.
- User-bound question with no defensible default.

Halt path: notify (chat + local PushNotification if available), write halt note to per-chain decisions file, open `--draft` PR if useful work was done, exit cleanly.

### 9.7 Approval invalidation (hash-based) and frontmatter persistence

**Per-artifact frontmatter (cross-session bridge):**

Each design or plan doc reviewed by the plugin gets these auto-managed frontmatter fields:

```yaml
---
codex_thread_id: thread_abc123                   # written on first review of this artifact;
                                                 # used by frontmatter resume when state file is absent
codex_design_review_status: approved             # only on design docs; set when design-review approves
codex_design_review_approved_hash: <sha256>      # only on design docs
codex_plan_review_status: approved               # only on plan docs; set when plan-review approves
codex_plan_review_approved_hash: <sha256>        # only on plan docs
---
```

`codex_thread_id` is the load-bearing field for frontmatter resume. Without it, the "fresh project, existing chain" path (state file deleted, project pulled to a new machine, etc.) has nothing to read.

**Impl-review approval lives in state file** (no impl artifact): `state.impl_review_approved_sha = <git HEAD sha>` at approval time.

**Hash computation:** SHA-256 of artifact body content with YAML frontmatter block stripped entirely. Excludes auto-managed `codex_*` fields by construction. Body changes invalidate; frontmatter changes don't.

**Cascade rule:**
- Design stale → plan and impl also stale.
- Plan stale → impl also stale.
- Impl stale (HEAD moved) → just impl.

`/cross-model-status` recomputes on each invocation; surfaces stale state explicitly.

**Frontmatter resume mechanics (re-stated for clarity):**

When state file is absent at bootstrap, the plugin's resume logic uses the **same disambiguation rules as `/cross-model-review-now`** (Section 7.1) to find a candidate artifact. Auto-resume happens only when the candidate is unambiguous:

1. Search `docs/plans/` for design/plan docs on the current branch with a `codex_thread_id` in their frontmatter.
2. Filter to candidates within a recent window (last 24 hours of file modification, OR matching the active branch's most-recent commits — whichever is more conservative).
3. **If exactly one candidate** → attempt to resume that thread. On success, write a fresh state file with the resumed thread_id and the artifact path as `active_chain_artifact`. On failure (thread expired/rotated), fall back to fresh thread + universal priming + recovery handoff (Section 5.8).
4. **If zero candidates** → start fresh thread; no resume needed.
5. **If multiple candidates** → do NOT auto-resume. Start a new fresh thread, and post a chat note:
   > *"Multiple design/plan docs in `docs/plans/` could match this branch. Not auto-resuming to avoid attaching to the wrong chain. Use `/cross-model-review-now <kind> <path>` to manually resume from a specific artifact, or just proceed — a fresh chain will be established on the next review."*

This makes the recovery path safe in repos with multiple historical plan docs. Auto-resume only fires when the answer is obvious.

### 9.8 Recovery from interruption

State persists across interruption (state file, decisions file, design doc frontmatter, git state).

On user's next session:
- New session reads state file → cross-session continuity available.
- User runs `/cross-model-status` to see where things left off.
- User invokes `/cross-model-review-now <kind>` to resume manually OR `/cross-model-reset` for fresh start.

**v0.1 does not auto-resume.** Manual resume only.

### 9.9 Notifications (v0.1)

Chat output only. `PushNotification` MCP tool fires if available (desktop-local).

**No webhook, no cross-device push.** Deferred to v0.2 (sketch in Section 12).

### 9.10 Out of scope for v0.1 autonomous mode

- Auto-resolve git conflicts.
- Run tests in CI (relies on subagent-driven-development's TDD).
- Modify global config.
- Push branches automatically (PR creation pushes; nothing else).
- Respond to PR review comments after opening.
- Detect "complete enough to ship" beyond Codex's impl-review approval.
- Auto-merge PRs.
- Auto-resume after interruption.

## 10. CLAUDE.md additions

Stripped to ~25 lines. Just natural-language intent mapping; no skill behavior restated.

```markdown
## Cross-Model-Review Plugin

Natural-language intent mapping for the cross-model-review plugin:

| User says | Map to |
|-----------|--------|
| "let codex take over" / "go autonomous" | `/cross-model-autonomous-on` |
| "I'll take it from here" / "Tim's back" | `/cross-model-autonomous-off` + end any active codex-brainstorm-partner stand-in for the current brainstorm |
| "skip codex on this" / "skip the review" | `/cross-model-skip` |
| "let's brainstorm with codex" / "let codex weigh in" | Invoke `cross-model-review:codex-brainstorm-partner` |
| "ask codex about <X>" / "what does codex think about <X>" | Launch async ad-hoc consultation via `codex exec resume <state.codex_thread_id>` (or fresh `codex exec` if first call) with `[MODE: ad-hoc]` prefix; written to a prompt file and run via Bash `run_in_background: true` per §5.9 |
| "review the plan with codex" / "have codex check the implementation" | `/cross-model-review-now <kind>` |
| "show me codex status" / "what's codex doing" | `/cross-model-status` |
| "reset codex" / "fresh codex thread" | `/cross-model-reset` |
| "let codex stop reviewing" | NO auto-map. Ask: "Skip just the next review (`/cross-model-skip`), turn off autonomous mode (`/cross-model-autonomous-off`), or both?" |

The plugin's skills handle all behavior internally — bootstrap, mode tagging,
review flows, autonomous handling, approval tracking, recovery. Their
descriptions trigger them at lifecycle moments. The plugin's hooks provide
backup nudges if a trigger is missed. Don't restate skill behavior here.
```

### 10.1 Per-project CLAUDE.md notes (documented in README, not auto-added)

Example for mixed-content repos like deflocksc-website:

```markdown
## Cross-Model-Review notes for this repo

Code work lives in: src/components/, src/layouts/, src/lib/, scripts/
Content (skip Codex review) lives in: src/content/posts/, src/content/articles/
Always trigger Codex for: package.json, astro.config.*, tsconfig.json
```

## 11. Layer architecture summary

| Layer | Job | Where it lives |
|-------|-----|----------------|
| 1: Skill descriptions | Auto-fire skills at lifecycle moments based on conversation context | `description` frontmatter in each skill's `SKILL.md` |
| 2: CLAUDE.md | Map natural-language phrases to commands | ~25 lines in `~/.claude/CLAUDE.md` |
| 3: Hooks | Backup nudges if a lifecycle trigger is missed | 2 Stop-event entries in `hooks/hooks.json` |
| 4: Skill bodies | All actual behavior — flows, mode tagging, state management, autonomous handling, recovery | `skills/*/SKILL.md` bodies |

Layer 4 is the workhorse.

## 12. Out of scope (deferred to v0.2 or later)

- **Cross-device push notifications** — webhook architecture sketched (env-var configurable, payload-minimal: title/message/URL only); add when need is signaled.
- **Auto-resume after interruption** — currently manual; auto could redo work or mis-identify chain state.
- **Sticky pause/resume** — `/cross-model-pause` + `/cross-model-resume` and `paused` field. Deferred until skip-per-trigger ergonomics become painful.
- **Chain-level frontmatter opt-out** — currently three artifact-scoped opts; add chain-level if used often.
- **Multi-chain juggling** — v0.1 supports one active review chain at a time per project.
- **Branch-aware decisions file keying** — current keying uses artifact basename only; add branch to key if collisions become real.
- **Codex thread compaction** — long-running threads accumulate context; rely on user `/cross-model-reset` for v0.1.
- **Dynamic verification mode** — Codex with `workspace-write` to run tests/instrument code during review.
- **`/cross-model-status --all`** — historical approvals across older docs.
- **Auto-detect framework patterns for first-run config** — currently user adds project CLAUDE.md notes manually.
- **PR comment integration** — plugin doesn't respond to PR review comments after opening.
- **CLAUDE.md self-gating preamble** — explicitly rejected per Tim.
- **Push notifications via PushNotification MCP** — if available, fires; otherwise chat-only.

## 13. Major decisions and rationale

| Decision | Rationale |
|----------|-----------|
| Own repo for plugin | Matches existing pattern (cortex, prose-craft, etc.). Clean versioning. |
| Approach 1: lean, three self-contained skills | Auditable; minor duplication acceptable; priming will iterate; easier to delete pieces later. |
| Codex acts as user stand-in (not via sentinels) | Matches user's manual workflow; brainstorming's natural rhythm handles convergence; no protocol design needed. |
| One Codex thread per project (durable) | Honors "same Claude session = same Codex session" + cross-session impl-review continuity. |
| State file is durable recovery state | Resolves contradiction between "active session marker" and "interruption recovery." |
| `[MODE: <kind>]` mode tags on every Codex call | Disambiguates inside long-lived thread; supports clean role-switching. |
| `[CHAIN-BOUNDARY]` markers for new chains | Codex switches task context cleanly while keeping general session context. |
| Hooks advisory-only (no state mutation) | Hooks are nudges; skills are actors. Clear separation. |
| Brainstorm-partner bootstrap differs from review bootstrap | No skip / no duplicate guard; protects legitimate brainstorm turns. |
| Read-only Codex sandbox | Sufficient for static tracing; avoids merge conflicts and role muddle. |
| CLAUDE.md heuristic via project notes (no JSON config) | Plain English; Claude interprets; lower ceremony. |
| Trigger-biased heuristic | "Skip only when reasonably sure non-code"; cost of missing review > cost of unnecessary one. |
| `CLAUDE.md` / `AGENTS.md` etc. NOT in CODE classification | Per user: instruction-file changes don't auto-trigger; user invokes manually. |
| Anchorless impl-review supported | User can invoke Codex review on a branch without going through brainstorm/plan flow. |
| Halt-path PRs are `--draft` | Visually distinct from successful runs. |
| Hash-based approval invalidation | Edits to artifacts after approval correctly downgrade status. |
| 10-field state schema | Each field serves a distinct purpose; flat YAML for readability. |
| Single CLAUDE.md addition (~25 lines) | Skill behavior lives in skill bodies; CLAUDE.md is intent mapping only. |

## 14. Implementation entry point

This design hands off to `writing-plans` to produce the implementation plan. The plan will cover, at minimum:

- `.claude-plugin/plugin.json` and `marketplace.json` content
- Each skill's `SKILL.md` (frontmatter + runbook bodies)
- Each slash command's `*.md` file
- `hooks/hooks.json` content
- README, CHANGELOG, MANIFEST.md, .gitignore content
- Any tests or validation scripts (if any — markdown plugins have minimal test surface)

The implementation plan will include the universal priming text in full, the mode-tag conventions, the bootstrap snippet shared across review skills, and the natural-language intent mapping table. These are the load-bearing artifacts of v0.1.

---

**Brainstorm complete. Eight sections agreed and locked.** Next: writing-plans skill produces the implementation plan from this design.
