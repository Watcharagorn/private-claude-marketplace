#!/usr/bin/env bash
# test-context-gate.sh — regression tests for context-gate.sh (UserPromptSubmit) and
# begin-plan.sh's plan-start context check (v2.0.0).
#
# Builds a real git repo (project-scoped .mentor/ state) and a set of transcript
# fixtures, then drives the hook with UserPromptSubmit JSON across the full tier
# matrix: passthroughs, kill switch, threshold precedence, once-per-session warn,
# block, transcript extraction edge cases, and fail-soft robustness.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
HOOK="$HOOKS/context-gate.sh"
BEGIN="$HOOKS/begin-plan.sh"
for f in "$HOOK" "$BEGIN"; do [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }; done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
STATE="$REPO/.mentor"; mkdir -p "$STATE"
CONF="$STATE/config.json"
ERRFILE="$ROOT/err"
BASH_BIN="$(command -v bash)"
NOJQ_DIR="$ROOT/nojq"; mkdir -p "$NOJQ_DIR"   # empty PATH dir → `command -v jq` fails

trap 'rm -rf "$ROOT"' EXIT

# Transcript builder (all fixture kinds live in one python script).
BUILDER="$ROOT/build.py"
cat > "$BUILDER" <<'PY'
import json,sys
f=sys.argv[1]; parts=sys.argv[2].split(":"); kind=parts[0]
def au(t): return {"type":"assistant","message":{"usage":{"input_tokens":t,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
def side(t): return {"type":"assistant","isSidechain":True,"message":{"usage":{"input_tokens":t,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
def synth(): return {"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
def compact(p): return {"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":p}}
K={
 "usage": lambda: [au(int(parts[1]))],
 "sidechain_mask": lambda: [au(int(parts[1])), side(3), side(4)],
 "all_sidechain": lambda: [side(3), side(4)],
 "compact_after": lambda: [au(int(parts[1])), compact(int(parts[2]))],
 "usage_after_compact": lambda: [compact(6000), au(int(parts[1]))],
 "garbage": lambda: ["GARBAGE NOT JSON", au(int(parts[1])), "{broken json"],
 "usageless": lambda: [{"type":"assistant","message":{"content":"no usage"}}, au(int(parts[1]))],
 "synthetic_trailing": lambda: [au(int(parts[1])), synth(), synth()],
 "no_assistant": lambda: [{"type":"user","message":{"content":"hi"}}, {"type":"system","subtype":"other"}],
}
lines=K[kind]()
with open(f,"w") as fh:
    for l in lines: fh.write((l if isinstance(l,str) else json.dumps(l))+"\n")
PY
mktx() { python3 "$BUILDER" "$1" "$2"; }

# Standard fixtures.
TX_UNDER="$ROOT/under.jsonl";  mktx "$TX_UNDER" usage:150000
TX_WARN="$ROOT/warn.jsonl";    mktx "$TX_WARN"  usage:215000
TX_BLOCK="$ROOT/block.jsonl";  mktx "$TX_BLOCK" usage:285000
TX_NONE="$ROOT/missing.jsonl"  # deliberately not created

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
contains() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
mkinput() { python3 -c 'import json,sys;print(json.dumps({"prompt":sys.argv[1],"transcript_path":sys.argv[2],"cwd":sys.argv[3],"session_id":sys.argv[4]}))' "$1" "$2" "$3" "$4"; }

# run <prompt> <session> <transcript> [env=val ...] → sets RC / OUT / ERR
run() {
  local prompt="$1" sess="$2" tx="$3"; shift 3
  RC=0
  OUT="$(mkinput "$prompt" "$tx" "$REPO" "$sess" \
    | env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_WARN_TOKENS -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_TAIL_LINES "$@" bash "$HOOK" 2>"$ERRFILE")" || RC=$?
  ERR="$(cat "$ERRFILE")"
}
# run_nojq: same, but with a PATH where jq cannot be found. Input is fed from a FILE
# (not a pipe): the hook exits at the `command -v jq` guard before reading stdin, so a
# pipe would hand its producer a BrokenPipe that pipefail then surfaces as the rc.
run_nojq() {
  local prompt="$1" sess="$2" tx="$3"
  mkinput "$prompt" "$tx" "$REPO" "$sess" > "$ROOT/in.json"
  RC=0
  OUT="$(PATH="$NOJQ_DIR" "$BASH_BIN" "$HOOK" < "$ROOT/in.json" 2>"$ERRFILE")" || RC=$?
  ERR="$(cat "$ERRFILE")"
}
marker() { echo "$STATE/.context-warned-$1"; }

echo "== A. Baseline (fail-soft, quiet) =="
run "hello" a1 "$TX_UNDER"
chk "under-warn → exit 0"        test "$RC" = "0"
chk "under-warn → silent"        test -z "$OUT$ERR"
run "hello" a2 "$TX_NONE"
chk "missing transcript → exit 0" test "$RC" = "0"
chk "missing transcript → silent" test -z "$OUT$ERR"
mktx "$ROOT/na.jsonl" no_assistant
run "hello" a3 "$ROOT/na.jsonl"
chk "no usable usage → exit 0"   test "$RC" = "0"

echo "== B. Warn tier (once per session) =="
run "hello" warnsess "$TX_WARN"
chk "215k → exit 0"              test "$RC" = "0"
chk "215k → warn notice on stdout" contains "getting large" "$OUT"
chk "215k → warn marker created"   test -e "$(marker warnsess)"
run "hello again" warnsess "$TX_WARN"
chk "same session → silent"        test -z "$OUT"
chk "same session → still exit 0"  test "$RC" = "0"
run "hello" warnsess2 "$TX_WARN"
chk "new session → warns again"    contains "getting large" "$OUT"

echo "== B2. Warn-high tier (near-limit, re-fires) =="
TX_HIGH="$ROOT/high.jsonl"; mktx "$TX_HIGH" usage:250000   # ≥ 243000 (90% of 270k), < 270000
run "hello" hi1 "$TX_HIGH"
chk "250k → exit 0"                          test "$RC" = "0"
chk "250k → near-limit notice"               contains "close to the BLOCK" "$OUT"
run "hello again" hi1 "$TX_HIGH"
chk "same session → re-fires (no marker)"    contains "close to the BLOCK" "$OUT"
printf '{"context_warn_high_tokens":100000}\n' > "$CONF"
run "hello" hi2 "$TX_UNDER"
chk "config context_warn_high_tokens honored (150k ≥ 100k)" contains "close to the BLOCK" "$OUT"
rm -f "$CONF"

echo "== C. Block tier =="
run "please do a thing" blk1 "$TX_BLOCK"
chk "285k plain prompt → exit 2"   test "$RC" = "2"
chk "285k → stderr names /mentor:handoff" contains "/mentor:handoff" "$ERR"
chk "285k → nothing on stdout"     test -z "$OUT"
run "/mentor:handoff \"x\"" blk2 "$TX_BLOCK"
chk "slash /mentor:handoff passes" test "$RC" = "0"
run "/compact" blk3 "$TX_BLOCK"
chk "slash /compact passes"        test "$RC" = "0"
run "" blk4 "$TX_BLOCK"
chk "empty prompt passes"          test "$RC" = "0"
# Harness-synthetic prompts at block level: measured but NEVER erased.
run "<task-notification>reviewer finished: verdict Approved</task-notification>" blk5 "$TX_BLOCK"
chk "synthetic task-notification at 285k → exit 0 (never erased)" test "$RC" = "0"
chk "synthetic at 285k → loud advisory on stdout" contains "NOT blocked" "$OUT"
run "<agent-message from=\"step6-docs\">fix summary body</agent-message>" blk6 "$TX_BLOCK"
chk "synthetic agent-message at 285k → exit 0"    test "$RC" = "0"
run "<teammate-message>idle ping</teammate-message>" blk7 "$TX_BLOCK"
chk "synthetic teammate-message at 285k → exit 0" test "$RC" = "0"

echo "== D. Kill switch =="
run "do thing" ks1 "$TX_BLOCK" MENTOR_CONTEXT_GATE=off
chk "env MENTOR_CONTEXT_GATE=off → exit 0" test "$RC" = "0"
chk "env off → silent"                     test -z "$OUT$ERR"
printf '{"context_gate":"off"}\n' > "$CONF"
run "do thing" ks2 "$TX_BLOCK"
chk "config context_gate=off → exit 0"     test "$RC" = "0"
rm -f "$CONF"

echo "== E. Threshold precedence (env > config > default) =="
run "do thing" p1 "$TX_UNDER" MENTOR_CONTEXT_BLOCK_TOKENS=1000
chk "env lowers block → 2"                 test "$RC" = "2"
printf '{"context_block_tokens":1000}\n' > "$CONF"
run "do thing" p2 "$TX_UNDER"
chk "config lowers block → 2"              test "$RC" = "2"
printf '{"context_block_tokens":999999999}\n' > "$CONF"
run "do thing" p3 "$TX_UNDER" MENTOR_CONTEXT_BLOCK_TOKENS=1000
chk "env beats config → 2"                 test "$RC" = "2"
rm -f "$CONF"
run "do thing" p4 "$TX_UNDER" MENTOR_CONTEXT_BLOCK_TOKENS=abc
chk "non-numeric env → default (150k<270k, no block)" test "$RC" = "0"

echo "== F. Transcript extraction edge cases (block-level unless noted) =="
mktx "$ROOT/sm.jsonl" sidechain_mask:285000
run "do thing" f1 "$ROOT/sm.jsonl"
chk "trailing sidechain doesn't mask 285k → 2" test "$RC" = "2"
mktx "$ROOT/as.jsonl" all_sidechain
run "do thing" f2 "$ROOT/as.jsonl"
chk "all-sidechain → unmeasurable → exit 0"    test "$RC" = "0"
mktx "$ROOT/ca.jsonl" compact_after:285000:5000
run "do thing" f3 "$ROOT/ca.jsonl"
chk "compact_boundary(5000) after 285k → exit 0" test "$RC" = "0"
mktx "$ROOT/uac.jsonl" usage_after_compact:285000
run "do thing" f4 "$ROOT/uac.jsonl"
chk "usage after compact → 2"                  test "$RC" = "2"
mktx "$ROOT/gb.jsonl" garbage:285000
run "do thing" f5 "$ROOT/gb.jsonl"
chk "garbage lines interleaved → 2"            test "$RC" = "2"
mktx "$ROOT/ul.jsonl" usageless:285000
run "do thing" f6 "$ROOT/ul.jsonl"
chk "usage-less assistant skipped → 2"         test "$RC" = "2"
mktx "$ROOT/syn.jsonl" synthetic_trailing:285000
run "do thing" f7 "$ROOT/syn.jsonl"
chk "trailing <synthetic> all-zero after 285k → 2" test "$RC" = "2"

echo "== G. Robustness =="
run_nojq "do thing" g1 "$TX_BLOCK"
chk "no jq on PATH → exit 0"        test "$RC" = "0"
chk "no jq → silent"               test -z "$OUT$ERR"
# 25h-old warn marker is pruned → warn re-fires.
run "hello" prune "$TX_WARN"        # create marker
touch -t "$(date -v-25H +%Y%m%d%H%M 2>/dev/null || date -d '25 hours ago' +%Y%m%d%H%M)" "$(marker prune)" 2>/dev/null || true
run "hello" prune "$TX_WARN"
chk "25h-old marker pruned → warn re-fires" contains "getting large" "$OUT"

echo "== H. begin-plan.sh plan-start check (CLAUDE_CONFIG_DIR + CLAUDE_CODE_SESSION_ID fixtures) =="
CFG="$ROOT/cfg"; mkdir -p "$CFG/projects/proj"
SESS="begin-sess"
bp() { # <transcript-tokens|none> → sets RC/OUT; cleans marker first
  rm -f "$STATE/plans/.planning"
  local toks="$1"
  if [ "$toks" = "none" ]; then rm -f "$CFG/projects/proj/$SESS.jsonl"
  else mktx "$CFG/projects/proj/$SESS.jsonl" "usage:$toks"; fi
  RC=0
  OUT="$( cd "$REPO" && env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
      CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SESS" bash "$BEGIN" 2>&1 )" || RC=$?
}
bp 300000
chk "over-block → CONTEXT: BLOCKED printed"  contains "CONTEXT: BLOCKED" "$OUT"
chk "over-block → .planning NOT created"     test ! -f "$STATE/plans/.planning"
chk "over-block → not armed"                 sh -c '! printf "%s" "$1" | grep -q "Plan phase ARMED"' _ "$OUT"
bp 230000
chk "warn → armed + CONTEXT: WARN"           contains "CONTEXT: WARN" "$OUT"
chk "warn → .planning created"               test -f "$STATE/plans/.planning"
bp none
chk "no transcript → arms silently (no CONTEXT line)" sh -c '! printf "%s" "$1" | grep -q "CONTEXT:"' _ "$OUT"
chk "no transcript → armed"                  test -f "$STATE/plans/.planning"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
