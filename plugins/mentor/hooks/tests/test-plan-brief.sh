#!/usr/bin/env bash
# test-plan-brief.sh — regression tests for `plan-state.sh brief` (v2.31.0+).
#
# Contract under test:
#   • `brief <slug> [--step N]` emits a scope-complete, READ-ONLY envelope: PLAN/TITLE,
#     the `## Context` goal line (mentor_plan_goal_line, section="context" — an ordinary
#     mentor-authored plan carries `## Context`, never `## Goal`), the whole `## Out of
#     scope` section body, one line per step (title + ✅ tick state) in document order,
#     the VERBATIM body of step N when `--step` is given, and the `## Verification`
#     topic title lines (`Topic N — …`) only — never the whole section.
#   • Step-line detection reuses lib/state.sh's MENTOR_STEP_LINE_PATTERN — the SAME
#     pattern mentor_plan_tick_counts/mentor_plan_tick_step match against — so `brief`
#     and `tick` can never disagree about what counts as a step. Both the `Step N — …`
#     heading form and the `N. **Title**` numbered-item form must work.
#   • `--step`'s body is byte-identical to the corresponding lines of plan.md: no
#     trimming, no reformatting, no dropped/added lines.
#   • Never writes: no `.state.json`, no plan.md mutation, ever.
#   • Usage errors (missing slug, unknown slug, missing plan.md, out-of-range --step,
#     non-numeric/zero --step, a stray extra positional) all exit 1 with a stderr reason.
#
# Runs against a SANDBOX $HOME and a throwaway git repo so it never touches real
# user/repo state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
PLANSTATE="$HOOKS/plan-state.sh"
[ -f "$PLANSTATE" ] || { echo "FATAL: not found: $PLANSTATE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1

trap 'rm -rf "$ROOT"' EXIT

PLANS="$REPO/.mentor/plans"
mkdir -p "$PLANS"

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
has()  { printf '%s' "$2" | grep -q -- "$1"; }
hasnt(){ ! printf '%s' "$2" | grep -q -- "$1"; }

_env() { env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
              -u CLAUDE_CODE_SESSION_ID HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" "$@"; }
ps()    { ( cd "$REPO" && _env bash "$PLANSTATE" "$@" 2>&1 ); }          # merged
psout() { ( cd "$REPO" && _env bash "$PLANSTATE" "$@" 2>/dev/null ); }   # stdout only

plan() { # <slug> <plan.md content via stdin>
  local slug="$1"
  mkdir -p "$PLANS/$slug"
  cat > "$PLANS/$slug/plan.md"
}

echo "== A. Full envelope: every section present, numbered-item step form =="
plan full-envelope <<'MD'
# Full Envelope Plan

## Context

This plan touches every layer of the scoped envelope so the test can assert each
section actually shows up, wrapped across more than one line on purpose.

## Implementation steps

1. **First step title**
   Details about the first step, spanning here.

2. **Second step title**
   - sub bullet one
   - sub bullet two
   More narrative text for step two.

3. **Third step title** ✅

## Out of scope

- Widget re-theming — decided against this pass.
- Legacy migration — out of scope, tracked separately.

## Verification

Topic 1 — First check
  Focus: whatever the first check covers.

Topic 2 — Second check
  Focus: whatever the second check covers.
MD
out="$(ps brief full-envelope)"; rc=$?
chk "brief (no --step) → exit 0"        test "$rc" = "0"
chk "..names the plan"                  has "PLAN: full-envelope" "$out"
chk "..carries the title"               has "TITLE: Full Envelope Plan" "$out"
chk "..carries the CONTEXT goal line"   has "CONTEXT: This plan touches every layer" "$out"
chk "..Out of scope heading present"    has "## Out of scope" "$out"
chk "..Out of scope first bullet"       has "Widget re-theming" "$out"
chk "..Out of scope second bullet"      has "Legacy migration" "$out"
chk "..Steps heading with tick ratio"   has "## Steps (1/3 ticked)" "$out"
chk "..step 1 listed"                   has "1: 1. \\*\\*First step title\\*\\*" "$out"
chk "..step 3 listed with its ✅"       has "3: 3. \\*\\*Third step title\\*\\* ✅" "$out"
chk "..Verification topics heading"     has "## Verification topics" "$out"
chk "..Topic 1 title line"              has "Topic 1 — First check" "$out"
chk "..Topic 2 title line"              has "Topic 2 — Second check" "$out"
chk "..Verification FOCUS prose excluded (topic titles only)" \
  hasnt "Focus: whatever the first check covers" "$out"
chk "..no verbatim-body section when --step omitted" hasnt "verbatim body" "$out"

echo "== B. --step body is byte-identical to plan.md (numbered-item form) =="
# Independently derive the expected slice straight from the source file (sed range from
# step 2's own line up to, but excluding, step 3's line) rather than re-deriving it via
# the same code path under test.
expected="$(sed -n '/^2\. \*\*Second step title\*\*/,/^3\. \*\*Third step title\*\*/p' "$PLANS/full-envelope/plan.md" | sed '$d')"
out="$(ps brief full-envelope --step 2)"; rc=$?
chk "brief --step 2 → exit 0"           test "$rc" = "0"
got="$(printf '%s\n' "$out" | awk '/^## Step 2 — verbatim body/{f=1; next} /^$/{if(f){f=0}} f')"
chk "--step 2 verbatim body is byte-identical to the source lines" test "$got" = "$expected"
chk "..header names the step"           has "## Step 2 — verbatim body" "$out"

echo "== C. Step N — form (with sub-bullets, role/effort tag) also byte-identical =="
plan step-dash-form <<'MD'
# Step-Dash Plan

## Context

Uses the `Step N —` heading convention instead of numbered items.

## Implementation steps

Step 1 — First thing  [role: general-purpose · model: sonnet · effort: high] ✅
  - Goal: do the first thing.
  - Done when: it is done.

Step 2 — Second thing  [role: general-purpose · model: sonnet · effort: medium]
  - Goal: do the second thing.
  - Inputs: whatever step 1 produced.
  - Done when: it is also done.

Step 3 — Third thing  [role: general-purpose · model: sonnet · effort: low]
  - Goal: do the third thing.

## Out of scope

- Nothing else this pass.

## Verification

Topic 1 — Only check
  Focus: end to end.
MD
expected2="$(sed -n '/^Step 2 — Second thing/,/^Step 3 — Third thing/p' "$PLANS/step-dash-form/plan.md" | sed '$d')"
out="$(ps brief step-dash-form --step 2)"; rc=$?
chk "brief --step 2 (Step-N-dash form) → exit 0" test "$rc" = "0"
got2="$(printf '%s\n' "$out" | awk '/^## Step 2 — verbatim body/{f=1; next} /^$/{if(f){f=0}} f')"
chk "..verbatim body byte-identical"    test "$got2" = "$expected2"
out_list="$(ps brief step-dash-form)"
chk "..steps list shows Step-N-dash tick states" \
  has "1: Step 1 — First thing  \\[role: general-purpose · model: sonnet · effort: high\\] ✅" "$out_list"
chk "..steps list shows the unticked step too" \
  has "2: Step 2 — Second thing" "$out_list"
chk "..tick ratio (1/3 ticked)"         has "## Steps (1/3 ticked)" "$out_list"

echo "== D. --step out of range =="
out="$(ps brief step-dash-form --step 99)"; rc=$?
chk "--step out of range → exit 1"      test "$rc" = "1"
chk "..names the slug and total"        has "step-dash-form has no step 99" "$out"
chk "..names the total step count"      has "plan.md has 3 step(s)" "$out"

echo "== E. Unknown slug and missing plan.md =="
out="$(ps brief does-not-exist)"; rc=$?
chk "unknown slug → exit 1"             test "$rc" = "1"
chk "..points at 'list'"                has "plan-state.sh list" "$out"

mkdir -p "$PLANS/no-plan-md"   # a real plan dir, but no plan.md written yet
out="$(ps brief no-plan-md)"; rc=$?
chk "missing plan.md → exit 1"          test "$rc" = "1"
chk "..names the missing file"          has "no plan.md at" "$out"

echo "== F. A plan with zero steps =="
plan zero-steps <<'MD'
# Zero Steps Plan

## Context

Nothing to do yet.

## Implementation steps

Nothing here yet — steps TBD, none of these lines are step lines.

## Out of scope

Nothing decided yet.

## Verification

Topic 1 — Placeholder
  Focus: nothing yet.
MD
out="$(ps brief zero-steps)"; rc=$?
chk "zero-step plan → exit 0"           test "$rc" = "0"
chk "..reports 0/0 ticked"              has "## Steps (0/0 ticked)" "$out"
chk "..reports no steps found"          has "(no steps found)" "$out"
out="$(ps brief zero-steps --step 1)"; rc=$?
chk "--step 1 on a zero-step plan → exit 1 (out of range)" test "$rc" = "1"
chk "..names 0 total steps"             has "plan.md has 0 step(s)" "$out"

echo "== G. Missing optional sections fall back to (none) =="
plan minimal <<'MD'
# Minimal Plan

## Implementation steps

1. Only step here.

## Verification

Topic 1 — Only check.
MD
out="$(ps brief minimal)"; rc=$?
chk "minimal plan (no Context/Out of scope) → exit 0" test "$rc" = "0"
chk "..CONTEXT falls back to (none)"    has "CONTEXT: (none)" "$out"
oos_body="$(printf '%s\n' "$out" | awk '/^## Out of scope/{f=1; next} /^## Steps/{f=0} f && NF')"
chk "..Out of scope body falls back to (none)" test "$oos_body" = "(none)"

echo "== H. Usage errors: bad/missing arguments =="
out="$(ps brief)"; rc=$?
chk "no slug → exit 1"                  test "$rc" = "1"
out="$(ps brief full-envelope extra-positional)"; rc=$?
chk "stray extra positional → exit 1"   test "$rc" = "1"
chk "..names the bad argument"          has "unexpected argument" "$out"
out="$(ps brief full-envelope --step abc)"; rc=$?
chk "--step non-numeric → exit 1"       test "$rc" = "1"
chk "..names the bad value"             has "must be a positive integer" "$out"
out="$(ps brief full-envelope --step 0)"; rc=$?
chk "--step 0 → exit 1 (usage error, not a valid step)" test "$rc" = "1"

echo "== I. brief never writes: no sidecar, no plan.md mutation =="
before_sum="$(cksum "$PLANS/full-envelope/plan.md")"
ps brief full-envelope >/dev/null
ps brief full-envelope --step 1 >/dev/null
after_sum="$(cksum "$PLANS/full-envelope/plan.md")"
chk "brief never mutates plan.md"       test "$before_sum" = "$after_sum"
chk "brief never writes a sidecar"      test ! -f "$PLANS/full-envelope/.state.json"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
