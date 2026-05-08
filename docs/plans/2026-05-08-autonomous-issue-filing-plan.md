---
codex_thread_id: 019e08e2-e245-7c61-acbd-91601d090978
codex_plan_review_status: in_review
---

# Autonomous Issue Filing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Land the v0.2 enhancement designed in `2026-05-08-autonomous-issue-filing-design.md` — replace the per-chain decisions file with structured GitHub issues, add an in-skill context-budget gate to push more fixes in-session, and bind all state-file writers to a single contract so the pre-upgrade detection rule works.

**Architecture:** Markdown-only edits across 3 skill bodies, 6 commands, and a new bash script. No runtime code, no test harness. Verification is per-task: re-read the edited section, spot-check state-file output via the actual commands, shellcheck the bash script. The implementation chain ends with `codex-impl-review` against the final diff.

**Tech Stack:** Markdown skills (Claude Code plugin format), bash scripts, `gh` CLI, Codex MCP integration. No Python, no Node.

**Design doc:** `docs/plans/2026-05-08-autonomous-issue-filing-design.md` (Codex-approved after 5 rounds; hash `38a350fc…3260` in frontmatter). All section references below point into this doc.

**Pre-upgrade compatibility:** This work is for a chain that started AFTER the design landed. The chain's state file (`.claude/cross-model-review.session.local.md`) already has `codex_thread_id` and the active chain set; `filed_issues` will be added in Phase 1. Pre-upgrade detection (Phase 3) is the rule for *future* chains, not this one.

**Commit cadence:** one commit per phase. Conventional Commits style; messages reference the design section that drove the change.

---

## Phase 1: State-file write protocol across all 8 writers

Bind every state-file writer to the contract from design Section 6.1: fresh writes emit `filed_issues: []` and `context_limit_tokens: 200000`; updates preserve both verbatim; `/cross-model-reset` preserves `context_limit_tokens` and sets `filed_issues: []`.

**Files:**
- Modify: `commands/cross-model-reset.md` (state defaults block)
- Modify: `commands/cross-model-autonomous-on.md` (state-touch behavior)
- Modify: `commands/cross-model-autonomous-off.md` (state-touch behavior)
- Modify: `commands/cross-model-skip.md` (state-touch behavior)
- Modify: `commands/cross-model-review-now.md` (state-touch behavior)
- Modify: `skills/codex-impl-review/SKILL.md` (Bootstrap step 2 fresh-state branch)
- Modify: `skills/codex-plan-review/SKILL.md` (Bootstrap step 2 fresh-state branch)
- Modify: `skills/codex-brainstorm-partner/SKILL.md` (Bootstrap step 1 fresh-state branch)

**Step 1: Update `commands/cross-model-reset.md` defaults block.** In the YAML defaults, change `context_limit_tokens: null` is NOT what we want — instead, keep `context_limit_tokens` whatever the previous state file held (preserved across reset), and add `filed_issues: []`. Add a note above the defaults block: *"Reset preserves `context_limit_tokens` (user-tuned project config) and sets `filed_issues: []` (reset establishes a fresh new-regime chain)."* Update step 4 of the command to read the existing `context_limit_tokens` first if the state file is present, default to `200000` only if creating from scratch.

**Step 2: Update `commands/cross-model-autonomous-on.md` step 1.** The "create with defaults if missing" branch must include `filed_issues: []` and `context_limit_tokens: 200000`. The "update existing" branch (step 2) preserves both fields verbatim — only flips `autonomous: true`.

**Step 3: Update `commands/cross-model-autonomous-off.md` step 1.** Same shape — fresh-create branch emits both new fields; update branch preserves them.

**Step 4: Update `commands/cross-model-skip.md` step 1.** Same.

**Step 5: Update `commands/cross-model-review-now.md` step 2.** Same.

**Step 6: Update `skills/codex-impl-review/SKILL.md` Bootstrap step 2.** In the PERSISTED-mode `If absent` branch (lines around the "write fresh state file with defaults" instruction), specify that the fresh state must include `filed_issues: []` and `context_limit_tokens: 200000`. Add a sentence to the skill's preamble: *"State-file writes follow the contract in design Section 6.1: fresh writes always emit `filed_issues: []` and `context_limit_tokens: 200000`; updates preserve both verbatim."*

**Step 7: Update `skills/codex-plan-review/SKILL.md` Bootstrap step 2.** Same edit pattern as Step 6.

**Step 8: Update `skills/codex-brainstorm-partner/SKILL.md` Bootstrap step 1.** Same.

**Step 9: Verify by static grep — non-destructive.**

The active chain in this repo's state file must not be mutated during verification (this implementation runs in the live session). Verify by grepping the edited markdown directly to confirm each writer's fresh-state branch emits the new fields, and that update branches preserve them:

```bash
cd C:/Users/tim/OneDrive/Documents/Projects/cross-model-review

# Each writer's source must mention both new fields somewhere in its body
for f in commands/cross-model-reset.md \
         commands/cross-model-autonomous-on.md \
         commands/cross-model-autonomous-off.md \
         commands/cross-model-skip.md \
         commands/cross-model-review-now.md \
         skills/codex-impl-review/SKILL.md \
         skills/codex-plan-review/SKILL.md \
         skills/codex-brainstorm-partner/SKILL.md; do
  if grep -q "filed_issues" "$f" && grep -q "context_limit_tokens" "$f"; then
    echo "OK:   $f"
  else
    echo "MISSING: $f" >&2
  fi
done
```

Expected: every line is `OK: <path>`. Any `MISSING: …` line means the corresponding edit didn't land — re-open that file and add the field references.

Do NOT delete the live state file or invoke any review skill / state-touching command as part of verification — those would mutate the active chain or set the skip flag and suppress a subsequent review.

**Step 10: Commit.**

```bash
git add commands/ skills/
git commit -m "feat: state-file writer contract for filed_issues + context_limit_tokens (design §6.1)"
```

---

## Phase 2: Codex universal priming — parseable tag-line spec

Add the parseable tag-line specification from design Section 8 to the universal priming text. The block appears verbatim in three skill bodies (`codex-plan-review`, `codex-impl-review`, `codex-brainstorm-partner`) and must be edited identically in all three.

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md` (Universal Codex priming section)
- Modify: `skills/codex-impl-review/SKILL.md` (Universal Codex priming section)
- Modify: `skills/codex-brainstorm-partner/SKILL.md` (Universal Codex priming section)

**Step 1: Locate the priming block.** In each skill, find the `## Universal Codex priming` section. The priming text is inside a fenced block. The "Modes details" subsection has three numbered items; the new tag-line spec is appended to item 2 ("Design / plan / diff review").

**Step 2: Append the new spec to all three priming blocks.** After the existing item-2 paragraph in each, add the block from design Section 8 verbatim — the parseable tag-line definition, severity/scope/cluster semantics, and the "user-decision marker takes precedence over severity" note.

**Step 3: Verify identical text across all three skills.**

```bash
diff <(awk '/^You are participating/,/^If at any point/' skills/codex-plan-review/SKILL.md) \
     <(awk '/^You are participating/,/^If at any point/' skills/codex-impl-review/SKILL.md)
diff <(awk '/^You are participating/,/^If at any point/' skills/codex-plan-review/SKILL.md) \
     <(awk '/^You are participating/,/^If at any point/' skills/codex-brainstorm-partner/SKILL.md)
```

Both diffs must be empty.

**Step 4: Commit.**

```bash
git add skills/
git commit -m "feat: parseable tag-line spec in universal priming (design §8)"
```

---

## Phase 3: Pre-upgrade chain detection at every gate's bootstrap

Implement the rule from design Section 10 in all three review-skill bootstraps. Detection: state file absent → fresh chain (write `filed_issues: []`, use new behavior); state file present + `filed_issues` field present → new-regime chain; state file present + field absent → pre-upgrade chain (use v0.1 behavior, do NOT add the field).

**Files:**
- Modify: `skills/codex-impl-review/SKILL.md` (Bootstrap, after step 2)
- Modify: `skills/codex-plan-review/SKILL.md` (Bootstrap, after step 2)
- Modify: `skills/codex-brainstorm-partner/SKILL.md` (Bootstrap, after step 1)

**Step 1: Add a new bootstrap step (call it step 2.5 or insert as step 3 with renumber) to each review skill.** The step:

```markdown
2.5. **Pre-upgrade chain detection.** After loading state in step 2, classify
   the chain regime:
   - State file was just created fresh → set `regime = new`. The fresh state
     write already emitted `filed_issues: []`.
   - State file existed AND has `filed_issues` field (even if empty list) →
     set `regime = new`.
   - State file existed AND has NO `filed_issues` field → set
     `regime = pre-upgrade`. Do NOT add the field — its absence is the
     durable marker.

   `regime` is consulted later in defer paths (Section 5.8) and PR-construction
   paths to choose between issue-filing (new) and decisions-file (pre-upgrade).
```

**Step 2: Update each skill's "State updates" / "Response handling" sections** to reference `regime`. Where the original v0.1 path writes to the decisions file, wrap with `if regime == "pre-upgrade"`. Where the new design files an issue, wrap with `if regime == "new"`.

**Step 3: Verify by reading the bootstrap of each skill end-to-end.** The detection rule must fire BEFORE any defer-path or chain-update logic. Order matters — chain-update happens before MCP call, but regime-detection happens before chain-update so user-input deferrals at design-review correctly route by regime.

**Step 4: Commit.**

```bash
git add skills/
git commit -m "feat: pre-upgrade chain detection at bootstrap (design §10)"
```

---

## Phase 4: codex-plan-review — common entry check + apply-to-doc routing

Restructure `codex-plan-review`'s response-handling loop per design Section 4. Common entry check (user-input → defer to `design-input-needed` issue, regardless of severity) followed by mode-specific routing (substantive critique → revise doc; loop until approved).

**Files:**
- Modify: `skills/codex-plan-review/SKILL.md` (Response handling loop section)

**Step 1: Add a tag-line parser sub-section** under "Response handling loop." The parser regex-extracts `severity`, `scope`, `cluster` from each finding's first-line tag block per design Section 4.1. Defaults: `severity=minor`, `scope=n-a` (design/plan), `cluster=solo-<sha8(finding-text)>`.

**Step 2: Replace the existing branch 2 ("User-bound question") logic** with the routing from design Section 4's common entry check:

- If user-input flagged → batch-defer to `design-input-needed` issue (autonomous, new regime) OR ask-in-chat (interactive) OR write to decisions file (pre-upgrade regime). The issue-filing path uses the helper to be added in Phase 6.
- Otherwise → continue to mode-specific routing (branch 3 substantive critique).

**Step 3: Branch 3 stays mostly as-is** but document explicitly: at `design-review` and `plan-review`, "substantive critique" means revise the doc, not file an `autonomous-safe` issue. SCOPE is `n-a` here. There are no code fixes at these gates.

**Step 4: Verify by re-reading the routing block.** Trace through three scenarios mentally: (a) Codex flags a UI-judgment item with `severity=critical` — must defer to issue, not force-fix the doc; (b) Codex flags a code-only design flaw — must revise doc; (c) Codex approves — exits per existing on-APPROVAL behavior.

**Step 5: Commit.**

```bash
git add skills/codex-plan-review/SKILL.md
git commit -m "feat: codex-plan-review routing with common entry check (design §4)"
```

---

## Phase 5: codex-impl-review — common entry check + impl-specific routing with budget gate

Restructure `codex-impl-review`'s response-handling loop per design Section 4. Common entry check (same as Phase 4) plus impl-specific paths: CRITICAL/IMPORTANT → fix-loop; MINOR + code-only → fix-or-defer based on context-budget signal.

**Files:**
- Modify: `skills/codex-impl-review/SKILL.md` (Response handling loop section)

**Step 1: Add the same tag-line parser sub-section as Phase 4** to `codex-impl-review`. Same regex; this time `scope` is consumed (small/medium/large drives the budget gate).

**Step 2: Restructure the response-handling branches.** Replace the current MINOR / IMPORTANT / CRITICAL severity-routing with:

```markdown
### Routing (design §4 impl-review path)

For each finding (or cluster):

1. **Common entry check (regardless of severity):** if user-input flagged →
   batch-defer to `design-input-needed` issue (autonomous, new regime) OR
   ask-in-chat (interactive) OR write to decisions file (pre-upgrade regime).
   User-input check **outranks severity**.

2. Otherwise:
   - SEVERITY = critical OR important → existing fix-loop (subagent dispatch
     per cluster). Codex won't approve until these are resolved.
   - SEVERITY = minor (code-only):
     a. Run the context-budget probe (Section 6 of design; concrete steps in
        Phase 9 of this plan).
     b. If `pct < threshold_low` AND `scope == small` → inline fix.
     c. If `pct < threshold_high` AND `scope ∈ {small, medium}` → subagent
        fix (offloads context).
     d. Else → batch-defer to `autonomous-safe` issue.

   Specific thresholds: `threshold_low = 70%`, `threshold_high = 85%`.
```

**Step 3: Update the "Findings handled outcome-based" sub-section** to reflect the new routing. Replace the v0.1 wording about MINOR-as-deferred-in-PR with the new SCOPE-driven dispatch.

**Step 4: Verify by re-reading.** Trace: CRITICAL user-input → defers (entry check wins). MINOR small-scope at 50% → inline fix. MINOR medium-scope at 90% → defer issue. CRITICAL code-only → fix-loop unchanged.

**Step 5: Commit.**

```bash
git add skills/codex-impl-review/SKILL.md
git commit -m "feat: codex-impl-review routing with budget gate (design §4)"
```

---

## Phase 6: Issue-filing helper section in both review skills

Add a shared helper section that documents how to file an issue (title format, body format, batching by cluster). This is invoked by Phase 4 and Phase 5's defer paths.

**Files:**
- Modify: `skills/codex-impl-review/SKILL.md` (new section after Response handling loop)
- Modify: `skills/codex-plan-review/SKILL.md` (new section after Response handling loop)

**Step 1: Author the helper section once.** The shape, per design Sections 5.1-5.3:

```markdown
## Issue filing (autonomous mode, new-regime chains)

When a defer-path routes to issue-filing:

1. **Group by cluster.** Findings sharing a `cluster` tag from the parser
   batch into one issue. If a cluster mixes `autonomous-safe` and
   `design-input-needed` defers, split into two issues — one per kind.

2. **Compose the title.** Format: `[<chain-stem>] <imperative description>`.
   Stem is the existing stem-matching algorithm (design doc §9.2).
   For anchorless impl-only chains, stem is `branch:<branch-name>`.

3. **Compose the body.** Use the appropriate template from design §5.3:
   - `autonomous-safe`: Context / Findings (with cluster name) / Suggested
     approach / Acceptance criteria / bot footer.
   - `design-input-needed`: Context / Decision needed / Default applied /
     How to resolve / bot footer.

4. **Run the defer-path preconditions** (Section 5.8 — three checks).
   See Phase 7 for the concrete Bash invocations.

5. **File via `gh issue create`, capturing the issue number.** `gh issue
   create` writes the new issue's URL to stdout (e.g.,
   `https://github.com/owner/repo/issues/123`). Capture that URL, extract
   the trailing number, append `{number, cluster, kind}` to
   `state.filed_issues`.

6. **Bidirectional cross-link** (impl-review's PR-creation closer; not
   immediate). When the PR is opened, this skill runs `gh issue comment <num>`
   on each filed issue: "Originally filed during PR #N: <url>".

`gh issue create` invocation pattern with number capture:

\`\`\`bash
issue_url=$(gh issue create \
  --title "[<chain-stem>] <description>" \
  --body "$(cat <<'EOF'
<body content>
EOF
)" \
  --label "<autonomous-safe|design-input-needed>")

# Extract trailing number from the URL gh prints
issue_number="${issue_url##*/}"
\`\`\`

The `${var##*/}` parameter expansion strips everything up to and
including the last `/`, leaving just the issue number. Then append
`{number: $issue_number, cluster: "<cluster-name>", kind: "<label>"}`
to `state.filed_issues` and write state.

If `gh issue create` fails (non-zero exit or empty stdout despite
success), surface as a halt per the precondition table in Section 5.8 —
the issue was supposed to be filed but isn't, so the chain cannot be
considered safely deferred.
```

**Step 2: Add the section verbatim to both skills.** The text is identical between `codex-plan-review` and `codex-impl-review`; both need their own copy (per the "no shared `prompts/` directory" architecture in MANIFEST.md).

**Step 3: Verify identical sections.**

```bash
diff <(awk '/^## Issue filing/,/^## /' skills/codex-plan-review/SKILL.md | head -n -1) \
     <(awk '/^## Issue filing/,/^## /' skills/codex-impl-review/SKILL.md | head -n -1)
```

Diff must be empty (modulo any skill-specific deviation, which should be flagged).

**Step 4: Commit.**

```bash
git add skills/
git commit -m "feat: issue-filing helper in both review skills (design §5.1-5.3)"
```

---

## Phase 7: Defer-path preconditions (3 checks) wired into the issue-filing helper

Add the runtime ownership + gh auth + gh issue list precondition checks per design Section 5.8.

**Files:**
- Modify: `skills/codex-impl-review/SKILL.md` (Issue filing section from Phase 6)
- Modify: `skills/codex-plan-review/SKILL.md` (Issue filing section from Phase 6)

**Step 1: Add a "Defer-path preconditions" sub-section to each skill's Issue filing helper.** Per design Section 5.8:

```markdown
### Defer-path preconditions

Before any `gh issue create`, run these three checks IN ORDER. All three
must pass; first failure routes to halt-or-chat per the failure table below.

1. **Ownership.**
   \`\`\`bash
   git remote get-url origin | grep -E "TimSimpsonJr/|TimSimpsonJr:" || exit 1
   \`\`\`
   Non-zero → ownership precondition failed.

2. **gh auth.**
   \`\`\`bash
   gh auth status >/dev/null 2>&1
   \`\`\`
   Non-zero → auth precondition failed.

3. **gh issue list.**
   \`\`\`bash
   gh issue list --limit 1 >/dev/null 2>&1
   \`\`\`
   Non-zero → repo-issues precondition failed (issues disabled, no
   GitHub remote, etc.).

On any precondition failure:
- Autonomous + design/plan-review gate → `state.chain_status = halted`;
  post chat note naming which precondition failed.
- Autonomous + impl-review mid-loop → halt; write halt note to
  `.claude/cross-model-review/halts/<chain-stem>.md`.
- Autonomous + impl-review PR-creation closer → existing draft-PR halt
  path; include unfiled defer payloads in the fallback section.
- Interactive → post chat note describing failure; user resolves and
  re-invokes. For ownership specifically, the note explains the policy:
  "This repo is not owned by you, so the cross-model-review labeling
  convention doesn't apply. The plugin will not file issues here."
```

**Step 2: Add to both skills (identical text).**

**Step 3: Verify identical between skills.**

```bash
diff <(awk '/^### Defer-path preconditions/,/^### /' skills/codex-plan-review/SKILL.md | head -n -1) \
     <(awk '/^### Defer-path preconditions/,/^### /' skills/codex-impl-review/SKILL.md | head -n -1)
```

**Step 4: Commit.**

```bash
git add skills/
git commit -m "feat: defer-path preconditions (ownership + gh auth + issues) (design §5.8)"
```

---

## Phase 8: Re-flag prevention (framing line + defensive parser)

Per design Section 5.5: each Codex round's framing line lists already-filed clusters; the response parser also defensively filters Codex's findings against `state.filed_issues[*].cluster`.

**Files:**
- Modify: `skills/codex-impl-review/SKILL.md` (Codex MCP call section + Response handling loop)
- Modify: `skills/codex-plan-review/SKILL.md` (same)

**Step 1: Add framing-line construction logic in the "Codex MCP call" section** of each skill. Just before constructing the MCP prompt, build a string from `state.filed_issues`:

```markdown
**Re-flag prevention framing.** If `state.filed_issues` is non-empty,
prepend to the artifact content:

> Already filed as issues in this chain (do not re-flag):
> cluster=<name> issue #N, cluster=<name> issue #N, ...

Use cluster names from state, not titles (titles can be edited; clusters
are durable).
```

**Step 2: Add defensive parser logic in Response handling loop.** After the tag-line parser extracts `cluster` from each finding:

```markdown
**Defensive re-flag filter.** For each parsed finding, check whether its
cluster matches any `state.filed_issues[*].cluster`. If yes, treat the
finding as a no-op for this round (Codex re-surfaced an already-deferred
concern despite the framing). Log a one-line chat note: "Codex re-flagged
already-filed cluster '<name>' (issue #N); ignored."
```

**Step 3: Add to both skills.**

**Step 4: Verify by tracing:** simulate `state.filed_issues = [{number: 100, cluster: foo, kind: autonomous-safe}]`. Codex returns a finding tagged `cluster:foo`. The parser must see the match and skip. Confirm by re-reading the response-handling section.

**Step 5: Commit.**

```bash
git add skills/
git commit -m "feat: cluster-based re-flag prevention (design §5.5)"
```

---

## Phase 9: In-skill context-budget probe (codex-impl-review only)

Add the probe procedure from design Section 6 to `codex-impl-review`. The probe runs at each fix-vs-defer decision in the impl-review loop and produces `pct` for the routing gate added in Phase 5.

**Files:**
- Modify: `skills/codex-impl-review/SKILL.md` (new section before Response handling loop)

**Step 1: Add the probe procedure as a new section.** Place it before "Response handling loop" so the routing logic in Phase 5 can refer to it:

```markdown
## Context-budget probe (impl-review only)

Run this probe at each fix-vs-defer decision. Produces `pct` (estimated
working-context usage as a percentage). Per design §6.

### Probe procedure

1. **Resolve project's transcript directory.**
   \`\`\`bash
   toplevel=$(git rev-parse --show-toplevel)
   \`\`\`
   Then transform `toplevel` by replacing each `:`, `/`, and `\` with `-`.
   Claude does this in-prompt — produces a string Claude assigns to a
   conceptual `encoded` variable used in the next step. Example: a
   Windows toplevel `C:/Users/tim/proj` becomes the encoded form
   `C--Users-tim-proj`. (Encoding is mechanical; no shell needed for it.)

2. **Find this project's newest transcript.** Use Glob with the literal
   pattern `~/.claude/projects/<the encoded value>/*.jsonl` — Claude
   substitutes the value from step 1 into the pattern string. Glob
   returns newest-first by mtime. Take the first result and assign it
   to `transcript`. If no matches → treat `pct = 0` (fresh session);
   proceed default-to-fix.

3. **Read size.**
   \`\`\`bash
   bytes=$(wc -c < "$transcript")
   \`\`\`
   Note: `<` here is shell input redirection, and `"$transcript"` is the
   path captured in step 2. The double-quoted variable handles paths with
   spaces. `wc -c` over stdin emits just the byte count (no filename
   prefix), which is what we want for the arithmetic in step 4.

4. **Compute percentage.**
   \`\`\`bash
   pct=$(( bytes * 100 / 4 / context_limit_tokens ))
   \`\`\`
   `context_limit_tokens` comes from state (defaults to 200000; user
   sets 1000000 for 1M tier). The `bytes / 4` is a rough char-to-token
   approximation. The `* 100` and final `/ context_limit_tokens` give a
   percentage. Order matters in integer arithmetic: multiplying by 100
   before dividing avoids zero from rounding.

### Sampling

Once per fix-vs-defer decision is sufficient. Do NOT run on every tool
call; the probe is a soft signal, not a real-time tracker.

### Approximation caveats

- Captures working-session context only. Subagent context offloaded
  intentionally.
- Bytes/4 is a rough char-to-token approximation.
- Does not account for prompt-cache state.

These caveats are acceptable for v1; a more accurate probe is v0.2 work.
```

**Step 2: Verify the probe section is referenced from Phase 5's routing block.** Search the response-handling section for `Run the context-budget probe` (or equivalent); it should point to this new section.

**Step 3: Commit.**

```bash
git add skills/codex-impl-review/SKILL.md
git commit -m "feat: in-skill context-budget probe (design §6)"
```

---

## Phase 10: PR cross-link + bidirectional cross-link (codex-impl-review)

Per design Sections 5.6 and 5.7: when the impl-review PR is created, its description includes "## Filed for follow-up" listing issues with titles (re-fetched via `gh issue view`); after PR creation, each filed issue gets a `gh issue comment` linking back.

**Files:**
- Modify: `skills/codex-impl-review/SKILL.md` (Termination handoff section)

**Step 1: Update the autonomous-mode PR-creation block.** Where the PR description is constructed (currently mentions "Decisions deferred to your review" pasted from decisions file), branch on `regime`:

```markdown
**PR description "Filed for follow-up" section (regime = new):**

For each entry in `state.filed_issues`:
\`\`\`bash
title=$(gh issue view <number> --json title --jq .title)
\`\`\`
Then assemble:
\`\`\`markdown
## Filed for follow-up

- #123 (autonomous-safe): Extract query builder into separate module
- #124 (design-input-needed): Decide cache backend: in-memory vs Redis
\`\`\`

**PR description (regime = pre-upgrade):**

Use existing v0.1 behavior — paste decisions-file contents verbatim into a
"Decisions deferred to your review" section. (No change.)
```

**Step 2: Add bidirectional cross-link after PR creation succeeds (regime = new only).**

```markdown
**Bidirectional cross-link.** After `gh pr create` returns the PR URL,
for each entry in `state.filed_issues`:

\`\`\`bash
gh issue comment <number> --body "Originally filed during PR #<pr-num>: <pr-url>"
\`\`\`

Best-effort: if `gh issue comment` fails for any individual issue, log
the failure to the halt note but do NOT halt the chain — the PR
already exists and is the load-bearing artifact.
```

**Step 3: Verify the chain_status: completed transition** still happens after PR creation in the new regime, same as v0.1.

**Step 4: Commit.**

```bash
git add skills/codex-impl-review/SKILL.md
git commit -m "feat: PR cross-link to filed issues + bidirectional comment (design §5.6, §5.7)"
```

---

## Phase 11: /cross-model-setup refactor — insert gh-validation + label-creation steps

Per design Section 9: insert new step 3 (gh validation + ownership), insert new step 7 (label creation in owned repos), refactor existing step 6 (now step 8) to per-rule install. Renumber 3-7 to 4-8.

**Files:**
- Modify: `commands/cross-model-setup.md`

**Step 1: Insert new step 3 after Superpowers verification.** Per design §9.1:

```markdown
3. **Verify gh + ownership check.**

   a. Run `gh auth status`. If non-zero exit:
      - Output: "GitHub CLI is not authenticated. Run `gh auth login`
        and re-run /cross-model-setup. Skipping label creation; the
        plugin's review-and-fix flows still work, but it will halt
        if it tries to defer in autonomous mode."
      - Mark labels-step (step 7 below) as SKIP for this run.

   b. Run `git remote get-url origin` and check for `TimSimpsonJr/`
      or `TimSimpsonJr:` in the result.
      - If matches → owned-repo flag = TRUE.
      - If no match → owned-repo flag = FALSE; output:
        "Repo is not owned by TimSimpsonJr. Skipping plugin label
        creation per the global ownership rule (~/.claude/CLAUDE.md).
        The plugin will halt if it tries to file an issue here —
        intentional."
        Mark labels-step as SKIP.
```

**Step 2: Renumber existing steps 3-7 to 4-8.** Update internal references (e.g., the existing step 8 "idempotent" footer's reference to step numbers).

**Step 3: Insert new step 7 (between Apply CLAUDE.md and Verify hookify).** Per design §9.2:

```markdown
7. **Create plugin labels in current repo.** Skipped if step 3 marked
   labels-step as SKIP.

   For each label in [autonomous-safe, design-input-needed]:
   \`\`\`bash
   gh label create <name> --color <c> --description <d>
   \`\`\`

   Filter stderr per the bulk-script pattern in design §7.2: "already
   exists" → silent skip; any other error → surface with the label name.

   Label color/description constants:
   - autonomous-safe: color=0E8A16, description="Code-only follow-up;
     eligible for autonomous pickup"
   - design-input-needed: color=D93F0B, description="Requires user
     judgment before work proceeds"
```

**Step 4: Refactor existing hookify step (now step 8) to per-rule install.** Replace the "if both exist, skip" short-circuit with:

```markdown
   For EACH planned rule file:
     - Check if file exists.
     - If absent → write the rule body verbatim.
     - If present → skip silently.

   No "if all exist" early-exit; future rule additions land cleanly.
```

**Step 5: Verify step numbering.** Read the entire setup file; ensure no dangling references to old numbers.

**Step 6: Commit.**

```bash
git add commands/cross-model-setup.md
git commit -m "feat: /cross-model-setup gh-validation + label-creation + per-rule hookify (design §9)"
```

---

## Phase 12: /cross-model-status — filed-issues block + hooks status one-liner

Per design Section 6.2: replace pending-decisions output with filed-issues block (regime = new) or keep pending-decisions (regime = pre-upgrade). Collapse hooks reporting to one line.

**Files:**
- Modify: `commands/cross-model-status.md`

**Step 1: Update the PERSISTED-state output template.** Replace the "Pending decisions" block with a regime-dependent block:

```markdown
**Filed issues block (regime = new):**

Filed issues (this chain):
   #123 (autonomous-safe):    <title from gh issue view>
   #124 (design-input-needed): <title from gh issue view>

(or "(none)" if state.filed_issues is empty)

**Pending decisions block (regime = pre-upgrade):**

Pending decisions: N items in .claude/cross-model-review/decisions/<basename>.md
   <handle>: <one-line summary>
   ...
```

The status command's own logic decides which to show based on the regime check from Phase 3.

**Step 2: Add the hooks status one-liner.** After the "Skip flag" line, add:

```markdown
Hooks: N of M installed (re-run /cross-model-setup to add missing).
```

The "(re-run …)" suffix only appears when N < M. Currently M = 2 (the two hookify rules); could grow if future versions add more.

**Step 3: Implement the per-rule hooks check.** In the status command's bash:

```bash
# Enumerate planned rule files
PLANNED=(
  ".claude/hookify.cross-model-plan-review.local.md"
  ".claude/hookify.cross-model-impl-review.local.md"
)
installed=0
for f in "${PLANNED[@]}"; do
  [ -f "$f" ] && installed=$((installed + 1))
done
total=${#PLANNED[@]}
```

**Step 4: Verify by re-reading the status output template.** All three formats (PERSISTED, EPHEMERAL, NONE) should still be coherent. EPHEMERAL doesn't have filed_issues persistence so it shows decisions-only; NONE shows nothing.

**Step 5: Commit.**

```bash
git add commands/cross-model-status.md
git commit -m "feat: /cross-model-status filed-issues block + hooks one-liner (design §6.2, §9.4)"
```

---

## Phase 13: Bulk label creation script

Create `scripts/bulk-create-labels.sh` per design Section 7.2 verbatim.

**Files:**
- Create: `scripts/bulk-create-labels.sh`

**Step 1: Create the script directory.**

```bash
mkdir -p C:/Users/tim/OneDrive/Documents/Projects/cross-model-review/scripts
```

**Step 2: Write the script verbatim from design §7.2.** Includes `set -euo pipefail`, separate-producer pattern, failure accumulator, exit codes 0/2/3/4, etc.

**Step 3: Make executable.**

```bash
chmod +x scripts/bulk-create-labels.sh
```

**Step 4: Syntax check.**

```bash
bash -n scripts/bulk-create-labels.sh
```

Expected: silent (zero output, exit 0).

**Step 5: Optional: shellcheck if available.**

```bash
shellcheck scripts/bulk-create-labels.sh 2>/dev/null || echo "shellcheck not installed; skipping"
```

If shellcheck is installed, address any warnings before committing. If unavailable, that's fine — the design's script was already reviewed by Codex.

**Step 6: Commit.**

```bash
git add scripts/bulk-create-labels.sh
git commit -m "feat: bulk-create-labels.sh script (design §7.2)"
```

---

## Phase 14: Plugin version bump + CHANGELOG + MANIFEST.md update

Bump version to 0.2.0, document changes, refresh MANIFEST.md to reflect the new `scripts/` directory.

**Files:**
- Modify: `.claude-plugin/plugin.json` (version field)
- Modify: `CHANGELOG.md` (new 0.2.0 entry)
- Modify: `MANIFEST.md` (add scripts/, note new behavior)
- Modify: `README.md` (only if user-facing usage changed)

**Step 1: Bump plugin.json version.** Change `"version": "0.1.0"` to `"version": "0.2.0"`.

**Step 2: Add CHANGELOG entry.**

```markdown
## 0.2.0 — 2026-05-08

### Added
- Structured GitHub issue filing for deferred items, replacing the
  per-chain decisions-file → PR-description-paste mechanism. Two labels:
  `autonomous-safe` (code-only follow-ups) and `design-input-needed`
  (user-judgment items).
- In-skill context-budget probe at impl-review fix-vs-defer decisions.
  Reads transcript size for the current project; routes minor findings
  to inline fix / subagent fix / autonomous-safe issue based on
  estimated context %.
- `state.filed_issues` schema: list of `{number, cluster, kind}` records
  scoped to the active chain.
- `state.context_limit_tokens` field: project-level, default 200000;
  user sets 1000000 for the 1M-context tier.
- `scripts/bulk-create-labels.sh`: one-shot script to create the two
  plugin labels across all owned repos with proper error filtering.
- Three-precondition defer-path check (ownership + gh auth + gh issue
  list) at issue-filing time.
- Cluster-based re-flag prevention so deferred-but-unfixed items don't
  trigger Codex's adversarial re-surfacing.

### Changed
- Routing rule restructured: user-input check now outranks severity. A
  CRITICAL UI judgment call defers to a `design-input-needed` issue
  rather than being force-fixed.
- Codex universal priming: parseable tag-line spec
  (`[severity:..., scope:..., cluster:...]`) at the start of each
  finding so the skill body can route reliably.
- `/cross-model-setup` adds new step 3 (gh validation + ownership check)
  and new step 7 (label creation in owned repos). Existing hookify-rule
  install (now step 8) refactored to per-rule check so future rule
  additions land on existing installs.
- `/cross-model-status` shows filed-issues block (new chains) or
  pending-decisions (pre-upgrade chains), plus a one-line hooks-installed
  summary.
- PR description's "Filed for follow-up" section replaces "Decisions
  deferred to your review" for new chains. Bidirectional cross-link:
  each filed issue gets a `gh issue comment` pointing back to the PR.

### Pre-upgrade compatibility
- Chains established under v0.1 (state file lacks `filed_issues` field)
  complete on old behavior — decisions file still written/read,
  PR-description-paste preserved. New chains use new behavior. No
  auto-migration; chains commit to one regime at first establishment.

### Design doc
- `docs/plans/2026-05-08-autonomous-issue-filing-design.md`
  (Codex-approved, hash `38a350fc…3260` in frontmatter)
```

**Step 3: Update MANIFEST.md.**

- Add `scripts/bulk-create-labels.sh` to the Structure tree.
- Update the Stack section's bullet count if the count changed.
- Add a Key Relationships entry for the issue-filing helper duplication ("two skills' Issue filing sections must stay in sync; verified by diff in Phase 6 of the v0.2 plan").

**Step 4: Update README.md ONLY if user-facing setup changed.** Re-read README; if the install instructions don't mention re-running `/cross-model-setup` after upgrade, add a "Upgrading from v0.1" section noting that existing installs should re-run setup to pick up the new gh-validation and label-creation steps.

**Step 5: Verify by reading each updated file.**

**Step 6: Commit.**

```bash
git add .claude-plugin/plugin.json CHANGELOG.md MANIFEST.md README.md
git commit -m "chore: bump to 0.2.0; document autonomous issue filing"
```

---

## Phase 15: Codex impl-review (the closer)

After all 14 phases above commit cleanly, the implementation chain ends with `codex-impl-review` against the full diff. The skill body itself runs the review — no manual step here beyond invoking it.

**Step 1: Verify all phases committed.**

```bash
git log --oneline main..HEAD
```

Should show roughly 14 commits, one per phase, plus this plan's commit and any commits made during the design-review chain.

**Step 2: Invoke codex-impl-review.** This skill auto-triggers when `subagent-driven-development` or `executing-plans` finishes per its skill description. If working under autonomous mode, the skill itself handles the review loop, fix-loop dispatch, and PR creation.

**Step 3: On Codex approval → autonomous mode opens the PR via `gh pr create`** with the new "Filed for follow-up" section (Phase 10) populated from `state.filed_issues`.

**Step 4: Run the bulk label creation script (manual, post-merge).**

```bash
bash scripts/bulk-create-labels.sh
```

This is a one-shot to back-fill labels into existing owned repos. Not part of the implementation diff — runs after the PR merges.

---

## Notes for the executor

- **No tests in the traditional sense.** This is markdown configuration, not runtime code. Verification is per-task (re-read the section, spot-check a state-file write, syntax-check bash). The end-to-end test is Codex's impl-review at Phase 15.

- **Mandatory bash syntax check for every embedded snippet.** Every phase that embeds new bash inside a skill or command body — currently Phases 6, 7, 9, 10, 11, 12, 13 — MUST include this verification step before commit. (Phase 1 emits no new bash inside the writers; its writers' YAML defaults blocks aren't shell, so it's exempt.) The principle: any time you add a new fenced ` ```bash ` block to a skill or command body, syntax-check it. Run:

  1. Extract every fenced bash block from the file you just edited:
     \`\`\`bash
     awk '/^```bash$/,/^```$/' <edited-file> | grep -v '^```' > /tmp/extracted.sh
     \`\`\`
  2. Syntax-check:
     \`\`\`bash
     bash -n /tmp/extracted.sh
     \`\`\`
     Expected: silent, exit 0. Any error → fix the snippet before committing.
  3. Optional shellcheck for additional rigor (warnings only — informational, not blocking):
     \`\`\`bash
     shellcheck /tmp/extracted.sh 2>/dev/null || true
     \`\`\`
  4. Clean up: `rm /tmp/extracted.sh`.

  This catches malformed redirections, unquoted variables, missing
  delimiters — exactly the class of bug that slipped through plan-review
  round 1.

- **No worktree assumed.** This plan is being executed in the cross-model-review repo's `main` branch directly per the user's autonomous-mode session. If the executor wants worktree isolation, switch to a feature branch before Phase 1.

- **Frequent commits.** One commit per phase. Conventional Commits style. Reference the design section in the message.

- **DRY duplication intentional.** The Issue filing helper (Phase 6) and Defer-path preconditions (Phase 7) are duplicated across `codex-plan-review` and `codex-impl-review` because the plugin's architecture is "no shared `prompts/` directory" (per MANIFEST.md). Verify identical with `diff` after each.

- **Push to remote at the end of Phase 14.** Phase 15 (Codex impl-review) is the closer; in autonomous mode it opens the PR after approval.

---

**Plan complete and saved to `docs/plans/2026-05-08-autonomous-issue-filing-plan.md`.**

Per autonomous mode: proceeding to Codex `plan-review` next.
