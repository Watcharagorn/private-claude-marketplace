#!/usr/bin/env bash
# context-gate.sh — UserPromptSubmit
#
# The mentor CONTEXT GATE. Measures the live context size from the session transcript
# and acts in three tiers — it NEVER blocks or erases a prompt (warn-only + ask-first):
#   • WARN  (≥ warn threshold, default 200000): exit 0 with a one-line stdout notice
#     (UserPromptSubmit stdout is injected as context, so Claude can proactively offer a
#     handoff). Fires ONCE per session — a `.context-warned-<session_id>` marker in the
#     state dir; stale markers (>24h) are pruned so new sessions re-warn.
#   • WARN-HIGH (≥ warn-high threshold, default 90% of the effective ask threshold):
#     a near-limit nudge that RE-FIRES on every prompt in the zone — no marker — so the
#     agent steers toward a natural handoff boundary before the ask tier.
#   • ASK (≥ ask threshold, default 350000): stdout DIRECTIVE + exit 0 — the model must
#     first ask the user via AskUserQuestion: hand off now (recommended), or bypass the
#     gate for this session. "Bypass" runs bypass-context.sh, which writes a
#     `.context-bypass-<session_id>` marker; with the marker present this tier degrades
#     to a one-line advisory. A fresh handoff note (<30 min old) also suppresses the
#     question — the handoff already happened; the advisory just points at it.
#     (The ask-threshold knob keeps its historical name: MENTOR_CONTEXT_BLOCK_TOKENS /
#     context_block_tokens.)
#
# Escape hatches ALWAYS pass: an empty prompt, or any prompt starting with "/" (slash
# commands like /mentor:handoff, /compact, /mentor:mode) — checked FIRST, before any
# measurement, so the gate can never slow down the tools that fix it.
#
# Harness-synthetic prompts (an inbound agent report or task notification — no human
# behind them) are MEASURED like any prompt but never get the ASK question: nobody is
# there to answer it, and a question would stall an autonomous flow. They pass with a
# loud stdout advisory instead.
#
# Fail-soft everywhere: no jq / no transcript / no usage record in the tail window /
# malformed input → exit 0. Never brick a session.
#
# Kill switch: MENTOR_CONTEXT_GATE=off (env) or "context_gate":"off" (.mentor/config.json).
# Thresholds: MENTOR_CONTEXT_{WARN,WARN_HIGH,BLOCK}_TOKENS (env) or
# context_{warn,warn_high,block}_tokens (config).

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh"

INPUT="$(cat)" || exit 0

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)" || exit 0
# Passthroughs FIRST: empty prompt or any slash command → never gate.
[ -z "$PROMPT" ] && exit 0
case "$PROMPT" in /*) exit 0 ;; esac

# Harness-synthetic prompt? Still measured below, but never asked a question (see header).
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

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || true
state_dir="$(mentor_state_dir "$repo_root")"
[ -z "$state_dir" ] && state_dir="${HOME}/.claude/mentor/_no-repo"

ASK_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_BLOCK_TOKENS:-}" context_block_tokens 350000)"
WARN_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_TOKENS:-}" context_warn_tokens 200000)"
# Near-limit tier defaults to 90% of the EFFECTIVE ask threshold so it tracks overrides.
WARN_HIGH_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_HIGH_TOKENS:-}" context_warn_high_tokens $(( ASK_AT * 9 / 10 )))"

# --- ASK tier (top tier — never blocks; degradations checked first) ----------
if [ "$TOKENS" -ge "$ASK_AT" ]; then
  # 1) The user already chose to bypass this session → one-line advisory only.
  if [ -e "${state_dir}/.context-bypass-${SESSION_ID:-nosession}" ]; then
    echo "[mentor] Context gate bypassed for this session (~${TOKENS} tokens ≥ ${ASK_AT}) — still prefer wrapping the current unit of work and handing off at the next natural boundary (/mentor:handoff → /mentor:resume in a fresh session)."
    exit 0
  fi
  # 2) A fresh handoff note (<30 min) exists → the handoff already happened; point at it.
  latest_handoff="$(mentor_latest_handoff "$repo_root")"
  if [ -n "$latest_handoff" ] && [ -n "$(find "$latest_handoff" -mmin -30 2>/dev/null)" ]; then
    slug="${latest_handoff##*/}"; slug="${slug%.md}"
    slug="${slug#[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-}"
    echo "[mentor] Context is over the ask threshold (~${TOKENS} tokens ≥ ${ASK_AT}) but a fresh handoff note already exists (${latest_handoff}). Answer briefly and remind the user they can continue in a fresh session with: /mentor:resume ${slug}"
    exit 0
  fi
  # 3) Synthetic agent report → never a question; consume the result, advise loudly.
  if [ "$SYNTHETIC" = "1" ]; then
    echo "[mentor] Context is over the ask threshold (~${TOKENS} tokens ≥ ${ASK_AT}) and this prompt is a harness-generated agent report. Consume this result, then hand off at the next natural boundary — /mentor:handoff (→ /mentor:resume in a fresh session) or /compact — BEFORE dispatching more work."
    exit 0
  fi
  # 4) Human prompt, no bypass, no fresh handoff → the user decides first.
  cat <<EOF
[mentor] CONTEXT: ASK (~${TOKENS} tokens ≥ ${ASK_AT}). Do NOT act on this prompt yet.
FIRST ask the user via AskUserQuestion (header "Context", two options):
  1. "Hand off to next agent (Recommended)" — then invoke Skill(skill="mentor:handoff")
     with a focus describing the work in flight, write the handoff doc, print its
     copy-paste /mentor:resume prompt, and STOP.
  2. "Proceed anyway (bypass for this session)" — then run
     \`bash ${HOOK_DIR}/bypass-context.sh\` and immediately fulfill the user's original
     request above. Warnings continue; a fresh session re-arms the gate.
(Threshold: "context_block_tokens" in .mentor/config.json or MENTOR_CONTEXT_BLOCK_TOKENS;
disable entirely with MENTOR_CONTEXT_GATE=off.)
EOF
  exit 0
fi

# --- WARN-HIGH tier (near-limit, re-fires every prompt in the zone) ----------
if [ "$TOKENS" -ge "$WARN_HIGH_AT" ]; then
  echo "[mentor] Context is nearing the handoff threshold (~${TOKENS} of ${ASK_AT} tokens). Steer toward a natural boundary now — wrap the current unit of work, then /mentor:handoff (→ /mentor:resume in a fresh session) or /compact. Avoid opening new large workstreams. (Re-fires each prompt; tune \"context_warn_high_tokens\" / \"context_block_tokens\" in .mentor/config.json if your repo uses a different budget.)"
  exit 0
fi

# --- WARN tier (once per session) ------------------------------------------
if [ "$TOKENS" -ge "$WARN_AT" ]; then
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
