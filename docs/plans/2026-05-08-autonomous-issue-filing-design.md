---
codex_thread_id: 019e08e2-e245-7c61-acbd-91601d090978
codex_design_review_status: in_review
---

# Autonomous Issue Filing — Design Document

**Status:** Brainstorm complete; under Codex design-review.
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

The gate has a common entry check that applies to all review modes, then a mode-specific path.

**Common entry check** (every finding or cluster, regardless of mode):

```
1. Codex flagged it as user-input-required (UI/UX, judgment, "user decision: ...")
     → AUTONOMOUS: file as `design-input-needed` issue (Section 5)
                   pick defensible default + record it in issue body
                   continue review
     → INTERACTIVE: ask user in chat; respect answer

2. else → continue to mode-specific routing below
```

User-input check **outranks severity**. A CRITICAL UI judgment call still becomes a `design-input-needed` issue — it is not force-fixed.

**design-review / plan-review routing** (post entry check):

```
Substantive critique → apply to artifact (revise design or plan doc); loop
                       until Codex approves. No code fixes at this gate;
                       no autonomous-safe issues.
```

`autonomous-safe` issues are not produced at design/plan gates — there is no code diff yet, so context-budget pressure does not exist. The only deferral mechanism at design/plan is the user-input path above.

**impl-review routing** (post entry check):

```
1. SEVERITY = CRITICAL or IMPORTANT
     → fix-loop (subagent dispatch per cluster; existing behavior)

2. SEVERITY = MINOR (code-only)
     → default: fix (subagent dispatch preferred — see below)
     → exception: defer as `autonomous-safe` issue when the context-budget
       signal indicates fixing would risk collapse (Section 6)

Throughout: prefer subagent dispatch over inline edit for any non-trivial
fix. Subagents offload context from the working session, which is what
we're protecting.
```

**Default heavily favors fix.** Defer is the escape hatch, not the path of least resistance. The user's stated frustration with v0.1 was repeated re-dispatching of sessions to clean up batches of deferred minor items — the gate is tuned to do as much in-session as the budget allows.

### 4.1 Codex tag schema

Each finding Codex returns starts with a parseable tag line of this form:

```
[severity:critical|important|minor, scope:small|medium|large|n-a, cluster:<short-name>]
```

The line appears as the first content of each finding so a regex parser can extract the three tags reliably.

| Tag | Values | Used for |
|---|---|---|
| `severity` | `critical` \| `important` \| `minor` | impl-review fix-loop gate (existing behavior) |
| `scope` | `small` \| `medium` \| `large` \| `n-a` | impl-review context-budget gate (see 4.2). `n-a` at design/plan gates where no code diff exists. |
| `cluster` | short kebab-case name | Batching — findings sharing a cluster name group into one issue or one fix subagent. Also the durable identifier for re-flag prevention (Section 5.5). |

**Tag-line absence handling.** If Codex omits or malforms the tag line on a finding, the parser falls back to inferring from the prose:
- severity defaults to `minor`
- scope defaults to `medium` at impl-review, `n-a` at design/plan
- cluster defaults to `solo-<sha8(finding-text)>` (no batching for that finding)

These defaults make malformed tags safe rather than blocking.

### 4.2 SCOPE only matters at impl-review

`scope` is a context-impact signal for code fixes. At design-review and plan-review there is no code diff to fix — substantive critiques are applied to the design or plan doc directly, not deferred. So `scope` is `n-a` at those gates and the impl-review budget logic does not run.

For impl-review specifically, Codex tags `scope` based on *"how much new context does this fix require Claude's working session to load?"* — using the diff as proxy for what's already hot:

- **small** — fix is contained within files already in the diff, or trivially extends to imports of those files. A 300-line refactor across files Claude just modified is *small*: those files are loaded.
- **medium** — fix requires modifications to 1-3 files outside the diff, or moderate cross-referencing.
- **large** — fix requires loading many new files, exploring unfamiliar areas of the codebase, or extensive cross-cutting verification.

**Universal priming gets a new paragraph clarifying this** (text in Section 8). The principle: *Codex uses the diff as proxy for what's hot in Claude's context. A fix touching files in the diff is small regardless of line count; a fix requiring unfamiliar files is medium-or-larger regardless of size.*

The skill body's impl-review gate combines `scope` with the in-skill context % check: `small` + low context % → inline fix; `small` + high context % → subagent fix (still cheap from working session perspective); `medium` / `large` + high context % → defer as issue.

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

**Each round's framing line includes:** *"Already filed as issues in this chain (do not re-flag): cluster=<name> issue #N, cluster=<name> issue #N, ..."* The list comes from `state.filed_issues` (Section 6.1). Cluster is the durable identifier — issue titles can be edited but cluster names are set at filing time and do not change.

**Defensive parser side.** When parsing Codex's next response, the skill checks each finding's `cluster` tag against `state.filed_issues[*].cluster`. If a match exists, the finding is treated as a no-op (Codex re-surfaced an already-deferred concern despite the framing). Cheap insurance against framing-hint failure.

### 5.6 Cross-link from PR

When the impl-review PR is created, its description gains:

```markdown
## Filed for follow-up

- #123 (autonomous-safe): Extract query builder into separate module
- #124 (design-input-needed): Decide cache backend: in-memory vs Redis
```

Issue numbers come from `state.filed_issues`. Title is re-fetched via `gh issue view <num> --json title` per issue at PR-creation time (exact lookup, not fuzzy search). Label is read from the local state — `state.filed_issues[i].kind` ∈ {`autonomous-safe`, `design-input-needed`} — so no extra fetch needed.

### 5.7 Bidirectional cross-link

After PR creation, plugin runs `gh issue comment <num>` on each filed issue:

> Originally filed during PR #N: \<url\>

This makes navigation work both ways — from PR you find the issues; from each issue you find the PR that prompted it.

### 5.8 Defer-path preconditions — lazy gating + runtime ownership check

Three preconditions are checked **at the moment we are about to file an issue** (not at gate entry). A review run that fully resolves in-session — no defers — runs without any of these checks and works fine on a non-GitHub remote.

The three checks, in order:

1. **Ownership.** `git remote get-url origin` matches `TimSimpsonJr/` or `TimSimpsonJr:`. This enforces the global "issues filed only in owned repos" policy at the actual write point, not just at setup time. Setup may have been skipped, labels may exist on a repo we don't own (someone else added them), or origin may have been changed since setup ran — the runtime check is the load-bearing one.
2. **`gh auth status`** — exits zero.
3. **`gh issue list --limit 1`** — exits zero. Catches "issues disabled on repo" and "no GitHub remote" simultaneously.

If any of the three fails, the runtime treats it as a "cannot defer here" condition and routes per the failure table below.

**Failure handling (autonomous mode), by gate:**

| Gate | Failure handling |
|---|---|
| design-review / plan-review | Halt the chain. `state.chain_status = halted`. Post chat note explaining which precondition failed (ownership, `gh auth`, or `gh issue list`). The artifact (design or plan doc) keeps any revisions Codex caused; Codex's thread is preserved for resumption via `/cross-model-review-now`. No PR is opened — no PR exists yet at these gates. |
| impl-review (mid-loop) | Same: halt the chain, write halt note to a session-local halt log (`.claude/cross-model-review/halts/<chain-stem>.md` — new file, separate from the retired decisions file). Resume via `/cross-model-review-now impl`. |
| impl-review (PR-creation closer) | Existing halt-path PR behavior unchanged: opens `gh pr create --draft` with explicit "AUTONOMOUS RUN HALTED" header, includes any unfiled defer payloads in a fallback section. |

**Failure handling (interactive mode):** post chat note describing which precondition failed and what was about to be filed; user resolves and re-invokes. For ownership failures specifically, the chat note explains the global policy — *"This repo is not owned by you, so the cross-model-review labeling convention doesn't apply. The plugin will not file issues here."*

**Interactive mode defer choice:** when Codex flags an item for deferral in interactive mode, the skill asks: *"File as `<label>` issue or skip (Codex will not re-flag this round; no record kept)?"* The "keep in PR description" option from the original v1 sketch is removed — that path is what this design retires. If the user picks skip, the item is gone.

## 6. Context-budget check (in-skill, no hooks)

The original draft of this design proposed two new hooks (`PreCompact` circuit-breaker + `PostToolUse` transcript-size). Both were dropped:

- **`PreCompact` is too late.** In a 1M context, PreCompact fires near the end of the window — past the point of useful intervention. Users on smaller contexts hit it earlier, but the design needs to work for the 1M case.
- **Hookify doesn't support `PostToolUse` for arbitrary tools.** Confirmed by reading hookify v0.x supported events: `bash`, `file`, `stop`, `prompt`, `all` only. Going to native Claude Code hooks would require settings.json modification + cross-platform shell scripts — meaningful plumbing for a soft signal.

**Replacement: in-skill check at each impl-review loop iteration.** The skill body uses Claude's tools directly (Glob + Bash) rather than embedded shell scripts, so the probe works regardless of host OS.

**Probe procedure (impl-review only — design/plan have no fix-vs-defer decision):**

1. **Resolve project's transcript directory.** Get the repo toplevel via `git rev-parse --show-toplevel` (Bash). Then transform that path into Claude Code's encoded directory name by replacing each of `:`, `/`, and `\` with `-`. Claude does this string transformation in its own head — no shell substitution required, so it works the same on Windows and Unix. The result is the directory name under `~/.claude/projects/` that holds this project's transcripts. Example: a Windows toplevel `C:/Users/tim/OneDrive/Documents/Projects/cross-model-review` becomes `C--Users-tim-OneDrive-Documents-Projects-cross-model-review`.

2. **Find this project's newest transcript.** Glob `~/.claude/projects/<encoded>/*.jsonl`. Glob returns paths sorted by modification time (newest first). Take the first result. This guarantees we read THIS project's transcript even if other Claude Code sessions are running concurrently in different repos. If Glob returns no matches, treat as `pct = 0` (fresh session); proceed with default-to-fix routing.

3. **Read size.** `wc -c <path>` via Bash gives the byte count. (`wc` is available on Unix and on Windows under Git Bash / mingw64, both of which ship with Claude Code's environment.)

4. **Compute percentage.** `pct = (bytes / 4) * 100 / context_limit_tokens` where `context_limit_tokens` comes from `state.context_limit_tokens` (Section 6.1). Defaults to `200000` for 200k models; the user sets to `1000000` for the 1M Sonnet/Opus 1M-context tier. Bytes-divided-by-4 is a rough char-to-token approximation; good enough for the soft signal we need.

The probe is roughly four tool calls per check (one Bash for toplevel, one Glob, one Bash for `wc`, plus arithmetic). Sampling granularity is up to the skill body — once per fix-vs-defer decision is plenty; we are not trying to track context in real time.

**Thresholds and routing.** Specific values (e.g., "fix freely <70%", "small-only 70-85%", "defer >85%") live in the skill body and are tunable. The principle: lean toward fix; defer when budget signal indicates fixing would lose more than it gains.

**What the probe approximates and what it misses.** The probe captures Claude's working-session context only — it is the relevant signal because the working session is what we are protecting from collapse. It does NOT account for prompt-cache state, subagent context (intentionally — subagents are off-context), or future tool calls within the same fix. Acceptable for v1; a more accurate probe is a v0.2 candidate.

### 6.1 State changes

`.claude/cross-model-review.session.local.md` gains two fields:

```yaml
filed_issues:
  - {number: 123, cluster: query-builder-extract, kind: autonomous-safe}
  - {number: 124, cluster: caching-strategy,      kind: design-input-needed}
context_limit_tokens: 1000000   # default 200000; user-tunable for 1M tiers
```

`number` is the GitHub issue number for cross-link.
`cluster` is the durable identifier for re-flag prevention (Section 5.5) — set at filing time, never changes.
`kind` records the label so we don't have to fetch it again when constructing the PR description's "Filed for follow-up" section.
Title is fetched on-demand via `gh issue view <num> --json title` at PR-creation time only.

**Lifecycle of `filed_issues`:** scoped to the active chain. When `state.active_chain_artifact` changes (per Section 9.2 of the original design), `filed_issues` resets. Old chains' issues stay in GitHub and were already listed in the merged PR; no reason to carry them forward.

**Lifecycle of `context_limit_tokens`:** project-level, not per-chain. Defaults to `200000` if absent (200k context tier). Set to `1000000` for the 1M tier. The user edits this once per project; it is not auto-detected because the harness does not expose model-tier context size to skills. **Reset preserves this field** — `/cross-model-reset` rewrites the rest of state to defaults but leaves `context_limit_tokens` alone (and `filed_issues` is reset to `[]`, not removed, since reset establishes a fresh new-regime chain).

**State-file write protocol — applies to every writer.** The detection rule in Section 10 keys on `filed_issues` field presence, so every component that creates or rewrites the state file must emit it. The full set of writers (verified against the current repo):

| Writer | Behavior |
|---|---|
| `skills/codex-impl-review/SKILL.md` | First write of a fresh state file: emit `filed_issues: []` and `context_limit_tokens: 200000`. Subsequent writes preserve both fields verbatim. |
| `skills/codex-plan-review/SKILL.md` | Same. |
| `skills/codex-brainstorm-partner/SKILL.md` | Same. |
| `commands/cross-model-autonomous-on.md` | If creating a fresh state file: emit `filed_issues: []` and `context_limit_tokens: 200000`. If updating an existing one: preserve both verbatim, only flip `autonomous: true`. |
| `commands/cross-model-autonomous-off.md` | Same — preserve both verbatim, only flip `autonomous: false`. |
| `commands/cross-model-skip.md` | Same — preserve both verbatim, only set `skip_next_review: true`. |
| `commands/cross-model-reset.md` | Reset to defaults, but: **preserve `context_limit_tokens`** (user-tuned config); **set `filed_issues: []`** (not absent — reset establishes a fresh new-regime chain). |
| `commands/cross-model-review-now.md` | Same as the review skills — emit on first write, preserve on update. |

The implication for pre-upgrade detection: a state file written by ANY of the above under v0.1 lacks `filed_issues`. Once any of them runs under the new version on that file, the absence is the durable marker — Section 10's detection treats the chain as pre-upgrade and **does not add the field**, even on update writes from those commands.

The decisions file mechanism (`.claude/cross-model-review/decisions/<basename>.md`) is **retired** for new chains created after this enhancement lands. Pre-upgrade chains keep using the old behavior — see Section 10 for the detection rule.

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

One-shot script to run as part of this work. Captures stderr so we can distinguish "already exists" (idempotent skip) from real failures (permission denied, archived repo, transient network errors), and prints the real failures with the repo name so they don't disappear silently.

```bash
#!/usr/bin/env bash
# Requires bash. On Windows, run under Git Bash / mingw64.
set -euo pipefail

LABELS=(
  "autonomous-safe|0E8A16|Code-only follow-up; eligible for autonomous pickup"
  "design-input-needed|D93F0B|Requires user judgment before work proceeds"
)

# Fetch the repo list separately so a producer failure aborts the script
# rather than silently producing zero-iteration "success."
repos=$(gh repo list TimSimpsonJr --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner') \
  || { echo "ERROR: gh repo list failed. Check gh auth + network." >&2; exit 2; }

if [ -z "$repos" ]; then
  echo "ERROR: gh repo list returned no repos. Aborting before iteration." >&2
  exit 3
fi

while read -r repo; do
  for entry in "${LABELS[@]}"; do
    IFS='|' read -r name color desc <<< "$entry"
    if out=$(gh label create "$name" --repo "$repo" --color "$color" --description "$desc" 2>&1); then
      echo "OK:   $repo/$name"
    elif echo "$out" | grep -qi "already exists"; then
      : # idempotent skip; no log
    else
      echo "FAIL: $repo/$name → $out" >&2
    fi
  done
done <<< "$repos"
```

The producer (`gh repo list`) runs separately so any failure there aborts with a clear error and a non-zero exit code. `set -o pipefail` plus `set -e` make any other unexpected failure abort early. The per-label `gh label create` is wrapped in an `if` so its non-zero exit codes don't trigger `set -e` — those are handled by the `already exists` filter.

Exit codes: `0` on success (every label create either succeeded or was an idempotent skip), `2` for repo-list failure, `3` for empty repo list, non-zero otherwise. Callers can `&&` the script reliably now.

Real failures land on stderr with the repo and label names attached, so they survive even if you redirect stdout. "Already exists" is the only swallowed condition.

The script requires `bash`. On Windows, run it under Git Bash / mingw64, both of which ship with the Claude Code environment.

### 7.3 Plugin setup also creates labels (in owned repos only)

`/cross-model-setup` runs `gh label create` for both labels in the current repo, but **only if the repo is owned by `TimSimpsonJr`**. The ownership check uses the same `git remote get-url origin | grep -E 'TimSimpsonJr/|TimSimpsonJr:'` pattern as the global CLAUDE.md rule (Section 7.1). Setup in a non-owned repo skips this step with a chat note: *"Repo is not owned by `TimSimpsonJr`; skipping plugin label creation. The plugin will halt if it tries to file an issue here — this is intentional."*

This way the global "owned-repos-only" labeling rule is honored consistently. The plugin works in non-owned repos for its review-and-fix flows; it just cannot defer (which is acceptable since deferring writes to the user's tracker, and the user's tracker convention does not apply to other people's repos).

## 8. Codex universal priming changes

Add to the priming text (Section 5.7 of original design doc), in the *"Modes details / Design / plan / diff review"* section:

```
When returning findings, start each finding with a parseable tag line of
this exact form:

  [severity:critical|important|minor, scope:small|medium|large|n-a, cluster:<short-kebab-name>]

- severity: critical | important | minor — same meaning as before.
- scope:
  * For impl-review (code diff): small | medium | large — context impact,
    NOT change size. Use the diff as proxy for what's already loaded in
    Claude's working context. A 300-line refactor inside files in the
    diff is "small" (those files are hot). A 5-line tweak in a file
    outside the diff is "medium" (Claude has to load it).
  * For design-review and plan-review: n-a (no code diff exists at these
    gates; the routing logic does not consume scope here).
- cluster: a short kebab-case name like "query-builder-extract" or
  "auth-precedence". Group related findings under the same cluster name
  so they can be batched into one fix subagent or one follow-up issue.
  Use distinct cluster names for unrelated concerns. The cluster name
  becomes the durable identifier for that group of findings; do not
  rename it across rounds.

If a finding is genuinely a user-judgment call (UI/UX, brand-relevant
default, "could go either way"), still emit the tag line, then add the
existing 'this is a user decision: <question>' marker as the next line.
The user-decision marker takes routing precedence over severity.
```

**Existing thread handling:** out of scope. Old chains running on the prior priming get the prior behavior; new chains use the new priming. (Per user direction in brainstorm.)

## 9. Setup changes

The current `/cross-model-setup` has 7 ordered steps (read from `commands/cross-model-setup.md`):

1. Verify Codex MCP availability
2. Verify Superpowers plugin
3. Print the CLAUDE.md additions
4. Ask whether to apply automatically
5. Apply (write CLAUDE.md additions)
6. Verify hookify and offer to install backup-nudge rules
7. Suggest per-project notes

This design inserts two new steps and refactors one existing step:

### 9.1 New step — gh validation + ownership check

Inserted as **new step 3** (after Superpowers verification, before CLAUDE.md additions). Existing steps 3-7 renumber to 4-8.

```
Step 3 — Verify gh + ownership check.

a. Run `gh auth status`. If non-zero exit:
     Output: "GitHub CLI is not authenticated. Run `gh auth login` and
     re-run /cross-model-setup. Skipping label creation; the plugin's
     review-and-fix flows still work, but it will halt if it tries to
     defer in autonomous mode."
     Mark labels-step (step 7 below) as SKIP for this run.

b. Run `git remote get-url origin` and check for `TimSimpsonJr/` or
   `TimSimpsonJr:` in the result.
     If matches → owned-repo flag = TRUE.
     If no match → owned-repo flag = FALSE; output:
     "Repo is not owned by TimSimpsonJr. Skipping plugin label creation
     per the global ownership rule (~/.claude/CLAUDE.md). The plugin
     will halt if it tries to file an issue here — intentional."
     Mark labels-step (step 7 below) as SKIP for this run.
```

### 9.2 New step — Create plugin labels in current repo (if owned)

Inserted as **new step 7** (between Apply CLAUDE.md and Verify hookify). Skipped if step 3 marked it SKIP.

```
Step 7 — Create plugin labels in current repo.

For each label in [autonomous-safe, design-input-needed]:
  Run `gh label create <name> --color <c> --description <d>` against
  the current repo. Filter stderr per the bulk-script pattern in
  Section 7.2: "already exists" → silent skip; any other error →
  surface with the label name.
```

### 9.3 Existing step refactor — hookify install per-rule

The current step 6 (now renumbered to step 8) writes hookify rule files but contains an "if both exist, skip" short-circuit. New behavior: per-rule check + install. Iterate over the planned rule list (currently 2 hookify rules; this design adds no new ones); for each, write if missing, skip if present. The "if both exist, skip" short-circuit goes away — that prevented future additions from landing on existing installs.

This refactor is small and isolated (~10 lines). Once landed, future additions to the rule list (this design or any future) drop in cleanly.

### 9.4 `/cross-model-status` per-rule check

Same refactor mirrors `/cross-model-status`: enumerate the planned rule list, check each, summarize. Output is one line: `"Hooks: N of M installed (re-run /cross-model-setup to add missing)."` — only shows the "(re-run)" suffix if N < M.

## 10. Edge cases and pre-upgrade chains

**Pre-upgrade chain detection — runs at every gate.** Issue-filing applies at design-review, plan-review, AND impl-review (a user-input deferral can fire at any of them in autonomous mode). So the v0.1-vs-new-behavior detection has to run wherever a deferral could happen, not just at impl-review entry.

**Detection rule (applied in the bootstrap of every review skill before any deferral path runs):**

```
if state file does NOT exist:
    → fresh chain. Write state with `filed_issues: []`. Use new behavior.

if state file exists:
    if `filed_issues` field is present (even if []):
        → chain established under new regime. Use new behavior.
    if `filed_issues` field is absent:
        → chain established under v0.1, before the upgrade.
          Use old behavior for the rest of this chain's lifetime.
          Do NOT add the field — its absence is the durable marker.
```

The "fresh state file from frontmatter resume on a new machine" case (existing skills already support this — see `skills/codex-plan-review/SKILL.md:87-104`) is now correctly handled: a frontmatter-resumed chain creates a fresh state file with `filed_issues: []`, which puts it on new behavior. Codex's thread continues from the resumed point, but the chain's deferral mechanism is the new one. This is a slightly different outcome than "old chains die naturally," but it is the only consistent outcome — there is no signal in the design/plan doc itself that says "this was written under v0.1," so we err toward forward compatibility.

**Pre-upgrade chain behavior (when detected):**

- The decisions file at `.claude/cross-model-review/decisions/<basename>.md` keeps being written and read as before
- PR description gets the verbatim-paste section as before
- New issue-filing mechanism does NOT activate for that chain
- No auto-migration: the original decisions file held a mix of user-decision items, heuristic ambiguity logs, and halt notes. Auto-converting all of them to `design-input-needed` issues would mislabel two of those three categories.

The core property: **a chain commits to one regime at first establishment and stays there.** No mid-chain switching, no auto-migration.

**Other edge cases:**

| Case | Behavior |
|---|---|
| Repo has GitHub issues disabled | `gh issue list --limit 1` fails when about to file → halt per Section 5.8 |
| Repo isn't on GitHub (no origin or non-GitHub remote) | Same — `gh` calls fail when about to file → halt per Section 5.8 |
| User opens issue manually with these labels | Plugin doesn't interfere; only tracks issues in `state.filed_issues` (its own creations, identified by cluster name) |
| Issue gets superseded mid-chain (decision reversed) | Plugin closes via `gh issue close <num> --reason "not planned" --comment "Superseded by <new-decision>"` and removes the entry from `state.filed_issues` |
| Codex omits the tag-line on a finding | Parser falls back to defaults per Section 4.1 (`severity=minor`, `scope=medium`-or-`n-a`, `cluster=solo-<sha8>`) |
| Codex re-flags an already-filed cluster despite framing hint | Skill filters Codex's findings against `state.filed_issues[*].cluster` before deciding fix-vs-defer (Section 5.5 defensive parser) |

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
| `skills/codex-impl-review/SKILL.md` | New routing rule (Section 4); parseable tag-line parser (Section 4.1); in-skill context-budget probe with project-encoded transcript path (Section 6); cluster-based re-flag prevention (Section 5.5); 3-precondition defer-path check including runtime ownership (Section 5.8); pre-upgrade chain detection at bootstrap (Section 10); state-file writer contract (Section 6.1) |
| `skills/codex-plan-review/SKILL.md` | New routing rule applied at design-review and plan-review (entry check + apply-to-doc path); user-input defers file `design-input-needed` issues in autonomous mode; 3-precondition defer-path check including runtime ownership (Section 5.8); pre-upgrade chain detection at bootstrap (Section 10); state-file writer contract (Section 6.1) |
| `skills/codex-brainstorm-partner/SKILL.md` | State-file writer contract — emit `filed_issues: []` + `context_limit_tokens: 200000` on first write; preserve both on update (Section 6.1) |
| Universal priming text (in both review skills) | New parseable tag-line spec (Section 8) |
| `commands/cross-model-setup.md` | Insert new step 3 (gh validation + ownership) and new step 7 (label creation in owned repos); refactor existing step 6 (now step 8) to per-rule install; renumber steps 3-7 to 4-8 (Sections 9.1, 9.2, 9.3) |
| `commands/cross-model-status.md` | Per-rule hooks check; filed-issues block (Sections 6.2, 9.4). Read-only — does not write state. |
| `commands/cross-model-autonomous-on.md` | State-file writer contract per Section 6.1 — emit new fields on first write, preserve on update |
| `commands/cross-model-autonomous-off.md` | Same |
| `commands/cross-model-skip.md` | Same |
| `commands/cross-model-reset.md` | State-file writer contract per Section 6.1 — preserve `context_limit_tokens`, set `filed_issues: []` |
| `commands/cross-model-review-now.md` | State-file writer contract per Section 6.1 |
| `~/.claude/CLAUDE.md` | New "GitHub Issues in Owned Repos" section (Section 7.1) — already drafted |
| One-shot bulk script | Run during deployment to create labels in all owned repos with proper error filtering and `set -o pipefail` (Section 7.2) |
| `state.filed_issues` schema | List of `{number, cluster, kind}` records (Section 6.1) |
| `state.context_limit_tokens` | New project-level field; default 200000, user sets to 1000000 for 1M tier (Section 6.1) |

**No migration logic.** Pre-upgrade chains (state file lacks `filed_issues` field) complete under v0.1 behavior; new chains write `filed_issues` and use new behavior. Decisions file mechanism retired only for new chains (Section 10).
