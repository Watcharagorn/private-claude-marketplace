#!/usr/bin/env bash
# set-mode.sh — read/write the persisted per-repo mentor defaults, on THREE axes.
#
# Usage: set-mode.sh [plan|plan-only|agents|solo|verify-only|instant-on|instant-off|status]
#        (bare = status)
#
# All axes live in <repo_root>/.mentor/config.json and are independent — setting one
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
#   solo        — implementation AND verification stay in the main thread. Gives up
#                 independent grading, so the plan's report has to disclose that.
#   verify-only — implementation in the main thread, verification still dispatched.
# Recording a value is what stops `plan-state.sh policy` re-raising the same question at
# every dispatch surface in every session: it prints POLICY: SET and the surfaces obey.
#
# AXIS 3, "instant" — UNATTENDED CONTINUATION (v2.37.0). May dispatch-agents' per-step
# loop run a granted plan to completion without a human in the turn? Unset behaves as
# ON — the default is deliberate: the loop runs nothing until `plan-state.sh instant`
# answers GO, and every stop it can hit fails toward a question, never toward work
# (see mentor_get_instant in lib/state.sh for the full rationale).
#   instant-on  — the loop runs whenever the ladder clears (per-plan branch,
#                 end-of-run auto-commit on that branch, push/PR still questions).
#   instant-off — restore the attended flow end to end.
#
# Status output contract (consumed by commands/mode.md and the plan skill):
#   "mode: <mode>", "dispatch: <value>" and "instant: <value>", with the literal token
#   "UNSET" on the line for whichever axis has nothing persisted.

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
      echo "  Record one with: /mentor:mode agents | solo | verify-only"
    else
      echo "dispatch: ${dispatch}"
    fi
    instant="$(mentor_get_instant "$repo_root")"
    if [ -z "$instant" ]; then
      echo "instant: UNSET — behaves as on (unattended continuation runs when plan-state.sh instant answers GO)."
      echo "  Override with: /mentor:mode instant-off"
    else
      echo "instant: ${instant}"
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
  agents|solo|verify-only)
    write_key dispatch "$arg"
    echo "[mentor mode] dispatch set: ${arg}"
    echo "  config: ${config}"
    case "$arg" in
      agents)
        echo "  agents — route per dispatch-agents' \"Where dispatch pays\": verification, review and"
        echo "  research dispatch; implementation dispatches when 2+ file-disjoint steps can run at"
        echo "  once, or a single step's context cost would flood the main thread."
        ;;
      solo)
        echo "  solo — implementation AND verification stay in the main thread. This gives up the"
        echo "  independent grader, so a plan closed this way must say so in its report; pick"
        echo "  verify-only instead if you want in-thread edits but real verification. (An"
        echo "  instant run's per-step prose-criterion verifier still dispatches, disclosed.)"
        ;;
      verify-only)
        echo "  verify-only — implementation in the main thread, verification still dispatched to"
        echo "  fresh agents. Keeps independent grading, which is the part worth not losing."
        ;;
    esac
    echo "  \`plan-state.sh policy\` now reports POLICY: SET, so no dispatch surface will ask again."
    exit 0
    ;;
  instant-on|instant-off)
    write_key instant "${arg#instant-}"
    echo "[mentor mode] instant set: ${arg#instant-}"
    echo "  config: ${config}"
    case "$arg" in
      instant-on)
        echo "  on — dispatch-agents' unattended loop runs a granted plan to completion when"
        echo "  \`plan-state.sh instant\` answers GO: per-plan branch, end-of-run auto-commit on"
        echo "  that branch; push/PR/merge stay questions. (Unset already behaves as on — record"
        echo "  it only to survive a later instant-off.)"
        ;;
      instant-off)
        echo "  off — attended flow end to end: no per-plan branch, no auto-commit, every"
        echo "  closing question intact."
        ;;
    esac
    exit 0
    ;;
  *)
    echo "[mentor mode] Unknown mode: ${arg}" >&2
    echo "Usage: set-mode.sh [plan | plan-only | agents | solo | verify-only | instant-on | instant-off | status]" >&2
    echo "  plan|plan-only            approval-gate default" >&2
    echo "  agents|solo|verify-only   where implementation and verification run" >&2
    echo "  instant-on|instant-off    unattended continuation (unset behaves as on)" >&2
    exit 1
    ;;
esac
