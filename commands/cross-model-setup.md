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

6. **Suggest per-project notes (optional).** "If this project is a mixed-content repo (some content work, some code work — e.g., a website with a blog), add a per-project CLAUDE.md note. See README.md for an example."

7. **Idempotent:** running this multiple times just re-checks status. Doesn't double-write the section.
