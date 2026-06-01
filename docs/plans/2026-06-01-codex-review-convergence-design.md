---
title: Codex Review Convergence + Depth Calibration
date: 2026-06-01
status: draft
cross_model_review: false
---

# Codex Review Convergence + Depth Calibration

## Problem

Plan and design reviews regressed from converging in 3–4 Codex rounds to
grinding through 9–10 rounds of minor nitpicks. The regression is worst at the
`design-review` gate (end of brainstorming), where Codex gets "into the weeds"
on implementation-level detail that does not belong at the conceptual stage.

## Root cause

Two factors compounded; only one is recent.

1. **Trigger (recent — PR #7 / fix #5, 2026-05-28).** The universal priming
   gained a "read files directly" nudge for Windows
   (`skills/codex-plan-review/SKILL.md` priming block). Before it, Codex's
   shell-based grep/read was blocked by powershell-wrapping in the sandbox, so
   on Windows it reviewed the artifact text in relative isolation and converged
   fast. After it, Codex actually inspects the repo and — following the
   long-standing priming instruction to "verify claims against actual code …
   cite file paths and line numbers" — surfaces far more findings, most of them
   minor.

2. **Amplifier (long-standing).** `plan-review`/`design-review` have **no
   severity floor**. The routing (`SKILL.md:457`) revises the artifact on *any*
   substantive finding — `minor` is treated identically to `critical` — and the
   loop only ends when Codex spontaneously emits a fuzzy convergence phrase
   ("looks good"/"approved", detected at `SKILL.md:433`). `impl-review` already
   has a floor ("approve OR all CRITICAL/IMPORTANT resolved; MINOR does not
   block"); the plan/design gates never got one.

Net: #5 unlocked deep review, and the missing floor converts that depth
directly into rounds. The approval signal was always *detected*, never
*requested*, so once Codex always has "one more nit," it never volunteers the
signal and the loop runs long.

## Goals

- Converge plan/design reviews in a small number of rounds again, **without**
  giving up the deeper repo-aware review #5 unlocked.
- Make the approval decision an explicit, parseable per-round verdict rather
  than fuzzy phrase-matching.
- Calibrate review depth to the gate: high-altitude at `design-review`,
  in-the-weeds at `plan-review` and `impl-review`.
- Stop `impl-review` from deferring fixes a subagent could simply make.

## Non-goals

- Changing the chain/state machine, frontmatter resume, or issue-filing schema.
- Changing `codex-brainstorm-partner`'s behavior (it is not a review gate).
- Pinning Codex reasoning effort (left to the user's `~/.codex/config.toml`, as
  today).

## Design

### 1. Verdict contract (per-turn approval gate)

Each review round, Codex must end its response with a **parseable verdict line**:

```
[VERDICT: approved]            — no blocking (critical/important) concerns remain.
[VERDICT: changes-requested]   — at least one blocking concern.
```

On `changes-requested`, Codex lists **only the blocking items**, each phrased as
a concrete, actionable change Claude can make to earn approval next round, using
the existing `[severity:…, scope:…, cluster:…]` tag-line. Non-blocking
observations go under a separate `Non-blocking notes:` heading and **do not
affect the verdict**.

This makes the severity floor structural: only blocking items can appear in the
actionable list, so `minor` findings physically cannot drive the loop. It also
replaces fuzzy convergence detection with a real token.

### 2. Per-mode depth calibration

A mode-specific **depth header** precedes the artifact in the per-turn prompt:

- **`design-review` — architecture level.** Read the repo only to check whether
  the design's assumptions about existing code hold (e.g. a module it relies on
  already works differently than assumed). Do **not** cite line numbers, nitpick
  naming, or raise implementation-level detail — that belongs at the
  implementation-plan gate.
- **`plan-review` — deep / repo-verify.** Verify the plan in detail against the
  actual repo: confirm referenced symbols exist and behave as claimed, check
  file paths, flag drift from the previously-approved design.
- **`impl-review` — deep (unchanged).** Already deep; already floored.

### 3. Routing & convergence (skill body)

Replaces the current `plan-review`/`design-review` routing (`SKILL.md:427-480`):

1. **Parse `[VERDICT: …]`.**
   - `approved` → **stop.** Apply any `Non-blocking notes:` as a final polish
     edit (see §4), then write approval status + hash to frontmatter, post the
     "approved after N rounds" summary, exit loop.
   - `changes-requested` → go to step 3.
   - **No parseable token** → treat as `changes-requested` (never auto-approve
     without an explicit token). If Codex *also* returned no actionable items,
     fall to the existing "garbage: retry once, then treat as unavailable" path
     (`SKILL.md:694`).
2. **User-input check (unchanged).** A "this is a user decision" flag still
   outranks severity and routes to the user (interactive) or a
   `design-input-needed` issue (autonomous).
3. **Address blocking items.** Edit the artifact to resolve only the actionable
   blocking items (plus any non-blocking notes — see §4). At `plan-review`,
   still flag changes that contradict the approved design as drift
   (`SKILL.md:480`). Loop back for the next verdict.

The loop's **terminal condition** is `[VERDICT: approved]`. It is *not* gated on
"zero non-blocking notes" — doing so would reopen the nitpick spiral.

### 4. Non-blocking disposition (design/plan gates)

Rule: **Claude addresses non-blocking notes in the round they are raised.**

- **Raised mid-loop** (alongside blockers in a `changes-requested` round): fixed
  together with the blockers, so they are re-reviewed for free on the next
  submission. Zero added rounds.
- **Raised in the approving response**: applied as a single final polish edit
  before moving on. The approval hash is computed **after** this edit, so the
  recorded hash matches the artifact that actually moves forward. **No extra
  confirmation round** — the items are non-blocking by construction, and a
  confirmation pass would reintroduce the round-cost this design removes.

This supersedes the interim "surface-and-stop" idea: non-blocking items are
fixed, never merely listed.

### 5. impl-review budget-gate fix

The existing `impl-review` minor routing (`codex-impl-review/SKILL.md` §3b)
defers a finding to an `autonomous-safe` issue when `scope == large` **or**
`pct >= 85%`. Both are exactly the cases a subagent should absorb — a subagent
fixes in its own context window, so a large-scope minor is the *best* case for a
subagent, and a loaded main session is a reason to *offload to* one, not to
defer. The gate over-defers fixes that should just be dispatched.

Revised §3b:

- **Trivial + comfortable context** (small scope, main session has room) →
  **inline fix.**
- **Otherwise → subagent fix.** The default. Offloads large context and/or
  protects a loaded session. One subagent per cluster.
- **Defer to an `autonomous-safe` issue only when the fix is not cleanly
  subagent-dispatchable** — cross-cutting/multi-file work, or large/risky enough
  to deserve its own reviewed PR. (Design-judgment cases already route to
  `design-input-needed` via the user-decision check, not here.)

Net: `scope` and `pct` now only choose **inline vs subagent**; deferral becomes
a rare, explicitly-justified exception.

### 6. Placement & priming changes

Per Approach A, the **operative** instructions (verdict contract + depth header)
live in the **per-turn prompt**, re-sent every round so they survive long-thread
context drift — the exact failure mode behind the regression. The **universal
priming** keeps the stable role definition, the `[severity:…]` tag-line spec,
the user-decision surfacing, and the Windows file-read note.

Priming edits:

- **Generalize** the current "Design / plan / diff review" bullet
  (`SKILL.md:71-78`): drop the universal "cite file paths and line numbers"
  directive (the line mis-calibrating `design-review`); state that depth and
  focus are specified per-turn by mode.
- **Add one line** noting that review turns end with a `[VERDICT: …]` line per
  the per-turn instructions.
- **Remove** the fuzzy "Signal convergence with 'looks good' or 'approved'"
  instruction (`SKILL.md:77`) in favor of the verdict line.

### 7. Scope across the three skills + lockstep discipline

| Skill / mode | Depth header (per-turn) | Verdict contract | Non-blocking disposition |
|---|---|---|---|
| `codex-plan-review` · design-review | architecture-level | yes | fix-before-moving-on (§4) |
| `codex-plan-review` · plan-review | deep / repo-verify | yes | fix-before-moving-on (§4) |
| `codex-impl-review` | deep (unchanged) | yes | budget-gated (§5) |
| `codex-brainstorm-partner` | n/a — not a review gate | no | n/a |

- **`codex-impl-review`** keeps its budget-gated minor handling (a *code* fix can
  be context-expensive, unlike a cheap doc edit). It gains the verdict contract
  and verdict-parsing in its routing; its depth is unchanged.
- **`codex-brainstorm-partner`** is behaviorally untouched — it has its own
  convergence ("looks good, write the plan") and no artifact to approve. It
  inherits the shared priming edit only, to preserve byte-identical lockstep.

**Refined lockstep discipline** (updates `MANIFEST.md:61`):

- **Universal priming** → byte-identical across all three → diff-verify all three.
- **Verdict-contract block** → identical across the two review skills (plan +
  impl) → diff-verify those two.
- **Depth header** → mode-specific → *not* lockstep; edited per mode.

### 8. Autonomous non-convergence safety valve

The verdict gate makes convergence far more likely but not guaranteed (e.g. a
fix for blocker A reintroduces blocker B, oscillating). Interactive mode is
self-correcting — the user sees each round. **Autonomous mode** has no human, so:

- After **N = 6** rounds still in `changes-requested`, autonomous mode **halts**,
  writes a halt note (existing autonomous halt mechanism), and surfaces instead
  of looping. Interactive mode stays **uncapped**.

## Affected files

- `skills/codex-plan-review/SKILL.md` — priming generalization; per-turn prompt
  (depth header + verdict contract); routing rewrite (§3); non-blocking
  disposition (§4); safety valve (§8).
- `skills/codex-impl-review/SKILL.md` — shared priming edit; per-turn verdict
  contract; verdict-parsing in routing; §3b budget-gate fix (§5); safety valve.
- `skills/codex-brainstorm-partner/SKILL.md` — shared priming edit only.
- `MANIFEST.md` — refined lockstep note (§7).
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — version bump + entry.

## Risks & mitigations

- **Codex ignores the verdict format.** Mitigated by the "no token →
  changes-requested" default (never a false approval) plus the existing
  retry-once-then-unavailable path.
- **Depth header leaks across modes** because the priming is shared. Mitigated
  by keeping depth in the per-turn prompt (which carries the `[MODE]` tag), not
  the priming.
- **Lockstep drift** between the two review skills' verdict blocks. Mitigated by
  the diff-verify discipline (§7), same as the existing priming/launch-block
  discipline.

## Validation

- Dogfood: once implemented, run this design's *own* implementation plan through
  the new `plan-review` and confirm it converges in a small number of rounds
  with a clean `[VERDICT: approved]`.
- Spot-check a `design-review` produces architecture-level findings only (no
  line-number nitpicks).
- Spot-check an `impl-review` minor with `scope: large` is dispatched to a
  subagent rather than deferred to an issue.
