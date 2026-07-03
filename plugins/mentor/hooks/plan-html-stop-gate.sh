#!/usr/bin/env bash
# plan-html-stop-gate.sh — Stop
#
# The persist-the-plan floor: in EVERY mode (plan | plan-only) the plan's deliverable is the
# persisted plan FILE (SKILL Step 6b) — a styled HTML doc or a Mermaid-first Markdown doc,
# per the repo's plan output format — NOT the chat transcript. This hook
# closes the observed failure where the main thread surfaces the plan body as a text-only
# message (Step 6a) and the turn ENDS — no HTML persisted, no release question asked, the
# `.planning` marker left armed (session 18e26172).
#
# It blocks the main agent from stopping when ALL of:
#   • a fresh `.planning` marker exists (we are mid plan phase), and
#   • `.plan-authored` exists (a plan-author subagent was DISPATCHED — note: the tracker sets this
#     at dispatch time, so the author may still be running async; its body is in hand only once it
#     returns), and
#   • no plan FILE (of the repo's configured format extension — *.html or *.md) is newer than
#     `.plan-authored` (the body was never rendered and persisted, or a re-authored body has not
#     been re-rendered yet, or the author is still running).
#
# Once the plan file lands (Write → also triggers plan-open.sh), the newest-file check passes and
# stopping is free. Approval (approve-plan.sh) deletes the markers entirely, so post-release
# turns are never touched. Turns BEFORE the author dispatch are never touched either —
# clarifying questions mid-planning remain free.
#
# Loop safety: if stop_hook_active is set (we already blocked once this stop chain), allow.
# Subagent stops are a different event (SubagentStop) and never reach this hook; the
# transcript-path guard below is belt-and-braces only.
# Escape hatch: MENTOR_PLAN_AUTHOR=off (same switch as the author gate — trivial sessions).
# Inert outside a repo / without jq. Fail-open on any parse error.

set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
[ "${MENTOR_PLAN_AUTHOR:-}" = "off" ] && exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0

# Already continuing because a stop hook blocked → never block twice (no loops).
ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" || ACTIVE="false"
[ "$ACTIVE" = "true" ] && exit 0

TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || TRANSCRIPT=""
case "$TRANSCRIPT" in */subagents/*) exit 0 ;; esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"
[ -z "$repo_root" ] && exit 0
plans_dir="$(mentor_plans_dir "$repo_root")"

# Mid plan phase only (stale >8h → treat as released; allow).
mentor_marker_fresh "${plans_dir}/.planning" || exit 0

# Author not yet dispatched → nothing to persist yet; allow.
[ -f "${plans_dir}/.plan-authored" ] || exit 0

# Resolve the configured output format → deliverable extension (md → *.md, else *.html).
# Deferred to here so the shasum+jq run only when we are genuinely mid-plan-phase with an
# author dispatched — the common Stop event exits at one of the guards above without paying.
plan_ext="$(mentor_plan_ext "$repo_root")"

# A plan file (current format) at least as new as the (latest) author dispatch → the body
# was rendered; allow.
newer="$(find "$plans_dir" -maxdepth 1 -name "*.${plan_ext}" -newer "${plans_dir}/.plan-authored" 2>/dev/null | head -1)" || newer=""
[ -n "$newer" ] && exit 0

if [ "$plan_ext" = "md" ]; then
  render_line="6b. Render the plan-author's returned Markdown into the \"Markdown Plan Document Format\"
      (Mermaid-first; the .md file is its OWN canonical source — bare footer markers at EOF, no
      plan-source block) and Write it to ${plans_dir}/<slug>.md"
  rewrite_line="If you re-dispatched the plan-author (Keep planning), re-write the SAME .md so it reflects
the latest body. Escape hatch for trivial sessions: MENTOR_PLAN_AUTHOR=off."
else
  render_line="6b. Render the plan-author's returned Markdown into the Step 8 HTML document (bespoke
      theme, plan-source block byte-identical to the surfaced body) and Write it to
      ${plans_dir}/<slug>.html"
  rewrite_line="If you re-dispatched the plan-author (Keep planning), re-write the SAME .html so it reflects
the latest body. Escape hatch for trivial sessions: MENTOR_PLAN_AUTHOR=off."
fi

cat >&2 << EOF
BLOCKED by mentor: a plan-author was dispatched but no plan file has been persisted yet.

If the plan-author is still running (Agent dispatches are async here), do NOT busy-poll it in Bash.
This gate nudges you ONCE, then ALLOWS the stop on the immediate retry so the turn is never trapped
— it does NOT re-deliver the author's body for you. Take the returned body from the author's
delivered completion message (never scrape subagents/*.jsonl or task .output files), then render.
Once the author has returned, the plan FILE is the deliverable in EVERY mode (plan / plan-only)
— the chat text is not. Finish Step 6 before the turn ends:

  ${render_line}
  6c. Then ask the release question (Proceed / Deliver plan / Review / Keep planning) and,
      on approval, run approve-plan.sh.

${rewrite_line}
EOF
exit 2
