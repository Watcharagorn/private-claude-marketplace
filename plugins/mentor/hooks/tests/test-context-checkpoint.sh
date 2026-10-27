#!/usr/bin/env bash
# test-context-checkpoint.sh — regression tests for context-checkpoint.sh
# (PostToolBatch, v2.37.0): the mid-run context reading context-gate.sh cannot take.
#
# The contract under test, in order of what it would cost to lose:
#   1. ADVISORY ONLY — the hook must NEVER exit non-zero on a measurable transcript:
#      on PostToolBatch, exit 2 stops the agentic loop dead, which is exactly the
#      trade the 2026-08-20 ruling rejected. Every tier asserts exit 0.
#   2. It speaks through hookSpecificOutput.additionalContext (valid JSON), not bare
#      stdout, and only when the tier rose or the count grew past the re-arm delta —
#      a batch-frequency hook that spoke every batch would bury the transcript.
#   3. Fail-soft: garbage input, missing transcript, no jq → silent exit 0.
#   4. Both kill switches work and are distinct: the gate's own, and its own
#      MENTOR_CONTEXT_CHECKPOINT / "context_checkpoint" — off just this hook while
#      the per-prompt gate keeps running.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
HOOK="$HOOKS/context-checkpoint.sh"
[ -f "$HOOK" ] || { echo "FATAL: not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
STATE="$REPO/.mentor"; mkdir -p "$STATE"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ok   $d"; else FAIL=$((FAIL+1)); echo "  FAIL $d"; fi; }

# Transcript fixture: one assistant usage record at the requested size.
mktx() {
  python3 - "$1" "$2" <<'PY'
import json,sys
with open(sys.argv[1],"w") as fh:
    fh.write(json.dumps({"type":"assistant","message":{"usage":{"input_tokens":int(sys.argv[2]),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}})+"\n")
PY
}
TX_UNDER="$ROOT/under.jsonl"; mktx "$TX_UNDER" 150000
TX_WARN="$ROOT/warn.jsonl";   mktx "$TX_WARN"  215000
TX_GROW="$ROOT/grow.jsonl";   mktx "$TX_GROW"  270000   # +55k over TX_WARN: past the 50k delta
TX_HIGH="$ROOT/high.jsonl";   mktx "$TX_HIGH"  320000   # ≥ 90% of 350k → WARN-HIGH tier
TX_ASK="$ROOT/ask.jsonl";     mktx "$TX_ASK"   365000

# Pin the environment: a developer's own MENTOR_CONTEXT_* or a host-reported window must
# not move an assertion; MENTOR_STATE_HOME keeps the session-dir window lookup sandboxed.
STATE_HOME="$ROOT/state-home"
PIN_ENV=(-u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_CHECKPOINT -u MENTOR_CONTEXT_WARN_TOKENS
  -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_HIGH_TOKENS -u MENTOR_CONTEXT_TAIL_LINES
  -u MENTOR_CONTEXT_WINDOW -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u MENTOR_CONTEXT_WARN_RATIO
  -u MENTOR_CONTEXT_HIGH_RATIO -u CLAUDE_CONFIG_DIR -u XDG_STATE_HOME -u MENTOR_STATE_HOME)

# run <session> <transcript> [env overrides...] — drives the hook; captures stdout+rc.
run() {
  local sid="$1" tx="$2"; shift 2
  OUT="$(printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' "$tx" "$sid" "$REPO" \
        | env "${PIN_ENV[@]}" MENTOR_STATE_HOME="$STATE_HOME" "$@" bash "$HOOK" 2>>"$ROOT/err")"; RC=$?
}
ctx() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

echo "== A. tiers speak, advisory-only (exit 0 everywhere) =="
run s-a "$TX_UNDER"
chk "under warn → silent"            test "$RC" = "0" -a -z "$OUT"
run s-a "$TX_WARN"
chk "warn tier → exit 0"             test "$RC" = "0"
chk "warn tier → valid JSON payload" sh -c "printf '%s' \"\$0\" | jq -e '.hookSpecificOutput.hookEventName == \"PostToolBatch\"'" "$OUT"
chk "warn text says still mid-run"   sh -c "printf '%s' \"\$0\" | grep -q 'still mid-run'" "$(ctx)"
run s-b "$TX_HIGH"
chk "warn-high tier → exit 0"        test "$RC" = "0"
chk "warn-high text warns"           sh -c "printf '%s' \"\$0\" | grep -q 'nearing the limit'" "$(ctx)"
run s-c "$TX_ASK"
chk "high tier → exit 0 (NEVER 2)"   test "$RC" = "0"
chk "high text warns over the limit" sh -c "printf '%s' \"\$0\" | grep -q 'over the limit'" "$(ctx)"
# v4.2.0 warn-only: no tier steers toward a handoff or ends the turn.
for tx in "$TX_WARN" "$TX_HIGH" "$TX_ASK"; do
  rm -f "$STATE"/.context-checkpoint-s-nh
  run s-nh "$tx"
  chk "no handoff/end-turn steer ($(basename "$tx"))" sh -c "! printf '%s' \"\$0\" | grep -qi 'handoff\|mentor:resume\|END THE TURN'" "$(ctx)"
done

echo "== B. rate limit: same tier + small growth stays silent; re-fires on delta or rise =="
run s-r "$TX_WARN"
chk "first warn fires"               test -n "$OUT"
run s-r "$TX_WARN"
chk "same size again → silent"       test "$RC" = "0" -a -z "$OUT"
run s-r "$TX_GROW"
chk "growth past delta → re-fires"   test -n "$OUT"
run s-r "$TX_GROW"
chk "..then silent again"            test -z "$OUT"
run s-r "$TX_ASK"
chk "tier rise → fires despite delta bookkeeping" test -n "$OUT"
chk "marker written per session"     test -e "$STATE/.context-checkpoint-s-r"

echo "== C. a leftover pre-v4.2.0 bypass marker changes nothing =="
touch "$STATE/.context-bypass-s-d"
run s-d "$TX_ASK"
chk "legacy bypass marker → exit 0"   test "$RC" = "0"
chk "legacy bypass marker → same high warning" sh -c "printf '%s' \"\$0\" | grep -q 'over the limit'" "$(ctx)"

echo "== D. kill switches (distinct) =="
run s-k1 "$TX_ASK" MENTOR_CONTEXT_GATE=off
chk "gate kill switch → silent"      test "$RC" = "0" -a -z "$OUT"
run s-k2 "$TX_ASK" MENTOR_CONTEXT_CHECKPOINT=off
chk "checkpoint kill switch → silent" test "$RC" = "0" -a -z "$OUT"
jq -n '{context_checkpoint:"off"}' > "$STATE/config.json"
run s-k3 "$TX_ASK"
chk "config context_checkpoint=off → silent" test "$RC" = "0" -a -z "$OUT"
rm -f "$STATE/config.json"

echo "== E. fail-soft =="
OUT="$(printf 'NOT JSON' | bash "$HOOK" 2>>"$ROOT/err")"; RC=$?
chk "garbage stdin → exit 0, silent" test "$RC" = "0" -a -z "$OUT"
run s-f "$ROOT/no-such-transcript.jsonl"
chk "missing transcript → exit 0, silent" test "$RC" = "0" -a -z "$OUT"
OUT="$(printf '{}' | bash "$HOOK" 2>>"$ROOT/err")"; RC=$?
chk "empty payload → exit 0, silent" test "$RC" = "0" -a -z "$OUT"

echo "== F. threshold overrides flow through =="
run s-g "$TX_UNDER" MENTOR_CONTEXT_WARN_TOKENS=100000 MENTOR_CONTEXT_BLOCK_TOKENS=140000
chk "lowered thresholds → high tier at 150k" sh -c "printf '%s' \"\$0\" | grep -q 'over the limit'" "$(ctx)"
# v4.3.0 clamp: a limit set under the warn cap pulls warn down with it. Before, the hook
# exited at the warn check (150k < 200k) and a 150k session over a 140k limit heard nothing.
run s-g2 "$TX_UNDER" MENTOR_CONTEXT_BLOCK_TOKENS=140000
chk "limit alone under the warn cap → high tier at 150k" sh -c "printf '%s' \"\$0\" | grep -q 'over the limit'" "$(ctx)"

echo "== G. known window (v4.3.0): ratio thresholds, percent text, re-arm step =="
PROGRESS_LINE="Before compacting, record your progress in the plan: finished steps, what's in flight, findings, the exact next action. The summary is lossy; the plan is not."
has() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
TX_105="$ROOT/w105.jsonl"; mktx "$TX_105" 105000
TX_95="$ROOT/w95.jsonl";   mktx "$TX_95"  95000
run s-w0 "$TX_95" MENTOR_CONTEXT_WINDOW=200000
chk "200k window, 95k → silent"                     test "$RC" = "0" -a -z "$OUT"
run s-w1 "$TX_105" MENTOR_CONTEXT_WINDOW=200000
chk "200k window, 105k → warn tier, exit 0"         test "$RC" = "0"
chk "200k window, 105k → ~N tokens (r% of window)"  has "~105000 tokens (52% of window)" "$(ctx)"
run s-w2 "$TX_UNDER" MENTOR_CONTEXT_WINDOW=200000
chk "200k window, 150k → over the 130000 limit"     has "over the limit" "$(ctx)"
chk "200k window, 150k → % of window"               has "(75% of window)" "$(ctx)"
# The session dir's context-window file, keyed by the hook's own session_id.
mkdir -p "$STATE_HOME/sessions/s-wf"; echo 200000 > "$STATE_HOME/sessions/s-wf/context-window"
run s-wf "$TX_105"
chk "session context-window file → warns at 105k"   has "(52% of window)" "$(ctx)"
# Re-arm step is 10% of a known window: +55k at 1M stays quiet (it re-fired at +50k before).
run s-w3 "$TX_WARN" MENTOR_CONTEXT_WINDOW=1000000
chk "1M window, 215k → warns at the 200k cap"       test -n "$OUT"
run s-w3 "$TX_GROW" MENTOR_CONTEXT_WINDOW=1000000
chk "1M window, +55k → silent (re-arm 100000)"      test "$RC" = "0" -a -z "$OUT"
# No window → today's thresholds and no percent text.
run s-w4 "$TX_105"
chk "no window, 105k → silent (today's 200k warn)"  test "$RC" = "0" -a -z "$OUT"
run s-w5 "$TX_WARN"
chk "no window → no percent text"                   sh -c "! printf '%s' \"\$0\" | grep -q '% of window'" "$(ctx)"

echo "== H. progress-first line on every tier =="
for tx in "$TX_WARN" "$TX_HIGH" "$TX_ASK"; do
  rm -f "$STATE"/.context-checkpoint-s-pf
  run s-pf "$tx"
  chk "progress-first line ($(basename "$tx"))"     has "$PROGRESS_LINE" "$(ctx)"
done

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
