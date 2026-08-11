# daily-report email format — worked templates

The canonical shapes for the report email. SKILL.md Step 3 carries the rules; these are the rules
applied, reviewed and approved as the copy standard. Substitute real values — never invent counts
or commit lines (they come from the day's log and `git log`). Widest line in every template is
under 62 columns.

Why these look the way they do: Gmail renders `text/plain` in a proportional font (Arial on web,
Roboto on the phone), truncates subjects around 40 characters on the phone, and shows ~90 body
characters as the list-view preview snippet. So: markers instead of indentation, one ALL-CAPS
heading level, 62-column wrap, subject payload up front, first line spending the preview snippet
on what the subject couldn't fit.

## Good day with changes (the common case)

Subject: `Loom OK 08-11 — 4 learned, 3 harvested`

```
Everything ran clean and 2026-08-11 is stamped. Published
mentor v2.24.0 and tmux-design v1.9.1; folded 3 artifacts
across 2 of 3 projects.

PLUGINS IMPROVED

mentor — 3 sessions learned, published v2.24.0
- resuming: stamp resolved notes only after the
  plan-complete check
- planning: harden Step-4 dispatch annotations against
  empty plans

tmux-design — 1 session learned, published v1.9.1
- console: verify pane shapes before applying a layout

PROJECTS HARVESTED

cloud-resoruce-governance — folded 2 artifacts
- /drift-check — new command. Run it before a terraform
  apply to list resources whose live state drifted from
  code. Use: /drift-check [account]
- resource-tagging rules — new CLAUDE.md note. Loads
  automatically in that repo, so the tagging policy is
  applied without being asked. Nothing to run.

system-infra — folded 1 artifact
- deploy-verify skill — updated. Now covers rollback
  steps. Triggers as before when you ask to verify a
  deploy.

Full log:
~/.claude-ntb/loom/automation/logs/daily-2026-08-11.log
```

Every created/changed artifact carries its "reach for it when / how" line: a command shows its
slash invocation and the situation it serves, a skill names what triggers it, a CLAUDE.md note
says it loads automatically. ≤2 wrapped lines each — the email teaches what the user now owns
without them opening the repo.

## Failed day (FAILURES first)

Subject: `Loom FAILED 08-10 — harvest hit ceiling`

```
2026-08-10 FAILED — harvest hit the 2-hour ceiling in
all 3 projects. Nothing was lost: the day is not
stamped, so tomorrow's fire retries everything that
didn't finish.

FAILURES

- Harvest was watchdog-killed at the 7200s ceiling in all
  3 projects (cloud-resoruce-governance, system-infra,
  himmes; exit 143). Work up to the kill is kept; the
  next fire resumes from the watermark.
- 2 learn fires for mentor exited 1. Slot logs:
  daily-2026-08-10-slot-2.log, daily-2026-08-10-slot-3.log
- Likely cause: repeated kills at the same target usually
  mean the 2h ceiling is too tight for a first-time
  backlog. Raise "maxRunSecs" to widen it (next fire):
  ~/.claude-ntb/loom/automation/config.json

WHAT STILL LANDED

mentor — 1 session learned and merged
- resuming: re-check the skip bar when resuming mid-plan
- 2 more sessions were claimed, then requeued when their
  workers were killed; they retry on the next fire.

To retry now:
sh ~/.claude-ntb/loom/automation/bin/daily-run.sh

Full log:
~/.claude-ntb/loom/automation/logs/daily-2026-08-10.log
```

Slot-log names are always spelled out in full — `-slot-3.log` is not a filename anyone can grep.
The `Likely cause:` line is the only inference allowed, and only under that label.

## Quiet day (everything ran, nothing changed)

Subject: `Loom OK 08-12 — quiet day`

```
2026-08-12 ran clean and is stamped — nothing changed.

All 3 projects were harvested with nothing new to fold,
and no unanalyzed sessions were waiting for mentor or
tmux-design.

Full log:
~/.claude-ntb/loom/automation/logs/daily-2026-08-12.log
```

No sections on a quiet day; never write "0 learned, 0 harvested" (zeros read as failure).

## Harvest-only day (learn skipped)

Subject: `Loom OK 08-13 — 2 harvested, learn skipped`

Body = the good-day shape minus PLUGINS IMPROVED, plus one line stating the skip with its fix:

```
Learn phase: skipped — no plugins tracked for this
marketplace. /loom:track <plugin> adds one.
```

A vanished project directory is reported with its remedy, and the subject counts only projects
actually harvested.
