#!/usr/bin/env bash
# skill-creator-gate-mark.sh — PostToolUse (Skill)
#
# Companion to skill-creator-gate.sh: once /skill-creator:skill-creator has
# actually been invoked this session (namespaced or bare — real transcripts
# sometimes drop the namespace), write the marker that silences the
# PreToolUse reminder for every subsequent skill edit this session. The
# gate's job is to get the skill loaded once, not to nag after it has been.
#
# Fail-soft: no jq / unparsable input / not a skill-creator invocation → exit 0.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat)" || exit 0

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
[ "$TOOL_NAME" = "Skill" ] || exit 0

SKILL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // ""' 2>/dev/null)" || exit 0
case "$SKILL_NAME" in
  *skill-creator*) ;;
  *) exit 0 ;;
esac

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null)" || SESSION_ID="nosession"
: > "/tmp/claude-skill-creator-gate-${SESSION_ID}" 2>/dev/null || true
exit 0
