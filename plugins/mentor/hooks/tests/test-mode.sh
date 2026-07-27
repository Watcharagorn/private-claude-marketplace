#!/usr/bin/env bash
# test-mode.sh — regression tests for set-mode.sh + begin-plan.sh's mode-aware output.
#
# Runs against a SANDBOX $HOME so it never touches real user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
SETMODE="$HOOKS/set-mode.sh"
BEGIN="$HOOKS/begin-plan.sh"
for f in "$SETMODE" "$BEGIN"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

trap 'rm -rf "$ROOT"' EXIT

repo_root="$(cd "$REPO" && pwd -P)"
STATE_DIR="$repo_root/.mentor"   # project-scoped, in-repo (v2.0.0)
PLANS_DIR="$STATE_DIR/plans"
CONF="$STATE_DIR/config.json"

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
sm() { ( cd "$REPO" && HOME="$SANDBOX" bash "$SETMODE" "$@" 2>&1 ); }

echo "== A. set-mode.sh status / set / invalid / key preservation =="
out="$(sm status)"; rc=$?
chk "unset → exits 0"                  test "$rc" = "0"
chk "unset → prints UNSET token"       sh -c "printf '%s' \"\$0\" | grep -q '^UNSET'" "$out"

out="$(sm plan-only)"
chk "set plan-only → confirmation"     sh -c "printf '%s' \"\$0\" | grep -q 'mode set: plan-only'" "$out"
chk "plan-only → no legacy SOFT-STOPS" sh -c "! printf '%s' \"\$0\" | grep -q 'SOFT-STOPS'" "$out"
chk "config.json written"              test -f "$CONF"
chk "config mode is plan-only"         test "$(jq -r .mode "$CONF")" = "plan-only"

out="$(sm status)"
chk "status → mode: plan-only"         sh -c "printf '%s' \"\$0\" | grep -q '^mode: plan-only'" "$out"

# Key preservation: foreign keys must survive a mode change.
jq '. + {custom: "keep-me"}' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
out="$(sm plan)"
chk "set plan → confirmation"          sh -c "printf '%s' \"\$0\" | grep -q 'mode set: plan'" "$out"
chk "config mode is plan"              test "$(jq -r .mode "$CONF")" = "plan"
chk "foreign config key preserved"     test "$(jq -r .custom "$CONF")" = "keep-me"
out="$(sm status)"
chk "status → mode: plan"              sh -c "printf '%s' \"\$0\" | grep -q '^mode: plan'" "$out"

out="$(sm bogus)"; rc=$?
chk "invalid mode → exit 1"            test "$rc" = "1"
chk "invalid mode → usage printed"     sh -c "printf '%s' \"\$0\" | grep -q 'Usage:'" "$out"

rc=0; ( cd "$NONGIT" && HOME="$SANDBOX" bash "$SETMODE" status >/dev/null 2>&1 ) || rc=$?
chk "non-repo → exit 1"                test "$rc" = "1"

echo "== B. begin-plan.sh mode-aware output + arming =="
sm plan-only >/dev/null
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" 2>&1 )"
chk "plan-only → MODE: plan-only line" sh -c "printf '%s' \"\$0\" | grep -q '^MODE: plan-only$'" "$out"
chk "plan-only → no hard directive"    sh -c "! printf '%s' \"\$0\" | grep -q 'do NOT implement'" "$out"
chk "marker armed"                     test -f "$PLANS_DIR/.planning"
sm plan >/dev/null
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" 2>&1 )"
chk "plan → MODE: plan line"           sh -c "printf '%s' \"\$0\" | grep -q '^MODE: plan$'" "$out"
rm -f "$CONF"
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" 2>&1 )"
chk "unset → UNSET defaults to plan"   sh -c "printf '%s' \"\$0\" | grep -qF 'MODE: UNSET (default: plan)'" "$out"
chk "unset → no upfront ask"           sh -c "! printf '%s' \"\$0\" | grep -qE 'AskUserQuestion|set-mode.sh'" "$out"
# .opened sidecars are cleared on arm — recursively (dot-hidden in plan dirs,
# the zooms tree) + legacy flat. A legacy plans/<slug>/zoom/ sidecar is first
# RELOCATED to zooms/<slug>/ (v2.12.0) and then swept — gone either way.
ZOOMS_DIR="$STATE_DIR/zooms"
mkdir -p "$PLANS_DIR/some-plan/zoom" "$ZOOMS_DIR/some-plan"
: > "$PLANS_DIR/some-plan/.plan.md.opened"
: > "$PLANS_DIR/some-plan/zoom/.checkout-end-user.html.opened"
: > "$ZOOMS_DIR/some-plan/.billing-implementor.html.opened"
: > "$PLANS_DIR/legacy-flat.md.opened"
( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" >/dev/null 2>&1 )
chk "nested .opened sidecar cleared"      test ! -f "$PLANS_DIR/some-plan/.plan.md.opened"
chk "legacy zoom .opened sidecar gone (relocated + swept)" sh -c "test ! -f '$PLANS_DIR/some-plan/zoom/.checkout-end-user.html.opened' && test ! -f '$ZOOMS_DIR/some-plan/.checkout-end-user.html.opened'"
chk "zooms tree .opened sidecar cleared"  test ! -f "$ZOOMS_DIR/some-plan/.billing-implementor.html.opened"
chk "legacy flat .opened sidecar cleared" test ! -f "$PLANS_DIR/legacy-flat.md.opened"
# Outside a repo: fail-soft (exit 0, notice printed, no marker anywhere).
out="$( cd "$NONGIT" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" 2>&1 )"; rc=$?
chk "non-repo begin-plan exits 0"      test "$rc" = "0"
chk "non-repo → NOT-armed notice"      sh -c "printf '%s' \"\$0\" | grep -q 'NOT armed'" "$out"

echo "== C. Flat-layout migration on arm (v2.2.0 hop + v2.12.0 relocation) =="
rm -rf "$PLANS_DIR" "$ZOOMS_DIR"; mkdir -p "$PLANS_DIR"
printf '# Demo\n'      > "$PLANS_DIR/demo.md"
: > "$PLANS_DIR/demo-checkout-end-user.html"
# prefix collision: "auth-retry"'s zoom must not be captured by the shorter "auth" plan
printf '# Auth\n'      > "$PLANS_DIR/auth.md"
printf '# AuthRetry\n' > "$PLANS_DIR/auth-retry.md"
: > "$PLANS_DIR/auth-retry-x-y.html"
( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" >/dev/null 2>&1 )
chk "demo.md → demo/plan.md"                       test -f "$PLANS_DIR/demo/plan.md"
chk "demo zoom → zooms/demo/checkout-end-user.html (both hops)" test -f "$ZOOMS_DIR/demo/checkout-end-user.html"
chk "auth.md → auth/plan.md"                       test -f "$PLANS_DIR/auth/plan.md"
chk "auth-retry.md → auth-retry/plan.md"           test -f "$PLANS_DIR/auth-retry/plan.md"
chk "collision zoom → zooms/auth-retry/x-y.html"   test -f "$ZOOMS_DIR/auth-retry/x-y.html"
chk "auth has no captured zoom"                    sh -c "test ! -e '$PLANS_DIR/auth/zoom' && test ! -e '$ZOOMS_DIR/auth'"
chk "no plans/<slug>/zoom/ dirs left"              test -z "$(ls -d "$PLANS_DIR"/*/zoom 2>/dev/null)"
chk "no flat .md left"                             test -z "$(ls "$PLANS_DIR"/*.md 2>/dev/null)"
chk "no flat .html left"                           test -z "$(ls "$PLANS_DIR"/*.html 2>/dev/null)"
chk "marker armed after migration"                 test -f "$PLANS_DIR/.planning"

echo "== C2. v2.12.0 relocation alone (per-plan zoom/ → zooms/<slug>/) =="
mkdir -p "$PLANS_DIR/demo/zoom"
: > "$PLANS_DIR/demo/zoom/billing-implementor.html"
: > "$ZOOMS_DIR/demo/existing.html"   # pre-existing target content must survive (mv -n)
( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" >/dev/null 2>&1 )
chk "per-plan zoom html relocated"        test -f "$ZOOMS_DIR/demo/billing-implementor.html"
chk "emptied zoom/ dir removed"           test ! -e "$PLANS_DIR/demo/zoom"
chk "pre-existing zooms file untouched"   test -f "$ZOOMS_DIR/demo/existing.html"
# idempotent: a second arm with nothing to relocate must not fail or invent dirs
( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" >/dev/null 2>&1 ); rc=$?
chk "second arm (nothing to relocate) exits 0" test "$rc" = "0"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
