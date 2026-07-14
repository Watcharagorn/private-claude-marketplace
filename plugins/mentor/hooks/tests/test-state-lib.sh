#!/usr/bin/env bash
# test-state-lib.sh — regression tests for hooks/lib/state.sh (v1.0.0).
#
# The lib backs every hook, so it gets its own suite: derivation parity with the
# inline logic, `set -e` caller safety (sourced functions must never abort a
# set -e hook), and the mentor_get_mode / mentor_cwd contracts.
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

echo "== A. Derivation parity with the inline logic =="
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
expect_base="$(basename "$expect_root")"
expect_hash="$(printf '%s' "$expect_root" | shasum | cut -c1-8)"
got_state="$(libsh "mentor_state_dir '$expect_root'")"
chk "state dir is \$HOME/.claude/mentor/{base}-{hash}" \
  test "$got_state" = "$SANDBOX/.claude/mentor/${expect_base}-${expect_hash}"
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
chk "mentor_cwd on empty input"           libsh 'c="$(mentor_cwd "")"; [ -n "$c" ]'
chk "mentor_cwd on garbage input"         libsh 'c="$(mentor_cwd "not json")"; [ -n "$c" ]'
chk "mentor_cwd extracts cwd"             libsh 'c="$(mentor_cwd "{\"cwd\":\"/tmp/x\"}")"; [ "$c" = "/tmp/x" ]'

echo "== D. mentor_get_mode =="
CONF_DIR="$SANDBOX/.claude/mentor/${expect_base}-${expect_hash}"
RCONF="$CONF_DIR/config.json"
mkdir -p "$CONF_DIR"
printf '{"mode": "plan"}\n'      > "$RCONF"
chk "mode=plan read back"      test "$(libsh "mentor_get_mode '$expect_root'")" = "plan"
printf '{"mode": "plan-only"}\n' > "$RCONF"
chk "mode=plan-only read back" test "$(libsh "mentor_get_mode '$expect_root'")" = "plan-only"
printf '{"other": 1}\n'          > "$RCONF"
chk "absent mode key → empty"  test -z "$(libsh "mentor_get_mode '$expect_root'")"
rm -f "$RCONF"
chk "no config file → empty"   test -z "$(libsh "mentor_get_mode '$expect_root'")"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
