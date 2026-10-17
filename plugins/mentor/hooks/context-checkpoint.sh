#!/usr/bin/env bash
# context-checkpoint.sh — PostToolBatch (v2.37.0): the mid-run context reading.
#
# context-gate.sh is UserPromptSubmit-only, so any long autonomous stretch — a fan-out
# and its verification round, a multi-step implementation the user let run — collapses
# N turns into one and receives ZERO context readings between prompts. Measured before this existed: one
# real session grew ~247k tokens between two readings with no warning in between.
# resuming/SKILL.md names the shape: "a long autonomous stretch between this reading
# and that report is exactly the shape context-gate.sh's own WARN tier cannot catch."
# PostToolBatch fires once per tool batch, before the next model request, which is
# exactly the cadence that closes the blind spot.
#
# ADVISORY ONLY, BY RULING — this hook NEVER exits 2 (on PostToolBatch, exit 2 stops
# the agentic loop dead: mid-step, half-edited tree, no failed --note — safety bought at
# the price of everything the run would otherwise have written down). Every tier injects
# a one-line warning via hookSpecificOutput.additionalContext and exits 0. The guarantee
# is "never blind", not "forced stop" — that trade was chosen explicitly (2026-08-20)
# over an exit-2 backstop. Like the gate (v4.2.0), it warns only: no handoff steer.
#
# Fires the same three tiers as the gate (WARN / WARN-HIGH / HIGH), from the same
# thresholds, but rate-limited by its own marker (.context-checkpoint-<session_id>,
# storing "<tier> <tokens>"): a batch-frequency hook that spoke every batch would bury
# the transcript in its own advisories. It speaks when the tier RISES, or when the
# count has grown a quarter of the warn threshold since it last spoke.
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
[ -z "$state_dir" ] && state_dir="$(mentor_no_repo_state_dir)"

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
    MSG="[mentor] CONTEXT CHECKPOINT: ~${TOKENS} tokens ≥ ${ASK_AT} — over the limit. Keep the rest of this run small and lean. (Advisory only — this hook never blocks.)"
    ;;
  2)
    MSG="[mentor] CONTEXT CHECKPOINT: ~${TOKENS} of ${ASK_AT} tokens — nearing the limit. Avoid opening new large workstreams."
    ;;
  *)
    MSG="[mentor] CONTEXT CHECKPOINT: ~${TOKENS} tokens ≥ ${WARN_AT} and still mid-run. (Re-fires on tier rise or every ~${rearm_delta} tokens of growth.)"
    ;;
esac

jq -n --arg msg "$MSG" '{hookSpecificOutput: {hookEventName: "PostToolBatch", additionalContext: $msg}}' 2>/dev/null || true
exit 0
