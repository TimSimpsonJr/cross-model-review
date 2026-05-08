---
name: cross-model-autonomous-on
description: Enable autonomous mode for the cross-model-review plugin. Codex consensus replaces user approval at code-only gates.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-autonomous-on

Enable autonomous mode for the cross-model-review plugin in this project.

## Steps

1. Bootstrap state per the universal pattern: read `.claude/cross-model-review.session.local.md`; create with defaults if missing.

   Fresh-create defaults (writer contract, design §6.1) include:

   ```yaml
   filed_issues: []
   context_limit_tokens: 200000
   ```

   alongside the other v0.1 defaults (`autonomous`, `codex_thread_id`, `active_chain_artifact`, etc.).

2. Set `state.autonomous = true`. Update the state file on disk. **Preserve `filed_issues` and `context_limit_tokens` verbatim** — only flip `autonomous`.

3. If `state.codex_thread_id` is null (no Codex calls yet this project), don't initialize a thread — just record the autonomous flag.

4. Output:

   ```
   Autonomous mode ON.

   Codex consensus will replace user approval at design / plan / impl review gates.
   UI/UX questions will be deferred to the per-chain decisions file with defensible defaults.

   To return to interactive mode: /cross-model-autonomous-off
   ```

5. If a brainstorming flow is currently active in this conversation, also note: "Brainstorming-partner mode will activate automatically for upcoming brainstorm turns."
