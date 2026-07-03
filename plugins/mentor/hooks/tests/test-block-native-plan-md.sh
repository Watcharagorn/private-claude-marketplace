#!/usr/bin/env bash
# test-block-native-plan-md.sh — regression tests for block-native-plan-md.sh.
#
# The hook blocks writes to the harness-native plan file ($HOME/.claude/plans/*.md)
# so it can't drift against mentor's HTML plan — but ONLY while a plan flow is
# actually active (v0.38.3). Builds a real git repo, derives the repo-scoped plans
# dir as the hooks do, and asserts:
#   • no plan flow active (no .planning marker, not native plan mode) → ALLOW
#     (the over-reach fix: native plan mode in an unrelated repo, or a sibling skill
#      like audit-and-fix-plugin, can write ~/.claude/plans/*.md);
#   • Claude Code native plan mode (permission_mode == "plan") → BLOCK (this hook is
#     the sole guard for the native .md there — block-edits-in-plan-mode delegates it);
#   • mentor OWNED flow (fresh repo-scoped .planning marker) → BLOCK;
#   • stale .planning (>8h) → ALLOW (not fresh);
#   • path scope: only *.md directly under the native plans dir; other paths/tools ALLOW.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/block-native-plan-md.sh"
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
MARKER="$PLANS_DIR/.planning"
mkdir -p "$PLANS_DIR"

NATIVE_MD="$HOME/.claude/plans/myplan.md"   # path string only — hook never writes it
NATIVE_HTML="$HOME/.claude/plans/myplan.html"

trap 'rm -rf "$ROOT"; rm -f "$MARKER"; rmdir "$PLANS_DIR" "$(dirname "$PLANS_DIR")" 2>/dev/null || true' EXIT

PASS=0; FAIL=0
reset() { rm -f "$MARKER"; }

gate() { # expect tool file_path perm_mode desc
  local expect="$1" tool="$2" fp="$3" perm="$4" desc="$5" rc=0 got json
  json="$(python3 -c 'import json,sys
d={"tool_name":sys.argv[2],"cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[3]}}
if sys.argv[4]: d["permission_mode"]=sys.argv[4]
print(json.dumps(d))' "$REPO" "$tool" "$fp" "$perm")"
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  got="allow"; [ "$rc" = "2" ] && got="block"
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s (rc=%s): %s\n" "$expect" "$got" "$rc" "$desc"; fi
}

echo "== A. No plan flow active (no marker, no plan-mode) → ALLOW (over-reach fix) =="
reset
gate allow Write "$NATIVE_MD" "" "native .md, nothing active → allowed"
gate allow Edit  "$NATIVE_MD" "" "native .md Edit, nothing active → allowed"

echo "== B. Native plan mode (permission_mode=plan) → BLOCK (no regression) =="
reset
gate block Write "$NATIVE_MD" "plan" "native .md in native plan mode → blocked"
gate block Edit  "$NATIVE_MD" "plan" "native .md Edit in native plan mode → blocked"

echo "== C. mentor OWNED flow (fresh .planning marker) → BLOCK =="
reset; : > "$MARKER"
gate block Write "$NATIVE_MD" "" "native .md with fresh marker → blocked"

echo "== D. Stale .planning (>8h) and not plan-mode → ALLOW (not fresh) =="
reset; : > "$MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
gate allow Write "$NATIVE_MD" "" "native .md with stale marker → allowed"

echo "== E. Path scope: only *.md under the native plans dir =="
reset; : > "$MARKER"   # plan flow active, so only the path filter decides allow/block
gate allow Write "$NATIVE_HTML"        "" "native .html (not .md) → allowed even when planning"
gate allow Write "/tmp/scratch.md"     "" "out-of-dir .md → allowed"
gate allow Write "$REPO/notes.md"      "" "in-repo .md → not this hook's concern"

echo "== F. Non-Write/Edit tool → ignored (ALLOW) =="
reset; : > "$MARKER"
gate allow Bash "$NATIVE_MD" "" "Bash on native .md → ignored"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
