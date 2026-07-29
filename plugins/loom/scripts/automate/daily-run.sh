#!/bin/sh
# loom daily automation runner — headless harvest + learn.
#
# Installed by the `automate` skill as $cfg/loom/automation/bin/daily-run.sh and fired
# daily by launchd (macOS) or cron (Linux). Targets come from $cfg/loom/automation/config.json
# (the schedule itself lives in the plist/crontab — re-run /loom:automate to change it).
#
# launchd/cron give this script a bare environment: the installer must provide PATH (jq +
# claude reachable) and CLAUDE_CONFIG_DIR (when non-default) via the plist EnvironmentVariables
# / a crontab env line — the `automate` skill wires both.
#
# Design (borrowed from a battle-tested launchd harness):
# - once-per-day SUCCESS stamp: the stamp is written only when every invocation succeeded, so
#   any extra fire after a success is a no-op and a manual re-fire after a failure is a real
#   retry (the daily schedule itself fires once — a failed day otherwise waits for tomorrow);
# - per-invocation watchdog: a run stalled by machine sleep must die, not hang forever;
# - one target's failure never blocks the rest — both skills ledger `error` and are
#   idempotently re-runnable, so whatever failed is picked up by the next fire.
set -u

cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
auto="$cfg/loom/automation"
config="$auto/config.json"
CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
MAX_RUN_SECS=2700   # per claude invocation

mkdir -p "$auto/logs" "$auto/stamps"
TODAY=$(date '+%Y-%m-%d')
exec >>"$auto/logs/daily-$TODAY.log" 2>&1
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

[ -f "$config" ] || { log "no config at $config — run /loom:automate first"; exit 1; }
command -v jq >/dev/null || { log "jq not on PATH ($PATH) — fix the plist/cron environment"; exit 1; }
[ -x "$CLAUDE_BIN" ] || { log "claude not found ($CLAUDE_BIN) — fix the plist/cron environment"; exit 1; }

STAMP_FILE="$auto/stamps/last-ok"
if [ -f "$STAMP_FILE" ] && [ "$(cut -d' ' -f1 "$STAMP_FILE")" = "$TODAY" ]; then
    log "already completed today — skipping"
    exit 0
fi

# Run lock: a manual fire must not overlap a scheduled one (two claudes pushing one repo).
# A lock older than 2x the per-invocation ceiling is a crash leftover (EXIT traps don't fire on
# SIGKILL/shutdown) — steal it rather than staying blocked forever.
if ! mkdir "$auto/run.lock" 2>/dev/null; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$auto/run.lock" 2>/dev/null || stat -c %Y "$auto/run.lock" 2>/dev/null || date +%s) ))
    if [ "$lock_age" -gt $((MAX_RUN_SECS * 2)) ]; then
        log "stealing stale run.lock (age ${lock_age}s)"
    else
        log "another run holds $auto/run.lock (age ${lock_age}s) — skipping"
        exit 0
    fi
fi
trap 'rmdir "$auto/run.lock" 2>/dev/null' EXIT INT TERM HUP

find "$auto/stamps" -name 'fail-*' -mtime +30 -delete 2>/dev/null   # cap failure-marker buildup

PERM_MODE=$(jq -r '.permissionMode // "bypassPermissions"' "$config")
MKT_REPO=$(jq -r '.marketplaceRepo // empty' "$config")
FAIL_MARK="$auto/stamps/fail-$TODAY"
rm -f "$FAIL_MARK"

# run_claude <workdir> <prompt> — one headless invocation with its own watchdog.
# `exec` makes the subshell BECOME claude, so $pid (and the watchdog's kill) hit the real process.
run_claude() {
    wd="$1"; prompt="$2"
    log "run: cd $wd && claude -p '$prompt'"
    ( cd "$wd" && exec "$CLAUDE_BIN" -p "$prompt" --permission-mode "$PERM_MODE" ) &
    pid=$!
    ( sleep "$MAX_RUN_SECS"; log "watchdog: '$prompt' exceeded ${MAX_RUN_SECS}s — killing (pid $pid)"; kill "$pid" 2>/dev/null ) &
    wd_pid=$!
    ec=0; wait "$pid" || ec=$?
    kill "$wd_pid" 2>/dev/null || true
    if [ "$ec" = 0 ]; then
        log "done (exit 0)"
    else
        log "FAILED (exit $ec)"
        echo "$prompt (exit $ec)" >> "$FAIL_MARK"   # a file survives the |while subshells below
    fi
}

log "starting loom daily run (perm=$PERM_MODE)"

# 1. Harvest each configured project (skip roots that no longer exist).
jq -r '.projects[]?.root // empty' "$config" | while read -r proj; do
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
    jq -r --arg mkt "$MKT_NAME" '.track[]? | select(.marketplace == $mkt) | .plugin' \
        "$cfg/loom/learning/config.json" 2>/dev/null | sort -u | while read -r plugin; do
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
