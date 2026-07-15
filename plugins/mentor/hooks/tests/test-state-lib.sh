#!/usr/bin/env bash
# test-state-lib.sh — regression tests for hooks/lib/state.sh (v2.0.0).
#
# The lib backs every hook, so it gets its own suite: project-scoped state-dir
# derivation (<repo>/.mentor), `set -e` caller safety (sourced functions must never
# abort a set -e hook), the config/mode readers, the .gitignore bootstrap, and the
# context-gate helpers (threshold precedence, kill switch, token extraction).
#
# Runs against a SANDBOX $HOME so it never touches real user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$(dirname "$SCRIPT_DIR")/lib/state.sh"
[ -f "$LIB" ] || { echo "FATAL: lib not found at $LIB" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
# Run a snippet with the lib sourced, sandbox HOME, under set -euo pipefail (the
# caller contract). Echoes the snippet's stdout; non-zero rc = the snippet aborted.
libsh() { HOME="$SANDBOX" bash -c "set -euo pipefail; . '$LIB'; $1"; }

echo "== A. Project-scoped state-dir derivation (<repo>/.mentor) =="
old_root() {
  local gc abs
  gc="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null || true)"
  [ -z "$gc" ] && { echo ""; return 0; }
  case "$gc" in /*) abs="$gc";; *) abs="$1/$gc";; esac
  cd "$(dirname "$abs")" && pwd
}
expect_root="$(old_root "$REPO")"
got_root="$(libsh "mentor_repo_root '$REPO'")"
chk "repo root matches inline derivation" test "$got_root" = "$expect_root"
got_state="$(libsh "mentor_state_dir '$expect_root'")"
chk "state dir is <repo_root>/.mentor" test "$got_state" = "$expect_root/.mentor"
got_plans="$(libsh "mentor_plans_dir '$expect_root'")"
chk "plans dir is {state}/plans" test "$got_plans" = "$got_state/plans"
chk "no repo → empty root" test -z "$(libsh "mentor_repo_root '$NONGIT'")"
chk "empty root → empty state dir" test -z "$(libsh "mentor_state_dir ''")"
chk "empty root → empty plans dir" test -z "$(libsh "mentor_plans_dir ''")"

echo "== B. Linked worktrees share one state dir =="
WT="$ROOT/linked-wt"
git -C "$REPO" worktree add -q "$WT" -b wt-branch >/dev/null 2>&1
wt_root="$(libsh "mentor_repo_root '$WT'")"
chk "linked worktree resolves to main repo root" test "$wt_root" = "$expect_root"

echo "== C. set -e caller safety (functions must not abort the hook) =="
chk "mentor_get_mode on nonexistent root" \
  libsh 'm="$(mentor_get_mode /nonexistent/path)"; [ -z "$m" ]; echo done >/dev/null'
chk "mentor_get_mode with no config"      libsh 'm="$(mentor_get_mode "'"$expect_root"'")"; [ -z "$m" ]'
chk "mentor_config_get bad input"         libsh 'v="$(mentor_config_get "" "")"; [ -z "$v" ]'
chk "mentor_context_tokens no file"       libsh 'v="$(mentor_context_tokens /nope.jsonl)"; [ -z "$v" ]'
chk "mentor_context_gate_state no repo"   libsh 's="$(mentor_context_gate_state "")"; [ "$s" = "on" ]'
chk "mentor_ensure_gitignore empty"       libsh 'mentor_ensure_gitignore ""; echo ok >/dev/null'
chk "mentor_cwd on empty input"           libsh 'c="$(mentor_cwd "")"; [ -n "$c" ]'
chk "mentor_cwd on garbage input"         libsh 'c="$(mentor_cwd "not json")"; [ -n "$c" ]'
chk "mentor_cwd extracts cwd"             libsh 'c="$(mentor_cwd "{\"cwd\":\"/tmp/x\"}")"; [ "$c" = "/tmp/x" ]'

echo "== D. mentor_get_mode / mentor_config_get =="
STATE="$expect_root/.mentor"
RCONF="$STATE/config.json"
mkdir -p "$STATE"
printf '{"mode": "plan"}\n'      > "$RCONF"
chk "mode=plan read back"      test "$(libsh "mentor_get_mode '$expect_root'")" = "plan"
printf '{"mode": "plan-only"}\n' > "$RCONF"
chk "mode=plan-only read back" test "$(libsh "mentor_get_mode '$expect_root'")" = "plan-only"
printf '{"other": 1}\n'          > "$RCONF"
chk "absent mode key → empty"  test -z "$(libsh "mentor_get_mode '$expect_root'")"
printf '{"context_block_tokens": 300000, "context_gate": "off"}\n' > "$RCONF"
chk "config_get numeric coerced to string" test "$(libsh "mentor_config_get '$expect_root' context_block_tokens")" = "300000"
chk "config_get string value"              test "$(libsh "mentor_config_get '$expect_root' context_gate")" = "off"
chk "config_get missing key → empty"       test -z "$(libsh "mentor_config_get '$expect_root' nope")"
rm -f "$RCONF"
chk "no config file → empty mode"   test -z "$(libsh "mentor_get_mode '$expect_root'")"

echo "== E. mentor_context_threshold precedence (env > config > default) =="
printf '{"context_block_tokens": 250000}\n' > "$RCONF"
chk "config wins over default"  test "$(libsh "mentor_context_threshold '$expect_root' '' context_block_tokens 270000")" = "250000"
chk "env wins over config"      test "$(libsh "mentor_context_threshold '$expect_root' 999 context_block_tokens 270000")" = "999"
chk "non-numeric env falls through to config" test "$(libsh "mentor_context_threshold '$expect_root' abc context_block_tokens 270000")" = "250000"
rm -f "$RCONF"
chk "no env/config → default"   test "$(libsh "mentor_context_threshold '$expect_root' '' context_block_tokens 270000")" = "270000"

echo "== F. mentor_context_gate_state kill switch =="
chk "env off"          test "$(libsh "MENTOR_CONTEXT_GATE=off mentor_context_gate_state '$expect_root'")" = "off"
chk "env 0"            test "$(libsh "MENTOR_CONTEXT_GATE=0 mentor_context_gate_state '$expect_root'")" = "off"
printf '{"context_gate": "off"}\n' > "$RCONF"
chk "config off"       test "$(libsh "mentor_context_gate_state '$expect_root'")" = "off"
printf '{"context_gate": "on"}\n' > "$RCONF"
chk "config on → on"   test "$(libsh "mentor_context_gate_state '$expect_root'")" = "on"
rm -f "$RCONF"

echo "== G. mentor_ensure_gitignore (commit config.json + constitution.md; idempotent) =="
GI="$STATE/.gitignore"
rm -f "$GI"
libsh "mentor_ensure_gitignore '$STATE'"
chk ".gitignore created"                     test -f "$GI"
chk ".gitignore ignores everything (*)"       grep -qx '\*' "$GI"
chk ".gitignore un-ignores config.json"       grep -qx '!config.json' "$GI"
chk ".gitignore un-ignores constitution.md"   grep -qx '!constitution.md' "$GI"
printf 'CUSTOM\n' > "$GI"
libsh "mentor_ensure_gitignore '$STATE'"
chk "never overwrites an existing .gitignore"  test "$(cat "$GI")" = "CUSTOM"

echo "== H. mentor_context_tokens extraction =="
TX="$ROOT/tx.jsonl"
python3 - "$TX" <<'PY'
import json,sys
lines=[
 {"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":100000,"cache_creation_input_tokens":8000}}},
 {"type":"assistant","isSidechain":True,"message":{"usage":{"input_tokens":5,"cache_read_input_tokens":5,"cache_creation_input_tokens":5}}},
 {"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}},
]
open(sys.argv[1],"w").write("\n".join(json.dumps(l) for l in lines)+"\n")
PY
chk "sums input+cache, skips sidechain + <synthetic>" test "$(libsh "mentor_context_tokens '$TX'")" = "108010"
python3 - "$TX" <<'PY'
import json,sys
lines=[
 {"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":228000,"cache_creation_input_tokens":0}}},
 {"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":7000}},
]
open(sys.argv[1],"w").write("\n".join(json.dumps(l) for l in lines)+"\n")
PY
chk "compact_boundary postTokens wins after usage" test "$(libsh "mentor_context_tokens '$TX'")" = "7000"
printf 'not json\n{"type":"user"}\n' > "$TX"
chk "no usage record → empty" test -z "$(libsh "mentor_context_tokens '$TX'")"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
