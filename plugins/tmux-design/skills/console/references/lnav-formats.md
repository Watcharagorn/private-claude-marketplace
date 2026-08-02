# lnav formats for log panes

A pane running `lnav` on a log with no installed format shows the same wall of raw lines a `tail`
pane would — lnav's coloring, level filtering and SQL all come from the format file. Writing one
is what turns a log pane into a designed surface.

## 1. Write the format file

`<name>.lnav.json` in the repo, schema `https://lnav.org/schemas/format-v1.schema.json`:

```json
{
  "$schema": "https://lnav.org/schemas/format-v1.schema.json",
  "myapp_log": {
    "title": "MyApp log",
    "regex": {
      "labeled": {
        "pattern": "^(?<timestamp>\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2})\\s+(?<level>[A-Z]{1,8}): (?<component>\\w+) (?<body>.*)$"
      },
      "plain": {
        "pattern": "^(?<timestamp>\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2})\\s+(?<body>(?![A-Z]{1,8}: ).*)$"
      }
    },
    "level-field": "level",
    "level": { "error": "ERROR|FATAL", "warning": "WARN(ING)?", "info": "INFO" },
    "value": {
      "component": { "kind": "string", "identifier": true },
      "body": { "kind": "string" }
    },
    "sample": [
      { "line": "2026-07-12 19:55:03 ERROR: fetcher upstream timed out after 30s" },
      { "line": "2026-07-12 19:55:04 heartbeat ok" }
    ]
  }
}
```

Key fields:

- `(?<timestamp>…)` is required — lnav orders and filters on it.
- `"identifier": true` on entity-ish values (component, symbol, request id) gives each distinct
  value its own stable color. That's what makes a log pane scannable: you track a color, not a word.
- `level-field` + `level` map drive lnav's error/warning coloring and the `log_level` column.
- `sample` lines are validated at install time — a format whose samples don't match is rejected,
  which is the fastest feedback you get, so include one sample per regex.

## 2. Multiple regexes must be mutually exclusive

lnav does **not** try patterns most-specific-first; it takes the first that matches. If a general
pattern can also match a specific line, the specific pattern's captures stay NULL and you'll be
staring at a format that "installed fine" but parses nothing.

Guard the general pattern with a negative lookahead of the specific one:

```
(?<body>(?![A-Z]{1,8}: ).*)
```

## 3. Install and validate headlessly

```bash
lnav -i <name>.lnav.json                          # installs; backs up the previous version
lnav -n -c ';SELECT component, log_level, count(*) FROM myapp_log GROUP BY 1,2' <logfile>
```

SQL gotchas that cost the most time:

- The queryable table is named after the **format key** (`myapp_log`), not the file.
- Named captures keep their names as columns, but the fallback body column is `log_body`, not
  `body`, unless you captured `body` explicitly.
- A column that comes back all-NULL means the other regex is eating those lines — go back to §2.

## 4. Iterate, then respawn

Edit → `lnav -i` → re-query until fields and levels populate. Then **respawn the lnav pane** — a
running lnav loaded the old format at startup and will not pick up the new one, which is the same
trap as the renderer verify loop:

```bash
tmux respawn-pane -k -t <pane_id> "lnav /abs/path/to/<logfile>"
sleep 3 && tmux capture-pane -e -p -t <pane_id> | head -20
```
