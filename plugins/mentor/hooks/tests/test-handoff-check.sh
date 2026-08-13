#!/usr/bin/env bash
# Regression tests for hooks/handoff-check.sh — the SessionStart advisory that nudges a
# fresh session toward this repo's live mentor handoff note instead of starting cold.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
for dep in "$HOOKS/handoff-check.sh" "$HOOKS/lib/state.sh"; do
  [ -f "$dep" ] || { echo "FATAL: $dep not found"; exit 1; }
done

ROOT="$(mktemp -d)"
SANDBOX="$ROOT/home"
mkdir -p "$SANDBOX"
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/repo"
git init -q -b main "$REPO" >/dev/null
( cd "$REPO" && git config user.email t@t.co && git config user.name t \
  && echo x > f && git add -A && git commit -q -m init ) >/dev/null

PASS=0; FAIL=0
chk() {  # chk <description> <predicate...>
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   — $desc"
  else FAIL=$((FAIL+1)); echo "FAIL — $desc"; fi
}

# run <source> <cwd> — feed handoff-check.sh one SessionStart input under sandbox $HOME.
run() {
  ( export HOME="$SANDBOX"
    printf '{"source":"%s","cwd":"%s"}' "$1" "$2" | bash "$HOOKS/handoff-check.sh" )
}
# run_env <ENVVAR=val> <source> <cwd> — same, with one extra env var exported.
run_env() {
  ( export HOME="$SANDBOX"; export "$1"
    printf '{"source":"%s","cwd":"%s"}' "$2" "$3" | bash "$HOOKS/handoff-check.sh" )
}
fires()      { [ -n "$(run "$1" "$2")" ]; }
silent()     { [ -z "$(run "$1" "$2")" ]; }
silent_env() { [ -z "$(run_env "$1" "$2" "$3")" ]; }
contains()   { case "$(run "$1" "$2")" in *"$3"*) return 0 ;; *) return 1 ;; esac; }
raw_ok()     { ( export HOME="$SANDBOX"; printf '%s' "$1" | bash "$HOOKS/handoff-check.sh" >/dev/null ); }

# write_note <topic> <ts> <focus-line> — a conforming topic-folder handoff note, mtime = now.
write_note() {
  local dir="$REPO/.mentor/plans/$1/handoffs"
  mkdir -p "$dir"
  printf '# Handoff\n\n## Goal / next-session focus\n%s\n' "$3" > "$dir/$2-$1.md"
}

echo "== A. source gating — only startup/clear fire =="
write_note "gate-topic" "20260810-000000" "Fix the pane overflow toggle."
chk "startup fires"               fires  startup "$REPO"
chk "clear fires"                 fires  clear   "$REPO"
chk "resume stays silent"         silent resume  "$REPO"
chk "compact stays silent"        silent compact "$REPO"
chk "unknown source stays silent" silent weird   "$REPO"
rm -rf "$REPO/.mentor"

echo "== B. no live note anywhere -> silent =="
chk "no notes at all -> silent" silent startup "$REPO"

echo "== C. plan.md branching =="
write_note "plan-topic" "20260810-000000" "Wire the retry queue."
chk "no plan.md -> routes to /mentor:plan <topic>" contains startup "$REPO" "/mentor:plan plan-topic"
mkdir -p "$REPO/.mentor/plans/plan-topic"
touch "$REPO/.mentor/plans/plan-topic/plan.md"
chk "plan.md present -> routes to /mentor:resume <slug>" contains startup "$REPO" "/mentor:resume plan-topic"
rm -rf "$REPO/.mentor"

echo "== D. legacy flat notes -- always /mentor:resume, no plan.md check attempted =="
mkdir -p "$REPO/.mentor/handoffs"
printf '# Handoff\n\n## Goal / next-session focus\nLegacy topic-less note.\n' \
  > "$REPO/.mentor/handoffs/20260810-000000-legacy-slug.md"
chk "legacy note -> /mentor:resume <slug>"        contains startup "$REPO" "/mentor:resume legacy-slug"
out_legacy="$(run startup "$REPO")"
chk "legacy note -> never routed to /mentor:plan" bash -c "case '$out_legacy' in *'/mentor:plan'*) exit 1;; *) exit 0;; esac"
rm -rf "$REPO/.mentor"

echo "== E. focus extraction =="
mkdir -p "$REPO/.mentor/plans/focus-topic/handoffs"
printf '# Handoff\n\n## Goal / next-session focus\nThe exact focus line.\n' \
  > "$REPO/.mentor/plans/focus-topic/handoffs/20260810-000000-focus-topic.md"
chk "focus line surfaced verbatim" contains startup "$REPO" "The exact focus line."
rm -rf "$REPO/.mentor"
mkdir -p "$REPO/.mentor/plans/nofocus-topic/handoffs"
printf '# Handoff\n\nJust a paragraph, no canonical heading.\n' \
  > "$REPO/.mentor/plans/nofocus-topic/handoffs/20260810-000000-nofocus-topic.md"
chk "missing focus section -> fallback label" contains startup "$REPO" "(no focus section)"
rm -rf "$REPO/.mentor"

echo "== F. freshness -- a note older than 14 days is treated as parked, not nagged =="
mkdir -p "$REPO/.mentor/plans/stale-topic/handoffs"
STALE_NOTE="$REPO/.mentor/plans/stale-topic/handoffs/20260101-000000-stale-topic.md"
printf '# Handoff\n\n## Goal / next-session focus\nOld work.\n' > "$STALE_NOTE"
touch -t 202601010000 "$STALE_NOTE"
chk "note older than 14 days -> silent" silent startup "$REPO"
rm -rf "$REPO/.mentor"

echo "== G. live-note count in the advisory =="
write_note "count-a" "20260810-000000" "First topic."
write_note "count-b" "20260811-000000" "Second topic."
chk "counts every live note, not just the newest" contains startup "$REPO" "2 live handoff note(s)"
rm -rf "$REPO/.mentor"

echo "== H. kill switch =="
write_note "kill-topic" "20260810-000000" "Should be suppressed."
chk "MENTOR_HANDOFF_CHECK=off (env) suppresses" silent_env "MENTOR_HANDOFF_CHECK=off" startup "$REPO"
mkdir -p "$REPO/.mentor"
printf '{"handoff_check":"off"}' > "$REPO/.mentor/config.json"
chk "\"handoff_check\":\"off\" in .mentor/config.json suppresses" silent startup "$REPO"
rm -f "$REPO/.mentor/config.json"
rm -rf "$REPO/.mentor/plans"

echo "== I. no repo / no _no-repo notes -> silent, never errors =="
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"
chk "non-git cwd, no _no-repo notes -> silent" silent startup "$NONGIT"
chk "non-git cwd -> hook still exits 0" bash -c "
  export HOME='$SANDBOX'
  printf '{\"source\":\"startup\",\"cwd\":\"$NONGIT\"}' | bash '$HOOKS/handoff-check.sh'"

echo "== J. malformed / empty stdin never aborts =="
chk "empty stdin -> exits 0"    raw_ok ""
chk "non-JSON stdin -> exits 0" raw_ok "not json"

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
