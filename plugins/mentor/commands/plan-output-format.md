---
description: get or set the persisted per-repo mentor PLAN OUTPUT FORMAT (md | html). Markdown plans are Mermaid-first; HTML plans are the bespoke styled document.
argument-hint: "[md | html | status]"
allowed-tools: [Bash, AskUserQuestion, Read]
---

# mentor — plan output format

The plan output format persists per repo in `~/.claude/mentor/<repo>-<hash>/config.json`
(the `format` key, alongside `mode` and `orchestrator`):

- **html** — the bespoke, self-contained **styled HTML** plan document (the original
  deliverable). Rich CSS theme, live `<iframe>` before/after mockups, purposeful
  animation, in-place self-refresh; auto-opens for review in a browser / VSCode tab.
- **md** — a self-contained **Markdown** plan. Visualization is **Mermaid-first**
  (fenced ```` ```mermaid ````) with **ASCII diagrams**, **GFM tables**, and **GFM
  alerts** (`> [!NOTE]`). The `.md` file *is* its own canonical source (footer markers
  at end-of-file, dispatch annotations inline — no embedded `plan-source` block).
  Portable: renders richly on GitHub/GitLab and in any Mermaid-capable Markdown viewer.

> **No baked-in default.** When the format is unset for a repo, `/mentor:plan` asks once
> (Markdown / HTML) and persists your choice here. An env override
> `MENTOR_PLAN_FORMAT=md|html` (set under `env` in `~/.claude/settings.json`) takes
> precedence over the persisted value but is not written by this command.

Ownership rule: `set-plan-output-format.sh` owns the `.format` key (it merges,
preserving `.mode` / `.orchestrator`). The config file is the single source of truth.

Do these in order:

1. **Run the format script with the format word only.** Take only the **first
   whitespace-delimited token** of the arguments as the format word (`md` | `html` |
   `status`; empty → `status`) and run:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-plan-output-format.sh" <format-word>
   ```

   The raw arguments were: `$ARGUMENTS`

2. **If the output contains the token `UNSET`** (status request on a repo with no
   persisted format): ask the user which format to persist via `AskUserQuestion` — one
   question, two options (`Markdown` / `HTML`), using the one-line descriptions above —
   then run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-plan-output-format.sh" <choice>`
   (map **Markdown → `md`**, **HTML → `html`**).

3. **Report the resulting format verbatim** (the script's confirmation lines, including
   any active `env override` line).

If a feature/task request (or `/mentor:plan …`) was passed in the SAME prompt as this
command — i.e. anything beyond the first format-word token — it did **not** start the
plan harness (only the leading command runs). After reporting the format, enter the
harness yourself:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"
```

Read its stdout first — it carries the resolved `FORMAT:` line and any mode/format
ask-to-persist prompts — then invoke
`Skill(skill="mentor:mentor-plan", args="<the co-submitted request>")`.
