---
description: toggle the mentor orchestrator (on|off|status|clear) — an orthogonal config flag, settable per-repo or globally, that forces the main thread to orchestrate (dispatch subagents) for all substantive work
argument-hint: "[on | off | status | clear] [global]"
allowed-tools: [Bash, Read]
---

# mentor — orchestrator toggle

Orchestrator is an **orthogonal toggle** (not a working mode — see `/mentor:mode`). When ON,
a hard `PreToolUse` gate forces the main conversation to be a pure orchestrator: it dispatches
subagents for **all** substantive work (every repo edit, repo-mutating Bash, bulk reads) and
verifies their returns. Subagents run freely; the plan / ship / harvest / simplify flows are exempt.

It persists as `{"orchestrator": true|false}` in two scopes:

- **repo** — `~/.claude/mentor/<repo>-<hash>/config.json` (default scope for this command)
- **global** — `~/.claude/mentor/config.json` (add the `global` token)

**Resolution:** explicit repo value > legacy `mode:commander` > global value > OFF. So a repo
`off` overrides a global `on`; `clear` deletes the scope's key so it re-inherits the lower scope
(the only way back from an explicit repo `off`). Global ON takes effect only inside a git repo
(the gate is repo-scoped).

Do this:

1. **Parse the arguments** (action-first grammar):
   - **token1** ∈ `on | off | status | clear` (empty → `status`)
   - **token2** (optional) ∈ `global` → global scope; otherwise repo scope
   - Anything else → show usage and stop.

   Then run (map `global` → `--global`):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-orchestrator.sh" <action> [--global]
   ```

   The raw arguments were: `$ARGUMENTS`

2. **Report the script's output verbatim** (it prints the resulting + resolved state). If the
   toggle is now ON, note the gate reads the config on every call, so it is live for an
   already-running session. (Exception: if mentor was just installed/updated this session, its
   hooks only register on the next session start — restart to activate the gate.)
