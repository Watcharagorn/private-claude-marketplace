#!/usr/bin/env bash
# UserPromptSubmit hook — plan-flow prompt entry.
#
# Two jobs:
#  A. CO-SUBMITTED /mentor:plan routing. When /mentor:plan is typed as ARGUMENT text after
#     another slash command (e.g. `/mentor:orchestrator on` + `/mentor:plan for X` in one prompt),
#     only the LEADING command executes — plan.md never loads, so begin-plan.sh never runs and
#     the plan harness never starts. The model then improvises a plan and (under orchestrator) the
#     in-repo plan Write is blocked. We detect a non-leading /mentor:plan token and inject a
#     directive routing the model into the real harness. Fires regardless of orchestrator state.
#  B. NATIVE plan mode at session START (permissionMode: "plan") rather than via an explicit
#     /plan command mid-session. The PostToolUse:EnterPlanMode hook never fires in that case,
#     so this fills the gap. Uses a per-session flag to inject the strategy instructions once.
#
# stdout is injected as model context. No `set -e` (optional ops); fail-open / silent.

input=$(cat)
permission_mode=$(echo "$input" | jq -r '.permissionMode // ""')
prompt=$(echo "$input" | jq -r '.prompt // ""')

# --- A. Route a co-submitted (non-leading) /mentor:plan into the real harness. ---
# The co-submit grep is `-`-boundary-safe (never matches /mentor:plan-review). The leading
# check uses head -n1 over non-empty lines (the true first token of the WHOLE prompt, not
# grep's per-line ^), so a LEADING /mentor:plan — which self-starts via plan.md → begin-plan.sh
# — is skipped (re-running begin-plan.sh would wipe mid-plan flags, begin-plan.sh:41-44).
if printf '%s' "$prompt" | grep -qE '(^|[[:space:]])/mentor:plan([[:space:]]|$)'; then
  first_line="$(printf '%s\n' "$prompt" | sed '/^[[:space:]]*$/d' | head -n1)"
  case "$first_line" in
    /mentor:plan|/mentor:plan[[:space:]]*) ;;   # leading → harness self-starts; do nothing
    *)
      HOOKS_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")"
      cat <<PLANROUTE
[mentor] A /mentor:plan request is in this prompt, but it was submitted as ARGUMENT text
(another slash command is leading) — so the plan harness did NOT auto-start. Do NOT author a
plan inline or Write a plan file into the repo; enter the harness now, in order:
  1. bash "${HOOKS_DIR}/begin-plan.sh"        (arms the plan phase)
  2. Skill(skill="mentor:mentor-plan")          (follow it end to end)
It persists its plan (HTML or Markdown, per /mentor:plan-output-format) under ~/.claude/mentor/<repo>-<hash>/plans/ (outside the repo)
and is exempt from orchestrator mode.
PLANROUTE
      ;;
  esac
fi

# --- B. Native plan mode activated at session start. ---
# Only act when we're in plan mode
[ "$permission_mode" != "plan" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // .sessionId // "default"')
flag="/tmp/mentor-plan-loaded-${session_id}"

# Only inject on the first plan-mode prompt in this session
[ -f "$flag" ] && exit 0
touch "$flag"

SKILL_FILE="$(dirname "$0")/../skills/mentor-plan/SKILL.md"

cat <<'HEADER'
[mentor] Plan mode detected — strategy instructions auto-loaded.

EXECUTE THE FOLLOWING IMMEDIATELY. Do not ask anything or begin planning until
the strategy question below has been answered by the user.

────────────────────────────────────────────────────────────────────────────────
HEADER

# Emit SKILL.md body — strip YAML frontmatter (skip up to and including closing ---)
awk 'BEGIN{f=0} /^---/{f++; if(f==2){f=3; next}} f>=3{print}' "$SKILL_FILE"
