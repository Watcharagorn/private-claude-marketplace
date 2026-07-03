#!/usr/bin/env bash
# research-dispatch-tracker.sh — PreToolUse:Agent|Task
#
# Records that the main thread DELEGATED to a subagent during the plan phase by
# touching `.research-dispatched` in the repo-scoped plans dir. That flag does two
# jobs for the always-delegate-planning floor:
#   • it satisfies the floor — plan-read-gate.sh stops gating once it exists; and
#   • it self-disables the read gate for the subagents' OWN reads (they inherit the
#     parent's cwd, so without this they'd be gated too → deadlock).
#
# It ALSO records the always-delegate-AUTHORING floor (plan-author-gate.sh): when the
# dispatched Task/Agent is the plan-AUTHOR — its prompt (or description) carries the
# token `mentor:plan-author`, or its subagent_type is `Plan` (documented fallback) —
# it touches `.plan-authored`, which lets the main thread write the plan file.
#
# It NEVER blocks — it only records. Inert when no `.planning` marker exists, so it
# is a complete no-op outside the plugin-owned plan phase. Fail-open on any error.

set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL_NAME" in
  Task|Agent) ;;
  *) exit 0 ;;
esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"
[ -z "$repo_root" ] && exit 0
plans_dir="$(mentor_plans_dir "$repo_root")"

[ -f "${plans_dir}/.planning" ] || exit 0
: > "${plans_dir}/.research-dispatched" 2>/dev/null || true

# Also record a plan-AUTHOR dispatch (for plan-author-gate.sh). `prompt` and
# `subagent_type` are documented Agent tool_input fields; `description` is greppped
# defensively (empty if absent).
DESC="$(printf '%s' "$INPUT" | jq -r '.tool_input.description // ""' 2>/dev/null)" || true
PROMPT="$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null)" || true
SUBTYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)" || true
if printf '%s' "${DESC}${PROMPT}" | grep -q 'mentor:plan-author'; then
  : > "${plans_dir}/.plan-authored" 2>/dev/null || true
elif [ "$SUBTYPE" = "Plan" ]; then
  : > "${plans_dir}/.plan-authored" 2>/dev/null || true
fi
exit 0
