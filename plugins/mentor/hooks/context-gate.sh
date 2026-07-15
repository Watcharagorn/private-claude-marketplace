#!/usr/bin/env bash
# context-gate.sh — UserPromptSubmit
#
# The mentor CONTEXT GATE. Measures the live context size from the session transcript
# and acts in two tiers:
#   • WARN  (≥ warn threshold, default 200000): exit 0 with a one-line stdout notice
#     (UserPromptSubmit stdout is injected as context, so Claude can proactively offer a
#     handoff). Fires ONCE per session — a `.context-warned-<session_id>` marker in the
#     state dir; stale markers (>24h) are pruned so new sessions re-warn.
#   • BLOCK (≥ block threshold, default 270000): print guidance to stderr and exit 2,
#     which ERASES the prompt (same mechanism as plan-gate.sh). The user must shrink the
#     context (/mentor:handoff → /mentor:resume, or /compact) before continuing.
#
# Escape hatches ALWAYS pass: an empty prompt, or any prompt starting with "/" (slash
# commands like /mentor:handoff, /compact, /mentor:mode) — checked FIRST, before any
# measurement, so the gate can never lock the user out of the tools that fix it.
#
# Fail-soft everywhere: no jq / no transcript / no usage record in the tail window /
# malformed input → exit 0. Never brick a session.
#
# Kill switch: MENTOR_CONTEXT_GATE=off (env) or "context_gate":"off" (.mentor/config.json).
# Thresholds: MENTOR_CONTEXT_{WARN,BLOCK}_TOKENS (env) or context_{warn,block}_tokens (config).

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)" || exit 0
# Passthroughs FIRST: empty prompt or any slash command → never gate.
[ -z "$PROMPT" ] && exit 0
case "$PROMPT" in /*) exit 0 ;; esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"

# Kill switch (env or per-repo config).
[ "$(mentor_context_gate_state "$repo_root")" = "on" ] || exit 0

TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || exit 0
TOKENS="$(mentor_context_tokens "$TRANSCRIPT")"
[ -z "$TOKENS" ] && exit 0   # unmeasurable → fail-soft

BLOCK_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_BLOCK_TOKENS:-}" context_block_tokens 270000)"
WARN_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_TOKENS:-}" context_warn_tokens 200000)"

# --- BLOCK tier -------------------------------------------------------------
if [ "$TOKENS" -ge "$BLOCK_AT" ]; then
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
    echo "[mentor] Context is getting large (~${TOKENS} tokens ≥ ${WARN_AT}). At a natural stopping point, consider /mentor:handoff (then /mentor:resume in a fresh session) or /compact. (Shown once per session.)"
  fi
fi

exit 0
