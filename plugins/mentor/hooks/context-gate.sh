#!/usr/bin/env bash
# context-gate.sh — UserPromptSubmit
#
# The mentor CONTEXT GATE. Measures the live context size from the session transcript
# and acts in three tiers:
#   • WARN  (≥ warn threshold, default 200000): exit 0 with a one-line stdout notice
#     (UserPromptSubmit stdout is injected as context, so Claude can proactively offer a
#     handoff). Fires ONCE per session — a `.context-warned-<session_id>` marker in the
#     state dir; stale markers (>24h) are pruned so new sessions re-warn.
#   • WARN-HIGH (≥ warn-high threshold, default 90% of the effective block threshold):
#     a near-limit nudge that RE-FIRES on every prompt in the zone — no marker — so a
#     fast climb toward the cliff gets one more actionable checkpoint.
#   • BLOCK (≥ block threshold, default 270000): print guidance to stderr and exit 2,
#     which ERASES the prompt (same mechanism as plan-gate.sh). The user must shrink the
#     context (/mentor:handoff → /mentor:resume, or /compact) before continuing.
#
# Escape hatches ALWAYS pass: an empty prompt, or any prompt starting with "/" (slash
# commands like /mentor:handoff, /compact, /mentor:mode) — checked FIRST, before any
# measurement, so the gate can never lock the user out of the tools that fix it.
#
# Harness-synthetic prompts (an inbound agent report or task notification — no human
# behind them) are MEASURED like any prompt and can trigger both WARN tiers, but are
# NEVER erased: exit 2 would destroy a completed subagent's delivered work with nobody
# able to "re-send" it. At block level they pass through with a loud stdout advisory.
#
# Fail-soft everywhere: no jq / no transcript / no usage record in the tail window /
# malformed input → exit 0. Never brick a session.
#
# Kill switch: MENTOR_CONTEXT_GATE=off (env) or "context_gate":"off" (.mentor/config.json).
# Thresholds: MENTOR_CONTEXT_{WARN,WARN_HIGH,BLOCK}_TOKENS (env) or
# context_{warn,warn_high,block}_tokens (config).

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)" || exit 0
# Passthroughs FIRST: empty prompt or any slash command → never gate.
[ -z "$PROMPT" ] && exit 0
case "$PROMPT" in /*) exit 0 ;; esac

# Harness-synthetic prompt? Still measured below, but never erased (see header).
SYNTHETIC=0
case "$PROMPT" in
  '<agent-message'* | '<teammate-message'* | '<task-notification'*) SYNTHETIC=1 ;;
esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"

# Kill switch (env or per-repo config).
[ "$(mentor_context_gate_state "$repo_root")" = "on" ] || exit 0

TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || exit 0
TOKENS="$(mentor_context_tokens "$TRANSCRIPT")"
[ -z "$TOKENS" ] && exit 0   # unmeasurable → fail-soft

BLOCK_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_BLOCK_TOKENS:-}" context_block_tokens 270000)"
WARN_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_TOKENS:-}" context_warn_tokens 200000)"
# Near-limit tier defaults to 90% of the EFFECTIVE block threshold so it tracks overrides.
WARN_HIGH_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_HIGH_TOKENS:-}" context_warn_high_tokens $(( BLOCK_AT * 9 / 10 )))"

# --- BLOCK tier -------------------------------------------------------------
if [ "$TOKENS" -ge "$BLOCK_AT" ]; then
  if [ "$SYNTHETIC" = "1" ]; then
    # Never erase an agent's delivered work — no human exists to "re-send" it.
    # Advise loudly instead; stdout is injected as context alongside the report.
    echo "[mentor] Context is over the BLOCK threshold (~${TOKENS} tokens ≥ ${BLOCK_AT}) but this prompt is a harness-generated agent report, so it was NOT blocked — erasing it would lose the agent's completed work. Consume this result, then /mentor:handoff (→ /mentor:resume in a fresh session) or /compact BEFORE dispatching more work."
    exit 0
  fi
  cat >&2 <<EOF
BLOCKED by mentor: context is too large (~${TOKENS} tokens ≥ ${BLOCK_AT}).
Plan/answer quality degrades badly past this point. Before continuing, shrink the context:
  • /mentor:handoff "<what you're working on>"   then   /mentor:resume   (fresh session), or
  • /compact
Your prompt was NOT submitted — re-send it after handing off or compacting.
Override: MENTOR_CONTEXT_BLOCK_TOKENS=<n> (env) or "context_block_tokens" in .mentor/config.json;
disable entirely with MENTOR_CONTEXT_GATE=off.
EOF
  exit 2
fi

# --- WARN-HIGH tier (near-limit, re-fires every prompt in the zone) ----------
if [ "$TOKENS" -ge "$WARN_HIGH_AT" ]; then
  echo "[mentor] Context is close to the BLOCK threshold (~${TOKENS} of ${BLOCK_AT} tokens). Wrap up now — /mentor:handoff (then /mentor:resume in a fresh session) or /compact — before the hard block. (Re-fires each prompt; tune \"context_warn_high_tokens\" / \"context_block_tokens\" in .mentor/config.json if your repo uses a different budget.)"
  exit 0
fi

# --- WARN tier (once per session) ------------------------------------------
if [ "$TOKENS" -ge "$WARN_AT" ]; then
  SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || true
  state_dir="$(mentor_state_dir "$repo_root")"
  [ -z "$state_dir" ] && state_dir="${HOME}/.claude/mentor/_no-repo"
  # Prune stale warn markers (>24h) so a long-lived repo re-warns in later sessions.
  find "$state_dir" -maxdepth 1 -name '.context-warned-*' -mmin +1440 -delete 2>/dev/null || true
  marker="${state_dir}/.context-warned-${SESSION_ID:-nosession}"
  if [ ! -e "$marker" ]; then
    mkdir -p -m 700 "$state_dir" 2>/dev/null || true
    [ -n "$repo_root" ] && mentor_ensure_gitignore "$state_dir"
    : > "$marker" 2>/dev/null || true
    echo "[mentor] Context is getting large (~${TOKENS} tokens ≥ ${WARN_AT}). At a natural stopping point, consider /mentor:handoff (then /mentor:resume in a fresh session) or /compact. (Shown once per session; thresholds: \"context_warn_tokens\" / \"context_block_tokens\" in .mentor/config.json.)"
  fi
fi

exit 0
