#!/usr/bin/env bash
# test-state-lib.sh — regression tests for hooks/lib/state.sh (v0.37).
#
# The lib backs every enforcement hook, so it gets its own suite: derivation parity
# with the old inline logic, one-shot legacy dir migration (+ idempotency, markers survive),
# `set -e` caller safety (sourced functions must never abort a set -e hook), and the
# mentor_config_bool / mentor_orchestrator_on (repo>legacy>global precedence) /
# mentor_migrate_legacy_commander / mentor_get_mode / mentor_marker_fresh contracts.
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

echo "== A. Derivation parity with the old inline logic =="
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

echo "== B. One-shot legacy migration =="
LEGACY="$SANDBOX/.claude/mentor/plans/${expect_base}-${expect_hash}"
rm -rf "$SANDBOX/.claude/mentor"
mkdir -p "$LEGACY"
: > "$LEGACY/.planning"; : > "$LEGACY/old-plan.html"
pd="$(libsh "mentor_plans_dir '$expect_root'")"
chk "markers survive migration"   test -f "$pd/.planning"
chk "plan HTML survives migration" test -f "$pd/old-plan.html"
chk "legacy dir is gone"           test ! -d "$LEGACY"
pd2="$(libsh "mentor_plans_dir '$expect_root'")"
chk "idempotent re-derivation"     test "$pd" = "$pd2"
chk "markers intact after re-call" test -f "$pd2/.planning"

echo "== C. set -e caller safety (functions must not abort the hook) =="
chk "mentor_get_mode on nonexistent root" \
  libsh 'm="$(mentor_get_mode /nonexistent/path)"; [ -z "$m" ]; echo done >/dev/null'
chk "mentor_get_mode with no config"      libsh 'm="$(mentor_get_mode "'"$expect_root"'")"; [ -z "$m" ]'
chk "mentor_cwd on empty input"           libsh 'c="$(mentor_cwd "")"; [ -n "$c" ]'
chk "mentor_session_id on garbage input"  libsh 's="$(mentor_session_id "not json")"; [ "$s" = "default" ]'
chk "condition-form orchestrator_on survives set -e" \
  libsh 'mentor_orchestrator_on "'"$expect_root"'" || true; echo ok >/dev/null'

echo "== D. config_bool / orchestrator_on precedence / migration contract =="
CONF_DIR="$SANDBOX/.claude/mentor/${expect_base}-${expect_hash}"
RCONF="$CONF_DIR/config.json"
GCONF="$SANDBOX/.claude/mentor/config.json"
mkdir -p "$CONF_DIR"
# off-check helper: 0 iff orchestrator resolves OFF for the sample repo.
off_repo() { bash -c "! ( HOME='$SANDBOX' bash -c \". '$LIB'; mentor_orchestrator_on '$expect_root'\" )"; }

# --- mentor_config_bool: true / false / absent must be DISTINCT (jq has() requirement) ---
printf '{"orchestrator": true}\n'  > "$RCONF"
chk "config_bool true"             test "$(libsh "mentor_config_bool '$RCONF' orchestrator")" = "true"
printf '{"orchestrator": false}\n' > "$RCONF"
chk "config_bool false (NOT unset)" test "$(libsh "mentor_config_bool '$RCONF' orchestrator")" = "false"
printf '{"mode": "plan"}\n'        > "$RCONF"
chk "config_bool absent → unset"   test "$(libsh "mentor_config_bool '$RCONF' orchestrator")" = "unset"

# --- precedence: repo explicit > legacy mode:commander > global > OFF ---
rm -f "$GCONF"
printf '{"orchestrator": true}\n'  > "$RCONF"; chk "repo true,  global unset → ON"  libsh "mentor_orchestrator_on '$expect_root'"
printf '{"orchestrator": false}\n' > "$RCONF"; chk "repo false, global unset → OFF" off_repo
printf '{"orchestrator": true}\n'  > "$GCONF"
printf '{"orchestrator": false}\n' > "$RCONF"; chk "repo false beats global true → OFF (keystone)" off_repo
printf '{"mode": "plan"}\n'        > "$RCONF"; chk "repo absent, global true → ON"  libsh "mentor_orchestrator_on '$expect_root'"
rm -f "$GCONF"
printf '{"mode": "plan"}\n'        > "$RCONF"; chk "repo absent, global unset → OFF" off_repo
printf '{"mode": "commander"}\n'   > "$RCONF"; chk "legacy commander (no orch key) → ON" libsh "mentor_orchestrator_on '$expect_root'"
printf '{"mode": "commander", "orchestrator": false}\n' > "$RCONF"; chk "legacy commander + orch:false → OFF" off_repo
chk "orchestrator_on false for no repo" bash -c "! ( HOME='$SANDBOX' bash -c \". '$LIB'; mentor_orchestrator_on ''\" )"

# --- mentor_migrate_legacy_commander: clobber-safe, idempotent ---
printf '{"mode": "commander"}\n' > "$RCONF"
libsh "mentor_migrate_legacy_commander '$expect_root'" >/dev/null
chk "migrate commander → mode=plan"          test "$(libsh "mentor_get_mode '$expect_root'")" = "plan"
chk "migrate commander → orchestrator true"  test "$(libsh "mentor_config_bool '$RCONF' orchestrator")" = "true"
printf '{"mode": "commander", "orchestrator": false}\n' > "$RCONF"
libsh "mentor_migrate_legacy_commander '$expect_root'" >/dev/null
chk "migrate keeps mode=plan"                test "$(libsh "mentor_get_mode '$expect_root'")" = "plan"
chk "migrate does NOT clobber orch:false"    test "$(libsh "mentor_config_bool '$RCONF' orchestrator")" = "false"

# --- get_mode + extra keys ---
printf '{"mode": "plan-only"}\n' > "$RCONF"
chk "mode=plan-only read back" test "$(libsh "mentor_get_mode '$expect_root'")" = "plan-only"
printf '{"orchestrator": true, "other": 1}\n' > "$RCONF"
chk "extra config keys tolerated" libsh "mentor_orchestrator_on '$expect_root'"
rm -f "$RCONF" "$GCONF"

echo "== E. mentor_marker_fresh =="
M="$ROOT/marker"; : > "$M"
chk "fresh marker → true"   libsh "mentor_marker_fresh '$M'"
touch -t 202001010000 "$M"
chk "stale marker → false"  bash -c "! ( HOME='$SANDBOX' bash -c \". '$LIB'; mentor_marker_fresh '$M'\" )"
chk "missing marker → false" bash -c "! ( HOME='$SANDBOX' bash -c \". '$LIB'; mentor_marker_fresh '$ROOT/nope'\" )"

echo "== F. mentor_get_format (env > config > empty; validated md|html) =="
mkdir -p "$CONF_DIR"; rm -f "$RCONF" "$GCONF"
chk "no config → empty"                 test -z "$(libsh "mentor_get_format '$expect_root'")"
printf '{"format": "md"}\n'   > "$RCONF"; chk "config md → md"     test "$(libsh "mentor_get_format '$expect_root'")" = "md"
printf '{"format": "html"}\n' > "$RCONF"; chk "config html → html" test "$(libsh "mentor_get_format '$expect_root'")" = "html"
printf '{"format": "markdown"}\n' > "$RCONF"; chk "config invalid value → empty" test -z "$(libsh "mentor_get_format '$expect_root'")"
printf '{"mode": "plan"}\n'   > "$RCONF"; chk "config absent format key → empty"  test -z "$(libsh "mentor_get_format '$expect_root'")"
printf '{"format": "html"}\n' > "$RCONF"
chk "env md beats config html"          test "$(MENTOR_PLAN_FORMAT=md libsh "mentor_get_format '$expect_root'")" = "md"
chk "env invalid → fall through to config" test "$(MENTOR_PLAN_FORMAT=markdown libsh "mentor_get_format '$expect_root'")" = "html"
chk "env empty → fall through to config"   test "$(MENTOR_PLAN_FORMAT='' libsh "mentor_get_format '$expect_root'")" = "html"
rm -f "$RCONF"
chk "env md wins with no config/repo"   test "$(MENTOR_PLAN_FORMAT=md libsh "mentor_get_format ''")" = "md"
chk "env invalid + no config → empty"   test -z "$(MENTOR_PLAN_FORMAT=htm libsh "mentor_get_format '$expect_root'")"
chk "get_format on nonexistent root → empty" libsh 'f="$(mentor_get_format /nonexistent/path)"; [ -z "$f" ]'
chk "get_format set -e safe"            libsh "mentor_get_format '$expect_root' >/dev/null; echo ok >/dev/null"
rm -f "$RCONF" "$GCONF"

echo "== G. mentor_plan_ext (format→extension; the gates' single source of truth) =="
mkdir -p "$CONF_DIR"; rm -f "$RCONF" "$GCONF"
printf '{"format": "md"}\n'   > "$RCONF"; chk "format md → ext md"      test "$(libsh "mentor_plan_ext '$expect_root'")" = "md"
printf '{"format": "html"}\n' > "$RCONF"; chk "format html → ext html"  test "$(libsh "mentor_plan_ext '$expect_root'")" = "html"
rm -f "$RCONF"
chk "unset format → ext html (back-compat default)" test "$(libsh "mentor_plan_ext '$expect_root'")" = "html"
printf '{"format": "markdown"}\n' > "$RCONF"; chk "invalid format → ext html" test "$(libsh "mentor_plan_ext '$expect_root'")" = "html"
chk "env md → ext md"                   test "$(MENTOR_PLAN_FORMAT=md libsh "mentor_plan_ext '$expect_root'")" = "md"
chk "plan_ext on nonexistent root → html" test "$(libsh "mentor_plan_ext /nonexistent/path")" = "html"
chk "plan_ext set -e safe"              libsh "mentor_plan_ext '$expect_root' >/dev/null; echo ok >/dev/null"
rm -f "$RCONF" "$GCONF"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
