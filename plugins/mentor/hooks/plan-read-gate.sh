#!/usr/bin/env bash
# plan-read-gate.sh — PreToolUse:Read|Grep|Glob
#
# The always-delegate-planning floor (main-conversation context optimization).
# During the plan phase the main thread should DISPATCH Explore/Plan subagents to
# do the heavy codebase reading, then synthesize their distilled returns — rather
# than bulk-reading files into its own context. This hook enforces that as a hard
# floor on top of the SKILL Step 1.5 mandate:
#
#   • ~2 free reads (the user-named files) are allowed with a nudge; then
#   • further bulk reads are BLOCKED (exit 2) until a research subagent has been
#     dispatched (research-dispatch-tracker.sh sets `.research-dispatched`); then
#   • the gate STEPS ASIDE — subagents' own reads and the main thread's small
#     verification reads are allowed.
#
# Escape hatch: MENTOR_PLAN_RESEARCH=off → no-op (trivial sessions).
# Inert when no `.planning` marker. Fail-open on any parse error.

set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
[ "${MENTOR_PLAN_RESEARCH:-}" = "off" ] && exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL_NAME" in
  Read|Grep|Glob) ;;
  *) exit 0 ;;
esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"
[ -z "$repo_root" ] && exit 0
plans_dir="$(mentor_plans_dir "$repo_root")"

# Fresh .planning marker required (not planning / stale >8h → allow).
mentor_marker_fresh "${plans_dir}/.planning" || exit 0
[ -f "${plans_dir}/.research-dispatched" ] && exit 0      # already delegated → allow all

budget_file="${plans_dir}/.read-budget"
count="$(cat "$budget_file" 2>/dev/null || echo 0)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac

if [ "$count" -ge 2 ]; then
  cat >&2 << EOF
BLOCKED by mentor: always-delegate planning (context optimization).

You've already taken ${count} direct reads during this plan phase. To keep the main
conversation lean, this plugin requires planning RESEARCH to be DELEGATED:

  • Dispatch 2–4 parallel Explore agents over disjoint areas (and a Plan agent for
    design) instead of bulk-reading the codebase yourself.
  • Have each agent return FINDINGS (<=~400 words) + EVIDENCE as file:line refs only
    — NO file dumps — then synthesize and write the plan file (HTML or Markdown, per format).

See mentor-plan SKILL Step 1.5 (Mandatory Research Dispatch).

As soon as you dispatch a research subagent this gate steps aside automatically (the
subagents' own reads, and your later verification reads, are allowed).

Escape hatch for trivial sessions: set MENTOR_PLAN_RESEARCH=off.
EOF
  exit 2
fi

# Free read (#1 / #2): record and allow.
echo "$((count + 1))" > "$budget_file" 2>/dev/null || true
exit 0
