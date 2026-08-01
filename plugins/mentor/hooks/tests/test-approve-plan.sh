#!/usr/bin/env bash
# test-approve-plan.sh — regression tests for approve-plan.sh.
#
# Contract: release the .planning gate ONLY when a non-empty Markdown plan
# exists that is NEWER than the marker (i.e. written this planning session).
# --handoff / --deliver print their directives (mode-agnostic — the persisted
# mode is never read — and still printed when the gate is already open);
# unknown flags are rejected before the marker is touched.
#
# Runs against a SANDBOX $HOME so it never touches real user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
APPROVE="$HOOKS/approve-plan.sh"
SETMODE="$HOOKS/set-mode.sh"
PLANSTATE="$HOOKS/plan-state.sh"
for f in "$APPROVE" "$SETMODE" "$PLANSTATE"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1

trap 'rm -rf "$ROOT"' EXIT

repo_root="$(cd "$REPO" && pwd -P)"
STATE_DIR="$repo_root/.mentor"   # project-scoped, in-repo (v2.0.0)
PLANS_DIR="$STATE_DIR/plans"
MARKER="$PLANS_DIR/.planning"
mkdir -p "$PLANS_DIR"

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
ap() { ( cd "$REPO" && HOME="$SANDBOX" bash "$APPROVE" "$@" 2>&1 ); }
sm() { ( cd "$REPO" && HOME="$SANDBOX" bash "$SETMODE" "$@" >/dev/null 2>&1 ); }
arm() { : > "$MARKER"; }
fresh_plan() { sleep 1; mkdir -p "$PLANS_DIR/fixture-plan"; printf '# Plan\n\n1. Do the thing.\n' > "$PLANS_DIR/fixture-plan/plan.md"; }
stale_plan() { mkdir -p "$PLANS_DIR/fixture-plan"; printf '# Old plan\n\nfrom last session\n' > "$PLANS_DIR/fixture-plan/plan.md"; }
clear_plans() { rm -rf "$PLANS_DIR"/*/ 2>/dev/null; rm -f "$PLANS_DIR"/*.md; }

echo "== A. No plan → gate stays closed =="
sm plan
clear_plans; arm
out="$(ap)"; rc=$?
chk "no plan → exit 1"                 test "$rc" = "1"
chk "no plan → marker kept"            test -f "$MARKER"
chk "no plan → error message"          sh -c "printf '%s' \"\$0\" | grep -q 'No Markdown plan found'" "$out"

echo "== B. Empty plan → gate stays closed =="
arm; mkdir -p "$PLANS_DIR/fixture-plan"; : > "$PLANS_DIR/fixture-plan/plan.md"
out="$(ap)"; rc=$?
chk "empty plan → exit 1"              test "$rc" = "1"
chk "empty plan → marker kept"         test -f "$MARKER"

echo "== C. Stale prior-session plan (older than marker) → gate stays closed =="
clear_plans
stale_plan
sleep 1; arm   # marker is now NEWER than the plan
out="$(ap)"; rc=$?
chk "stale plan → exit 1"              test "$rc" = "1"
chk "stale plan → marker kept"         test -f "$MARKER"
chk "stale plan → staleness message"   sh -c "printf '%s' \"\$0\" | grep -q 'predates this planning session'" "$out"

echo "== D. Fresh plan → gate released =="
arm; fresh_plan
out="$(ap)"; rc=$?
chk "fresh plan → exit 0"              test "$rc" = "0"
chk "fresh plan → marker gone"         test ! -f "$MARKER"
chk "fresh plan → APPROVED message"    sh -c "printf '%s' \"\$0\" | grep -q 'Plan APPROVED'" "$out"
chk "fresh plan → plan path printed"   sh -c "printf '%s' \"\$0\" | grep -q 'fixture-plan/plan.md'" "$out"
chk "fresh plan → SDD directive"       sh -c "printf '%s' \"\$0\" | grep -q 'subagents-first'" "$out"

echo "== D2. Legacy flat <slug>.md is ignored by the resolver =="
sleep 1; arm                                                # marker now NEWER than the nested plan
sleep 1; printf '# Flat legacy plan\n' > "$PLANS_DIR/legacy-flat.md"   # newer than marker, but flat
out="$(ap)"; rc=$?
chk "flat newer → still exit 1"        test "$rc" = "1"
chk "flat newer → marker kept"         test -f "$MARKER"
chk "flat newer → staleness message"   sh -c "printf '%s' \"\$0\" | grep -q 'predates this planning session'" "$out"
rm -f "$PLANS_DIR/legacy-flat.md" "$MARKER"

echo "== E. Idempotency: gate already open → exit 0, directives still print =="
out="$(ap)"; rc=$?
chk "already open → exit 0"            test "$rc" = "0"
chk "already open → notice"            sh -c "printf '%s' \"\$0\" | grep -q 'already open'" "$out"
chk "already open → SDD directive"     sh -c "printf '%s' \"\$0\" | grep -q 'subagents-first'" "$out"
# A re-run of a no-implementation flag must never lose its directive.
out="$(ap --deliver)"; rc=$?
chk "open + --deliver → exit 0"        test "$rc" = "0"
chk "open + --deliver → directive"     sh -c "printf '%s' \"\$0\" | grep -q 'DELIVER-ONLY'" "$out"
out="$(ap --handoff)"; rc=$?
chk "open + --handoff → exit 0"        test "$rc" = "0"
chk "open + --handoff → directive"     sh -c "printf '%s' \"\$0\" | grep -q 'HAND-OFF REQUESTED'" "$out"

echo "== F. --handoff: approve + hand off, never implement =="
arm; fresh_plan
out="$(ap --handoff)"; rc=$?
chk "handoff → exit 0"                 test "$rc" = "0"
chk "handoff → marker gone"            test ! -f "$MARKER"
chk "handoff → sentinel + skill ref"   sh -c "printf '%s' \"\$0\" | grep -q 'HAND-OFF REQUESTED' && printf '%s' \"\$0\" | grep -q 'mentor:handoff'" "$out"
# handoff with a stale plan: validation precedes the hand-off branch.
clear_plans
stale_plan; sleep 1; arm
out="$(ap --handoff)"; rc=$?
chk "handoff(stale) → exit 1"          test "$rc" = "1"
chk "handoff(stale) → marker kept"     test -f "$MARKER"
chk "handoff(stale) → no sentinel"     sh -c "! printf '%s' \"\$0\" | grep -q 'HAND-OFF REQUESTED'" "$out"

echo "== G. --deliver: mode-agnostic deliverable soft-stop =="
sm plan
arm; fresh_plan
out="$(ap --deliver)"; rc=$?
chk "deliver → exit 0"                 test "$rc" = "0"
chk "deliver → marker gone"            test ! -f "$MARKER"
chk "deliver → DELIVER-ONLY directive" sh -c "printf '%s' \"\$0\" | grep -q 'DELIVER-ONLY'" "$out"
# deliver with a stale plan: validation precedes the directive.
clear_plans
stale_plan; sleep 1; arm
out="$(ap --deliver)"; rc=$?
chk "deliver(stale) → exit 1"          test "$rc" = "1"
chk "deliver(stale) → marker kept"     test -f "$MARKER"
chk "deliver(stale) → no directive"    sh -c "! printf '%s' \"\$0\" | grep -q 'DELIVER-ONLY'" "$out"
# persisted plan-only mode must NOT change a plain approve (the old mode branch is gone).
sm plan-only
arm; fresh_plan
out="$(ap)"; rc=$?
chk "plan-only + no-arg → exit 0"      test "$rc" = "0"
chk "plan-only + no-arg → no soft-stop" sh -c "! printf '%s' \"\$0\" | grep -qE 'DELIVER-ONLY|PLAN-ONLY MODE'" "$out"
sm plan

echo "== H. Unknown flag → rejected before touching the marker =="
arm; fresh_plan
out="$(ap --bogus)"; rc=$?
chk "bogus flag → exit 1"              test "$rc" = "1"
chk "bogus flag → marker kept"         test -f "$MARKER"
chk "bogus flag → usage printed"       sh -c "printf '%s' \"\$0\" | grep -q 'Usage:'" "$out"
rm -f "$MARKER"

echo "== I. Non-repo cwd → exit 1 =="
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"
rc=0; ( cd "$NONGIT" && HOME="$SANDBOX" bash "$APPROVE" >/dev/null 2>&1 ) || rc=$?
chk "non-repo → exit 1"                test "$rc" = "1"

echo "== J. Plan state: every approval path promotes, and only THIS session's plans =="
# The bug this section guards: approve-plan.sh deletes the marker, and both
# `[ a -nt b ]` and `find -newer b` are TRUE when b is gone. Asking "which plans are
# newer than the marker" AFTER the release would stamp every plan dir in the repo.
psq() { ( cd "$REPO" && HOME="$SANDBOX" bash "$PLANSTATE" "$@" 2>/dev/null ); }
st()  { psq list | awk -v s="$1" '$3 == s { print $2 }'; }   # $2 STATE · $3 PLAN
newplan() { sleep 1; mkdir -p "$PLANS_DIR/$1"; printf '# %s\n' "$1" > "$PLANS_DIR/$1/plan.md"; psq init "$1" >/dev/null; }

clear_plans; rm -f "$MARKER"
# A months-old plan dir. It must survive every approve below untouched.
mkdir -p "$PLANS_DIR/ancient"; printf '# ancient\n' > "$PLANS_DIR/ancient/plan.md"
touch -t 202501010000 "$PLANS_DIR/ancient/plan.md"

arm; newplan this-session
out="$(ap)"
chk "no-arg approve promotes this session's plan" test "$(st this-session)" = "approved"
chk "months-old plan NOT promoted"                test "$(st ancient)" = "unknown"
chk "approve reports the promotion"    sh -c "printf '%s' \"\$0\" | grep -q 'state: approved'" "$out"

# A split parent's plan.md is ALSO newer than the marker — it must not flip back.
arm; newplan split-parent; newplan split-kid
psq set split-parent superseded >/dev/null
psq init split-kid --group split-parent --order 1 >/dev/null
ap >/dev/null
chk "superseded parent not flipped back"          test "$(st split-parent)" = "superseded"
chk "split child promoted"                        test "$(st split-kid)" = "approved"

# --deliver / --handoff approve too — the flags defer implementation, not approval.
# (Leaving these at `draft` made plan-track refuse handoff-approved plans next session.)
arm; newplan delivered
ap --deliver >/dev/null
chk "--deliver promotes to approved"              test "$(st delivered)" = "approved"
arm; newplan handed-off
ap --handoff >/dev/null
chk "--handoff promotes to approved"              test "$(st handed-off)" = "approved"

# No marker → no snapshot → nothing to promote. This is what stops a re-run from
# stamping the whole repo.
rm -f "$MARKER"; newplan gate-open
ap >/dev/null
chk "gate already open → nothing promoted"        test "$(st gate-open)" = "draft"
chk "months-old plan still untouched at the end"  test "$(st ancient)" = "unknown"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
