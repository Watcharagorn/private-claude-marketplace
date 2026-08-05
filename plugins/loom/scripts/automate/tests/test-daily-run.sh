#!/usr/bin/env bash
# Regression tests for scripts/automate/daily-run.sh's concurrent learn-phase round loop —
# atomic claiming, worktree-isolated commits, claim-order cherry-pick, conflict-abort-requeue,
# stale-claim reclaim, the watermark guard, the FATAL halt on a stuck abort, and teardown.
#
# daily-run.sh itself is run FOR REAL, wholesale, once per scenario — this suite never
# reimplements its orchestrator logic (claim_order, merge_slot, finalize_claim, release_claim,
# setup/reset/teardown_slots all run as the real committed code). The one thing a test cannot
# do is invoke the real `claude -p` LLM, so PATH is pointed at a fixture `claude` (below) that
# stands in for a `/loom:learn <plugin> --headless --concurrent` worker: it performs the REAL
# §K.8 claim recipe (mkdir lock, jq claims[] patch, no-candidate sidecar) against a small
# test-only backlog file, then "does the work" — one file write, one commit carrying the
# Loom-Session trailer, one result sidecar — exactly the shape merge_slot expects.
#
# Two more fixtures earn their keep:
#   - a "crash-once" backlog entry that claims a session and then exits nonzero (mimicking a
#     watchdog SIGKILL) before writing anything else, so its claim is genuinely left dangling.
#     Rather than sleeping for real wall-clock `2 x maxRunSecs` to age it out, the test backdates
#     the claim's `claimedAt` directly — the GC comparison being tested only cares about the
#     stored timestamp, not the real time elapsed, so this keeps the suite fast without faking
#     the comparison logic itself.
#   - a `git` shim, PATH-prepended only for the FATAL-halt scenario, that lets `cherry-pick
#     --abort` through untouched for every call EXCEPT the one this test forces to fail — which
#     it does by refusing to run the real abort at all, so the repo is genuinely left mid-pick,
#     not just made to LOOK that way.
#
# A note on claim order and timestamp resolution (found while chasing a flaky scenario D):
# daily-run.sh's claim_order() sorts "claimedAt\tslot" lines, and the real §K.8 recipe stamps
# claimedAt at whole-SECOND resolution (`date -u +%Y-%m-%dT%H:%M:%SZ`). The claim step itself
# (mkdir lock + tiny jq read/write) takes single-digit milliseconds, so when N workers are fired
# at once — the norm under real concurrency, not a corner — their claimedAt values routinely tie
# at the same second, confirmed empirically (isolated 3-way race: all three claims landed in the
# same second on every trial). Under a tie, claim_order's only discriminator is slot NUMBER,
# which is unrelated to which slot actually WON the lock race first (verified with a
# sub-millisecond instrumented replay: slot 3 beat slot 2 to the lock while still sorting after
# it) — so which physical session ends up in which claim-order position is genuinely, routinely
# nondeterministic. This is a real, reproducible characteristic of the shipped code, not a test
# artifact. Whether it needs a production fix is a separate question from whether THIS suite can
# be deterministic — this suite answers the latter by giving scenarios B and D each session an
# explicit `claimedAtOverride` (a near-future timestamp, so it's never mistaken for stale) that
# the stub writes verbatim via the real jq claims[] patch, instead of real wall-clock time. That
# pins claim order without touching daily-run.sh or faking anything the mechanism does — the
# real lock, the real sessionEndTs-driven candidate pick, and the real claims[] write all still
# run; only the recorded timestamp is controlled, exactly like scenario C already controls
# claimedAt (by backdating it) for a different determinism purpose.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAILY_RUN="$(cd "$SCRIPT_DIR/.." && pwd)/daily-run.sh"
[ -f "$DAILY_RUN" ] || { echo "FATAL: $DAILY_RUN not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq not on PATH" >&2; exit 1; }
REAL_GIT="$(command -v git)" || { echo "FATAL: git not on PATH" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"
mkdir -p "$SANDBOX"
export HOME="$SANDBOX"
git config --global user.email "loom-test@example.com" >/dev/null 2>&1
git config --global user.name "loom-test" >/dev/null 2>&1
git config --global init.defaultBranch main >/dev/null 2>&1
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() {   # chk <description> <command...>
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}

PLUGIN="testplugin"

# --- fixture bin: the fake `claude` worker + the scenario-D-only `git` shim -------------------
FIXTURE_BIN="$ROOT/fixture-bin"; mkdir -p "$FIXTURE_BIN"
GITSHIM_BIN="$ROOT/gitshim-bin"; mkdir -p "$GITSHIM_BIN"

cat > "$FIXTURE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
# Fixture double for `claude`, used only by test-daily-run.sh. Everything ORCHESTRATOR-side
# (merge, cherry-pick, ledger finalize, teardown) is the real daily-run.sh code; this stub
# only replaces the LLM session daily-run.sh cannot invoke in a test.
set -uo pipefail

prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --model|--effort|--permission-mode) shift 2 ;;
    *) shift ;;
  esac
done

case "$prompt" in
  */loom:harvest*|*/loom:publish-plugin*) exit 0 ;;
esac

plugin=$(printf '%s' "$prompt" | sed -n 's#.*/loom:learn \([^ ]*\).*#\1#p')
if [ -z "$plugin" ]; then
  echo "stub-claude: cannot parse plugin from prompt: $prompt" >&2
  exit 1
fi

cfg="${CLAUDE_CONFIG_DIR:?CLAUDE_CONFIG_DIR not set}"
backlog="${LOOM_TEST_BACKLOG:?LOOM_TEST_BACKLOG not set}"
state="${LOOM_TEST_STATE:?LOOM_TEST_STATE not set}"
mkdir -p "$state"

ledger="$cfg/loom/learning/$plugin.json"
lock="$ledger.lock"
[ -f "$ledger" ] || printf '{"schemaVersion":1,"plugin":"%s","analyzed":[]}\n' "$plugin" > "$ledger"

maxRunSecs=$(jq -r '.maxRunSecs // 7200' "$cfg/loom/automation/config.json" 2>/dev/null)
case "$maxRunSecs" in ''|*[!0-9]*) maxRunSecs=7200 ;; esac
stale=$(( maxRunSecs * 2 ))

now_epoch=$(date +%s)
cut=$(date -u -r $(( now_epoch - stale )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$(( now_epoch - stale ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- acquire the claim lock: mkdir, stale-stealable past 2xmaxRunSecs (chassis §K.8) ---
deadline=$(( $(date +%s) + 30 ))
until mkdir "$lock" 2>/dev/null; do
  lock_age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0) ))
  if [ "$lock_age" -gt "$stale" ]; then rm -rf "$lock"; continue; fi
  [ "$(date +%s)" -ge "$deadline" ] && { echo "stub-claude: claim lock busy" >&2; exit 1; }
  sleep 0.2
done

analyzed_ids=$(jq -r '(.analyzed // [])[].sessionId' "$ledger" 2>/dev/null)
live_ids=$(jq -r --arg cut "$cut" '(.claims // [])[] | select(.claimedAt >= $cut) | .sessionId' "$ledger" 2>/dev/null)

sid=""; end=""; file=""; content=""; mode=""; claim_override=""
while IFS=$'\t' read -r c_sid c_end c_file c_content c_mode c_override; do
  [ -n "$c_sid" ] || continue
  printf '%s\n' "$analyzed_ids" | grep -qxF "$c_sid" && continue
  printf '%s\n' "$live_ids" | grep -qxF "$c_sid" && continue
  sid="$c_sid"; end="$c_end"; file="$c_file"; content="$c_content"; mode="$c_mode"; claim_override="$c_override"
  break
done < <(jq -r 'sort_by(.sessionEndTs)[] | [.sessionId, .sessionEndTs, .editFile, .editContent, .mode, (.claimedAtOverride // "")] | @tsv' "$backlog")

if [ -z "$sid" ]; then
  jq -n '{outcome:"no-candidate"}' > .loom-learn-result.json
  rmdir "$lock" 2>/dev/null
  echo "stub-claude: no candidate available"
  exit 0
fi

# Real wall-clock claimedAt ties across concurrent claimants at whole-second resolution — see
# the header note. A fixture that needs a STABLE claim order (so a conflict/FATAL lands on a
# known session) supplies claimedAtOverride per backlog entry; everything else about this write
# (the lock, the jq claims[] patch, the GC filter) is the real §K.8 recipe, unchanged.
claim_now="$now"
[ -n "$claim_override" ] && claim_now="$claim_override"

jq --arg sid "$sid" --arg end "$end" --arg now "$claim_now" --arg cut "$cut" \
   --argjson slot "${LOOM_SLOT:-0}" --argjson pid "$$" \
   '.claims = ((.claims // []) | map(select(.claimedAt >= $cut)))
              + [{sessionId:$sid, sessionEndTs:$end, slot:$slot, pid:$pid, claimedAt:$now}]' \
   "$ledger" > "$ledger.tmp" && jq empty "$ledger.tmp" && mv "$ledger.tmp" "$ledger"
rmdir "$lock" 2>/dev/null

if [ "$mode" = "crash-once" ] && [ ! -f "$state/crashed-$sid" ]; then
  touch "$state/crashed-$sid"
  echo "stub-claude: simulating a killed worker for $sid (claimed, exiting before reporting)"
  exit 137   # mimics the real watchdog's SIGKILL exit code, so run_claude logs a real FAILED
fi

mkdir -p "plugins/$plugin"
printf '%s\n' "$content" > "plugins/$plugin/$file"
git add "plugins/$plugin/$file"
git commit -q -m "learn($plugin): session ${sid} - fixture edit" --trailer "Loom-Session=$sid"

analyzedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg sid "$sid" --arg tp "/fake/projects/$sid.jsonl" --arg proj "test-project" \
      --arg end "$end" --arg at "$analyzedAt" \
   '{outcome:"analyzed", sessionId:$sid, transcriptPath:$tp, project:$proj, sessionEndTs:$end,
     lineCount:1, markerHits:1, viaSubagent:false, analyzedAt:$at, findings:1}' \
   > .loom-learn-result.json

echo "stub-claude: session $sid analyzed"
exit 0
STUB
chmod +x "$FIXTURE_BIN/claude"

cat > "$GITSHIM_BIN/git" <<'SHIM'
#!/usr/bin/env bash
# git shim used only by the FATAL-halt scenario: forwards every call to the real git EXCEPT
# `cherry-pick --abort`, which it fails WITHOUT running (gated by LOOM_TEST_FORCE_ABORT_FAIL) —
# so the repo is genuinely left mid-cherry-pick, the same as a real stuck abort would leave it.
real_git="${LOOM_TEST_REAL_GIT:?LOOM_TEST_REAL_GIT not set}"
if [ -n "${LOOM_TEST_FORCE_ABORT_FAIL:-}" ]; then
  saw_cp=0; saw_abort=0
  for a in "$@"; do
    case "$a" in
      cherry-pick) saw_cp=1 ;;
      --abort) saw_abort=1 ;;
    esac
  done
  if [ "$saw_cp" = 1 ] && [ "$saw_abort" = 1 ]; then
    echo "git-shim: forcing 'cherry-pick --abort' to fail (test fixture)" >&2
    exit 1
  fi
fi
exec "$real_git" "$@"
SHIM
chmod +x "$GITSHIM_BIN/git"

# --- scenario scaffolding ----------------------------------------------------------------------

new_scenario() {   # <name> <concurrency> <maxRunSecs> -> sets SC_ROOT SC_MKT SC_CFG SC_STATE
  local name="$1" conc="$2" mrs="$3"
  SC_ROOT="$ROOT/$name"
  SC_MKT="$SC_ROOT/mkt-repo"
  SC_CFG="$SC_ROOT/cfg"
  SC_STATE="$SC_ROOT/state"
  mkdir -p "$SC_MKT" "$SC_CFG/loom/automation/bin" "$SC_CFG/loom/learning" "$SC_STATE"

  git init -q -b main "$SC_MKT"
  ( cd "$SC_MKT" \
    && mkdir -p .claude-plugin "plugins/$PLUGIN" \
    && printf '{"name":"test-marketplace","plugins":[{"name":"%s","source":"./plugins/%s"}]}\n' \
         "$PLUGIN" "$PLUGIN" > .claude-plugin/marketplace.json \
    && printf 'seed\n' > "plugins/$PLUGIN/SEED.md" \
    && git add -A && git commit -q -m init ) \
    || { echo "FATAL: could not seed scenario $name's mkt-repo" >&2; exit 1; }

  cp "$DAILY_RUN" "$SC_CFG/loom/automation/bin/daily-run.sh"
  chmod +x "$SC_CFG/loom/automation/bin/daily-run.sh"

  jq -n --arg repo "$SC_MKT" --argjson conc "$conc" --argjson mrs "$mrs" \
    '{marketplaceRepo:$repo, concurrency:$conc, maxRunSecs:$mrs,
      permissionMode:"bypassPermissions", model:"", effort:""}' \
    > "$SC_CFG/loom/automation/config.json"

  jq -n --arg p "$PLUGIN" '{track:[{plugin:$p, marketplace:"test-marketplace"}]}' \
    > "$SC_CFG/loom/learning/config.json"
}

run_daily() {   # <cfg> <backlog> <state> [use_shim 0/1] [force_abort 0/1] -> daily-run.sh's exit code
  local cfg="$1" backlog="$2" state="$3" use_shim="${4:-0}" force_abort="${5:-0}"
  local pathprefix="$FIXTURE_BIN"
  [ "$use_shim" = 1 ] && pathprefix="$GITSHIM_BIN:$FIXTURE_BIN"
  (
    export LOOM_TEST_BACKLOG="$backlog"
    export LOOM_TEST_STATE="$state"
    export LOOM_TEST_REAL_GIT="$REAL_GIT"
    export PATH="$pathprefix:$PATH"
    [ "$force_abort" = 1 ] && export LOOM_TEST_FORCE_ABORT_FAIL=1
    "$cfg/loom/automation/bin/daily-run.sh"
  )
}

assert_teardown_clean() {   # <mkt-repo> <plugin> <label>
  local mkt="$1" plugin="$2" label="$3"
  chk "$label: worktree list back down to just the main checkout" \
    test "$(git -C "$mkt" worktree list --porcelain | grep -c '^worktree ')" = "1"
  chk "$label: no leftover loom-learn/$plugin/* branches" \
    test -z "$(git -C "$mkt" branch --list "loom-learn/$plugin/*")"
}

future_ts() {   # <seconds-ahead> -> ISO-8601 UTC timestamp that far past real now
  local off="$1"
  date -u -v+"${off}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$(( $(date +%s) + off ))" +%Y-%m-%dT%H:%M:%SZ
}

# =================================================================================================
echo "== A. clean concurrent merge across 3 slots, a genuine multi-round drain, and teardown =="
# 5 sessions > 3 slots forces a real 2nd round; every session touches its OWN file so nothing
# conflicts regardless of merge order — isolates "does the happy path work" from conflict handling.
new_scenario sc-a 3 60
BACKLOG_A="$ROOT/sc-a/backlog.json"
jq -n '[
  {sessionId:"sess-a1", sessionEndTs:"2026-01-01T00:00:00Z", editFile:"file-a1.txt", editContent:"content-a1", mode:"normal"},
  {sessionId:"sess-a2", sessionEndTs:"2026-01-02T00:00:00Z", editFile:"file-a2.txt", editContent:"content-a2", mode:"normal"},
  {sessionId:"sess-a3", sessionEndTs:"2026-01-03T00:00:00Z", editFile:"file-a3.txt", editContent:"content-a3", mode:"normal"},
  {sessionId:"sess-a4", sessionEndTs:"2026-01-04T00:00:00Z", editFile:"file-a4.txt", editContent:"content-a4", mode:"normal"},
  {sessionId:"sess-a5", sessionEndTs:"2026-01-05T00:00:00Z", editFile:"file-a5.txt", editContent:"content-a5", mode:"normal"}
]' > "$BACKLOG_A"

run_daily "$SC_CFG" "$BACKLOG_A" "$SC_STATE"
rc_a=$?
LOG_A="$SC_CFG/loom/automation/logs/daily-$(date +%Y-%m-%d).log"
LEDGER_A="$SC_CFG/loom/learning/$PLUGIN.json"

chk "daily-run.sh exits 0" test "$rc_a" = "0"
chk "stamp file written (day marked success)" test -f "$SC_CFG/loom/automation/stamps/last-ok"
chk "5 analyzed[] entries, one per session" test "$(jq '.analyzed | length' "$LEDGER_A")" = "5"
chk "no duplicate sessionIds in analyzed[]" \
  test "$(jq -r '.analyzed[].sessionId' "$LEDGER_A" | sort | uniq -d | wc -l | tr -d ' ')" = "0"
chk "claims[] empty once the backlog drains" test "$(jq '(.claims // []) | length' "$LEDGER_A")" = "0"
chk "all 5 sessionIds landed in the ledger" \
  test "$(jq -r '.analyzed[].sessionId' "$LEDGER_A" | sort | tr '\n' ',')" = "sess-a1,sess-a2,sess-a3,sess-a4,sess-a5,"
chk "5 commits landed on mkt-repo's main (+1 seed commit)" \
  test "$(git -C "$SC_MKT" rev-list --count HEAD)" = "6"
chk "every commit carries its own Loom-Session trailer" bash -c '
  for s in sess-a1 sess-a2 sess-a3 sess-a4 sess-a5; do
    git -C "'"$SC_MKT"'" log -F --grep="Loom-Session: $s" -n1 --format=%H | grep -q . || exit 1
  done'
chk "the round loop actually spanned 2 rounds (5 sessions, 3-slot concurrency)" \
  test "$(grep -c 'learn testplugin: round starting' "$LOG_A")" = "2"
chk "round 1 disposed all 3 concurrent slots cleanly" \
  grep -q 'round done — 3 disposed, 0 requeued, 0 no-candidate, 0 failed' "$LOG_A"
chk "round 2 disposed the remaining 2 and drained on no-candidate" \
  grep -q 'round done — 2 disposed, 0 requeued, 1 no-candidate, 0 failed' "$LOG_A"
chk "fires_used counted all 6 invocations toward the cap (3 + 3)" \
  grep -q '6/24 fires used' "$LOG_A"

assert_teardown_clean "$SC_MKT" "$PLUGIN" "scenario A"

# =================================================================================================
echo "== B. manufactured conflict -> abort + requeue =="
# Two sessions add the SAME new file with different content. The candidate PICK is always
# oldest-sessionEndTs-first (unaffected by the note above — that's a plain sorted read under the
# lock, not a timestamp comparison), so sess-b-old is always claimed before sess-b-new. But
# claim_order() — which decides MERGE order — sorts by claimedAt, and real concurrent claims tie
# at whole-second resolution (see the header note), so which of the two is actually claimed
# FIRST doesn't reliably land FIRST in claim_order without help. claimedAtOverride pins that:
# sess-b-old's merge-order position is now deterministic, so "old merges clean, new conflicts" is
# a guaranteed outcome, not a coin flip — while the lock, the pick, and the merge/abort/requeue
# machinery are all still the real code, doing real work. Note: because a requeued session
# retries against FRESH main next round (by design — reset_slots resets to the new tip before
# every round), it disposes cleanly on its second attempt; that is the intended, documented
# behavior (plan scenario 2), not a test gap. What this asserts is the conflict+requeue
# TRANSITION itself, via the round's own disposed/requeued counters (real code, not log prose)
# and the fact that the aborted attempt left no trace in mkt-repo.
new_scenario sc-b 2 60
BACKLOG_B="$ROOT/sc-b/backlog.json"
jq -n --arg t1 "$(future_ts 1)" --arg t2 "$(future_ts 2)" '[
  {sessionId:"sess-b-old", sessionEndTs:"2026-02-01T00:00:00Z", editFile:"conflict.txt", editContent:"content-from-old", mode:"normal", claimedAtOverride:$t1},
  {sessionId:"sess-b-new", sessionEndTs:"2026-02-02T00:00:00Z", editFile:"conflict.txt", editContent:"content-from-new", mode:"normal", claimedAtOverride:$t2}
]' > "$BACKLOG_B"

run_daily "$SC_CFG" "$BACKLOG_B" "$SC_STATE"
rc_b=$?
LOG_B="$SC_CFG/loom/automation/logs/daily-$(date +%Y-%m-%d).log"
LEDGER_B="$SC_CFG/loom/learning/$PLUGIN.json"

chk "daily-run.sh exits 0 (a conflict is requeued, not a failure)" test "$rc_b" = "0"
chk "round 1: exactly one clean merge, one genuine conflict+requeue" \
  grep -q 'round done — 1 disposed, 1 requeued, 0 no-candidate, 0 failed' "$LOG_B"
chk "the conflict was logged as an abort + requeue, not ledgered at that moment" \
  grep -q 'session sess-b-new conflicted on merge — requeued' "$LOG_B"
chk "the older session's clean merge was logged BEFORE the conflict" bash -c '
  merged_line=$(grep -n "session sess-b-old merged" "'"$LOG_B"'" | head -1 | cut -d: -f1)
  conflict_line=$(grep -n "session sess-b-new conflicted" "'"$LOG_B"'" | head -1 | cut -d: -f1)
  [ -n "$merged_line" ] && [ -n "$conflict_line" ] && [ "$merged_line" -lt "$conflict_line" ]'
chk "the aborted cherry-pick left no extra commit (exactly 1 per session survives)" \
  test "$(git -C "$SC_MKT" log --oneline | wc -l | tr -d ' ')" = "3"
chk "both sessions eventually land (retry against fresh main succeeds — by design)" \
  test "$(jq '.analyzed | length' "$LEDGER_B")" = "2"
chk "no duplicate sessionIds in analyzed[]" \
  test "$(jq -r '.analyzed[].sessionId' "$LEDGER_B" | sort | uniq -d | wc -l | tr -d ' ')" = "0"
chk "claims[] empty at the end (no leaked claim from the requeue)" \
  test "$(jq '(.claims // []) | length' "$LEDGER_B")" = "0"
chk "mkt-repo left genuinely clean (no CHERRY_PICK_HEAD, no unmerged files)" bash -c '
  ! git -C "'"$SC_MKT"'" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1 &&
  [ -z "$(git -C "'"$SC_MKT"'" ls-files --unmerged)" ] &&
  [ -z "$(git -C "'"$SC_MKT"'" status --porcelain)" ]'

assert_teardown_clean "$SC_MKT" "$PLUGIN" "scenario B"

# =================================================================================================
echo "== C. stale-claim reclaim after a simulated worker crash + the watermark guard =="
# sess-c-crash claims, then "dies" (nonzero exit, no sidecar) — its claim is left for staleness
# GC. sess-c-good (a much NEWER sessionEndTs, distinct file) disposes cleanly in the SAME round,
# which is what proves the watermark guard: the guard must hold watermark back from sess-c-good's
# newer endTs because sess-c-crash's OLDER-endTs claim is still live. Real time is not slept —
# the claim's claimedAt is backdated directly to simulate "2 x maxRunSecs elapsed", which is what
# the GC comparison actually reads; the reclaim + disposal that follows is the real code path.
new_scenario sc-c 2 2
BACKLOG_C="$ROOT/sc-c/backlog.json"
jq -n '[
  {sessionId:"sess-c-crash", sessionEndTs:"2020-01-01T00:00:00Z", editFile:"crash.txt", editContent:"crash-content", mode:"crash-once"},
  {sessionId:"sess-c-good",  sessionEndTs:"2026-03-01T00:00:00Z", editFile:"good.txt",  editContent:"good-content",  mode:"normal"}
]' > "$BACKLOG_C"

run_daily "$SC_CFG" "$BACKLOG_C" "$SC_STATE"
rc_c1=$?
LOG_ALL="$SC_CFG/loom/automation/logs/daily-$(date +%Y-%m-%d).log"
LOG_C1="$ROOT/sc-c/log-inv1.txt"; cp "$LOG_ALL" "$LOG_C1"
LEDGER_C="$SC_CFG/loom/learning/$PLUGIN.json"

chk "invocation 1 exits 1 (the crashed worker is a real, surfaced failure)" test "$rc_c1" = "1"
chk "sess-c-good disposed despite the sibling crash in the same round" \
  test "$(jq '.analyzed | length' "$LEDGER_C")" = "1"
chk "sess-c-crash's claim survives (left alone for staleness GC, not touched by merge_slot)" \
  test "$(jq -r '(.claims // [])[] | select(.sessionId=="sess-c-crash") | .sessionId' "$LEDGER_C")" = "sess-c-crash"
chk "watermark guard: held back while sess-c-crash is still claimed" \
  test "$(jq -r '.watermark // "null"' "$LEDGER_C")" = "null"
chk "drained-but-lost gate correctly withheld publish (a crashed session is still outstanding)" \
  test -z "$(grep 'publish testplugin:' "$LOG_C1")"

# --- simulate 2xmaxRunSecs elapsing: backdate the surviving claim's claimedAt past the cutoff ---
jq --arg sid "sess-c-crash" --arg t "2000-01-01T00:00:00Z" \
   '(.claims[] | select(.sessionId==$sid) | .claimedAt) = $t' "$LEDGER_C" > "$LEDGER_C.tmp" \
   && mv "$LEDGER_C.tmp" "$LEDGER_C"

run_daily "$SC_CFG" "$BACKLOG_C" "$SC_STATE"
rc_c2=$?
LOG_C2="$ROOT/sc-c/log-inv2.txt"
tail -n +"$(( $(wc -l < "$LOG_C1") + 1 ))" "$LOG_ALL" > "$LOG_C2"   # only invocation 2's new lines

chk "invocation 2 exits 0 (the reclaim + retry both succeed)" test "$rc_c2" = "0"
chk "the stale claim was reclaimed and completed this time" \
  test "$(jq -r '.analyzed[] | select(.sessionId=="sess-c-crash") | .sessionId' "$LEDGER_C")" = "sess-c-crash"
chk "both sessions analyzed, no duplicate sessionIds" \
  test "$(jq -r '.analyzed[].sessionId' "$LEDGER_C" | sort -u | wc -l | tr -d ' ')" = "2"
chk "claims[] empty once the reclaimed session disposes" \
  test "$(jq '(.claims // []) | length' "$LEDGER_C")" = "0"
chk "watermark now free to advance past the once-blocked session" \
  test "$(jq -r '.watermark' "$LEDGER_C")" != "null"
chk "invocation 2 needed just 1 round (only 1 candidate was left)" \
  test "$(grep -c 'round starting' "$LOG_C2")" = "1"

assert_teardown_clean "$SC_MKT" "$PLUGIN" "scenario C"

# =================================================================================================
echo "== D. forced cherry-pick --abort FAILURE -> FATAL halt =="
# 3 concurrent sessions: sess-d-1 (clean), sess-d-2 (conflicts with sess-d-1, and its abort is
# forced to fail via the git shim), sess-d-3 (would merge cleanly, but must NEVER be reached —
# claim_order's for-loop breaks the instant a FATAL is returned). The candidate PICK is still
# real oldest-sessionEndTs-first (unaffected — see the claimedAtOverride note above scenario B),
# but claim_order() — which decides merge/processing order, and so which position the FATAL
# lands at — sorts by claimedAt, which real concurrent claims routinely tie on (see the header
# note). Pinning claimedAtOverride to 3 distinct, ascending, near-future timestamps makes
# claim_order = [sess-d-1, sess-d-2, sess-d-3] deterministic, so "sess-d-3 is genuinely never
# reached" is a guaranteed, checkable outcome instead of a coin flip across 3 racing slots — the
# lock, the pick, and the merge/abort/FATAL machinery underneath are still the real code.
new_scenario sc-d 3 60
BACKLOG_D="$ROOT/sc-d/backlog.json"
jq -n --arg t1 "$(future_ts 1)" --arg t2 "$(future_ts 2)" --arg t3 "$(future_ts 3)" '[
  {sessionId:"sess-d-1", sessionEndTs:"2026-04-01T00:00:00Z", editFile:"shared.txt",       editContent:"content-1", mode:"normal", claimedAtOverride:$t1},
  {sessionId:"sess-d-2", sessionEndTs:"2026-04-02T00:00:00Z", editFile:"shared.txt",       editContent:"content-2", mode:"normal", claimedAtOverride:$t2},
  {sessionId:"sess-d-3", sessionEndTs:"2026-04-03T00:00:00Z", editFile:"never-reached.txt", editContent:"content-3", mode:"normal", claimedAtOverride:$t3}
]' > "$BACKLOG_D"

run_daily "$SC_CFG" "$BACKLOG_D" "$SC_STATE" 1 1   # use_shim=1, force_abort=1
rc_d=$?
LOG_D="$SC_CFG/loom/automation/logs/daily-$(date +%Y-%m-%d).log"
LEDGER_D="$SC_CFG/loom/learning/$PLUGIN.json"

chk "daily-run.sh exits 1 (a FATAL halt is a real, surfaced failure)" test "$rc_d" = "1"
chk "the FATAL halt was logged loudly" \
  grep -Eq 'FATAL: cherry-pick abort left .* dirty — halting testplugin for today' "$LOG_D"
chk "the first (not-yet-conflicting) session merged before the halt" \
  test "$(jq -r '.analyzed[0].sessionId' "$LEDGER_D")" = "sess-d-1"
chk "exactly one session merged before the halt" test "$(jq '.analyzed | length' "$LEDGER_D")" = "1"
chk "the never-reached session's file was never merged into mkt-repo" \
  test ! -e "$SC_MKT/plugins/$PLUGIN/never-reached.txt"
chk "the never-reached session's claim was left untouched (never gotten to)" \
  test "$(jq -r '(.claims // [])[] | select(.sessionId=="sess-d-3") | .sessionId' "$LEDGER_D")" = "sess-d-3"
chk "the conflicted session's claim was ALSO left untouched (FATAL returns before release)" \
  test "$(jq -r '(.claims // [])[] | select(.sessionId=="sess-d-2") | .sessionId' "$LEDGER_D")" = "sess-d-2"
chk "mkt-repo genuinely left dirty (the forced abort really never ran)" bash -c '
  git -C "'"$SC_MKT"'" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1 ||
  [ -n "$(git -C "'"$SC_MKT"'" status --porcelain)" ]'
chk "teardown still ran despite the FATAL halt (best-effort, unconditional)" \
  test "$(git -C "$SC_MKT" worktree list --porcelain | grep -c '^worktree ')" = "1"
chk "no leftover loom-learn/testplugin/* branches despite the FATAL halt" \
  test -z "$(git -C "$SC_MKT" branch --list "loom-learn/$PLUGIN/*")"

# Tidy the deliberately-stuck cherry-pick before the outer trap rm -rf's this scratch repo —
# not load-bearing (rm -rf doesn't care about git's internal state), just good hygiene.
git -C "$SC_MKT" cherry-pick --abort >/dev/null 2>&1 || true

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
