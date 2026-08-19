#!/usr/bin/env bash
# skill-invoked-mark.sh — PostToolUse (Skill)
#
# Generic companion for this repo's warn-only skill gates: when the named skill
# is actually invoked in a session, write the marker that silences its
# PreToolUse reminder for the rest of that session. A gate's job is to get the
# skill loaded once, not to keep nagging after it has been.
#
#   usage: skill-invoked-mark.sh <skill-name-substring> <marker-prefix>
#     e.g. skill-invoked-mark.sh skill-creator       skill-creator-gate
#          skill-invoked-mark.sh instruction-hygiene instruction-hygiene-gate
#
# The marker path is /tmp/claude-<marker-prefix>-<session_id>, which is the path
# the matching gate script checks. Matching is a substring so both the
# namespaced and bare skill names count — real transcripts carry either.
#
# One script serves every gate on purpose: two near-identical marker scripts is
# the duplication the instruction-hygiene skill exists to remove.
#
# Fail-soft: no jq / unparsable input / missing args / other skill → exit 0.
# Never brick a session over a reminder.

set -euo pipefail

MATCH="${1:-}"
PREFIX="${2:-}"
[ -n "$MATCH" ] && [ -n "$PREFIX" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat)" || exit 0

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
[ "$TOOL_NAME" = "Skill" ] || exit 0

SKILL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // ""' 2>/dev/null)" || exit 0
case "$SKILL_NAME" in
  *"$MATCH"*) ;;
  *) exit 0 ;;
esac

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null)" || SESSION_ID="nosession"
: > "/tmp/claude-${PREFIX}-${SESSION_ID}" 2>/dev/null || true
exit 0
