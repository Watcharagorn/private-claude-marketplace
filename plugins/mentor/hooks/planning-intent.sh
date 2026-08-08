#!/usr/bin/env bash
# planning-intent.sh — UserPromptSubmit
#
# A narrow, non-blocking advisory: when a prompt OPENS with an explicit planning-intent
# phrase, print one line suggesting /mentor:plan. This never blocks, never asks a
# question, and never invokes any skill itself.
#
# The gap this closes: a session that talks through a plan conversationally and never
# runs /mentor:plan or Skill(mentor:planning) engages NONE of mentor's machinery —
# plan-gate.sh has no marker to enforce, and skills/planning/SKILL.md's own Step 0
# self-check (which redirects a conversational "help me plan this" to the command) only
# runs once that skill is actually loaded. This hook is the one layer that sees the
# prompt before any skill is chosen, so it is the only place that can catch the case
# where mentor never gets a chance to catch itself.
#
# This does NOT contradict "never auto-select mentor:planning for a conversational
# ask" (skills/planning/SKILL.md's own frontmatter): that rule governs the skill BODY
# running without an armed gate. Nudging the human toward the /mentor:plan COMMAND is
# the same direction that rule already points — planning/SKILL.md:54 prescribes this
# exact remedy ("ask the user to run /mentor:plan <their request>") for the one path
# that can reach it. This hook delivers the same nudge one layer earlier, where the
# rule can't reach at all because the skill was never loaded.
#
# Deliberately ANCHORED at position 0 (same convention context-gate.sh uses for its
# SYNTHETIC check): a mid-sentence match would fire on a prompt that merely mentions
# planning, not one asking mentor to do it. This is a precision-over-recall choice on
# purpose — the pattern list below is short and will miss many real planning asks
# phrased differently ("I want to build X", "let's figure out how to Y"). That is
# fine: a silent miss costs nothing (the session behaves exactly as it does today),
# while a false positive costs a stray, unactionable nudge on every matching prompt.
# Broadening the list trades this hook's whole reason to stay quiet for more recall —
# don't, without re-deriving that tradeoff.
#
# Escape hatches (checked FIRST, same order as context-gate.sh):
#   - empty prompt, or any prompt starting with "/" (a slash command must never be
#     second-guessed here — /mentor:handoff "...write it as a plan..." is real work,
#     not a miss to correct)
#   - a harness-synthetic prompt (agent report / task notification / background-agent
#     stop notice) — nothing to act on, and the once-per-session slot belongs to the
#     next real human turn
#   - the plan gate is already armed (.mentor/plans/.planning exists) — the session is
#     already inside mentor's planning flow; nudging would be noise at best
#
# Fires AT MOST ONCE per session. The marker lives OUTSIDE the target repo's .mentor/
# tree, under a machine-global scratch dir — a heuristic prompt match must never create
# repo state (a .mentor/ dir + .gitignore) in a repo that has never actually used
# mentor. context-gate.sh only creates .mentor/ from its WARN tier onward, i.e. once a
# session is plainly deep in real work; this hook has no equivalent signal, so it never
# touches the repo at all.
#
# Kill switch: MENTOR_PLANNING_INTENT=off (env) or "planning_intent":"off" in
# .mentor/config.json (read-only lookup — never creates config.json or .mentor/).
#
# Fail-soft everywhere: no jq / malformed input → exit 0. Never brick a session.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh"

INPUT="$(cat)" || exit 0

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)" || exit 0
# Passthroughs FIRST: empty prompt or any slash command → never nudge.
[ -z "$PROMPT" ] && exit 0
case "$PROMPT" in /*) exit 0 ;; esac

# Harness-synthetic prompt? Never nudge on one — same shapes as context-gate.sh.
case "$PROMPT" in
  '<agent-message'* | '<teammate-message'* | '<task-notification'*) exit 0 ;;
  'Another Claude session sent a message:'*) exit 0 ;;
  'Background agent "'*' was stopped by the user'*) exit 0 ;;
  [0-9]*' background agent'*' stopped by the user'*) exit 0 ;;
esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"

# Kill switch (env, or per-repo config when one already exists — read-only, never
# creates .mentor/ or config.json).
case "${MENTOR_PLANNING_INTENT:-}" in
  off|0|false|no) exit 0 ;;
esac
[ "$(mentor_config_get "$repo_root" "planning_intent")" = "off" ] && exit 0

# Already inside mentor's planning flow → the gate is armed, nudging now is noise.
if [ -n "$repo_root" ] && [ -f "${repo_root}/.mentor/plans/.planning" ]; then
  exit 0
fi

# Narrow, anchored planning-intent openers (case-insensitive). See header for why this
# list stays short.
PROMPT_LC="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')"
case "$PROMPT_LC" in
  "help me plan"*|"let's plan"*|"lets plan"*|"can you plan"*|"plan out"*|"i want to plan"*) ;;
  *) exit 0 ;;
esac

# Once-per-session only. Marker lives under a machine-global scratch dir — NEVER
# inside the target repo's .mentor/ (see header).
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || true
scratch_dir="${HOME}/.claude/mentor/_prompt-nudges"
marker="${scratch_dir}/.planning-intent-${SESSION_ID:-nosession}"
[ -e "$marker" ] && exit 0
mkdir -p "$scratch_dir" 2>/dev/null || true
: > "$marker" 2>/dev/null || true

echo "[mentor] This looks like a planning request. Offer the user \`/mentor:plan <topic>\` so mentor's edit gate and structured plan format apply — do NOT invoke Skill(mentor:planning) yourself; only the /mentor:plan command arms the gate that makes it safe. (Disable this advisory with MENTOR_PLANNING_INTENT=off or \"planning_intent\":\"off\" in .mentor/config.json.)"
exit 0
