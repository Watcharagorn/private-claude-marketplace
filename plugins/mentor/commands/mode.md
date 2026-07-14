---
description: get or set the persisted per-repo mentor WORKING MODE (plan | plan-only)
argument-hint: "[plan | plan-only | status]"
allowed-tools: [Bash, AskUserQuestion, Read]
---

# mentor — repo mode

The mentor working mode persists per repo in `~/.claude/mentor/<repo>-<hash>/config.json`:

- **plan** — default behavior: `/mentor:plan` plans, then executes on approval. (It does
  **not** force planning — it names the default flow.)
- **plan-only** — plans are the deliverable: `/mentor:plan` runs the full harness, but after
  approval execution **soft-stops** (no implementation, no dispatch).

Do these in order:

1. **Run the mode script with the mode word only.** Take only the **first
   whitespace-delimited token** of the arguments as the mode word (`plan` |
   `plan-only` | `status`; empty → `status`) and run:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <mode-word>
   ```

   The raw arguments were: `$ARGUMENTS`

2. **If the output contains the token `UNSET`** (status request on a repo with no persisted
   mode): ask the user which mode to persist via `AskUserQuestion` — one question, two
   options (`plan` / `plan-only`), using the one-line descriptions above — then run
   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <choice>`.

3. **Report the resulting mode verbatim** (the script's confirmation lines).

If a feature/task request was passed in the SAME prompt as this command (anything
beyond the first mode-word token), it did **not** start the plan harness. After
reporting the mode, enter the harness yourself:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"
```

Read its stdout first (it carries the mode-aware instructions), then invoke
`Skill(skill="mentor:plan", args="<the co-submitted request>")`.
