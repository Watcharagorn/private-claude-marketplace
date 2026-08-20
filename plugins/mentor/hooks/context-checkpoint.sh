#!/usr/bin/env bash
# context-checkpoint.sh — PostToolBatch (v2.37.0): the mid-run context reading.
#
# context-gate.sh is UserPromptSubmit-only, so a run that collapses N human turns into
# one — dispatch-agents' unattended continuation, or any long autonomous stretch —
# receives ZERO context readings between prompts. Measured before this existed: one
# real session grew ~247k tokens between two readings with no warning in between.
# resuming/SKILL.md names the shape: "a long autonomous stretch between this reading
# and that report is exactly the shape context-gate.sh's own WARN tier cannot catch."
# PostToolBatch fires once per tool batch, before the next model request, which is
# exactly the cadence that closes the blind spot.
#
# ADVISORY ONLY, BY RULING — this hook NEVER exits 2 (on PostToolBatch, exit 2 stops
# the agentic loop dead: mid-step, half-edited tree, no handoff note, no failed --note
# — safety bought at the price of the auditability the loop exists to add). Every
# tier injects text via hookSpecificOutput.additionalContext and exits 0. The
# guarantee is "never blind", not "forced stop": a run CAN still exhaust the window
# if it ignores the directive — that trade was chosen explicitly (2026-08-20) over an
# exit-2 backstop.
#
# Fires the same three tiers as the gate (WARN / WARN-HIGH / ASK), from the same
# thresholds, but rate-limited by its own marker (.context-checkpoint-<session_id>,
# storing "<tier> <tokens>"): a batch-frequency hook that spoke every batch would bury
# the transcript in its own advisories. It speaks when the tier RISES, or when the
# count has grown a quarter of the warn threshold since it last spoke. The ASK tier
# text is a directive to END THE TURN at the current step boundary — it deliberately
# does not restate the gate's AskUserQuestion contract, because mid-batch there may be
# nobody in the turn to answer; the boundary itself is where the question belongs.
#
# Fail-soft everywhere: no jq / no transcript / unmeasurable / malformed input →
# exit 0 silently. Never brick a session. Kill switches: the gate's own
# (MENTOR_CONTEXT_GATE=off / "context_gate":"off") — a repo that turned the gate off
# has opted out of context policing entirely — plus its own
# MENTOR_CONTEXT_CHECKPOINT=off / "context_checkpoint":"off" for turning off just the
# batch-frequency reading while keeping the per-prompt gate.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh"

INPUT="$(cat)" || exit 0

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"

# Kill switches — the gate's, then this hook's own.
[ "$(mentor_context_gate_state "$repo_root")" = "on" ] || exit 0
ckpt_cfg="$(mentor_config_get "$repo_root" "context_checkpoint")"
[ "${MENTOR_CONTEXT_CHECKPOINT:-${ckpt_cfg:-on}}" = "off" ] && exit 0

TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || exit 0
TOKENS="$(mentor_context_tokens "$TRANSCRIPT")"
[ -z "$TOKENS" ] && exit 0   # unmeasurable → fail-soft

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || true
state_dir="$(mentor_state_dir "$repo_root")"
[ -z "$state_dir" ] && state_dir="${HOME}/.claude/mentor/_no-repo"

ASK_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_BLOCK_TOKENS:-}" context_block_tokens 350000)"
WARN_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_TOKENS:-}" context_warn_tokens 200000)"
WARN_HIGH_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_HIGH_TOKENS:-}" context_warn_high_tokens $(( ASK_AT * 9 / 10 )))"

[ "$TOKENS" -ge "$WARN_AT" ] || exit 0

tier=1
[ "$TOKENS" -ge "$WARN_HIGH_AT" ] && tier=2
[ "$TOKENS" -ge "$ASK_AT" ] && tier=3

# Rate limit: speak on a tier RISE, or on growth ≥ WARN_AT/4 since the last time.
find "$state_dir" -maxdepth 1 -name '.context-checkpoint-*' -mmin +1440 -delete 2>/dev/null || true
marker="${state_dir}/.context-checkpoint-${SESSION_ID:-nosession}"
last_tier=0; last_tokens=0
if [ -e "$marker" ]; then
  read -r last_tier last_tokens < "$marker" 2>/dev/null || true
fi
case "$last_tier" in ''|*[!0-9]*) last_tier=0 ;; esac
case "$last_tokens" in ''|*[!0-9]*) last_tokens=0 ;; esac
rearm_delta=$(( WARN_AT / 4 ))
if [ "$tier" -le "$last_tier" ] && [ $(( TOKENS - last_tokens )) -lt "$rearm_delta" ]; then
  exit 0
fi

mkdir -p -m 700 "$state_dir" 2>/dev/null || true
[ -n "$repo_root" ] && mentor_ensure_gitignore "$state_dir"
printf '%s %s' "$tier" "$TOKENS" > "$marker" 2>/dev/null || true

case "$tier" in
  3)
    if [ -e "${state_dir}/.context-bypass-${SESSION_ID:-nosession}" ]; then
      MSG="[mentor] CONTEXT CHECKPOINT: ~${TOKENS} tokens ≥ ${ASK_AT} (gate bypassed for this session). Keep the run lean: finish the current unit of work, then hand off at the next natural boundary (/mentor:handoff → /mentor:resume in a fresh session)."
    else
      MSG="[mentor] CONTEXT CHECKPOINT: ~${TOKENS} tokens ≥ ${ASK_AT}. If you are mid-run (dispatch-agents' unattended loop, or any long autonomous stretch): finish ONLY the current step, record its outcome (tick it, or plan-state.sh set <slug> failed --note), write the handoff (Skill mentor:handoff-note), and END THE TURN — do not start another step. If a human is in the turn, surface the handoff question now instead. (Advisory only — this hook never blocks.)"
    fi
    ;;
  2)
    MSG="[mentor] CONTEXT CHECKPOINT: ~${TOKENS} of ${ASK_AT} tokens — nearing the handoff threshold mid-run. Steer toward a natural boundary: finish the current step, avoid opening new large workstreams, and prefer ending the turn at the next step boundary over starting another step."
    ;;
  *)
    MSG="[mentor] CONTEXT CHECKPOINT: ~${TOKENS} tokens ≥ ${WARN_AT} and still mid-run. At the next natural step boundary, consider wrapping up and handing off (/mentor:handoff → /mentor:resume in a fresh session). (Re-fires on tier rise or every ~${rearm_delta} tokens of growth.)"
    ;;
esac

jq -n --arg msg "$MSG" '{hookSpecificOutput: {hookEventName: "PostToolBatch", additionalContext: $msg}}' 2>/dev/null || true
exit 0
