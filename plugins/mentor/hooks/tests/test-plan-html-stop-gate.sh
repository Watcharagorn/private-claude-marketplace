#!/usr/bin/env bash
# test-plan-html-stop-gate.sh — regression tests for plan-html-stop-gate.sh
# (the persist-the-plan Stop floor), covering BOTH output formats.
#
# The gate BLOCKS the turn from ending when a plan-author was dispatched (.plan-authored)
# under a fresh .planning marker but no plan FILE of the configured format extension is
# newer than that dispatch. It ALLOWS once the file lands, and is inert outside the plan
# phase / on loop-safety signals (stop_hook_active, subagent transcript, MENTOR_PLAN_AUTHOR=off).
#
# Uses python3 to build the Stop event JSON. Runs against the real $HOME under a temp
# repo whose hash is unique (mktemp), cleaning up its own state dir on exit.
set -uo pipefail
unset MENTOR_PLAN_FORMAT 2>/dev/null || true   # html-format cases assume UNSET (→ html)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/plan-html-stop-gate.sh"
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
STATE_DIR="$HOME/.claude/mentor/${repo_base}-${repo_hash}"
PLANS_DIR="$STATE_DIR/plans"
MARKER="$PLANS_DIR/.planning"; AUTH="$PLANS_DIR/.plan-authored"; CONF="$STATE_DIR/config.json"
mkdir -p "$PLANS_DIR"

trap 'rm -rf "$ROOT"; rm -f "$MARKER" "$AUTH" "$CONF" "$PLANS_DIR"/*.html "$PLANS_DIR"/*.md 2>/dev/null; rmdir "$PLANS_DIR" "$STATE_DIR" 2>/dev/null || true' EXIT

PASS=0; FAIL=0
stopjson() { # [stop_hook_active 0|1] [transcript_path]
  python3 -c 'import json,sys;print(json.dumps({"cwd":sys.argv[1],"stop_hook_active":(sys.argv[2]=="1"),"transcript_path":sys.argv[3]}))' \
    "$REPO" "${1:-0}" "${2:-/x/y.jsonl}"
}
gate() { # desc expect [active] [transcript] [env=val]
  local desc="$1" expect="$2" active="${3:-0}" tp="${4:-/x/y.jsonl}" env="${5:-}" rc=0 got
  if [ -n "$env" ]; then
    printf '%s' "$(stopjson "$active" "$tp")" | env "$env" bash "$HOOK" >/dev/null 2>&1 || rc=$?
  else
    printf '%s' "$(stopjson "$active" "$tp")" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  fi
  got="allow"; [ "$rc" = "2" ] && got="block"
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s (rc=%s): %s\n" "$expect" "$got" "$rc" "$desc"; fi
}
reset() { rm -f "$MARKER" "$AUTH" "$CONF" "$PLANS_DIR"/*.html "$PLANS_DIR"/*.md 2>/dev/null || true; }
# .plan-authored stamped in the past so a freshly-created plan file is unambiguously newer.
auth_old() { : > "$AUTH"; touch -t 202401010000 "$AUTH"; }

echo "== A. No .planning marker → ALLOW (gate inert) =="
reset
gate "no marker → allow" allow

echo "== B. .planning but no .plan-authored → ALLOW (author not dispatched) =="
reset; : > "$MARKER"
gate "marker, no author → allow" allow

echo "== C. html: .planning + .plan-authored + NO plan file → BLOCK =="
reset; : > "$MARKER"; auth_old
gate "html, author dispatched, no plan file → block" block

echo "== D. html: a .html newer than .plan-authored → ALLOW =="
: > "$PLANS_DIR/plan.html"   # created now → newer than the 2024 .plan-authored
gate "html present + newer → allow" allow

echo "== E. Loop safety: stop_hook_active=true → ALLOW (never block twice) =="
reset; : > "$MARKER"; auth_old
gate "stop_hook_active=true → allow" allow 1

echo "== F. Subagent transcript → ALLOW =="
gate "subagent transcript → allow" allow 0 "/foo/subagents/bar.jsonl"

echo "== G. Escape hatch MENTOR_PLAN_AUTHOR=off → ALLOW =="
gate "author=off → allow" allow 0 /x/y.jsonl "MENTOR_PLAN_AUTHOR=off"

echo "== H. md format: NO .md → BLOCK; then a newer .md → ALLOW =="
reset; printf '{"format":"md"}\n' > "$CONF"; : > "$MARKER"; auth_old
gate "md, author dispatched, no .md → block" block
: > "$PLANS_DIR/plan.md"     # now → newer than .plan-authored
gate "md present + newer → allow" allow

echo "== I. md format: a newer .html does NOT satisfy (requires .md) → BLOCK =="
reset; printf '{"format":"md"}\n' > "$CONF"; : > "$MARKER"; auth_old
: > "$PLANS_DIR/plan.html"   # newer .html, but format=md → not the deliverable
gate "md format + only a newer .html → block" block

echo "== J. Stale .planning (>8h) → treated as released → ALLOW =="
reset; : > "$MARKER"; auth_old
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
gate "stale marker → allow" allow

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
