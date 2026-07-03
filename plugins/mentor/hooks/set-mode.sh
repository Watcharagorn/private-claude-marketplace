#!/usr/bin/env bash
# set-mode.sh — read/write the persisted per-repo mentor WORKING MODE.
#
# Usage: set-mode.sh [plan|plan-only|status]    (bare = status)
#
# The mode lives in ~/.claude/mentor/{repo_base}-{repo_hash}/config.json as
# {"mode": "..."} :
#   plan      — default behavior (plan harness plans, then executes on approval).
#               NOTE: does NOT force planning; it just names today's default.
#   plan-only — /mentor:plan runs fully, but after approval the plan file is the
#               deliverable: execution soft-stops (no dispatch, no implementation).
# `commander` is no longer a mode — it became the orthogonal `orchestrator` toggle
# (set-orchestrator.sh / /mentor:orchestrator). A `commander` arg here REDIRECTS:
# it sets mode=plan + orchestrator=true (and one-shot-migrates legacy configs).
#
# Ownership: this script owns the `.mode` key (merges atomically, preserving
# `.orchestrator`). set-orchestrator.sh owns `.orchestrator`. Neither touches /tmp flags.
#
# Status output contract (consumed by commands/mode.md and mentor-plan SKILL Step 6):
#   "mode: <mode>"  or the literal token "UNSET" when no mode is persisted.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "[mentor mode] jq is required." >&2; exit 1; }

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${hook_dir}/lib/state.sh"

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  echo "[mentor mode] Not inside a git repo — mentor mode is per-repo. cd into a repo first." >&2
  exit 1
fi

mentor_migrate_legacy_commander "$repo_root"   # one-shot normalize legacy {"mode":"commander"}

state_dir="$(mentor_state_dir "$repo_root")"
config="${state_dir}/config.json"
arg="$(printf '%s' "${1:-status}" | tr '[:upper:]' '[:lower:]')"

print_status() {
  local mode orch
  mode="$(mentor_get_mode "$repo_root")"
  if [ -z "$mode" ]; then
    echo "UNSET — no mentor mode persisted for this repo."
    echo "  config: ${config}"
    echo "  Set one with: /mentor:mode plan | plan-only"
  else
    echo "mode: ${mode}"
    echo "  config: ${config}"
  fi
  # orchestrator is an orthogonal toggle (owned by /mentor:orchestrator) — shown read-only.
  if mentor_orchestrator_on "$repo_root"; then orch="ON"; else orch="OFF"; fi
  echo "  orchestrator: ${orch} (change with /mentor:orchestrator on|off)"
}

case "$arg" in
  status)
    print_status
    exit 0
    ;;
  commander)
    # Redirect: commander is now the orthogonal orchestrator toggle. Honor the intent —
    # set mode=plan and turn orchestrator ON (repo scope) — then point at the new command.
    mkdir -p -m 700 "$state_dir"
    if [ -f "$config" ]; then
      tmp="$(mktemp "${state_dir}/.config.XXXXXX")"
      jq '.mode = "plan" | .orchestrator = true' "$config" > "$tmp" && mv "$tmp" "$config"
    else
      jq -n '{mode: "plan", orchestrator: true}' > "$config"
    fi
    echo "[mentor mode] 'commander' is now the orchestrator toggle — not a mode."
    echo "  Enabled orchestrator (repo) and set mode=plan."
    echo "  config: ${config}"
    echo "  Manage it with: /mentor:orchestrator on | off | status | clear"
    exit 0
    ;;
  plan|plan-only)
    mkdir -p -m 700 "$state_dir"
    if [ -f "$config" ]; then
      tmp="$(mktemp "${state_dir}/.config.XXXXXX")"
      jq --arg m "$arg" '.mode = $m' "$config" > "$tmp" && mv "$tmp" "$config"
    else
      jq -n --arg m "$arg" '{mode: $m}' > "$config"   # merge-safe create (preserves nothing yet)
    fi
    echo "[mentor mode] mode set: ${arg}"
    echo "  config: ${config}"
    case "$arg" in
      plan)
        echo "  plan — default behavior: /mentor:plan plans, then executes on approval."
        echo "  (Note: this mode does NOT force planning; it names the default flow.)"
        ;;
      plan-only)
        echo "  plan-only — plans are the deliverable: /mentor:plan runs fully, but after"
        echo "  approval execution SOFT-STOPS (no implementation, no dispatch). Switch back"
        echo "  with /mentor:mode plan to execute plans again."
        ;;
    esac
    exit 0
    ;;
  *)
    echo "[mentor mode] Unknown mode: ${arg}" >&2
    echo "Usage: set-mode.sh [plan | plan-only | status]   (orchestration: /mentor:orchestrator)" >&2
    exit 1
    ;;
esac
