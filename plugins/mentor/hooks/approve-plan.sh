#!/usr/bin/env bash
# approve-plan.sh — validate the plan, release the plan-phase gate, emit dispatch directive.
#
# Run by the mentor-plan / dispatch-agents skill when the user chooses
# "Proceed" in the plugin-OWNED flow (it replaces the ExitPlanMode + .proceed-mode
# path; there is no ExitPlanMode call). It:
#   1. locates the newest HTML plan in the repo-scoped plans dir;
#   2. validates it by DELEGATING to strategy-guard.sh — the single source of
#      truth for footer markers + HTML freshness — via a synthetic plan_path JSON;
#   3. on success: deletes .planning / .research-dispatched / .read-budget / .proceed-mode
#      (the gate OPENS — repo edits are now allowed), then runs dispatch-executor.sh
#      so dispatch / worktree+dispatch plans get their fan-out directive;
#   4. on failure: surfaces strategy-guard's exact error, leaves .planning in place
#      (the gate STAYS CLOSED), and exits non-zero.
#
# --handoff mode: same validation + gate release, but INSTEAD of dispatching it prints
# a hand-off directive (approve the plan, then write a /mentor:handoff doc for the next
# agent and STOP) and exits before the plan-only block and dispatch-executor.sh — so no
# dispatch directive is ever emitted on the hand-off path, for any strategy. This printed
# directive is the SINGLE source of truth for the hand-off instruction; the owned-flow
# SKILL handlers defer to it rather than restating it.
#
# Validation stays unbypassable: the gate cannot open with a malformed plan, and no
# ExitPlanMode is involved.

set -euo pipefail

# --handoff: approve + release the gate, then hand off instead of implementing/dispatching.
# The ${1:-} guard keeps arg-less callers (the Proceed path) working under `set -u`.
handoff_mode=0
[ "${1:-}" = "--handoff" ] && handoff_mode=1

command -v jq >/dev/null 2>&1 || { echo "[mentor approve-plan] jq is required." >&2; exit 1; }

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${hook_dir}/lib/state.sh"
cwd="$(pwd)"

repo_root="$(mentor_repo_root "$cwd")"
if [ -z "$repo_root" ]; then
  echo "[mentor approve-plan] Not in a git repo — nothing to release." >&2
  exit 1
fi
repo_base="$(basename "$repo_root")"
repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
plans_dir="$(mentor_plans_dir "$repo_root")"
marker="${plans_dir}/.planning"

# Resolve the configured output format → deliverable extension + human label.
case "$(mentor_get_format "$repo_root")" in
  md) plan_ext="md";   plan_kind="Markdown" ;;
  *)  plan_ext="html"; plan_kind="styled HTML" ;;
esac

newest_plan="$(ls -t "${plans_dir}/"*."${plan_ext}" 2>/dev/null | head -1 || true)"
if [ -z "$newest_plan" ]; then
  # Legacy (pre-0.33) location — a session that started before the upgrade may have
  # written here after the markers migrated. Drop in 0.34.
  legacy_dir="${HOME}/.claude/mentor/plans/${repo_base}-${repo_hash}"
  newest_plan="$(ls -t "${legacy_dir}/"*."${plan_ext}" 2>/dev/null | head -1 || true)"
fi
if [ -z "$newest_plan" ]; then
  echo "[mentor approve-plan] No ${plan_kind} plan found in ${plans_dir}." >&2
  echo "Write the ${plan_kind} plan (mentor-plan Step 6b) before approving." >&2
  exit 1
fi

# Validate by delegating to strategy-guard.sh (markers + HTML freshness). It prints
# the exact missing-marker / missing-HTML message to stderr and exits 2 on failure.
synthetic="$(jq -nc --arg p "$newest_plan" --arg c "$cwd" \
  '{tool_name:"ExitPlanMode", cwd:$c, tool_input:{plan_path:$p}}')"

if ! printf '%s' "$synthetic" | bash "${hook_dir}/strategy-guard.sh"; then
  echo "" >&2
  echo "[mentor approve-plan] Plan REJECTED — the gate stays CLOSED and repo edits remain blocked." >&2
  echo "Fix the plan (re-write the ${plan_kind} plan per Step 6b), then choose \"Proceed\" again." >&2
  exit 1
fi

# Release the gate.
rm -f "$marker" \
      "${plans_dir}/.research-dispatched" \
      "${plans_dir}/.plan-authored" \
      "${plans_dir}/.read-budget" \
      "${plans_dir}/.proceed-mode" 2>/dev/null || true

echo "[mentor approve-plan] Plan APPROVED — gate released. Repo edits are now allowed."
echo "  plan: ${newest_plan}"

# Hand-off: the plan is approved and the gate is open, but implementation is deferred to
# a fresh agent. Print the directive and exit BEFORE the plan-only block and before
# dispatch-executor.sh — so no dispatch directive is emitted, for any strategy. (Validation
# above already ran, so a malformed plan exits 1 before reaching here — the gate cannot open
# on the hand-off path either.)
if [ "$handoff_mode" -eq 1 ]; then
  cat <<EOF

HAND-OFF REQUESTED — plan APPROVED and gate released. Do NOT implement and do NOT
dispatch implementation agents in this session. The approved plan file is:
  ${newest_plan}
Invoke Skill(skill="mentor:handoff") now to write the handoff document so the next
agent can pick up implementation from this plan, then STOP.
EOF
  exit 0
fi

# plan-only repo mode: the plan is the deliverable — no dispatch, no implementation.
if [ "$(mentor_get_mode "$repo_root")" = "plan-only" ]; then
  cat <<EOF

PLAN-ONLY MODE — gate released, but do NOT implement and do NOT dispatch
implementation agents. The plan file is the deliverable:
  ${newest_plan}
Summarize where it lives and STOP. (Switch with /mentor:mode plan to execute plans.)
EOF
  exit 0
fi

# Dispatch / worktree+dispatch plans: emit the fan-out directive (no-op otherwise).
printf '%s' "$synthetic" | bash "${hook_dir}/dispatch-executor.sh" || true

exit 0
