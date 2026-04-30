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

## Universal Codex priming

The text below is the universal priming string. Send it verbatim to Codex on the first MCP call per project (the fresh-thread path in the **Codex MCP call** section). It establishes Codex's role across all modes this project will use.

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

## Bootstrap (do this first, every invocation)

1. Detect storage mode:
   - If working directory has `.git/` AND `.claude/` is writable: PERSISTED mode.
   - If neither (read-only filesystem, projectless context): EPHEMERAL mode.

2. Load state:
   - PERSISTED: read `.claude/cross-model-review.session.local.md` if present.
     If absent, check for frontmatter resume:
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

3. If `state.skip_next_review == true`: clear flag (write state file in
   PERSISTED mode; update in-context marker in EPHEMERAL mode), post chat
   note ("Codex review skipped per /cross-model-skip"), exit skill.

4. Duplicate-trigger guard: if `state.last_invocation_kind == this_kind`
   AND `(now - state.last_invocation) < 5 seconds` AND not manually
   invoked via `/cross-model-review-now` → exit early (silent dedupe).

5. Compute code-detection heuristic (Section 8 of design doc) on the
   artifact's file list (output of `git diff --name-only <branch-base>..HEAD`).
   Record the result (TRIGGER or SKIP) but do NOT exit yet.

6. Apply active-chain anti-flip-flop guard:
   - This step reads the value of `state.active_chain_artifact` as loaded
     in step 2 (the pre-update value; the Chain update section below has
     not run yet).
   - If `state.active_chain_artifact` is set AND the current trigger's
     artifact is in that chain (per Section 9.2 stem-matching rules) →
     OVERRIDE heuristic to TRIGGER regardless of step 5's result.
   - Otherwise, the heuristic result stands.

7. Now act on the (possibly overridden) result:
   - If TRIGGER → continue to the Chain update section, then the Codex MCP call.
   - If SKIP → post chat note explaining why (heuristic outcome AND chain
     status), exit skill.

## Chain update (compute before the MCP call)

Bootstrap has exited with TRIGGER. Now apply the impl-review chain rules
per design doc Section 9.2. First capture
`prev_active_chain_artifact = state.active_chain_artifact` (may be null) —
this is the value Bootstrap step 6 used.

Branch-mismatch precondition: if `state.active_chain_branch` is non-null
AND differs from the current branch (`git rev-parse --abbrev-ref HEAD`),
clear the chain first (`state.active_chain_artifact = null`,
`state.active_chain_branch = null`) and treat
`prev_active_chain_artifact` as null for the steps below.

Anchorless-impl initialization: if `state.active_chain_artifact` is null
after the branch-mismatch handling above (no prior chain on this feature
branch), set:

- `state.active_chain_artifact = "branch:<current-branch-name>"`
  (per design doc Section 5.4 anchorless impl-review — this makes the
  decisions file naming work, e.g.
  `branch--<current-branch-name>--impl-only.md`).
- `state.active_chain_branch = <current-branch-name>`.

Otherwise (chain was already set and matches the current branch), preserve
`state.active_chain_artifact` and `state.active_chain_branch` as-is —
**impl-review never changes the active chain** per design doc Section 9.2.

Set `chain_just_changed = (this section set or cleared the chain)`. In
practice: `chain_just_changed = true` only when the branch-mismatch
clearing fired and was followed by anchorless-impl initialization (i.e.,
`state.active_chain_artifact` differs from `prev_active_chain_artifact`),
OR when anchorless-impl initialization fired against a previously-null
chain. Otherwise `chain_just_changed = false`.

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
     - `prompt`: the full universal priming text from the **Universal Codex priming** section above + "\n\n[MODE: impl-review]\n\n<artifact content>"
   - If the late-bound resume in step 1 failed (thread expired), prepend
     a recovery handoff to the priming:
     "[RESUMING — previous Codex thread (id: <old-id>) could not be
     resumed. Reconstructing context: active chain: <stem>, branch:
     <branch>, last invocation kind: <kind>, approvals so far: <derived
     from artifact frontmatter>, pending decisions: <count>. Previous
     thread's discussion is unavailable. Treat current artifact content
     as primary context.]"
   - Capture `threadId` from response; write to `state.codex_thread_id`.
   - For impl-review specifically, there is no design/plan artifact in
     this invocation — the threadId is captured to `state.codex_thread_id`
     only. If a chain has a plan doc, future plan-review-now or
     design-review-now invocations on that doc will pick up the threadId
     from state and persist it to the doc's frontmatter at that point.

Else (state.codex_thread_id is set; continuation call):

- If chain just changed (active_chain_artifact updated this invocation),
  prepend "[CHAIN-BOUNDARY] starting new task: <stem>; previous task: <old-stem>\n\n" to content.
- Invoke `mcp__codex__codex-reply` with:
  - `threadId`: `state.codex_thread_id`
  - `prompt`: "[MODE: impl-review]\n\n<artifact content>"
- If reply errors with thread-not-found / expired:
  - Reset `state.codex_thread_id = null`
  - Re-enter this section's first branch (now-null state.codex_thread_id
    will trigger late-bound frontmatter check, then fresh-thread path).
  - The recovery handoff text above will be included in the priming.

For this skill, `<this-mode>` is `impl-review`. Content includes:
- The plan content (full text of plan doc, if chain has one).
- The diff (full `git diff <branch-base>..HEAD` output).
- Brief framing line: "Review this implementation against the approved plan. Categorize findings as CRITICAL / IMPORTANT / MINOR per universal priming."

## Response handling loop

After receiving Codex response, three branches:

1. **Convergence signal** ("looks good", "approved", "no further concerns",
   similar plain-language signal):
   - For design-review / plan-review / impl-review: APPROVAL. Write
     `codex_<kind>_status: approved` and `codex_<kind>_approved_hash:
     <sha256>` to the artifact's frontmatter. For impl-review, write
     `state.impl_review_approved_sha = <git HEAD sha>`.
   - **Note for impl-review:** do NOT write `codex_impl_review_status` to
     any artifact's frontmatter — that field does not exist in the schema.
     The impl-review approval lives only in
     `state.impl_review_approved_sha = <git HEAD sha>`. Per design doc §9.7,
     only design-doc and plan-doc frontmatter carry approval status.
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
`state.last_invocation_kind = "impl-review"`.

For this skill specifically:

- **Findings handled outcome-based, not finding-based.** Group related findings (same module, same edge case, same design gap). For each group, dispatch ONE fix subagent with all related findings together. A subagent can address one finding or several in one pass.
- **Severity routing:**
  - CRITICAL: dispatch fix subagent immediately, loop.
  - IMPORTANT: dispatch fix subagent immediately, loop.
  - MINOR: log in PR description as "noted, deferred." Don't necessarily fix.
- **Approval condition:** Codex approves OR all CRITICAL/IMPORTANT are fixed.

## Termination handoff

After approval:

- Set `state.impl_review_approved_sha = <git HEAD sha>`. (Approval is recorded; chain status NOT yet completed — PR opening is the closer.)
- Leave `state.chain_status = "in_progress"` for now. Do NOT prematurely set it to `completed`.

**Interactive mode:**
- Post: "Codex approved the implementation. Ready to open PR? [Y/n]"
- If user says yes → user opens PR via `gh pr create` themselves; Claude does not auto-set `chain_status` (manual chain closure is fine — `/cross-model-status` will still show approvals correctly).

**Autonomous mode** — PR creation is the chain closer:

1. Run `gh pr create` with description per template.
2. Description includes: summary, all three approvals' status, decisions-pending file contents, any error notes, test plan from the original plan, "Generated with cross-model-review" footer.
3. **Branch on result:**
   - **PR creation succeeded** (gh exits 0, PR URL returned):
     - Set `state.chain_status = "completed"`.
     - Post chat note with PR URL.
     - Fire local PushNotification if available.
   - **PR creation failed** (non-zero exit, network error, gh not authenticated, etc.):
     - Capture the error.
     - Treat as halt scenario: write halt note to per-chain decisions file with PR creation failure detail; transition `state.chain_status = "halted"`.
     - Post chat note: *"Implementation approved by Codex but PR creation failed: <error>. State left as `halted`. Resolve the gh / network issue and run `gh pr create` manually, or invoke `/cross-model-review-now impl` to retry the autonomous closer."*
     - Fire notification (autonomous halts notify per Section 9.6 of design doc).

4. **Halt-path PRs are draft.** Whenever this skill opens a PR after a halt scenario (PR-creation failure that warrants retry-with-context, dirty-state halt with useful work to surface, or any other halt path that produces a PR), use `gh pr create --draft` and include an explicit `## ⚠️ AUTONOMOUS RUN HALTED` header at the top of the PR description with a one-paragraph explanation of why the run halted (gh-auth failure, dirty state, Codex unavailable, etc.). This visually distinguishes incomplete work from successful runs (per design doc Section 9.4).

The contract: `chain_status: completed` means a PR exists for this work. If no PR exists (gh failed, user hasn't run it yet, etc.), the chain is NOT completed — even though approvals may be in place.

## Halt conditions specific to impl-review

- Branch in dirty state at start: ask in interactive; HALT in autonomous (open `--draft` PR per the **Halt-path PRs are draft** rule above if useful work was done; describe in halt note in decisions file).
- subagent-driven-development task fails after retries: surface in chat (interactive); HALT in autonomous.
- Branch-base undeterminable: skip with warning (interactive); HALT in autonomous.
- Codex unavailable: HALT in autonomous mode (Section 9.6 of design doc — review is a critical gate).

## State updates

After every loop iteration AND on termination:
- `state.last_invocation = now()`
- `state.last_invocation_kind = "impl-review"`
- `state.chain_status` updated per termination flow (see above).
