---
name: automate
description: Set up (or manage) a DAILY scheduled headless run that harvests configured projects and learns tracked plugins automatically — launchd on macOS, cron on Linux, driving "claude -p '/loom:harvest --headless'" per project and "/loom:learn <plugin> --headless" per tracked plugin. Use when the user says "automate loom", "schedule daily harvest/learn", "run harvest every day", "set up the loom daily job", "/loom:automate", or asks how to make harvesting/learning happen without them. Also handles "--status" (show schedule + last run) and "--stop" (uninstall the schedule, keep config). Setup is idempotent — re-run anytime to change projects or the schedule time.
version: 0.1.0
---

# automate — daily headless harvest + learn

Install a once-a-day scheduled job that runs `loom:harvest` over a **configured list of projects** and
`loom:learn` over every **tracked plugin** (from `loom:track`'s registry), fully unattended. Both
skills' `--headless` flags guarantee zero prompts; their ledgers + watermarks make every run
incremental and idempotent.

**Say the tradeoff up front, before installing anything:** the scheduled runs use
`--permission-mode bypassPermissions` — Claude edits files and (for `learn`) commits + pushes the
marketplace repo without asking. The guardrails are real but post-hoc: harvest folds only into
**project scope**, so `git diff` in each project reviews what landed; learn implements only
expert-review-approved items and publishes through `publish-plugin`'s validated flow. If the user is
not comfortable with that, stop here and suggest running `/loom:harvest --review` manually instead.

`cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` throughout. All state lives under `$cfg/loom/automation/`:

```
$cfg/loom/automation/
├── config.json          # targets + schedule (schema below)
├── bin/daily-run.sh     # the installed runner (copied from this plugin)
├── logs/daily-<date>.log
├── run.lock/            # transient: held while a run is in flight (rmdir if stale)
└── stamps/
    ├── last-ok          # once-per-day SUCCESS stamp
    └── fail-<date>      # per-day failure markers (auto-pruned after 30 days)
```

## Step 1 — Resolve mode

- **no argument** → **setup / refresh** (first run and re-runs are the same flow — idempotent),
- **`--status`** → report and stop,
- **`--stop`** → uninstall the schedule and stop.

## Step 2 — Setup / refresh

1. **Gather targets.** Ask (one `AskUserQuestion` batch, skipping anything already in an existing
   `config.json` unless the user wants changes):
   - **Projects to harvest** — absolute directory paths. Offer the current project root as a default
     option; the user can add more via "Other".
   - **Schedule time** — hour of day (default 09:00 local).
   - **Marketplace repo** for the learn phase — default to the cwd's git root when it contains
     `.claude-plugin/marketplace.json`, otherwise ask for the path (learn must run with cwd = its
     marketplace repo). If the user has no marketplace repo, the learn phase is simply skipped —
     that's fine, record `marketplaceRepo` as absent.

   Learn's plugin list is **not** asked here — the runner reads `$cfg/loom/learning/config.json`
   (`loom:track`'s registry) live at run time, so `/loom:track <plugin>` additions are picked up with
   no re-setup. If nothing is tracked yet, note that the learn phase will no-op and point at
   `/loom:track`.

2. **Write `config.json`** under §E merge-json discipline (timestamped backup when it exists →
   `jq` → `jq empty` validate → restore on invalid; the chassis-resolution glob from `loom`'s other
   skills finds `session-plugin-common.md` if you need the recipe verbatim):

   ```json
   { "schemaVersion": 1,
     "projects": [ { "root": "/abs/path/to/project", "addedAt": "<iso8601>" } ],
     "schedule": { "hour": 9, "minute": 0 },
     "permissionMode": "bypassPermissions",
     "marketplaceRepo": "/abs/path/to/marketplace-repo" }
   ```

   The runner reads `projects`, `permissionMode`, and `marketplaceRepo` at every fire; `schedule` is
   read only by THIS skill when building the plist/crontab — editing it in the file does nothing
   until `/loom:automate` is re-run. Learn's plugin list is never stored here (it comes from track's
   registry, live).

3. **Install the runner copy.** Copy the bundled script to config-dir state and make it executable —
   the scheduler must never point into the plugin cache, which moves on plugin updates:

   ```bash
   mkdir -p "$cfg/loom/automation/bin" "$cfg/loom/automation/logs" "$cfg/loom/automation/stamps"
   src="${CLAUDE_PLUGIN_ROOT:-}"
   [ -f "$src/scripts/automate/daily-run.sh" ] \
     || src="$(find "$cfg/plugins" -path '*loom*/scripts/automate/daily-run.sh' 2>/dev/null | head -1 \
               | sed 's|/scripts/automate/daily-run.sh$||')"   # matches both cache (loom/<ver>/…) and marketplace-clone layouts
   cp "$src/scripts/automate/daily-run.sh" "$cfg/loom/automation/bin/daily-run.sh"
   chmod +x "$cfg/loom/automation/bin/daily-run.sh"
   ```

   Re-running setup refreshes this copy, so plugin updates propagate on the next `/loom:automate`.

4. **Install the schedule** (OS from `uname -s`):

   launchd and cron hand the job a **bare environment** — no user PATH, no `CLAUDE_CONFIG_DIR`. The
   installer must bake both in, or the runner finds neither `jq` nor `claude` (and, with a custom
   config dir, reads the wrong state) while still looking "installed". Resolve them now:

   ```bash
   command -v claude >/dev/null || { echo "ABORT: claude not on PATH — cannot bake a valid PATH into the schedule"; }
   claude_dir="$(dirname "$(command -v claude)")"   # e.g. /Users/you/.local/bin — NEVER '.' (abort above)
   runner="$cfg/loom/automation/bin/daily-run.sh"   # substitute the REAL absolute path below
   ```

   - **Darwin** — write `~/Library/LaunchAgents/com.loom.daily.plist` (overwrite is the idempotency:
     one label, one file), substituting every `<REPLACED: …>` token with the resolved absolute value
     (launchd expands neither `~` nor env vars), then reload it:

     ```xml
     <?xml version="1.0" encoding="UTF-8"?>
     <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
     <plist version="1.0"><dict>
       <key>Label</key><string>com.loom.daily</string>
       <key>ProgramArguments</key><array>
         <string>/bin/sh</string><string><REPLACED: absolute $runner path></string>
       </array>
       <key>EnvironmentVariables</key><dict>
         <key>PATH</key><string><REPLACED: $claude_dir>:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
         <key>CLAUDE_CONFIG_DIR</key><string><REPLACED: absolute $cfg></string>
       </dict>
       <key>StandardOutPath</key><string><REPLACED: $cfg>/loom/automation/logs/launchd.log</string>
       <key>StandardErrorPath</key><string><REPLACED: $cfg>/loom/automation/logs/launchd.log</string>
       <key>StartCalendarInterval</key><dict>
         <key>Hour</key><integer><REPLACED: hour></integer><key>Minute</key><integer><REPLACED: minute></integer>
       </dict>
     </dict></plist>
     ```

     ```bash
     launchctl unload ~/Library/LaunchAgents/com.loom.daily.plist 2>/dev/null
     launchctl load ~/Library/LaunchAgents/com.loom.daily.plist
     ```

   - **Linux** — a crontab block between markers, stripped-then-appended so re-runs replace it
     (the same idempotency-marker pattern as ntbx-infra's bootstrap), carrying the same environment:

     ```bash
     ( crontab -l 2>/dev/null | awk '/# >>> loom-automate >>>/{skip=1} !skip; /# <<< loom-automate <<</{skip=0}' ; \
       printf '# >>> loom-automate >>>\n%d %d * * * PATH=%s:/usr/local/bin:/usr/bin:/bin CLAUDE_CONFIG_DIR=%s /bin/sh %s\n# <<< loom-automate <<<\n' \
         "$MINUTE" "$HOUR" "$claude_dir" "$cfg" "$runner" ) | crontab -
     ```

5. **Confirm + first-run offer.** Print what was installed (schedule time, projects, tracked plugins
   found, marketplace repo, log/stamp paths) and offer to fire the runner once now in the background
   (`nohup sh "$cfg/loom/automation/bin/daily-run.sh" &`) so the user can inspect
   `logs/daily-<today>.log` instead of waiting for tomorrow.

## Step 3 — `--status`

Report, without changing anything: whether `config.json` exists (print projects + schedule +
marketplace repo), whether the schedule is live (`launchctl list | grep com.loom.daily` on macOS;
`crontab -l | grep loom-automate` on Linux), the tracked-plugin list the learn phase would use, the
stamp date, and the tail of the newest log file.

## Step 4 — `--stop`

Uninstall the schedule but keep `config.json` (so a later setup restores the same targets):

- macOS: `launchctl unload ~/Library/LaunchAgents/com.loom.daily.plist 2>/dev/null` then delete the
  plist;
- Linux: strip the marker block from the crontab (the awk filter above, without the append).

Say explicitly that config, logs, stamps, and all harvest/learn ledgers were left untouched.

## Edge cases

- **`claude`/`jq` not found at fire time** — the installer bakes PATH into the plist/crontab from
  `command -v claude` at setup; the runner refuses to start (exit 1, logged) rather than half-run.
  Fix the binary's location in your shell, then re-run `/loom:automate` to refresh the baked PATH
  (never hand-edit the runner copy — setup re-copies it).
- **Machine asleep at fire time** — launchd coalesces a missed `StartCalendarInterval` into one fire
  on wake; cron simply misses. The once-per-day stamp makes any extra fires no-ops, and a missed day
  self-heals on the next fire (watermarks mean nothing is lost, just delayed).
- **A run fails** — the runner stamps success only when every invocation succeeded. The daily
  schedule fires once, so a failed day waits for tomorrow's fire — or fire the runner manually
  (`sh $cfg/loom/automation/bin/daily-run.sh`) to retry today; the stamp guard only blocks re-runs
  after a *success*.
- **A target project was deleted** — the runner logs "skip harvest" and continues; remove it from
  `config.json` on the next setup pass.
- **Nothing tracked** — the learn phase no-ops with a log line; `/loom:track <plugin>` fixes it with
  no re-setup.

## Done when

- The tradeoff statement was made **before** any install; the mode resolved from `$ARGUMENTS`.
- Setup: `config.json` written (validated, backed up when pre-existing), the runner **copied** to
  `$cfg/loom/automation/bin/` (never scheduled from the plugin cache), the schedule installed
  idempotently (one plist label / one crontab marker block), and the confirmation + first-run offer
  printed.
- `--status` reported schedule liveness, config, stamp, and log tail without writing anything.
- `--stop` removed only the schedule and said what was kept.
- Zero hardcoded `$HOME/.claude` — `$cfg` throughout.
