#!/usr/bin/env bash
# test-state-consistency.sh — regression guard for the plan-state enum staying in
# sync across its three independent sources.
#
# Session 19352ca6 (2026-08-10) re-derived, by full-repo grep, five separate times in
# one transcript that README.md's state table, `mentor_plan_state_rank` in
# `hooks/lib/state.sh`, and `plan-track/SKILL.md`'s "Effective state" recovery table
# must agree on the plan-state enum — each is a different VIEW of the same six states
# (draft/approved/in_progress/implemented/failed/superseded), authored by hand, with
# nothing enforcing that a rename or a new state lands in all three. A prose "map"
# documenting this was considered and rejected (loom `learn mentor` session
# 19352ca6-3ee8-4239-b212-421717331575, expert review): a fourth hand-maintained
# artifact is one more thing to drift, and would have described the problem without
# stopping it. This test can't drift silently the way a doc can — it reads the actual
# case arms and table rows on every run.
#
# `plan-track`'s recovery table deliberately excludes `superseded` (those plans are
# offered as "quick options" elsewhere — SKILL.md's own text near "quick options",
# never as a row to act on here) and adds `unknown` (a derived read, not a stored
# state). That is a real, intentional difference, not drift — so the invariant below
# compares README's table MINUS `superseded` against plan-track's table MINUS
# `unknown`, rather than asserting raw set equality across all three.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
STATE_LIB="$PLUGIN_DIR/hooks/lib/state.sh"
README="$PLUGIN_DIR/README.md"
PLAN_TRACK="$PLUGIN_DIR/skills/plan-track/SKILL.md"
for f in "$STATE_LIB" "$README" "$PLAN_TRACK"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }

sorted() { tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '; }

# --- source 1: hooks/lib/state.sh — mentor_plan_state_rank()'s explicit case arms ---
rank_states="$(awk '/^mentor_plan_state_rank\(\)/{f=1} f{print} f && /^}/{exit}' "$STATE_LIB" \
  | grep -oE '^[[:space:]]*[a-z_]+\)' | tr -d ') \t' | sorted)"
[ -n "$rank_states" ] || { echo "FATAL: could not extract case arms from mentor_plan_state_rank() in $STATE_LIB — function renamed or reshaped?" >&2; exit 1; }

# --- source 2: README.md — the "## Plan state" section's own State/Meaning table ---
# Anchored on the table header, not the section heading: the same section also carries
# an unrelated "Sidecar schema" Field/Type table further down, which a heading-to-heading
# scan would wrongly swallow.
readme_states="$(awk '/^\| State \| Meaning \|/{f=1;next} f && !/^\|/{exit} f' "$README" \
  | grep -oE '^\| `[a-z_]+`' | sed -E 's/^\| `//; s/`$//' | sorted)"
[ -n "$readme_states" ] || { echo "FATAL: could not extract states from README.md's State/Meaning table — heading or table shape changed?" >&2; exit 1; }

# --- source 3: plan-track/SKILL.md — the "Effective state" recovery table's first column ---
plantrack_states="$(awk '/^\| Effective state \| What to do \|/{f=1;next} f && !/^\|/{exit} f' "$PLAN_TRACK" \
  | grep -oE '^\| `[a-z_]+`' | sed -E 's/^\| `//; s/`$//' | sorted)"
[ -n "$plantrack_states" ] || { echo "FATAL: could not extract states from plan-track/SKILL.md's 'Effective state' table — heading or table shape changed?" >&2; exit 1; }

echo "== A. README.md's state table matches mentor_plan_state_rank()'s case arms =="
if [ "$readme_states" = "$rank_states" ]; then
  ok "README: {$readme_states}"
else
  bad "README {$readme_states} != state.sh rank arms {$rank_states} — a state was renamed/added/removed in one but not the other"
fi

echo "== B. plan-track's recovery table matches README's table, minus superseded/unknown =="
readme_minus_superseded="$(printf '%s' "$readme_states" | tr ' ' '\n' | grep -vx 'superseded' | sorted)"
plantrack_minus_unknown="$(printf '%s' "$plantrack_states" | tr ' ' '\n' | grep -vx 'unknown' | sorted)"
if [ "$readme_minus_superseded" = "$plantrack_minus_unknown" ]; then
  ok "plan-track (minus unknown): {$plantrack_minus_unknown}"
else
  bad "plan-track recovery table {$plantrack_minus_unknown} != README states minus superseded {$readme_minus_superseded} — plan-track's table should cover every stored state except superseded (handled elsewhere as a quick option)"
fi

echo "== C. plan-track's table names no state the rank function doesn't know =="
unknown_to_rank=""
for s in $plantrack_states; do
  [ "$s" = "unknown" ] && continue
  case " $rank_states " in *" $s "*) ;; *) unknown_to_rank="$unknown_to_rank $s" ;; esac
done
if [ -z "$unknown_to_rank" ]; then
  ok "every plan-track row names a real rank-function state"
else
  bad "plan-track table names state(s) not in mentor_plan_state_rank():$unknown_to_rank"
fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
