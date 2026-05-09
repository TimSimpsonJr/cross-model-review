---
name: cross-model-skip
description: Suppress the next single Codex review trigger of any kind. One-shot; clears automatically after one trigger fires-or-skips.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-skip

Suppress the next Codex review trigger of any kind. One-shot.

## Steps

1. Bootstrap state. If the state file is missing, fresh-create with defaults (writer contract, design §6.1) including:

   ```yaml
   filed_issues: []
   context_limit_tokens: 200000
   ```

   alongside the other v0.1 defaults.

2. Set `state.skip_next_review = true`. Update state file. **Preserve `filed_issues` and `context_limit_tokens` verbatim** — only set `skip_next_review`.

3. Determine what's likely to fire next (based on conversation context — is brainstorming about to end? Did writing-plans just save? Did subagent-driven-development complete?). Identify the most likely next trigger.

4. Output an explicit announcement of what's armed vs still armed:

   ```
   /cross-model-skip armed.

   Next review trigger will be suppressed. Based on current context, the
   most likely upcoming trigger is:
     <best guess: design-review | plan-review | impl-review | none currently expected>

   Still armed for normal triggering after this single skip:
     <list of other review kinds not affected>
     brainstorm-partner (not affected by skip)
     ad-hoc consultations (not affected by skip)

   Skip flag clears automatically after one review trigger fires-or-skips.
   ```

5. The flag is consumed when:
   - Any review skill bootstraps and finds it set (Block B step 2): clear flag, exit skill, post "Codex review skipped per /cross-model-skip" chat note.
   - User invokes `/cross-model-skip` again with the flag already set: refresh the announcement (no double-skip).
   - `/cross-model-reset` invoked: cleared with all other state.
