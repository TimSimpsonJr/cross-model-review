---
name: cross-model-setup
description: First-run setup for the cross-model-review plugin. Verifies Codex CLI installation, prints CLAUDE.md additions, optionally applies them. Idempotent.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-setup

First-run setup wizard. Verifies the plugin's environment and prints (optionally applies) the CLAUDE.md additions needed for natural-language intent routing.

## Steps

1. **Verify Codex CLI installation.** Run `which codex` (or equivalent on Windows) and `codex --version`. If `which codex` returns non-zero OR the version is below `0.125.0`:
   - Output: "Codex CLI not found on PATH (or version is below 0.125.0). The cross-model-review plugin v0.3.0+ uses the Codex CLI via async Bash invocation — the MCP server is no longer required. Install or upgrade via `npm install -g @openai/codex` and re-run `/cross-model-setup`."
   - Exit.

   Note: prior plugin versions (v0.1, v0.2) required the Codex MCP server. v0.3.0+ uses the CLI directly to bypass Claude Code's UI watchdog (see [anthropics/claude-code#58480](https://github.com/anthropics/claude-code/issues/58480)). If you previously configured the MCP server, you can leave it configured — it's unused but not harmful — or remove its entry from `~/.claude/mcp_servers.json` / per-project `.mcp.json`.

2. **Verify Superpowers plugin.** Check whether `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:subagent-driven-development` skills are available. If absent:
   - Output: "Superpowers plugin not detected. Install via `/plugin install superpowers@superpowers-marketplace`. Re-run `/cross-model-setup` afterward."
   - Continue (warn, don't exit — plugin can still operate, just less integrated).

3. **Verify gh + ownership check.**

   a. Run `gh auth status`. If non-zero exit:
      - Output: "GitHub CLI is not authenticated. Run `gh auth login`
        and re-run /cross-model-setup. Skipping label creation; the
        plugin's review-and-fix flows still work, but it will halt
        if it tries to defer in autonomous mode."
      - Mark labels-step (step 7 below) as SKIP for this run.

   b. Run `git remote get-url origin 2>/dev/null` and check for
      `TimSimpsonJr/` or `TimSimpsonJr:` in the result.
      - If matches → owned-repo flag = TRUE.
      - If no match → owned-repo flag = FALSE; output:
        "Repo is not owned by TimSimpsonJr. Skipping plugin label
        creation per the global ownership rule (~/.claude/CLAUDE.md).
        The plugin will halt if it tries to file an issue here —
        intentional."
        Mark labels-step (step 7 below) as SKIP.

4. **Print the CLAUDE.md additions** that the plugin needs in `~/.claude/CLAUDE.md`:

   ```markdown
   ## Cross-Model-Review Plugin

   Natural-language intent mapping for the cross-model-review plugin:

   | User says | Map to |
   |-----------|--------|
   | "let codex take over" / "go autonomous" | `/cross-model-autonomous-on` |
   | "I'll take it from here" / "Tim's back" | `/cross-model-autonomous-off` + end any active codex-brainstorm-partner stand-in for the current brainstorm |
   | "skip codex on this" / "skip the review" | `/cross-model-skip` |
   | "let's brainstorm with codex" / "let codex weigh in" | Invoke `cross-model-review:codex-brainstorm-partner` |
   | "ask codex about <X>" / "what does codex think about <X>" | Launch async ad-hoc consultation via `codex exec resume <state.codex_thread_id>` (or fresh `codex exec` if first call) with `[MODE: ad-hoc]` prefix; written to a prompt file and run via Bash `run_in_background: true` per the **Codex async CLI call** pattern in the review skills |
   | "review the plan with codex" / "have codex check the implementation" | `/cross-model-review-now <kind>` |
   | "show me codex status" / "what's codex doing" | `/cross-model-status` |
   | "reset codex" / "fresh codex thread" | `/cross-model-reset` |
   | "let codex stop reviewing" | NO auto-map. Ask: "Skip just the next review (`/cross-model-skip`), turn off autonomous mode (`/cross-model-autonomous-off`), or both?" |

   The plugin's skills handle all behavior internally — bootstrap, mode tagging,
   review flows, autonomous handling, approval tracking, recovery. Their
   descriptions trigger them at lifecycle moments. The plugin's hooks provide
   backup nudges if a trigger is missed. Don't restate skill behavior here.
   ```

5. **Ask whether to apply automatically.** "Append the above to `~/.claude/CLAUDE.md` now? [Y/n]"

6. If yes:
   - Read `~/.claude/CLAUDE.md`. Check whether `## Cross-Model-Review Plugin` section already exists.
   - If exists: output "Section already present in CLAUDE.md. No changes made. If you want to refresh, manually delete the section and re-run setup."
   - If absent: append the additions verbatim. Output "Appended ~25 lines to ~/.claude/CLAUDE.md. The plugin is now active."

7. **Create plugin labels in current repo.** Skipped if step 3 marked
   labels-step as SKIP.

   For each label in `[autonomous-safe, design-input-needed]`, run
   `gh label create` with stderr filtering per the bulk-script pattern
   (design §7.2): "already exists" → silent skip; any other error →
   surface with the label name.

   ```bash
   for entry in "autonomous-safe|0E8A16|Code-only follow-up; eligible for autonomous pickup" \
                "design-input-needed|D93F0B|Requires user judgment before work proceeds"; do
     IFS='|' read -r name color desc <<< "$entry"
     out=$(gh label create "$name" --color "$color" --description "$desc" 2>&1)
     rc=$?
     if [ $rc -eq 0 ]; then
       echo "Created label: $name"
     elif echo "$out" | grep -qi "already exists"; then
       : # idempotent skip; no log
     else
       echo "FAIL: $name → $out" >&2
     fi
   done
   ```

8. **Verify hookify and offer to install backup-nudge rules.**

   Native Claude Code Stop hooks don't support transcript-pattern matchers (Stop events ignore the `matcher` field per the official hooks docs), so this plugin's Layer 3 backup nudges ride on the **hookify** plugin, which provides regex-driven Stop-event rules via per-project `.claude/hookify.*.local.md` files.

   - Detect hookify by checking whether the `hookify:writing-rules` skill (or any `hookify:*` command) is available in the current session. If absent:
     - Output: "hookify plugin not detected. The cross-model-review plugin's Layer 3 backup nudges (Stop-event reminders if a code-touching artifact was just saved and Codex review wasn't invoked) require hookify. Install via `/plugin install hookify@superpowers-marketplace` (or your equivalent marketplace) and re-run `/cross-model-setup`. Skipping hook installation — the plugin's skills and CLAUDE.md routing (Layers 1+2) still work."
     - Skip to step 9.
   - If hookify is present, ask: "Install hookify backup-nudge rules into `.claude/hookify.cross-model-plan-review.local.md` and `.claude/hookify.cross-model-impl-review.local.md` in this project? [Y/n]"
   - If yes:
     - For EACH planned rule file:
       - Check if file exists.
       - If absent → write the rule body verbatim.
       - If present → skip silently.
     - No "if all exist" early-exit; future rule additions land cleanly.
     - **NOTE for maintainers:** the rule files listed below must stay
       in sync with the `PLANNED` array in `commands/cross-model-status.md`
       step 5. If you add a third hookify rule, update both files in
       lockstep — otherwise the status report will be wrong-by-one.
     - Output: "Wrote N hookify rule file(s) to `.claude/`. Restart Claude Code for hookify to pick them up." (where N is the count of files actually written; if N is 0, output "All hookify rule files already present. No changes made.")

   **File 1 — `.claude/hookify.cross-model-plan-review.local.md`:**

   ```markdown
   ---
   name: cross-model-plan-review-nudge
   enabled: true
   event: stop
   action: warn
   conditions:
     - field: transcript
       operator: regex_match
       pattern: (saved to docs/plans/|plan complete|design doc written)
   ---

   Reminder: a plan or design doc was recently saved to `docs/plans/`. If this is
   a code-touching artifact and Codex review hasn't been invoked, consider
   invoking `cross-model-review:codex-plan-review` now. If you skipped it
   intentionally or it's not applicable (non-code plan), ignore this nudge.

   Respect `state.skip_next_review` — if set in
   `.claude/cross-model-review.session.local.md`, do not invoke (the plugin's
   skill bodies handle the actual skip; this hook is just a reminder).
   ```

   **File 2 — `.claude/hookify.cross-model-impl-review.local.md`:**

   ```markdown
   ---
   name: cross-model-impl-review-nudge
   enabled: true
   event: stop
   action: warn
   conditions:
     - field: transcript
       operator: regex_match
       pattern: (all tasks complete|implementation complete|subagent-driven-development finished|ready to PR)
   ---

   Reminder: subagent-driven-development recently completed. Consider invoking
   `cross-model-review:codex-impl-review` before opening a PR. If skipped
   intentionally or not applicable, ignore.

   Respect `state.skip_next_review` — if set in
   `.claude/cross-model-review.session.local.md`, do not invoke.
   ```

   Notes for the writer:
   - Both rules use `action: warn` (the hookify default) so the nudge surfaces without blocking the agent stop. Skip-flag respect lives inside the message body — Claude reads it and consults `state.skip_next_review` before acting.

9. **Suggest per-project notes (optional).** "If this project is a mixed-content repo (some content work, some code work — e.g., a website with a blog), add a per-project CLAUDE.md note. See README.md for an example."

10. **Idempotent:** running this multiple times just re-checks status. Doesn't double-write the CLAUDE.md section, doesn't re-create existing labels (filtered as "already exists" in step 7), doesn't overwrite existing hookify rule files (per-rule check in step 8).
