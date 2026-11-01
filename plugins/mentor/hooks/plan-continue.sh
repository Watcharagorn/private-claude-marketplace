#!/usr/bin/env bash
# plan-continue.sh — Stop (v6.0.0): keep an approved run going until a terminal state.
#
# The core concept (AGENTS.md → Mentor core concept, rule 6) is "run until the check
# passes, using native host primitives". This is that primitive: when the model tries
# to end its turn while the session's approved plan is still in_progress, the hook
# blocks the stop and names the next step. It is NOT a sequencer — it never decides
# what to do, never reads verdicts or decision-log rows, never re-polls anything. It
# reads two facts (the session's run marker and the plan's STORED state) and answers
# "may this session stop now?".
#
# Rows, first match wins (planning/SKILL.md → After Proceed; README → How it works):
#   1. MENTOR_CONTINUE=off or "continue":"off" in .mentor/config.json → allow
#   2. no run marker .mentor/.run-<session_id>                            → allow
#   3. the marker's plan has a stored state other than in_progress        → allow
#      (paused = approved, failed, implemented — all terminal for this hook)
#   4. plan.md untouched for MENTOR_PLAN_MARKER_STALE_MIN minutes         → allow, delete marker
#   5. ≥ continue_max_idle_blocks (default 3) consecutive blocks with no
#      progress (plan.md and the working tree unchanged since the last block)
#                                                                         → allow, with a notice
#   6. otherwise                                                          → block, naming the next step
#
# stop_hook_active is deliberately ignored: it is true on every re-entry after a block,
# so it cannot tell a stuck loop from a working one — row 5's progress check does that.
# The host's own consecutive-block cap (8 by default) is a further backstop.
#
# Fail-open everywhere: no jq, malformed input, an unreadable plan → exit 0 silently.
# A broken guardrail must never trap a session.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state.sh
. "${HOOK_DIR}/lib/state.sh" 2>/dev/null || exit 0

INPUT="$(cat)" || exit 0

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"
[ -n "$repo_root" ] || exit 0
state_dir="$(mentor_state_dir "$repo_root")"

# Row 1 — off switch.
cont_cfg="$(mentor_config_get "$repo_root" "continue")"
[ "${MENTOR_CONTINUE:-${cont_cfg:-on}}" = "off" ] && exit 0

# Row 2 — no run marker for this session.
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
[ -n "$SESSION_ID" ] || exit 0
find "$state_dir" -maxdepth 1 -name '.run-*' -mmin +1440 -delete 2>/dev/null || true
marker="${state_dir}/.run-${SESSION_ID}"
[ -f "$marker" ] || exit 0

slug="$(sed -n 's/^slug=//p' "$marker" 2>/dev/null | head -n 1)"
[ -n "$slug" ] || exit 0
plan_dir="${state_dir}/plans/${slug}"
plan_md="${plan_dir}/plan.md"
[ -f "$plan_md" ] || { rm -f "$marker" "${marker}.idle"; exit 0; }

# Row 3 — stored state, never the tick-derived effective state: a plan whose steps are
# all ticked derives `implemented` before its Goal check, Done review, and delivery ran.
stored="$(mentor_plan_state_stored "$plan_dir")"
[ "$stored" = "in_progress" ] || exit 0

# Row 4 — stale: the plan has not moved for a working day (no tick, row, or review).
# The marker's own age is not used — every block below refreshes it, so the 1440-minute
# prune above only ever removes markers of sessions that stopped blocking long ago.
stale_min="${MENTOR_PLAN_MARKER_STALE_MIN:-480}"
if [ -n "$(find "$plan_md" -mmin "+${stale_min}" 2>/dev/null)" ]; then
  rm -f "$marker" "${marker}.idle"
  exit 0
fi

# Row 5 — progress: plan.md (ticks, log rows, Done review) or the working tree changed
# since the last block. Fingerprint, not a diff: cheap, and any real work moves it.
fingerprint="$( {
  cksum < "$plan_md"
  git -C "$repo_root" status --porcelain 2>/dev/null
  git -C "$repo_root" diff HEAD 2>/dev/null
} | cksum | cut -d' ' -f1)"
idle_file="${marker}.idle"
last_fp=""; idle=0
if [ -f "$idle_file" ]; then
  read -r idle last_fp < "$idle_file" 2>/dev/null || true
fi
case "$idle" in ''|*[!0-9]*) idle=0 ;; esac
if [ "$fingerprint" = "$last_fp" ]; then idle=$((idle + 1)); else idle=0; fi

max_cfg="$(mentor_config_get "$repo_root" "continue_max_idle_blocks")"
max_idle="${MENTOR_CONTINUE_MAX_IDLE:-${max_cfg:-3}}"
case "$max_idle" in ''|*[!0-9]*) max_idle=3 ;; esac

if [ "$idle" -ge "$max_idle" ]; then
  rm -f "$idle_file"
  msg="[mentor] plan-continue: ${slug} made no progress across ${idle} continuations — letting this stop through. Write a paused row in ## Decision log saying what blocks the run, set the plan paused (plan-state.sh set ${slug} approved --note \"paused: row N\"), and write ## Done review before you end."
  jq -n --arg m "$msg" '{systemMessage: $m}' 2>/dev/null || true
  exit 0
fi
printf '%s %s\n' "$idle" "$fingerprint" > "$idle_file" 2>/dev/null || true
touch "$marker" 2>/dev/null || true

# Row 6 — block, naming the next unticked step.
next="$(mentor_plan_step_scan "$plan_md" 2>/dev/null | awk -F'\t' '$1 == "STEP" && $5 == 0 { print $2; exit }')"
if [ -n "$next" ]; then
  where="next step ${next}"
else
  where="every step is ticked — grade ## Verification, write ## Done review, grade the ## Goal check against it, deliver"
fi
reason="continue ${slug}: ${where}. Re-read .mentor/plans/${slug}/plan.md and planning \"After Proceed\" + references/verifier-contract.md. Stop only at a terminal state: done (set implemented), paused on an always-pause item (set approved --note \"paused: row N\"), or failed (set failed --note)."
jq -n --arg r "$reason" '{decision: "block", reason: $r}' 2>/dev/null || exit 0
exit 0
