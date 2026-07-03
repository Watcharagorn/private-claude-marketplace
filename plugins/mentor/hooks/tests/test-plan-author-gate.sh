#!/usr/bin/env bash
# test-plan-author-gate.sh — regression tests for plan-author-gate.sh + the
# .plan-authored tracking added to research-dispatch-tracker.sh.
#
# Builds a real git repo, derives the repo-scoped plans dir as the hooks do, and:
#   • drives plan-author-gate.sh with PreToolUse:Write/Edit JSON, asserting the
#     plans-HTML write is BLOCKED until .plan-authored exists, is PATH-SCOPED to
#     the plans HTML, honors MENTOR_PLAN_AUTHOR=off, and self-heals on a stale marker;
#   • drives research-dispatch-tracker.sh with PreToolUse:Agent/Task JSON, asserting
#     .plan-authored is set on the token (in prompt or description) or the Plan role,
#     and NOT set by a plain research Explore dispatch.
#
# Sections A–G run with the output format UNSET (→ html), so the gate enforces *.html and a
# plans-dir *.md is NOT the deliverable; section H sets format=md and asserts the inverse.
set -uo pipefail
unset MENTOR_PLAN_FORMAT 2>/dev/null || true   # keep A–G deterministic regardless of caller env

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/plan-author-gate.sh"
TRACKER="$(dirname "$SCRIPT_DIR")/research-dispatch-tracker.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
[ -f "$TRACKER" ] || { echo "FATAL: tracker not found at $TRACKER" >&2; exit 1; }

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
MARKER="$PLANS_DIR/.planning"; DISP="$PLANS_DIR/.research-dispatched"
AUTH="$PLANS_DIR/.plan-authored"; BUD="$PLANS_DIR/.read-budget"
HTML="$PLANS_DIR/myplan-20260101-0000.html"
mkdir -p "$PLANS_DIR"

trap 'rm -rf "$ROOT"; rm -f "$MARKER" "$DISP" "$AUTH" "$BUD"; rmdir "$PLANS_DIR" "$(dirname "$PLANS_DIR")" 2>/dev/null || true' EXIT

PASS=0; FAIL=0
reset() { rm -f "$MARKER" "$DISP" "$AUTH" "$BUD"; }

# ---- plan-author-gate.sh : Write/Edit on a target path ----
gate() { # expect tool file_path desc [envassign]
  local expect="$1" tool="$2" fp="$3" desc="$4" env="${5:-}" rc=0 got json
  json="$(python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[2],"cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[3]}}))' "$REPO" "$tool" "$fp")"
  if [ -n "$env" ]; then
    printf '%s' "$json" | env "$env" bash "$HOOK" >/dev/null 2>&1 || rc=$?
  else
    printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  fi
  got="allow"; [ "$rc" = "2" ] && got="block"
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s (rc=%s): %s\n" "$expect" "$got" "$rc" "$desc"; fi
}

# ---- research-dispatch-tracker.sh : assert .plan-authored side effect ----
track() { # expect(set|unset) tool json_tool_input desc
  local expect="$1" tool="$2" ti="$3" desc="$4" json
  rm -f "$AUTH"
  json="$(python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[1],"cwd":sys.argv[2],"tool_input":json.loads(sys.argv[3])}))' "$tool" "$REPO" "$ti")"
  printf '%s' "$json" | bash "$TRACKER" >/dev/null 2>&1 || true
  local got="unset"; [ -f "$AUTH" ] && got="set"
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s: %s\n" "$expect" "$got" "$desc"; fi
}

echo "== A. No .planning marker → ALLOW (gate inert) =="
reset
gate allow Write "$HTML" "html write, no marker"

echo "== B. Marker, no .plan-authored → plans HTML BLOCKED; other paths ALLOW =="
reset; : > "$MARKER"
gate block Write "$HTML" "plans HTML blocked (no author dispatched)"
gate block Edit  "$HTML" "plans HTML Edit blocked too"
gate allow Write "$PLANS_DIR/notes.md"   "non-html in plans dir → not enforced"
gate allow Write "$REPO/src/x.ts"        "in-repo write → plan-author-gate inert (phase-gate's job)"
gate allow Write "/tmp/scratch.html"     "out-of-dir html → not enforced"

echo "== C. After .plan-authored → plans HTML ALLOWED (incl. revisions) =="
: > "$AUTH"
gate allow Write "$HTML" "first authored write"
gate allow Write "$HTML" "later revision write (sticky marker)"

echo "== D. Escape hatch MENTOR_PLAN_AUTHOR=off → ALLOW =="
reset; : > "$MARKER"
gate allow Write "$HTML" "off escape hatch" "MENTOR_PLAN_AUTHOR=off"

echo "== E. Non-Write/Edit tool → ignored (ALLOW) =="
reset; : > "$MARKER"
gate allow Bash "$HTML" "bash ignored by author-gate"

echo "== F. Stale .planning (>8h) → treated as released (ALLOW) =="
reset; : > "$MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
gate allow Write "$HTML" "html write with stale marker"

echo "== G. Tracker sets .plan-authored on author signals only =="
reset; : > "$MARKER"
track set   Agent '{"subagent_type":"Plan","prompt":"design X mentor:plan-author"}' "token in prompt (Agent)"
reset; : > "$MARKER"
track set   Task  '{"subagent_type":"general-purpose","description":"mentor:plan-author author the plan"}' "token in description (Task)"
reset; : > "$MARKER"
track set   Agent '{"subagent_type":"Plan","prompt":"design the implementation"}' "Plan role fallback, no token"
reset; : > "$MARKER"
track unset Agent '{"subagent_type":"Explore","prompt":"locate payment touchpoints"}' "plain research Explore → NOT author"
# tracker is inert without the .planning marker
reset
track unset Agent '{"subagent_type":"Plan","prompt":"mentor:plan-author"}' "no .planning marker → tracker inert"

echo "== H. format=md → the .md write is the enforced deliverable (html is not) =="
CONF="$HOME/.claude/mentor/${repo_base}-${repo_hash}/config.json"
MD="$PLANS_DIR/myplan.md"
printf '{"format":"md"}\n' > "$CONF"
reset; : > "$MARKER"
gate block Write "$MD"   "md plan write blocked when format=md (no author dispatched)"
gate allow Write "$HTML" "html write NOT enforced when format=md"
: > "$AUTH"
gate allow Write "$MD"   "md plan write allowed after author dispatched"
rm -f "$CONF"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
