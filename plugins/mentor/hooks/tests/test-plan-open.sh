#!/usr/bin/env bash
# test-plan-open.sh — regression tests for plan-open.sh
#
# Builds a real git repo, derives the repo-scoped plans dir exactly as the hook does, writes a
# fake plan .html, and drives the hook with PostToolUse:Write JSON under MENTOR_PLAN_OPEN_DRYRUN
# (each opener prints its name instead of launching anything). Asserts opener SELECTION per
# MENTOR_PLAN_OPENER / VSCode env, plus the no-op cases (off-switch, non-plan path, open-once
# marker). The ambient VSCode env vars are cleared in the base runner so the result doesn't
# depend on whether the test itself runs inside VSCode's integrated terminal.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/plan-open.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }

ROOT="$(mktemp -d)"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1

git_common="$(git -C "$REPO" rev-parse --git-common-dir)"
case "$git_common" in /*) common_abs="$git_common";; *) common_abs="$REPO/$git_common";; esac
repo_root="$(cd "$(dirname "$common_abs")" && pwd)"
PLANS_DIR="$repo_root/.mentor/plans"   # project-scoped, in-repo; per-plan dirs since v2.2.0
PLAN_DIR="$PLANS_DIR/sample-plan"
mkdir -p "$PLAN_DIR/zoom"
PLAN="$PLAN_DIR/zoom/checkout-end-user.html"
MARKER="$PLAN_DIR/zoom/.checkout-end-user.html.opened"
: > "$PLAN"

trap 'rm -rf "$ROOT"' EXIT   # .mentor/ lives inside $ROOT, so this cleans everything

PASS=0; FAIL=0
mkjson() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1]}}))' "$1"; }

# Base runner: clears any inherited VSCode signals, enables the dry-run seam, applies per-case
# env assignments ("$@"), and returns the hook's stdout (the selected opener name, or empty).
run() {
  local fp="$1"; shift
  printf '%s' "$(mkjson "$fp")" \
    | env -u TERM_PROGRAM -u VSCODE_PID -u VSCODE_GIT_IPC_HANDLE -u VSCODE_IPC_HOOK_CLI -u VSCODE_INJECTION \
          MENTOR_PLAN_OPEN_DRYRUN=1 "$@" bash "$HOOK" 2>/dev/null
}
check() { # expect desc filepath [env=val ...]
  local expect="$1" desc="$2" fp="$3"; shift 3
  rm -f "$(dirname "$fp")/.$(basename "$fp").opened"   # clear the dot-hidden open-once sidecar for THIS file
  local got; got="$(run "$fp" "$@")"
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "${expect:-<none>}" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL want=%q got=%q: %s\n" "$expect" "$got" "$desc"; fi
}

echo "== A. auto mode selects VSCode in-editor when inside VSCode, else Chrome =="
check chrome "auto + NOT in VSCode -> chrome"        "$PLAN"
check vscode "auto + TERM_PROGRAM=vscode -> vscode"  "$PLAN" TERM_PROGRAM=vscode
check vscode "auto + VSCODE_PID set -> vscode"       "$PLAN" VSCODE_PID=123

echo "== B. Forced modes ignore detection =="
check vscode "MENTOR_PLAN_OPENER=vscode (no VSCode env) -> vscode" "$PLAN" MENTOR_PLAN_OPENER=vscode
check chrome "MENTOR_PLAN_OPENER=chrome -> chrome"                 "$PLAN" MENTOR_PLAN_OPENER=chrome
check system "MENTOR_PLAN_OPENER=system -> system"                 "$PLAN" MENTOR_PLAN_OPENER=system

echo "== C. No-op cases (no opener selected) =="
check "" "off-switch MENTOR_PLAN_OPEN=off -> no-op"   "$PLAN" MENTOR_PLAN_OPEN=off
check "" "non-plan path -> no-op"                     "$ROOT/random.html"

echo "== C2. Path patterns: per-plan <slug>/ layout only =="
check chrome "zoom html inside <slug>/zoom/ matches" "$PLAN"
LEGACY_HTML="$PLANS_DIR/legacy-flat.html"; : > "$LEGACY_HTML"
check "" "legacy flat html in plans/ -> no-op"        "$LEGACY_HTML"
LEGACY_MD="$PLANS_DIR/legacy-flat.md"; : > "$LEGACY_MD"
check "" "legacy flat md in plans/ -> no-op"          "$LEGACY_MD"
STRAY_HTML="$PLAN_DIR/stray.html"; : > "$STRAY_HTML"
check "" "html beside plan.md (not in zoom/) -> no-op" "$STRAY_HTML"
STRAY_MD="$PLAN_DIR/notes.md"; : > "$STRAY_MD"
check "" "non-plan.md md inside <slug>/ -> no-op"      "$STRAY_MD"
rm -f "$LEGACY_HTML" "$LEGACY_MD" "$STRAY_HTML" "$STRAY_MD"

echo "== E. Markdown (.md) plans: prefer a VSCode tab, never raw-text Chrome =="
MD="$PLAN_DIR/plan.md"; : > "$MD"
check vscode "md auto (not in VSCode) -> vscode (prefer tab, not Chrome)" "$MD"
check vscode "md auto + VSCODE_PID -> vscode"                            "$MD" VSCODE_PID=123
check vscode "md forced vscode -> vscode"                                "$MD" MENTOR_PLAN_OPENER=vscode
check system "md forced chrome -> system (Chrome can't render raw .md)"   "$MD" MENTOR_PLAN_OPENER=chrome
check system "md forced system -> system"                                "$MD" MENTOR_PLAN_OPENER=system
check ""     "md off-switch -> no-op"                                    "$MD" MENTOR_PLAN_OPEN=off
rm -f "$MD" "$PLAN_DIR/.plan.md.opened"

echo "== D. Open-once: marker present -> no-op =="
: > "$MARKER"
got="$(run "$PLAN")"
if [ -z "$got" ]; then PASS=$((PASS+1)); printf "  ok   [<none>] marker present -> no re-open\n"
else FAIL=$((FAIL+1)); printf "  FAIL want=%q got=%q: marker present -> no re-open\n" "" "$got"; fi
rm -f "$MARKER"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
