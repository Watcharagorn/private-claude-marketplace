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
#   idempotently re-runnable, so whatever failed is picked up by the next fire;
# - learn runs as concurrent ROUNDS (max 24 fires/plugin/day). Each round fires up to `concurrency`
#   (config, 1-3) `learn <plugin> --headless --concurrent` invocations at once — one per git-worktree
#   slot — so several of the SAME plugin's queued sessions are analyzed in parallel. A worker claims
#   its session atomically under the ledger's claim lock, commits inside its own worktree, and reports
#   through a result sidecar; it never writes the ledger and never publishes. THIS orchestrator owns
#   everything shared: the worktree lifecycle (`git worktree add/remove` rewrite one .git/worktrees/
#   metadata store, so running them from inside three parallel agents would race), the cherry-pick of
#   each slot's commits onto the marketplace checkout in claim order, the ledger write that follows a
#   landed merge, and the single publish when the backlog drains. So the watchdog still bounds ONE
#   session's work per slot, a merge conflict only requeues its own session (nothing reaches the
#   ledger until its commit is on main), and a kill can never strand finished-but-unpublished work.

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

# Model, effort, the wall-clock ceiling and the learn-phase slot count are read fresh at every fire,
# so editing them in config.json takes effect on the next run — no /loom:automate re-install needed
# (unlike `schedule`, which is baked into the plist/crontab). The defaults are deliberate: these runs
# read long transcripts and then rewrite plugin sources unattended under bypassPermissions, and a
# shallow pass there yields edits someone unpicks by hand afterwards — thinking hard is the whole
# point of a run nobody is watching, which is why the EFFORT default stays `xhigh` even though the
# model default is the cheaper Sonnet. `maxRunSecs` stays where it is for the same reason: cheapening
# the model is the safe direction, so the wall-clock ceiling needs no matching cut. Set either string
# to "" to pass no flag and take the account default instead.
MODEL=$(jq -r '.model // "claude-sonnet-5"' "$config")
EFFORT=$(jq -r '.effort // "xhigh"' "$config")
MAX_RUN_SECS=$(jq -r '.maxRunSecs // 7200' "$config")   # per claude invocation, wall clock
CONCURRENCY=$(jq -r '.concurrency // 3' "$config")      # learn slots fired per round
MAX_FIRES=24   # learn invocations per plugin per day, summed across slots — bounds a runaway loop
# A non-numeric ceiling turns the watchdog arithmetic below into a shell error mid-run, so the
# day would die after the config was already accepted. Leading zeros are rejected too — POSIX
# arithmetic reads 0700 as octal, and a ceiling that silently shrinks is worse than a loud one.
case "$MAX_RUN_SECS" in
    ''|*[!0-9]*|0*) log "maxRunSecs='$MAX_RUN_SECS' is not a positive integer — using 7200"; MAX_RUN_SECS=7200 ;;
esac
# Same guard, tighter range: one git worktree per slot is created up front, and 3 parallel headless
# claudes is the ceiling this design was reasoned about. Set "concurrency": 1 to run the concurrent
# machinery one slot at a time (the staged-rollout setting) — remove the key to take the default.
case "$CONCURRENCY" in
    1|2|3) ;;
    *) log "concurrency='$CONCURRENCY' is not 1, 2 or 3 — using 3"; CONCURRENCY=3 ;;
esac

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
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s; }
lock_mtime() { file_mtime "$auto/run.lock"; }
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

# run_claude <workdir> <prompt> [outfile] [tag] — one headless invocation with its own watchdog.
# This is the ONE invocation core both phases use. Harvest calls it in the foreground with neither
# optional argument, which is byte-for-byte today's behavior. The learn phase wraps this same call in
# `( … ) &` once per slot, handing each slot its own outfile and tag — a hand-written parallel twin
# would mean two copies of the watchdog and exit-code handling drifting apart.
#   outfile — "" → claude inherits this script's stdout/stderr (the shared daily log). A path → only
#             claude's own output goes there, so three parallel slots stay separately readable; this
#             function's own log lines still land in the daily log, which keeps the round-level story.
#   tag     — "" → log lines exactly as before. "learn mentor slot-2" → every line names its slot,
#             without which three interleaved invocations are indistinguishable in the daily log.
# `exec` makes the subshell BECOME claude, so $pid (and the watchdog's kill) hit the real process.
# The watchdog polls a wall-clock deadline (a single long `sleep` pauses across machine sleep
# and once let a wall-clock-capped invocation run 4.7 hours) and escalates TERM → KILL.
run_claude() {
    wd="$1"; prompt="$2"; outfile="${3:-}"; tag="${4:-}"
    [ -z "$tag" ] || tag="$tag: "
    # Build argv with `set --` instead of interpolating "${MODEL:+--model $MODEL}": that expansion
    # is unquoted by construction, and a model id may contain brackets (config.json can still ask
    # for claude-opus-5[1m]) that pathname expansion would try to match against the project's cwd.
    set -- -p "$prompt" --permission-mode "$PERM_MODE"
    [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"
    [ -n "$EFFORT" ] && set -- "$@" --effort "$EFFORT"
    log "${tag}run: cd $wd && claude -p '$prompt'${MODEL:+ --model $MODEL}${EFFORT:+ --effort $EFFORT}${outfile:+ >> $outfile}"
    if [ -n "$outfile" ]; then
        echo "----- $(date '+%Y-%m-%d %H:%M:%S') ${tag}$prompt" >> "$outfile"
        ( cd "$wd" && exec "$CLAUDE_BIN" "$@" ) >>"$outfile" 2>&1 &
    else
        ( cd "$wd" && exec "$CLAUDE_BIN" "$@" ) &
    fi
    pid=$!
    (
        deadline=$(( $(date +%s) + MAX_RUN_SECS ))
        while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 30; done
        if kill -0 "$pid" 2>/dev/null; then
            log "${tag}watchdog: '$prompt' exceeded ${MAX_RUN_SECS}s wall clock — killing (pid $pid)"
            kill "$pid" 2>/dev/null; sleep 10; kill -9 "$pid" 2>/dev/null
        fi
    ) &
    wd_pid=$!
    ec=0; wait "$pid" || ec=$?
    kill "$wd_pid" 2>/dev/null || true
    touch "$auto/run.lock" 2>/dev/null   # heartbeat: staleness clock restarts at every finished invocation
    if [ "$ec" = 0 ]; then
        log "${tag}done (exit 0)"
    else
        log "${tag}FAILED (exit $ec)"
        echo "$prompt (exit $ec)" >> "$FAIL_MARK"   # a file survives the |while subshells below
    fi
    return "$ec"   # harvest stops re-firing a target whose last fire failed; learn slots log via .ec
}

log "starting loom daily run (cfg=$cfg perm=$PERM_MODE model=${MODEL:-<account default>} effort=${EFFORT:-<account default>} ceiling=${MAX_RUN_SECS}s learn-slots=$CONCURRENCY cap=$MAX_FIRES)"

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

# ---------------------------------------------------------------------------------------------
# Concurrent learn phase — orchestrator side.
#
# Everything SHARED lives in here, in this single-threaded script: the git worktree lifecycle, the
# cherry-picks onto $MKT_REPO, the ledger writes, the publish. The concurrent workers only claim a
# session, commit inside their own worktree and drop a result sidecar. That split is the whole
# safety argument — `git worktree add/remove` rewrite one .git/worktrees/ metadata store and the
# ledger is one file, so both would race if three parallel agents touched them.
# ---------------------------------------------------------------------------------------------

slot_wt() { echo "$auto/worktrees/$1-slot-$2"; }                # <plugin> <n>
slot_br() { echo "loom-learn/$1/slot-$2/$TODAY-$$"; }           # <plugin> <n> — fresh name per run

# §K.8 claim lock — the very lock the workers take, so an orchestrator ledger write can never
# interleave with a worker claiming its session. Deliberately NOT run.lock: that is the whole-script
# single-flight guard, and taking it here would re-serialize the slots and delete the concurrency.
# mkdir, not flock(1): macOS ships no flock and launchd is the real deployment target.
claim_lock_acquire() {   # <plugin> → 0 held · 1 gave up
    cl_lock="$cfg/loom/learning/$1.json.lock"
    cl_stale=$(( MAX_RUN_SECS * 2 ))   # same reclaim rule as run.lock's
    cl_deadline=$(( $(date +%s) + 120 ))   # bounded wait: a wedged lock must never hang the runner
    until mkdir "$cl_lock" 2>/dev/null; do
        [ $(( $(date +%s) - $(file_mtime "$cl_lock") )) -gt "$cl_stale" ] \
            && { log "learn $1: stealing stale claim lock"; rm -rf "$cl_lock"; continue; }
        [ "$(date +%s)" -ge "$cl_deadline" ] && return 1
        sleep 1
    done
    return 0
}
claim_lock_release() { rm -rf "$cfg/loom/learning/$1.json.lock"; }

# ISO-8601 UTC horizon for claim staleness: a claim older than this belonged to a worker that is
# certainly gone. BSD `date -r <epoch>` first, GNU `date -d @<epoch>` second (GNU's -r wants a real
# FILE and fails on a bare number, which is exactly the fallthrough we want). If neither parses,
# emit the epoch so the GC drops NOTHING — a lingering stale claim costs one delayed session, while
# a bogus "everything is stale" cutoff would hand a live worker's session to a second worker.
stale_cutoff() {
    sc_epoch=$(( $(date +%s) - MAX_RUN_SECS * 2 ))
    date -u -r "$sc_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@$sc_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "1970-01-01T00:00:00Z"
}

# One ledger mutation inside §K.7's backup → validate → restore-on-failure envelope. Caller holds
# the claim lock and supplies the finished jq argv (program last).
ledger_apply() {   # <plugin> <jq-arg>... <program>
    la_ledger="$cfg/loom/learning/$1.json"; shift
    la_bak="$la_ledger.bak.$(date +%s)"
    cp "$la_ledger" "$la_bak" 2>/dev/null || { log "cannot back up $la_ledger"; return 1; }
    if jq "$@" "$la_ledger" > "$la_ledger.tmp" 2>/dev/null && jq empty "$la_ledger.tmp" 2>/dev/null; then
        mv "$la_ledger.tmp" "$la_ledger"
        rm -f "$la_bak"   # keeping it would grow the "$ledger".bak.* glob §K.7 warns about
        return 0
    fi
    log "ledger write on $la_ledger produced invalid JSON — restoring from $la_bak"
    rm -f "$la_ledger.tmp"; cp "$la_bak" "$la_ledger"
    return 1
}

# Merge landed → dispose the session: drop its claim, append the sidecar body verbatim as its
# analyzed[] entry (§K.8 — it already has the analyzed[] shape), advance the watermark under §K.4's
# guard. The guard reads .claims AFTER its own reassignment, so it sees the sessions genuinely still
# outstanding, and never lets the watermark reach the oldest of them: overshooting a still-claimed
# session hides it from discovery forever once its claim ages out, which is the exact silent backlog
# loss this machinery exists to prevent. A blocked advance is DROPPED, not deferred — the watermark
# only ever gates un-ledgered sessions, so lagging costs a few cheap re-filtered candidates.
finalize_claim() {   # <plugin> <sessionId> <sidecar-path>
    if ! claim_lock_acquire "$1"; then
        # Never write unlocked. The work is already merged and the append is del-then-append, so a
        # later fire's finalize is idempotent — a torn write would not be.
        log "WARN: learn $1: claim lock unavailable — $2 merged but not ledgered; a later fire finalizes it"
        return 1
    fi
    ledger_apply "$1" --arg sid "$2" --arg cut "$(stale_cutoff)" --argjson entry "$(cat "$3")" \
        '.claims   = ((.claims // []) | map(select(.claimedAt >= $cut and .sessionId != $sid)))
       | .analyzed = ([(.analyzed // [])[] | select(.sessionId != $sid)] + [$entry])
       | .watermark = ( ([.watermark, $entry.sessionEndTs] | max) as $w
                      | ([.claims[]?.sessionEndTs] | min) as $floor
                      | if $floor != null and $w >= $floor then .watermark else $w end )'
    fc_ec=$?
    claim_lock_release "$1"
    return "$fc_ec"
}

# Conflict path → requeue: drop the claim and write NO analyzed[] entry, so the session is claimable
# again next round. Merging BEFORE the ledger write is what makes this safe — a conflict never
# reaches the ledger, so there is nothing to roll back.
release_claim() {   # <plugin> <sessionId>
    claim_lock_acquire "$1" || return 1
    ledger_apply "$1" --arg sid "$2" --arg cut "$(stale_cutoff)" \
        '.claims = ((.claims // []) | map(select(.claimedAt >= $cut and .sessionId != $sid)))'
    rc_ec=$?
    claim_lock_release "$1"
    return "$rc_ec"
}

# Has a failed cherry-pick been genuinely unwound? Scoped to this plugin's tree on purpose: an
# unrelated file someone left modified elsewhere in the repo must not be mistaken for a botched
# abort (and the pre-flight guard in learn_plugin already proved plugins/<plugin>/ started clean).
repo_settled() {   # <plugin>
    git -C "$MKT_REPO" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1 && return 1
    [ -n "$(git -C "$MKT_REPO" ls-files --unmerged 2>/dev/null)" ] && return 1
    [ -n "$(git -C "$MKT_REPO" status --porcelain -- "plugins/$1/" 2>/dev/null)" ] && return 1
    return 0
}

# Remove one slot's worktree AND its branch. Best-effort by design, and used from both ends:
# teardown (where a failure is logged and tomorrow's setup mops it up) and setup (where it clears a
# previous day's FATAL-halted leftovers before `worktree add` can collide with them).
slot_cleanup() {   # <plugin> <n>
    sc_wt=$(slot_wt "$1" "$2")
    git -C "$MKT_REPO" worktree remove --force "$sc_wt" >/dev/null 2>&1 || rm -rf "$sc_wt"
    git -C "$MKT_REPO" worktree prune >/dev/null 2>&1   # `rm -rf` leaves the admin entry behind
    # `worktree remove` leaves the branch ref, and a fresh branch name is minted per slot per day —
    # without this the daily fires grow an unbounded trail of dangling refs. Sweep the whole slot
    # namespace, not just today's name: a halted run left a differently-dated one behind.
    git -C "$MKT_REPO" for-each-ref --format='%(refname:short)' "refs/heads/loom-learn/$1/slot-$2" 2>/dev/null \
        | while read -r sc_br; do
            [ -n "$sc_br" ] || continue
            git -C "$MKT_REPO" branch -D "$sc_br" >/dev/null 2>&1 \
                || log "learn $1: could not delete leftover branch $sc_br"
          done
    rm -f "$auto/slots/$1-slot-$2.pid" "$auto/slots/$1-slot-$2.ec"
}

setup_slots() {   # <plugin> <base-sha> — once per plugin's daily batch; idempotent vs leftovers
    mkdir -p "$auto/worktrees" "$auto/slots"
    ss_n=1
    while [ "$ss_n" -le "$CONCURRENCY" ]; do
        slot_cleanup "$1" "$ss_n"
        git -C "$MKT_REPO" worktree add --quiet -b "$(slot_br "$1" "$ss_n")" \
            "$(slot_wt "$1" "$ss_n")" "$2" 2>&1 \
            || { log "learn $1: cannot create worktree slot $ss_n — skipping this plugin today"; return 1; }
        ss_n=$((ss_n + 1))
    done
    return 0
}

teardown_slots() {   # <plugin> — unconditional on EVERY exit from the round loop
    ts_n=1
    while [ "$ts_n" -le "$CONCURRENCY" ]; do
        slot_cleanup "$1" "$ts_n"
        ts_n=$((ts_n + 1))
    done
}

reset_slots() {   # <plugin> <base-sha> — before every round, uniformly, whatever the slot last did
    rs_n=1
    while [ "$rs_n" -le "$CONCURRENCY" ]; do
        rs_wt=$(slot_wt "$1" "$rs_n")
        git -C "$rs_wt" reset -q --hard "$2" 2>&1 \
            || { log "learn $1: slot-$rs_n reset to $2 failed"; return 1; }
        # `reset --hard` only touches TRACKED files, so without this a prior round's untracked
        # .loom-learn-result.json survives and this round reads a stale outcome as its own.
        git -C "$rs_wt" clean -qfd 2>&1 || { log "learn $1: slot-$rs_n clean failed"; return 1; }
        # Belt and braces: the sidecar is the one file whose staleness silently corrupts a round,
        # and `clean -fd` would spare it the day someone gitignores it.
        rm -f "$rs_wt/.loom-learn-result.json"
        rs_n=$((rs_n + 1))
    done
    return 0
}

fire_round() {   # <plugin> <slots> — fire N workers at once, return when all have finished
    fr_n=1
    while [ "$fr_n" -le "$2" ]; do
        fr_state="$auto/slots/$1-slot-$fr_n"
        rm -f "$fr_state.ec" "$fr_state.pid"
        (
            LOOM_SLOT="$fr_n"; export LOOM_SLOT   # §K.8 stamps the slot onto the claim
            run_claude "$(slot_wt "$1" "$fr_n")" "/loom:learn $1 --headless --concurrent" \
                "$auto/logs/daily-$TODAY-slot-$fr_n.log" "learn $1 slot-$fr_n"
            echo $? > "$fr_state.ec"
        ) &
        echo $! > "$fr_state.pid"
        fr_n=$((fr_n + 1))
    done
    # POSIX sh has no arrays, so no exit code can be collected in-memory: each slot reports through
    # its own .ec statefile, and a bare `wait` blocks on all of them without one blocking another.
    wait
}

# Slot numbers ordered by the claimedAt of the session each one claimed (oldest first, §K.8): the
# oldest backlog session's work gets first crack at main when two slots touched the same file.
# Slots that claimed nothing (no-candidate, or a crashed worker) sort last — nothing to merge.
claim_order() {   # <plugin> <slots> → slot numbers, one per line
    co_n=1
    while [ "$co_n" -le "$2" ]; do
        co_sid=$(jq -r '.sessionId // empty' "$(slot_wt "$1" "$co_n")/.loom-learn-result.json" 2>/dev/null)
        co_at=""
        [ -z "$co_sid" ] || co_at=$(jq -r --arg s "$co_sid" \
            'first((.claims // [])[] | select(.sessionId == $s) | .claimedAt) // empty' \
            "$cfg/loom/learning/$1.json" 2>/dev/null)
        printf '%s\t%s\n' "${co_at:-~}" "$co_n"   # ~ sorts after any ISO timestamp in the C locale
        co_n=$((co_n + 1))
    done | LC_ALL=C sort | cut -f2
}

# Fold one slot's result back into $MKT_REPO and the ledger.
#   → 0 disposed (ledgered) · 1 requeued · 2 no-candidate · 3 worker failed · 4 FATAL, halt the plugin
merge_slot() {   # <plugin> <n> <base-sha>
    ms_wt=$(slot_wt "$1" "$2")
    ms_sidecar="$ms_wt/.loom-learn-result.json"

    if ! jq empty "$ms_sidecar" 2>/dev/null; then
        # No readable sidecar means the worker died before reporting. Its claim is left ALONE on
        # purpose — only staleness GC may reclaim it, so a straggler that is somehow still running
        # can never have its session handed to a second worker.
        log "learn $1: slot-$2 wrote no result sidecar — worker failed; claim left for staleness GC"
        return 3
    fi
    ms_outcome=$(jq -r '.outcome // "error"' "$ms_sidecar")
    if [ "$ms_outcome" = "no-candidate" ]; then
        log "learn $1: slot-$2 found no claimable session"
        return 2
    fi
    ms_sid=$(jq -r '.sessionId // empty' "$ms_sidecar")
    if [ -z "$ms_sid" ]; then
        log "learn $1: slot-$2 sidecar says '$ms_outcome' but names no session — treating as a failure"
        return 3
    fi

    ms_head=$(git -C "$ms_wt" rev-parse HEAD 2>/dev/null)
    if [ -z "$ms_head" ]; then
        # An unreadable worktree must not be mistaken for "the worker committed nothing" — that
        # would ledger the session as disposed and lose its work silently. Leave the claim.
        log "learn $1: slot-$2 worktree HEAD unreadable — treating session $ms_sid as a failure"
        return 3
    fi
    ms_commits=$(git -C "$ms_wt" rev-list "$3..$ms_head" 2>/dev/null)
    if git -C "$MKT_REPO" log -F --grep="Loom-Session: $ms_sid" -n 1 --format=%H 2>/dev/null | grep -q .; then
        # A previous round's cherry-pick landed but the orchestrator died before ledgering it. The
        # trailer proves the work is already on main — finalize instead of applying it twice.
        log "learn $1: slot-$2 session $ms_sid already on main (Loom-Session trailer) — ledgering only"
    elif [ -z "$ms_commits" ]; then
        # `analyzed`/`no-usage` with nothing to commit (no findings, or the work was already there).
        # Nothing to merge, but the session IS disposed and must be ledgered — otherwise it is
        # re-claimed every round forever.
        log "learn $1: slot-$2 session $ms_sid disposed '$ms_outcome' with no commit — ledgering only"
    elif git -C "$MKT_REPO" cherry-pick "$3..$ms_head" >/dev/null 2>&1; then
        log "learn $1: slot-$2 session $ms_sid merged ($(printf '%s\n' "$ms_commits" | grep -c .) commit(s))"
    else
        git -C "$MKT_REPO" cherry-pick --abort >/dev/null 2>&1
        ms_abort=$?
        if [ "$ms_abort" != 0 ] || ! repo_settled "$1"; then
            log "FATAL: cherry-pick abort left $MKT_REPO dirty — halting $1 for today"
            git -C "$MKT_REPO" status --porcelain 2>&1 | sed 's/^/  dirty: /'
            echo "learn $1: cherry-pick abort left $MKT_REPO dirty (slot-$2, session $ms_sid)" >> "$FAIL_MARK"
            return 4
        fi
        if release_claim "$1" "$ms_sid"; then
            log "learn $1: slot-$2 session $ms_sid conflicted on merge — requeued"
        else
            log "learn $1: slot-$2 session $ms_sid conflicted on merge — claim NOT released (lock busy); staleness GC reclaims it"
        fi
        return 1
    fi
    finalize_claim "$1" "$ms_sid" "$ms_sidecar"
    return 0
}

# Unpushed commits on the checked-out branch — today's merges plus anything a previous cap-hit day
# stranded, which together are exactly the bundle publish-plugin pushes. -1 = no upstream to compare.
unpushed_count() {
    uc_up=$(git -C "$MKT_REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || uc_up=""
    [ -n "$uc_up" ] || { printf '%s\n' -1; return 0; }   # printf, not echo: `echo -1` is option-shaped
    git -C "$MKT_REPO" rev-list --count "$uc_up..HEAD" 2>/dev/null || echo 0
}

# One plugin's whole daily learn batch: setup slots → rounds of concurrent fires, each merged back
# in claim order → teardown → publish once if the backlog drained.
learn_plugin() {   # <plugin>
    # The orchestrator now commits INTO $MKT_REPO itself, so a dirty plugin tree is no longer just
    # the worker's problem: every cherry-pick would fail against it, and repo_settled() could not
    # tell that pre-existing dirt from a botched abort — turning it into a false FATAL. Same stop
    # the worker's own working-tree guard would take, taken one level up and before a fire is spent.
    if [ -n "$(git -C "$MKT_REPO" status --porcelain -- "plugins/$1/" 2>/dev/null)" ]; then
        log "skip learn: plugins/$1/ has uncommitted changes in $MKT_REPO — commit or clean them before the next run"
        return 0
    fi
    lp_base=$(git -C "$MKT_REPO" rev-parse HEAD 2>/dev/null) \
        || { log "skip learn: cannot resolve $MKT_REPO HEAD"; return 0; }
    [ -f "$cfg/loom/learning/$1.json" ] || printf '{"schemaVersion":1,"plugin":"%s","analyzed":[]}\n' "$1" \
        > "$cfg/loom/learning/$1.json"   # first run: the workers claim into it, so it must exist
    setup_slots "$1" "$lp_base" || { teardown_slots "$1"; return 0; }

    lp_fires=0; lp_disposed_total=0; lp_lost_total=0; lp_drained=0
    while :; do
        lp_base=$(git -C "$MKT_REPO" rev-parse HEAD)   # main moved under the last round's merges
        reset_slots "$1" "$lp_base" \
            || { log "learn $1: worktree reset failed — halting this plugin for today"; break; }

        lp_slots=$CONCURRENCY
        [ $(( lp_fires + lp_slots )) -gt "$MAX_FIRES" ] && lp_slots=$(( MAX_FIRES - lp_fires ))
        [ "$lp_slots" -gt 0 ] || break
        log "learn $1: round starting — $lp_slots slot(s), $lp_fires/$MAX_FIRES fires used"
        fire_round "$1" "$lp_slots"
        # Every invocation counts, whatever it returned: the cap bounds invocations (cost), not
        # distinct completed sessions, and a no-candidate exit is cheap precisely because of that.
        lp_fires=$(( lp_fires + lp_slots ))

        lp_fatal=0; lp_disposed=0; lp_requeued=0; lp_nocand=0; lp_failed=0
        for lp_sn in $(claim_order "$1" "$lp_slots"); do
            merge_slot "$1" "$lp_sn" "$lp_base"
            case $? in
                0) lp_disposed=$((lp_disposed + 1)) ;;
                1) lp_requeued=$((lp_requeued + 1)) ;;
                2) lp_nocand=$((lp_nocand + 1)) ;;
                3) lp_failed=$((lp_failed + 1)) ;;
                *) lp_fatal=1; break ;;
            esac
        done
        lp_disposed_total=$(( lp_disposed_total + lp_disposed ))
        lp_lost_total=$(( lp_lost_total + lp_failed ))
        log "learn $1: round done — $lp_disposed disposed, $lp_requeued requeued, $lp_nocand no-candidate, $lp_failed failed ($lp_fires/$MAX_FIRES fires used)"

        [ "$lp_fatal" = 1 ] && break
        if [ "$lp_nocand" -gt 0 ] && [ "$lp_requeued" -eq 0 ] && [ "$lp_failed" -eq 0 ]; then
            # A slot asked for work and the backlog had none left, with nothing requeued and nothing
            # lost to a crash: this design's `remaining == 0`. (The count itself is deliberately not
            # recomputed here — that would duplicate the skill's discovery logic in the runner.)
            lp_drained=1; break
        fi
        if [ $(( lp_disposed + lp_requeued )) -eq 0 ]; then
            log "learn $1: round merged nothing and requeued nothing — stopping for today"
            break
        fi
        if [ "$lp_fires" -ge "$MAX_FIRES" ]; then
            log "learn $1: daily fire cap ($MAX_FIRES) reached — sessions still queued drain on the next fire"
            break
        fi
    done
    teardown_slots "$1"

    # Same publish gate as the sequential runner's: bump + push exactly once, only when the queue is
    # actually empty. A crashed worker's session is still outstanding, so lp_lost_total > 0 means the
    # backlog is NOT drained — its commits ride along in a later day's push, matching how a failed
    # sequential fire has always deferred the publish.
    if [ "$lp_drained" = 1 ] && [ "$lp_lost_total" -eq 0 ]; then
        lp_unpushed=$(unpushed_count)
        if [ "$lp_unpushed" -lt 0 ]; then
            log "learn $1: $MKT_REPO has no upstream to compare against — publishing only if this run disposed anything"
            lp_unpushed=$lp_disposed_total
        fi
        if [ "$lp_unpushed" -gt 0 ]; then
            log "learn $1: backlog drained with $lp_unpushed unpushed commit(s) — publishing"
            run_claude "$MKT_REPO" "/loom:publish-plugin release $1 — bundle the pending learn commits into one bump. This is an unattended --headless run: never pause on an ambiguous bump, take the lower class and note the ambiguity in the commit body." "" "publish $1"
        else
            log "learn $1: backlog drained, nothing pending to publish"
        fi
    fi
    log "learn $1: batch complete — $lp_fires fire(s), $lp_disposed_total session(s) disposed"
}

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
            # Round loop: each round fires up to $CONCURRENCY `learn --headless --concurrent`
            # invocations at once, one per worktree slot, each processing exactly ONE session — so
            # every fire still gets its own watchdog window and a kill costs one in-flight session,
            # never a finished batch. This orchestrator then cherry-picks the round's commits back
            # in claim order and writes the ledger; the drain publishes the whole bundle once.
            learn_plugin "$plugin"
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
