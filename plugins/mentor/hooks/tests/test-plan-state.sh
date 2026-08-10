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
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX/.claude/projects/proj"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
BARE="$ROOT/bare-repo"          # a repo that has never planned
git init -q -b main "$BARE" >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

# A PATH with real `git`/`dirname` but NO jq — for overview's fail-soft-without-jq
# check. Only those two externals run before overview's own require_jq_read guard
# (mentor_repo_root → git/dirname; everything after is shell builtins), so this
# minimal PATH is enough to prove the guard fires rather than crashing on a missing
# unrelated tool.
BASH_BIN="$(command -v bash)"
NOJQ_DIR="$ROOT/nojq"; mkdir -p "$NOJQ_DIR"
ln -s "$(command -v git)" "$NOJQ_DIR/git"
ln -s "$(command -v dirname)" "$NOJQ_DIR/dirname"

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
# Same as ps/psout/pserr but with a PATH where `jq` cannot be found (see NOJQ_DIR).
psq_nojq_out() { ( cd "${CWD:-$REPO}" && _env PATH="$NOJQ_DIR" "$BASH_BIN" "$PLANSTATE" "$@" 2>/dev/null ); }
psq_nojq_err() { ( cd "${CWD:-$REPO}" && _env PATH="$NOJQ_DIR" "$BASH_BIN" "$PLANSTATE" "$@" 2>&1 >/dev/null ); }
psq_nojq_rc()  { ( cd "${CWD:-$REPO}" && _env PATH="$NOJQ_DIR" "$BASH_BIN" "$PLANSTATE" "$@" >/dev/null 2>&1 ); }
# Read one field straight off a plan's sidecar (deps/origin — list/current never
# surface these, so the CLI-output assertions above can't reach them).
sidecar() { jq -r "${2}" "$PLANS/$1/.state.json" 2>/dev/null; }   # sidecar <slug> <jq filter>

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
chk "over ask → offers the handoff"     has "mentor:handoff-note" "$out"
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

echo "== I2. dir: pure path derivation, before every guard =="
CWD="$REPO"
out="$(psout dir)"; rc=$?
chk "dir in a repo → exit 0"            test "$rc" = "0"
chk "dir in a repo → <root>/.mentor"    test "$out" = "$REPO/.mentor"
chk "dir --plans → plans dir"           test "$(psout dir --plans)" = "$REPO/.mentor/plans"
CWD="$BARE"
chk "dir in a never-planned repo works" test "$(psout dir)" = "$BARE/.mentor"   # no plans-dir guard
CWD="$NONGIT"
chk "dir outside a repo → _no-repo"     test "$(psout dir)" = "$SANDBOX/.claude/mentor/_no-repo"
CWD="$REPO"

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

echo "== ensure-dir — creates + locks to 700, and refuses to escape the mentor dir =="
# Skills substitute a model-chosen <topic> into these paths, so an unconfined ensure-dir
# would be an arbitrary mkdir-and-chmod primitive reachable straight from a prompt.
ed_mdir="$(ps dir)"
out="$(ps ensure-dir "$ed_mdir/plans/ed-topic/handoffs")"; rc=$?
chk "ensure-dir inside the mentor dir → exit 0"  test "$rc" = "0"
chk "ensure-dir echoes the path"                 has "plans/ed-topic/handoffs" "$out"
chk "ensure-dir created it"                      test -d "$ed_mdir/plans/ed-topic/handoffs"
chk "ensure-dir locked the leaf to 700" \
  test "$(ls -ld "$ed_mdir/plans/ed-topic/handoffs" | cut -c1-10)" = "drwx------"
chk "ensure-dir locked the intermediate too" \
  test "$(ls -ld "$ed_mdir/plans/ed-topic" | cut -c1-10)" = "drwx------"

out="$(ps ensure-dir "$ROOT/escape-me")"; rc=$?
chk "ensure-dir outside the mentor dir → exit 1" test "$rc" = "1"
chk "ensure-dir refusal says so"                 has "refuses a path outside" "$out"
chk "ensure-dir created nothing outside"         test ! -d "$ROOT/escape-me"

out="$(ps ensure-dir "$ed_mdir/plans/../../../escape-dots")"; rc=$?
chk "ensure-dir rejects a .. escape"             test "$rc" = "1"
chk "..-escape created nothing"                  test ! -d "$ROOT/escape-dots"

out="$(ps ensure-dir)"; rc=$?
chk "ensure-dir with no path → exit 1"           test "$rc" = "1"

echo "== J. init --deps / --deferred (v2.17.0) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan dep-a; plan dep-b
ps init dep-a >/dev/null
out="$(ps init dep-b --deps dep-a)"; rc=$?
chk "init --deps → exit 0"                  test "$rc" = "0"
chk "init --deps reports deps"              has "deps=dep-a" "$out"
chk "init --deps stored in sidecar"         test "$(sidecar dep-b '(.deps//[])|join(",")')" = "dep-a"
out="$(ps init dep-b --deferred)"
chk "init --deferred reports origin"        has "origin=deferred" "$out"
chk "init --deferred sets sidecar origin"   test "$(sidecar dep-b '.origin')" = "deferred"
chk "init --deferred does not disturb deps" test "$(sidecar dep-b '(.deps//[])|join(",")')" = "dep-a"

plan dep-self
out="$(ps init dep-self --deps dep-self --deferred)"; rc=$?
chk "init --deps self-cycle → exit 0 (fail-soft)"          test "$rc" = "0"
chk "init --deps self-cycle refused on stderr"              has "dependency cycle" "$out"
chk "init --deps self-cycle: deps NOT set"                  test "$(sidecar dep-self '(.deps//[])|length')" = "0"
chk "init --deps self-cycle: sibling flags still applied"   test "$(sidecar dep-self '.origin')" = "deferred"

echo "== K. set-deps: replace wholesale, cycle-checked, fail-soft =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan sd-a; plan sd-b; plan sd-c
ps init sd-a >/dev/null; ps init sd-b >/dev/null; ps init sd-c >/dev/null
out="$(ps set-deps sd-a sd-b,sd-c)"; rc=$?
chk "set-deps → exit 0"                      test "$rc" = "0"
chk "set-deps reports deps"                  has "deps = sd-b,sd-c" "$out"
chk "set-deps stored wholesale, in order"    test "$(sidecar sd-a '(.deps//[])|join(",")')" = "sd-b,sd-c"

out="$(ps set-deps sd-a sd-a)"; rc=$?
chk "self-cycle → exit 0 (fail-soft)"        test "$rc" = "0"
chk "self-cycle refused on stderr"           has "dependency cycle" "$out"
chk "self-cycle: deps unchanged"             test "$(sidecar sd-a '(.deps//[])|join(",")')" = "sd-b,sd-c"

# Multi-node (2 hops): a→b, then b→a must be refused (closes a→b→a).
plan mn-a; plan mn-b
ps init mn-a >/dev/null; ps init mn-b >/dev/null
ps set-deps mn-a mn-b >/dev/null
out="$(ps set-deps mn-b mn-a)"; rc=$?
chk "2-node multi-node cycle → exit 0 (fail-soft)" test "$rc" = "0"
chk "2-node multi-node cycle refused on stderr"    has "dependency cycle" "$out"
chk "2-node cycle: deps unchanged (empty)"         test "$(sidecar mn-b '(.deps//[])|length')" = "0"

# Multi-node (3 hops): a→b→c, then c→a must also be refused.
plan mn3-a; plan mn3-b; plan mn3-c
ps init mn3-a >/dev/null; ps init mn3-b >/dev/null; ps init mn3-c >/dev/null
ps set-deps mn3-a mn3-b >/dev/null
ps set-deps mn3-b mn3-c >/dev/null
out="$(ps set-deps mn3-c mn3-a)"; rc=$?
chk "3-node cycle → exit 0 (fail-soft)"      test "$rc" = "0"
chk "3-node cycle refused on stderr"         has "dependency cycle" "$out"
chk "3-node cycle: deps unchanged (empty)"   test "$(sidecar mn3-c '(.deps//[])|length')" = "0"

plan unk-x
ps init unk-x >/dev/null
out="$(ps set-deps unk-x does-not-exist)"; rc=$?
chk "unknown dep slug allowed (may be deferred later)" test "$rc" = "0"
chk "unknown dep slug stored"                          test "$(sidecar unk-x '(.deps//[])|join(",")')" = "does-not-exist"
out="$(ps set-deps unk-x "")"; rc=$?
chk "empty deps clears them → exit 0"        test "$rc" = "0"
chk "empty deps reported as (none)"          has "deps = (none)" "$out"
chk "empty deps → sidecar deps = []"         test "$(sidecar unk-x '(.deps//[])|length')" = "0"

plan note-dep
ps init note-dep >/dev/null
ps set note-dep failed --note "keep me" >/dev/null
ps set-deps note-dep sd-b >/dev/null
chk "set-deps preserves the note"            test "$(sidecar note-dep '.note')" = "keep me"
chk "set-deps preserves the state"           test "$(state_of note-dep)" = "failed"

echo "== L. claim: clears origin; note and other fields round-trip =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan clm
ps init clm --deferred >/dev/null
chk "init --deferred → origin deferred"     test "$(sidecar clm '.origin')" = "deferred"
ps set clm draft --note "stub context" >/dev/null
chk "a plain set preserves origin (omitted flag)" test "$(sidecar clm '.origin')" = "deferred"
out="$(ps claim clm)"; rc=$?
chk "claim → exit 0"                        test "$rc" = "0"
chk "claim reports clearing"                has "claimed — origin cleared" "$out"
chk "claim clears origin"                   test "$(sidecar clm '.origin')" = "null"
chk "claim preserves the note"              test "$(sidecar clm '.note')" = "stub context"
chk "claim preserves the state"             test "$(state_of clm)" = "draft"
out="$(ps claim clm)"; rc=$?
chk "claim again → exit 0"                  test "$rc" = "0"
chk "claim again → nothing to claim"        has "origin already unset" "$out"

plan clm2
ps init clm2 >/dev/null   # never deferred
out="$(ps claim clm2)"; rc=$?
chk "claim on a never-deferred plan → exit 0"           test "$rc" = "0"
chk "claim on a never-deferred plan → nothing to claim" has "origin already unset" "$out"

echo "== L2. tick: writes the ✅ a hand-rolled Edit used to place by hand =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan tk '# t' '## Implementation steps' \
  'Step 1 — first  [role: general-purpose]' '   Done when: it works' \
  'Step 2 — second  [role: general-purpose]' '   Done when: it also works' \
  '1. **Numbered form**' '2. **Second numbered**' \
  '## Verification' 'Step 1 — prose about verification, not a real step'
chk "before any tick: 0 ticked"          test "$(state_of tk)" = "unknown"
out="$(ps tick tk 1)"; rc=$?
chk "tick step 1 → exit 0"               test "$rc" = "0"
chk "tick step 1 → reports 1/4"          has "step 1 .* ticked (1/4)" "$out"
chk "tick step 1 → plan.md carries ✅ on the Step 1 line, not Done when:" \
  bash -c "sed -n '3p' '$PLANS/tk/plan.md' | grep -q '✅' && ! sed -n '4p' '$PLANS/tk/plan.md' | grep -q '✅'"
chk "tick step 1 → derived state advances"   test "$(state_of tk)" = "in_progress"
out="$(ps tick tk 1)"; rc=$?
chk "re-tick the same step → exit 0 (idempotent)"  test "$rc" = "0"
chk "re-tick reports already-ticked, no write"     has "already ✅" "$out"
out="$(ps tick tk 3)"; rc=$?
chk "tick a numbered-item step → exit 0"           test "$rc" = "0"
chk "numbered-item step ✅ lands on its own line" bash -c "sed -n '7p' '$PLANS/tk/plan.md' | grep -q '✅'"
out="$(ps tick tk 99)"; rc=$?
chk "tick past the last step → exit 1"             test "$rc" = "1"
chk "tick past the last step → names the count"    has "no step 99" "$out"
chk "tick past the last step → no write happened"  test "$(state_of tk)" = "in_progress"
out="$(ps tick tk 0)"; rc=$?
chk "tick step 0 → exit 1"                         test "$rc" = "1"
out="$(ps tick tk abc)"; rc=$?
chk "tick a non-numeric step → exit 1"             test "$rc" = "1"
out="$(ps tick tk 1 extra)"; rc=$?
chk "tick with a stray extra argument → exit 1"    test "$rc" = "1"
out="$(ps tick nope 1)"; rc=$?
chk "tick unknown slug → exit 1"                   test "$rc" = "1"
chk "tick unknown slug → points at list"           has "plan-state.sh list" "$out"
before_verify="$(sed -n '10p' "$PLANS/tk/plan.md")"
chk "the Verification section's own 'Step 1 —' line is never touched" \
  test "$before_verify" = "Step 1 — prose about verification, not a real step"
ps tick tk 2 >/dev/null; ps tick tk 4 >/dev/null
chk "all 4 steps ticked → derived state reaches implemented" test "$(state_of tk)" = "implemented"

echo "== M. overview --json: repo-wide hierarchy (v2.17.0) — the new surface =="
rm -rf "$PLANS" "$REPO/.mentor/handoffs"; mkdir -p "$PLANS"
out="$(psout overview --json)"; rc=$?
chk "overview --json on an empty repo → exit 0" test "$rc" = "0"
chk "overview --json on an empty repo → []"     test "$out" = "[]"

plan ov-a '# a' '## Implementation steps' '1. one ✅' '2. two ✅'
mkdir -p "$PLANS/ov-a/handoffs/resolved"
: > "$PLANS/ov-a/handoffs/live-note.md"
: > "$PLANS/ov-a/handoffs/resolved/old-note.md"
ps init ov-a >/dev/null

plan ov-b '# b' '## Implementation steps' '1. one ✅' '2. two'
ps init ov-b >/dev/null
ps set-deps ov-b "ov-a,ov-missing" >/dev/null

mkdir -p "$PLANS/ov-topic/handoffs"
: > "$PLANS/ov-topic/handoffs/nudge.md"

mkdir -p "$REPO/.mentor/handoffs"
: > "$REPO/.mentor/handoffs/legacy-note.md"

out="$(psout overview --json)"; rc=$?
chk "overview --json → exit 0"    test "$rc" = "0"
chk "overview --json → valid JSON" sh -c 'printf "%s" "$0" | jq . >/dev/null 2>&1' "$out"
chk "overview → 4 entries (2 plans + plan-less topic + legacy)" test "$(printf '%s' "$out" | jq 'length')" = "4"

ov_a="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-a")')"
chk "ov-a: kind plan"                   test "$(printf '%s' "$ov_a" | jq -r '.kind')" = "plan"
chk "ov-a: effective state implemented" test "$(printf '%s' "$ov_a" | jq -r '.state')" = "implemented"
chk "ov-a: step counts 2/2"             test "$(printf '%s' "$ov_a" | jq -r '.steps.ticked,.steps.total' | tr '\n' ' ')" = "2 2 "
chk "ov-a: live handoff only, resolved excluded" test "$(printf '%s' "$ov_a" | jq -c '.handoffs')" = '["live-note.md"]'
chk "ov-a: no deps"                     test "$(printf '%s' "$ov_a" | jq -c '.deps')" = '[]'
chk "ov-a: origin null"                 test "$(printf '%s' "$ov_a" | jq -r '.origin')" = "null"

ov_b="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-b")')"
chk "ov-b: step counts 1/2"                  test "$(printf '%s' "$ov_b" | jq -r '.steps.ticked,.steps.total' | tr '\n' ' ')" = "1 2 "
chk "ov-b: deps carry both slugs, in order"  test "$(printf '%s' "$ov_b" | jq -c '.deps | map(.slug)')" = '["ov-a","ov-missing"]'
chk "ov-b: known dep marked not missing"     test "$(printf '%s' "$ov_b" | jq -r '.deps[0].missing')" = "false"
chk "ov-b: unknown dep marked missing"       test "$(printf '%s' "$ov_b" | jq -r '.deps[1].missing')" = "true"
chk "ov-b: no handoffs"                      test "$(printf '%s' "$ov_b" | jq -c '.handoffs')" = '[]'

ov_topic="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-topic")')"
chk "plan-less topic: kind no_plan_topic"  test "$(printf '%s' "$ov_topic" | jq -r '.kind')" = "no_plan_topic"
chk "plan-less topic: state 'no plan yet'" test "$(printf '%s' "$ov_topic" | jq -r '.state')" = "no plan yet"
chk "plan-less topic: live handoff listed" test "$(printf '%s' "$ov_topic" | jq -c '.handoffs')" = '["nudge.md"]'
chk "plan-less topic: zero step counts"    test "$(printf '%s' "$ov_topic" | jq -c '.steps')" = '{"ticked":0,"total":0}'

ov_legacy="$(printf '%s' "$out" | jq -c '.[] | select(.kind=="legacy_handoffs")')"
chk "legacy dir: topic-less (slug null)" test "$(printf '%s' "$ov_legacy" | jq -r '.slug')" = "null"
chk "legacy dir: state null"             test "$(printf '%s' "$ov_legacy" | jq -r '.state')" = "null"
chk "legacy dir: steps null"             test "$(printf '%s' "$ov_legacy" | jq -r '.steps')" = "null"
chk "legacy dir: lists the flat note"    test "$(printf '%s' "$ov_legacy" | jq -c '.handoffs')" = '["legacy-note.md"]'

chk "plan dirs never double as a plan-less topic" \
  test -z "$(printf '%s' "$out" | jq -r '.[] | select(.kind=="no_plan_topic" and (.slug=="ov-a" or .slug=="ov-b"))')"

echo "== N. overview --json is fail-soft when jq is absent from PATH =="
out="$(psq_nojq_out overview --json)"
err="$(psq_nojq_err overview --json)"
rc=0; psq_nojq_rc overview --json || rc=$?
chk "no jq → exit 0"                  test "$rc" = "0"
chk "no jq → empty stdout"            test -z "$out"
chk "no jq → one-line stderr notice"  test "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = "1"
chk "no jq → notice names the problem" has "jq not found" "$err"

echo "== O. list stays byte-compatible even when a plan carries deps/origin =="
ps init ov-b --deferred >/dev/null   # give ov-b an origin too, alongside its deps
out="$(psout list)"
row="$(printf '%s' "$out" | awk -v s="ov-b" '$3 == s')"
chk "row for a deps+origin plan is still found"    test -n "$row"
chk "row is still exactly 5 whitespace-separated columns" \
  test "$(printf '%s' "$row" | awk '{print NF}')" = "5"
chk "row carries no stray JSON from deps/origin" \
  sh -c '! printf "%s" "$0" | grep -qE "[][{}]"' "$row"

echo "== P. gate: read-only plan-gate marker status, before every guard =="
CWD="$REPO"
GATE_MARKER="$REPO/.mentor/plans/.planning"
rm -f "$GATE_MARKER"
chk "no marker → RELEASED"                     test "$(psout gate)" = "RELEASED"
: > "$GATE_MARKER"
chk "fresh marker → ARMED"                     test "$(psout gate)" = "ARMED"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$GATE_MARKER" 2>/dev/null || true
chk "9h-old marker → STALE"                    test "$(psout gate)" = "STALE"
chk "gate never deletes the marker"            test -e "$GATE_MARKER"
rm -f "$GATE_MARKER"
CWD="$BARE"
chk "gate in a never-planned repo → RELEASED"  test "$(psout gate)" = "RELEASED"
CWD="$NONGIT"
chk "gate outside a repo → RELEASED"           test "$(psout gate)" = "RELEASED"
CWD="$REPO"
out="$(ps gate extra)"; rc=$?
chk "gate rejects a stray argument → exit 1"   test "$rc" = "1"
chk "gate rejects a stray argument → names it" has "unexpected argument" "$out"

echo "== P2. gate --verbose: additive-only, ARMED-only owner/age/affected-plans =="
CWD="$REPO"
rm -f "$GATE_MARKER"
plan gv-old "old plan — written BEFORE the marker, must not show as affected"
sleep 1
{ echo "session=test-session-xyz"; echo "cwd=/some/other/repo"; } > "$GATE_MARKER"
sleep 1
plan gv-new "new plan — written AFTER the marker, exactly what approve-plan.sh would promote"
out="$(psout gate --verbose)"
chk "gate --verbose: line 1 is still the bare token" \
  test "$(printf '%s\n' "$out" | sed -n '1p')" = "ARMED"
chk "gate --verbose: reports the owning session"      has "owner_session=test-session-xyz" "$out"
chk "gate --verbose: reports the owning cwd"           has "owner_cwd=/some/other/repo" "$out"
chk "gate --verbose: reports a numeric age" \
  sh -c 'printf "%s" "$0" | grep -qE "age_min=[0-9]+"' "$out"
chk "gate --verbose: affected_plans is exactly the plan written after the marker" \
  test "$(printf '%s\n' "$out" | grep '^affected_plans=')" = "affected_plans=gv-new"
rm -rf "$PLANS/gv-old" "$PLANS/gv-new"

rm -f "$GATE_MARKER"
chk "gate --verbose on RELEASED: still exactly one line" \
  test "$(psout gate --verbose | wc -l | tr -d ' ')" = "1"
: > "$GATE_MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$GATE_MARKER" 2>/dev/null || true
chk "gate --verbose on STALE: still exactly one line" \
  test "$(psout gate --verbose | wc -l | tr -d ' ')" = "1"
rm -f "$GATE_MARKER"

out="$(ps gate --verbose extra)"; rc=$?
chk "gate --verbose rejects a further stray argument → exit 1"   test "$rc" = "1"
chk "gate --verbose rejects a further stray argument → names it" has "unexpected argument" "$out"

echo "== Q. set … implemented/failed: closing-checklist reminder (closing_checklist_reminder) =="
# mentor_find_transcript's cwd-hash fallback (CLAUDE_CODE_SESSION_ID is stripped by
# _env, same as every other test here) — a fixture transcript lives under the
# sandboxed CLAUDE_CONFIG_DIR at projects/<hash of $REPO>/<sid>.jsonl.
REPO_HASH="$(printf '%s' "$REPO" | sed 's/[^A-Za-z0-9]/-/g')"
TXDIR="$SANDBOX/.claude/projects/$REPO_HASH"; mkdir -p "$TXDIR"
tx_agent_only() {   # one Agent dispatch, no TaskList
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}' \
    > "$TXDIR/cc.jsonl"
}
tx_agent_and_tasklist() {   # Agent dispatch, closed out with TaskList
  { printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskList","input":{}}]}}'
  } > "$TXDIR/cc.jsonl"
}
tx_no_agent() {   # a session that never dispatched anything
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' \
    > "$TXDIR/cc.jsonl"
}

plan cc-fire; plan cc-silent-tasklist; plan cc-silent-noagent; plan cc-silent-otherstate
plan cc-silent-notx; plan cc-refire; plan cc-failed

tx_agent_only
merged="$(ps set cc-fire implemented)"; rc=$?   # ps merges stdout+stderr — one call, several assertions
chk "dispatched agents, no TaskList → reminder fires"      has "Closing checklist" "$merged"
chk "reminder → names TaskList enumerate/diff/TaskStop"    has "TaskList: enumerate" "$merged"
chk "reminder → names the /mentor:tour offer"              has "/mentor:tour" "$merged"
chk "reminder → names the /mentor:ship pointer"             has "/mentor:ship" "$merged"
chk "reminder → names the /mentor:defer sweep"             has "/mentor:defer" "$merged"
chk "reminder → still reports the state transition"        has "unknown → implemented" "$merged"
chk "reminder path still exits 0"                           test "$rc" = "0"

tx_agent_and_tasklist
out="$(ps set cc-silent-tasklist implemented)"
chk "TaskList already called → no TaskList line"           hasnt "TaskList: enumerate" "$out"
chk "TaskList already called → defer sweep still fires"    has "/mentor:defer" "$out"

tx_no_agent
out="$(ps set cc-silent-noagent implemented)"
chk "no Agent dispatch → no TaskList line"                  hasnt "TaskList: enumerate" "$out"
chk "no Agent dispatch → defer/tour/ship still fire"        has "/mentor:defer" "$out"

tx_agent_only
out="$(pserr set cc-silent-otherstate in_progress)"
chk "transition to a non-terminal state → silent"           hasnt "Closing checklist" "$out"

rm -f "$TXDIR/cc.jsonl"
out="$(ps set cc-silent-notx implemented)"
chk "no transcript on disk at all → no TaskList line"        hasnt "TaskList: enumerate" "$out"
chk "no transcript on disk at all → defer sweep still fires" has "/mentor:defer" "$out"

tx_agent_only
ps set cc-refire implemented >/dev/null   # first close — dispatch-agents' own transition
out="$(pserr set cc-refire implemented)"  # shipping/merging idempotently re-closing the same plan
chk "idempotent re-close (before==state already) → silent"  hasnt "Closing checklist" "$out"

tx_agent_only
out="$(ps set cc-failed failed --note "verification unresolved")"
chk "failed → TaskList line still fires"                     has "TaskList: enumerate" "$out"
chk "failed → defer sweep still fires"                       has "/mentor:defer" "$out"
chk "failed → tour offer held (checklist carve-out)"         hasnt "/mentor:tour" "$out"
chk "failed → ship pointer held (checklist carve-out)"       hasnt "/mentor:ship" "$out"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
