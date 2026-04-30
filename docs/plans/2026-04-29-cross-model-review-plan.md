# Cross-Model-Review v0.1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the v0.1 release of the `cross-model-review` Claude Code plugin per the design doc at [`docs/plans/2026-04-29-cross-model-review-design.md`](2026-04-29-cross-model-review-design.md).

**Architecture:** Markdown-driven plugin with three skills, seven slash commands, and two backup hooks. Layers on Superpowers and Codex MCP without modifying upstream skills. Per-project durable state file; per-chain decisions log; design/plan doc frontmatter as cross-machine resume bridge. No runtime code beyond what Claude executes by reading the markdown.

**Tech Stack:** Claude Code plugin format (`.claude-plugin/plugin.json` + `marketplace.json`), markdown skill bodies (frontmatter-driven), markdown slash commands, native Claude Code hooks (`hooks/hooks.json`). No Python, JS, or compiled code. Validation tools used: `jq` for JSON files, visual review for markdown frontmatter.

---

## Adapting TDD for a markdown plugin

There's no `pytest`/`jest` for skill content. Verification steps in each task either:
- Validate JSON with `jq . <file>` (returns 0 + reformatted output if valid).
- Inspect markdown frontmatter with `head -20 <file>` to confirm required fields.
- Visual-review the runbook content for matches against the design doc section it implements.

End-to-end behavior verification happens in the final task (manual smoke test): install the plugin locally, run `/cross-model-setup`, walk through a synthetic brainstorm-to-impl-review flow against a sandbox repo.

## Reference content blocks

Several files reuse content. Defined once here; tasks reference by name.

### Block A: Universal Codex priming (used in skill bodies)

This is sent as the prompt body of the FIRST `mcp__codex__codex` call per project. Tasks 6, 7, 8 (skill bodies) instruct Claude to send this text. Source of truth: design doc Section 5.7. The full text:

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

### Block B: Review-skill bootstrap snippet (shared across `codex-plan-review`, `codex-impl-review`)

Inlined into each review skill body. Source: design doc Sections 3.1, 5.1.

```markdown
## Bootstrap (do this first, every invocation)

1. Read `.claude/cross-model-review.session.local.md`. If absent, check for
   frontmatter resume:
   - Search `docs/plans/` on the current branch for design/plan docs whose
     frontmatter contains `codex_thread_id`.
     - Filter to candidates within last 24h or matching active branch's
       most-recent commits.
     - If exactly ONE candidate → resume that thread (try
       `mcp__codex__codex-reply` with that threadId; on failure, fresh
       thread + recovery handoff per Section 5.8 of design doc).
     - If ZERO candidates → fresh thread; no resume.
     - If MULTIPLE candidates → fresh thread + chat note about ambiguity.
   - In all paths, write a fresh state file before continuing.
2. If `state.skip_next_review == true`: clear flag, post chat note
   ("Codex review skipped per /cross-model-skip"), exit skill.
3. Duplicate-trigger guard: if `state.last_invocation_kind == this_kind`
   AND `(now - state.last_invocation) < 5 seconds` AND not manually
   invoked via `/cross-model-review-now` → exit early (silent dedupe).
4. Run code-detection heuristic (Section 6 of design doc) on the artifact's
   file list. If it says skip, post chat note explaining why and exit.
5. Active-chain rule: if `state.active_chain_artifact` is set and current
   trigger is for an artifact in that chain, ignore heuristic skip
   (anti-flip-flop guard).
```

### Block C: MCP invocation pattern

```markdown
## Codex MCP call

If `state.codex_thread_id` is null (first call this project):
- Invoke `mcp__codex__codex` with:
  - `cwd`: project root (via `git rev-parse --show-toplevel`)
  - `sandbox`: "read-only"
  - `prompt`: <Block A: Universal Codex priming> + "\n\n[MODE: <this-mode>]\n\n<artifact content>"
- Capture `threadId` from response; write to `state.codex_thread_id`.
- Write `codex_thread_id` to the artifact's frontmatter (design or plan doc
  only — impl has no artifact).

Else (continuation):
- If chain just changed (active_chain_artifact updated this invocation),
  prepend "[CHAIN-BOUNDARY] starting new task: <stem>; previous task: <old-stem>\n\n" to content.
- Invoke `mcp__codex__codex-reply` with:
  - `threadId`: `state.codex_thread_id`
  - `prompt`: "[MODE: <this-mode>]\n\n<artifact content>"
- If reply errors with thread-not-found / expired:
  - Reset `state.codex_thread_id = null`
  - Re-invoke this section's first branch (mcp__codex__codex with priming).
  - Add recovery handoff to the priming: "[RESUMING — previous Codex
    thread (id: <old-id>) could not be resumed. Reconstructing context:
    active chain: <stem>, branch: <branch>, last invocation kind:
    <kind>, approvals so far: <derived from artifact frontmatter>,
    pending decisions: <count>. Previous thread's discussion is
    unavailable. Treat current artifact content as primary context.]"
```

### Block D: Response handling pattern

```markdown
## After receiving Codex response

Three branches:

1. **Convergence signal** ("looks good", "approved", "no further concerns",
   similar plain-language signal):
   - For design-review / plan-review / impl-review: APPROVAL. Write
     `codex_<kind>_status: approved` and `codex_<kind>_approved_hash:
     <sha256>` to the artifact's frontmatter. For impl-review, write
     `state.impl_review_approved_sha = <git HEAD sha>`.
   - For brainstorm-partner: HANDOFF. Brainstorming converges naturally
     (this is upstream skill behavior; this skill just relays).
   - Post summary chat note ("Codex approved <kind> after N rounds.").
   - Exit loop.

2. **User-bound question** (Codex tagged "this is a user decision: ..." OR
   Claude classifies as UI/UX):
   - In INTERACTIVE mode: post question in chat with optional
     PushNotification fire; end Claude turn (turn-taking handles pause).
   - In AUTONOMOUS mode: append to per-chain decisions file
     (`.claude/cross-model-review/decisions/<basename>.md`) with stable
     handle (`decision-<YYYY-MM-DD>-<HHMM>-<4char-hash>`); pick most
     defensible default; continue loop with default applied.

3. **Substantive critique** (Codex flagged issues to address):
   - Apply critique to artifact (edit design doc, edit plan, dispatch fix
     subagent for impl-review per Section 5.4 of design doc).
   - Loop back to "Codex MCP call" with revised content.

After every loop iteration: update `state.last_invocation = now()`,
`state.last_invocation_kind = <this-kind>`.
```

---

## Tasks

### Task 1: Plugin manifest (`.claude-plugin/plugin.json`)

**Files:**
- Create: `.claude-plugin/plugin.json`

**Step 1: Define verification**

The file must be valid JSON with required fields: `name`, `description`, `version`. Optional: `author`, `homepage`, `repository`.

**Step 2: Write the file**

```json
{
  "name": "cross-model-review",
  "version": "0.1.0",
  "description": "Codex MCP integration for adversarial review of designs, plans, and implementations. Layers on Superpowers without modifying upstream skills. Supports overnight autonomous code-fix sessions.",
  "author": {
    "name": "Tim Simpson",
    "email": "tim@timsimpsonjr.com"
  },
  "homepage": "https://github.com/TimSimpsonJr/cross-model-review",
  "repository": {
    "type": "git",
    "url": "https://github.com/TimSimpsonJr/cross-model-review"
  },
  "license": "MIT"
}
```

**Step 3: Verify JSON parses**

Run: `jq . .claude-plugin/plugin.json`
Expected: pretty-printed JSON identical in structure to what was written; exit code 0.

**Step 4: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "feat: add plugin manifest"
```

---

### Task 2: Marketplace entry (`.claude-plugin/marketplace.json`)

**Files:**
- Create: `.claude-plugin/marketplace.json`

**Step 1: Define verification**

Valid JSON; matches Claude Code marketplace schema with `plugins` array.

**Step 2: Write the file**

```json
{
  "name": "cross-model-review",
  "owner": {
    "name": "Tim Simpson",
    "email": "tim@timsimpsonjr.com",
    "url": "https://github.com/TimSimpsonJr"
  },
  "plugins": [
    {
      "name": "cross-model-review",
      "source": ".",
      "description": "Codex MCP integration for adversarial review of designs, plans, and implementations.",
      "version": "0.1.0",
      "category": "development-workflow",
      "tags": ["codex", "review", "superpowers", "autonomous"]
    }
  ]
}
```

**Step 3: Verify JSON parses**

Run: `jq . .claude-plugin/marketplace.json`
Expected: pretty-printed JSON, exit 0.

**Step 4: Commit**

```bash
git add .claude-plugin/marketplace.json
git commit -m "feat: add marketplace entry"
```

---

### Task 3: README.md (replace placeholder with v0.1 content)

**Files:**
- Modify: `README.md` (currently a placeholder from initial commit)

**Step 1: Define verification**

README has install instructions, commands list, requirements, link to design doc, and example per-project CLAUDE.md note for mixed-content repos.

**Step 2: Write the file**

```markdown
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
```

**Step 3: Verify**

Run: `head -50 README.md`
Expected: starts with `# cross-model-review`, includes "v0.1.0" and slash command table.

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs: expand README to v0.1 content"
```

---

### Task 4: LICENSE (MIT)

**Files:**
- Create: `LICENSE`

**Step 1: Write the file**

```
MIT License

Copyright (c) 2026 Tim Simpson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

**Step 2: Commit**

```bash
git add LICENSE
git commit -m "docs: add MIT license"
```

---

### Task 5: CHANGELOG.md

**Files:**
- Create: `CHANGELOG.md`

**Step 1: Write the file**

```markdown
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
```

**Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add CHANGELOG with v0.1.0 entry"
```

---

### Task 6: `codex-plan-review` skill (`skills/codex-plan-review/SKILL.md`)

**Files:**
- Create: `skills/codex-plan-review/SKILL.md`

**Step 1: Define verification**

Frontmatter has `name` and `description` matching design doc Section 4.2. Body contains: trigger explanation (5.3a + 5.3b), Block B (bootstrap), Block C (MCP call), Block D (response handling), explicit mode-tagging instruction, frontmatter-write contract.

**Step 2: Write the file**

```markdown
---
name: codex-plan-review
description: Use immediately after a design doc is written to docs/plans/ before invoking writing-plans, OR immediately after writing-plans saves an implementation plan. Reviews the artifact adversarially via Codex MCP. Triggers on phrases like "design doc written", "design saved to docs/plans/", "plan complete", "plan saved to docs/plans/", "ready for implementation", "ready to write the plan".
---

# codex-plan-review

Adversarial review of design docs and implementation plans by Codex via MCP. Same skill, two modes: `design-review` (after brainstorming writes a design doc, before writing-plans is invoked) and `plan-review` (after writing-plans saves an implementation plan, to check drift from the design).

**Announce at start:** "Using codex-plan-review to invoke Codex review."

**Priming for Claude (read this before invoking the loop):** Codex is reviewing this artifact as a peer reviewer. Treat its responses as peer-review feedback — read each critique, evaluate it, and either revise the artifact or push back with reasoning. When Codex signals it has no further substantive concerns, the artifact is finalized.

## Determining mode

If you got here right after `brainstorming` wrote a design doc to `docs/plans/`:
- Mode: `design-review`
- Artifact: the just-written design doc (`docs/plans/<latest>-design.md`)

If you got here right after `writing-plans` wrote a plan doc to `docs/plans/`:
- Mode: `plan-review`
- Artifact: the just-written plan doc

If invoked manually via `/cross-model-review-now <design|plan> [path]`:
- Mode and artifact provided by user; resolve per design doc Section 7.1.

## Bootstrap

[Block B: Review-skill bootstrap snippet — see implementation plan reference]

After bootstrap, if active_chain_artifact updates this invocation (new chain), set the `chain_just_changed` flag for the MCP call below.

## Codex MCP call

[Block C: MCP invocation pattern — see implementation plan reference]

For this skill, `<this-mode>` is `design-review` or `plan-review` per the determination above. The artifact content is the full text of the design or plan doc.

## Response handling loop

[Block D: Response handling pattern — see implementation plan reference]

For this skill specifically:

- On APPROVAL: write the appropriate `codex_*_status` and `codex_*_approved_hash` to the artifact's frontmatter. For design docs, also persist `codex_thread_id`. Compute hash per Section 9.7 of design doc (SHA-256 of body content with frontmatter stripped).
- On REVISE: edit the artifact, then loop. For design-review revisions, edit the design doc directly. For plan-review revisions, edit the plan doc — flag any change that contradicts the previously-approved design as drift, and surface to user (interactive) or log to decisions file (autonomous).

## Termination handoff

After approval:

- **`design-review` complete:**
  - Interactive mode: surface to user — "Codex approved the design. Ready to invoke writing-plans? [Y/n]"
  - Autonomous mode: invoke `superpowers:writing-plans` directly.
- **`plan-review` complete:**
  - Interactive mode: "Codex approved the plan. Ready to proceed to implementation? [Y/n]"
  - Autonomous mode: invoke `superpowers:subagent-driven-development` directly.

In both cases, post summary to chat: "Plan/design approved by Codex after N rounds. Key revisions: [bullet list]."

## State updates

After every loop iteration AND on termination:
- `state.last_invocation = now()`
- `state.last_invocation_kind = <this-mode>`
- `state.chain_status = "in_progress"` (if it was null)
- `state.active_chain_branch = <current branch>` (if it was null)

## Errors and edge cases

- Codex MCP unavailable: post chat note. INTERACTIVE: continue without review (user's call). AUTONOMOUS: HALT (Section 9.6 of design doc).
- Plan has no `Files:` section: trigger anyway; let Codex flag the format issue.
- User invokes `/cross-model-skip` mid-loop: not applicable; skip is consumed pre-bootstrap.
- Codex returns garbage (unparseable response): retry once. Still bad → treat as Codex unavailable.
```

**Step 3: Verify**

Run: `head -10 skills/codex-plan-review/SKILL.md`
Expected: frontmatter visible, `name: codex-plan-review` and `description:` present.

**Step 4: Commit**

```bash
git add skills/codex-plan-review/SKILL.md
git commit -m "feat: add codex-plan-review skill"
```

---

### Task 7: `codex-impl-review` skill (`skills/codex-impl-review/SKILL.md`)

**Files:**
- Create: `skills/codex-impl-review/SKILL.md`

**Step 1: Write the file**

```markdown
---
name: codex-impl-review
description: Use immediately after subagent-driven-development completes its final code-reviewer step, before opening a PR or marking work complete. Reviews the diff against the approved plan via Codex MCP. Triggers on phrases like "all tasks complete", "ready to PR", "implementation complete", "subagent-driven-development finished".
---

# codex-impl-review

Adversarial review of code diffs against the approved plan by Codex via MCP.

**Announce at start:** "Using codex-impl-review to invoke Codex review of the diff."

**Priming for Claude:** Codex is reviewing the implementation against the approved plan. For findings flagged as bugs or plan deviations, dispatch a fix subagent (group related findings into one subagent invocation per group, not one per finding). For findings you disagree with, push back with technical reasoning. Loop until Codex approves or all CRITICAL/IMPORTANT issues are resolved.

## Determining the artifact

The artifact is the diff between branch-base and HEAD on the current feature branch.

- Compute branch-base: merge-base between current branch and default branch (`origin/main` or `origin/master`, fallback to local).
- Compute diff: `git diff <branch-base>..HEAD` (full diff with context).
- File list: `git diff --name-only <branch-base>..HEAD`.

If branch is the default branch or branch-base undeterminable, this skill exits with error per Section 9.6 of design doc.

If `state.active_chain_artifact` is set, the plan to compare against is derived from it (resolver per Section 7.1 of design doc). If anchorless (impl-only chain via `branch:<branch-name>`), no plan to compare — Codex reviews the diff in isolation.

## Bootstrap

[Block B: Review-skill bootstrap snippet — see implementation plan reference]

The code-detection heuristic for impl-review applies the file list from `git diff --name-only`.

## Codex MCP call

[Block C: MCP invocation pattern — see implementation plan reference]

For this skill, `<this-mode>` is `impl-review`. Content includes:
- The plan content (full text of plan doc, if chain has one).
- The diff (full `git diff <branch-base>..HEAD` output).
- Brief framing line: "Review this implementation against the approved plan. Categorize findings as CRITICAL / IMPORTANT / MINOR per universal priming."

## Response handling loop

[Block D: Response handling pattern — see implementation plan reference]

For this skill specifically:

- **Findings handled outcome-based, not finding-based.** Group related findings (same module, same edge case, same design gap). For each group, dispatch ONE fix subagent with all related findings together. A subagent can address one finding or several in one pass.
- **Severity routing:**
  - CRITICAL: dispatch fix subagent immediately, loop.
  - IMPORTANT: dispatch fix subagent immediately, loop.
  - MINOR: log in PR description as "noted, deferred." Don't necessarily fix.
- **Approval condition:** Codex approves OR all CRITICAL/IMPORTANT are fixed.

## Termination handoff

After approval:

- Set `state.impl_review_approved_sha = <git HEAD sha>`.
- Set `state.chain_status = "completed"` (assuming PR will be opened next).
- Interactive mode: "Codex approved the implementation. Ready to open PR? [Y/n]"
- Autonomous mode: open PR per Section 9.4 of design doc:
  - Run `gh pr create` with description per template.
  - Description includes: summary, all three approvals' status, decisions-pending file contents, any error notes, test plan from the original plan, "Generated with cross-model-review" footer.
  - On success: post chat note with PR URL; fire local PushNotification if available.
  - State transition: `chain_status: in_progress → completed`.

## Halt conditions specific to impl-review

- Branch in dirty state at start: ask in interactive; HALT in autonomous (open `--draft` PR if useful work was done; describe in halt note in decisions file).
- subagent-driven-development task fails after retries: surface in chat (interactive); HALT in autonomous.
- Branch-base undeterminable: skip with warning (interactive); HALT in autonomous.
- Codex unavailable: HALT in autonomous mode (Section 9.6 of design doc — review is a critical gate).

## State updates

After every loop iteration AND on termination:
- `state.last_invocation = now()`
- `state.last_invocation_kind = "impl-review"`
- `state.chain_status` updated per termination flow (see above).
```

**Step 2: Verify**

Run: `head -10 skills/codex-impl-review/SKILL.md`
Expected: frontmatter visible.

**Step 3: Commit**

```bash
git add skills/codex-impl-review/SKILL.md
git commit -m "feat: add codex-impl-review skill"
```

---

### Task 8: `codex-brainstorm-partner` skill (`skills/codex-brainstorm-partner/SKILL.md`)

**Files:**
- Create: `skills/codex-brainstorm-partner/SKILL.md`

**Step 1: Write the file**

```markdown
---
name: codex-brainstorm-partner
description: Use during brainstorming when the user has explicitly opted in to having Codex stand in for the user role, OR when autonomous mode is active during a brainstorming session. Triggers on phrases like "let codex take over", "let's brainstorm with codex", "let codex weigh in", "ask codex about this".
---

# codex-brainstorm-partner

Codex stands in for the user during a brainstorming flow. Routes Claude's brainstorming questions to Codex via MCP and feeds Codex's responses back to Claude as conversational input.

**Announce at start:** "Using codex-brainstorm-partner — Codex will stand in for the user this turn."

**No priming for Claude.** Claude doesn't get any peer-review framing. The brainstorming flow proceeds normally; this skill operates between Claude asking a question and Claude reading "the user's response."

## Bootstrap (DIFFERENT from review skills — no skip / no duplicate guard)

1. Read `.claude/cross-model-review.session.local.md` (or use ephemeral fallback).
   - If absent and at least one design/plan doc with `codex_thread_id` exists in `docs/plans/` on the current branch: apply the same disambiguation rule as bootstrap in review skills (Block B). Auto-resume only if exactly one candidate.
2. **Do NOT check `skip_next_review`.** Skip is review-only.
3. **Do NOT apply duplicate-trigger guard.** Each brainstorm turn is independent.
4. **Check `state.paused`** — wait, paused field doesn't exist in v0.1. Section deleted.
   (Field was discussed and removed; no check needed.)

## Codex MCP call

[Block C: MCP invocation pattern — see implementation plan reference]

For this skill, `<this-mode>` is `brainstorm-partner`. Content is Claude's question prefixed with brief context if needed:

```
[MODE: brainstorm-partner]

<the question Claude just asked>
```

If user has provided any "Tim note:" annotations in the session, append:

```
Tim's recent annotations to consider:
<list of recent Tim notes from chat history>
```

## Response handling

Codex's response IS the user's response, semantically. Claude reads it as conversational input and continues brainstorming.

If Codex responds with "this is a UI/UX call I shouldn't make for Tim — surface it: <question>":
- Interactive mode: pause, post in chat with notification, wait for user.
- Autonomous mode: log to per-chain decisions file with defensible default; continue.

If Codex responds with "looks good, write the plan" or convergence signal:
- Brainstorming converges naturally (this is `brainstorming` skill's flow; this skill just relays).
- The hand-off to `writing-plans` happens via `brainstorming`'s checklist.

## Mid-brainstorm user takeover

If the user provides a direct chat response (not invoking this skill) OR says "I'll take it from here" / "Tim's back" / "let me drive":
- This skill is no longer invoked for the rest of the brainstorm flow.
- If user said an explicit takeover phrase, also invoke `/cross-model-autonomous-off` (per CLAUDE.md intent mapping).
- Re-activation requires explicit user re-opt-in.

## State updates

After every invocation:
- `state.last_invocation = now()`
- `state.last_invocation_kind = "brainstorm-partner"`

## Errors

- Codex MCP unavailable: post chat note ("Codex unavailable; brainstorming continues with Claude only"); skill exits silently. NOT a halt scenario — brainstorm-partner is opt-in collaboration, not a gate.
```

**Step 2: Verify**

Run: `head -10 skills/codex-brainstorm-partner/SKILL.md`

**Step 3: Commit**

```bash
git add skills/codex-brainstorm-partner/SKILL.md
git commit -m "feat: add codex-brainstorm-partner skill"
```

---

### Task 9: `cross-model-autonomous-on` command (`commands/cross-model-autonomous-on.md`)

**Files:**
- Create: `commands/cross-model-autonomous-on.md`

**Step 1: Write the file**

```markdown
---
description: Enable autonomous mode for the cross-model-review plugin. Codex consensus replaces user approval at code-only gates.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-autonomous-on

Enable autonomous mode for the cross-model-review plugin in this project.

## Steps

1. Bootstrap state per the universal pattern: read `.claude/cross-model-review.session.local.md`; create with defaults if missing.

2. Set `state.autonomous = true`. Update the state file on disk.

3. If `state.codex_thread_id` is null (no Codex calls yet this project), don't initialize a thread — just record the autonomous flag.

4. Output:

   ```
   Autonomous mode ON.

   Codex consensus will replace user approval at design / plan / impl review gates.
   UI/UX questions will be deferred to the per-chain decisions file with defensible defaults.

   To return to interactive mode: /cross-model-autonomous-off
   ```

5. If a brainstorming flow is currently active in this conversation, also note: "Brainstorming-partner mode will activate automatically for upcoming brainstorm turns."
```

**Step 2: Verify**

Run: `head -10 commands/cross-model-autonomous-on.md`
Expected: frontmatter with `description` and `allowed-tools`.

**Step 3: Commit**

```bash
git add commands/cross-model-autonomous-on.md
git commit -m "feat: add /cross-model-autonomous-on command"
```

---

### Task 10: `cross-model-autonomous-off` command

**Files:**
- Create: `commands/cross-model-autonomous-off.md`

**Step 1: Write the file**

```markdown
---
description: Disable autonomous mode for the cross-model-review plugin. Return to interactive mode where user approves transitions between gates.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-autonomous-off

Return to interactive mode for the cross-model-review plugin.

## Steps

1. Bootstrap state.

2. Set `state.autonomous = false`. Update state file.

3. **Also end any active codex-brainstorm-partner stand-in for the current brainstorm flow.** Don't invoke `codex-brainstorm-partner` again unless user explicitly re-opts in (e.g., says "let codex take over again").

4. Output:

   ```
   Autonomous mode OFF.

   User approval is required for transitions between design → plan → impl gates.
   Codex review still fires automatically for code-touching work.

   To re-enable autonomous mode: /cross-model-autonomous-on
   ```
```

**Step 2: Verify**

Run: `head -5 commands/cross-model-autonomous-off.md`

**Step 3: Commit**

```bash
git add commands/cross-model-autonomous-off.md
git commit -m "feat: add /cross-model-autonomous-off command"
```

---

### Task 11: `cross-model-skip` command

**Files:**
- Create: `commands/cross-model-skip.md`

**Step 1: Write the file**

```markdown
---
description: Suppress the next single Codex review trigger of any kind. One-shot; clears automatically after one trigger fires-or-skips.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-skip

Suppress the next Codex review trigger of any kind. One-shot.

## Steps

1. Bootstrap state.

2. Set `state.skip_next_review = true`. Update state file.

3. Determine what's likely to fire next (based on conversation context — is brainstorming about to end? Did writing-plans just save? Did subagent-driven-development complete?). Identify the most likely next trigger.

4. Output an explicit announcement of what's armed vs still armed:

   ```
   /cross-model-skip armed.

   Next review trigger will be suppressed. Based on current context, the
   most likely upcoming trigger is:
     <best guess: design-review | plan-review | impl-review | none currently expected>

   Still armed for normal triggering after this single skip:
     <list of other review kinds not affected>
     brainstorm-partner (not affected by skip)
     ad-hoc consultations (not affected by skip)

   Skip flag clears automatically after one review trigger fires-or-skips.
   ```

5. The flag is consumed when:
   - Any review skill bootstraps and finds it set (Block B step 2): clear flag, exit skill, post "Codex review skipped per /cross-model-skip" chat note.
   - User invokes `/cross-model-skip` again with the flag already set: refresh the announcement (no double-skip).
   - `/cross-model-reset` invoked: cleared with all other state.
```

**Step 2: Verify**

Run: `head -5 commands/cross-model-skip.md`

**Step 3: Commit**

```bash
git add commands/cross-model-skip.md
git commit -m "feat: add /cross-model-skip command"
```

---

### Task 12: `cross-model-review-now` command

**Files:**
- Create: `commands/cross-model-review-now.md`

**Step 1: Write the file**

```markdown
---
description: Manually invoke a Codex review (design / plan / impl). Bypasses duplicate-trigger guard. Bypasses skip flag without consuming it. Requires unambiguous artifact target.
allowed-tools: Read, Write, Edit, Bash
argument-hint: design|plan|impl [optional path]
---

# /cross-model-review-now

Manually invoke a Codex review. Useful when auto-triggers misfire or when you want to force a review on a specific artifact.

**Usage:**
- `/cross-model-review-now design` — review the active design doc
- `/cross-model-review-now plan` — review the active plan doc
- `/cross-model-review-now impl` — review the current branch's diff vs base
- `/cross-model-review-now <kind> <path>` — explicit artifact path

## Steps

1. Parse the `<kind>` argument. If missing or invalid, output: "Usage: /cross-model-review-now <design|plan|impl> [path]" and exit.

2. Bootstrap state.

3. Resolve the artifact per design doc Section 7.1:

   **For `design`:**
   - If `state.active_chain_artifact` matches `docs/plans/*-design.md` → use it.
   - Else if explicit path passed → use it; verify exists.
   - Else search `docs/plans/` for the most recent `*-design.md` on the current branch within last 24h. If exactly one → use it. Zero or many → ask (interactive) / halt + log (autonomous).

   **For `plan`:**
   - If explicit path passed → use it.
   - Else if `state.active_chain_artifact` matches `*-design.md` → derive plan path: strip `-design`, look for `<stem>.md` or `<stem>-plan.md`. If exactly one exists → use it.
   - Else if `state.active_chain_artifact` matches a plan doc → use it directly.
   - Else if `state.active_chain_artifact` is `branch:<branch-name>` → error: "Anchorless impl-only chain — no plan doc to review. Use `/cross-model-review-now impl` instead."
   - Else search; same disambiguation as design.

   **For `impl`:**
   - Must be on a feature branch.
   - Use `git diff <branch-base>..HEAD`.
   - Default branch → ask / halt.
   - Branch-base undeterminable → halt with note.

4. **Bypass duplicate-guard and skip:**
   - Mark this invocation as `manual_invocation = true` so review skills' bootstrap skip the duplicate-guard.
   - Do NOT consume `state.skip_next_review` — it stays armed for the next AUTO-trigger.

5. Invoke the appropriate skill with the resolved artifact:
   - `design` or `plan` → `codex-plan-review` with mode set accordingly
   - `impl` → `codex-impl-review`

6. Output before invoking:

   ```
   Manually invoking codex-{kind}-review on <artifact>.

   Bypassing duplicate-trigger guard (manual invocation).
   Bypassing skip flag (manual invocation does NOT consume skip — skip stays armed for next auto-trigger).
   ```
```

**Step 2: Verify**

Run: `head -10 commands/cross-model-review-now.md`

**Step 3: Commit**

```bash
git add commands/cross-model-review-now.md
git commit -m "feat: add /cross-model-review-now command"
```

---

### Task 13: `cross-model-setup` command

**Files:**
- Create: `commands/cross-model-setup.md`

**Step 1: Write the file**

```markdown
---
description: First-run setup for the cross-model-review plugin. Verifies Codex MCP, prints CLAUDE.md additions, optionally applies them. Idempotent.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-setup

First-run setup wizard. Verifies the plugin's environment and prints (optionally applies) the CLAUDE.md additions needed for natural-language intent routing.

## Steps

1. **Verify Codex MCP availability.** Check whether `mcp__codex__codex` and `mcp__codex__codex-reply` tools are present in the current session. If absent:
   - Output: "Codex MCP server is not configured. The cross-model-review plugin requires Codex MCP. Configure your MCP server (typically via `~/.claude/mcp_servers.json` or per-project `.mcp.json`) and re-run `/cross-model-setup`."
   - Exit.

2. **Verify Superpowers plugin.** Check whether `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:subagent-driven-development` skills are available. If absent:
   - Output: "Superpowers plugin not detected. Install via `/plugin install superpowers@superpowers-marketplace`. Re-run `/cross-model-setup` afterward."
   - Continue (warn, don't exit — plugin can still operate, just less integrated).

3. **Print the CLAUDE.md additions** that the plugin needs in `~/.claude/CLAUDE.md`:

   ```markdown
   ## Cross-Model-Review Plugin

   Natural-language intent mapping for the cross-model-review plugin:

   | User says | Map to |
   |-----------|--------|
   | "let codex take over" / "go autonomous" | `/cross-model-autonomous-on` |
   | "I'll take it from here" / "Tim's back" | `/cross-model-autonomous-off` + end any active codex-brainstorm-partner stand-in for the current brainstorm |
   | "skip codex on this" / "skip the review" | `/cross-model-skip` |
   | "let's brainstorm with codex" / "let codex weigh in" | Invoke `cross-model-review:codex-brainstorm-partner` |
   | "ask codex about <X>" / "what does codex think about <X>" | Direct `mcp__codex__codex-reply` (or `codex` if first call) with `[MODE: ad-hoc]` prefix; uses active session thread |
   | "review the plan with codex" / "have codex check the implementation" | `/cross-model-review-now <kind>` |
   | "show me codex status" / "what's codex doing" | `/cross-model-status` |
   | "reset codex" / "fresh codex thread" | `/cross-model-reset` |
   | "let codex stop reviewing" | NO auto-map. Ask: "Skip just the next review (`/cross-model-skip`), turn off autonomous mode (`/cross-model-autonomous-off`), or both?" |

   The plugin's skills handle all behavior internally — bootstrap, mode tagging,
   review flows, autonomous handling, approval tracking, recovery. Their
   descriptions trigger them at lifecycle moments. The plugin's hooks provide
   backup nudges if a trigger is missed. Don't restate skill behavior here.
   ```

4. **Ask whether to apply automatically.** "Append the above to `~/.claude/CLAUDE.md` now? [Y/n]"

5. If yes:
   - Read `~/.claude/CLAUDE.md`. Check whether `## Cross-Model-Review Plugin` section already exists.
   - If exists: output "Section already present in CLAUDE.md. No changes made. If you want to refresh, manually delete the section and re-run setup."
   - If absent: append the additions verbatim. Output "Appended ~25 lines to ~/.claude/CLAUDE.md. The plugin is now active."

6. **Suggest per-project notes (optional).** "If this project is a mixed-content repo (some content work, some code work — e.g., a website with a blog), add a per-project CLAUDE.md note. See README.md for an example."

7. **Idempotent:** running this multiple times just re-checks status. Doesn't double-write the section.
```

**Step 2: Verify**

Run: `head -10 commands/cross-model-setup.md`

**Step 3: Commit**

```bash
git add commands/cross-model-setup.md
git commit -m "feat: add /cross-model-setup command"
```

---

### Task 14: `cross-model-status` command

**Files:**
- Create: `commands/cross-model-status.md`

**Step 1: Write the file**

```markdown
---
description: Plain-language report of cross-model-review state. Read-only; does NOT create the state file.
allowed-tools: Read, Bash
---

# /cross-model-status

Diagnostic report. Reads current plugin state and surfaces it in human-readable form.

## Steps

1. **Pure-read.** Do NOT create the state file if absent.

2. Read `.claude/cross-model-review.session.local.md` if present.

3. Determine state-storage mode:
   - File present → PERSISTED, surface frontmatter-resume implications.
   - File absent → could be EPHEMERAL (read-only filesystem) or just "haven't done anything yet."

4. Compute approval state per design doc Section 9.7:
   - For active chain (or anchorless impl-only chain), check artifact frontmatter for approval status + hash.
   - Compute current artifact body hash. If matches recorded → approved. Else → STALE.
   - Cascade staleness: design stale → plan + impl stale; plan stale → impl stale.

5. Compute pending decisions count: read per-chain `decisions-<basename>.md` if exists, count entries with format `## decision-...`.

6. Output the status block. Two formats:

   **Persisted state with active chain:**

   ```
   Cross-Model-Review Session Status
   ─────────────────────────────────

   State storage:  PERSISTED  (.claude/cross-model-review.session.local.md)
      Frontmatter resume is SUPPRESSED while state file exists.

   Mode:           INTERACTIVE | AUTONOMOUS  (per state.autonomous)

   Codex thread:   <thread_id>  (project-scoped, durable until reset; primed at <time>)
   Active chain:   <state.active_chain_artifact>
      Status:       ⏳ IN PROGRESS | ✅ COMPLETED (PR: <url>) | ⏸️ HALTED (<reason>)
      Last call:    <state.last_invocation>  (kind: <state.last_invocation_kind>)

   Approvals (active chain only — hash-validated):
      design-review:  ✅ approved | ⚠️ STALE | — N/A | ⏳ in progress | ⏸️ blocked
      plan-review:    [same options]
      impl-review:    [same options]

   Skip flag:      NOT ARMED | ARMED  (next review trigger will be suppressed)

   Pending decisions: N items in .claude/cross-model-review/decisions/<basename>.md
      <handle>: <one-line summary>
      <handle>: <one-line summary>
   ```

   **No state file (truly fresh):**

   ```
   Cross-Model-Review Session Status
   ─────────────────────────────────

   State storage:  NONE (state file does not exist; no Codex interactions yet in this project)
      Frontmatter resume from docs/plans/ IS available for impl-review continuity.

   Mode:           — (defaults to interactive on first stateful action)

   To begin: invoke any cross-model-review skill, slash command (other than
   /cross-model-status or /cross-model-setup), or trigger an auto-review by
   completing brainstorming/writing-plans/subagent-driven-development.
   ```

7. Output is the only effect. No state changes.
```

**Step 2: Verify**

Run: `head -10 commands/cross-model-status.md`

**Step 3: Commit**

```bash
git add commands/cross-model-status.md
git commit -m "feat: add /cross-model-status command"
```

---

### Task 15: `cross-model-reset` command

**Files:**
- Create: `commands/cross-model-reset.md`

**Step 1: Write the file**

```markdown
---
description: Start a fresh cross-model-review chain in this project. Writes default-state file (overwrites existing). Does NOT touch design / plan doc content.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-reset

Reset the cross-model-review chain to start fresh.

## Steps

1. Bootstrap state (read or create).

2. Capture the previous `codex_thread_id` for the chat note (will be released).

3. Overwrite the state file with defaults:

   ```yaml
   ---
   autonomous: false
   codex_thread_id: null
   active_chain_artifact: null
   active_chain_branch: null
   chain_status: null
   skip_next_review: false
   last_invocation: null
   last_invocation_kind: null
   impl_review_approved_sha: null
   session_start: <current ISO timestamp>
   ---

   # Cross-Model-Review Session State

   Auto-managed by the cross-model-review plugin. To reset, run `/cross-model-reset`.
   ```

4. **Do NOT touch design or plan doc frontmatter.** Their `codex_thread_id` and approval fields persist as fallback for *new* installs without state files; they won't be consulted while the post-reset state file exists.

5. Output:

   ```
   /cross-model-reset done.

   Session state reset to defaults. Active codex_thread_id was <previous_id> — now released.

   Next Codex invocation in this project will:
     - Start a fresh thread with the universal priming
     - NOT resume from any design / plan doc's codex_thread_id frontmatter
       (state file is present, marking active session)

   Frontmatter resume stays suppressed as long as the state file exists. To
   re-enable frontmatter resume (rare): manually delete
   .claude/cross-model-review.session.local.md.

   For a fresh start in a different chain: edit your design doc, or invoke
   /cross-model-review-now <kind> on the new artifact.
   ```
```

**Step 2: Verify**

Run: `head -10 commands/cross-model-reset.md`

**Step 3: Commit**

```bash
git add commands/cross-model-reset.md
git commit -m "feat: add /cross-model-reset command"
```

---

### Task 16: Hooks (`hooks/hooks.json`)

**Files:**
- Create: `hooks/hooks.json`

**Step 1: Define verification**

Valid JSON. Two Stop-event hooks. Both prompt-injection-only (no state mutation). Both check `state.skip_next_review` before injecting (stay silent if set).

**Step 2: Write the file**

The exact format depends on Claude Code's native hooks schema. Below is the prompt-based pattern; if native hooks don't support transcript regex matching, this file may need to be replaced with hookify-format `.local.md` rules installed via `/cross-model-setup`. Implementation phase decides.

```json
{
  "hooks": {
    "Stop": [
      {
        "name": "cross-model-review-plan-review-nudge",
        "matcher": {
          "transcript_pattern": "(saved to docs/plans/|plan complete|design doc written)",
          "no_recent_invocation_of": "cross-model-review:codex-plan-review"
        },
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Reminder: a plan or design doc was recently saved to docs/plans/. If this is a code-touching artifact and Codex review hasn't been invoked, consider invoking cross-model-review:codex-plan-review now. If you skipped it intentionally or it's not applicable (non-code plan), ignore this nudge. Note: respect state.skip_next_review — if set, do not invoke.",
            "respect_skip_flag": true
          }
        ]
      },
      {
        "name": "cross-model-review-impl-review-nudge",
        "matcher": {
          "transcript_pattern": "(all tasks complete|implementation complete|subagent-driven-development finished|ready to PR)",
          "no_recent_invocation_of": "cross-model-review:codex-impl-review"
        },
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Reminder: subagent-driven-development recently completed. Consider invoking cross-model-review:codex-impl-review before opening a PR. If skipped intentionally or not applicable, ignore. Note: respect state.skip_next_review — if set, do not invoke.",
            "respect_skip_flag": true
          }
        ]
      }
    ]
  }
}
```

**Note for implementer:** Verify the exact `matcher` schema against the Claude Code hooks documentation at implementation time. The fields `transcript_pattern` and `no_recent_invocation_of` are speculative — if Claude Code uses different field names, adapt accordingly. If native hooks don't support these matchers, replace this file with hookify rules in `.claude/hookify.cross-model-*.local.md` shipped via `/cross-model-setup`.

**Step 3: Verify JSON parses**

Run: `jq . hooks/hooks.json`
Expected: pretty-printed valid JSON, exit 0.

**Step 4: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat: add Stop-event backup nudge hooks"
```

---

### Task 17: Update MANIFEST.md to reflect final structure

**Files:**
- Modify: `MANIFEST.md`

**Step 1: Write the new content (replaces existing minimal MANIFEST.md)**

```markdown
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
│   ├── cross-model-setup.md                       # first-run setup; verifies env + applies CLAUDE.md
│   ├── cross-model-status.md                      # plain-language state report (read-only)
│   └── cross-model-reset.md                       # fresh chain in this project
├── hooks/
│   └── hooks.json                                 # 2 Stop-event nudge hooks (advisory only)
├── docs/
│   └── plans/
│       ├── 2026-04-29-cross-model-review-design.md   # full design doc
│       └── 2026-04-29-cross-model-review-plan.md     # this implementation plan
├── README.md                                      # install + usage + privacy note
├── CHANGELOG.md
├── MANIFEST.md                                    # this file
├── LICENSE                                        # MIT
└── .gitignore
```

## Key Relationships

- **Design doc → implementation plan**: `docs/plans/2026-04-29-cross-model-review-design.md` is the input to writing-plans; `docs/plans/2026-04-29-cross-model-review-plan.md` is the output and references design doc sections by number.
- **Plugin-vs-runtime boundary**: this repo contains plugin package files only. Runtime artifacts (`.claude/cross-model-review.session.local.md`, `.claude/cross-model-review/decisions/`) are created in *target* repos at runtime, never in this plugin's repo.
- **Skill bodies share three reference blocks**: bootstrap snippet (Block B), MCP invocation pattern (Block C), response handling (Block D). All three are inlined per skill (per Approach 1 lean architecture); no shared `prompts/` directory.
- **Frontmatter persistence as cross-machine bridge**: design doc and plan doc frontmatter store `codex_thread_id`, approval status, and approval hashes. These let a fresh install on a new machine resume the chain by reading frontmatter.
- **Hooks are advisory-only**: never mutate state; just inject reminder prompts on transcript-pattern match. Skill bodies and CLAUDE.md are the load-bearing layers.
```

**Step 2: Verify**

Run: `head -20 MANIFEST.md`
Expected: starts with `# MANIFEST` and shows updated structure.

**Step 3: Commit**

```bash
git add MANIFEST.md
git commit -m "docs: update MANIFEST.md to reflect v0.1 plugin structure"
```

---

### Task 18: Append CLAUDE.md additions to global config (manual user step)

**Files:**
- Modify: `~/.claude/CLAUDE.md` (USER's machine, not in plugin repo)

**Step 1: This is a manual step the user runs after install**

The `/cross-model-setup` slash command (Task 13) handles this interactively. The plan task here is to confirm the user runs it after installing the plugin.

**Step 2: Document this dependency in README**

Already done in Task 3 (README explicitly says "run `/cross-model-setup` after install").

**Step 3: No commit needed (this task is a no-op for the repo).**

---

### Task 19: Manual smoke test

**Files:**
- No file changes; runtime verification only.

**Step 1: Install the plugin locally**

From a Claude Code session in any test repo:

```
/plugin marketplace add file:///c/Users/tim/OneDrive/Documents/Projects/cross-model-review
/plugin install cross-model-review@cross-model-review
```

Or via direct path / git URL once published.

**Step 2: Run setup**

```
/cross-model-setup
```

Expected: detects Codex MCP, prints CLAUDE.md additions, asks to apply.

**Step 3: Verify status reads cleanly with no state**

```
/cross-model-status
```

Expected: shows "State storage: NONE" output.

**Step 4: Trigger a synthetic auto-flow in a sandbox repo**

In a minimal sandbox repo:

1. Use brainstorming to design a small feature (e.g., "add a hello-world function").
2. Write the design doc.
3. Verify codex-plan-review fires (or hook nudges).
4. Approve through plan-review.
5. Run subagent-driven-development.
6. Verify codex-impl-review fires.
7. Approve, observe PR creation in autonomous mode (or stay interactive and verify the prompt).

**Step 5: Verify state and decisions files exist as expected**

```bash
cat .claude/cross-model-review.session.local.md
ls .claude/cross-model-review/decisions/
```

Expected: state file with reasonable values; decisions file present if any deferrals occurred.

**Step 6: Verify reset works**

```
/cross-model-reset
/cross-model-status
```

Expected: status shows defaults, codex_thread_id null, frontmatter resume suppressed.

**Step 7: If any defects found, file them as v0.1.1 issues**

Don't block v0.1.0 release on minor smoke-test findings unless they break primary flows.

**Step 8: Tag and release**

If smoke test passes:

```bash
cd /c/Users/tim/OneDrive/Documents/Projects/cross-model-review
git tag v0.1.0
git push origin main --tags
```

Once tagged, the marketplace install path becomes available for use in any other project.

---

## Plan summary

19 tasks. ~16 actual file-creating tasks; 1 README update; 1 MANIFEST update; 1 manual setup; 1 smoke test.

Each task creates one or two files with full content provided. Verification steps use `jq` for JSON files, `head` for markdown frontmatter inspection. End-to-end verification is the manual smoke test (Task 19).

Reference content blocks (universal priming, bootstrap snippet, MCP invocation, response handling) are defined once at the top of this plan and referenced by each skill task — implementer should inline these blocks into the corresponding skill bodies during Task 6, 7, 8.

The plan does NOT cover:
- Auto-resume after interruption (deferred to v0.2 per design doc Section 12).
- Cross-device push notifications (deferred to v0.2).
- Sticky pause/resume (deferred to v0.2).
- Multi-chain juggling (out of scope).
- Codex thread compaction (relies on user `/cross-model-reset` for v0.1).

These will be tracked in CHANGELOG.md as future work.
