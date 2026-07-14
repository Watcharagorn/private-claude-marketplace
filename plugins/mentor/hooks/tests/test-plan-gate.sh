#!/usr/bin/env bash
# test-plan-gate.sh — regression tests for plan-gate.sh
#
# Builds a real git repo, derives the repo-scoped plans dir EXACTLY as the hook
# does, plants/removes the .planning marker, then drives the hook with PreToolUse
# JSON for a matrix of tool calls and asserts allow (exit 0) vs block (exit 2).
#
# Contract under test (v1.0.0): while the .planning marker is present the hook is
# FAIL-CLOSED for Write/Edit/MultiEdit/NotebookEdit (only OUTSIDE-repo targets
# allowed). Bash is not matched (not enforced). No marker → inert. Stale marker
# (>8h) → treated as released.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/plan-gate.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }

# Canonicalize the temp root (macOS mktemp returns /var/... which is a symlink to
# /private/var/...). Production cwd from Claude Code is already canonical.
ROOT="$(cd "$(mktemp -d)" && pwd -P)"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"
  git config user.email t@t.co; git config user.name t
  mkdir -p src; echo "x" > src/app.ts
  git add -A; git commit -q -m init ) >/dev/null 2>&1

# Derive plans dir + marker exactly as the hook does.
git_common="$(git -C "$REPO" rev-parse --git-common-dir)"
case "$git_common" in /*) common_abs="$git_common";; *) common_abs="$REPO/$git_common";; esac
repo_root="$(cd "$(dirname "$common_abs")" && pwd)"
repo_base="$(basename "$repo_root")"
repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
PLANS_DIR="$HOME/.claude/mentor/${repo_base}-${repo_hash}/plans"
MARKER="$PLANS_DIR/.planning"
mkdir -p "$PLANS_DIR"

trap 'rm -rf "$ROOT"; rm -f "$MARKER"; rmdir "$PLANS_DIR" "$(dirname "$PLANS_DIR")" 2>/dev/null || true' EXIT

PASS=0; FAIL=0
run() { # expect cwd tool desc file_path
  local expect="$1" cwd="$2" tool="$3" desc="$4" payload="$5" json rc=0 got
  json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[3],"cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$cwd" "$payload" "$tool")
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  got="allow"; [ "$rc" = "2" ] && got="block"
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else
    FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s (rc=%s): %s\n       payload: %s\n" "$expect" "$got" "$rc" "$desc" "$payload"
  fi
}

echo "== A. No marker → hook inert (ALLOW all) =="
rm -f "$MARKER"
run allow "$REPO" Write "Write repo file (no marker)" "$REPO/src/app.ts"
run allow "$REPO" Edit  "Edit repo file (no marker)"  "$REPO/src/app.ts"

echo "== B. Marker present → repo Write/Edit/MultiEdit/NotebookEdit BLOCKED; outside ALLOWED =="
: > "$MARKER"
run block "$REPO" Write        "Write repo source"           "$REPO/src/app.ts"
run block "$REPO" Edit         "Edit repo source"            "$REPO/src/app.ts"
run block "$REPO" MultiEdit    "MultiEdit repo source"       "$REPO/src/app.ts"
run block "$REPO" Write        "Write new repo file"         "$REPO/NEWFILE"
run block "$REPO" NotebookEdit "NotebookEdit in repo"        "$REPO/nb.ipynb"
run allow "$REPO" Write        "Write the plan .md (outside)" "$PLANS_DIR/plan.md"
run allow "$REPO" Write        "Write to scratch (outside)"  "$ROOT/scratch.txt"

echo "== C. Marker present → NotebookEdit notebook_path field also gated =="
json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"NotebookEdit","cwd":sys.argv[1],"tool_input":{"notebook_path":sys.argv[2]}}))' "$REPO" "$REPO/nb.ipynb")
rc=0; printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "2" ]; then PASS=$((PASS+1)); echo "  ok   [block] notebook_path in repo"
else FAIL=$((FAIL+1)); echo "  FAIL want=block got=allow (rc=$rc): notebook_path in repo"; fi

echo "== D. Marker present → empty/unresolvable path DENIED (fail-closed) =="
json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{}}))' "$REPO")
rc=0; printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "2" ]; then PASS=$((PASS+1)); echo "  ok   [block] empty file_path"
else FAIL=$((FAIL+1)); echo "  FAIL want=block got=allow (rc=$rc): empty file_path"; fi

echo "== E. Bash is NOT matched → hook inert for Bash even with marker =="
json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"rm "+sys.argv[1]+"/src/app.ts"}}))' "$REPO")
rc=0; printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "0" ]; then PASS=$((PASS+1)); echo "  ok   [allow] Bash not gated"
else FAIL=$((FAIL+1)); echo "  FAIL want=allow got rc=$rc: Bash not gated"; fi

echo "== F. Stale marker (>8h) → treated as released (ALLOW + self-heal) =="
: > "$MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
run allow "$REPO" Write "Write repo file (stale marker)" "$REPO/src/app.ts"
if [ ! -f "$MARKER" ]; then PASS=$((PASS+1)); echo "  ok   stale marker self-healed (removed)"
else FAIL=$((FAIL+1)); echo "  FAIL stale marker still present"; fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
