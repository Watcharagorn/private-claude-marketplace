#!/usr/bin/env bash
# test-state-consistency.sh — regression guard for the plan-state enum staying in
# sync across its independent hand-authored sources.
#
# Session 19352ca6 (2026-08-10) re-derived, by full-repo grep, five separate times in
# one transcript that the plan-state enum's views must agree — each is a different VIEW
# of the same six states (draft/approved/in_progress/implemented/failed/superseded),
# authored by hand, with nothing enforcing that a rename or a new state lands in all of
# them. A prose "map" documenting this was considered and rejected (loom `learn mentor`
# session 19352ca6-3ee8-4239-b212-421717331575, expert review): a further
# hand-maintained artifact is one more thing to drift. This test reads the actual case
# arms, list and table rows on every run.
#
# Sources compared (v5.0.0 — plan-track's recovery table went with that skill):
#   1. hooks/lib/state.sh — mentor_plan_state_rank()'s case arms (what reads rank)
#   2. hooks/lib/state.sh — MENTOR_PLAN_STATES (what `set` accepts, via
#      mentor_plan_state_valid)
#   3. README.md — the State/Meaning table (what users are told)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
STATE_LIB="$PLUGIN_DIR/hooks/lib/state.sh"
README="$PLUGIN_DIR/README.md"
for f in "$STATE_LIB" "$README"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }

sorted() { tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '; }

# --- source 1: mentor_plan_state_rank()'s explicit case arms ---
rank_states="$(awk '/^mentor_plan_state_rank\(\)/{f=1} f{print} f && /^}/{exit}' "$STATE_LIB" \
  | grep -oE '^[[:space:]]*[a-z_]+\)' | tr -d ') \t' | sorted)"
[ -n "$rank_states" ] || { echo "FATAL: could not extract case arms from mentor_plan_state_rank() in $STATE_LIB — function renamed or reshaped?" >&2; exit 1; }

# --- source 2: MENTOR_PLAN_STATES, the validator's accepted list ---
valid_states="$(sed -nE 's/^MENTOR_PLAN_STATES="([^"]*)".*/\1/p' "$STATE_LIB" | head -1 | sorted)"
[ -n "$valid_states" ] || { echo "FATAL: could not extract MENTOR_PLAN_STATES from $STATE_LIB — variable renamed or reshaped?" >&2; exit 1; }

# --- source 3: README.md's State/Meaning table ---
# Anchored on the table header, not a section heading, so an unrelated table in the
# same section is never swallowed.
readme_states="$(awk '/^\| State \| Meaning \|/{f=1;next} f && !/^\|/{exit} f' "$README" \
  | grep -oE '^\| `[a-z_]+`' | sed -E 's/^\| `//; s/`$//' | sorted)"
[ -n "$readme_states" ] || { echo "FATAL: could not extract states from README.md's State/Meaning table — heading or table shape changed?" >&2; exit 1; }

echo "== A. MENTOR_PLAN_STATES matches mentor_plan_state_rank()'s case arms =="
if [ "$valid_states" = "$rank_states" ]; then
  ok "state.sh: {$valid_states}"
else
  bad "MENTOR_PLAN_STATES {$valid_states} != rank arms {$rank_states} — \`set\` would accept a state that ranks 0, or reject one that ranks"
fi

echo "== B. README.md's state table matches mentor_plan_state_rank()'s case arms =="
if [ "$readme_states" = "$rank_states" ]; then
  ok "README: {$readme_states}"
else
  bad "README {$readme_states} != state.sh rank arms {$rank_states} — a state was renamed/added/removed in one but not the other"
fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
