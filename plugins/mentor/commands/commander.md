---
description: (renamed) commander is now the orchestrator toggle — use /mentor:orchestrator
argument-hint: "[on | off | status]"
allowed-tools: [Bash, Read]
---

# mentor — commander (renamed to orchestrator in v0.37; this stub drops in 0.38)

Commander is now the orthogonal **orchestrator toggle** owned by `/mentor:orchestrator`
(settable per-repo or globally; repo overrides global). It is no longer a working mode.

Take the first whitespace-delimited token of the arguments (`on` | `off` | `status`;
empty → `status`) and run the orchestrator script directly:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-orchestrator.sh" <on|off|status>
```

Then report its output verbatim and tell the user the command was renamed — going forward
use `/mentor:orchestrator on | off | status | clear` (add `global` for the global scope).

$ARGUMENTS
