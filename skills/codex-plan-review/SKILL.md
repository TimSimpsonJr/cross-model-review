---
name: codex-plan-review
description: Use immediately after a design doc is written to docs/plans/ before invoking writing-plans, OR immediately after writing-plans saves an implementation plan. Reviews the artifact adversarially via Codex MCP. Triggers on phrases like "design doc written", "design saved to docs/plans/", "plan complete", "plan saved to docs/plans/", "ready for implementation", "ready to write the plan".
---

# codex-plan-review

Adversarial review of design docs and implementation plans by Codex via MCP. Same skill, two modes: `design-review` (after brainstorming writes a design doc, before writing-plans is invoked) and `plan-review` (after writing-plans saves an implementation plan, to check drift from the design).

**Announce at start:** "Using codex-plan-review to invoke Codex review."

**Priming for Claude (read this before invoking the loop):** Codex is reviewing this artifact as a peer reviewer. Treat its responses as peer-review feedback — read each critique, evaluate it, and either revise the artifact or push back with reasoning. When Codex signals it has no further substantive concerns, the artifact is finalized.

**State-file writer contract (design §6.1):** every fresh state-file write from this skill emits `filed_issues: []` and `context_limit_tokens: 200000` alongside the v0.1 defaults; every update preserves both fields verbatim.

## Determining mode

If you got here right after `brainstorming` wrote a design doc to `docs/plans/`:
- Mode: `design-review`
- Artifact: the just-written design doc (`docs/plans/<latest>-design.md`)

If you got here right after `writing-plans` wrote a plan doc to `docs/plans/`:
- Mode: `plan-review`
- Artifact: the just-written plan doc

If invoked manually via `/cross-model-review-now <design|plan> [path]`:
- Mode and artifact provided by user; resolve per design doc Section 7.1.

## Universal Codex priming

The text below is the universal priming string. Send it verbatim to Codex on the first MCP call per project (the fresh-thread path in the next section). It establishes Codex's role across all modes this project will use.

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

3. UI/UX surfacing: When you encounter a question that's genuinely a user
   judgment call (visual design, copy, interaction patterns,
   brand-relevant defaults), don't decide it yourself. Surface it: 'this
   is a user decision: <question>'.

If at any point you're missing critical context to give a good response,
say so explicitly and ask Claude to provide what you need.
```

## Bootstrap (do this first, every invocation)

1. Detect storage mode:
   - If working directory has `.git/` AND `.claude/` is writable: PERSISTED mode.
   - If neither (read-only filesystem, projectless context): EPHEMERAL mode.

2. Load state:
   - PERSISTED: read `.claude/cross-model-review.session.local.md` if present.
     If absent, check for frontmatter resume. (Any "write fresh state file" path
     below emits `filed_issues: []` and `context_limit_tokens: 200000` per the
     writer contract above.)
     - Search `docs/plans/` on the current branch for design/plan docs whose
       frontmatter contains `codex_thread_id`.
     - Filter to candidates within last 24h OR matching the branch's
       most-recent commits.
     - If exactly ONE candidate → attempt `mcp__codex__codex-reply` with that
       threadId. On success: write fresh state file with that thread_id and
       artifact path as `active_chain_artifact`. On failure (thread expired):
       fall through to fresh-thread path with recovery handoff per design
       doc Section 5.8.
     - If ZERO candidates → write fresh state file with defaults; first MCP
       call this project will create a new thread.
     - If MULTIPLE candidates → write fresh state file with defaults; post
       chat note: "Multiple design/plan docs in `docs/plans/` could match
       this branch. Not auto-resuming. Use `/cross-model-review-now <kind>
       <path>` to manually resume from a specific artifact."
   - EPHEMERAL: read in-conversation state marker (look for the most recent
     `[cmr-state: ...]` line in transcript, or treat as fresh if absent).
     Do NOT attempt to write a state file.

2.5. **Pre-upgrade chain detection.** After loading state in step 2, classify
   the chain regime:
   - State file was just created fresh in step 2 (or in EPHEMERAL mode,
     marker just initialized) → set `regime = new`. The fresh-state write
     from step 2 already emitted `filed_issues: []` per the writer
     contract (preamble, design §6.1).
   - State file existed AND has the `filed_issues` field (even if []) →
     set `regime = new`.
   - State file existed AND has NO `filed_issues` field → set
     `regime = pre-upgrade`. Do NOT add the field — its absence is the
     durable marker.

   `regime` is consulted later in defer paths (Section 5.8 of design doc)
   and PR-construction paths (Section 5.6 of design doc) to choose
   between issue-filing (regime=new) and decisions-file (regime=pre-upgrade).

3. If `state.skip_next_review == true`: clear flag (write state file in
   PERSISTED mode; update in-context marker in EPHEMERAL mode), post chat
   note ("Codex review skipped per /cross-model-skip"), exit skill.

4. Duplicate-trigger guard: if `state.last_invocation_kind == this_kind`
   AND `(now - state.last_invocation) < 5 seconds` AND not manually
   invoked via `/cross-model-review-now` → exit early (silent dedupe).

5. Compute code-detection heuristic (Section 8 of design doc) on the
   artifact's file list. Record the result (TRIGGER or SKIP) but do NOT
   exit yet.

6. Apply active-chain anti-flip-flop guard. This step reads the value of
   `active_chain_artifact` as loaded in step 2 (the pre-update value;
   the Chain update section below has not run yet):
   - If the loaded `state.active_chain_artifact` is set AND the current
     trigger's artifact is in that chain (per Section 9.2 stem-matching
     rules) → OVERRIDE heuristic to TRIGGER regardless of step 5's
     result.
   - Otherwise, the heuristic result stands.

7. Now act on the (possibly overridden) result:
   - If TRIGGER → continue to MCP call (next section).
   - If SKIP → post chat note explaining why (heuristic outcome AND chain
     status), exit skill.

## Chain update (compute before the MCP call)

Bootstrap has exited with TRIGGER. Now compute the chain transition for
this invocation per design doc Section 9.2. First capture
`prev_active_chain_artifact = state.active_chain_artifact` (may be
null) — this is the value Bootstrap step 6 used.

Branch-mismatch precondition: if `state.active_chain_branch` is non-null
AND differs from the current branch (`git rev-parse --abbrev-ref HEAD`),
clear the chain first (`state.active_chain_artifact = null`,
`state.active_chain_branch = null`) and then re-evaluate the transitions
below as if `prev_active_chain_artifact` were null.

Apply the transition for this invocation's mode:

- **`design-review`:** always set
  `state.active_chain_artifact = <design-doc-path>` and
  `state.active_chain_branch = <current-branch>`. Set
  `chain_just_changed = (prev_active_chain_artifact != <design-doc-path>)`.
- **`plan-review` with `prev_active_chain_artifact == null`:** set
  `state.active_chain_artifact = <plan-doc-path>`,
  `state.active_chain_branch = <current-branch>`, and
  `chain_just_changed = true`.
- **`plan-review` with `prev_active_chain_artifact != null`:** compute
  `stems_match(prev_active_chain_artifact, <plan-doc-path>)` per design
  doc Section 9.2 (strip leading `YYYY-MM-DD-` date prefix, strip
  trailing `-design`/`-plan`/`-impl` suffix, strip `.md` extension;
  equal stems = match).
  - If stems match → preserve `prev_active_chain_artifact`; set
    `chain_just_changed = false`.
  - If stems mismatch → set
    `state.active_chain_artifact = <plan-doc-path>`,
    `state.active_chain_branch = <current-branch>`, and
    `chain_just_changed = true` (this is a new chain).

Persist the updated state (PERSISTED mode: write
`.claude/cross-model-review.session.local.md`; EPHEMERAL mode: update
the in-context `[cmr-state: ...]` marker). The Codex MCP call below
reads `chain_just_changed` to decide whether to prepend the
`[CHAIN-BOUNDARY] ...` marker.

## Codex MCP call

If `state.codex_thread_id` is null:

1. **Late-bound frontmatter resume check.** Before initiating a fresh
   thread, look at the artifact this invocation is about to review:
   - If the artifact is a design or plan doc with `codex_thread_id` in its
     frontmatter → attempt to resume that thread first (try
     `mcp__codex__codex-reply` with that threadId + bare content + mode
     tag). On success: write that threadId into state, proceed as
     continuation.
   - If the artifact is a `branch:<branch>` anchor (anchorless impl-only)
     OR has no frontmatter `codex_thread_id` → skip late-bound resume,
     proceed to fresh-thread path.

   This makes the manual recovery path work: when bootstrap left
   `state.codex_thread_id` null because of ambiguous candidates, and the
   user invokes `/cross-model-review-now <kind> <explicit-path>`, the MCP
   layer reads that explicit artifact's frontmatter and resumes from it.
   Same logic applies any time a review fires for an artifact whose
   frontmatter has a thread_id but state doesn't.

2. **Fresh-thread path (no frontmatter resume available, or resume failed):**
   - Invoke `mcp__codex__codex` with:
     - `cwd`: project root (via `git rev-parse --show-toplevel`)
     - `sandbox`: "read-only"
     - `prompt`: the full universal priming text from the **Universal Codex priming** section above + "\n\n[MODE: <this-mode>]\n\n<artifact content>"
   - If the late-bound resume in step 1 failed (thread expired), prepend
     a recovery handoff to the priming:
     "[RESUMING — previous Codex thread (id: <old-id>) could not be
     resumed. Reconstructing context: active chain: <stem>, branch:
     <branch>, last invocation kind: <kind>, approvals so far: <derived
     from artifact frontmatter>, pending decisions: <count>. Previous
     thread's discussion is unavailable. Treat current artifact content
     as primary context.]"
   - Capture `threadId` from response; write to `state.codex_thread_id`.
   - Write `codex_thread_id` to the artifact's frontmatter (design or plan
     doc — both, per the cross-machine-resume contract; impl has no
     artifact).

Else (state.codex_thread_id is set; continuation call):

- If chain just changed (active_chain_artifact updated this invocation),
  prepend "[CHAIN-BOUNDARY] starting new task: <stem>; previous task: <old-stem>\n\n" to content.
- Invoke `mcp__codex__codex-reply` with:
  - `threadId`: `state.codex_thread_id`
  - `prompt`: "[MODE: <this-mode>]\n\n<artifact content>"
- If reply errors with thread-not-found / expired:
  - Reset `state.codex_thread_id = null`
  - Re-enter this section's first branch (now-null state.codex_thread_id
    will trigger late-bound frontmatter check, then fresh-thread path).
  - The recovery handoff text above will be included in the priming.

For this skill, `<this-mode>` is `design-review` or `plan-review` per the determination above. The artifact content is the full text of the design or plan doc.

## Response handling loop

### Tag-line parser

Each finding from Codex begins with a tag line of the form:

  `[severity:critical|important|minor, scope:small|medium|large|n-a, cluster:<short-kebab-name>]`

Regex-extract the three values from each finding's first line. Defaults
when the tag line is missing or malformed:
- `severity` → `minor`
- `scope` → `n-a` (this skill's gates have no code diff)
- `cluster` → `solo-<sha8(finding-text)>` (no batching for that finding)

These defaults make malformed tags safe rather than blocking. See design
§4.1.

### Routing (design §4)

After receiving Codex response, first check session-level convergence;
otherwise route each finding through the common entry check then the
mode-specific path.

1. **Convergence signal** ("looks good", "approved", "no further concerns",
   similar plain-language signal at the response level — not per-finding):
   - APPROVAL. Write `codex_<kind>_status: approved` and
     `codex_<kind>_approved_hash: <sha256>` to the artifact's frontmatter.
   - Post summary chat note ("Codex approved <kind> after N rounds.").
   - Exit loop.

Otherwise, for each finding (or cluster):

2. **Common entry check — user-input flagged** (Codex tagged "this is a
   user decision: ..." OR Claude classifies as UI/UX). **This check
   outranks severity** — even a CRITICAL UI judgment call routes here, not
   into substantive critique:
   - INTERACTIVE: post question in chat with optional PushNotification
     fire; end Claude turn (turn-taking handles pause).
   - AUTONOMOUS + regime = new: batch-defer to `design-input-needed`
     issue. (Phase 6 documents the issue-filing helper; for now this
     branch just records the routing choice.)
   - AUTONOMOUS + regime = pre-upgrade: append to per-chain decisions
     file (`.claude/cross-model-review/decisions/<basename>.md`) with
     stable handle (`decision-<YYYY-MM-DD>-<HHMM>-<4char-hash>`); pick
     most defensible default; continue loop with default applied.
     (Existing v0.1 behavior — unchanged.)

3. **Substantive critique** (anything else Codex flagged — code-only
   design flaws, plan deviations, missing edge cases, ambiguous specs):
   - At `design-review` and `plan-review`, "substantive critique" means
     **revise the artifact** (edit the design doc or plan doc directly)
     and loop back to "Codex MCP call" with revised content. `scope` is
     `n-a` here.

Note: at design-review and plan-review gates, `autonomous-safe` issues
are NOT produced. There is no code diff yet, so context-budget pressure
does not exist. The only deferral mechanism at these gates is the
user-input path above.

After every loop iteration: update `state.last_invocation = now()`,
`state.last_invocation_kind = <this-kind>`.

For this skill specifically:

- **On APPROVAL:**
  - Write the appropriate approval-status and approval-hash to the artifact's frontmatter:
    - `design-review`: `codex_design_review_status: approved` + `codex_design_review_approved_hash: <sha256>`.
    - `plan-review`: `codex_plan_review_status: approved` + `codex_plan_review_approved_hash: <sha256>`.
  - Compute hash per Section 9.7 of design doc (SHA-256 of body content with frontmatter stripped entirely).
  - **Persist `codex_thread_id` to the artifact's frontmatter on EVERY approval** — applies to BOTH design docs AND plan docs. This is the load-bearing field for cross-machine frontmatter resume; both artifact types must carry it so a fresh install can resume from either. If the artifact already has `codex_thread_id` set (from a previous invocation), confirm it matches the current `state.codex_thread_id` and overwrite if different.
- **On REVISE:** edit the artifact, then loop. For design-review revisions, edit the design doc directly. For plan-review revisions, edit the plan doc — flag any change that contradicts the previously-approved design as drift, and surface to user (interactive). In autonomous mode the drift note routes by regime: regime = pre-upgrade logs to the decisions file (existing v0.1 behavior — unchanged); regime = new defers to a `design-input-needed` issue (Phase 6 documents the helper; this branch just records the routing choice).

## Issue filing (autonomous mode, new-regime chains)

When a defer-path routes to issue-filing (autonomous mode + `regime = new`),
follow these steps. The text below is identical between `codex-plan-review`
and `codex-impl-review` per the "no shared `prompts/` directory" architecture
(MANIFEST.md); changes must be applied to both copies.

1. **Group by cluster.** Findings sharing a `cluster` tag (extracted by
   the tag-line parser earlier in this skill) batch into one issue per
   cluster. If a cluster mixes `autonomous-safe` and `design-input-needed`
   defers, split into two issues — one per kind. If Codex omitted the
   cluster tag, the parser's `solo-<sha8(...)>` default means each finding
   becomes its own cluster (no batching).

2. **Compose the title.** Format: `[<chain-stem>] <imperative description>`.
   The stem comes from the existing stem-matching algorithm specified in
   the original design doc `2026-04-29-cross-model-review-design.md` §9.2:
   strip leading `YYYY-MM-DD-` date prefix, strip trailing
   `-design`/`-plan`/`-impl` suffix, strip `.md` extension. For anchorless
   impl-only chains (`state.active_chain_artifact = "branch:<branch-name>"`),
   the stem is `branch:<branch-name>` verbatim.

3. **Compose the body** (markdown, no frontmatter) per design §5.3.

   **For `autonomous-safe`:**

   ```markdown
   ## Context
   - **Chain:** `<active_chain_artifact path or branch:ref>`
   - **Branch:** `<current branch>`
   - **Filed during:** <gate-name> (commit <short-sha>)

   ## Findings (cluster: <cluster-name>)
   - **<SEVERITY> / <SCOPE> scope** — <finding 1 description>
   - (repeat per finding in the cluster)

   ## Suggested approach
   <Codex's recommended fix as one paragraph or bullet list>

   ## Acceptance criteria
   - [ ] <criterion 1, derived from Codex's Suggested approach>
   - (repeat per criterion)

   ---
   🤖 Filed by cross-model-review during <gate-name> on <YYYY-MM-DD>.
   ```

   `<gate-name>` is one of `design-review`, `plan-review`, or
   `impl-review` — match the skill name exactly (lowercase kebab-case).

   **For `design-input-needed`,** replace `Suggested approach` and
   `Acceptance criteria` with:

   ```markdown
   ## Decision needed
   <the question Codex flagged>

   ## Default applied (autonomous run)
   <what Claude+Codex picked, with reasoning>

   ## How to resolve
   - Comment with your preferred answer to override
   - Close as completed if the default is acceptable
   - Close as superseded if circumstances changed before resolution
   ```

   The Context block, the closing footer line, and the bot-footer divider
   are constant across both kinds.

4. **Run the defer-path preconditions** before invoking `gh`. See the
   **Defer-path preconditions** sub-section below for the three concrete
   bash invocations (ownership, `gh auth status`, `gh issue list --limit
   1`) and the failure-routing table per gate / mode (design §5.8). All
   three checks must pass before reaching step 5.

5. **File via `gh issue create`, capturing the issue number.** `gh issue
   create` writes the new issue's URL to stdout (e.g.,
   `https://github.com/owner/repo/issues/123`). The snippet below
   composes the body into a temp file (avoids a heredoc-EOF collision if
   Codex's findings or recommendations contain a literal `EOF` line —
   e.g., when reviewing shell scripts that themselves use heredocs),
   files via `--body-file`, then validates the extracted issue number
   with a regex before appending to `state.filed_issues`. The
   `<chain-stem>`, `<description>`, body content, and label value are
   placeholders the skill substitutes per the steps above.

```bash
# Compose the body content into a temp file (avoids heredoc-EOF
# collision if the body contains a literal "EOF" line). The inner
# heredoc uses a unique sentinel that won't collide with English prose.
body_file=$(mktemp -t cmr-issue-body.XXXXXX)
cat > "$body_file" <<'MARKER_BODY_EOF'
<body content goes here — verbatim from the templates above>
MARKER_BODY_EOF

issue_url=$(gh issue create \
  --title "[<chain-stem>] <description>" \
  --body-file "$body_file" \
  --label "<autonomous-safe|design-input-needed>")

issue_number="${issue_url##*/}"
[[ "$issue_number" =~ ^[0-9]+$ ]] || {
  echo "ERROR: could not extract issue number from gh output: $issue_url" >&2
  rm -f "$body_file"
  exit 1
}
rm -f "$body_file"
```

   The `${var##*/}` parameter expansion strips everything up to and
   including the last `/`, leaving just the issue number. The
   `[[ ... =~ ^[0-9]+$ ]]` regex test then asserts the result is purely
   digits — guards against trailing-slash URLs, malformed gh output,
   etc. On extraction failure, treat as a `gh-issue-list`-precondition
   failure with the extraction failure as the chat-note detail (route
   per the failure-handling table in **Defer-path preconditions** below).

   On success, append
   `{number: $issue_number, cluster: "<cluster-name>", kind: "<label>"}`
   to `state.filed_issues` and persist state (PERSISTED mode: write
   `.claude/cross-model-review.session.local.md`; EPHEMERAL mode: update
   the in-context `[cmr-state: ...]` marker).

   If `gh issue create` itself fails (non-zero exit, OR exit zero but
   stdout is empty / does not contain a recognizable issues URL), surface
   as a halt per the **Defer-path preconditions** failure table — the
   issue was supposed to be filed but isn't, so the chain cannot be
   considered safely deferred.

6. **Bidirectional cross-link** (impl-review's PR-creation closer — NOT
   done at filing time). When the PR is opened by `codex-impl-review`,
   the skill runs `gh issue comment <number>` on each entry in
   `state.filed_issues`: *"Originally filed during PR #N: <url>"*.
   *(Phase 10 of the autonomous-issue-filing plan documents the PR-time
   mechanics and the failure-tolerance rules. This skill at design-review
   and plan-review gates does not perform the cross-link itself; it only
   appends to `state.filed_issues` so the impl-review closer has the data
   to work with.)*

### Defer-path preconditions

Before any `gh issue create`, run these three checks IN ORDER. All three
must pass; first failure routes to halt-or-chat per the failure table below.

1. **Ownership.**
   ```bash
   git remote get-url origin | grep -E "TimSimpsonJr/|TimSimpsonJr:" || exit 1
   ```
   Non-zero → ownership precondition failed.

2. **gh auth.**
   ```bash
   gh auth status >/dev/null 2>&1
   ```
   Non-zero → auth precondition failed.

3. **gh issue list.**
   ```bash
   gh issue list --limit 1 >/dev/null 2>&1
   ```
   Non-zero → repo-issues precondition failed (issues disabled, no
   GitHub remote, etc.).

On any precondition failure:

- **AUTONOMOUS + design-review or plan-review gate** → set
  `state.chain_status = halted`; post chat note naming which precondition
  failed (`ownership`, `gh-auth`, or `gh-issue-list`).
- **AUTONOMOUS + impl-review mid-loop** → halt; write halt note to
  `.claude/cross-model-review/halts/<chain-stem>.md` (new file, separate
  from the retired decisions file).
- **AUTONOMOUS + impl-review PR-creation closer** → existing draft-PR
  halt path (Section 9.6 of the original design doc
  `2026-04-29-cross-model-review-design.md`); include unfiled defer
  payloads in the fallback section of the PR description.
- **INTERACTIVE** → post chat note describing failure; user resolves
  and re-invokes. For ownership specifically, include this policy
  explanation: *"This repo is not owned by you, so the
  cross-model-review labeling convention doesn't apply. The plugin
  will not file issues here."*

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
