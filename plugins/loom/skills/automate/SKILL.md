---
name: automate
description: Set up (or manage) a DAILY scheduled headless run that harvests configured projects and learns tracked plugins automatically — launchd on macOS, cron on Linux, driving "claude -p '/loom:harvest --headless'" per project and concurrent rounds of "/loom:learn <plugin> --headless --concurrent" per tracked plugin (up to 3 fires at once, each with its own wall-clock watchdog). Each CLAUDE_CONFIG_DIR gets its own fully isolated schedule (per-config launchd label / cron marker; the runner pins sessions + credentials to its own install's config dir) — setting up from one config dir never touches another's. Use when the user says "automate loom", "schedule daily harvest/learn", "run harvest every day", "set up the loom daily job", "/loom:automate", or asks how to make harvesting/learning happen without them. Also handles "--status" (show schedule + last run) and "--stop" (uninstall the schedule, keep config). Setup is idempotent — re-run anytime to change projects or the schedule time.
version: 0.3.0
---

# automate — daily headless harvest + learn

Install a once-a-day scheduled job that runs `loom:harvest` over a **configured list of projects** and
`loom:learn` over every **tracked plugin** (from `loom:track`'s registry), fully unattended. Both
skills' `--headless` flags guarantee zero prompts; their ledgers + watermarks make every run
incremental and idempotent. Learn runs as **concurrent rounds**: each round fires up to `concurrency`
(config, 1–3, default 3) `claude -p "/loom:learn <plugin> --headless --concurrent"` invocations at
once — one per isolated git worktree slot — each claiming and processing exactly one session
(committing its delta inside its own worktree), and the runner keeps firing rounds while the plugin's
backlog remains, up to 24 fires/plugin/day summed across every slot. The orchestrator alone owns
everything shared — merging each round's worktree commits back onto the marketplace repo in claim
order, writing the ledger only after a clean merge, and publishing the whole bundle once the backlog
drains — so a kill still bounds at most one in-flight session per slot, never a whole round or a
finished batch.

**Say the tradeoff up front, before installing anything:** the scheduled runs use
`--permission-mode bypassPermissions` — Claude edits files and (for `learn`) commits + pushes the
marketplace repo without asking. The guardrails are real but post-hoc: harvest folds only into
**project scope**, so `git diff` in each project reviews what landed; learn implements only
expert-review-approved items and publishes through `publish-plugin`'s validated flow. If the user is
not comfortable with that, stop here and suggest running `/loom:harvest --review` manually instead.

`cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` throughout. **Everything this skill installs is scoped to
that one config dir** — schedule label, runner copy, state, and the headless sessions + credentials the
runs use. A machine can hold several installs (e.g. `~/.claude` and `~/.claude-ntb`), one per config
dir, side by side; never inspect, migrate, or remove another config dir's schedule. All state lives
under `$cfg/loom/automation/`:

```
$cfg/loom/automation/
├── config.json          # targets + schedule (schema below)
├── bin/daily-run.sh     # the installed runner (copied from this plugin)
├── logs/
│   ├── daily-<date>.log          # + logs/launchd.log: anything before the runner's own redirect —
│   │                              # shared orchestrator log (harvest, plus round-level learn events)
│   └── daily-<date>-slot-N.log   # one per concurrent learn slot — that slot's own claude output only
├── run.lock/             # transient: held while a run is in flight (self-healing — the runner steals stale locks)
├── worktrees/<plugin>-slot-N/    # one isolated git worktree per concurrent learn slot (N = 1..concurrency);
│                                 # set up once per plugin's daily batch, reset before every round, torn down
│                                 # at the end — carries a `.loom-learn-result.json` sidecar (the worker's
│                                 # analyzed[] entry + outcome) once that slot's claude exits
├── slots/<plugin>-slot-N.{pid,ec}  # per-slot statefiles: POSIX sh has no arrays, so the round loop tracks
│                                   # each backgrounded slot's pid, and — once it exits — its exit code, here
└── stamps/
    ├── last-ok          # once-per-day SUCCESS stamp
    └── fail-<date>      # per-day failure markers (auto-pruned after 30 days)
```

The per-plugin claim lock (`$cfg/loom/learning/<plugin>.json.lock`, `mkdir`-based) and the ledger it
guards (`$cfg/loom/learning/<plugin>.json`) live next to `loom:track`'s registry, not under
`automation/` — every concurrent slot's ledger write is serialized through that lock (Edge cases
below).

## Step 1 — Resolve mode (from `$ARGUMENTS`)

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
   `/loom:track`. The model / effort / ceiling / concurrency knobs aren't asked here either — Step
   2.2 says why.

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

   The runner reads `projects`, `permissionMode`, `marketplaceRepo`, `model`, `effort`,
   `maxRunSecs`, and `concurrency` at every fire; `schedule` is read only by THIS skill when
   building the plist/crontab — editing it in the file does nothing until `/loom:automate` is
   re-run. Learn's plugin list is never stored here (it comes from track's registry, live).

   **Don't ask about `model`, `effort`, `maxRunSecs`, or `concurrency`, and don't write them** —
   they carry defaults that suit an unattended run, and an absent key is what lets a later default
   improvement reach existing installs the next time `/loom:automate` refreshes the runner copy.
   The runner is the source of truth and the table only mirrors it, so when the two disagree read
   `$cfg/loom/automation/bin/daily-run.sh` — the copy that actually fires. (The plugin's
   `scripts/automate/daily-run.sh` is only what the *next* re-install would put there.)

   | key | default | why that default |
   |---|---|---|
   | `model` | `claude-sonnet-5` | Sonnet is materially cheaper than the prior Opus default for a daily unattended job. `maxRunSecs` is deliberately **unchanged** by this switch — cheapening the model is the safe direction (see below), so the ceiling needs no matching cut. |
   | `effort` | `xhigh` | These runs read long transcripts whole and then rewrite plugin sources with nobody watching — a shallow pass produces edits the user unpicks by hand later, which costs more than the run saved. |
   | `maxRunSecs` | `7200` | Per-invocation wall-clock ceiling. Learn does ONE session per invocation per slot (the runner loops rounds), so the ceiling bounds a single session's analyze→implement→commit — a kill costs at most that one in-flight session, never a whole round. |
   | `concurrency` | `3` | Learn slots fired per round — up to this many `/loom:learn <plugin> --headless --concurrent` invocations run at once, one per isolated git worktree, each claiming a different backlog session. Guarded to 1–3. |

   **During setup**, mention them only when the user asks how to make the runs cheaper, faster, or
   more thorough — `--status` reports them unconditionally (Step 3), which is a different job.
   All four take effect on the next fire with no re-install (`schedule` is the exception), and
   `"model": ""` or `"effort": ""` passes no flag at all, falling back to the account default —
   which is also the escape hatch on a CLI too old for these flags, since an unknown option is a
   hard parse error that would kill every invocation. A `maxRunSecs` that isn't a *plain* positive
   integer — leading zeros included, since POSIX arithmetic reads `0700` as octal — is logged and
   replaced with 7200 rather than crashing the fire; a `concurrency` outside 1–3 is likewise logged
   and replaced with 3 rather than crashing the fire. Setting `"concurrency": 1` is the supported
   way to run the concurrent claim/worktree machinery one slot at a time — a staged rollout, not a
   code change — while leaving the key out (or any value in 1–3) takes the machinery at full
   strength.

   Treat model and ceiling as coupled when advising: a slower or harder-thinking model needs a
   *higher* `maxRunSecs`, not the same one. The failure it produces if you forget is a watchdog
   kill of the in-flight session — its work is redone next fire (finished sessions are already
   committed, so nothing else is lost), but repeated kills at the same session mean the ceiling
   never lets one session finish. Cheapening the model without lowering the ceiling is safe;
   raising effort without raising the ceiling is not. The `claude-sonnet-5` default above is
   exactly that safe case — `maxRunSecs` stays `7200`, unchanged from the prior Opus default.

3. **Install the runner copy.** First the in-flight guard: if `$cfg/loom/automation/run.lock`
   exists and is younger than 2× `maxRunSecs` (4 hours at the default — the same staleness
   threshold the runner itself uses to decide a lock is a crash leftover), a headless
   `bypassPermissions` run is live **right now** — replacing its script or (in the next step)
   unloading its job kills a claude mid-write, possibly mid-commit in the marketplace repo. Say
   so, point at `logs/daily-<today>.log`, and proceed only on an explicit go-ahead or once the
   lock ages out.

   ```bash
   lock="$cfg/loom/automation/run.lock"
   [ -d "$lock" ] && age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || date +%s) ))
   # GNU stat first, BSD second — GNU's -f means --file-system and corrupts the arithmetic
   max=$(jq -r '.maxRunSecs // 7200' "$cfg/loom/automation/config.json" 2>/dev/null)
   case "$max" in ''|*[!0-9]*|0*) max=7200 ;; esac   # same guard the runner applies
   # live when age <= 2*max — the runner steals only when age EXCEEDS it, so match that boundary
   # exactly; anything older is a crash leftover the runner would steal on its own
   ```

   Then copy the bundled script to config-dir state and make it executable — the scheduler must
   never point into the plugin cache, which moves on plugin updates:

   ```bash
   mkdir -p "$cfg/loom/automation/bin" "$cfg/loom/automation/logs" "$cfg/loom/automation/stamps"
   src="${CLAUDE_PLUGIN_ROOT:-}"
   [ -f "$src/scripts/automate/daily-run.sh" ] \
     || src="$(find "$cfg/plugins" -path '*loom*/scripts/automate/daily-run.sh' 2>/dev/null -exec ls -t {} + \
               | head -1 | sed 's|/scripts/automate/daily-run.sh$||')"   # cache + marketplace-clone layouts; ls -t picks the NEWEST when several cached versions coexist
   [ -f "$src/scripts/automate/daily-run.sh" ] \
     || { echo "ABORT: cannot locate the bundled daily-run.sh — is the loom plugin installed?"; exit 1; }
   cp "$src/scripts/automate/daily-run.sh" "$cfg/loom/automation/bin/daily-run.sh.new"
   chmod +x "$cfg/loom/automation/bin/daily-run.sh.new"
   mv "$cfg/loom/automation/bin/daily-run.sh.new" "$cfg/loom/automation/bin/daily-run.sh"
   ```

   Temp + `mv`, never `cp` onto the live path: a scheduled run may be executing that file at
   this very moment, and `sh` reads scripts incrementally by offset — an in-place overwrite
   shifts every byte under a running interpreter. `mv` swaps the inode, so running shells finish
   on the old copy.

   Re-running setup refreshes this copy, so plugin updates propagate on the next `/loom:automate`.

4. **Install the schedule** (OS from `uname -s`):

   launchd and cron hand the job a **bare environment** — no user PATH, no `CLAUDE_CONFIG_DIR`.
   The installer must bake PATH in, or the runner finds neither `jq` nor `claude` while still
   looking "installed". Bake `CLAUDE_CONFIG_DIR` in too, even though the current runner derives
   the config dir from its own installed location and exports it itself (pinning sessions and
   credentials to this install no matter how it's fired): for that runner the baked value is a
   harmless no-op, but it is the only guard keeping a STALE runner copy — one installed before
   self-location existed, or refreshed from an older plugin cache — from silently falling back
   to `~/.claude` and running another install's projects with its credentials. Resolve now:

   ```bash
   command -v claude >/dev/null || { echo "ABORT: claude not on PATH — cannot bake a valid PATH into the schedule"; exit 1; }
   claude --help 2>&1 | grep -q -- '--effort' \
     || echo "WARN: this claude predates --effort; the runner passes it every fire and an unknown flag is a hard parse error — set \"effort\": \"\" (and \"model\": \"\" if the model id is also rejected) in config.json, or upgrade the CLI"
   claude_dir="$(dirname "$(command -v claude)")"   # e.g. /Users/you/.local/bin — never '.' (the exit above guarantees it)
   runner="$cfg/loom/automation/bin/daily-run.sh"   # substitute the REAL absolute path below
   HOUR=$(jq -r '.schedule.hour // 9' "$cfg/loom/automation/config.json")
   MINUTE=$(jq -r '.schedule.minute // 0' "$cfg/loom/automation/config.json")
   slug="$(basename "$cfg" | sed 's/^\.*//; s/[^A-Za-z0-9-]/-/g')"   # .claude → claude, .claude-ntb → claude-ntb; use the path as configured — a symlinked cfg keeps its logical name, so the label stays stable
   label="com.loom.daily.$slug"
   ```

   An ABORT anywhere in setup means stop and report to the user — nothing has been installed
   yet. `$HOUR`/`$MINUTE` feed both the plist's `StartCalendarInterval` integers and the crontab
   fields below; left undefined they'd silently schedule midnight.

   The **per-config label** is what keeps installs isolated: each config dir owns exactly one
   schedule under its own name, and re-running setup overwrites only that one. Two config dirs
   with the same basename (e.g. `~/.claude` and `~/work/.claude`) collide on the slug, so guard
   the overwrite with an ownership check — the same runner-path grep the legacy migration uses:

   ```bash
   # Re-derive $slug/$label here — this is a fresh Bash invocation and does not inherit the
   # block above's shell state.
   slug="$(basename "$cfg" | sed 's/^\.*//; s/[^A-Za-z0-9-]/-/g')"
   label="com.loom.daily.$slug"
   plist=~/Library/LaunchAgents/"$label".plist
   if [ -f "$plist" ] && ! grep -qF "$cfg/loom/automation/bin/daily-run.sh" "$plist"; then
     echo "ABORT: $label already belongs to a different config dir — rename one config dir instead of silently stealing its schedule"; exit 1
   fi
   ```

   (Linux equivalent: extract this slug's block with
   `crontab -l | sed -n "/loom-automate:$slug >>>/,/loom-automate:$slug <<</p"` and require it to
   contain this `$cfg`'s runner path before replacing it.)

   - **Darwin** — write `~/Library/LaunchAgents/$label.plist` (overwrite is the idempotency:
     one label per config dir, one file), substituting every `<REPLACED: …>` token with the
     resolved absolute value (launchd expands neither `~` nor env vars), then reload it:

     ```xml
     <?xml version="1.0" encoding="UTF-8"?>
     <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
     <plist version="1.0"><dict>
       <key>Label</key><string><REPLACED: $label></string>
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
     # Re-derive $slug/$label — a fresh Bash invocation, not a continuation of the block above.
     slug="$(basename "$cfg" | sed 's/^\.*//; s/[^A-Za-z0-9-]/-/g')"
     label="com.loom.daily.$slug"
     launchctl unload ~/Library/LaunchAgents/"$label".plist 2>/dev/null
     launchctl load ~/Library/LaunchAgents/"$label".plist
     ```

     **Legacy migration** — releases before per-config labels wrote a shared
     `com.loom.daily.plist`, so a second config dir's setup silently stole the first's schedule.
     If that file exists AND its runner path points into **this** `$cfg`, it's this install's
     pre-isolation schedule — unload and delete it (superseded by `$label`). If it points at a
     different config dir it belongs to that install: leave it untouched and just mention it.

     ```bash
     legacy=~/Library/LaunchAgents/com.loom.daily.plist
     if [ -f "$legacy" ] && grep -qF "$cfg/loom/automation/bin/daily-run.sh" "$legacy"; then
       launchctl unload "$legacy" 2>/dev/null; rm "$legacy"
     fi
     # Pre-isolation setups also left timestamped plist BACKUPS behind (their §E-style backup
     # step). launchd never auto-loads them, but they carry the retired shared label and pollute
     # future label greps — clear them on every setup pass, whichever install they referenced.
     # find, not a bare glob: an unmatched glob is a hard error under zsh.
     find ~/Library/LaunchAgents -maxdepth 1 -name 'com.loom.daily.plist.bak.*' -delete 2>/dev/null
     ```

   - **Linux** — a crontab block between **per-config markers** (`loom-automate:$slug`),
     stripped-then-appended so re-runs replace only this config dir's block (the same
     idempotency-marker pattern as ntbx-infra's bootstrap):

     ```bash
     # Re-derive every value this block needs — a fresh Bash invocation, not a continuation of
     # the shared "Resolve now" block earlier in this step.
     claude_dir="$(dirname "$(command -v claude)")"
     runner="$cfg/loom/automation/bin/daily-run.sh"
     HOUR=$(jq -r '.schedule.hour // 9' "$cfg/loom/automation/config.json")
     MINUTE=$(jq -r '.schedule.minute // 0' "$cfg/loom/automation/config.json")
     slug="$(basename "$cfg" | sed 's/^\.*//; s/[^A-Za-z0-9-]/-/g')"
     ( crontab -l 2>/dev/null | awk -v s="$slug" \
         'index($0, "# >>> loom-automate:" s " >>>"){skip=1} !skip; index($0, "# <<< loom-automate:" s " <<<"){skip=0}' ; \
       printf '# >>> loom-automate:%s >>>\n%d %d * * * PATH=%s:/usr/local/bin:/usr/bin:/bin CLAUDE_CONFIG_DIR=%s /bin/sh %s\n# <<< loom-automate:%s <<<\n' \
         "$slug" "$MINUTE" "$HOUR" "$claude_dir" "$cfg" "$runner" "$slug" ) | crontab -
     ```

     The per-slug awk above **cannot** see the old unsuffixed `# >>> loom-automate >>>` markers
     (its match requires the `:$slug`), so the legacy block needs a dedicated pass — strip it only
     when its command line points into this `$cfg`; one pointing elsewhere is another install's,
     leave it:

     ```bash
     if crontab -l 2>/dev/null | sed -n '/^# >>> loom-automate >>>$/,/^# <<< loom-automate <<<$/p' \
          | grep -qF "$cfg/loom/automation/bin/daily-run.sh"; then
       crontab -l | awk '$0=="# >>> loom-automate >>>"{skip=1} !skip; $0=="# <<< loom-automate <<<"{skip=0}' | crontab -
     fi
     ```

     (The exact-line `$0==` match strips only the unsuffixed block — every `loom-automate:<slug>`
     block survives it.)

5. **Confirm + first-run offer.** Print what was installed (schedule time, projects, tracked plugins
   found, marketplace repo, log/stamp paths, and the model / effort / per-invocation ceiling /
   concurrent-slot count the runs will use — defaults unless `config.json` overrides them). Name
   those four even though Step 2.2 says not to *ask* about them: the user is opting into
   unattended runs on a capable model at high effort, running up to `concurrency` sessions at
   once, and setup is where that gets said out loud rather than left for someone to discover in
   `--status`. Then offer to fire the runner once now in the background
   (`nohup sh "$cfg/loom/automation/bin/daily-run.sh" &`) so the user can inspect
   `logs/daily-<today>.log` instead of waiting for tomorrow.

## Step 3 — `--status`

Report, without changing anything: whether `config.json` exists (print projects + schedule +
marketplace repo, and the effective model / effort / `maxRunSecs` / `concurrency` — printing the
defaults when the keys are absent **or invalid**, applying the same positive-integer (or, for
`concurrency`, 1–3) guard the runner does, because "what will tonight's run actually use" is the
question `--status` answers and echoing a literal `"maxRunSecs": "abc"` answers it wrongly),
whether **this config dir's** schedule is live (compute `$slug`/`$label` from
`$cfg` as in setup, then `launchctl list | awk '{print $3}' | grep -qxF "$label"` on macOS;
`crontab -l | grep -F "loom-automate:$slug >>>"` on Linux — the match must be anchored:
`com.loom.daily.claude` is a strict prefix of `com.loom.daily.claude-ntb`, so a bare substring
grep reports a neighbour install's schedule as this one's), the tracked-plugin list the learn
phase would use, the stamp date, and the tail of the newest log file. Legacy detection, both
OSes: a shared unsuffixed schedule may predate isolation — check
`~/Library/LaunchAgents/com.loom.daily.plist` on macOS, the unsuffixed
`# >>> loom-automate >>>` block on Linux, with the ownership test
(`grep -qF "$cfg/loom/automation/bin/daily-run.sh"`). Pointing into this `$cfg` → report a
pre-isolation schedule the next setup run migrates; pointing elsewhere → another install's, say
so and don't count it as this one's.

## Step 4 — `--stop`

Uninstall **this config dir's** schedule but keep `config.json` (so a later setup restores the
same targets). Run the same in-flight guard as setup first — unloading a job whose run is live
kills a `bypassPermissions` claude mid-write, so surface a fresh `run.lock` and get a go-ahead
before proceeding. Then compute `$label`/`$slug` from `$cfg` as in setup:

- macOS: `launchctl unload ~/Library/LaunchAgents/"$label".plist 2>/dev/null` then delete that
  plist — plus the legacy `com.loom.daily.plist` only when its runner path points into this `$cfg`;
- Linux: strip this slug's marker block from the crontab (the awk filter above, without the
  append) — plus a legacy unsuffixed block via setup's **dedicated legacy pass** (the per-slug
  awk cannot match unsuffixed markers), only when it points into this `$cfg`.

Another config dir's schedule (different slug, or a legacy file pointing elsewhere) is never
touched by `--stop`.

Say explicitly that config, logs, stamps, and all harvest/learn ledgers were left untouched.

## Edge cases

- **Multiple config dirs on one machine** — each install is self-contained: its own label/marker,
  runner copy, state, and (via the runner's self-located `CLAUDE_CONFIG_DIR`) its own sessions and
  credentials. Setting up, checking, or stopping one never alters another. A headless run that
  reports "Not logged in" means *that* config dir has no credentials — log in once under it
  (`CLAUDE_CONFIG_DIR=<cfg> claude /login`); credentials from a different config dir are never
  used, by design.
- **Setup or `--stop` while a run is in flight** — a fresh `$cfg/loom/automation/run.lock`
  (younger than 2× `maxRunSecs`) means a headless `bypassPermissions` run is live; replacing the runner or
  unloading the job kills a claude mid-write. Both flows surface it and wait for a go-ahead; the
  atomic `mv` install additionally keeps an already-running shell safe if the user proceeds.
- **`claude`/`jq` not found at fire time** — the installer bakes PATH into the plist/crontab from
  `command -v claude` at setup; the runner refuses to start (exit 1, logged) rather than half-run.
  Fix the binary's location in your shell, then re-run `/loom:automate` to refresh the baked PATH
  (never hand-edit the runner copy — setup re-copies it).
- **`error: unknown option '--effort'` in the log** (or a rejected model id) — the CLI on this
  machine predates a flag the runner passes. An unknown option is a parse error *before* any work,
  so every invocation dies instantly, the fail marker is written, no stamp is set, and tomorrow's
  fire repeats it forever; the only symptom is the log. Nothing self-heals here. Either upgrade
  the CLI, or set `"effort": ""` / `"model": ""` in `config.json` to stop passing that flag and
  take the account default — effective on the next fire, no re-install. Setup warns about this
  when it resolves `claude`, but a CLI downgrade after setup would slip past that check.
- **Machine asleep at fire time** — launchd coalesces a missed `StartCalendarInterval` into one fire
  on wake; cron simply misses. The once-per-day stamp makes any extra fires no-ops, and a missed day
  self-heals on the next fire (watermarks mean nothing is lost, just delayed).
- **A run fails** — the runner stamps success only when every invocation succeeded. The most
  common failure is the watchdog: an invocation past its `maxRunSecs` wall-clock ceiling (2h by
  default) is killed and logged as `watchdog: … exceeded <n>s`; ledgers + watermarks mean the next
  fire resumes where it stopped, so big first-time backlogs drain across days by design. A kill
  costs at most the **one in-flight session**: learn commits each session's delta before ledgering
  it and fires one session per invocation, so finished sessions are already in git — and if the
  kill landed after the last session but before its publish, the next learn fire detects the
  stranded unpushed commits and publishes the bundle itself (nothing to recover by hand). Repeated
  kills at the same session are a sign the ceiling is too tight for one session's work. The daily
  schedule fires once, so a failed day waits for tomorrow's fire — or fire the runner manually
  (`sh $cfg/loom/automation/bin/daily-run.sh`) to retry today; the stamp guard only blocks re-runs
  after a *success*.
- **A round's concurrent slots conflict, or a slot's worker crashes** — each of `concurrency`'s
  slots claims a different backlog session under a per-plugin `mkdir`-based claim lock
  (`$cfg/loom/learning/<plugin>.json.lock`), works in its own git worktree, and reports through a
  result sidecar; the orchestrator alone merges each slot's commit back onto the marketplace repo,
  in claim order, and only writes the ledger after a clean merge. Two slots that touched the same
  file merge fine for whichever lands first; the second's cherry-pick conflicts, gets aborted, and
  its claim is released — that session is requeued and claimable again next round (or tomorrow),
  never lost and never double-ledgered, since a conflict simply never reaches the ledger. A slot
  whose worker is killed (watchdog, crash, or worse) leaves its claim in place on purpose — nothing
  reclaims it until its age exceeds `2 × maxRunSecs`, the same staleness rule `run.lock` itself
  uses, because a still-running straggler must never have its session handed to a second worker in
  the meantime. `--status`/log readers see this as `slot-N session <id> conflicted on merge —
  requeued` or a claim that simply persists across a round or two before reclaiming.
- **`plugins/<plugin>/ has uncommitted changes` in the learn log** — the tree was dirty before the
  fire (the user's WIP, or a kill mid-implement that predates this design). Headless learn refuses
  to touch it — it cannot tell WIP from wreckage, and a per-session commit would sweep both in.
  It reports `remaining: 0` so the runner moves on; the message repeats daily until someone commits
  or cleans `plugins/<plugin>/` by hand.
- **A target project was deleted** — the runner logs "skip harvest" and continues; remove it from
  `config.json` on the next setup pass.
- **Nothing tracked** — the learn phase no-ops with a log line; `/loom:track <plugin>` fixes it with
  no re-setup.

## Done when

- The tradeoff statement was made **before** any install; the mode resolved from `$ARGUMENTS`.
- Setup: `config.json` written (validated, backed up when pre-existing), the runner **copied** to
  `$cfg/loom/automation/bin/` (never scheduled from the plugin cache), the schedule installed
  idempotently under the **per-config label** (`com.loom.daily.$slug` / `loom-automate:$slug`),
  the label-collision ownership check passed before any overwrite, any legacy shared-label
  schedule (macOS plist or Linux unsuffixed cron block) migrated only when it points into this
  `$cfg`, and the confirmation + first-run offer printed — the confirmation naming the model,
  effort, per-invocation ceiling, and concurrent-slot count the runs will use.
- `--status` reported this config dir's schedule liveness (anchored label match), config, stamp,
  the **effective** model / effort / `maxRunSecs` / `concurrency` (defaults substituted for absent
  or invalid keys, not echoed raw), and log tail without writing anything.
- `--stop` removed only this config dir's schedule and said what was kept.
- Setup and `--stop` checked `run.lock` before replacing the runner or touching the schedule, and
  the runner was installed via temp + `mv`, never an in-place `cp`.
- No other config dir's schedule, state, or credentials were read or modified at any point.
- Zero hardcoded `$HOME/.claude` — `$cfg` throughout.
