#!/usr/bin/env bash
# test-plan-finalize-flow.sh — integration tests for the finalize-at-approval flow across
# approve-plan.sh, dispatch-executor.sh, and begin-plan.sh.
#
# Regressions pinned here (found in review):
#   1. Double-finalize on the owned path must NOT resurrect a stale/abandoned .html as a
#      fresh-mtime .md (explicit-target finalize).
#   2. begin-plan.sh must NOT delete the finalized approved .md of a prior session when a
#      new /mentor:plan starts in an html-format repo.
#   3. plan-only mode must KEEP the styled HTML (the plan is the deliverable; no finalize).
# Plus: approve-plan re-run idempotency, and the native dispatch directive pointing at the .md.
#
# Runs against the real $HOME under a temp repo whose hash is unique (mktemp), cleaning up
# its own state dir on exit (pattern shared with test-plan-html-stop-gate.sh).
set -uo pipefail
unset MENTOR_PLAN_FORMAT 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
for h in approve-plan.sh dispatch-executor.sh begin-plan.sh plan-finalize.sh; do
  [ -f "$HOOKS/$h" ] || { echo "FATAL: hook not found at $HOOKS/$h" >&2; exit 1; }
done

ROOT="$(mktemp -d)"
REPO="$ROOT/flow-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1

. "$HOOKS/lib/state.sh"
repo_root="$(mentor_repo_root "$REPO")"
STATE_DIR="$(mentor_state_dir "$repo_root")"
PLANS_DIR="$(mentor_plans_dir "$repo_root")"
mkdir -p "$PLANS_DIR"
CONF="$STATE_DIR/config.json"

trap 'rm -rf "$ROOT" "$STATE_DIR"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }
check() { if [ "$2" = "0" ]; then ok "$1"; else fail "$1"; fi }
reset() { rm -f "$PLANS_DIR"/* "$CONF" 2>/dev/null || true; }

write_html() { # path [strategy-block]
  local block="${2:-strategy: dispatch}"
  cat > "$1" <<HTML
<html><body><h1>render</h1>
<script type="text/markdown" id="plan-source">
# Plan $(basename "$1")
Run in parallel:
- Step 1 — thing  [role: general-purpose · model: sonnet · effort: low]

${block}
</script>
</body></html>
HTML
}

echo "== A. Owned flow: approve → finalize → dispatch directive points at the .md =="
reset
printf '{"format":"html","mode":"plan"}\n' > "$CONF"
: > "$PLANS_DIR/.planning"
write_html "$PLANS_DIR/feature-a.html"
out="$(cd "$REPO" && bash "$HOOKS/approve-plan.sh" 2>&1)"; rc=$?
check "approve exits 0" "$rc"
[ -f "$PLANS_DIR/feature-a.md" ]; check "finalized .md exists" "$?"
[ ! -f "$PLANS_DIR/feature-a.html" ]; check ".html terminated" "$?"
[ ! -f "$PLANS_DIR/.planning" ]; check "gate released" "$?"
printf '%s' "$out" | grep -q "plan: ${PLANS_DIR}/feature-a.md"; check "printed plan path is the .md" "$?"
printf '%s' "$out" | grep -q "Read the approved plan file now: ${PLANS_DIR}/feature-a.md"; check "dispatch directive targets the .md" "$?"

echo "== B. Owned flow: stale abandoned .html is NOT resurrected by the double-finalize =="
reset
printf '{"format":"html","mode":"plan"}\n' > "$CONF"
: > "$PLANS_DIR/.planning"
write_html "$PLANS_DIR/stale-old.html"; touch -t 202401010000 "$PLANS_DIR/stale-old.html"
write_html "$PLANS_DIR/feature-b.html"
out="$(cd "$REPO" && bash "$HOOKS/approve-plan.sh" 2>&1)"; rc=$?
check "approve exits 0" "$rc"
[ -f "$PLANS_DIR/feature-b.md" ]; check "current plan finalized" "$?"
[ -f "$PLANS_DIR/stale-old.html" ]; check "stale html untouched" "$?"
[ ! -f "$PLANS_DIR/stale-old.md" ]; check "stale html NOT converted to .md" "$?"

echo "== C. Owned flow: re-run after finalize is an idempotent no-op =="
rm -f "$PLANS_DIR"/stale-old.html   # leave only the finalized feature-b.md
out="$(cd "$REPO" && bash "$HOOKS/approve-plan.sh" 2>&1)"; rc=$?
check "re-run exits 0" "$rc"
printf '%s' "$out" | grep -q "already APPROVED and finalized"; check "reports already-finalized" "$?"
[ -f "$PLANS_DIR/feature-b.md" ]; check ".md untouched" "$?"

echo "== D. begin-plan (html format) preserves the finalized .md of the prior approval =="
out="$(cd "$REPO" && bash "$HOOKS/begin-plan.sh" 2>&1)"; rc=$?
check "begin-plan exits 0" "$rc"
[ -f "$PLANS_DIR/feature-b.md" ]; check "finalized .md survives a new plan start" "$?"
[ -f "$PLANS_DIR/.planning" ]; check "gate re-armed" "$?"
rm -f "$PLANS_DIR/.planning"

echo "== E. begin-plan (md format) still purges foreign .html review surfaces =="
reset
printf '{"format":"md","mode":"plan"}\n' > "$CONF"
write_html "$PLANS_DIR/foreign.html"
out="$(cd "$REPO" && bash "$HOOKS/begin-plan.sh" 2>&1)"; rc=$?
check "begin-plan exits 0" "$rc"
[ ! -f "$PLANS_DIR/foreign.html" ]; check "foreign .html purged in md repo" "$?"
rm -f "$PLANS_DIR/.planning"

echo "== F. plan-only mode: approve KEEPS the styled HTML (no finalize) =="
reset
printf '{"format":"html","mode":"plan-only"}\n' > "$CONF"
: > "$PLANS_DIR/.planning"
write_html "$PLANS_DIR/deliverable.html" "strategy: normal
dispatch-agents: skipped"
out="$(cd "$REPO" && bash "$HOOKS/approve-plan.sh" 2>&1)"; rc=$?
check "approve exits 0" "$rc"
[ -f "$PLANS_DIR/deliverable.html" ]; check ".html kept (it IS the deliverable)" "$?"
[ ! -f "$PLANS_DIR/deliverable.md" ]; check "no .md written" "$?"
printf '%s' "$out" | grep -q "PLAN-ONLY MODE"; check "plan-only directive printed" "$?"

echo "== G. Native path: dispatch-executor finalizes the resolved html and targets the .md =="
reset
printf '{"format":"html","mode":"plan"}\n' > "$CONF"
write_html "$PLANS_DIR/native-c.html"
write_html "$PLANS_DIR/stale-d.html" ; touch -t 202401010000 "$PLANS_DIR/stale-d.html"
out="$(printf '{"tool_name":"ExitPlanMode","cwd":"%s","tool_input":{}}' "$REPO" | bash "$HOOKS/dispatch-executor.sh" 2>&1)"; rc=$?
check "dispatch-executor exits 0" "$rc"
[ -f "$PLANS_DIR/native-c.md" ]; check "resolved html finalized" "$?"
[ -f "$PLANS_DIR/stale-d.html" ]; check "stale html untouched" "$?"
printf '%s' "$out" | grep -q "Read the approved plan file now: ${PLANS_DIR}/native-c.md"; check "directive targets the .md" "$?"

echo "== H. Native path, plan-only: keeps html, no dispatch directive =="
reset
printf '{"format":"html","mode":"plan-only"}\n' > "$CONF"
write_html "$PLANS_DIR/po.html" "strategy: normal
dispatch-agents: skipped"
out="$(printf '{"tool_name":"ExitPlanMode","cwd":"%s","tool_input":{}}' "$REPO" | bash "$HOOKS/dispatch-executor.sh" 2>&1)"; rc=$?
check "dispatch-executor exits 0" "$rc"
[ -f "$PLANS_DIR/po.html" ]; check ".html kept in plan-only" "$?"
printf '%s' "$out" | grep -q "PLAN-ONLY MODE"; check "plan-only notice printed" "$?"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
