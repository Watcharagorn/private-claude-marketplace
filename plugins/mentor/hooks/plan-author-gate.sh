#!/usr/bin/env bash
# plan-author-gate.sh — PreToolUse:Write|Edit
#
# The always-delegate-AUTHORING floor (sibling of plan-read-gate.sh, which is the
# always-delegate-RESEARCH floor). During the plan phase the comprehensive plan
# BODY must be authored by a DISPATCHED subagent — the main thread is courier +
# renderer only: it receives the agent's returned markdown, renders it into the
# Step 8 HTML document, and writes it. This hook enforces that as a hard floor on top of
# the SKILL Step 1.5 mandate:
#
#   • it is PATH-SCOPED to the repo's plans HTML (~/.claude/mentor/<repo>-<hash>/plans/*.html).
#     Writes to any other path — in-repo source (covered by plan-phase-gate.sh),
#     /tmp, a subagent's scratch files — are ignored here; and
#   • the plans HTML write is BLOCKED (exit 2) until a plan-author subagent has been
#     dispatched (research-dispatch-tracker.sh sets `.plan-authored` when it sees a
#     Task/Agent whose prompt carries the token `mentor:plan-author`, or whose
#     subagent_type is `Plan`); then
#   • the gate STEPS ASIDE — the first authored write AND every later revision are
#     allowed (the marker is sticky for the session).
#
# Because it is path-scoped to the plans HTML, this gate is correct regardless of
# whether main-session hooks fire for a subagent's own tool calls: the plan-author
# agent never writes the HTML (it RETURNS markdown), so it can never trip the gate.
#
# Escape hatch: MENTOR_PLAN_AUTHOR=off → no-op (trivial sessions).
# Inert when no `.planning` marker. Fail-open on any parse error.

set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
[ "${MENTOR_PLAN_AUTHOR:-}" = "off" ] && exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"
[ -z "$repo_root" ] && exit 0
plans_dir="$(mentor_plans_dir "$repo_root")"

# Fresh .planning marker required (stale >8h → treat as released; allow).
mentor_marker_fresh "${plans_dir}/.planning" || exit 0

# Cheap prefix gate FIRST: only writes into THIS repo's plans dir can be the plan
# deliverable. Everything else → allow (in-repo writes are plan-phase-gate's job; scratch
# writes elsewhere are fine). This lets the vast majority of writes skip the format lookup
# (a shasum+jq) below — it runs only for the rare write that lands in the plans dir.
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)" || true
case "$FILE_PATH" in
  "${plans_dir}/"*) ;;   # in the plans dir → resolve format and check the deliverable
  *) exit 0 ;;
esac

# Resolve the configured output format → deliverable extension (md → *.md, else *.html).
plan_ext="$(mentor_plan_ext "$repo_root")"

# Only the configured-format deliverable is enforced. Note: when format=md this correctly
# enforces ANY *.md in the plans dir — the plans dir holds only the plan + markers, so the
# plan IS the .md being written.
case "$FILE_PATH" in
  "${plans_dir}/"*."${plan_ext}") ;;   # the plan deliverable → enforce
  *) exit 0 ;;
esac

[ -f "${plans_dir}/.plan-authored" ] && exit 0   # author dispatched → allow (incl. revisions)

if [ "$plan_ext" = "md" ]; then
  render_target='render it into the "Markdown Plan Document Format" (Mermaid-first; the .md file is its OWN canonical source — bare footer markers at EOF, no plan-source block), and write THIS .md'
else
  render_target='render it into the Step 8 HTML document (bespoke theme, machine contract intact), and write THIS .html'
fi

cat >&2 << EOF
BLOCKED by mentor: always-delegate AUTHORING (the plan body must come from a subagent).

Do NOT draft the comprehensive plan in the main conversation. Dispatch ONE plan-author
agent (a Plan agent, model opus) whose PROMPT contains the token

  mentor:plan-author

and which RETURNS the complete, footer-compliant plan body — Context, use case scenarios
(actors/triggers, current vs expected behavior, concrete walkthroughs, edge cases),
Approach, per-topic visualization specs (prose, realized as polished HTML — not ASCII art),
implementation steps (with
[role: … · model: … · effort: …] annotations for dispatch strategies), critical files,
out-of-scope, verification, a short THEME spec for the HTML rendering, and the
Step 5 footer markers — written for a generalist reviewer (define jargon, state why
each step matters). For a Normal-strategy plan, one combined research+author agent
(carrying the same token) may return the body.

The main thread is courier + renderer ONLY: take the agent's returned markdown, ${render_target}.
As soon as you dispatch the plan-author agent this gate steps aside automatically (the first
write and all later revisions are allowed). See mentor-plan SKILL Step 1.5.

Escape hatch for trivial sessions: set MENTOR_PLAN_AUTHOR=off.
EOF
exit 2
