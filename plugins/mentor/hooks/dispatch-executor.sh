#!/usr/bin/env bash
# PostToolUse:ExitPlanMode — detects dispatch strategies and injects a
# mandatory directive telling Claude to dispatch agents per the plan.
# Exit 0 always (post-hooks cannot block).

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

input=$(cat) || exit 0

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
[[ "$tool_name" != "ExitPlanMode" ]] && exit 0

# Resolve plan body across ExitPlanMode shapes — see strategy-guard.sh for
# the full rationale. Try plan_path, then legacy inline plan, then the
# most-recent *.md under the global plans dir (v0.13.0+), then the legacy
# in-repo "${cwd}/.claude/plans/" location for one-version migration.
plan_path=$(printf '%s' "$input" | jq -r '.tool_input.plan_path // ""' 2>/dev/null) || exit 0
plan_inline=$(printf '%s' "$input" | jq -r '.tool_input.plan // ""' 2>/dev/null) || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null) || exit 0

repo_root=$(mentor_repo_root "${cwd:-$PWD}")
global_plans_dir=""
[[ -n "$repo_root" ]] && global_plans_dir=$(mentor_plans_dir "$repo_root")

# plan-only repo mode: the plan is the deliverable — never emit a dispatch directive.
# This branch covers BOTH call sites (approve-plan.sh and the native PostToolUse:
# ExitPlanMode fallback), so plan-only cannot leak into execution via either path.
if [[ -n "$repo_root" ]] && [[ "$(mentor_get_mode "$repo_root")" == "plan-only" ]]; then
  cat << 'MSG'
PLAN-ONLY MODE — this repo's mentor mode is plan-only. The approved plan FILE is the
DELIVERABLE. Do NOT implement and do NOT dispatch implementation agents. Summarize
where the plan lives and STOP. (Switch with /mentor:mode plan to execute plans.)
MSG
  exit 0
fi

if [[ -n "$plan_path" && -r "$plan_path" ]]; then
  plan=$(cat "$plan_path")
elif [[ -n "$plan_inline" ]]; then
  plan="$plan_inline"
else
  fallback_file=""
  if [[ -n "$global_plans_dir" && -d "$global_plans_dir" ]]; then
    # v0.15.0: plans persist as .html (legacy .md honored one release). Newest wins.
    fallback_file=$(ls -t "${global_plans_dir}/"*.html "${global_plans_dir}/"*.md 2>/dev/null | head -1)
  fi
  if [[ -z "$fallback_file" && -n "$cwd" && -d "${cwd}/.claude/plans" ]]; then
    fallback_file=$(ls -t "${cwd}/.claude/plans/"*.html "${cwd}/.claude/plans/"*.md 2>/dev/null | head -1)
  fi
  if [[ -n "$fallback_file" && -r "$fallback_file" ]]; then
    plan=$(cat "$fallback_file")
  else
    plan=""
  fi
fi

# v0.15.0: extract the canonical Markdown from the HTML plan-source block when present.
if printf '%s' "$plan" | grep -q 'id="plan-source"'; then
  plan=$(printf '%s' "$plan" | sed -n '/<script[^>]*id="plan-source"/,/<\/script>/p' | sed '1d;$d')
fi

strategy=$(printf '%s' "$plan" | grep -E '^strategy:[[:space:]]*' | head -1 \
  | sed 's/^strategy:[[:space:]]*//' | tr -d '[:space:]' || true)

[[ "$strategy" == "dispatch" || "$strategy" == "worktree+dispatch" ]] || exit 0

# Format-aware read-back instruction: an HTML plan carries the canonical Markdown in a
# plan-source block; a Markdown plan IS its own canonical source (read it directly).
case "$(mentor_get_format "$repo_root")" in
  md)
    read_step='1. Read the plan file now (path shown in the plan mode system message). It is a
     Markdown document and IS its own canonical source — read the plan directly. The footer
     markers are bare lines at end-of-file; the [role: … · model: … · effort: …] annotations
     and the "Run in parallel:" / "Sequential:" groups are inline in the steps.'
    ;;
  *)
    read_step='1. Read the plan file now (path shown in the plan mode system message). It is an HTML
     document — read the canonical plan from the Markdown inside
     <script type="text/markdown" id="plan-source">…</script> (NOT the rendered body).
     The parallel/sequential groups and the [role: … · model: … · effort: …] annotations
     live in that Markdown block.'
    ;;
esac

cat <<MSG
ENHANCED-PLANNING DISPATCH ACTIVATED — PostToolUse:ExitPlanMode

This hook fires only after the user has APPROVED the plan via ExitPlanMode — dispatch is now
permitted. No implementation or editing should have occurred before this point; during plan mode
only read-only research agents (Explore, Plan, /plan-review) were allowed to run.

Strategy: DISPATCH — the approved plan contains annotated subagent steps.

Your MANDATORY next action (do not skip, do not continue inline):
  ${read_step}
  2. Find every "Run in parallel:" group — issue ALL their Agent() calls in ONE message.
  3. For each "Sequential:" step, wait for prior results before dispatching.
  4. After each agent completes, check its output against its "Done when:" criterion.

Dispatch the agents now.
MSG
