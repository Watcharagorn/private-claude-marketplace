#!/usr/bin/env bash
# begin-plan.sh — arm the mentor plan-phase gate.
#
# Invoked by the /mentor:plan command body as its FIRST action, before
# any drafting. It writes the repo-scoped `.planning` marker (which CLOSES the
# plan-phase edit gate — plan-phase-gate.sh) and clears stale flags from a prior
# planning session in the same repo. It runs as a normal Bash call and is allowed
# precisely because, at this instant, no marker exists yet (the gate is open).
#
# Repo-scoped (not session-scoped): a command body has no session_id, and this
# mirrors how `.proceed-mode` is already keyed. Path derivation lives in lib/state.sh
# (shared with every other gate hook).
#
# Mode-aware (v0.33): reads the persisted repo mode (set-mode.sh / /mentor:mode) and
# appends per-mode instructions — plan-only soft-stop notice, or the ask-to-persist
# prompt when no mode is set.
#
# Fail-soft: if we cannot resolve a git repo, print a notice and exit 0 — the
# skill still runs; the gate simply isn't armed outside a repo.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  echo "[mentor] Not inside a git repo — plan-phase gate NOT armed (planning still proceeds)."
  exit 0
fi
mentor_migrate_legacy_commander "$repo_root"   # normalize legacy {"mode":"commander"} before the case below
plans_dir="$(mentor_plans_dir "$repo_root")"

mkdir -p -m 700 "$plans_dir"

# Resolve the persisted/effective plan output format (md|html) up front so the banner
# can report it and the Step-6b path is unambiguous. Empty = unset → asked below.
format="$(mentor_get_format "$repo_root")"

# Clear any stale flags from a prior planning session in this repo, then arm.
# Also clear the per-plan ".opened" sidecars: plan paths are slug-derived and
# timestamp-free (v0.38.2), so a stale "<slug>.html.opened" from a prior session
# would otherwise suppress plan-open.sh's first-creation open for the same slug.
rm -f "${plans_dir}/.research-dispatched" \
      "${plans_dir}/.plan-authored" \
      "${plans_dir}/.read-budget" \
      "${plans_dir}/.proceed-mode" \
      "${plans_dir}"/*.opened 2>/dev/null || true

# Format-switch hygiene (md format only): drop any foreign *.html review surface (and its
# .opened sidecar) so the deliverable gates (strategy-guard.sh, approve-plan.sh,
# plan-html-stop-gate.sh) resolve ONLY the current-format plan. A switch via
# /mentor:plan-output-format must not leave a foreign-format plan behind.
#
# The html branch does NOT purge *.md — in an html-format repo a *.md is (since the
# finalize-at-approval enhancement) the FINALIZED APPROVED plan of a prior session, i.e.
# the durable artifact implementation/handoff/resume still consume. Sweeping it here
# destroyed the approved plan the moment a new /mentor:plan started. The html gates all
# key on *.html, so a lingering .md cannot confuse them during planning.
case "$format" in
  md) rm -f "${plans_dir}"/*.html "${plans_dir}"/*.html.opened 2>/dev/null || true ;;
esac

: > "${plans_dir}/.planning"

cat <<EOF
[mentor] Plan phase ARMED.
  marker:   ${plans_dir}/.planning
  edits:    repo source writes are now BLOCKED until the plan is approved
            (plan-phase-gate.sh — holds even under bypassPermissions).
  research: bulk reads are gated — DELEGATE exploration to Explore/Plan subagents
            (mentor-plan SKILL Step 1.5). Escape hatch:
            MENTOR_PLAN_RESEARCH=off.

Now follow the mentor-plan skill. Do NOT edit repo files until approval.
EOF

# Report the resolved output format. Drives Step 6b: md → "Markdown Plan Document
# Format" (Mermaid-first .md, its own canonical source); html → "HTML Plan Document
# Format" (bespoke styled HTML). UNSET → ask + persist below before persisting a plan.
if [ -n "$format" ]; then
  echo "FORMAT: ${format}"
else
  echo "FORMAT: UNSET"
fi

mode="$(mentor_get_mode "$repo_root")"

# First-time persistence prompts. `mode` and `format` are independent per-repo
# settings; when BOTH are unset, ask them together in ONE AskUserQuestion (two
# questions) so the skill never fires two competing "FIRST ask" directives.
if [ -z "$mode" ] && [ -z "$format" ]; then
  cat <<'EOF'

Neither a repo MODE nor a plan output FORMAT is set. After entering the mentor-plan
skill, FIRST ask the user BOTH in a SINGLE AskUserQuestion call (two questions), then
persist each choice, then continue planning:
  • Mode — plan (default: plan then execute on approval) / plan-only (plans are the
    deliverable; no execution).  Persist with:
      bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <plan|plan-only>
  • Format — Markdown (Mermaid-first .md plan) / HTML (bespoke styled HTML plan).
    Persist with:
      bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-plan-output-format.sh" <md|html>
(Always-orchestrate is a separate toggle: /mentor:orchestrator on.)
EOF
else
  case "$mode" in
    plan-only)
      cat <<'EOF'

MODE: plan-only — after approval the plan file is the DELIVERABLE. Do NOT implement
and do NOT dispatch implementation agents; the approval step (Step 6) will soft-stop.
Skip the Step 1 strategy question — use strategy: normal (dispatch-agents: skipped).
EOF
      ;;
    "")
      cat <<'EOF'

No repo mode is set. After entering the mentor-plan skill, FIRST ask the user via
AskUserQuestion which mode to persist for this repo — plan (default: plan then execute
on approval) / plan-only (plans are deliverables; no execution) — then run:
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <choice>
and continue planning. (Always-orchestrate is a separate toggle: /mentor:orchestrator on.)
EOF
      ;;
  esac

  if [ -z "$format" ]; then
    cat <<'EOF'

No plan output format is set. After entering the mentor-plan skill, ask the user via
AskUserQuestion which format to persist for this repo — Markdown (Mermaid-first .md
plan) / HTML (bespoke styled HTML plan) — then run:
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-plan-output-format.sh" <md|html>
and continue planning.
EOF
  fi
fi
exit 0
