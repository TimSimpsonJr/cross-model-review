---
name: codex-brainstorm-partner
description: Use during brainstorming when the user has explicitly opted in to having Codex stand in for the user role, OR when autonomous mode is active during a brainstorming session. Triggers on phrases like "let codex take over", "let's brainstorm with codex", "let codex weigh in".
---

# codex-brainstorm-partner

Codex stands in for the user during a brainstorming flow. Routes Claude's brainstorming questions to Codex via MCP and feeds Codex's responses back to Claude as conversational input.

**Announce at start:** "Using codex-brainstorm-partner — Codex will stand in for the user this turn."

**No priming for Claude.** Claude doesn't get any peer-review framing. The brainstorming flow proceeds normally; this skill operates between Claude asking a question and Claude reading "the user's response."

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

## Bootstrap (DIFFERENT from review skills — no skip / no duplicate guard)

Brainstorm-partner is opt-in and turn-based, so its bootstrap is much lighter than the review skills:

1. Read `.claude/cross-model-review.session.local.md` (or use ephemeral fallback — look for the most recent `[cmr-state: ...]` line in transcript, or treat as fresh if absent).
   - If absent and at least one design/plan doc with `codex_thread_id` exists in `docs/plans/` on the current branch, apply the frontmatter-resume disambiguation rule:
     - Search `docs/plans/` on the current branch for design/plan docs whose frontmatter contains `codex_thread_id`.
     - Filter to candidates within last 24h OR matching the branch's most-recent commits.
     - If exactly ONE candidate → attempt `mcp__codex__codex-reply` with that threadId. On success: write fresh state file with that thread_id and artifact path as `active_chain_artifact`. On failure (thread expired): fall through to fresh-thread path with recovery handoff per design doc Section 5.8.
     - If ZERO candidates → write fresh state file with defaults; first MCP call this project will create a new thread.
     - If MULTIPLE candidates → write fresh state file with defaults; post chat note: "Multiple design/plan docs in `docs/plans/` could match this branch. Not auto-resuming. Use `/cross-model-review-now <kind> <path>` to manually resume from a specific artifact."
2. **Do NOT check `skip_next_review`.** Skip is review-only.
3. **Do NOT apply duplicate-trigger guard.** Each brainstorm turn is independent.

(No `state.paused` check — that field is not part of the v0.1 schema; brainstorm-partner is gated only by user opt-in.)

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
     - `prompt`: the full universal priming text from the **Universal Codex priming** section above + "\n\n[MODE: brainstorm-partner]\n\n<artifact content>"
   - If the late-bound resume in step 1 failed (thread expired), prepend
     a recovery handoff to the priming:
     "[RESUMING — previous Codex thread (id: <old-id>) could not be
     resumed. Reconstructing context: active chain: <stem>, branch:
     <branch>, last invocation kind: <kind>, approvals so far: <derived
     from artifact frontmatter>, pending decisions: <count>. Previous
     thread's discussion is unavailable. Treat current artifact content
     as primary context.]"
   - Capture `threadId` from response; write to `state.codex_thread_id`.
   - For brainstorm-partner there typically is no doc artifact yet — the
     brainstorm hasn't produced a design doc. The threadId is captured to
     `state.codex_thread_id` only. When brainstorming later writes the
     design doc and codex-plan-review fires, that skill will write the
     same `state.codex_thread_id` to the new design doc's frontmatter.

Else (state.codex_thread_id is set; continuation call):

- `chain_just_changed` is essentially always `false` for brainstorm-partner
  (this skill does not modify the active chain). Only prepend the
  `[CHAIN-BOUNDARY]` marker if `state.active_chain_artifact` was just
  modified by another skill earlier in the same Claude turn (uncommon).
- Invoke `mcp__codex__codex-reply` with:
  - `threadId`: `state.codex_thread_id`
  - `prompt`: "[MODE: brainstorm-partner]\n\n<artifact content>"
- If reply errors with thread-not-found / expired:
  - Reset `state.codex_thread_id = null`
  - Re-enter this section's first branch (now-null `state.codex_thread_id`
    will trigger late-bound frontmatter check, then fresh-thread path).
  - The recovery handoff text above will be included in the priming.

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
