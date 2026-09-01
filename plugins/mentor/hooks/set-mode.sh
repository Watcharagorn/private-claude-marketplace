#!/usr/bin/env bash
# set-mode.sh — read/write the persisted per-repo mentor defaults, on TWO axes.
#
# Usage: set-mode.sh [plan|plan-only|agents|verify-only|status]
#        (bare = status)
#
# Both axes live in <repo_root>/.mentor/config.json and are independent — setting one
# never clears the others.
#
# AXIS 1, "mode" — the APPROVAL-GATE DEFAULT. Decides only which option the
# plan-approval question lists FIRST; both outcomes are always offered there:
#   plan      — "Proceed" listed first (plan, then implement on approval).
#   plan-only — "Deliver plan only" listed first (the plan file is the deliverable).
# Unset behaves as plan. The mode never blocks execution and is never asked
# for upfront — /mentor:plan works without it.
#
# AXIS 2, "dispatch" — where implementation and verification RUN. Unset is the ordinary
# state: no override, route per dispatch-agents' "Where dispatch pays" test.
#   agents      — route per the skill. An explicit opt-in, which also silences a
#                 false-positive policy hit in a repo that merely discusses agents.
#   verify-only — implementation in the main thread, verification still dispatched.
#                 The strongest honor of a standing no-subagents instruction: mentor has
#                 no mode that retires the verification round (a `solo` value existed
#                 until v3.0.0 and did; it was removed because the independent grader is
#                 the one thing a plan cannot substitute for itself).
# Recording a value is what stops `plan-state.sh policy` re-raising the same question at
# every dispatch surface in every session: it prints POLICY: SET and the surfaces obey.
#
# Status output contract (consumed by commands/mode.md and the plan skill):
#   "mode: <mode>" and "dispatch: <value>", with the literal token "UNSET" on the line
#   for whichever axis has nothing persisted.

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

# write_key <json-key> <value> — persist one axis, preserving every other key. Every axis
# shares this: the merge-or-create dance is where a hand-rolled second copy would drop
# another axis, which is exactly the bug an independent-axes design must not have.
write_key() {
  local key="$1" val="$2" tmp
  mkdir -p -m 700 "$state_dir"
  mentor_ensure_gitignore "$state_dir"
  if [ -f "$config" ]; then
    tmp="$(mktemp "${state_dir}/.config.XXXXXX")"
    jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$config" > "$tmp" && mv "$tmp" "$config"
  else
    jq -n --arg k "$key" --arg v "$val" '{($k): $v}' > "$config"
  fi
}

case "$arg" in
  status)
    mode="$(mentor_get_mode "$repo_root")"
    if [ -z "$mode" ]; then
      echo "UNSET — no approval default persisted for this repo (behaves as plan: \"Proceed\" listed first)."
      echo "  config: ${config}"
      echo "  Set one with: /mentor:mode plan | plan-only"
    else
      echo "mode: ${mode}"
      echo "  config: ${config}"
    fi
    dispatch="$(mentor_get_dispatch "$repo_root")"
    if [ -z "$dispatch" ]; then
      echo "dispatch: UNSET — no override; mentor routes per dispatch-agents' \"Where dispatch pays\" test."
      echo "  Record one with: /mentor:mode agents | verify-only"
    else
      echo "dispatch: ${dispatch}"
    fi
    exit 0
    ;;
  plan|plan-only)
    write_key mode "$arg"
    echo "[mentor mode] mode set: ${arg}"
    echo "  config: ${config}"
    case "$arg" in
      plan)
        echo "  plan — approval question lists \"Proceed\" first; \"Deliver plan only\" stays available."
        ;;
      plan-only)
        echo "  plan-only — approval question lists \"Deliver plan only\" first; \"Proceed\" stays"
        echo "  available. This is a default, not a lock — the choice is made at each approval."
        ;;
    esac
    exit 0
    ;;
  agents|verify-only)
    write_key dispatch "$arg"
    echo "[mentor mode] dispatch set: ${arg}"
    echo "  config: ${config}"
    case "$arg" in
      agents)
        echo "  agents — route per dispatch-agents' \"Where dispatch pays\": verification, review and"
        echo "  research dispatch; implementation dispatches when 2+ file-disjoint steps can run at"
        echo "  once, or a single step's context cost would flood the main thread."
        ;;
      verify-only)
        echo "  verify-only — implementation in the main thread, verification still dispatched to"
        echo "  fresh agents. Keeps independent grading, which is the part worth not losing."
        ;;
    esac
    echo "  \`plan-state.sh policy\` now reports POLICY: SET, so no dispatch surface will ask again."
    exit 0
    ;;
  *)
    echo "[mentor mode] Unknown mode: ${arg}" >&2
    echo "Usage: set-mode.sh [plan | plan-only | agents | verify-only | status]" >&2
    echo "  plan|plan-only            approval-gate default" >&2
    echo "  agents|verify-only        where implementation runs (verification always dispatches)" >&2
    exit 1
    ;;
esac
