---
description: Set up, inspect, or remove the DAILY scheduled headless run that auto-harvests configured projects and auto-learns tracked plugins (launchd/cron → claude -p --headless); setup is idempotent
argument-hint: [--status | --stop]
allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
---

# loom — daily automation

Follow the `automate` skill end to end. It manages a once-a-day scheduled job that runs
`/loom:harvest --headless` over a configured list of projects and `/loom:learn <plugin> --headless`
over every tracked plugin, fully unattended.

- **empty** — set up (or refresh) the schedule: pick projects + a time, install the runner and the
  launchd plist / cron entry. Idempotent — re-run to change targets.
- **`--status`** — show the schedule, config, last-run stamp, and newest log tail.
- **`--stop`** — uninstall the schedule; config, logs, and ledgers are kept.

Arguments provided: $ARGUMENTS
