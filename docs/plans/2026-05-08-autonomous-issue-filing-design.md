# Autonomous Issue Filing — Design Document

**Status:** Brainstorm complete; ready for writing-plans phase.
**Date:** 2026-05-08
**Type:** Enhancement / behavioral change to `cross-model-review` v0.1
**Original design doc:** `2026-04-29-cross-model-review-design.md` (referenced by section number throughout)

---

## 1. Goal

Replace the current "deferred items get pasted into PR description" mechanism with structured GitHub issues. Items deferred during any of the three review gates (design / plan / impl) become `autonomous-safe` or `design-input-needed` issues at the moment they're deferred, with a chain-stem prefix in the title and a per-chain cross-link from the resulting PR.

The change has two parallel goals:

1. **Stop losing things in PR notes.** The current per-chain decisions file gets pasted into the PR description verbatim and is easy to miss once the PR merges.
2. **Push the "fix in session" boundary further than current behavior allows.** Most items the previous design routed to "MINOR / log as deferred" should now be fixed in-session (often via subagent dispatch, which offloads context). Issues are reserved for genuine escalations: scope too large to fix without context collapse, or user judgment required.

The design also makes the plugin's outputs a clean input contract for future symphony-style autonomous orchestrators (per [openai/symphony](https://github.com/openai/symphony)). No actual symphony integration in v1; just labeled, machine-readable issues that a future consumer can pick up.

## 2. Background — what currently happens

Per Sections 5.4 and 9.3 of the original design doc:

- Codex returns findings tagged CRITICAL / IMPORTANT / MINOR.
- CRITICAL/IMPORTANT trigger fix subagents per cluster of related findings; loop until Codex approves.
- MINOR is "noted, deferred. Don't necessarily fix."
- User-bound questions (UI/UX, judgment) get a defensible default chosen and logged to `.claude/cross-model-review/decisions/<basename>.md`.
- The decisions file is pasted verbatim into the PR description's *"Decisions deferred to your review"* section at PR creation.

This produces the failure mode this enhancement targets: items pile up in the PR description, the user merges the PR without addressing them, the items are gone. Subsequent autonomous runs surface *more* items the user didn't even know they wanted to defer.

## 3. Design summary

Five changes to v0.1 behavior:

1. **Routing rule (Section 4)** — three-rule gate that defaults to fix; defers only when user input is required or context budget is at risk.
2. **Codex SCOPE attestation (Section 4.1)** — Codex tags each finding with context impact (small / medium / large), not change size. The diff serves as the proxy for "what's hot in Claude's context."
3. **Issues replace the decisions file (Section 5)** — defers become GitHub issues with two labels (`autonomous-safe`, `design-input-needed`). The decisions file mechanism is retired.
4. **In-skill context-budget check (Section 6)** — the impl-review skill body itself reads transcript size at each loop iteration. No hooks, no settings.json modification, no cross-platform shell.
5. **Global CLAUDE.md addition (Section 7)** — defines the labeling scheme as a project-wide convention applying to all issues filed in owned repos, not just plugin-filed ones. Bulk-label-creation across existing owned repos runs as a one-shot at deploy time.

## 4. Routing rule (the gate)

When Codex returns findings during any review (design / plan / impl):

```
For each finding (or cluster of related findings):
  1. SEVERITY = CRITICAL or IMPORTANT
       → fix-loop (existing behavior; Codex won't approve until fixed)

  2. requires user input (UI/UX, judgment, "could go either way")
       → batch-defer to `design-input-needed` issue
         pick defensible default + record it in issue body

  3. else (code-only, defensible default available)
       → default: fix
         (preferred path; lean heavily this way)
       → exception: defer as `autonomous-safe` issue when fixing would
         risk context collapse — see Section 6 for the budget check

  Throughout: prefer subagent dispatch over inline edit for any
  non-trivial fix. Subagents offload context from the working session,
  which is what we're protecting.
```

**Default heavily favors fix.** Defer is the escape hatch, not the path of least resistance. The user's stated frustration with v0.1 was repeated re-dispatching of sessions to clean up batches of deferred minor items — the gate is tuned to do as much in-session as the budget allows.

### 4.1 Codex tag schema

Codex returns each finding with three tags:

| Tag | Values | Used for |
|---|---|---|
| `SEVERITY` | `critical`, `important`, `minor` | Existing — gate rule 1; Codex won't approve until critical/important resolved |
| `SCOPE` | `small`, `medium`, `large` | Context impact — see Section 4.2 |
| `CLUSTER` | free-form name | Batching — findings sharing a cluster name group into one issue |

If Codex omits a tag (e.g., for ad-hoc consultations), defaults are: `severity=minor`, `scope=medium`, `cluster=<finding's hash>` (i.e., one finding per cluster).

### 4.2 SCOPE means context impact, not change size

Codex tags `SCOPE` based on *"how much new context does this fix require Claude's working session to load?"* — using the diff as proxy for what's already hot:

- **small** — fix is contained within files already in the diff, or trivially extends to imports of those files. A 300-line refactor across files Claude just modified is *small*: those files are loaded.
- **medium** — fix requires modifications to 1-3 files outside the diff, or moderate cross-referencing.
- **large** — fix requires loading many new files, exploring unfamiliar areas of the codebase, or extensive cross-cutting verification.

**Universal priming gets one new paragraph clarifying this** (text in Section 8). The principle: *Codex uses the diff as proxy for what's hot in Claude's context. A fix touching files in the diff is small regardless of line count; a fix requiring unfamiliar files is medium-or-larger regardless of size.*

The skill body's gate combines `SCOPE` with the in-skill context % check: `small` + low context % → inline fix; `small` + high context % → subagent fix (still cheap from working session perspective); `medium`/`large` + high context % → defer as issue.

Specific thresholds and the inline-vs-subagent distinction live in the skill body, not this design doc.

## 5. Issue creation mechanics

### 5.1 Labels

Two labels, both per-repo, created at setup time:

- `autonomous-safe` — code-only follow-up; eligible for autonomous pickup (cross-model-review re-run, symphony, etc.) without further user input
- `design-input-needed` — requires user judgment before work proceeds

Every plugin-filed issue gets exactly one of these. No root `cross-model-review` namespace label — chain-stem prefix in the title plus state-tracked issue numbers handle scoping.

### 5.2 Title format

`[<chain-stem>] <imperative description>`

Examples:
- `[search-feature] Refactor query builder into separate module`
- `[search-feature] Decide cache backend: in-memory vs Redis`
- `[branch:hotfix-401] Add retry logic for transient auth errors` (anchorless impl-only chain)

Chain-stem comes from the existing stem-matching algorithm (Section 9.2 of original design doc). For impl-only chains the stem is `branch:<branch-name>`.

### 5.3 Body format (markdown, no frontmatter)

For `autonomous-safe`:

```markdown
## Context
- **Chain:** `docs/plans/2026-05-08-search-feature-design.md`
- **Branch:** `feat/search-feature`
- **Filed during:** impl-review (commit a1b2c3d)

## Findings (cluster: query-builder-extract)
- **MINOR / medium scope** — Query builder logic in `service.py:142-198`
  should be extracted into a `query_builder.py` module
- **MINOR / medium scope** — Test scaffolding for the builder is currently
  inlined in `test_service.py`; should move alongside the module

## Suggested approach
<Codex's recommended fix>

## Acceptance criteria
- [ ] `query_builder.py` extracted with clean public API
- [ ] Tests moved and still passing
- [ ] No callers in `service.py` reach into builder internals

---
🤖 Filed by cross-model-review during impl-review on 2026-05-08.
```

For `design-input-needed`, replace `Suggested approach` + `Acceptance criteria` with:

```markdown
## Decision needed
<the question>

## Default applied (autonomous run)
<what Claude+Codex picked, with reasoning>

## How to resolve
- Comment with your preferred answer to override
- Close as completed if the default is acceptable
- Close as superseded if circumstances changed before resolution
```

### 5.4 Batching

Codex tags each finding with `CLUSTER: <name>`. Findings sharing a cluster name within the same review round group into one issue.

- If a cluster has both `autonomous-safe` and `design-input-needed` defers (mixed), they split into two issues — different labels, different handling.
- If Codex omits cluster tags, each finding becomes its own cluster (no batching).

### 5.5 Re-flag prevention

When Codex re-reviews a diff in subsequent rounds, deferred-but-unfixed items still appear. Codex would otherwise re-flag them and we'd loop.

**Each round's framing line includes:** *"Already filed as issues in this chain (do not re-flag): #123, #124."* The list comes from `state.filed_issues` (Section 6.1). Codex's thread memory plus the explicit hint prevents the loop.

### 5.6 Cross-link from PR

When the impl-review PR is created, its description gains:

```markdown
## Filed for follow-up

- #123 (autonomous-safe): Extract query builder into separate module
- #124 (design-input-needed): Decide cache backend: in-memory vs Redis
```

Issue numbers come from `state.filed_issues`. Title + label re-fetched via `gh issue list --json number,title,labels --search "<numbers>"` at PR-creation time.

### 5.7 Bidirectional cross-link

After PR creation, plugin runs `gh issue comment <num>` on each filed issue:

> Originally filed during PR #N: \<url\>

This makes navigation work both ways — from PR you find the issues; from each issue you find the PR that prompted it.

### 5.8 gh availability + repo gating

`gh` is already required for autonomous-mode PR creation. Issue-filing extends the precondition check:

- At every review gate that might defer, run `gh auth status` and `gh issue list --limit 1`. Both must succeed.
- **Autonomous + gh OK** → file issue normally
- **Autonomous + gh fails** (not authenticated, issues disabled on repo, no GitHub remote) → HALT, consistent with existing Codex-unavailable handling. Halt-path PR includes the would-be-issue contents in a fallback section so nothing is lost
- **Interactive mode** — design/plan user-bound questions: ask in chat as today (no issue filed); impl-review defers: ask user "file as issue or keep in PR description?" and respect the answer

## 6. Context-budget check (in-skill, no hooks)

The original draft of this design proposed two new hooks (`PreCompact` circuit-breaker + `PostToolUse` transcript-size). Both were dropped:

- **`PreCompact` is too late.** In a 1M context, PreCompact fires near the end of the window — past the point of useful intervention. Users on smaller contexts hit it earlier, but the design needs to work for the 1M case.
- **Hookify doesn't support `PostToolUse` for arbitrary tools.** Confirmed by reading hookify v0.x supported events: `bash`, `file`, `stop`, `prompt`, `all` only. Going to native Claude Code hooks would require settings.json modification + cross-platform shell scripts — meaningful plumbing for a soft signal.

**Replacement: in-skill check at each loop iteration.** The impl-review skill body reads transcript file size directly at each fix-vs-defer decision point.

```bash
# Resolve transcript path: encoded-cwd dir, newest .jsonl
encoded=$(pwd | sed 's|[:\\/]|-|g')
transcript=$(ls -t ~/.claude/projects/*${encoded}*/*.jsonl 2>/dev/null | head -1)
size=$(wc -c < "$transcript" 2>/dev/null)
pct=$(( (size / 4) * 100 / 1000000 ))   # bytes/4 ≈ tokens, /1M context
```

A few lines per iteration. No hooks, no settings.json, no cross-platform issues, no late-fire problem. Sampling granularity is up to the skill body — every iteration, every Nth, etc.

The exact thresholds (e.g., "fix freely <70%", "small-only 70-85%", "defer >85%") live in the skill body and are tunable. The principle is: lean toward fix; defer when budget signal indicates fixing would lose more than it gains.

### 6.1 State changes

`.claude/cross-model-review.session.local.md` gains exactly one field:

```yaml
filed_issues: [123, 124]
```

Just issue numbers. Title, labels, and any other metadata are re-fetched from `gh` when needed.

**Lifecycle:** scoped to the active chain. When `state.active_chain_artifact` changes (per Section 9.2 of original design), `filed_issues` resets. Old chains' issues stay in GitHub and were already listed in the merged PR; no reason to carry them forward.

The decisions file mechanism (`.claude/cross-model-review/decisions/<basename>.md`) is **retired entirely**. Migration handling for in-flight chains is in Section 9.

### 6.2 `/cross-model-status` output additions

Add two sections to the existing status output:

```
Filed issues (this chain):
   #123 (autonomous-safe):    Extract query builder into separate module
   #124 (design-input-needed): Decide cache backend: in-memory vs Redis

Hooks: 2 of 4 installed (re-run /cross-model-setup to add missing).
```

Note the "Hooks: N of M" line stays even though Section 6 dropped the new hooks — the existing hookify backup nudges still need this surface. The line just won't grow as we'd planned.

(Correction: with the in-skill approach, there are no new hooks. The line stays at "Hooks: 2 of 2 installed" referring to existing hookify rules. The "re-run /cross-model-setup" prompt appears only if some are missing.)

## 7. Global CLAUDE.md addition + bulk label creation

Two parallel pieces of work outside the plugin proper:

### 7.1 Global CLAUDE.md addition

Add to `~/.claude/CLAUDE.md` (the user's private global instructions):

```markdown
## GitHub Issues in Owned Repos

When filing GitHub issues in repos owned by `TimSimpsonJr` (detected via
`git remote get-url origin`), every issue MUST be labeled with exactly
one of:

- `autonomous-safe` — code-only follow-up; can be picked up by an
  autonomous agent (cross-model-review, symphony, etc.) without further
  user input
- `design-input-needed` — requires user judgment before work can proceed

If neither label fits cleanly, ask before filing.

When creating a new owned repo, also create these two labels via
`gh label create autonomous-safe --color "0E8A16" --description "..."` and
`gh label create design-input-needed --color "D93F0B" --description "..."`
as part of the initial setup.

This labeling scheme is shared with the cross-model-review plugin and is
the input contract for any future symphony-style autonomous orchestrator.
Don't apply this rule when filing issues in repos owned by others — they
have their own conventions.
```

### 7.2 Bulk label creation across existing owned repos

One-shot script to run as part of this work:

```bash
gh repo list TimSimpsonJr --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner' \
  | while read repo; do
      gh label create autonomous-safe \
        --repo "$repo" \
        --color "0E8A16" \
        --description "Code-only follow-up; eligible for autonomous pickup" \
        2>/dev/null || true
      gh label create design-input-needed \
        --repo "$repo" \
        --color "D93F0B" \
        --description "Requires user judgment before work proceeds" \
        2>/dev/null || true
    done
```

Idempotent — `gh label create` errors with non-zero status if the label exists; we swallow that. Safe to re-run.

### 7.3 Plugin setup also creates labels

`/cross-model-setup` step 6 (when validating gh availability) also runs `gh label create` for both labels in the current repo. This way, even if the bulk script wasn't run for a particular repo, setup ensures labels exist before the plugin can defer anything.

## 8. Codex universal priming changes

Add to the priming text (Section 5.7 of original design doc), in the *"Modes details / Design / plan / diff review"* section:

```
When returning findings, tag each one with:

- SEVERITY: critical | important | minor
- SCOPE: small | medium | large — context impact, NOT change size.
  Use the diff as proxy for what's already loaded in Claude's working
  context. A 300-line refactor inside files in the diff is "small"
  (those files are hot). A 5-line tweak in a file outside the diff is
  "medium" (Claude has to load it).
- CLUSTER: <short name> — group related findings under the same cluster
  name so they can be batched into one fix subagent or one follow-up
  issue. Use distinct cluster names for unrelated concerns.
```

**Existing thread handling:** out of scope. Old chains running on the prior priming get the prior behavior; new chains use the new priming. (Per user direction in brainstorm.)

## 9. Setup changes

### 9.1 `/cross-model-setup` step 6 refactor

Current behavior: writes hookify rule files; if both rules present, exits the step.

New behavior: per-rule check + install. Iterate over the planned rule list (currently 2 hookify rules; this design adds no new ones); for each, write if missing, skip if present. The "if both exist, skip" short-circuit goes away — that prevented future additions from landing on existing installs.

This refactor is small and isolated (~10 lines). Once landed, future additions to the rule list (this design or any future) drop in cleanly.

### 9.2 Label creation step

`/cross-model-setup` adds a new step (between gh validation and CLAUDE.md addition):

> *Step 7 — Create plugin labels in current repo.* Run `gh label create autonomous-safe ...` and `gh label create design-input-needed ...`. Idempotent; "already exists" errors swallowed.

Skipped if `gh` validation in step 1 failed.

### 9.3 `/cross-model-status` per-rule check

Same refactor mirrors `/cross-model-status`: enumerate the planned rule list, check each, summarize. Output is one line: `"Hooks: N of M installed (re-run /cross-model-setup to add missing)."` — only shows the "(re-run)" suffix if N < M.

## 10. Edge cases and migration

| Case | Behavior |
|---|---|
| Existing `.claude/cross-model-review/decisions/<basename>.md` present at impl-review entry (in-flight chain from before upgrade) | Read contents; for each entry, file as `design-input-needed` issue (preserving the question + default-applied); delete the file. One-time migration per chain. |
| Repo has GitHub issues disabled | Detected by `gh issue list` failure → treated as gh-unavailable → HALT in autonomous; ask in chat in interactive |
| Repo isn't on GitHub (no origin or non-GitHub remote) | Same — HALT in autonomous; ask in chat in interactive |
| User opens issue manually with these labels | Plugin doesn't interfere; only tracks issues in `state.filed_issues` (its own creations) |
| Issue gets superseded mid-chain (decision reversed) | Plugin closes via `gh issue close <num> --reason "not planned" --comment "Superseded by <new-decision>"` and removes from `state.filed_issues` |
| Codex omits SCOPE / CLUSTER tags | Defaults: `scope=medium`, `cluster=<finding-hash>` (one finding per cluster) |
| Codex re-flags an already-filed item despite framing hint | Skill body filters Codex's findings against `state.filed_issues` titles before deciding fix-vs-defer (defensive — shouldn't happen often given the hint, but cheap insurance) |

## 11. Out of scope

- **Native Claude Code hooks** for context-budget detection — replaced by in-skill check (Section 6).
- **`PreCompact` circuit-breaker** — too late in 1M contexts; in-skill check fires earlier and at the moments we care about.
- **Issue de-duplication across chains** (e.g., closing similar issues from prior runs). User can manage manually; plugin doesn't try to be smart about this.
- **Symphony integration itself** — design only ensures issues are pickup-able as input. Actual symphony deployment is a separate concern.
- **Migration of pre-upgrade priming on existing Codex threads** — explicitly out of scope per user direction. Old chains complete on old behavior.
- **Cross-platform hook scripts** — moot; design uses in-skill check rather than hooks.

## 12. Forward-compat with symphony

[openai/symphony](https://github.com/openai/symphony) is an issue-tracker-driven daemon that polls for active issues, creates per-issue workspaces, and dispatches Codex into them. Issues need: a clear title, a body the workflow prompt can pull task description from, and labels symphony can filter on.

This design produces:

- Titles with chain-stem prefix → human and machine-readable
- Bodies with `## Suggested approach` and `## Acceptance criteria` → ready for a workflow prompt to consume
- Labels (`autonomous-safe`, `design-input-needed`) → simple strings symphony filters on
- No frontmatter — matches symphony's spec preference for normalizing on its end

A future symphony-on-Tim's-repos deployment would filter on `label:autonomous-safe`, build prompts from `## Acceptance criteria`, and never touch `design-input-needed` issues until a human relabels them. No plugin changes required for that to work.

## 13. Implementation entry points

For the implementation plan (writing-plans phase), the changes touch:

| Component | Change |
|---|---|
| `skills/codex-impl-review/SKILL.md` | New routing rule (Section 4); in-skill context check (Section 6); re-flag prevention (Section 5.5) |
| `skills/codex-plan-review/SKILL.md` | New routing rule applied to design-review and plan-review modes; user-bound defers go to issues (autonomous mode) |
| Universal priming text (in both review skills) | New SCOPE/CLUSTER tag definitions (Section 8) |
| `commands/cross-model-setup.md` | Step 6 per-rule refactor; new step 7 label creation (Sections 9.1, 9.2) |
| `commands/cross-model-status.md` | Per-rule check + filed-issues block + (revised) hooks status line (Section 6.2, 9.3) |
| `~/.claude/CLAUDE.md` | New "GitHub Issues in Owned Repos" section (Section 7.1) |
| One-shot bulk script | Run during deployment to create labels in all owned repos (Section 7.2) |
| Migration logic | One-time read+convert+delete of existing decisions files (Section 10) |

State schema change: `state.filed_issues` list added. Decisions file path retired (Section 6.1).
