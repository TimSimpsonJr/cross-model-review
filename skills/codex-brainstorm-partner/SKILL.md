---
name: codex-brainstorm-partner
description: Use during brainstorming when the user has explicitly opted in to having Codex stand in for the user role, OR when autonomous mode is active during a brainstorming session. Triggers on phrases like "let codex take over", "let's brainstorm with codex", "let codex weigh in".
---

# codex-brainstorm-partner

Codex stands in for the user during a brainstorming flow. Routes Claude's brainstorming questions to Codex via async CLI (`codex exec` with Bash `run_in_background: true`) and feeds Codex's responses back to Claude as conversational input on the next turn.

**Announce at start:** "Using codex-brainstorm-partner — Codex will stand in for the user. Launching async; will resume brainstorming when Codex responds."

**No priming for Claude.** Claude doesn't get any peer-review framing. The brainstorming flow proceeds normally; this skill operates between Claude asking a question and Claude reading "the user's response."

**Integration caveat — depends on parent skill turn-boundary pauses.** This skill's async pattern works because `superpowers:brainstorming` pauses at turn boundaries to wait for "user input" between questions. brainstorm-partner launches a Codex bg job, ends the turn, and on the next turn (after bg completion notification) feeds Codex's response to brainstorming as if the user typed it. **If a future version of `superpowers:brainstorming` changes those semantics** (e.g., expects synchronous in-turn responses), brainstorm-partner will produce incorrect behavior and need revisiting. The no-op fallback in step 5 of Bootstrap is a defensive guard against the most obvious failure mode (double-launch) but does not catch all possible upstream regressions.

**State-file writer contract (design §6.1):** every fresh state-file write from this skill emits `filed_issues: []` and `context_limit_tokens: 200000` alongside the v0.1 defaults; every update preserves both fields verbatim.

## Universal Codex priming

The text below is the universal priming string. Send it verbatim to Codex on the first CLI call per project (the fresh-thread path in the **Codex async CLI call** section), written into the prompt file. It establishes Codex's role across all modes this project will use.

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

## Bootstrap (DIFFERENT from review skills — no skip / no duplicate-trigger guard, but has halt-on-ephemeral + no-op fallback)

Brainstorm-partner is opt-in and turn-based:

1. **Detect storage mode and halt on ephemeral.** Check whether the working directory has `.git/` AND `.claude/` is writable.
   - If yes: continue.
   - Otherwise: **HALT.** Post chat note: *"This project's `.claude/` directory is not writable. v0.3.0 requires persisted state for async Codex stand-in. Brainstorming continues with Claude only for this question."* Exit skill. The parent brainstorming flow continues without Codex's stand-in input.

2. **Read `.claude/cross-model-review.session.local.md`.** Any "write fresh state file" path below emits `filed_issues: []` and `context_limit_tokens: 200000` per the writer contract above.
   - If the state file is absent, apply the frontmatter-resume disambiguation rule:
     - Search `docs/plans/` on the current branch for design/plan docs whose frontmatter contains `codex_thread_id`.
     - Filter to candidates within last 24h OR matching the branch's most-recent commits.
     - If exactly ONE candidate → set `state.codex_thread_id` to its frontmatter thread_id; the next CLI call will be a `codex exec resume` continuation (stale-thread detection in the bg-completion handler covers expired-thread cases).
     - If ZERO candidates → write fresh state file with defaults; the first `codex exec` call this project makes will create a new thread.
     - If MULTIPLE candidates → write fresh state file with defaults; post chat note: "Multiple design/plan docs in `docs/plans/` could match this branch. Not auto-resuming. Use `/cross-model-review-now <kind> <path>` to manually resume from a specific artifact."

3. **Pre-upgrade chain detection.** After loading state in step 2, classify the chain regime:
   - State file was just created fresh in step 2 → set `regime = new`. The fresh-state write already emitted `filed_issues: []` per the writer contract.
   - State file existed AND has the `filed_issues` field (even if []) → set `regime = new`.
   - State file existed AND has NO `filed_issues` field → set `regime = pre-upgrade`. Do NOT add the field — its absence is the durable marker.

   For brainstorm-partner specifically, `regime` only feeds the writer contract (fresh writes emit `filed_issues: []`); the response-handling defer path stays on v0.1 behavior regardless of regime.

4. **Do NOT check `skip_next_review`** (skip is review-only). **Do NOT apply duplicate-trigger guard** (each brainstorm turn is independent).

5. **No-op fallback (defensive guard).** Look up `state.codex_reviews_in_progress` for any entry with `kind: brainstorm-partner` AND `branch: <current branch>` AND `status: in_progress`. If one exists, the previous async stand-in launch has not yet completed — do NOT double-launch. Post chat note: *"Previous Codex stand-in launch for this brainstorm is still running (bg_id `<bash_id>`, started `<ts>`). Brainstorming continues with Claude only for this question, or wait for the previous response."* Exit skill. This guards against the most obvious failure mode where the parent brainstorming flow has not paused for the prior stand-in's response. It does NOT detect all possible upstream-skill regressions — see the integration caveat at the top of this skill.

(No `state.paused` check — that field is not part of the v0.1 schema; brainstorm-partner is gated by user opt-in plus the no-op fallback above.)

## Codex async CLI call

The skill launches Codex via Bash with `run_in_background: true`, ending the current turn while Codex thinks. On completion notification, the next turn (handled in **On bg completion** below) reads the result and feeds it to brainstorming as if it were the user's response.

### Step 1: Pre-generate identifiers and file paths

Generate a `launch_uuid` (UUID v4). Compute file paths:

```text
prompt_file = /tmp/cmr-<launch_uuid>-prompt.txt
result_file = /tmp/cmr-<launch_uuid>-result.txt
jsonl_file  = /tmp/cmr-<launch_uuid>-events.jsonl
stderr_file = /tmp/cmr-<launch_uuid>-stderr.txt
```

### Step 2: Compose the prompt and write it to `prompt_file`

**If `state.codex_thread_id` is null** (fresh thread): write the full universal priming text + `[MODE: brainstorm-partner]` tag + Claude's question. Set `attempted_thread_id = null`.

**Fresh-thread content:**

```text
<full universal priming text>

[MODE: brainstorm-partner]

<the question Claude just asked>
```

**Continuation content** (`state.codex_thread_id` set): just the mode tag + question (priming was set on the first call). Set `attempted_thread_id = state.codex_thread_id`.

```text
[MODE: brainstorm-partner]

<the question Claude just asked>
```

**`chain_just_changed`** is essentially always `false` for brainstorm-partner (this skill does not modify the active chain). Only prepend a `[CHAIN-BOUNDARY]` marker if `state.active_chain_artifact` was just modified by another skill earlier in the same Claude turn (uncommon).

If user has provided any "Tim note:" annotations in the session, append before the question:

```
Tim's recent annotations to consider:
<list of recent Tim notes from chat history>
```

### Step 3: Pre-write the state slot (BEFORE bg launch)

Append a new entry to `state.codex_reviews_in_progress`:

```yaml
- launch_uuid: <uuid>
  bg_id: "pending"
  status: in_progress
  kind: brainstorm-partner
  branch: <git rev-parse --abbrev-ref HEAD>
  chain_artifact: <state.active_chain_artifact or "brainstorm:<branch>">
  attempted_thread_id: <thread_id or null>
  result_file: /tmp/cmr-<uuid>-result.txt
  jsonl_file:  /tmp/cmr-<uuid>-events.jsonl
  stderr_file: /tmp/cmr-<uuid>-stderr.txt
  started_at:  <ISO timestamp>
```

Persist by writing the state file. **If the state write fails, abort the launch immediately** — post chat note describing the failure, do NOT invoke Bash.

### Step 4: Launch via Bash with `run_in_background: true`

**Fresh thread** (attempted_thread_id null):
```bash
codex exec --sandbox read-only -C <project-toplevel> --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

**Continuation** (attempted_thread_id set):
```bash
codex exec resume <attempted_thread_id> --sandbox read-only -C <project-toplevel> --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

Use the Bash tool with `run_in_background: true`. Capture the returned `bash_id`.

### Step 5: Update the slot with the captured `bg_id`

Update the slot's `bg_id` from `"pending"` to the actual `bash_id`. Persist state.

### Step 6: Post chat note and end the turn

Post: *"Codex stand-in thinking about the brainstorming question (typical 1–5 min at `xhigh` reasoning for a single question). Will surface response when complete."*

End the turn. The parent brainstorming flow stays paused at its turn boundary waiting for "the user's response" (which will arrive via Codex on a subsequent turn).

## On bg completion (next-turn handling)

When a Bash bg job's completion notification arrives in a future turn:

1. **Look up the slot** in `state.codex_reviews_in_progress` by the notification's `bash_id`. If found, proceed to step 4.
2. **Fallback for the launch race**: if no direct match, scan slots where `bg_id == "pending"` AND `result_file` exists on disk. If exactly one matches, use it.
3. If still no match: this notification is for an unrelated bg job. Ignore.
4. **Branch on `status`:**
   - `status == "detached"` (user ran `/cross-model-reset` mid-stand-in): inspect result file; post a chat note per the four cases (non-empty / missing-or-empty / stale-thread / corrupt) per the pattern in `codex-plan-review`. Remove the slot. Brainstorming continues without this stand-in input (parent skill resumes when user provides actual input).
   - `status == "in_progress"`: proceed to step 5.
5. **Check for stale-thread error (best-effort).** Scan `result_file`, `jsonl_file`, `stderr_file` for `"Session not found for thread_id"` / `"thread not found"`. If detected, post chat note *"Codex thread `<attempted_thread_id>` has expired. Brainstorming continues with Claude only for this question."* Set slot's `status: "stale_thread_error"`. Remove the slot. Do NOT auto-recover.
6. **Read `result_file`** — Codex's reply, formatted as if it were the user's response.
7. **Extract `thread_id`** from `jsonl_file`'s `thread.started` event (fresh-thread case only) and persist to `state.codex_thread_id` if it was the first call.
8. **Remove the slot** from `codex_reviews_in_progress`.
9. **Feed Codex's reply to the brainstorming flow** as the "user's response" to the prior question. The parent `superpowers:brainstorming` skill picks up from its waiting state and continues with the next question.

## Response handling (semantic content)

Codex's response IS the user's response, semantically. The bg-completion handler feeds it to the parent brainstorming flow.

Special signals to detect in the response:

- **UI/UX surfacing** ("this is a UI/UX call I shouldn't make for Tim — surface it: <question>"):
  - Interactive mode: pause, post in chat with notification, wait for user.
  - Autonomous mode: log to per-chain decisions file with defensible default; continue with the default applied. (Existing v0.1 behavior — unchanged.)

- **Convergence** ("looks good, write the plan" or similar):
  - Brainstorming converges naturally — the parent `brainstorming` skill detects the convergence signal and hands off to `writing-plans` via its own checklist.

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

- **Codex CLI not on PATH** (caught at launch time via `which codex` if the skill body opts to check, or surfaced by Bash exit code on launch): post chat note *"Codex CLI not available; brainstorming continues with Claude only. Install via `npm install -g @openai/codex`."* Skill exits silently. NOT a halt scenario — brainstorm-partner is opt-in collaboration, not a gate.
- **Bash launch failed** (non-zero exit on the Bash invocation itself): post chat note describing the failure; remove the pre-written slot from `state.codex_reviews_in_progress`; brainstorming continues with Claude only.
- **Stale-thread error in bg result** (per step 5 of On bg completion): brainstorming continues with Claude only for the affected question.
