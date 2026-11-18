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

File access: your only way to read the repository is via your shell — there is no
separate built-in file-reading tool. Read files with simple shell commands (for
example `Get-Content <path>` or `rg <pattern>`); they work under this session's
sandbox. If a shell command is ever rejected, reformulate it as a simpler read and
retry — do not give up or ask for file contents to be pasted unless you are truly
unable to proceed. (You may see a `failed to record rollout items` line in the logs;
it is a harmless known Codex log — ignore it.)

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
   claims that don't match the actual repo. You can read the working directory
   to verify claims — you are a reviewer, so inspect it but do not modify it.
   The depth and focus expected of you — and whether
   to cite specific file paths and line numbers — depend on the mode and are
   specified in each per-turn prompt; follow those instructions. Be specific
   and avoid generic praise. Each review turn ends with a single
   machine-parseable verdict line per the per-turn prompt's instructions.

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
     - Search all three plan-doc roots on the current branch — `docs/superpowers/specs/` and `docs/superpowers/plans/` (superpowers ≥5) plus legacy `docs/plans/` (superpowers ≤4.3) — for design/plan docs whose frontmatter contains `codex_thread_id`.
     - Filter to candidates within last 24h OR matching the branch's most-recent commits.
     - If exactly ONE candidate → set `state.codex_thread_id` to its frontmatter thread_id; the next CLI call will be a `codex exec resume` continuation (stale-thread detection in the bg-completion handler covers expired-thread cases).
     - If ZERO candidates → write fresh state file with defaults; the first `codex exec` call this project makes will create a new thread.
     - If MULTIPLE candidates → write fresh state file with defaults; post chat note: "Multiple design/plan docs in `docs/superpowers/` or `docs/plans/` could match this branch. Not auto-resuming. Use `/cross-model-review-now <kind> <path>` to manually resume from a specific artifact."

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

**Compute the OS-gated sandbox mode first.** Run `uname -s`. If it matches `MINGW*`,
`MSYS*`, or `CYGWIN*` (Codex is the PowerShell-wrapping Windows build, whose `read-only`
command policy rejects PowerShell shell calls), set `SANDBOX_MODE=workspace-write`.
Otherwise (`Linux` including WSL, or `Darwin`) set `SANDBOX_MODE=read-only`.
`workspace-write` clears the Windows PowerShell block while still denying network and
out-of-workspace writes; the only relaxation is in-repo writes (accepted — see the
v0.4.1 design §4.1/§4.3/§4.4). Substitute the resolved value for `$SANDBOX_MODE` below.

**Fresh thread** (attempted_thread_id null):
```bash
codex exec --sandbox $SANDBOX_MODE -C <project-toplevel> --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

**Continuation** (attempted_thread_id set):
```bash
cd <project-toplevel> && codex exec resume <attempted_thread_id> -c sandbox_mode="$SANDBOX_MODE" --json \
  -o <result_file> < <prompt_file> > <jsonl_file> 2> <stderr_file>
```

> **cwd invariant (do not "simplify" away):** the leading `cd` is load-bearing.
> Codex records and filters sessions by cwd; the fresh-thread call above mints
> the thread from `<project-toplevel>` via `-C`, so resuming from that same
> directory is how Codex locates the session. Do not drop the `cd`, and do not
> add `--all` (which would disable cwd filtering). The fresh path keeps the
> first-class `--sandbox`/`-C` flags deliberately — they fail loud if the CLI
> changes again, whereas `-c sandbox_mode=` fails silent. `$SANDBOX_MODE` is
> `workspace-write` on Windows (Git Bash) and `read-only` elsewhere. (Design §4.)

Use the Bash tool with `run_in_background: true`. Capture the returned `bash_id`.

### Step 5: Update the slot with the captured `bg_id`

Update the slot's `bg_id` from `"pending"` to the actual `bash_id`. Persist state.

### Step 6: Post chat note and end the turn

Post: *"Codex stand-in thinking about the brainstorming question — sandbox `$SANDBOX_MODE` (on Windows this is `workspace-write`: Codex can write in-repo, network denied); typical 1–5 min at `xhigh` reasoning for a single question. Will surface response when complete."*

End the turn. The parent brainstorming flow stays paused at its turn boundary waiting for "the user's response" (which will arrive via Codex on a subsequent turn).

## On bg completion (next-turn handling)

When a Bash bg job's completion notification arrives in a future turn:

1. **Look up the slot** in `state.codex_reviews_in_progress` by the notification's `bash_id`. If found, proceed to step 4.
2. **Fallback for the launch race**: if no direct match, scan slots where `bg_id == "pending"` AND `result_file` exists on disk. If exactly one matches, use it.
3. If still no match: this notification is for an unrelated bg job. Ignore.
4. **Branch on `status`:**
   - `status == "detached"` (user ran `/cross-model-reset` mid-stand-in): inspect result file; post a chat note per the cases in `codex-plan-review` (non-empty; otherwise run the **Empty-result failure classifier** below → usage-limit / stale-thread / missing-or-empty / corrupt). Remove the slot. Brainstorming continues without this stand-in input (parent skill resumes when user provides actual input).
   - `status == "in_progress"`: proceed to step 5.
5. **Classify the outcome by positive evidence first.** Read `result_file`.
   - **If `result_file` is non-empty and usable as a reply → treat as SUCCESS,** regardless of any stderr substrings. If `stderr_file` also contains `"failed to record rollout items"`, post a soft chat note: *"Codex emitted a rollout-recording error during this turn; its reply is complete, but a later resume of this thread could be degraded."* Take NO state action. Proceed to step 6.
   - **Only if `result_file` is empty or unusable:** run the **Empty-result failure classifier** (after step 9) and act on its verdict:
     - `usage_limit` → post chat note *"Codex is unavailable right now (usage limit). The thread is fine; brainstorming continues with Claude only for this question, and Codex can stand in again once the limit resets."* (If `attempted_thread_id` is null, drop "The thread is fine;".) Set slot's `status: "usage_limit"`, remove the slot, and continue with Claude only. Do NOT clear `state.codex_thread_id`: the thread is intact.
     - `stale_thread` → post chat note *"Codex thread `<attempted_thread_id>` has expired. Brainstorming continues with Claude only for this question."* Set slot's `status: "stale_thread_error"`, remove the slot, and continue with Claude only. Do NOT auto-recover.
     - `other` → post a chat note that the Codex stand-in failed (see stderr at `<stderr_file>`), remove the slot, and continue with Claude only.
6. **Read `result_file`** — Codex's reply, formatted as if it were the user's response.
7. **Extract `thread_id`** from `jsonl_file`'s `thread.started` event (fresh-thread case only) and persist to `state.codex_thread_id` if it was the first call.
8. **Remove the slot** from `codex_reviews_in_progress`.
9. **Feed Codex's reply to the brainstorming flow** as the "user's response" to the prior question. The parent `superpowers:brainstorming` skill picks up from its waiting state and continues with the next question.

<!-- lockstep:empty-result-classifier:start (byte-identical in all 3 skills) -->
**Empty-result failure classifier.** Run this only when `result_file` is missing, empty, or unusable (step 5's failure path, and the detached cases in step 4). Work through it in order and stop at the first verdict that matches:

a. **Drop the harmless rollout line first.** Ignore every line of `jsonl_file` and `stderr_file` that contains `failed to record rollout items`. It is a cosmetic upstream log ([openai/codex#19475](https://github.com/openai/codex/issues/19475)) whose text includes `thread <id> not found`, so it must never reach steps b and c. It says nothing about why the turn failed.

Steps b and c look only at **error text**: the remaining lines of `stderr_file`, plus the `message` of `"type":"error"` events and the `error.message` of `"type":"turn.failed"` events in `jsonl_file`. Never scan `result_file` or other jsonl events (agent messages, command output): Codex may quote a file that happens to contain these phrases.

b. **`usage_limit`** — checked before the stale-thread scan, because a usage limit leaves the thread intact. Match if any holds (all substring matches case-insensitive):
   - the `turn.failed` message, an `error` event message, or a remaining `stderr_file` line contains `usage limit`, `quota exceeded`, `spend cap`, or `out of credits`; or
   - the `turn.failed` message (the turn's final error, not an earlier `error` event the turn may have recovered from) contains `rate limit`, `429 Too Many Requests`, or `exceeded retry limit, last status: 429`.

   A `turn.failed` event on its own is NOT enough: Codex emits one for every failed turn. The markers come from the Codex CLI source (`codex-rs/protocol/src/error.rs`, checked at 0.125.0, 0.151.0 and 0.170.0): `You've hit your usage limit…` (straight apostrophe through 0.151, curly `You’ve` by 0.170, so match on `usage limit`, never on the apostrophe), `Quota exceeded. Check your plan and billing details.`, `You hit your spend cap…` and `Your workspace is out of credits…` (newer builds only), the retry-exhausted `exceeded retry limit, last status: 429 Too Many Requests`, and an API `Rate limit reached for model …`. Retry notices such as `Reconnecting... 2/5 (…)` arrive as `error` events even when the turn later recovers, which is why `rate limit` and `429` count only in the final `turn.failed` message. Wording can drift across Codex releases: an unrecognized usage-limit message falls to `other` (generic failure handling), not to `stale_thread`, because step a already removed the rollout line that used to cause that misreport.
c. **`stale_thread`** — that error text contains `Session not found for thread_id`, `no rollout found for thread id`, or `thread not found`. (Fuzzy signal: the Codex CLI documents no stable error contract for an expired thread.)
d. **`other`** — nothing above matched.
<!-- lockstep:empty-result-classifier:end -->

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
- **Stale-thread error or usage limit in bg result** (per step 5 of On bg completion): brainstorming continues with Claude only for the affected question.
