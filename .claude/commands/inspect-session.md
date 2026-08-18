---
description: Skim a session transcript from any Claude config dir/project, line-numbered, without a hand-rolled python heredoc
argument-hint: [project-path-fragment] [session-id|latest] [--profile <config-dir>] [--range START-END]
allowed-tools: [Bash]
---

# Inspect Session

Condense a session transcript — from this project or a different Claude profile/project
entirely — into a line-numbered narrative of user asks and assistant text, skipping
tool_result/thinking/local-command-caveat noise. Arguments provided: $ARGUMENTS

- `$1` = a fragment of the target project's path (matched against directory names under
  `<config-dir>/projects/`). Required.
- `$2` = a session id, a full transcript path, or `latest` (newest `*.jsonl` by mtime in
  that project dir). Defaults to `latest` if omitted.
- `--profile <config-dir>` = use a different Claude config dir instead of the default
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` (e.g. `~/.claude-ntb` for another account/profile).
- `--range START-END` = after the overview, dump full detail (text + tool_use names/inputs)
  for just that line window.

## Steps

1. **Resolve the config dir.** `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, or the dir passed via
   `--profile`.
2. **Resolve the project dir.** Match `$1` against directory names under
   `<config-dir>/projects/` (the hashed-cwd naming, `/` and `.` -> `-`).
3. **Resolve the session.** `latest`/omitted -> newest `*.jsonl` by mtime in that project
   dir; otherwise treat `$2` as a session id (find `<id>.jsonl`) or a literal path.
4. **Stream, never load whole.** Pipe the JSONL through `jq -c`/python line by line,
   printing only user text turns and assistant text blocks (never `thinking` or raw
   `tool_result` payloads), each tagged with its physical line number.
5. **Optional detail dump.** If `--range START-END` was given, re-stream just that line
   window with full text + `tool_use` name/input detail included.

## Output

A condensed, line-numbered narrative of the session (user asks + assistant text), or — with
`--range` — the same narrative plus full tool-call detail for the requested window.
