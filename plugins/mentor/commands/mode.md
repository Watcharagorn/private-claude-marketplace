---
description: get or set the persisted per-repo mentor defaults — the approval-gate default (plan | plan-only) and the dispatch preference (agents | solo | verify-only)
argument-hint: "[plan | plan-only | agents | solo | verify-only | status]"
allowed-tools: [Bash, Read, Skill, AskUserQuestion]
---

# mentor — repo mode

Two independent defaults persist per repo in `<repo>/.mentor/config.json`.
Setting one never clears the other.

**Axis 1 — approval-gate default.** Decides which option `/mentor:plan`'s final
approval question lists first; both outcomes are always offered there:

- **plan** — "Proceed" listed first (plan, then implement on approval).
- **plan-only** — "Deliver plan only" listed first (the plan file is the
  deliverable). A default, not a lock — picking "Proceed" still implements.

Unset behaves as `plan`. `/mentor:plan` never asks for a mode upfront.

**Axis 2 — dispatch preference.** Decides where implementation and verification
run, and exists so a repo with a standing no-subagents instruction is asked once
instead of at every dispatch surface in every session:

- **agents** — route per `dispatch-agents`' "Where dispatch pays" test.
  Recording this explicitly also silences a false-positive policy hit in a repo
  that merely *discusses* background agents.
- **verify-only** — implementation in the main thread, verification still
  dispatched to fresh agents. Keeps the independent grader.
- **solo** — implementation *and* verification in the main thread. Gives up
  independent grading, so a plan closed this way must disclose that in its report.

Unset means "no override — route per the test", which is the ordinary state.
Once set, `plan-state.sh policy` reports `POLICY: SET` and no surface asks again.

Do these in order:

1. **Run the mode script with the mode word only.** Take only the **first
   whitespace-delimited token** of the arguments as the mode word (`plan` |
   `plan-only` | `agents` | `solo` | `verify-only` | `status`; empty → `status`)
   and run:

   ```bash
   [ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <mode-word>
   ```

   The raw arguments were: `$ARGUMENTS`

2. **Report the resulting mode verbatim** (the script's confirmation lines).
   `UNSET` is a fully functional state on both axes — `mode` defaults to `plan`,
   and an unset `dispatch` means the routing test decides. Report it as such; do
   **not** ask the user to pick either one.

If a feature/task request was passed in the SAME prompt as this command (anything
beyond the first mode-word token), it did **not** start the plan harness. After
reporting the mode, enter the harness yourself:

```bash
[ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"
```

Read its stdout first (it carries the mode-aware instructions). **If that stdout contains
`CONTEXT: ASK`**, do **not** invoke the plan skill yet — the user decides first: follow the
printed directive and ask via AskUserQuestion; on "Hand off & plan in a fresh session"
invoke `Skill(skill="mentor:handoff-note")` and STOP, on "Proceed anyway" run the printed bypass
script, re-run `begin-plan.sh`, then continue. If it contains `CONTEXT: HANDOFF` (armed,
critically large), surface it and keep the plan lean; if `CONTEXT: WARN`, mention it and
continue. Then invoke `Skill(skill="mentor:planning", args="<the co-submitted request>")`.
