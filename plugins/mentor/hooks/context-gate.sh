#!/usr/bin/env bash
# context-gate.sh — UserPromptSubmit (the ONE per-prompt hook)
#
# Carries two independent advisories that both fire on every prompt: the CONTEXT GATE
# (tier 1) and the PLANNING-INTENT NUDGE (tier 2, merged in from the retired
# planning-intent.sh in v2.34.0). They share nothing but the preamble — one process, one
# `. lib/state.sh`, one jq parse of stdin, one cwd/repo resolution — which is the entire
# reason they are one file. Each keeps its own kill switch, its own config key, its own
# marker location, and its own passthrough semantics for synthetic prompts (the gate
# MEASURES them; the nudge skips them). See each tier's own banner below.
#
# TIER 1 — the mentor CONTEXT GATE. Measures the live context size from the session transcript
# and WARNS in three tiers. Warn-only (v4.2.0): it never blocks, never asks a question, and
# never suggests a handoff — every tier is a one-line stdout notice (UserPromptSubmit stdout
# is injected as context) and exit 0.
#   • WARN  (≥ warn threshold, default 200000). RE-ARMS on growth — a
#     `.context-warned-<session_id>` marker in the state dir stores the token count at the
#     last fire, and WARN fires again once the live count has grown by a quarter of the warn
#     threshold (~50000 tokens at defaults) past that, so a session that keeps climbing gets
#     more than one notice before WARN-HIGH takes over. Stale markers (>24h) are pruned so
#     new sessions re-warn; an empty legacy marker reads as "never warned".
#   • WARN-HIGH (≥ warn-high threshold, default 90% of the effective limit):
#     near-limit notice that RE-FIRES on every prompt in the zone — no marker.
#   • HIGH (≥ limit, context_block_tokens, default 350000): over-the-limit notice, also every prompt.
#     (The knob keeps its historical name: MENTOR_CONTEXT_BLOCK_TOKENS /
#     context_block_tokens.)
#
# Escape hatches ALWAYS pass: an empty prompt, or any prompt starting with "/" (slash
# commands like /compact, /mentor:mode) — checked FIRST, before any measurement, so the
# gate can never slow down the tools that fix it.
#
# Harness-synthetic prompts (an inbound agent/teammate report, a task notification, a
# background-agent stop notice — no actionable human REQUEST behind them) are MEASURED
# like any prompt but never consume the re-arming WARN (see the WARN tier) — that notice
# belongs to the human's next real prompt.
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

# Harness-synthetic prompt? Still measured below, but never consumes the WARN re-arm (see header).
# Patterns are ANCHORED at position 0 on purpose: a leading `*…*` would exempt a real
# human prompt that merely QUOTES one of these phrases (e.g. asking about a log line).
# Shapes below were measured against this machine's transcript corpus (2026-08-04); the
# bare tags are kept because they are the inner tags of the wrapper form and the shape
# subagent threads already use — a harness change could hoist them to the front.
SYNTHETIC=0
case "$PROMPT" in
  '<agent-message'* | '<teammate-message'* | '<task-notification'*) SYNTHETIC=1 ;;
  # Inter-session / teammate reports arrive WRAPPED — the tag sits on line 2, so the
  # bare-tag arms above never fire for them. This is the dominant real shape.
  'Another Claude session sent a message:'*) SYNTHETIC=1 ;;
  # Background-agent stop notices: `Background agent "…" was stopped by the user.` and
  # `<N> background agent(s) was|were stopped by the user: …`.
  'Background agent "'*' was stopped by the user'*) SYNTHETIC=1 ;;
  [0-9]*' background agent'*' stopped by the user'*) SYNTHETIC=1 ;;
esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"

# ---------------------------------------------------------------------------
# TIER 1 — the context gate. A function, not the tail of the script, because the
# planning-intent nudge below must still run when this half returns early (kill switch
# off, unmeasurable transcript, or a tier that already fired). Under the two separate
# hooks this merge replaced, that independence was free; here `return 0` is what buys it.
# Bodies are deliberately NOT re-indented: an indent-only diff would hide real changes in
# review.
mentor_context_tiers() {
# Kill switch (env or per-repo config).
[ "$(mentor_context_gate_state "$repo_root")" = "on" ] || return 0

TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || return 0
TOKENS="$(mentor_context_tokens "$TRANSCRIPT")"
[ -z "$TOKENS" ] && return 0   # unmeasurable → fail-soft

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || true
state_dir="$(mentor_state_dir "$repo_root")"
[ -z "$state_dir" ] && state_dir="$(mentor_no_repo_state_dir)"

ASK_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_BLOCK_TOKENS:-}" context_block_tokens 350000)"
WARN_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_TOKENS:-}" context_warn_tokens 200000)"
# Near-limit tier defaults to 90% of the EFFECTIVE limit so it tracks overrides.
WARN_HIGH_AT="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_HIGH_TOKENS:-}" context_warn_high_tokens $(( ASK_AT * 9 / 10 )))"

# --- HIGH tier (over the limit; re-fires every prompt) -----------------------
if [ "$TOKENS" -ge "$ASK_AT" ]; then
  echo "[mentor] CONTEXT: HIGH (~${TOKENS} tokens ≥ ${ASK_AT}) — over the limit; answers degrade this deep into a session. Keep the remaining work small and lean. (Tune \"context_block_tokens\" in .mentor/config.json, or MENTOR_CONTEXT_GATE=off.)"
  return 0
fi

# --- WARN-HIGH tier (near-limit, re-fires every prompt in the zone) ----------
if [ "$TOKENS" -ge "$WARN_HIGH_AT" ]; then
  echo "[mentor] Context is nearing the limit (~${TOKENS} of ${ASK_AT} tokens). Avoid opening new large workstreams. (Re-fires each prompt; tune \"context_warn_high_tokens\" / \"context_block_tokens\" in .mentor/config.json if your repo uses a different budget.)"
  return 0
fi

# --- WARN tier (re-arms on growth) ------------------------------------------
# Synthetic prompts skip this tier entirely: in a fan-out-heavy session the prompt that
# first crosses the threshold is almost always an inbound agent report — burning the
# re-arm there spends the human's next warning on a turn they never see. WARN-HIGH and
# HIGH are unconditional, so nothing is lost above them.
if [ "$SYNTHETIC" = "0" ] && [ "$TOKENS" -ge "$WARN_AT" ]; then
  # Prune stale warn markers (>24h) so a long-lived repo re-warns in later sessions.
  find "$state_dir" -maxdepth 1 -name '.context-warned-*' -mmin +1440 -delete 2>/dev/null || true
  marker="${state_dir}/.context-warned-${SESSION_ID:-nosession}"
  last_warned=0
  [ -e "$marker" ] && last_warned="$(cat "$marker" 2>/dev/null)"
  case "$last_warned" in ''|*[!0-9]*) last_warned=0 ;; esac   # empty (legacy marker) / garbage → re-arm
  # A quarter of the warn threshold (~50000 tokens at defaults): far enough apart that a
  # session climbing steadily doesn't get spammed, close enough that a session sitting in
  # the 200k-to-WARN-HIGH zone for a while (the exact gap a fan-out-heavy session can spend
  # tens of turns inside) still gets more than the one notice at the bottom of the zone.
  rearm_delta=$(( WARN_AT / 4 ))
  if [ "$last_warned" = 0 ] || [ $(( TOKENS - last_warned )) -ge "$rearm_delta" ]; then
    mkdir -p -m 700 "$state_dir" 2>/dev/null || true
    [ -n "$repo_root" ] && mentor_ensure_gitignore "$state_dir"
    printf '%s' "$TOKENS" > "$marker" 2>/dev/null || true
    echo "[mentor] Context is getting large (~${TOKENS} tokens ≥ ${WARN_AT}). (Re-fires every ~${rearm_delta} tokens of further growth; thresholds: \"context_warn_tokens\" / \"context_block_tokens\" in .mentor/config.json.)"
  fi
fi

return 0
}

# ---------------------------------------------------------------------------
# TIER 2 — the planning-intent nudge, merged in from the retired planning-intent.sh
# (v2.34.0). It used to be a second UserPromptSubmit hook: a second process, a second
# source of the state lib, and a second jq parse of the same stdin, on every prompt of
# every session — to fire at most once. Everything it does is unchanged, including its
# own kill switch, its own config key, and its marker living under a machine-global
# scratch dir rather than the repo (a heuristic prompt match must never create .mentor/
# in a repo that has never used mentor). The shared preamble above already applied its
# empty-prompt, slash-command and synthetic-prompt passthroughs, which were identical.
mentor_planning_nudge() {
# Kill switch (env, or per-repo config when one already exists — read-only, never
# creates .mentor/ or config.json).
case "${MENTOR_PLANNING_INTENT:-}" in
  off|0|false|no) return 0 ;;
esac
[ "$(mentor_config_get "$repo_root" "planning_intent")" = "off" ] && return 0

# Already inside mentor's planning flow → THIS worktree's own marker (or the legacy
# repo-global one) is live, nudging now is noise. Routed through mentor_marker_stale
# (not a bare `-f` check) so a long-dead marker can't suppress the nudge forever, and
# through mentor_worktree_id/mentor_plan_marker so a live SIBLING worktree's marker —
# an independent gate that doesn't touch this worktree — never suppresses here.
if [ -n "$repo_root" ]; then
  pi_plans="${repo_root}/.mentor/plans"
  pi_wt_id="$(mentor_worktree_id "$CWD")"
  pi_own="$(mentor_plan_marker "$pi_plans" "$pi_wt_id")"
  pi_legacy="$(mentor_plan_marker "$pi_plans" "")"
  if { [ -e "$pi_own" ] && ! mentor_marker_stale "$pi_own"; } \
     || { [ -n "$pi_wt_id" ] && [ -e "$pi_legacy" ] && ! mentor_marker_stale "$pi_legacy"; }; then
    return 0
  fi
fi

# Narrow, anchored planning-intent openers (case-insensitive). See header for why this
# list stays short.
PROMPT_LC="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')"
case "$PROMPT_LC" in
  "help me plan"*|"let's plan"*|"lets plan"*|"can you plan"*|"plan out"*|"i want to plan"*) ;;
  *) return 0 ;;
esac

# Once-per-session only. Marker lives under a machine-global scratch dir — NEVER
# inside the target repo's .mentor/ (see header).
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || true
scratch_dir="${HOME}/.claude/mentor/_prompt-nudges"
marker="${scratch_dir}/.planning-intent-${SESSION_ID:-nosession}"
[ -e "$marker" ] && return 0
mkdir -p "$scratch_dir" 2>/dev/null || true
# Prune stale nudge markers (>24h) so the scratch dir doesn't grow one empty file
# per matching session forever — same idiom as the context gate's warn markers above.
find "$scratch_dir" -maxdepth 1 -name '.planning-intent-*' -mmin +1440 -delete 2>/dev/null || true
: > "$marker" 2>/dev/null || true

echo "[mentor] This looks like a planning request. Offer the user \`/mentor:plan <topic>\` so mentor's edit gate and structured plan format apply — do NOT invoke Skill(mentor:planning) yourself; only the /mentor:plan command arms the gate that makes it safe. (Disable this advisory with MENTOR_PLANNING_INTENT=off or \"planning_intent\":\"off\" in .mentor/config.json.)"

return 0
}

# Order mirrors the hooks.json order these two used to have: the context verdict is the
# more urgent line and must land above the nudge. Both write to stdout, which
# UserPromptSubmit injects as context — exactly as two separate hooks did.
mentor_context_tiers
mentor_planning_nudge

exit 0
