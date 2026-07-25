#!/usr/bin/env bash
# test-plan-state.sh — regression tests for hooks/plan-state.sh (v2.4.0).
#
# Contract:
#   • EFFECTIVE state = the more advanced of the sidecar's state and the state
#     derived from plan.md's ✅ step ticks. No sidecar and no ticks → `unknown`,
#     NEVER `draft` — a plan that shipped months ago was not "never approved".
#   • `init` is idempotent and never LOWERS a state; `set` is an upsert, because
#     most plans predate the sidecar.
#   • Usage errors (unknown subcommand, invalid state, unknown slug) exit 1.
#     Everything environmental (no repo, no plans dir) is fail-soft: exit 0 with a
#     reason line on stderr — silent-empty is indistinguishable from "no plans", and
#     the calling skill would improvise a listing.
#   • `current` skips superseded plans and, inside a split group, reports the whole
#     group instead of silently picking whichever child agent finished last.
#
# Runs against a SANDBOX $HOME and CLAUDE_CONFIG_DIR so it never touches real user
# state and never finds a real session transcript.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
PLANSTATE="$HOOKS/plan-state.sh"
[ -f "$PLANSTATE" ] || { echo "FATAL: not found: $PLANSTATE" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX/.claude/projects/proj"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
BARE="$ROOT/bare-repo"          # a repo that has never planned
git init -q -b main "$BARE" >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

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

# All runners pin HOME + CLAUDE_CONFIG_DIR into the sandbox and drop the context
# env overrides, so a developer's own shell can never change an assertion.
_env() { env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
              -u CLAUDE_CODE_SESSION_ID HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" "$@"; }
ps()    { ( cd "${CWD:-$REPO}" && _env bash "$PLANSTATE" "$@" 2>&1 ); }          # merged
psout() { ( cd "${CWD:-$REPO}" && _env bash "$PLANSTATE" "$@" 2>/dev/null ); }   # stdout only
pserr() { ( cd "${CWD:-$REPO}" && _env bash "$PLANSTATE" "$@" 2>&1 >/dev/null ); } # stderr only

plan() { # <slug> [body line...]  — create a plan dir with a plan.md
  local slug="$1"; shift
  mkdir -p "$PLANS/$slug"
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$PLANS/$slug/plan.md"
  else printf '# %s\n' "$slug" > "$PLANS/$slug/plan.md"; fi
}
# `list` columns: $1 ordinal · $2 STATE · $3 PLAN · $4 GROUP · $5 ORDER
state_of() { psout list | awk -v s="$1" '$3 == s { print $2 }'; }
slugs_in_order() { printf '%s' "$1" | awk 'NF && $1 ~ /^[0-9]+$/ { printf "%s ", $3 }'; }

echo "== A. Usage errors exit 1; the marker of a real CLI, not a hook =="
out="$(ps)"; rc=$?
chk "no subcommand → exit 1"            test "$rc" = "1"
chk "no subcommand → usage printed"     has "Usage: plan-state.sh" "$out"
out="$(ps frobnicate)"; rc=$?
chk "unknown subcommand → exit 1"       test "$rc" = "1"
chk "unknown subcommand → names it"     has "Unknown subcommand: frobnicate" "$out"
plan solo
out="$(ps set solo bogus)"; rc=$?
chk "invalid state → exit 1"            test "$rc" = "1"
chk "invalid state → lists valid ones"  has "draft approved in_progress implemented failed superseded" "$out"
out="$(ps set nope approved)"; rc=$?
chk "set unknown slug → exit 1"         test "$rc" = "1"
chk "set unknown slug → points at list" has "plan-state.sh list" "$out"
out="$(ps init nope)"; rc=$?
chk "init unknown slug → exit 1"        test "$rc" = "1"
out="$(ps set)"; rc=$?
chk "set with no slug → exit 1"         test "$rc" = "1"

echo "== B. Effective state derives from the ✅ ticks, so a forgotten set costs nothing =="
plan no-sidecar
plan ticked-all   '# t' '## Implementation steps' '1. **One** ✅' '2. **Two** ✅' '## Verification' '1. unticked, not a step'
plan ticked-some  '# t' '## Implementation steps' '1. **One** ✅' '2. **Two**'
plan ticked-steps '# t' '## Implementation steps' 'Step 1 — one  [role: general-purpose] ✅' 'Step 2 — two  [role: general-purpose] ✅'
plan no-steps     '# t' '## Context' 'nothing to tick here'
chk "no sidecar, no ticks → unknown (never draft)" test "$(state_of no-sidecar)" = "unknown"
chk "every step ticked → implemented"              test "$(state_of ticked-all)" = "implemented"
chk "some steps ticked → in_progress"              test "$(state_of ticked-some)" = "in_progress"
chk "'Step N —' style ticks counted too"           test "$(state_of ticked-steps)" = "implemented"
chk "ticks outside Implementation steps ignored"   test "$(state_of no-steps)" = "unknown"
# The derivation must OUTRANK a stale sidecar, which is the whole point.
ps init ticked-all >/dev/null
chk "stale 'draft' sidecar loses to all-ticked"    test "$(state_of ticked-all)" = "implemented"
# …but never demote a terminal state.
ps set ticked-all superseded >/dev/null
chk "superseded outranks all-ticked"               test "$(state_of ticked-all)" = "superseded"
ps set ticked-some failed --note "typecheck" >/dev/null
chk "failed survives a tick-derived in_progress"   test "$(state_of ticked-some)" = "failed"

echo "== C. init is idempotent and never lowers a state =="
plan idem
ps init idem >/dev/null
chk "init → draft"                      test "$(state_of idem)" = "draft"
ps init idem >/dev/null
chk "init twice → still draft"          test "$(state_of idem)" = "draft"
ps set idem approved >/dev/null
ps init idem >/dev/null
chk "init on an approved plan keeps it" test "$(state_of idem)" = "approved"
ps init idem --group parent --order 4 >/dev/null
out="$(psout list)"
chk "init backfills group/order"        has "idem  *parent  *4" "$out"
ps set idem in_progress >/dev/null
out="$(psout list)"
chk "set preserves group/order"         has "idem  *parent  *4" "$out"

echo "== D. set upserts onto a sidecar-less plan (the majority path on upgrade) =="
plan upsert
chk "no sidecar to begin with"          test ! -f "$PLANS/upsert/.state.json"
out="$(ps set upsert approved)"; rc=$?
chk "set on sidecar-less plan → exit 0" test "$rc" = "0"
chk "set on sidecar-less plan → wrote"  test -f "$PLANS/upsert/.state.json"
chk "set on sidecar-less plan → state"  test "$(state_of upsert)" = "approved"
chk "set reports the transition"        has "unknown → approved" "$out"
# A corrupt sidecar must be repairable, not permanently unwritable.
printf 'not json at all' > "$PLANS/upsert/.state.json"
chk "corrupt sidecar reads unknown"     test "$(state_of upsert)" = "unknown"
ps set upsert approved >/dev/null
chk "corrupt sidecar is repaired"       test "$(state_of upsert)" = "approved"

echo "== E. The note is replaced every time, so a stale failure reason cannot linger =="
plan noted
ps set noted failed --note "typecheck failed in invoice.ts" >/dev/null
chk "note stored"     sh -c "grep -q 'typecheck failed in invoice.ts' '$PLANS/noted/.state.json'"
ps set noted in_progress >/dev/null
chk "plain set clears the note" sh -c "! grep -q 'typecheck failed' '$PLANS/noted/.state.json'"

echo "== F. list: grouped, ordered, terminal states last =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan parent; plan kid-a; plan kid-b; plan kid-c; plan standalone; plan ancient
ps init parent >/dev/null
ps init kid-a --group parent --order 1 >/dev/null
ps init kid-b --group parent --order 2 >/dev/null
ps init kid-c --group parent --order 3 >/dev/null
ps init standalone >/dev/null
ps set parent superseded >/dev/null
ps set kid-a implemented >/dev/null
ps set standalone approved >/dev/null
out="$(psout list)"
order="$(slugs_in_order "$out")"
chk "group ordered by 'order', terminals last" test "$order" = "kid-a kid-b kid-c standalone ancient parent "
chk "list prints PLANS_DIR"             has "PLANS_DIR: $PLANS" "$out"
chk "list explains 'unknown'"           has "pre-2.4.0" "$out"
out="$(psout list --group parent)"
sibs="$(slugs_in_order "$out")"
chk "--group filters to the group"      test "$sibs" = "kid-a kid-b kid-c "
chk "--group excludes the parent"       hasnt "superseded" "$out"
out="$(ps list --group)"; rc=$?
chk "bare trailing --group terminates"  test "$rc" = "0"

echo "== G. current: skips superseded, and never silently picks one of N children =="
# parent is the newest by mtime but superseded → must not be "current".
touch "$PLANS/parent/plan.md"
out="$(psout current)"
chk "current skips the superseded parent" hasnt "SLUG: parent" "$out"
# Standalone plan is the answer when it is the newest non-superseded one.
touch "$PLANS/standalone/plan.md"
out="$(psout current)"
chk "current → newest non-superseded"   has "SLUG: standalone" "$out"
chk "current → GROUP: -"                has "GROUP: -" "$out"
chk "current → absolute PLAN path"      has "PLAN: $PLANS/standalone/plan.md" "$out"
# Inside a group, current reports the group and warns off a blind pick.
touch "$PLANS/kid-c/plan.md"
out="$(psout current)"
chk "current in a group → GROUP set"    has "GROUP: parent" "$out"
chk "current in a group → warns"        has "do NOT assume it is the one the user means" "$out"
chk "current in a group → lists siblings" has "kid-b" "$out"
# …and the pick is deterministic: lowest order that is not already done (kid-a is
# implemented), NOT whichever child agent happened to write last.
chk "current in a group → lowest unfinished order" has "SLUG: kid-b" "$out"

echo "== G2. A destroyed sidecar must not drop a child out of its group =="
# Everything the sidecar holds is also in the child's isolation header, so a plan dir
# carrying nothing but plan.md still reads correctly. If this regresses, `current`
# starts handing back finished work.
rm -rf "$PLANS"; mkdir -p "$PLANS"
for i in 1 2 3; do
  mkdir -p "$PLANS/kid-$i"
  cat > "$PLANS/kid-$i/plan.md" <<MD
# Child $i

> [!NOTE]
> **Plan $i of 3** · group \`huge-thing\` · depends on \`kid-1\`
> **Owns:** src/thing-$i/**
> **Does NOT touch:** the rest → \`kid-2\`

## Implementation steps
1. **step**
MD
  ps init "kid-$i" --group huge-thing --order "$i" >/dev/null
  ps set "kid-$i" approved >/dev/null
done
# Finish kid-1, destroy its sidecar, and make it the newest file — the worst case.
printf '# Child 1\n\n> [!NOTE]\n> **Plan 1 of 3** · group `huge-thing`\n\n## Implementation steps\n1. **step** ✅\n' > "$PLANS/kid-1/plan.md"
rm -f "$PLANS/kid-1/.state.json"
sleep 1; touch "$PLANS/kid-1/plan.md"
out="$(psout list)"
chk "sidecar-less child keeps its group" has "kid-1  *huge-thing  *1" "$out"
chk "sidecar-less child keeps its state" test "$(state_of kid-1)" = "implemented"
out="$(psout current)"
chk "current skips the finished sibling" has "SLUG: kid-2" "$out"
chk "current still reports the group"    has "GROUP: huge-thing" "$out"

echo "== H. context: the backstop /mentor:track needs (context-gate.sh passes slash commands) =="
mktx() { python3 - "$1" "$2" <<'PY'
import json,sys
open(sys.argv[1],"w").write(json.dumps(
  {"type":"assistant","message":{"usage":{"input_tokens":10,
   "cache_read_input_tokens":int(sys.argv[2])-10,"cache_creation_input_tokens":0}}})+"\n")
PY
}
TXDIR="$SANDBOX/.claude/projects/proj"
out="$(ps context)"; rc=$?
chk "no transcript → exit 0"            test "$rc" = "0"
chk "no transcript → UNKNOWN, proceed"  has "CONTEXT: UNKNOWN" "$out"
ctx() { ( cd "$REPO" && env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
          HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" CLAUDE_CODE_SESSION_ID=sess \
          bash "$PLANSTATE" context 2>&1 ); }
mktx "$TXDIR/sess.jsonl" 400000
out="$(ctx)"; rc=$?
chk "over ask → exit 0"                 test "$rc" = "0"
chk "over ask → CONTEXT: ASK"           has "CONTEXT: ASK" "$out"
chk "over ask → offers the handoff"     has "mentor:handoff" "$out"
chk "over ask → offers the bypass"      has "bypass-context.sh" "$out"
chk "over ask → does not dispatch yet"  has "Do NOT dispatch implementation yet" "$out"
# The user already chose to continue: this command must NEVER then refuse them.
# Being stricter than the gate itself is the bug this guards.
: > "$REPO/.mentor/.context-bypass-sess"
out="$(ctx)"
chk "bypassed → CONTEXT: HANDOFF"       has "CONTEXT: HANDOFF" "$out"
chk "bypassed → proceeds, no ASK"       hasnt "CONTEXT: ASK" "$out"
chk "bypassed → still says hand off next" has "/mentor:handoff" "$out"
rm -f "$REPO/.mentor/.context-bypass-sess"
mktx "$TXDIR/sess.jsonl" 230000
out="$(ctx)"
chk "over warn → CONTEXT: WARN"         has "CONTEXT: WARN" "$out"
chk "over warn → no ASK directive"      hasnt "CONTEXT: ASK" "$out"
mktx "$TXDIR/sess.jsonl" 50000
out="$( cd "$REPO" && env -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
        HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" CLAUDE_CODE_SESSION_ID=sess \
        bash "$PLANSTATE" context 2>&1 )"
chk "under warn → CONTEXT: OK"          has "CONTEXT: OK" "$out"
out="$( cd "$REPO" && env HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" \
        CLAUDE_CODE_SESSION_ID=sess MENTOR_CONTEXT_GATE=off bash "$PLANSTATE" context 2>&1 )"
chk "kill switch honored → UNKNOWN"     has "CONTEXT: UNKNOWN" "$out"
rm -f "$TXDIR/sess.jsonl"

echo "== I. Environmental problems are fail-soft: exit 0 with ONE reason on stderr =="
CWD="$NONGIT"
out="$(ps list)"; rc=$?
chk "not in a repo → exit 0"            test "$rc" = "0"
chk "not in a repo → says so"           has "Not in a git repo" "$out"
chk "not in a repo → reason on stderr"  test -n "$(pserr list)"
chk "not in a repo → nothing on stdout" test -z "$(psout list)"
out="$(ps current)"; rc=$?
chk "current outside a repo → exit 0"   test "$rc" = "0"
out="$(ps context)"; rc=$?
chk "context outside a repo → exit 0"   test "$rc" = "0"
CWD="$BARE"
out="$(ps list)"; rc=$?
chk "repo with no plans dir → exit 0"   test "$rc" = "0"
chk "repo with no plans dir → says so"  has "No plans dir yet" "$out"
CWD="$REPO"
rm -rf "$PLANS"; mkdir -p "$PLANS"
out="$(ps list)"; rc=$?
chk "empty plans dir → exit 0"          test "$rc" = "0"
chk "empty plans dir → reason"          has "No plans" "$out"
out="$(ps current)"; rc=$?
chk "current with no plans → exit 0"    test "$rc" = "0"
chk "current with no plans → reason"    has "No plan found" "$out"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
