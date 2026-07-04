#!/usr/bin/env bash
# test-plan-finalize.sh — regression tests for plan-finalize.sh
# (the approval-time finalizer: HTML review surface → canonical <slug>.md).
#
# Contract under test (explicit-target interface):
#   - --plan <x.html> with a valid plan-source block → <x>.md written (byte-faithful
#     Markdown incl. footer markers), .html + .html.opened deleted, .md.opened pre-created,
#     stdout = the .md path, exit 0.
#   - ONLY the targeted html is touched — a stale sibling .html is never converted
#     (regression: newest-wins targeting resurrected abandoned plans as fresh-mtime .md).
#   - --plan <x.md> / missing file / no args → silent no-op, exit 0.
#   - html WITHOUT a plan-source block, or with one missing the strategy footer →
#     fail-soft: html KEPT, no .md written, empty stdout, exit 0.
#   - idempotent: re-running with the same (now-deleted) target is a no-op.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/plan-finalize.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }

ROOT="$(mktemp -d)"
PLANS_DIR="$ROOT/plans"
mkdir -p "$PLANS_DIR"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }
check() { # desc condition-result
  if [ "$2" = "0" ]; then ok "$1"; else fail "$1"; fi
}
reset() { rm -f "$PLANS_DIR"/* 2>/dev/null || true; }

# A well-formed html plan: rendered body + canonical plan-source block with footer markers.
write_html() { # path
  cat > "$1" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>t · mentor</title><style>body{color:#111}</style></head>
<body>
  <h1>Rendered body — must NOT survive finalize</h1>
<script type="text/markdown" id="plan-source">
# Test plan

## Context
Some context line.

## Implementation steps
Run in parallel:
- Step 1 — do a thing  [role: general-purpose · model: sonnet · effort: low]

strategy: dispatch
</script>
</body>
</html>
HTML
}

echo "== A. Valid html target → finalized to .md, html terminated =="
reset
write_html "$PLANS_DIR/my-plan.html"
: > "$PLANS_DIR/my-plan.html.opened"
out="$(bash "$HOOK" --plan "$PLANS_DIR/my-plan.html")"; rc=$?
check "exit 0" "$rc"
[ "$out" = "$PLANS_DIR/my-plan.md" ]; check "stdout is the .md path" "$?"
[ -f "$PLANS_DIR/my-plan.md" ]; check ".md exists" "$?"
[ ! -f "$PLANS_DIR/my-plan.html" ]; check ".html deleted" "$?"
[ ! -f "$PLANS_DIR/my-plan.html.opened" ]; check ".html.opened sidecar deleted" "$?"
[ -f "$PLANS_DIR/my-plan.md.opened" ]; check ".md.opened pre-created (no re-open)" "$?"
grep -q '^strategy: dispatch$' "$PLANS_DIR/my-plan.md"; check "footer marker is a bare line in .md" "$?"
grep -q 'role: general-purpose' "$PLANS_DIR/my-plan.md"; check "dispatch annotation survived" "$?"
grep -qi 'Rendered body' "$PLANS_DIR/my-plan.md" && fail "no HTML body leaked into .md" || ok "no HTML body leaked into .md"
grep -q '<script' "$PLANS_DIR/my-plan.md" && fail "no script tags leaked into .md" || ok "no script tags leaked into .md"

echo "== B. Idempotent: re-run with the (now-deleted) target is a no-op =="
out="$(bash "$HOOK" --plan "$PLANS_DIR/my-plan.html")"; rc=$?
check "exit 0" "$rc"
[ -z "$out" ]; check "empty stdout (nothing converted)" "$?"
[ -f "$PLANS_DIR/my-plan.md" ]; check ".md untouched" "$?"

echo "== C. Explicit target only: a stale sibling .html is NEVER converted =="
reset
write_html "$PLANS_DIR/stale.html"; touch -t 202401010000 "$PLANS_DIR/stale.html"
write_html "$PLANS_DIR/current.html"
out="$(bash "$HOOK" --plan "$PLANS_DIR/current.html")"; rc=$?
[ "$out" = "$PLANS_DIR/current.md" ]; check "targeted plan converted" "$?"
[ ! -f "$PLANS_DIR/current.html" ]; check "targeted html deleted" "$?"
[ -f "$PLANS_DIR/stale.html" ]; check "stale sibling html untouched" "$?"
[ ! -f "$PLANS_DIR/stale.md" ]; check "stale sibling NOT resurrected as .md" "$?"

echo "== D. --plan pointing at a .md (already finalized / md-format) → no-op =="
reset
printf '# md plan\n\nstrategy: normal\ndispatch-agents: skipped\n' > "$PLANS_DIR/native.md"
out="$(bash "$HOOK" --plan "$PLANS_DIR/native.md")"; rc=$?
check "exit 0" "$rc"
[ -z "$out" ]; check "empty stdout" "$?"
[ -f "$PLANS_DIR/native.md" ]; check "existing .md untouched" "$?"

echo "== E. html WITHOUT plan-source block → fail-soft, html kept =="
reset
printf '<!DOCTYPE html><html><body><h1>no source block</h1></body></html>\n' > "$PLANS_DIR/bad.html"
out="$(bash "$HOOK" --plan "$PLANS_DIR/bad.html" 2>/dev/null)"; rc=$?
check "exit 0" "$rc"
[ -z "$out" ]; check "empty stdout" "$?"
[ -f "$PLANS_DIR/bad.html" ]; check ".html kept" "$?"
[ ! -f "$PLANS_DIR/bad.md" ]; check "no .md written" "$?"

echo "== F. plan-source present but NO strategy footer → fail-soft, html kept =="
reset
cat > "$PLANS_DIR/nostrat.html" <<'HTML'
<html><body>
<script type="text/markdown" id="plan-source">
# Plan with no footer
Just prose, no markers.
</script>
</body></html>
HTML
out="$(bash "$HOOK" --plan "$PLANS_DIR/nostrat.html" 2>/dev/null)"; rc=$?
check "exit 0" "$rc"
[ -z "$out" ]; check "empty stdout" "$?"
[ -f "$PLANS_DIR/nostrat.html" ]; check ".html kept" "$?"
[ ! -f "$PLANS_DIR/nostrat.md" ]; check "no .md written" "$?"

echo "== G. Bad invocation → silent no-op =="
out="$(bash "$HOOK" 2>/dev/null)"; rc=$?
check "no args: exit 0" "$rc"
out="$(bash "$HOOK" --plan "$ROOT/does-not-exist.html" 2>/dev/null)"; rc=$?
check "missing target: exit 0" "$rc"
out="$(bash "$HOOK" --plan "" 2>/dev/null)"; rc=$?
check "empty target: exit 0" "$rc"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
