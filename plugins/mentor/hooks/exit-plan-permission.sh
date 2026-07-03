#!/usr/bin/env bash
# PermissionRequest:ExitPlanMode — deterministic post-approval permission mode.
#
# mentor-plan (Step 6) and dispatch-agents write the user's chosen
# proceed-mode to
#   <global-plans-dir>/.proceed-mode   (one of: acceptEdits | bypassPermissions | default)
# immediately before calling ExitPlanMode. When the exit's permission dialog would
# appear, this hook reads that marker, AUTO-APPROVES the exit, and switches the
# session into the chosen mode via updatedPermissions/setMode.
#
# This REPLACES the native ExitPlanMode approval modal for plugin-driven exits: the
# user's answer to the plugin's proceed-mode question (asked just before ExitPlanMode)
# is the sole approval gate, and this hook performs the approval + mode switch.
#
# One-shot: the marker is consumed (deleted) on read, so it only governs the exit it
# was written for. If no fresh marker exists, the hook emits NOTHING and exits 0 — the
# native ExitPlanMode modal then appears as normal (safe fallback for any non-plugin
# ExitPlanMode, or for `-p` non-interactive runs where PermissionRequest never fires).
#
# Mode notes:
#   acceptEdits / default  — always work (setMode is functional for these).
#   bypassPermissions      — only takes effect when the session was launched with
#                            bypass available (--dangerously-skip-permissions or
#                            permissions.defaultMode: bypassPermissions). On some CC
#                            builds (see anthropics/claude-code#49525) setMode bypass
#                            may no-op; the exit is still approved, mode just stays put.
#
# Fail-open: any parse/resolution error -> exit 0 with no output (never blocks exit).

set -euo pipefail

# jq is used by every hook in this plugin; degrade gracefully if it's somehow absent.
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

input=$(cat) || exit 0
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
[ "$tool_name" = "ExitPlanMode" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null) || exit 0
[ -n "$cwd" ] || exit 0

# Derive the global plans dir from cwd's git repo root (matches mentor-plan
# Step 6b and strategy-guard.sh exactly).
repo_root=$(mentor_repo_root "$cwd")
[ -n "$repo_root" ] || exit 0
marker="$(mentor_plans_dir "$repo_root")/.proceed-mode"

# No marker -> let the native modal handle approval.
[ -f "$marker" ] || exit 0

# Stale marker (>120 min, mirroring the plan-phase staleness window) -> discard
# and fall back to the native modal rather than honoring an abandoned choice.
if [ -n "$(find "$marker" -mmin +120 2>/dev/null)" ]; then
  rm -f "$marker" 2>/dev/null || true
  exit 0
fi

mode=$(tr -d '[:space:]' < "$marker" 2>/dev/null || true)
rm -f "$marker" 2>/dev/null || true   # one-shot: consume regardless of outcome

case "$mode" in
  acceptEdits|bypassPermissions|default) ;;
  *) exit 0 ;;                          # unknown value -> native modal
esac

# Auto-approve the exit AND switch the session to the chosen mode (session-scoped).
printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"setMode","mode":"%s","destination":"session"}]}}}\n' "$mode"
exit 0
