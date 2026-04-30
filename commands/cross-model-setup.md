---
description: First-run setup for the cross-model-review plugin. Verifies Codex MCP, prints CLAUDE.md additions, optionally applies them. Idempotent.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-setup

First-run setup wizard. Verifies the plugin's environment and prints (optionally applies) the CLAUDE.md additions needed for natural-language intent routing.

## Steps

1. **Verify Codex MCP availability.** Check whether `mcp__codex__codex` and `mcp__codex__codex-reply` tools are present in the current session. If absent:
   - Output: "Codex MCP server is not configured. The cross-model-review plugin requires Codex MCP. Configure your MCP server (typically via `~/.claude/mcp_servers.json` or per-project `.mcp.json`) and re-run `/cross-model-setup`."
   - Exit.

2. **Verify Superpowers plugin.** Check whether `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:subagent-driven-development` skills are available. If absent:
   - Output: "Superpowers plugin not detected. Install via `/plugin install superpowers@superpowers-marketplace`. Re-run `/cross-model-setup` afterward."
   - Continue (warn, don't exit — plugin can still operate, just less integrated).

3. **Print the CLAUDE.md additions** that the plugin needs in `~/.claude/CLAUDE.md`:

   ```markdown
   ## Cross-Model-Review Plugin

   Natural-language intent mapping for the cross-model-review plugin:

   | User says | Map to |
   |-----------|--------|
   | "let codex take over" / "go autonomous" | `/cross-model-autonomous-on` |
   | "I'll take it from here" / "Tim's back" | `/cross-model-autonomous-off` + end any active codex-brainstorm-partner stand-in for the current brainstorm |
   | "skip codex on this" / "skip the review" | `/cross-model-skip` |
   | "let's brainstorm with codex" / "let codex weigh in" | Invoke `cross-model-review:codex-brainstorm-partner` |
   | "ask codex about <X>" / "what does codex think about <X>" | Direct `mcp__codex__codex-reply` (or `codex` if first call) with `[MODE: ad-hoc]` prefix; uses active session thread |
   | "review the plan with codex" / "have codex check the implementation" | `/cross-model-review-now <kind>` |
   | "show me codex status" / "what's codex doing" | `/cross-model-status` |
   | "reset codex" / "fresh codex thread" | `/cross-model-reset` |
   | "let codex stop reviewing" | NO auto-map. Ask: "Skip just the next review (`/cross-model-skip`), turn off autonomous mode (`/cross-model-autonomous-off`), or both?" |

   The plugin's skills handle all behavior internally — bootstrap, mode tagging,
   review flows, autonomous handling, approval tracking, recovery. Their
   descriptions trigger them at lifecycle moments. The plugin's hooks provide
   backup nudges if a trigger is missed. Don't restate skill behavior here.
   ```

4. **Ask whether to apply automatically.** "Append the above to `~/.claude/CLAUDE.md` now? [Y/n]"

5. If yes:
   - Read `~/.claude/CLAUDE.md`. Check whether `## Cross-Model-Review Plugin` section already exists.
   - If exists: output "Section already present in CLAUDE.md. No changes made. If you want to refresh, manually delete the section and re-run setup."
   - If absent: append the additions verbatim. Output "Appended ~25 lines to ~/.claude/CLAUDE.md. The plugin is now active."

6. **Verify hookify and offer to install backup-nudge rules.**

   Native Claude Code Stop hooks don't support transcript-pattern matchers (Stop events ignore the `matcher` field per the official hooks docs), so this plugin's Layer 3 backup nudges ride on the **hookify** plugin, which provides regex-driven Stop-event rules via per-project `.claude/hookify.*.local.md` files.

   - Detect hookify by checking whether the `hookify:writing-rules` skill (or any `hookify:*` command) is available in the current session. If absent:
     - Output: "hookify plugin not detected. The cross-model-review plugin's Layer 3 backup nudges (Stop-event reminders if a code-touching artifact was just saved and Codex review wasn't invoked) require hookify. Install via `/plugin install hookify@superpowers-marketplace` (or your equivalent marketplace) and re-run `/cross-model-setup`. Skipping hook installation — the plugin's skills and CLAUDE.md routing (Layers 1+2) still work."
     - Skip to step 7.
   - If hookify is present, ask: "Install hookify backup-nudge rules into `.claude/hookify.cross-model-plan-review.local.md` and `.claude/hookify.cross-model-impl-review.local.md` in this project? [Y/n]"
   - If yes:
     - Check whether either file already exists. If both exist: output "hookify rules already installed. No changes made. Delete them manually if you want to re-install." and skip to step 7.
     - For each missing file, write the corresponding content below verbatim.
     - Output: "Wrote N hookify rule file(s) to `.claude/`. Restart Claude Code for hookify to pick them up."

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

7. **Suggest per-project notes (optional).** "If this project is a mixed-content repo (some content work, some code work — e.g., a website with a blog), add a per-project CLAUDE.md note. See README.md for an example."

8. **Idempotent:** running this multiple times just re-checks status. Doesn't double-write the CLAUDE.md section, doesn't overwrite existing hookify rule files.
