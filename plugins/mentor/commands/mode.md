---
description: get or set the persisted per-repo mentor WORKING MODE (plan | plan-only). For session-wide orchestration use /mentor:orchestrator (an orthogonal toggle).
argument-hint: "[plan | plan-only | status]"
allowed-tools: [Bash, AskUserQuestion, Read]
---

# mentor — repo mode

The mentor working mode persists per repo in `~/.claude/mentor/<repo>-<hash>/config.json`:

- **plan** — default behavior: `/mentor:plan` plans, then executes on approval. (It does
  **not** force planning — it names the default flow.)
- **plan-only** — plans are the deliverable: `/mentor:plan` runs the full harness, but after
  approval execution **soft-stops** (no implementation, no dispatch).

> **`commander` is no longer a mode.** Always-orchestrate is now the orthogonal
> **`orchestrator` toggle** — `/mentor:orchestrator on|off` (settable per-repo or globally).
> A `commander` arg here is accepted but redirected (it enables orchestrator + sets mode=plan).

Ownership rule: `set-mode.sh` owns the `.mode` key (it merges, preserving `.orchestrator`);
`set-orchestrator.sh` owns `.orchestrator`. The config file is the single source of truth.

Do these in order:

1. **Run the mode script with the mode word only.** The arguments may carry more than the mode
   (a co-submitted feature/task request — see the routing note below). Take only the **first
   whitespace-delimited token** of the arguments as the mode word (`plan` | `plan-only` |
   `status`; empty → `status`) and run:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <mode-word>
   ```

   The raw arguments were: `$ARGUMENTS`

2. **If the output contains the token `UNSET`** (status request on a repo with no persisted
   mode): ask the user which mode to persist via `AskUserQuestion` — one question, two
   options (`plan` / `plan-only`), using the one-line descriptions above — then run
   `bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <choice>`.

3. **Report the resulting mode verbatim** (the script's confirmation lines, including the
   read-only `orchestrator:` line). To change orchestration, point the user at
   `/mentor:orchestrator on|off`.

If a feature/task request (or `/mentor:plan …`) was passed in the SAME prompt as this command —
i.e. anything beyond the first mode-word token — it did **not** start the plan harness (only the
leading command runs). After reporting the mode, enter the harness yourself:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"
```

Read its stdout first — it carries the mode-aware instructions (plan-only soft-stop notice /
ask-to-persist prompt) — then invoke
`Skill(skill="mentor:mentor-plan", args="<the co-submitted request>")`.
