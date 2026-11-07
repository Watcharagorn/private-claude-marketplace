#!/usr/bin/env bash
# context-gate.sh — UserPromptSubmit (the ONE per-prompt hook)
#
# Carries three independent advisories: the CONTEXT GATE (tier 1), the
# PLANNING-INTENT NUDGE (tier 2, merged in from the retired planning-intent.sh in
# v2.34.0), and a live PLAN POINTER on every prompt. They share one process, one
# `. lib/state.sh`, and one cwd/repo resolution. Warning and nudge switches remain
# independent; synthetic prompts are measured by the gate and skipped by the nudge.
#
# TIER 1 — the mentor CONTEXT GATE. Measures the live context size from the session transcript
# and WARNS in three tiers. Warn-only (v4.2.0): it never blocks and never asks a question —
# every tier is a one-line stdout notice (UserPromptSubmit stdout
# is injected as context) and exit 0, ending with the progress-first sentence.
# Thresholds come from mentor_context_limits (lib/state.sh, v4.3.0): a ratio of the
# compaction window capped by the token knobs when the window is known, the token knobs
# alone when it is not (the window is never guessed).
#   • WARN  (≥ warn threshold: min(50% of window, 200000), 200000 with no window). RE-ARMS
#     on growth — a `.context-warned-<session_id>` marker in the state dir stores the token
#     count at the last fire, and WARN fires again once the live count has grown by the
#     re-arm step (10% of the window, or a quarter of the warn threshold — ~50000 tokens
#     at defaults — with no window) past that, so a session that keeps climbing gets
#     more than one notice before WARN-HIGH takes over. Stale markers (>24h) are pruned so
#     new sessions re-warn; an empty legacy marker reads as "never warned".
#   • WARN-HIGH (≥ warn-high threshold, default 90% of the effective limit):
#     near-limit notice that RE-FIRES on every prompt in the zone — no marker.
#   • HIGH (≥ limit: min(65% of window, context_block_tokens), default 350000):
#     over-the-limit notice, also every prompt. (The cap keeps its historical name:
#     MENTOR_CONTEXT_BLOCK_TOKENS / context_block_tokens.)
#
# Empty prompts and slash commands skip context measurement and the nudge; a live
# plan pointer still prints so /compact and /mentor:plan retain the plan's location.
#
# Harness-synthetic prompts (an inbound agent/teammate report, a task notification, a
# background-agent stop notice — no actionable human REQUEST behind them) are MEASURED
# like any prompt but never consume the re-arming WARN (see the WARN tier) — that notice
# belongs to the human's next real prompt.
#
# Fail-soft everywhere: no jq / malformed input → exit 0. No transcript or usage
# record skips the context warning while the plan pointer remains independent.
#
# Kill switch: MENTOR_CONTEXT_GATE=off (env) or "context_gate":"off" (.mentor/config.json).
# Thresholds: MENTOR_CONTEXT_{WARN,WARN_HIGH,BLOCK}_TOKENS / MENTOR_CONTEXT_{WARN,HIGH}_RATIO
# / MENTOR_CONTEXT_WINDOW (env) or context_{warn,warn_high,block,window}_tokens /
# context_{warn,high}_ratio (config).

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh" 2>/dev/null || exit 0

INPUT="$(cat)" || exit 0

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)" || exit 0
# Passthroughs skip the warning/nudge functions, independently of the plan pointer.
PASSTHROUGH=0
case "$PROMPT" in ''|/*) PASSTHROUGH=1 ;; esac

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
plans_dir="$(mentor_plans_dir "$repo_root")"
wt_id=""
[ ! -d "$plans_dir" ] || wt_id="$(mentor_worktree_id "$CWD")"

# ---------------------------------------------------------------------------
# TIER 1 — the context gate. A function, not the tail of the script, because the
# planning-intent nudge below must still run when this half returns early (kill switch
# off, unmeasurable transcript, or a tier that already fired). Under the two separate
# hooks this merge replaced, that independence was free; here `return 0` is what buys it.
# Bodies are deliberately NOT re-indented: an indent-only diff would hide real changes in
# review.
mentor_context_tiers() {
[ "$PASSTHROUGH" = "0" ] || return 0
# Kill switch (env or per-repo config).
[ "$(mentor_context_gate_state "$repo_root")" = "on" ] || return 0

TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || return 0
TOKENS="$(mentor_context_tokens "$TRANSCRIPT")"
[ -z "$TOKENS" ] && return 0   # unmeasurable → fail-soft

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || true
state_dir="$(mentor_state_dir "$repo_root")"
[ -z "$state_dir" ] && state_dir="$(mentor_no_repo_state_dir)"

# One derivation for every context reading (window ratio + caps + clamp); the near-limit
# tier defaults to 90% of the EFFECTIVE limit so it tracks overrides.
read -r WARN_AT WARN_HIGH_AT ASK_AT rearm_delta WINDOW <<<"$(mentor_context_limits "$repo_root" "$SESSION_ID")"
SIZE="$(mentor_context_size "$TOKENS" "$WINDOW")"
PROGRESS="$(mentor_context_progress_note)"
# The tuning hint names both knob families: with a known window a ratio can be the
# binding limit, and raising a cap alone then changes nothing.
KNOBS='"context_*_tokens" / "context_*_ratio" in .mentor/config.json'

# --- HIGH tier (over the limit; re-fires every prompt) -----------------------
if [ "$TOKENS" -ge "$ASK_AT" ]; then
  echo "[mentor] CONTEXT: HIGH — ${SIZE} ≥ ${ASK_AT}, over the limit; answers degrade this deep into a session. Keep the remaining work small and lean. ${PROGRESS} (Thresholds: ${KNOBS}, or MENTOR_CONTEXT_GATE=off.)"
  return 0
fi

# --- WARN-HIGH tier (near-limit, re-fires every prompt in the zone) ----------
if [ "$TOKENS" -ge "$WARN_HIGH_AT" ]; then
  echo "[mentor] Context is nearing the limit: ${SIZE}, limit ${ASK_AT}. Avoid opening new large workstreams. ${PROGRESS} (Re-fires each prompt; thresholds: ${KNOBS}.)"
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
  # rearm_delta (from mentor_context_limits) is 10% of the window, or a quarter of the
  # warn threshold (~50000 tokens at defaults) with no window: far enough apart that a
  # session climbing steadily doesn't get spammed, close enough that a session sitting in
  # the WARN-to-WARN-HIGH zone for a while (the exact gap a fan-out-heavy session can spend
  # tens of turns inside) still gets more than the one notice at the bottom of the zone.
  if [ "$last_warned" = 0 ] || [ $(( TOKENS - last_warned )) -ge "$rearm_delta" ]; then
    mkdir -p -m 700 "$state_dir" 2>/dev/null || true
    [ -n "$repo_root" ] && mentor_ensure_gitignore "$state_dir"
    printf '%s' "$TOKENS" > "$marker" 2>/dev/null || true
    echo "[mentor] Context is getting large: ${SIZE} ≥ ${WARN_AT}. ${PROGRESS} (Re-fires every ~${rearm_delta} tokens of further growth; thresholds: ${KNOBS}.)"
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
# empty-prompt, slash-command and synthetic-prompt classification.
mentor_planning_nudge() {
[ "$PASSTHROUGH" = "0" ] || return 0
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
  if [ -n "$(mentor_live_gate "$plans_dir" "$wt_id" -e)" ]; then
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
# inside the target repo's .mentor/ (see header). The base follows MENTOR_STATE_HOME,
# else CLAUDE_CONFIG_DIR, else ~/.claude (mentor_host_state_base).
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || true
scratch_dir="$(mentor_host_state_base claude)/_prompt-nudges"
marker="${scratch_dir}/.planning-intent-${SESSION_ID:-nosession}"
[ -e "$marker" ] && return 0
mkdir -p "$scratch_dir" 2>/dev/null || true
# Prune stale nudge markers (>24h) so the scratch dir doesn't grow one empty file
# per matching session forever — same idiom as the context gate's warn markers above.
find "$scratch_dir" -maxdepth 1 -name '.planning-intent-*' -mmin +1440 -delete 2>/dev/null || true
: > "$marker" 2>/dev/null || true

echo "[mentor] This looks like a planning request. Use mentor's planning flow so its structured plan format and approval boundary apply: invoke Skill(mentor:planning) directly, or offer the user \`/mentor:plan <topic>\`, which in Claude Code also arms the enforced edit gate. (Disable this advisory with MENTOR_PLANNING_INTENT=off or \"planning_intent\":\"off\" in .mentor/config.json.)"

return 0
}

# ---------------------------------------------------------------------------
# The plan pointer has no warning threshold or dedup marker: every prompt while
# drafting/running needs the path, including near compaction. Read stored state;
# all steps ticked still leaves the Goal check to grade before a run is finished.
mentor_plan_pointer() {
  local pp_gate pp_md="" pp_slug="" pp_stored
  local pp_session pp_run pp_next pp_total pp_ticked pp_title pp_change=""
  [ -n "$repo_root" ] && [ -d "$plans_dir" ] || return 0
  pp_gate="$(mentor_live_gate "$plans_dir" "$wt_id")"

  if [ -n "$pp_gate" ]; then
    pp_md="$(mentor_armed_draft "$plans_dir" "$wt_id" "$pp_gate")"
    if [ -z "$pp_md" ]; then
      echo "mentor plan: no plan file yet · it is created at research start (planning Step 2)"
      return 0
    fi
    pp_slug="${pp_md%/plan.md}"
    pp_slug="${pp_slug##*/}"
  else
    pp_session="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || return 0
    case "$pp_session" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
    pp_run="${repo_root}/.mentor/.run-${pp_session}"
    [ -f "$pp_run" ] || return 0
    pp_slug="$(mentor_marker_field "$pp_run" slug)"
    case "$pp_slug" in ''|.|..|*[!A-Za-z0-9_-]*) return 0 ;; esac
    pp_md="${plans_dir}/${pp_slug}/plan.md"
    [ -f "$pp_md" ] || return 0
  fi

  pp_stored="$(mentor_plan_state_stored "${pp_md%/plan.md}")"
  if [ ! -f "$pp_md" ]; then
    pp_next="unavailable (plan.md missing)"
  elif [ "$pp_stored" = draft ]; then
    pp_next="drafting"
  else
    IFS=$'\t' read -r pp_ticked pp_total pp_next pp_title <<<"$(mentor_plan_scan_summary "$pp_md")" || return 0
    case "$pp_next:$pp_total" in *[!0-9:]*|:*|*:) return 0 ;; esac
    if [ "$pp_total" = "0" ] && [ "$pp_stored" != approved ] && [ "$pp_stored" != in_progress ]; then
      pp_next="drafting"
    elif [ "$pp_next" = "0" ]; then
      pp_next="goal check"
    else
      pp_next="step ${pp_next}/${pp_total}"
    fi
  fi
  if [ "$(mentor_plan_drift "$pp_md")" = "changed" ]; then
    pp_change=" · plan.md changed since mentor last wrote it — read it before editing it further"
  fi
  printf 'mentor plan: %s · .mentor/plans/%s/plan.md · %s · next: %s%s\n' \
    "$pp_slug" "$pp_slug" "${pp_stored:-unknown}" "$pp_next" "$pp_change"
  return 0
}

# Keep warning priority and the existing UserPromptSubmit stdout context channel.
# Each advisory runs independently; none can fail the prompt or swallow another.
mentor_context_tiers 2>/dev/null || true
mentor_planning_nudge 2>/dev/null || true
mentor_plan_pointer 2>/dev/null || true

exit 0
