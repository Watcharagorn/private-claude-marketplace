#!/usr/bin/env bash
# test-instant.sh — regression tests for `plan-state.sh instant` (v2.37.0).
#
# Contract under test (the full ladder lives in plan-state.sh's `instant` doc block):
#   • ONE bare token on stdout line 1 — GO|DEFER|ASK|HOLD|DONE|NO_STEPS|UNRESOLVED —
#     identical with and without --verbose. Exit 0 for the six real tokens, 2 for
#     UNRESOLVED (the check could not run), 1 for usage errors (unknown slug, missing
#     plan.md, bad/out-of-range <step-n>, stray positional, unknown flag — <step-n>
#     is POSITIONAL, `--step` is rejected).
#   • READ-ONLY, stricter than `brief`: never ticks, never writes a sidecar, never
#     touches a marker, never writes instant-run-*.md (that is the loop's artifact).
#   • Gate ladder: own/legacy marker live OR STALE → HOLD (a stale marker still feeds
#     approve-plan.sh's `find -newer` promotion sweep — the WORSE case); a sibling
#     worktree's live marker alone must NOT stop (gate=ARMED_ELSEWHERE proceeds).
#   • The grant reads the STORED sidecar state, never the effective one — ticking the
#     last step must not make the grant unsatisfiable (DONE with stored=approved AND
#     effective=implemented in the same --verbose output).
#   • Step facts: phantom step lines (wrapped prose starting `48, ` / `7) `) never
#     count toward total; `### ` glue lands in body_glue_from; outward actions match
#     two-tiered with LINE-scoped negation; the four Done-when ambiguity facts
#     (inverted / ellipsis / unclosed span / slash-only) each → ASK; a forward ref
#     → DEFER, and it EXCUSES the unticked predecessor for the later step
#     (prev_deferred, not HOLD).
#
# Pass A always runs, on distilled heredoc fixtures in a scratch repo. Pass B
# re-asserts stable facts against the real plans under the repo's gitignored
# .mentor/plans/ and SKIPS (never FAILs) when a fixture is absent. §N re-runs three
# load-bearing assertions against deliberately mutated COPIES of the hooks dir to
# prove the guards bite.
#
# Runs against a SANDBOX $HOME and a throwaway git repo so it never touches real
# user/repo state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
PLANSTATE="$HOOKS/plan-state.sh"
[ -f "$PLANSTATE" ] || { echo "FATAL: not found: $PLANSTATE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }
# shellcheck source=../lib/state.sh
. "$HOOKS/lib/state.sh"   # for mentor_worktree_id (marker suffix) + mentor_repo_root (Pass B)

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX/.claude/projects/proj"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
BARE="$ROOT/bare-repo"          # a repo that has never planned (no plans dir)
git init -q -b main "$BARE" >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

# A PATH with real `git`/`dirname` but NO jq — only those two externals run before
# instant's own jq guard (mentor_repo_root → git/dirname; the rest is builtins).
BASH_BIN="$(command -v bash)"
NOJQ_DIR="$ROOT/nojq"; mkdir -p "$NOJQ_DIR"
ln -s "$(command -v git)" "$NOJQ_DIR/git"
ln -s "$(command -v dirname)" "$NOJQ_DIR/dirname"

trap 'rm -rf "$ROOT"' EXIT

PLANS="$REPO/.mentor/plans"
mkdir -p "$PLANS"

# Marker paths — suffix derived with the exact production recipe (mentor_worktree_id)
# so the own-marker filename can never drift from what begin-plan.sh writes.
WT_ID="$(mentor_worktree_id "$REPO")"
[ -n "$WT_ID" ] || { echo "FATAL: could not derive a worktree id for the fixture repo" >&2; exit 1; }
OWN_MARKER="$PLANS/.planning.${WT_ID}"
LEGACY_MARKER="$PLANS/.planning"
SIB_MARKER="$PLANS/.planning.other-1234567890"
STALE_TS="202601011200"   # months older than MENTOR_PLAN_MARKER_STALE_MIN (480 min)

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
has()  { printf '%s' "$2" | grep -q -- "$1"; }
hasnt(){ ! printf '%s' "$2" | grep -q -- "$1"; }

# All runners pin HOME + CLAUDE_CONFIG_DIR into the sandbox and drop the context env
# overrides, so a developer's own shell can never change an assertion.
_env() { env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
              -u CLAUDE_CODE_SESSION_ID HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" "$@"; }
ps()    { ( cd "${CWD:-$REPO}" && _env bash "$PLANSTATE" "$@" 2>&1 ); }          # merged
psout() { ( cd "${CWD:-$REPO}" && _env bash "$PLANSTATE" "$@" 2>/dev/null ); }   # stdout only
psrc()  { ( cd "${CWD:-$REPO}" && _env bash "$PLANSTATE" "$@" >/dev/null 2>&1 ); } # rc only

# fld <verbose-output> <key> — the value of the first `key=value` line.
fld() { printf '%s\n' "$1" | sed -n "s/^${2}=//p" | head -1; }
# line1 <output> — the bare token line.
line1() { printf '%s\n' "$1" | head -1; }

plan() { # <slug> <plan.md content via stdin>
  local slug="$1"
  mkdir -p "$PLANS/$slug"
  cat > "$PLANS/$slug/plan.md"
}
sc() { # <slug> <raw sidecar JSON> — written directly, NOT via `set` (which validates transitions)
  printf '%s\n' "$2" > "$PLANS/$1/.state.json"
}

# ---------------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------------
plan go-plan <<'MD'
# Go Plan

## Context

A clean plan for the happy path: one tick down, two clear steps to go.

## Implementation steps

1. **First step** ✅
   - Goal: do the first thing.
   - Done when: the fixture file exists.

2. **Second step**
   - Goal: do the second thing.
   - Done when: the counter reads three.

3. **Third step**
   - Goal: wrap up.
   - Done when: docs updated and reviewed.
MD
sc go-plan '{"state":"approved"}'

plan grant-done <<'MD'
# Grant Done Plan

## Implementation steps

1. **First** ✅
   - Goal: a.
   - Done when: a done.

2. **Second** ✅
   - Goal: b.
   - Done when: b done.
MD
sc grant-done '{"state":"approved"}'

echo "== A. Token/exit contract: one bare token on line 1, positional step arity =="
out="$(psout instant go-plan)"; rc=$?
chk "GO fixture → exit 0"                          test "$rc" = "0"
chk "..bare output is exactly the token"           test "$out" = "GO"
chk "..bare output is ONE line"                    test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1"
vout="$(psout instant go-plan --verbose)"
chk "..--verbose line 1 identical to bare token"   test "$(line1 "$vout")" = "GO"
chk "..--verbose reason=next-step"                 test "$(fld "$vout" reason)" = "next-step"
chk "..--verbose next_step=2"                      test "$(fld "$vout" next_step)" = "2"
chk "..--verbose ticked=1 total=3"                 test "$(fld "$vout" ticked)/$(fld "$vout" total)" = "1/3"
sout="$(psout instant go-plan 2)"
svout="$(psout instant go-plan 2 --verbose)"
chk "step arity: bare token = verbose line 1"      test "$sout" = "$(line1 "$svout")"

CWD="$NONGIT"
out="$(psout instant some-slug)"; psrc instant some-slug; rc=$?
chk "non-git dir → UNRESOLVED"                     test "$out" = "UNRESOLVED"
chk "non-git dir → exit 2"                         test "$rc" = "2"
vout="$(psout instant some-slug --verbose)"
chk "..--verbose adds reason=no-repo (and only that)" test "$vout" = "UNRESOLVED
reason=no-repo"
CWD="$BARE"
vout="$(psout instant some-slug --verbose)"; psrc instant some-slug; rc=$?
chk "repo without a plans dir → UNRESOLVED reason=no-plans-dir" \
  test "$(line1 "$vout")/$(fld "$vout" reason)" = "UNRESOLVED/no-plans-dir"
chk "..exit 2"                                     test "$rc" = "2"
CWD="$REPO"

nojq_out="$( cd "$REPO" && _env PATH="$NOJQ_DIR" "$BASH_BIN" "$PLANSTATE" instant go-plan --verbose 2>/dev/null )"
( cd "$REPO" && _env PATH="$NOJQ_DIR" "$BASH_BIN" "$PLANSTATE" instant go-plan >/dev/null 2>&1 ); rc=$?
chk "PATH without jq → UNRESOLVED reason=no-jq" \
  test "$(line1 "$nojq_out")/$(fld "$nojq_out" reason)" = "UNRESOLVED/no-jq"
chk "..exit 2"                                     test "$rc" = "2"

out="$(ps instant no-such-slug)"; rc=$?
chk "unknown slug → exit 1"                        test "$rc" = "1"
chk "..names the missing plan dir"                 has "No such plan" "$out"
mkdir -p "$PLANS/no-plan-md"
out="$(ps instant no-plan-md)"; rc=$?
chk "missing plan.md → exit 1"                     test "$rc" = "1"
chk "..names the missing file"                     has "no plan.md at" "$out"
out="$(ps instant)"; rc=$?
chk "missing slug → exit 1"                        test "$rc" = "1"
out="$(ps instant go-plan --step 2)"; rc=$?
chk "--step is NOT a flag → exit 1"                test "$rc" = "1"
chk "..rejected as an unknown flag"                has "unknown flag" "$out"
out="$(ps instant go-plan abc)"; rc=$?
chk "non-integer <step-n> → exit 1"                test "$rc" = "1"
chk "..names the bad value"                        has "must be a positive integer" "$out"
out="$(ps instant go-plan 0)"; rc=$?
chk "<step-n> 0 → exit 1"                          test "$rc" = "1"
out="$(ps instant go-plan 99)"; rc=$?
chk "out-of-range <step-n> → exit 1"               test "$rc" = "1"
chk "..says out of range"                          has "out of range" "$out"
out="$(ps instant go-plan 2 3)"; rc=$?
chk "extra positional → exit 1"                    test "$rc" = "1"
chk "..names the stray argument"                   has "unexpected argument" "$out"

echo "== C. Gate ladder: own/legacy stop (live AND stale), sibling does not =="
plan gate-plan <<'MD'
# Gate Plan

## Implementation steps

1. **Only step**
   - Goal: exists to be gated.
   - Done when: gated no more.
MD
sc gate-plan '{"state":"approved"}'

touch "$OWN_MARKER"
out="$(psout instant gate-plan --verbose)"; psrc instant gate-plan; rc=$?
chk "own live marker → HOLD"                       test "$(line1 "$out")" = "HOLD"
chk "..reason=gate-armed gate=ARMED"               test "$(fld "$out" reason)/$(fld "$out" gate)" = "gate-armed/ARMED"
chk "..HOLD is a real token → exit 0"              test "$rc" = "0"
touch -t "$STALE_TS" "$OWN_MARKER"
out="$(psout instant gate-plan --verbose)"
# LOAD-BEARING: a stale own marker still feeds approve-plan.sh's find -newer sweep.
chk "own STALE marker → HOLD (LOAD-BEARING)"       test "$(line1 "$out")" = "HOLD"
chk "..reason=gate-stale gate=STALE (LOAD-BEARING)" test "$(fld "$out" reason)/$(fld "$out" gate)" = "gate-stale/STALE"
rm -f "$OWN_MARKER"
touch "$LEGACY_MARKER"
out="$(psout instant gate-plan --verbose)"
chk "legacy .planning live → HOLD gate-armed"      test "$(line1 "$out")/$(fld "$out" reason)" = "HOLD/gate-armed"
touch -t "$STALE_TS" "$LEGACY_MARKER"
out="$(psout instant gate-plan --verbose)"
chk "legacy .planning stale → HOLD gate-stale"     test "$(line1 "$out")/$(fld "$out" reason)" = "HOLD/gate-stale"
rm -f "$LEGACY_MARKER"
touch "$SIB_MARKER"
out="$(psout instant gate-plan --verbose)"
# LOAD-BEARING: a sibling worktree's marker must NOT stop this loop.
chk "sibling marker only → GO (LOAD-BEARING: must NOT stop)" test "$(line1 "$out")" = "GO"
chk "..gate=ARMED_ELSEWHERE (LOAD-BEARING)"        test "$(fld "$out" gate)" = "ARMED_ELSEWHERE"
chk "..proceeds on the normal reason"              test "$(fld "$out" reason)" = "next-step"
touch -t "$STALE_TS" "$SIB_MARKER"
out="$(psout instant gate-plan --verbose)"
chk "sibling marker stale → gate=RELEASED"         test "$(fld "$out" gate)" = "RELEASED"
rm -f "$SIB_MARKER"
out="$(psout instant gate-plan --verbose)"
chk "no markers → GO gate=RELEASED"                test "$(line1 "$out")/$(fld "$out" gate)" = "GO/RELEASED"

echo "== D. Swept-in approval: only the USER can bless it =="
plan swept-plan <<'MD'
# Swept Plan

## Implementation steps

1. **Only step**
   - Goal: exists.
   - Done when: done.
MD
sc swept-plan '{"state":"approved","note":"approved as part of plan approval — swept in by approve-plan.sh; not necessarily reviewed"}'
out="$(psout instant swept-plan --verbose)"
chk "swept-in note → ASK"                          test "$(line1 "$out")" = "ASK"
chk "..reason=swept-in note_swept=1"               test "$(fld "$out" reason)/$(fld "$out" note_swept)" = "swept-in/1"
sc swept-plan '{"state":"approved","note":"hand approved after review"}'
out="$(psout instant swept-plan --verbose)"
chk "ordinary note → GO"                           test "$(line1 "$out")" = "GO"
chk "..note_swept=0"                               test "$(fld "$out" note_swept)" = "0"

echo "== E. The grant reads the STORED state, never the effective one =="
out="$(psout instant grant-done --verbose)"
chk "approved + all ticked → DONE"                 test "$(line1 "$out")" = "DONE"
# LOAD-BEARING: stored and effective must BOTH appear, and disagree exactly this way —
# a grant keyed on the effective state would be unsatisfiable at this very moment.
chk "..stored=approved survives the last tick (LOAD-BEARING)"    test "$(fld "$out" stored)" = "approved"
chk "..effective=implemented reported, never decisive (LOAD-BEARING)" test "$(fld "$out" effective)" = "implemented"
chk "..reason=all-ticked"                          test "$(fld "$out" reason)" = "all-ticked"
sc grant-done '{"state":"in_progress"}'
out="$(psout instant grant-done --verbose)"
chk "in_progress + all ticked → DONE"              test "$(line1 "$out")" = "DONE"
sc grant-done '{"state":"implemented"}'
out="$(psout instant grant-done --verbose)"
chk "implemented + all ticked → DONE reason=closed" test "$(line1 "$out")/$(fld "$out" reason)" = "DONE/closed"
sc grant-done '{"state":"superseded"}'
out="$(psout instant grant-done --verbose)"
chk "superseded → HOLD"                            test "$(line1 "$out")/$(fld "$out" reason)" = "HOLD/superseded"
sc grant-done '{"state":"approved"}'   # restore for §B/§N

plan grant-open <<'MD'
# Grant Open Plan

## Implementation steps

1. **First** ✅
   - Goal: a.
   - Done when: a done.

2. **Second**
   - Goal: b.
   - Done when: b done.
MD
sc grant-open '{"state":"implemented"}'
out="$(psout instant grant-open --verbose)"
chk "implemented with ticks open → ASK"            test "$(line1 "$out")" = "ASK"
chk "..reason=stored-implemented-ticks-open"       test "$(fld "$out" reason)" = "stored-implemented-ticks-open"
sc grant-open '{"state":"draft"}'
out="$(psout instant grant-open --verbose)"
chk "stored draft → ASK reason=draft"              test "$(line1 "$out")/$(fld "$out" reason)" = "ASK/draft"
sc grant-open '{"state":"failed"}'
out="$(psout instant grant-open --verbose)"
chk "stored failed → ASK reason=failed"            test "$(line1 "$out")/$(fld "$out" reason)" = "ASK/failed"
rm -f "$PLANS/grant-open/.state.json"
out="$(psout instant grant-open --verbose)"
chk "no sidecar → ASK reason=no-grant-on-record"   test "$(line1 "$out")/$(fld "$out" reason)" = "ASK/no-grant-on-record"
chk "..stored=- when nothing is on record"         test "$(fld "$out" stored)" = "-"

echo "== F. Phantom-step regression: wrapped prose lines never count as steps =="
plan phantom <<'MD'
# Phantom Plan

## Context

Wrapped prose lines that merely BEGIN with a number must not read as steps.

## Implementation steps

1. **Real first step**
   - Goal: touch the lines named in Inputs.
   - Inputs: the hook file at lines 12, 33,
     48, 55, 61 and nothing else.
   - Done when: the edit lands.

2. **Real second step**
   - Goal: keep an enumerated aside intact, wrapped by hand like
     7) something a careful writer numbered mid-paragraph.
   - Done when: the aside is preserved.
MD
sc phantom '{"state":"approved"}'
out="$(psout instant phantom --verbose)"
# LOAD-BEARING: the `48, …` continuation and the `7) …` prose line are NOT steps.
chk "phantom lines excluded: total=2 (LOAD-BEARING)" test "$(fld "$out" total)" = "2"
chk "..next_step=1"                                test "$(fld "$out" next_step)" = "1"
chk "..plan arity → GO"                            test "$(line1 "$out")" = "GO"

echo "== G. Body glue + outward actions with line-scoped negation =="
plan outward <<'MD'
# Outward Plan

## Context

A release-shaped step whose body glues a col-0 ### heading.

## Implementation steps

1. **Prepare the change** ✅
   - Goal: stage the edits.
   - Done when: the diff is reviewed.

2. **Cut the release**
   - Goal: hand the release to the loom flow.

### Release

   Ship via the loom publish-plugin flow once checks pass.
   Guardrails: never `git push` by hand, no hand-rolled `gh pr create`, never `mentor:ship`.
   - Done when: the release lands.
MD
sc outward '{"state":"approved"}'
ship_ln="$(grep -n 'loom publish-plugin flow' "$PLANS/outward/plan.md" | cut -d: -f1)"
guard_ln="$(grep -n 'Guardrails:' "$PLANS/outward/plan.md" | cut -d: -f1)"
glue_ln="$(grep -n '^### Release' "$PLANS/outward/plan.md" | cut -d: -f1)"
out="$(psout instant outward 2 --verbose)"
chk "live outward mention → ASK"                   test "$(line1 "$out")" = "ASK"
chk "..reason=outward-action"                      test "$(fld "$out" reason)" = "outward-action"
chk "..outward names publish-plugin@line"          test "$(fld "$out" outward)" = "publish-plugin@${ship_ln}"
chk "..negated line lands in outward_negated, in order" \
  test "$(fld "$out" outward_negated)" = "git-push@${guard_ln},gh-pr-create@${guard_ln},mentor:ship@${guard_ln}"
chk "..body_glue_from names the ### line"          test "$(fld "$out" body_glue_from)" = "$glue_ln"
out="$(psout instant outward 1 --verbose)"
chk "previous step without outward mentions → outward=-" test "$(fld "$out" outward)" = "-"
chk "..outward_negated=- too"                      test "$(fld "$out" outward_negated)" = "-"

echo "== H. Done-when ambiguity facts: inverted criterion stops, FAIL=0 does not =="
plan inv-bad <<'MD'
# Inverted Plan

## Implementation steps

1. **Write the failing test**
   - Goal: prove the bug first.
   - Done when: the suite runs and **FAILS** against current HEAD.
MD
sc inv-bad '{"state":"approved"}'
out="$(psout instant inv-bad 1 --verbose)"
chk "inverted criterion → ASK"                     test "$(line1 "$out")" = "ASK"
chk "..reason=done-when-ambiguous dw_inverted=1"   test "$(fld "$out" reason)/$(fld "$out" dw_inverted)" = "done-when-ambiguous/1"

plan inv-ok <<'MD'
# Result Line Plan

## Implementation steps

1. **Run the suite to green**
   - Goal: make it pass.
   - Done when: the run prints `RESULT: PASS=12 FAIL=0`.
MD
sc inv-ok '{"state":"approved"}'
out="$(psout instant inv-ok 1 --verbose)"
# LOAD-BEARING false-positive guard: `RESULT … FAIL=0` is a normal green criterion.
chk "RESULT…FAIL=0 criterion → dw_inverted=0 (LOAD-BEARING)" test "$(fld "$out" dw_inverted)" = "0"
chk "..and it runs: GO reason=clear (LOAD-BEARING)" test "$(line1 "$out")/$(fld "$out" reason)" = "GO/clear"

plan amb-ellipsis <<'MD'
# Ellipsis Plan

## Implementation steps

1. **Query the rows**
   - Goal: read them back.
   - Done when: `plan-state.sh query …` returns the new row.
MD
sc amb-ellipsis '{"state":"approved"}'
out="$(psout instant amb-ellipsis 1 --verbose)"
chk "ellipsis inside a code span → ASK dw_ellipsis=1" \
  test "$(line1 "$out")/$(fld "$out" dw_ellipsis)" = "ASK/1"

plan amb-unclosed <<'MD'
# Unclosed Span Plan

## Implementation steps

1. **Grow the helper**
   - Goal: add it.
   - Done when: the file `lib/state.sh gains the helper.
MD
sc amb-unclosed '{"state":"approved"}'
out="$(psout instant amb-unclosed 1 --verbose)"
chk "unclosed code span → ASK dw_unclosed_span=1" \
  test "$(line1 "$out")/$(fld "$out" dw_unclosed_span)" = "ASK/1"

plan amb-slash <<'MD'
# Slash Only Plan

## Implementation steps

1. **Verify via the skill**
   - Goal: run the check.
   - Done when: `/mentor:verify` passes.
MD
sc amb-slash '{"state":"approved"}'
out="$(psout instant amb-slash 1 --verbose)"
chk "slash-command-only criterion → ASK dw_slash_only=1" \
  test "$(line1 "$out")/$(fld "$out" dw_slash_only)" = "ASK/1"

echo "== I. Forward refs: DEFER on the step, and the ordering excuse for the next =="
plan fwd <<'MD'
# Forward Ref Plan

## Implementation steps

1. **Groundwork** ✅
   - Goal: set up.
   - Done when: setup done.

2. **Write the review pass**
   - Goal: review everything.
   - Done when: zero unaddressed HIGH findings after Step 3.

3. **Address findings**
   - Goal: fix what the review found.
   - Done when: every finding is addressed.
MD
sc fwd '{"state":"approved"}'
out="$(psout instant fwd 2 --verbose)"
chk "forward-referencing Done when → DEFER"        test "$(line1 "$out")" = "DEFER"
chk "..reason=forward-ref"                         test "$(fld "$out" reason)" = "forward-ref"
chk "..dw_forward_refs=3 defer_until=3"            test "$(fld "$out" dw_forward_refs)/$(fld "$out" defer_until)" = "3/3"
out="$(psout instant fwd 3 --verbose)"
# LOAD-BEARING: the deferred predecessor EXCUSES the ordering hold — without this,
# steps 2 and 3 deadlock (plan-tour's step 6 vs 7).
chk "next step runs anyway → GO, not HOLD (LOAD-BEARING)" test "$(line1 "$out")" = "GO"
chk "..prev_deferred=2 (LOAD-BEARING)"             test "$(fld "$out" prev_deferred)" = "2"
chk "..prev_unticked=-"                            test "$(fld "$out" prev_unticked)" = "-"

plan ord <<'MD'
# Ordering Plan

## Implementation steps

1. **Groundwork** ✅
   - Goal: set up.
   - Done when: setup done.

2. **Middle step**
   - Goal: no forward reference here.
   - Done when: the middle work lands.

3. **Late step**
   - Goal: depends on step 2.
   - Done when: the late work lands.
MD
sc ord '{"state":"approved"}'
out="$(psout instant ord 3 --verbose)"
chk "unticked predecessor with NO forward ref → HOLD" test "$(line1 "$out")" = "HOLD"
chk "..reason=ordering prev_unticked=2"            test "$(fld "$out" reason)/$(fld "$out" prev_unticked)" = "ordering/2"
out="$(psout instant ord 1 --verbose)"
chk "already-ticked step → DONE reason=step-ticked" test "$(line1 "$out")/$(fld "$out" reason)" = "DONE/step-ticked"

echo "== K. NO_STEPS: a stub is not a failure =="
plan stub <<'MD'
# Stub Plan

## Goal

Capture the idea for later.
MD
sc stub '{"state":"approved"}'
out="$(psout instant stub --verbose)"
chk "step-less plan → NO_STEPS"                    test "$(line1 "$out")" = "NO_STEPS"
chk "..reason=stub total=0"                        test "$(fld "$out" reason)/$(fld "$out" total)" = "stub/0"
chk "..next_step=-"                                test "$(fld "$out" next_step)" = "-"
sc stub '{"state":"approved","origin":"deferred"}'
out="$(psout instant stub --verbose)"
chk "origin=deferred stub → reason=deferred-stub"  test "$(fld "$out" reason)" = "deferred-stub"
out="$(ps instant stub 1)"; rc=$?
chk "step arity on a stub → exit 1 (out of range)" test "$rc" = "1"

echo "== L. Context fold: ASK stops, WARN/HANDOFF/off do not =="
plan ctx-plan <<'MD'
# Context Plan

## Implementation steps

1. **Only step**
   - Goal: exists.
   - Done when: done.
MD
sc ctx-plan '{"state":"approved"}'
TXDIR="$SANDBOX/.claude/projects/proj"
printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":59990,"cache_creation_input_tokens":0}}}' > "$TXDIR/sess.jsonl"
ctx_ps() { # <extra env assignments…> — instant ctx-plan --verbose with a fake transcript wired in
  ( cd "$REPO" && env HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" CLAUDE_CODE_SESSION_ID=sess \
      "$@" bash "$PLANSTATE" instant ctx-plan --verbose 2>/dev/null );
}
out="$(ctx_ps MENTOR_CONTEXT_BLOCK_TOKENS=50000 MENTOR_CONTEXT_WARN_TOKENS=40000 MENTOR_CONTEXT_GATE=on)"
chk "context over the ask threshold → ASK"         test "$(line1 "$out")" = "ASK"
chk "..reason=context context=ASK"                 test "$(fld "$out" reason)/$(fld "$out" context)" = "context/ASK"
out="$(ctx_ps MENTOR_CONTEXT_BLOCK_TOKENS=70000 MENTOR_CONTEXT_WARN_TOKENS=40000 MENTOR_CONTEXT_GATE=on)"
chk "WARN tier does not stop → GO context=WARN"    test "$(line1 "$out")/$(fld "$out" context)" = "GO/WARN"
: > "$REPO/.mentor/.context-bypass-sess"
out="$(ctx_ps MENTOR_CONTEXT_BLOCK_TOKENS=50000 MENTOR_CONTEXT_WARN_TOKENS=40000 MENTOR_CONTEXT_GATE=on)"
chk "user already bypassed → GO context=HANDOFF (never stricter than the gate)" \
  test "$(line1 "$out")/$(fld "$out" context)" = "GO/HANDOFF"
rm -f "$REPO/.mentor/.context-bypass-sess"
out="$(ctx_ps MENTOR_CONTEXT_BLOCK_TOKENS=50000 MENTOR_CONTEXT_WARN_TOKENS=40000 MENTOR_CONTEXT_GATE=off)"
chk "kill switch → GO context=UNKNOWN"             test "$(line1 "$out")/$(fld "$out" context)" = "GO/UNKNOWN"
rm -f "$TXDIR/sess.jsonl"

echo "== M. Structure: a step without Done when, and unbalanced fences, both HOLD =="
plan struct-nodw <<'MD'
# No Done-when Plan

## Implementation steps

1. **Has one**
   - Goal: fine.
   - Done when: done.

2. **Missing its Done when**
   - Goal: not fine.
MD
sc struct-nodw '{"state":"approved"}'
nodw_ln="$(grep -n 'Missing its Done when' "$PLANS/struct-nodw/plan.md" | cut -d: -f1)"
out="$(psout instant struct-nodw --verbose)"
chk "step without Done when → HOLD"                test "$(line1 "$out")" = "HOLD"
chk "..reason=structure structure=FAIL:nodw@line"  test "$(fld "$out" reason)/$(fld "$out" structure)" = "structure/FAIL:nodw@${nodw_ln}"

plan struct-fence <<'MD'
# Fence Plan

## Context

An unclosed fence below:

```text
this fence is never closed

## Implementation steps

1. **Only step**
   - Goal: fine.
   - Done when: done.
MD
sc struct-fence '{"state":"approved"}'
out="$(psout instant struct-fence --verbose)"
chk "odd fence count → HOLD structure=FAIL:fences" test "$(line1 "$out")/$(fld "$out" structure)" = "HOLD/FAIL:fences"

echo "== B. Read-only guarantee: ~10 mixed calls leave no trace =="
ro_before="$(cksum "$PLANS/go-plan/plan.md" "$PLANS/go-plan/.state.json" \
                   "$PLANS/fwd/plan.md" "$PLANS/fwd/.state.json" \
                   "$PLANS/outward/plan.md" "$PLANS/grant-done/.state.json" 2>/dev/null)"
markers_before="$(find "$PLANS" -maxdepth 1 -name '.planning*' 2>/dev/null | sort)"
psrc instant go-plan
psrc instant go-plan --verbose
psrc instant go-plan 2
psrc instant go-plan 2 --verbose
psrc instant fwd 2 --verbose
psrc instant fwd 3 --verbose
psrc instant outward 2 --verbose
psrc instant grant-done --verbose
psrc instant stub --verbose
psrc instant no-such-slug
psrc instant go-plan 99
ro_after="$(cksum "$PLANS/go-plan/plan.md" "$PLANS/go-plan/.state.json" \
                  "$PLANS/fwd/plan.md" "$PLANS/fwd/.state.json" \
                  "$PLANS/outward/plan.md" "$PLANS/grant-done/.state.json" 2>/dev/null)"
markers_after="$(find "$PLANS" -maxdepth 1 -name '.planning*' 2>/dev/null | sort)"
chk "plan.md + sidecars byte-identical after mixed calls" test "$ro_before" = "$ro_after"
chk "no instant-run-*.md created anywhere"         test -z "$(find "$PLANS" -name 'instant-run-*.md' 2>/dev/null)"
chk "no .planning* marker created or removed"      test "$markers_before" = "$markers_after"
chk "no ticks appeared in go-plan"                 test "$(grep -c '✅' "$PLANS/go-plan/plan.md" | tr -d ' ')" = "1"

echo "== N. Mutation bites: each guard fails against a broken copy =="
mkmut() { # <name> — fresh copy of plan-state.sh + lib/ under $ROOT; echoes the dir
  local m
  m="$(mktemp -d "$ROOT/${1}.XXXXXX")"
  mkdir -p "$m/lib"
  cp "$HOOKS/plan-state.sh" "$m/plan-state.sh"
  cp -R "$HOOKS/lib/." "$m/lib/"
  echo "$m"
}

# (1) STALE falls through to RELEASED — §C's stale HOLD must flip to GO.
M1="$(mkmut mut1)"
sed 's/in_gate=STALE/: # mutated: stale falls through/' "$HOOKS/plan-state.sh" > "$M1/plan-state.sh"
touch "$OWN_MARKER"; touch -t "$STALE_TS" "$OWN_MARKER"
ctl="$(psout instant gate-plan)"
m1_out="$( cd "$REPO" && _env bash "$M1/plan-state.sh" instant gate-plan --verbose 2>/dev/null )"
chk "mut1 control: pristine script still HOLDs on the stale marker" test "$ctl" = "HOLD"
chk "mut1: stale→RELEASED mutation flips §C's HOLD to GO (guard bites)" test "$(line1 "$m1_out")" = "GO"
chk "..mutated gate reads RELEASED"                test "$(fld "$m1_out" gate)" = "RELEASED"
rm -f "$OWN_MARKER"

# (2) Grant keyed on the EFFECTIVE state — §E's stored=approved must vanish.
M2="$(mkmut mut2)"
sed 's/in_stored="$(mentor_plan_state_stored/in_stored="$(mentor_plan_effective_state/' \
  "$HOOKS/plan-state.sh" > "$M2/plan-state.sh"
m2_out="$( cd "$REPO" && _env bash "$M2/plan-state.sh" instant grant-done --verbose 2>/dev/null )"
chk "mut2: effective-keyed grant loses stored=approved (guard bites)" \
  test "$(fld "$m2_out" stored)" = "implemented"
chk "..reason flips from all-ticked to closed"     test "$(fld "$m2_out" reason)" = "closed"

# (3) The pre-v2.36.0 step pattern (`)*\.(`) — §F's total must inflate.
M3="$(mkmut mut3)"
sed 's/)\*\[\.\](/)*\\.(/' "$HOOKS/lib/state.sh" > "$M3/lib/state.sh"
m3_out="$( cd "$REPO" && _env bash "$M3/plan-state.sh" instant phantom --verbose 2>/dev/null )"
chk "mut3: reverted step pattern re-inflates the phantom total (guard bites)" \
  test "$(fld "$m3_out" total)" -gt 2

echo "== Pass B. Opportunistic conformance against the real (gitignored) plans =="
REAL_ROOT="$(mentor_repo_root "$SCRIPT_DIR")"
REAL_PLANS="${REAL_ROOT:+$REAL_ROOT/.mentor/plans}"
realize() { # <slug> — copy the REAL plan.md (never its sidecar) into scratch as r-<slug>
  local slug="$1" src="${REAL_PLANS:-/nonexistent}/$1/plan.md"
  [ -f "$src" ] || return 1
  mkdir -p "$PLANS/r-$slug"
  cp "$src" "$PLANS/r-$slug/plan.md"
  printf '%s\n' '{"state":"approved"}' > "$PLANS/r-$slug/.state.json"
  return 0
}

if realize fix-plans-under-root; then
  out="$(psout instant r-fix-plans-under-root 7 --verbose)"
  chk "fix-plans-under-root: total=7"              test "$(fld "$out" total)" = "7"
  chk "..step 7 header_line=301"                   test "$(fld "$out" header_line)" = "301"
else echo "  skip fix-plans-under-root (fixture absent)"; fi

if realize worktree-scoped-plan-gate; then
  out="$(psout instant r-worktree-scoped-plan-gate 12 --verbose)"
  chk "worktree-scoped-plan-gate: step 12 body_glue_from=578" test "$(fld "$out" body_glue_from)" = "578"
  chk "..outward=publish-plugin@586"               has "^outward=publish-plugin@586" "$out"
  chk "..outward_negated carries mentor:ship@585"  has "mentor:ship@585" "$(fld "$out" outward_negated)"
  chk "..outward_negated carries git-push@585"     has "git-push@585" "$(fld "$out" outward_negated)"
  chk "..outward_negated carries gh-pr-create@585" has "gh-pr-create@585" "$(fld "$out" outward_negated)"
  out="$(psout instant r-worktree-scoped-plan-gate 11 --verbose)"
  chk "..step 11 outward=-"                        test "$(fld "$out" outward)" = "-"
else echo "  skip worktree-scoped-plan-gate (fixture absent)"; fi

if realize plan-tour; then
  out="$(psout instant r-plan-tour 6 --verbose)"
  chk "plan-tour: step 6 dw_forward_refs=7"        test "$(fld "$out" dw_forward_refs)" = "7"
  chk "..step 6 defer_until=7"                     test "$(fld "$out" defer_until)" = "7"
  out="$(psout instant r-plan-tour 5 --verbose)"
  chk "..step 5 dw_forward_refs=-"                 test "$(fld "$out" dw_forward_refs)" = "-"
else echo "  skip plan-tour (fixture absent)"; fi

if realize dispatch-sweep-ugrep-flag; then
  out="$(psout instant r-dispatch-sweep-ugrep-flag --verbose)"
  chk "dispatch-sweep-ugrep-flag: total=6"         test "$(fld "$out" total)" = "6"
  out="$(psout instant r-dispatch-sweep-ugrep-flag 1 --verbose)"
  chk "..step 1 dw_inverted=1"                     test "$(fld "$out" dw_inverted)" = "1"
  out="$(psout instant r-dispatch-sweep-ugrep-flag 6 --verbose)"
  chk "..step 6 dw_inverted=0"                     test "$(fld "$out" dw_inverted)" = "0"
else echo "  skip dispatch-sweep-ugrep-flag (fixture absent)"; fi

if realize plan-defer-deps-tracking; then
  out="$(psout instant r-plan-defer-deps-tracking)"; rc=$?
  chk "plan-defer-deps-tracking: runs clean (exit 0)" test "$rc" = "0"
  case "$out" in GO|DEFER|ASK|HOLD|DONE|NO_STEPS) tok_ok=0 ;; *) tok_ok=1 ;; esac
  chk "..line 1 is one of the six real tokens"     test "$tok_ok" = "0"
else echo "  skip plan-defer-deps-tracking (fixture absent)"; fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
