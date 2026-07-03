#!/usr/bin/env bash
# test-orchestrator.sh — regression tests for set-orchestrator.sh (v0.37).
#
# Covers: repo on/off/clear, --global on/off/clear, status output, the merge-safe
# create paths (set-orchestrator must NOT clobber a concurrently-present .mode, and
# set-mode must not clobber .orchestrator), end-to-end precedence (repo off beats
# global on; repo clear re-inherits global), and the no-repo guard for repo scope.
#
# Runs against a SANDBOX $HOME so it never touches real user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
SO="$HOOKS/set-orchestrator.sh"
SM="$HOOKS/set-mode.sh"
for f in "$SO" "$SM"; do [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }; done

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"
trap 'rm -rf "$ROOT"' EXIT

repo_root="$(cd "$REPO" && pwd -P)"
repo_base="$(basename "$repo_root")"
repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
RCONF="$SANDBOX/.claude/mentor/${repo_base}-${repo_hash}/config.json"
GCONF="$SANDBOX/.claude/mentor/config.json"

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
# set-orchestrator.sh in the repo, sandbox HOME; echo stdout+stderr, swallow rc into $RC.
RC=0
so() { RC=0; ( cd "$REPO" && HOME="$SANDBOX" bash "$SO" "$@" 2>&1 ); RC=$?; }
sm() { ( cd "$REPO" && HOME="$SANDBOX" bash "$SM" "$@" 2>&1 ); }
rval() { jq -r 'if has("orchestrator") then (.orchestrator|tostring) else "unset" end' "$RCONF" 2>/dev/null || echo "nofile"; }
gval() { jq -r 'if has("orchestrator") then (.orchestrator|tostring) else "unset" end' "$GCONF" 2>/dev/null || echo "nofile"; }
reset_all() { rm -rf "$SANDBOX/.claude/mentor"; }

echo "== A. repo on / off / clear =="
reset_all
out="$(so on)"
chk "repo on → exit 0"          test "$RC" = "0"
chk "repo on → orchestrator true" test "$(rval)" = "true"
chk "repo on → reports ON"      sh -c "printf '%s' \"\$0\" | grep -q 'orchestrator: ON'" "$out"
so off >/dev/null
chk "repo off → orchestrator false (explicit)" test "$(rval)" = "false"
so clear >/dev/null
chk "repo clear → key deleted (unset)" test "$(rval)" = "unset"

echo "== B. --global on / off =="
reset_all
so on --global >/dev/null
chk "global on → global true"   test "$(gval)" = "true"
chk "global on → repo untouched" test "$(rval)" = "nofile"
so off --global >/dev/null
chk "global off → global false" test "$(gval)" = "false"

echo "== C. precedence end-to-end (repo overrides global; clear re-inherits) =="
reset_all
so on --global >/dev/null
out="$(so status)"
chk "global ON, repo unset → resolved ON" sh -c "printf '%s' \"\$0\" | grep -q 'orchestrator: ON'" "$out"
so off >/dev/null            # explicit repo off
out="$(so status)"
chk "repo off beats global on → resolved OFF" sh -c "printf '%s' \"\$0\" | grep -qE 'orchestrator: OFF.*winning scope: repo'" "$out"
so clear >/dev/null          # re-inherit global
out="$(so status)"
chk "repo clear → re-inherits global ON" sh -c "printf '%s' \"\$0\" | grep -qE 'orchestrator: ON.*winning scope: global'" "$out"

echo "== D. merge-safe create paths (no clobber across the two writers) =="
reset_all
sm plan >/dev/null           # creates {"mode":"plan"} first
so on >/dev/null             # must MERGE, not truncate
chk "set-orch keeps .mode"      test "$(jq -r .mode "$RCONF")" = "plan"
chk "set-orch sets .orchestrator" test "$(rval)" = "true"
reset_all
so on >/dev/null             # creates {"orchestrator":true} first (jq -n, not printf)
sm plan-only >/dev/null      # must MERGE, not truncate
chk "set-mode keeps .orchestrator" test "$(rval)" = "true"
chk "set-mode sets .mode"       test "$(jq -r .mode "$RCONF")" = "plan-only"

echo "== E. legacy migration on first call =="
reset_all
mkdir -p "$(dirname "$RCONF")"
printf '{"mode":"commander"}\n' > "$RCONF"
so status >/dev/null
chk "legacy commander migrated → mode=plan" test "$(jq -r .mode "$RCONF")" = "plan"
chk "legacy commander migrated → orchestrator=true" test "$(rval)" = "true"

echo "== F. no-repo guards =="
reset_all
rc=0; ( cd "$NONGIT" && HOME="$SANDBOX" bash "$SO" on >/dev/null 2>&1 ) || rc=$?
chk "repo-scope action in non-repo → exit 1" test "$rc" = "1"
rc=0; ( cd "$NONGIT" && HOME="$SANDBOX" bash "$SO" on --global >/dev/null 2>&1 ) || rc=$?
chk "global-scope action in non-repo → exit 0" test "$rc" = "0"
out="$( cd "$NONGIT" && HOME="$SANDBOX" bash "$SO" status 2>&1 )"
chk "status in non-repo → global-only note" sh -c "printf '%s' \"\$0\" | grep -q 'resolved state requires a repo'" "$out"
rc=0; ( cd "$REPO" && HOME="$SANDBOX" bash "$SO" bogus >/dev/null 2>&1 ) || rc=$?
chk "bad arg → exit 1" test "$rc" = "1"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
