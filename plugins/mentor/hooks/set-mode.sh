#!/usr/bin/env bash
# set-mode.sh — read/write the persisted per-repo mentor WORKING MODE.
#
# Usage: set-mode.sh [plan|plan-only|status]    (bare = status)
#
# The mode lives in <repo_root>/.mentor/config.json as
# {"mode": "..."} :
#   plan      — default behavior (/mentor:plan plans, then executes on approval).
#               NOTE: does NOT force planning; it just names today's default.
#   plan-only — /mentor:plan runs fully, but after approval the plan file is the
#               deliverable: execution soft-stops (no dispatch, no implementation).
#
# Status output contract (consumed by commands/mode.md and the plan skill):
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

state_dir="$(mentor_state_dir "$repo_root")"
config="${state_dir}/config.json"
arg="$(printf '%s' "${1:-status}" | tr '[:upper:]' '[:lower:]')"

case "$arg" in
  status)
    mode="$(mentor_get_mode "$repo_root")"
    if [ -z "$mode" ]; then
      echo "UNSET — no mentor mode persisted for this repo."
      echo "  config: ${config}"
      echo "  Set one with: /mentor:mode plan | plan-only"
    else
      echo "mode: ${mode}"
      echo "  config: ${config}"
    fi
    exit 0
    ;;
  plan|plan-only)
    mkdir -p -m 700 "$state_dir"
    mentor_ensure_gitignore "$state_dir"
    if [ -f "$config" ]; then
      tmp="$(mktemp "${state_dir}/.config.XXXXXX")"
      jq --arg m "$arg" '.mode = $m' "$config" > "$tmp" && mv "$tmp" "$config"
    else
      jq -n --arg m "$arg" '{mode: $m}' > "$config"
    fi
    echo "[mentor mode] mode set: ${arg}"
    echo "  config: ${config}"
    case "$arg" in
      plan)
        echo "  plan — default behavior: /mentor:plan plans, then executes on approval."
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
    echo "Usage: set-mode.sh [plan | plan-only | status]" >&2
    exit 1
    ;;
esac
