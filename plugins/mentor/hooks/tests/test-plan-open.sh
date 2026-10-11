#!/usr/bin/env bash
# test-plan-open.sh — regression tests for plan-open.sh
#
# Builds a real git repo, derives the repo-scoped plans dir exactly as the hook does, writes a
# fixture plan.md, and drives the hook with PostToolUse:Write JSON under MENTOR_PLAN_OPEN_DRYRUN
# (each opener prints its name instead of launching anything). Asserts opener SELECTION per
# MENTOR_PLAN_OPENER, the no-op cases (off-switch, non-plan paths, open-once marker), and the
# plan-and-page sync reminder (additionalContext when the plan has a review page). The ambient
# VSCode env vars are cleared in the base runner so the result doesn't depend on whether the
# test itself runs inside VSCode's integrated terminal.
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
REVIEW_DIR="$repo_root/.mentor/reviews/sample-plan"   # mentor:previewing's page for this plan
mkdir -p "$PLAN_DIR"
PLAN="$PLAN_DIR/plan.md"
MARKER="$PLAN_DIR/.plan.md.opened"
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
ok()  { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }

echo "== C. No-op cases (no opener selected) =="
check "" "off-switch MENTOR_PLAN_OPEN=off on plan.md -> no-op" "$PLAN" MENTOR_PLAN_OPEN=off
check "" "non-plan path -> no-op"                              "$ROOT/random.html"

echo "== C2. Path pattern: only plans/<slug>/plan.md =="
TOUR_HTML="$repo_root/.mentor/tours/sample-user.html"; mkdir -p "$repo_root/.mentor/tours"; : > "$TOUR_HTML"
check "" "tour html in tours/ -> no-op (published, never auto-opened)" "$TOUR_HTML"
LEGACY_HTML="$PLANS_DIR/legacy-flat.html"; : > "$LEGACY_HTML"
check "" "legacy flat html in plans/ -> no-op"        "$LEGACY_HTML"
LEGACY_MD="$PLANS_DIR/legacy-flat.md"; : > "$LEGACY_MD"
check "" "legacy flat md in plans/ -> no-op"          "$LEGACY_MD"
STRAY_HTML="$PLAN_DIR/stray.html"; : > "$STRAY_HTML"
check "" "html beside plan.md -> no-op"               "$STRAY_HTML"
STRAY_MD="$PLAN_DIR/notes.md"; : > "$STRAY_MD"
check "" "non-plan.md md inside <slug>/ -> no-op"      "$STRAY_MD"
mkdir -p "$REVIEW_DIR"; PAGE="$REVIEW_DIR/review.html"; : > "$PAGE"
check "" "review page in reviews/<slug>/ -> no-op (previewing opens its own page)" "$PAGE"
rm -f "$TOUR_HTML" "$LEGACY_HTML" "$LEGACY_MD" "$STRAY_HTML" "$STRAY_MD" "$PAGE"

echo "== C3. plans/<slug>/tour/ is NOT an opener location (plan-touring removed in v3.0.0) =="
PLAN_TOUR_DIR="$PLAN_DIR/tour"; mkdir -p "$PLAN_TOUR_DIR"
PLAN_TOUR_HTML="$PLAN_TOUR_DIR/whole-plan-system-architect.html"; : > "$PLAN_TOUR_HTML"
check "" "leftover tour/ html -> no-op"               "$PLAN_TOUR_HTML"
NOREPO_TOUR_DIR="$ROOT/.claude/mentor/_no-repo/plans/sample-plan/tour"; mkdir -p "$NOREPO_TOUR_DIR"
NOREPO_TOUR_HTML="$NOREPO_TOUR_DIR/whole-plan-system-architect.html"; : > "$NOREPO_TOUR_HTML"
check "" "_no-repo leftover tour/ html -> no-op"      "$NOREPO_TOUR_HTML"
rm -rf "$PLAN_TOUR_DIR" "$NOREPO_TOUR_DIR"

echo "== E. Markdown plans: prefer a VSCode tab, never raw-text Chrome =="
check vscode "md auto (not in VSCode) -> vscode (prefer tab, not Chrome)" "$PLAN"
check vscode "md auto + VSCODE_PID -> vscode"                            "$PLAN" VSCODE_PID=123
check vscode "md forced vscode -> vscode"                                "$PLAN" MENTOR_PLAN_OPENER=vscode
check system "md forced chrome -> system (Chrome can't render raw .md)"   "$PLAN" MENTOR_PLAN_OPENER=chrome
check system "md forced system -> system"                                "$PLAN" MENTOR_PLAN_OPENER=system
check ""     "md off-switch -> no-op"                                    "$PLAN" MENTOR_PLAN_OPEN=off
rm -f "$PLAN" "$MARKER"

echo "== D. Open-once: marker present -> no-op =="
: > "$PLAN"   # section E removed it; without the file the hook would pass on [ -f ] instead of on the marker
: > "$MARKER"
got="$(run "$PLAN")"
if [ -z "$got" ]; then PASS=$((PASS+1)); printf "  ok   [<none>] marker present -> no re-open\n"
else FAIL=$((FAIL+1)); printf "  FAIL want=%q got=%q: marker present -> no re-open\n" "" "$got"; fi
rm -f "$MARKER"

echo "== F. Plan and page in sync: reminder when the plan has a review page =="
mkdir -p "$REVIEW_DIR"; : > "$REVIEW_DIR/review.html"
reminder_ok() { # desc output
  if printf '%s\n' "$2" | head -1 | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | test("mentor:previewing §7"))' >/dev/null 2>&1; then
    ok "$1"
  else
    bad "$1 (got: $2)"
  fi
}
: > "$MARKER"
reminder_ok "page exists + .opened present -> reminder printed" "$(run "$PLAN")"
reminder_ok "page exists + MENTOR_PLAN_OPEN=off -> reminder printed" "$(run "$PLAN" MENTOR_PLAN_OPEN=off)"
rm -f "$MARKER"
out="$(run "$PLAN")"
reminder_ok "page exists, first open -> reminder printed" "$out"
[ "$(printf '%s\n' "$out" | tail -1)" = "vscode" ] && ok "page exists, first open -> plan still opens (vscode)" \
  || bad "page exists, first open -> plan still opens (got: $out)"
out="$(run "$REVIEW_DIR/review.html")"
[ -z "$out" ] && ok "Write of the page itself -> silent" || bad "Write of the page itself -> silent (got: $out)"
rm -rf "$REVIEW_DIR"
: > "$MARKER"
out="$(run "$PLAN")"
[ -z "$out" ] && ok "no page -> silent" || bad "no page -> silent (got: $out)"
rm -f "$MARKER"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
