#!/usr/bin/env bash
# handoff-check.sh — SessionStart
#
# Advisory nudge: when a session opens fresh in a repo that already carries a live
# (unresolved) mentor handoff note, print a one-line notice pointing at it so the
# session doesn't restate work a prior one already recorded. mentor's only other
# handoff-awareness (context-gate.sh's ASK tier) is reactive — it checks for a fresh
# note purely to suppress its own context-limit question once context has already
# ballooned past the ask threshold. This fires at the start instead, while context is
# still small. Fires on "startup" and "clear" — both put the next prompt in front of a
# thread with nothing about the note in it; "resume" and "compact" already carry the
# thread, so re-announcing here would just be noise.
#
# Points at /mentor:plan instead of /mentor:resume when the note's topic still has no
# plan.md — recommending /mentor:resume there would just produce another handoff note
# on the same plan-less topic, the exact loop this hook exists to interrupt.
#
# Kill switch: MENTOR_HANDOFF_CHECK=off (env) or "handoff_check":"off" in
# .mentor/config.json (read-only lookup — never creates config.json or .mentor/).
#
# Fail-soft everywhere: no jq / no live note / stale note (>14 days, likely parked
# rather than actionable) → exit 0. Never blocks session start.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh"

INPUT="$(cat)" || exit 0

SOURCE="$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null)" || exit 0
case "$SOURCE" in startup|clear) ;; *) exit 0 ;; esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"

# Kill switch (env, or per-repo config when one already exists — read-only, never
# creates .mentor/ or config.json).
case "${MENTOR_HANDOFF_CHECK:-}" in
  off|0|false|no) exit 0 ;;
esac
[ "$(mentor_config_get "$repo_root" "handoff_check")" = "off" ] && exit 0

latest="$(mentor_latest_handoff "$repo_root")"
[ -z "$latest" ] && exit 0
# Dormant topic — a note this old is likelier parked than actionable; stop nagging
# rather than firing at every session start indefinitely.
[ -n "$(find "$latest" -mtime -14 2>/dev/null)" ] || exit 0

count="$(mentor_live_handoff_count "$repo_root")"
slug="${latest##*/}"; slug="${slug%.md}"
slug="${slug#[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-}"

focus="$(awk '
  /^#+[[:space:]].*[Gg]oal.*next-session focus/ { infocus=1; next }
  infocus && /^#+[[:space:]]/ { exit }
  infocus && NF { print; exit }
' "$latest" 2>/dev/null)"
[ -z "$focus" ] && focus="(no focus section)"

# plan.md lives at the topic's own dir, two levels above the note (…/plans/<topic>/handoffs/<note>.md).
# Legacy flat notes (no /plans/<topic>/handoffs/ prefix) predate the topic-folder structure and have
# no plan.md concept — always route those to /mentor:resume.
topic_dir=""
case "$latest" in
  */plans/*/handoffs/*) topic_dir="$(dirname "$(dirname "$latest")")" ;;
esac

if [ -n "$topic_dir" ] && [ ! -f "${topic_dir}/plan.md" ]; then
  cmd="/mentor:plan $(basename "$topic_dir")"
else
  cmd="/mentor:resume ${slug}"
fi

echo "[mentor] ${count} live handoff note(s) in this repo — newest: \`${slug}\` (${focus}). Run ${cmd} to continue instead of starting cold. (Disable with MENTOR_HANDOFF_CHECK=off or \"handoff_check\":\"off\" in .mentor/config.json.)"
exit 0
