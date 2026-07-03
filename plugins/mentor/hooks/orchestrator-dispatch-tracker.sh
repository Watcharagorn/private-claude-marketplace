#!/usr/bin/env bash
# orchestrator-dispatch-tracker.sh — PreToolUse:Agent|Task
#
# When orchestrator mode is ON (resolved repo/global config), records that the
# orchestrator delegated to a subagent THIS TURN by touching
# /tmp/mentor-orchestrator-dispatched-<session_id>. orchestrator-gate.sh reads that flag
# to STEP ASIDE on Read/Grep/Glob — so after the orchestrator dispatches, it can
# freely read returned artifacts and verify within the same turn (fixing mid-turn
# read starvation in the dispatch → verify → dispatch loop). orchestrator-prompt.sh
# clears the flag at the start of every turn.
#
# NEVER blocks — it only records. No-op when orchestrator is off. Fail-open on any error.

set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL_NAME" in
  Task|Agent) ;;
  *) exit 0 ;;
esac

SESSION_ID="$(mentor_session_id "$INPUT")"
CWD="$(mentor_cwd "$INPUT")"

repo_root="$(mentor_repo_root "$CWD")"
[ -n "$repo_root" ] || exit 0
mentor_orchestrator_on "$repo_root" || exit 0

: > "/tmp/mentor-orchestrator-dispatched-${SESSION_ID}" 2>/dev/null || true
exit 0
