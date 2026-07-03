#!/usr/bin/env bash
# test-plan-read-gate.sh — regression tests for plan-read-gate.sh
#
# Builds a real git repo, derives the repo-scoped plans dir as the hook does, and
# drives the hook with PreToolUse JSON for Read/Grep/Glob, asserting the escalating
# floor: ~2 free reads then BLOCK until .research-dispatched exists; escape hatch
# MENTOR_PLAN_RESEARCH=off; inert without the .planning marker.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/plan-read-gate.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }

ROOT="$(mktemp -d)"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1

git_common="$(git -C "$REPO" rev-parse --git-common-dir)"
case "$git_common" in /*) common_abs="$git_common";; *) common_abs="$REPO/$git_common";; esac
repo_root="$(cd "$(dirname "$common_abs")" && pwd)"
repo_base="$(basename "$repo_root")"
repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
PLANS_DIR="$HOME/.claude/mentor/${repo_base}-${repo_hash}/plans"
MARKER="$PLANS_DIR/.planning"; DISP="$PLANS_DIR/.research-dispatched"; BUD="$PLANS_DIR/.read-budget"
mkdir -p "$PLANS_DIR"

trap 'rm -rf "$ROOT"; rm -f "$MARKER" "$DISP" "$BUD"; rmdir "$PLANS_DIR" "$(dirname "$PLANS_DIR")" 2>/dev/null || true' EXIT

PASS=0; FAIL=0
mkjson() { python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[2],"cwd":sys.argv[1],"tool_input":{"file_path":"x"}}))' "$REPO" "$1"; }
hit() { # expect tool desc  [envassign]
  local expect="$1" tool="$2" desc="$3" env="${4:-}" rc=0 got json
  json="$(mkjson "$tool")"
  if [ -n "$env" ]; then
    printf '%s' "$json" | env "$env" bash "$HOOK" >/dev/null 2>&1 || rc=$?
  else
    printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  fi
  got="allow"; [ "$rc" = "2" ] && got="block"
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s (rc=%s): %s\n" "$expect" "$got" "$rc" "$desc"; fi
}
reset() { rm -f "$MARKER" "$DISP" "$BUD"; }

echo "== A. No .planning marker → ALLOW =="
reset
hit allow Read "read with no marker"

echo "== B. Marker, no dispatch → 2 free reads, then BLOCK =="
reset; : > "$MARKER"
hit allow Read "read #1 (free)"
hit allow Grep "read #2 (free)"
hit block Glob "read #3 (blocked — must dispatch)"
hit block Read "read #4 (still blocked)"

echo "== C. After .research-dispatched → ALLOW again =="
: > "$DISP"
hit allow Read "read after dispatch"
hit allow Grep "grep after dispatch"

echo "== D. Escape hatch MENTOR_PLAN_RESEARCH=off → ALLOW (budget exhausted) =="
reset; : > "$MARKER"; echo 9 > "$BUD"
hit allow Read "off escape hatch" "MENTOR_PLAN_RESEARCH=off"

echo "== E. Non-read tool (Bash) → ignored (ALLOW) =="
reset; : > "$MARKER"; echo 9 > "$BUD"
hit allow Bash "bash ignored by read-gate"

echo "== F. Stale .planning marker (>8h) → treated as released (ALLOW) =="
reset; : > "$MARKER"; echo 9 > "$BUD"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
hit allow Read "read with stale marker"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
