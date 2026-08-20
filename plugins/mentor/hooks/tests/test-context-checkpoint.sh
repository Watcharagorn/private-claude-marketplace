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

# run <session> <transcript> [env overrides...] — drives the hook; captures stdout+rc.
run() {
  local sid="$1" tx="$2"; shift 2
  OUT="$(printf '{"transcript_path":"%s","session_id":"%s","cwd":"%s"}' "$tx" "$sid" "$REPO" \
        | env "$@" bash "$HOOK" 2>>"$ROOT/err")"; RC=$?
}
ctx() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

echo "== A. tiers speak, advisory-only (exit 0 everywhere) =="
run s-a "$TX_UNDER"
chk "under warn → silent"            test "$RC" = "0" -a -z "$OUT"
run s-a "$TX_WARN"
chk "warn tier → exit 0"             test "$RC" = "0"
chk "warn tier → valid JSON payload" sh -c "printf '%s' \"\$0\" | jq -e '.hookSpecificOutput.hookEventName == \"PostToolBatch\"'" "$OUT"
chk "warn text names the boundary"   sh -c "printf '%s' \"\$0\" | grep -q 'natural step boundary'" "$(ctx)"
run s-b "$TX_HIGH"
chk "warn-high tier → exit 0"        test "$RC" = "0"
chk "warn-high text steers"          sh -c "printf '%s' \"\$0\" | grep -q 'nearing the handoff threshold'" "$(ctx)"
run s-c "$TX_ASK"
chk "ask tier → exit 0 (NEVER 2)"    test "$RC" = "0"
chk "ask text directs end-the-turn"  sh -c "printf '%s' \"\$0\" | grep -q 'END THE TURN'" "$(ctx)"
chk "ask text names failed --note"   sh -c "printf '%s' \"\$0\" | grep -q 'failed --note'" "$(ctx)"

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

echo "== C. ask-tier degradation: session bypass marker → milder advisory =="
touch "$STATE/.context-bypass-s-d"
run s-d "$TX_ASK"
chk "bypassed → exit 0"              test "$RC" = "0"
chk "bypassed → no END THE TURN directive" sh -c "! printf '%s' \"\$0\" | grep -q 'END THE TURN'" "$(ctx)"
chk "bypassed → still names handoff" sh -c "printf '%s' \"\$0\" | grep -q 'mentor:handoff'" "$(ctx)"

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
chk "lowered thresholds → ask tier at 150k" sh -c "printf '%s' \"\$0\" | grep -q 'END THE TURN'" "$(ctx)"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
