#!/usr/bin/env bash
# test-approve-plan.sh — regression tests for approve-plan.sh.
#
# Contract: release the .planning gate ONLY when a non-empty Markdown plan
# exists that is NEWER than the marker (i.e. written this planning session).
# --deliver prints its directive (still printed when the gate is already
# open); unknown flags,
# including the retired --handoff (v4.2.0), are rejected before the marker is
# touched.
#
# v2.23.0 (worktree-scoped plan gate): the marker is now per-worktree —
# `.planning.<wt-id>` — with a bare legacy `.planning` reserved as a
# repo-wide fallback that only its own arming session may approve through.
# Ownership (sidecar `owner`/`owner_session`) scopes approval to THIS
# worktree's plans (or unowned ones, while no sibling worktree is planning);
# a live sibling marker excludes unowned plans too, reported by name rather
# than silently swept or silently dropped. MARKER below is retargeted to
# this (the "A") worktree's OWN suffixed marker; a second, linked worktree
# ("B", $WTB) exercises the cross-worktree cases.
#
# Section Q drives begin-plan.sh <slug>: an approved/in_progress plan owned by
# this worktree (or unowned) prints ALREADY APPROVED and writes no marker;
# foreign-owned or draft plans arm as before.
#
# Runs against a SANDBOX $HOME so it never touches real user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
APPROVE="$HOOKS/approve-plan.sh"
PLANSTATE="$HOOKS/plan-state.sh"
BEGIN="$HOOKS/begin-plan.sh"
for f in "$APPROVE" "$PLANSTATE" "$BEGIN"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }
# shellcheck source=../lib/state.sh
. "$HOOKS/lib/state.sh"   # only for mentor_worktree_id, to derive wt-ids the same way begin-plan.sh does

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
git -C "$REPO" worktree add -q "$ROOT/wt-b" -b wtb >/dev/null 2>&1

trap 'rm -rf "$ROOT"' EXIT

repo_root="$(cd "$REPO" && pwd -P)"
STATE_DIR="$repo_root/.mentor"   # project-scoped, in-repo (v2.0.0)
PLANS_DIR="$STATE_DIR/plans"
WTB="$ROOT/wt-b"
WTA_ID="$(mentor_worktree_id "$REPO")"
WTB_ID="$(mentor_worktree_id "$WTB")"
[ -n "$WTA_ID" ] && [ -n "$WTB_ID" ] || { echo "FATAL: could not derive worktree ids for the fixture repo" >&2; exit 1; }
MARKER="$PLANS_DIR/.planning.${WTA_ID}"    # A's own marker (retargeted from the old bare .planning)
MARKER_B="$PLANS_DIR/.planning.${WTB_ID}"  # B's own marker
LEGACY_MARKER="$PLANS_DIR/.planning"       # reserved legacy repo-global marker
mkdir -p "$PLANS_DIR"

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
# Every runner below unsets CLAUDE_CODE_SESSION_ID so the ambient session (if any)
# never leaks into a legacy_mode session-match check — sections that need a specific
# session pass it explicitly instead (see apsess/pssess).
ap()     { ( cd "$REPO" && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$APPROVE" "$@" 2>&1 ); }
ap_b()   { ( cd "$WTB"  && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$APPROVE" "$@" 2>&1 ); }
apsess() { local sess="$1"; shift; ( cd "$REPO" && HOME="$SANDBOX" CLAUDE_CODE_SESSION_ID="$sess" bash "$APPROVE" "$@" 2>&1 ); }
arm() { : > "$MARKER"; }
arm_b() { : > "$MARKER_B"; }
fresh_plan() { sleep 1; mkdir -p "$PLANS_DIR/fixture-plan"; printf '# Plan\n\n1. Do the thing.\n' > "$PLANS_DIR/fixture-plan/plan.md"; }
stale_plan() { mkdir -p "$PLANS_DIR/fixture-plan"; printf '# Old plan\n\nfrom last session\n' > "$PLANS_DIR/fixture-plan/plan.md"; }
clear_plans() { rm -rf "$PLANS_DIR"/*/ 2>/dev/null; rm -f "$PLANS_DIR"/*.md; }
sidecar() { jq -r "${2}" "$PLANS_DIR/$1/.state.json" 2>/dev/null; }   # sidecar <slug> <jq filter>
psq() { ( cd "$REPO" && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$PLANSTATE" "$@" 2>/dev/null ); }
psq_b() { ( cd "$WTB" && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$PLANSTATE" "$@" 2>/dev/null ); }

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
chk "fresh plan → main-thread directive" sh -c "printf '%s' \"\$0\" | grep -q 'Implement the plan.s steps in the main thread'" "$out"
chk "fresh plan → directive names tick, Verification, ship" sh -c "printf '%s' \"\$0\" | grep -q 'plan-state.sh tick' && printf '%s' \"\$0\" | grep -q '## Verification' && printf '%s' \"\$0\" | grep -q '/mentor:ship'" "$out"
chk "fresh plan → no removed-skill routing" sh -c "! printf '%s' \"\$0\" | grep -qE 'dispatch-agents|Dispatch: skipped|/mentor:handoff|claim'" "$out"

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
chk "already open → main-thread directive" sh -c "printf '%s' \"\$0\" | grep -q 'Implement the plan.s steps in the main thread'" "$out"
# A re-run of a no-implementation flag must never lose its directive.
out="$(ap --deliver)"; rc=$?
chk "open + --deliver → exit 0"        test "$rc" = "0"
chk "open + --deliver → directive"     sh -c "printf '%s' \"\$0\" | grep -q 'DELIVER-ONLY'" "$out"

echo "== F. --handoff retired (v4.2.0): usage error, marker untouched =="
arm; fresh_plan
out="$(ap --handoff 2>&1)"; rc=$?
chk "handoff → exit 1"                 test "$rc" = "1"
chk "handoff → marker kept"            test -f "$MARKER"
chk "handoff → usage names --deliver only" sh -c "printf '%s' \"\$0\" | grep -q 'Usage: approve-plan.sh \[--deliver\]'" "$out"
chk "handoff → no hand-off directive"  sh -c "! printf '%s' \"\$0\" | grep -q 'HAND-OFF REQUESTED'" "$out"
rm -f "$MARKER"; clear_plans

echo "== G. --deliver: deliverable soft-stop =="
arm; fresh_plan
out="$(ap --deliver)"; rc=$?
chk "deliver → exit 0"                 test "$rc" = "0"
chk "deliver → marker gone"            test ! -f "$MARKER"
chk "deliver → DELIVER-ONLY directive" sh -c "printf '%s' \"\$0\" | grep -q 'DELIVER-ONLY'" "$out"
chk "deliver → no handoff/implementation directive" sh -c "! printf '%s' \"\$0\" | grep -qE '/mentor:handoff|Implement the plan'" "$out"
# deliver with a stale plan: validation precedes the directive.
clear_plans
stale_plan; sleep 1; arm
out="$(ap --deliver)"; rc=$?
chk "deliver(stale) → exit 1"          test "$rc" = "1"
chk "deliver(stale) → marker kept"     test -f "$MARKER"
chk "deliver(stale) → no directive"    sh -c "! printf '%s' \"\$0\" | grep -q 'DELIVER-ONLY'" "$out"
# A legacy .mentor/config.json "mode": "plan-only" key is never read: a plain approve
# never soft-stops.
printf '{"mode":"plan-only"}\n' > "$STATE_DIR/config.json"
arm; fresh_plan
out="$(ap)"; rc=$?
chk "legacy plan-only key + no-arg → exit 0"      test "$rc" = "0"
chk "legacy plan-only key + no-arg → no soft-stop" sh -c "! printf '%s' \"\$0\" | grep -qE 'DELIVER-ONLY|PLAN-ONLY MODE'" "$out"
rm -f "$STATE_DIR/config.json"

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

# --deliver approves too — the flag defers implementation, not approval.
# (A flagged approval left at `draft` reads as "the gate never released" next session.)
arm; newplan delivered
ap --deliver >/dev/null
chk "--deliver promotes to approved"              test "$(st delivered)" = "approved"

# No marker → no snapshot → nothing to promote. This is what stops a re-run from
# stamping the whole repo.
rm -f "$MARKER"; newplan gate-open
out="$(ap)"
chk "gate already open → nothing promoted"        test "$(st gate-open)" = "draft"
# Silence here is indistinguishable from a plugin too old to have the promotion block
# at all — which is how a plan left at `draft` after a clean-looking approval went
# unnoticed until the next session refused to build it. Every path reports.
chk "gate-open path still reports state"   sh -c "printf '%s' \"\$0\" | grep -q 'state: unchanged'" "$out"

# Marker armed, but every candidate is already approved → nothing to promote, and that
# must say so rather than print nothing.
arm; newplan already-ok
psq set already-ok approved >/dev/null
out="$(ap)"
chk "all-already-approved reports state"   sh -c "printf '%s' \"\$0\" | grep -q 'state: unchanged'" "$out"
chk "already-approved plan stays approved"        test "$(st already-ok)" = "approved"

# The flag path early-exits after its directive — the state line must land BEFORE that.
arm; newplan flagged-d
out="$(ap --deliver)"
chk "--deliver prints the state line"      sh -c "printf '%s' \"\$0\" | grep -q 'state: approved'" "$out"

chk "months-old plan still untouched at the end"  test "$(st ancient)" = "unknown"

echo "== K. deps/group/order survive the promotion write =="

clear_plans; rm -f "$MARKER"
arm; newplan main-plan
# A plan's deps/group/order must survive its promotion — the write path is
# --state approved only. This is the whole reason mentor_plan_state_write went
# flag-style: the old fixed-positional write clobbered these back to defaults on
# every promotion.
arm; newplan survive-fields
psq init survive-fields --group grp-x --order 7 --deps main-plan >/dev/null
out="$(ap)"; rc=$?
chk "ordinary plan with deps/group/order → exit 0" test "$rc" = "0"
chk "ordinary plan promoted"                        test "$(st survive-fields)" = "approved"
chk "deps survive an ordinary promotion"            test "$(sidecar survive-fields '(.deps//[])|join(",")')" = "main-plan"
chk "group survives an ordinary promotion"          test "$(sidecar survive-fields '.group')" = "grp-x"
chk "order survives an ordinary promotion"          test "$(sidecar survive-fields '.order')" = "7"

echo "== L. Ownership matrix: A owns plan-a, B owns plan-b — A's approve promotes plan-a ONLY (v2.23.0) =="
clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"
arm; arm_b
sleep 1
mkdir -p "$PLANS_DIR/plan-a"; printf '# a\n' > "$PLANS_DIR/plan-a/plan.md"; psq init plan-a >/dev/null
mkdir -p "$PLANS_DIR/plan-b"; printf '# b\n' > "$PLANS_DIR/plan-b/plan.md"; psq_b init plan-b >/dev/null
chk "plan-a owned by A before approving"           test "$(sidecar plan-a '.owner')" = "$WTA_ID"
chk "plan-b owned by B before approving"           test "$(sidecar plan-b '.owner')" = "$WTB_ID"
out="$(ap)"; rc=$?
chk "A's approve → exit 0"                         test "$rc" = "0"
chk "A's own marker gone"                          test ! -f "$MARKER"
chk "B's marker survives A's approve untouched"    test -f "$MARKER_B"
chk "plan-a promoted"                              test "$(sidecar plan-a '.state')" = "approved"
chk "plan-b stays draft (B's draft survives untouched)" test "$(sidecar plan-b '.state')" = "draft"
chk "plan-b's owner is unchanged (still B)"        test "$(sidecar plan-b '.owner')" = "$WTB_ID"
chk "A's approve output names plan-a"              sh -c "printf '%s' \"\$0\" | grep -q 'plan-a'" "$out"
chk "A's approve output never names plan-b"        sh -c "! printf '%s' \"\$0\" | grep -q 'plan-b'" "$out"
# B's own approve then succeeds on its own plan, independently.
out_b="$(ap_b)"; rc=$?
chk "B's approve → exit 0"                         test "$rc" = "0"
chk "B's marker gone"                              test ! -f "$MARKER_B"
chk "plan-b promoted by B's own approve"           test "$(sidecar plan-b '.state')" = "approved"

echo "== M. Unowned plan + live sibling marker → excluded from newest AND the sweep, reported by name =="
clear_plans; rm -f "$MARKER" "$MARKER_B"
arm; arm_b
sleep 1
mkdir -p "$PLANS_DIR/owned-a"; printf '# a\n' > "$PLANS_DIR/owned-a/plan.md"; psq init owned-a >/dev/null
mkdir -p "$PLANS_DIR/stray-unowned"; printf '# u\n' > "$PLANS_DIR/stray-unowned/plan.md"   # never init'd — unowned
out="$(ap)"; rc=$?
chk "A's approve, sibling live + unowned present → exit 0"  test "$rc" = "0"
chk "owned-a promoted"                                       test "$(sidecar owned-a '.state')" = "approved"
chk "stray-unowned excluded from the sweep (no sidecar written)" test ! -f "$PLANS_DIR/stray-unowned/.state.json"
chk "approve reports the unowned skip by name"  sh -c "printf '%s' \"\$0\" | grep -q 'unowned, skipped' && printf '%s' \"\$0\" | grep -q 'stray-unowned'" "$out"

echo "== M2. Unowned plan, no sibling live → promoted (solo back-compat); promotion stamps owner =="
clear_plans; rm -f "$MARKER" "$MARKER_B"
arm
sleep 1
mkdir -p "$PLANS_DIR/solo-unowned"; printf '# s\n' > "$PLANS_DIR/solo-unowned/plan.md"   # never init'd — unowned
chk "solo-unowned starts with no owner"      test -z "$(sidecar solo-unowned '.owner')"
out="$(ap)"; rc=$?
chk "solo unowned, no sibling → exit 0"      test "$rc" = "0"
chk "solo unowned → marker gone"             test ! -f "$MARKER"
chk "solo unowned → promoted"                test "$(sidecar solo-unowned '.state')" = "approved"
chk "promotion stamps owner on the previously-unowned plan" test "$(sidecar solo-unowned '.owner')" = "$WTA_ID"

echo "== N. legacy_mode requires session match — matching session gets repo-wide behavior; mismatched/missing refuses, marker untouched =="
clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"
{ echo "session=S1"; echo "cwd=/wherever"; } > "$LEGACY_MARKER"
sleep 1
mkdir -p "$PLANS_DIR/legacy-plan"; printf '# lp\n' > "$PLANS_DIR/legacy-plan/plan.md"
before_sum="$(cksum "$LEGACY_MARKER")"
out="$(apsess S2)"; rc=$?
chk "mismatched session → exit 1"                test "$rc" = "1"
chk "mismatched session → marker byte-untouched" test "$(cksum "$LEGACY_MARKER")" = "$before_sum"
chk "mismatched session → refusal names it"      sh -c "printf '%s' \"\$0\" | grep -q 'Refusing to approve through the legacy plan gate'" "$out"
out="$(ap)"; rc=$?   # ap() unsets CLAUDE_CODE_SESSION_ID — missing session
chk "missing session → exit 1"                   test "$rc" = "1"
chk "missing session → marker byte-untouched"    test "$(cksum "$LEGACY_MARKER")" = "$before_sum"
out="$(apsess S1)"; rc=$?
chk "matching session → exit 0"                  test "$rc" = "0"
chk "matching session → legacy marker gone"      test ! -f "$LEGACY_MARKER"
chk "matching session → repo-wide release message" sh -c "printf '%s' \"\$0\" | grep -q 'legacy repo-wide gate released'" "$out"
chk "matching session → legacy-plan promoted"    test "$(sidecar legacy-plan '.state')" = "approved"

echo "== O. Own marker released while a live legacy exists → warn printed, legacy kept =="
clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"
{ echo "session=S1"; echo "cwd=/other"; } > "$LEGACY_MARKER"
arm
sleep 1
mkdir -p "$PLANS_DIR/own-and-legacy"; printf '# x\n' > "$PLANS_DIR/own-and-legacy/plan.md"; psq init own-and-legacy >/dev/null
out="$(ap)"; rc=$?
chk "own approve while legacy live → exit 0"     test "$rc" = "0"
chk "own marker released"                        test ! -f "$MARKER"
chk "legacy marker kept (not deleted)"           test -f "$LEGACY_MARKER"
chk "warns the legacy marker is still live"      sh -c "printf '%s' \"\$0\" | grep -q 'legacy repo-wide marker is still live'" "$out"
chk "own-and-legacy still promoted"              test "$(sidecar own-and-legacy '.state')" = "approved"
rm -f "$LEGACY_MARKER"

echo "== P. Owned-filter validation failures print the ownership wording, never the false 'No Markdown plan found' =="
clear_plans; rm -f "$MARKER" "$MARKER_B"
arm; arm_b
sleep 1
mkdir -p "$PLANS_DIR/b-only"; printf '# b\n' > "$PLANS_DIR/b-only/plan.md"; psq_b init b-only >/dev/null
out="$(ap)"; rc=$?
chk "A approve, every candidate foreign-owned → exit 1"  test "$rc" = "1"
chk "A's marker kept"                                     test -f "$MARKER"
chk "names the ownership situation"                       sh -c "printf '%s' \"\$0\" | grep -q 'owned by another worktree'" "$out"
chk "never prints the false 'No Markdown plan found'"     sh -c "! printf '%s' \"\$0\" | grep -q 'No Markdown plan found'" "$out"

echo "== P2. The staleness branch also names the ownership situation when the filter excluded candidates =="
clear_plans; rm -f "$MARKER" "$MARKER_B"
arm; arm_b
mkdir -p "$PLANS_DIR/a-stale"; printf '# old\n' > "$PLANS_DIR/a-stale/plan.md"; psq init a-stale >/dev/null
sleep 1; arm   # re-arm A so a-stale now predates A's marker
mkdir -p "$PLANS_DIR/b-fresh"; printf '# new\n' > "$PLANS_DIR/b-fresh/plan.md"; psq_b init b-fresh >/dev/null
out="$(ap)"; rc=$?
chk "A approve, only-owned plan predates the marker → exit 1" test "$rc" = "1"
chk "staleness message shown"                                  sh -c "printf '%s' \"\$0\" | grep -q 'predates this planning session'" "$out"
chk "ownership situation named too"                             sh -c "printf '%s' \"\$0\" | grep -q 'owned by another worktree'" "$out"

echo "== Q. begin-plan.sh <slug>: an approved/in-progress plan owned here (or unowned) is NOT re-armed =="
# Re-arming would close the gate on a plan already cleared for implementation, with
# nothing newer than the fresh marker left to release it. Foreign-owned and draft plans
# arm exactly as before.
bp()  { ( cd "$REPO" && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$BEGIN" "$@" 2>&1 ); }
mkplan() { mkdir -p "$PLANS_DIR/$1"; printf '# Plan %s\n\n1. Do it.\n' "$1" > "$PLANS_DIR/$1/plan.md"; }
clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"

mkplan q-own; psq init q-own >/dev/null; psq set q-own approved >/dev/null
out="$(bp q-own)"; rc=$?
chk "approved+owned → exit 0"                         test "$rc" = "0"
chk "approved+owned → ALREADY APPROVED line"          sh -c "printf '%s' \"\$0\" | grep -q '^ALREADY APPROVED: q-own'" "$out"
chk "approved+owned → re-plan hint"                   sh -c "printf '%s' \"\$0\" | grep -q 'plan-state.sh set q-own draft'" "$out"
chk "approved+owned → no marker written"              test ! -e "$MARKER"
chk "approved+owned → not ARMED"                      sh -c "! printf '%s' \"\$0\" | grep -q 'ARMED'" "$out"
# An existing own marker is not touched either (its mtime is the session start).
: > "$MARKER"; touch -t 202001010000 "$MARKER"; before="$(ls -l "$MARKER")"
out="$(bp q-own)"
chk "approved+owned → existing marker untouched"      test "$(ls -l "$MARKER")" = "$before"
rm -f "$MARKER"

psq set q-own in_progress >/dev/null
out="$(bp q-own)"; rc=$?
chk "in_progress+owned → ALREADY APPROVED, exit 0"    sh -c "[ \"\$1\" = 0 ] && printf '%s' \"\$0\" | grep -q '^ALREADY APPROVED: q-own'" "$out" "$rc"
chk "in_progress+owned → no marker written"           test ! -e "$MARKER"

mkplan q-unowned; printf '{"state":"approved"}\n' > "$PLANS_DIR/q-unowned/.state.json"
out="$(bp q-unowned)"
chk "approved+unowned → ALREADY APPROVED"             sh -c "printf '%s' \"\$0\" | grep -q '^ALREADY APPROVED: q-unowned'" "$out"
chk "approved+unowned → no marker written"            test ! -e "$MARKER"

mkplan q-foreign; psq_b init q-foreign >/dev/null; psq_b set q-foreign approved >/dev/null
out="$(bp q-foreign)"; rc=$?
chk "approved+foreign-owned → arms (exit 0, ARMED)"   sh -c "[ \"\$1\" = 0 ] && printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out" "$rc"
chk "approved+foreign-owned → marker written"         test -f "$MARKER"
chk "approved+foreign-owned → no ALREADY APPROVED"    sh -c "! printf '%s' \"\$0\" | grep -q 'ALREADY APPROVED'" "$out"
rm -f "$MARKER"

# The re-plan hint must actually work on a partly-TICKED plan: ticks advance the
# effective state, so the check keys on the stored one.
mkdir -p "$PLANS_DIR/q-ticked"
printf '# Plan\n\n## Implementation steps\n\n1. One.\n2. Two.\n' > "$PLANS_DIR/q-ticked/plan.md"
psq init q-ticked >/dev/null; psq set q-ticked approved >/dev/null; psq tick q-ticked 1 >/dev/null
out="$(bp q-ticked)"
chk "approved+ticked 1/2 → ALREADY APPROVED"          sh -c "printf '%s' \"\$0\" | grep -q '^ALREADY APPROVED: q-ticked'" "$out"
chk "approved+ticked 1/2 → no marker written"         test ! -e "$MARKER"
psq set q-ticked draft >/dev/null
out="$(bp q-ticked)"
chk "after the hint's set draft → arms"               sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "after the hint's set draft → marker written"     test -f "$MARKER"
rm -f "$MARKER"
# Fully ticked: effective state is implemented, past approval — arms as before.
mkdir -p "$PLANS_DIR/q-done"
printf '# Plan\n\n## Implementation steps\n\n1. One.\n' > "$PLANS_DIR/q-done/plan.md"
psq init q-done >/dev/null; psq set q-done approved >/dev/null; psq tick q-done 1 >/dev/null
out="$(bp q-done)"
chk "approved but fully ticked → arms"                sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
rm -f "$MARKER"

mkplan q-draft; psq init q-draft >/dev/null
out="$(bp q-draft)"
chk "draft → arms"                                    sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "draft → marker written"                          test -f "$MARKER"
chk "draft → no ALREADY APPROVED"                     sh -c "! printf '%s' \"\$0\" | grep -q 'ALREADY APPROVED'" "$out"
rm -f "$MARKER"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
