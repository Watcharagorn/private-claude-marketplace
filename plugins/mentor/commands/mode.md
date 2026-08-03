---
description: get or set the persisted per-repo approval-gate default (plan | plan-only)
argument-hint: "[plan | plan-only | status]"
allowed-tools: [Bash, Read, Skill, AskUserQuestion]
---

# mentor — repo mode

The mentor mode persists per repo in `<repo>/.mentor/config.json` and is only
the **approval-gate default** — it decides which option `/mentor:plan`'s final
approval question lists first; both outcomes are always offered there:

- **plan** — "Proceed" listed first (plan, then implement on approval).
- **plan-only** — "Deliver plan only" listed first (the plan file is the
  deliverable). A default, not a lock — picking "Proceed" still implements.

Unset behaves as `plan`. `/mentor:plan` never asks for a mode upfront.

Do these in order:

1. **Run the mode script with the mode word only.** Take only the **first
   whitespace-delimited token** of the arguments as the mode word (`plan` |
   `plan-only` | `status`; empty → `status`) and run:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <mode-word>
   ```

   The raw arguments were: `$ARGUMENTS`

2. **Report the resulting mode verbatim** (the script's confirmation lines).
   `UNSET` is a fully functional state (defaults to `plan`) — report it as
   such; do **not** ask the user to pick a mode.

If a feature/task request was passed in the SAME prompt as this command (anything
beyond the first mode-word token), it did **not** start the plan harness. After
reporting the mode, enter the harness yourself:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"
```

Read its stdout first (it carries the mode-aware instructions). **If that stdout contains
`CONTEXT: ASK`**, do **not** invoke the plan skill yet — the user decides first: follow the
printed directive and ask via AskUserQuestion; on "Hand off & plan in a fresh session"
invoke `Skill(skill="mentor:handoff-note")` and STOP, on "Proceed anyway" run the printed bypass
script, re-run `begin-plan.sh`, then continue. If it contains `CONTEXT: HANDOFF` (armed,
critically large), surface it and keep the plan lean; if `CONTEXT: WARN`, mention it and
continue. Then invoke `Skill(skill="mentor:planning", args="<the co-submitted request>")`.
