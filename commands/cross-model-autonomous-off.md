---
description: Disable autonomous mode for the cross-model-review plugin. Return to interactive mode where user approves transitions between gates.
allowed-tools: Read, Write, Edit, Bash
---

# /cross-model-autonomous-off

Return to interactive mode for the cross-model-review plugin.

## Steps

1. Bootstrap state.

2. Set `state.autonomous = false`. Update state file.

3. **Also end any active codex-brainstorm-partner stand-in for the current brainstorm flow.** Don't invoke `codex-brainstorm-partner` again unless user explicitly re-opts in (e.g., says "let codex take over again").

4. Output:

   ```
   Autonomous mode OFF.

   User approval is required for transitions between design → plan → impl gates.
   Codex review still fires automatically for code-touching work.

   To re-enable autonomous mode: /cross-model-autonomous-on
   ```
