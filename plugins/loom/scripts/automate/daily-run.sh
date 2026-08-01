#!/bin/sh
# loom daily automation runner — headless harvest + learn.
#
# Installed by the `automate` skill as $cfg/loom/automation/bin/daily-run.sh and fired
# daily by launchd (macOS) or cron (Linux). Targets come from $cfg/loom/automation/config.json
# (the schedule itself lives in the plist/crontab — re-run /loom:automate to change it).
#
# launchd/cron give this script a bare environment: the installer must provide PATH (jq +
# claude reachable) via the plist EnvironmentVariables / a crontab env line. The config dir is
# NOT taken from the environment — this copy lives at $cfg/loom/automation/bin/, so it derives
# $cfg from its own location and exports CLAUDE_CONFIG_DIR itself. That pins every fire —
# scheduled or manual, from any shell — to THIS install's config dir (sessions, credentials,
# ledgers), never the invoking shell's.
#
# Design (borrowed from a battle-tested launchd harness):
# - once-per-day SUCCESS stamp: the stamp is written only when every invocation succeeded, so
#   any extra fire after a success is a no-op and a manual re-fire after a failure is a real
#   retry (the daily schedule itself fires once — a failed day otherwise waits for tomorrow);
# - per-invocation watchdog on a WALL-CLOCK deadline: one long `sleep` stops counting across
#   machine sleep — exactly when runs stall — so the deadline is polled instead;
# - one target's failure never blocks the rest — both skills ledger `error` and are
#   idempotently re-runnable, so whatever failed is picked up by the next fire.

# Refuse to be sourced (checked before set -u so a sourcing shell's options are untouched):
# sourced under bash, $0 is the shell itself, the derivation below would export a garbage
# CLAUDE_CONFIG_DIR into the user's interactive shell and the exec would eat its stdout.
case "$0" in
*/daily-run.sh|daily-run.sh) ;;
*) echo "daily-run.sh must be executed, not sourced (\$0=$0)" >&2; return 1 2>/dev/null || exit 1 ;;
esac

set -u

cfg="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd -P)"   # bin → automation → loom → $cfg
[ -n "$cfg" ] || { echo "cannot resolve config dir from $0 — is the install tree intact?" >&2; exit 1; }
export CLAUDE_CONFIG_DIR="$cfg"
# Only this config dir's own login may authenticate the headless runs — a manual fire must
# not leak the invoking shell's key into them.
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
auto="$cfg/loom/automation"
config="$auto/config.json"
CLAUDE_BIN="$(command -v claude || echo "${HOME:-}/.local/bin/claude")"
MAX_RUN_SECS=2700   # per claude invocation, wall clock

# Refuse BEFORE touching the filesystem: a stray copy (plugin repo, stale cache) must exit
# without littering its surroundings with automation/logs trees.
[ -f "$config" ] || { echo "no config at $config — run /loom:automate first (and fire the installed copy under \$cfg/loom/automation/bin/, not the plugin-repo copy: cfg is derived from this script's location)" >&2; exit 1; }

mkdir -p "$auto/logs" "$auto/stamps"
TODAY=$(date '+%Y-%m-%d')
exec >>"$auto/logs/daily-$TODAY.log" 2>&1
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

command -v jq >/dev/null || { log "jq not on PATH (${PATH:-unset}) — fix the plist/cron environment"; exit 1; }
[ -x "$CLAUDE_BIN" ] || { log "claude not found ($CLAUDE_BIN) — fix the plist/cron environment"; exit 1; }
jq empty "$config" 2>/dev/null || { log "config.json is invalid JSON — re-run /loom:automate"; exit 1; }

STAMP_FILE="$auto/stamps/last-ok"
if [ -f "$STAMP_FILE" ] && [ "$(cut -d' ' -f1 "$STAMP_FILE")" = "$TODAY" ]; then
    log "already completed today — skipping"
    exit 0
fi

# Run lock: a manual fire must not overlap a scheduled one (two claudes pushing one repo).
# run_claude touches the lock after every finished invocation, so a lock is stale only when no
# invocation has finished for 2x the per-invocation ceiling — a crash leftover (EXIT traps
# don't fire on SIGKILL/shutdown). Steal those rather than staying blocked forever.
# GNU stat first (-c), BSD (-f) second: GNU's -f means --file-system and splatters a
# filesystem report into the arithmetic below while still "succeeding" enough to corrupt it.
lock_mtime() { stat -c %Y "$auto/run.lock" 2>/dev/null || stat -f %m "$auto/run.lock" 2>/dev/null || date +%s; }
if ! mkdir "$auto/run.lock" 2>/dev/null; then
    lock_age=$(( $(date +%s) - $(lock_mtime) ))
    if [ "$lock_age" -gt $((MAX_RUN_SECS * 2)) ]; then
        log "stealing stale run.lock (age ${lock_age}s)"
        touch "$auto/run.lock"   # restart the staleness clock, or a second fire steals it too
    else
        log "another run holds $auto/run.lock (age ${lock_age}s) — skipping"
        exit 0
    fi
fi
trap 'rmdir "$auto/run.lock" 2>/dev/null' EXIT
# Without this, a signal handler returns and the run CONTINUES with its lock deleted;
# `exit` re-enters the EXIT trap above for cleanup.
trap 'log "signal received — stopping"; exit 130' INT TERM HUP

find "$auto/stamps" -name 'fail-*' -mtime +30 -delete 2>/dev/null   # cap failure-marker buildup
find "$auto/logs" -name 'daily-*.log' -mtime +30 -delete 2>/dev/null   # logs carry full claude output — same cap

PERM_MODE=$(jq -r '.permissionMode // "bypassPermissions"' "$config")
MKT_REPO=$(jq -r '.marketplaceRepo // empty' "$config")
FAIL_MARK="$auto/stamps/fail-$TODAY"
rm -f "$FAIL_MARK"

# run_claude <workdir> <prompt> — one headless invocation with its own watchdog.
# `exec` makes the subshell BECOME claude, so $pid (and the watchdog's kill) hit the real process.
# The watchdog polls a wall-clock deadline (a single long `sleep` pauses across machine sleep
# and once let a "45-minute" invocation run 4.7 hours) and escalates TERM → KILL.
run_claude() {
    wd="$1"; prompt="$2"
    log "run: cd $wd && claude -p '$prompt'"
    ( cd "$wd" && exec "$CLAUDE_BIN" -p "$prompt" --permission-mode "$PERM_MODE" ) &
    pid=$!
    (
        deadline=$(( $(date +%s) + MAX_RUN_SECS ))
        while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 30; done
        if kill -0 "$pid" 2>/dev/null; then
            log "watchdog: '$prompt' exceeded ${MAX_RUN_SECS}s wall clock — killing (pid $pid)"
            kill "$pid" 2>/dev/null; sleep 10; kill -9 "$pid" 2>/dev/null
        fi
    ) &
    wd_pid=$!
    ec=0; wait "$pid" || ec=$?
    kill "$wd_pid" 2>/dev/null || true
    touch "$auto/run.lock" 2>/dev/null   # heartbeat: staleness clock restarts at every finished invocation
    if [ "$ec" = 0 ]; then
        log "done (exit 0)"
    else
        log "FAILED (exit $ec)"
        echo "$prompt (exit $ec)" >> "$FAIL_MARK"   # a file survives the |while subshells below
    fi
}

log "starting loom daily run (cfg=$cfg perm=$PERM_MODE)"

# 1. Harvest each configured project (skip roots that no longer exist).
# Enumerate into a variable FIRST: a jq failure inside `jq | while` is invisible — zero
# iterations, no fail marker, and the day would stamp "success" having harvested nothing.
projects=$(jq -r '.projects[]?.root // empty' "$config") \
    || { log "cannot enumerate projects from config.json"; echo "config parse: projects" >> "$FAIL_MARK"; projects=""; }
printf '%s\n' "$projects" | while read -r proj; do
    [ -n "$proj" ] || continue
    if [ -d "$proj" ]; then
        run_claude "$proj" "/loom:harvest --headless"
    else
        log "skip harvest: $proj no longer exists"
    fi
done

# 2. Learn each tracked plugin belonging to the configured marketplace repo
#    (learn must run with cwd = its marketplace repo; match on marketplace name, not just plugin).
if [ -n "$MKT_REPO" ] && [ -d "$MKT_REPO" ]; then
    MKT_NAME=$(jq -r '.name // empty' "$MKT_REPO/.claude-plugin/marketplace.json" 2>/dev/null)
    repo_plugins=$(jq -r '.plugins[].name' "$MKT_REPO/.claude-plugin/marketplace.json" 2>/dev/null)
    track_cfg="$cfg/loom/learning/config.json"
    tracked=""
    if [ -f "$track_cfg" ]; then
        # capture jq alone (a trailing |sort would eat its exit status), sort after
        if tracked=$(jq -r --arg mkt "$MKT_NAME" '.track[]? | select(.marketplace == $mkt) | .plugin' "$track_cfg" 2>/dev/null); then
            tracked=$(printf '%s\n' "$tracked" | sort -u)
        else
            log "cannot parse $track_cfg"; echo "config parse: tracking" >> "$FAIL_MARK"; tracked=""
        fi
    fi
    [ -n "$tracked" ] || log "learn phase: nothing tracked for marketplace '$MKT_NAME' — /loom:track adds plugins"
    printf '%s\n' "$tracked" | while read -r plugin; do
        [ -n "$plugin" ] || continue
        if echo "$repo_plugins" | grep -qxF "$plugin"; then
            run_claude "$MKT_REPO" "/loom:learn $plugin --headless"
        else
            log "skip learn: $plugin not in $MKT_REPO's marketplace.json"
        fi
    done
else
    log "skip learn phase: marketplaceRepo not configured or missing"
fi

if [ -f "$FAIL_MARK" ]; then
    log "loom daily run had failures — NOT stamping (a manual re-fire retries today):"
    sed 's/^/  failed: /' "$FAIL_MARK"
    exit 1
fi
date '+%Y-%m-%d %H:%M:%S' > "$STAMP_FILE"
log "loom daily run complete — stamped"
exit 0
