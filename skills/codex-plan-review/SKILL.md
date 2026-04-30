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

5. Compute code-detection heuristic (Section 6 of design doc) on the
   artifact's file list. Record the result (TRIGGER or SKIP) but do NOT
   exit yet.

6. Apply active-chain anti-flip-flop guard:
   - If `state.active_chain_artifact` is set AND the current trigger's
     artifact is in that chain (per Section 9.2 stem-matching rules) →
     OVERRIDE heuristic to TRIGGER regardless of step 5's result.
   - Otherwise, the heuristic result stands.

7. Now act on the (possibly overridden) result:
   - If TRIGGER → continue to MCP call (next section).
   - If SKIP → post chat note explaining why (heuristic outcome AND chain
     status), exit skill.

After bootstrap, if active_chain_artifact updates this invocation (new chain), set the `chain_just_changed` flag for the MCP call below.

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

After receiving Codex response, three branches:

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

For this skill specifically:

- **On APPROVAL:**
  - Write the appropriate approval-status and approval-hash to the artifact's frontmatter:
    - `design-review`: `codex_design_review_status: approved` + `codex_design_review_approved_hash: <sha256>`.
    - `plan-review`: `codex_plan_review_status: approved` + `codex_plan_review_approved_hash: <sha256>`.
  - Compute hash per Section 9.7 of design doc (SHA-256 of body content with frontmatter stripped entirely).
  - **Persist `codex_thread_id` to the artifact's frontmatter on EVERY approval** — applies to BOTH design docs AND plan docs. This is the load-bearing field for cross-machine frontmatter resume; both artifact types must carry it so a fresh install can resume from either. If the artifact already has `codex_thread_id` set (from a previous invocation), confirm it matches the current `state.codex_thread_id` and overwrite if different.
- **On REVISE:** edit the artifact, then loop. For design-review revisions, edit the design doc directly. For plan-review revisions, edit the plan doc — flag any change that contradicts the previously-approved design as drift, and surface to user (interactive) or log to decisions file (autonomous).

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
