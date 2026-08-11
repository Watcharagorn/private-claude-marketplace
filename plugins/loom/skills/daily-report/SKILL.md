---
name: daily-report
description: Compose and EMAIL a summary of one day of loom's daily automation — what harvest folded per project, which sessions learn disposed per plugin, what got published, and any failures — to the notify.email configured in $cfg/loom/automation/config.json, delivered through the Gmail MCP connector. The daily runner fires "/loom:daily-report --headless" itself at the end of every real run once notify.email is set (re-run /loom:automate or edit config.json to set it). Invoke manually to test the notification path or re-send a day's report — use when the user says "/loom:daily-report", "email me the loom daily summary", "send/test the automation report email", "set up or check the loom email report", or asks what the daily run changed and wants it mailed. --date YYYY-MM-DD reports a past day (default today); --dry-run composes and prints but never sends; --headless never prompts and self-reports failures into the runner's fail-notify marker.
version: 0.1.0
---

# daily-report — email the day's automation summary

One email per real daily run: a short, human summary of what `loom:automate`'s scheduled fire
actually changed — harvest folds per project, learn sessions disposed per plugin, publishes, and
any failures — sent to the `notify.email` address the user configured. The runner fires this skill
**best-effort**: a failure here must never change the day's verdict, which is why headless failures
go into a separate `fail-notify-<date>` marker (Step 4) instead of the day's own fail marker.

`cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` and `auto="$cfg/loom/automation"` throughout.

## Step 1 — resolve config and mode

Parse `$ARGUMENTS`: `--headless` (never prompt, concise log-friendly output — the runner's mode),
`--date YYYY-MM-DD` (report that day; default today — the runner always reports today, so `--date`
is a manual-use affordance), `--dry-run` (compose and print, never send).

```bash
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
auto="$cfg/loom/automation"
email=$(jq -r '.notify.email // empty' "$auto/config.json" 2>/dev/null)
mkt=$(jq -r '.marketplaceRepo // empty' "$auto/config.json" 2>/dev/null)
```

- **No `config.json`** → no automation install here. Say so (point at `/loom:automate`) and stop
  cleanly — nothing to report is not a failure, so no marker is written.
- **`email` empty** → headless: print `daily-report: no notify.email configured — skipping` and
  stop cleanly. Interactive: explain how to set it — add `"notify": {"email": "..."}` to
  `$auto/config.json` (read fresh at every fire, effective next run, no re-install) or re-run
  `/loom:automate` — and offer to write it now if the user gives an address.

## Step 2 — gather the day's evidence

Every source below may be absent — tolerate each and report from what exists. All state is under
`$auto`; the commit history lives in the marketplace repo (`$mkt`).

- **`logs/daily-<date>.log`** — the orchestrator log, the backbone of the report. Harvest fires
  write their claude output inline here (between each `run: cd <project> …` line and its
  `done (exit 0)` / `FAILED` line); the learn phase contributes round lines
  (`learn <plugin>: round done — N disposed, …`), batch summaries, and publish lines. Absent →
  no run happened that day: headless prints `daily-report: no run on <date> — nothing to report`
  and stops cleanly; interactive just says so.
- **`logs/daily-<date>-slot-N.log`** — per-slot learn output. Read only to explain a specific
  failure the orchestrator log names; never summarize them wholesale.
- **`stamps/fail-<date>`** — the day's verdict: present = the day failed (each line names a failed
  fire), absent = success. Ignore `fail-notify-<date>` when judging the day — those are prior
  *email* failures, deliberately excluded from the verdict. Don't consult `stamps/last-ok` for
  today: the runner fires this skill *before* stamping, so today's stamp legitimately isn't there
  yet.
- **Marketplace commits** — what learn actually landed:
  `git -C "$mkt" log --since "<date> 00:00" --until "<date> 23:59:59" --format='%h %s'` (current
  branch). Learn commits (`learn(<plugin>): …`), publish bumps (name the released versions), and
  a `--stat` when magnitude helps the story. Skip when `$mkt` is empty/missing.

Derive counts (sessions disposed, projects harvested, publishes) from the log's own round/batch
lines — never re-run discovery to recount; the report mirrors the run, it doesn't audit it.

## Step 3 — compose

Read **[`references/email-format.md`](references/email-format.md)** for the worked templates, then
compose within its rules. The rules exist because Gmail renders plain text in a **proportional**
font (Arial/Roboto) and its phone app truncates subjects at ~40 characters and wraps lines hard —
column alignment and deep indentation do not survive delivery:

- **Subject** — `Loom <OK|FAILED> <MM-DD> — <payload>`, ≤ ~42 chars so the whole thing survives the
  phone cut, verdict by character 6. OK payload: `<s> learned, <p> harvested` (collapse to
  `quiet day` when both are zero; `<p> harvested, learn skipped` on a harvest-only day). FAILED
  payload: name the failure (`harvest hit ceiling`), never the counts — the failure is why the
  email is worth opening. The full ISO date goes in the body's first line, where search finds it.
- **Body layout** — hierarchy is carried by line-leading markers and blank lines, **never by
  indentation** (2 spaces only for wrapped continuations, which may lose them). Hard-wrap at 62
  columns. One ALL-CAPS heading level (`PLUGINS IMPROVED`, `PROJECTS HARVESTED`, `FAILURES`) with
  a blank line before and none after. `- ` is the only bullet. One fact per line — never join two
  items with a semicolon. Commands and paths sit alone on a bare line with no trailing punctuation,
  so they copy clean and never wrap mid-path.
- **First line = Gmail's preview snippet** (~90 chars in the list view) — spend it on what the
  subject couldn't fit (which plugins, which versions), not on restating the subject.
- **Section order** — OK day: preview line → PLUGINS IMPROVED (per plugin: sessions learned, one
  line per commit from the commit subjects, published version) → PROJECTS HARVESTED (per project:
  what folded; a project that found nothing still gets its line; a skipped phase gets one line with
  its fix command) → `Full log:` + path. **Failed day: FAILURES comes first** — its lines from
  `fail-<date>`, the relevant slot-log names spelled out in full — then WHAT STILL LANDED (work
  that landed is never hidden by the failure), the retry command on its own line, then the footer.
- **Usage context per created/changed artifact** — every artifact the day created or changed gets
  a brief "reach for it when / how", so the user learns what they now own without opening the
  repo: a new command → its slash invocation plus the situation it serves; a new or updated
  skill → the situation that triggers it (it fires from its description — nothing to run); a
  hook → the event it now runs on; a CLAUDE.md/memory note → "loads automatically, nothing to
  run". Keep each to ≤2 wrapped lines. Source it from the harvest report section in the log; if
  the log lacks an artifact's purpose, read just that artifact's frontmatter description — never
  the whole repo. Behavior tweaks to an existing plugin skill just say what changed (the skill's
  name already tells when it applies); a brand-new capability inside a plugin gets the same
  when/how treatment.
- **Inference is labeled** — when the log shows a known pattern (e.g. repeated watchdog kills at
  one target → ceiling too tight), one advice line is allowed but must be prefixed `Likely cause:`
  so it is visibly not a fact.

`--dry-run` → print subject + body and stop here (no send, no marker, headless or not).

## Step 4 — send via the Gmail MCP

Find the Gmail send tool with ToolSearch (query `+gmail send`; connector tools are account-level —
present when the Gmail connector is enabled for this config dir's claude.ai account). Then send the
composed email to `$email` and confirm with whatever id the tool returns. Send as **plain text** —
pass the body to whichever parameter the tool documents as the plain/text body, never an HTML body
(HTML collapses every blank line and space, turning the report into one run-on paragraph). If the
tool only accepts HTML, wrap the body in
`<pre style="font:14px/1.6 Arial,sans-serif;white-space:pre-wrap">…</pre>` so the line structure
survives.

**No Gmail tool available, or the send itself fails:**

- **Headless** — self-report so the runner and `--status` can see it, then stop; the failure is
  the email's alone, never the day's:

  ```bash
  auto="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/loom/automation"
  echo "daily-report: <one-line reason — e.g. Gmail MCP unavailable>" \
    >> "$auto/stamps/fail-notify-$(date +%Y-%m-%d)"
  ```

  Print the same reason plus the fix: enable the **Gmail connector** (claude.ai → Settings →
  Connectors) for the account this config dir is logged in as, verify with `claude mcp list`.
- **Interactive** — same explanation and fix, and print the composed subject + body inline so the
  content isn't lost; no marker (the user is watching, nothing needs to surface it later).

## Done when

- Config + mode resolved; unset `notify.email` and no-run days ended as clean skips (message, no
  send, no marker) — a marker was written only for a genuine headless compose-or-send failure.
- The report was built from the day's log, fail marker, and marketplace commits — counts taken
  from the log's own lines, `fail-notify-*` never treated as the day's verdict, today's missing
  `last-ok` never read as failure.
- `--dry-run` printed and sent nothing; otherwise the email went to `notify.email` via the Gmail
  MCP, or the failure was self-reported (headless: `fail-notify-<date>`; interactive: explained
  with the composed email shown).
- Zero hardcoded `$HOME/.claude` — `$cfg` throughout.
