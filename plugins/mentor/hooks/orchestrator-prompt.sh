#!/usr/bin/env bash
# orchestrator-prompt.sh — UserPromptSubmit
#
# Owns orchestrator-mode OPERATIONAL session state (not the on/off switch — since v0.37
# orchestrator is a resolved repo/global config toggle; see set-orchestrator.sh /
# /mentor:orchestrator). It is the only hook guaranteed to run in the MAIN conversation
# (never a subagent) WITH a session_id. Each turn it:
#   1. GCs stale orchestrator/flow flags (>8h) so orphaned flags from dead sessions
#      can't leak state (incl. a one-release reaper for the legacy mentor-commander-* names).
#   2. Migrates any legacy {"mode":"commander"} repo config (one-shot, first-read).
#   3. When orchestrator is ON: resets the per-turn read budget + dispatch
#      flag, sets the shared mentor-flow-active marker if a /ship · /loom:harvest ·
#      /simplify command is present (so orchestrator-gate defers to that flow), emits the
#      <=2-line reminder, and ONCE per session injects the condensed playbook span
#      (<!--INJECT-->…<!--/INJECT-->) from skills/orchestrator/SKILL.md — NOT the whole
#      file (the 10k UserPromptSubmit cap).
#
# stdout is injected as model context. No `set -e` (many optional ops); fail-open / silent.

command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

input="$(cat)" || exit 0
prompt="$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)" || prompt=""
session_id="$(mentor_session_id "$input")"
cwd="$(mentor_cwd "$input")"

LOADED="/tmp/mentor-orchestrator-loaded-${session_id}"
BUDGET="/tmp/mentor-orchestrator-read-budget-${session_id}"
DISPATCHED="/tmp/mentor-orchestrator-dispatched-${session_id}"
FLOW="/tmp/mentor-flow-active-${session_id}"

# 1. GC stale flags (>8h). mentor-flow-active is a cross-cutting shared marker — pruned by
#    age only here, since future flows may also rely on it. The legacy mentor-commander-*
#    reaper covers old-name flags from sessions in flight at the v0.37 upgrade (drop in 0.38).
find /tmp -maxdepth 1 -name 'mentor-orchestrator-*' -mmin +480 -delete 2>/dev/null || true
find /tmp -maxdepth 1 -name 'mentor-commander-*'    -mmin +480 -delete 2>/dev/null || true
find /tmp -maxdepth 1 -name 'mentor-flow-active-*'  -mmin +480 -delete 2>/dev/null || true

# 2. Orchestrator on? Resolved from repo/global config (repo explicit > legacy > global).
repo_root="$(mentor_repo_root "$cwd")"
[ -n "$repo_root" ] || exit 0
mentor_migrate_legacy_commander "$repo_root"   # one-shot normalize on first read
mentor_orchestrator_on "$repo_root" || exit 0

# Per-turn reset: fresh read budget + clear the dispatch step-aside flag.
echo 0 > "$BUDGET" 2>/dev/null || true
rm -f "$DISPATCHED" 2>/dev/null || true

# Defer to a plugin-owned flow invoked THIS turn (fresh marker; orchestrator-gate honors <60min).
if printf '%s' "$prompt" | grep -qE '(^|[[:space:]])/(ship|simplify)([[:space:]]|$)' \
   || printf '%s' "$prompt" | grep -qE '(^|[[:space:]])/(loom:)?harvest([[:space:]]|$)'; then
  touch "$FLOW" 2>/dev/null || true
fi

# Per-turn reminder (<=2 lines — resists long-session drift; cheap).
cat <<'REMIND'
[mentor] orchestrator ON — orchestrate, don't do. Dispatch agents for ALL repo edits + bulk reads; verify every return (read the diff / rerun the check), never trust "done".
[mentor] blocked? don't retry — hand the full task to an impl/Explore agent. Off: /mentor:orchestrator off
REMIND

# Once per session: inject the condensed playbook (the sentinel span only).
if [ ! -f "$LOADED" ]; then
  touch "$LOADED" 2>/dev/null || true
  SKILL_FILE="$(dirname "$0")/../skills/orchestrator/SKILL.md"
  if [ -f "$SKILL_FILE" ]; then
    echo "────────────────────────────────────────────────────────────────────────────────"
    awk '/<!--INJECT-->/{f=1;next} /<!--\/INJECT-->/{f=0} f' "$SKILL_FILE"
  fi
fi
exit 0
