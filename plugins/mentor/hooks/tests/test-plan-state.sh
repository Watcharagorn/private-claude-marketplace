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
#   • v2.23.0 (worktree-scoped plan gate): `gate` reports one of FOUR tokens
#     (ARMED/STALE/ARMED_ELSEWHERE/RELEASED) for THIS worktree, with a per-token
#     `--verbose` field contract; `current` scopes to plans owned by this worktree
#     (or unowned) unless `--any`; `ensure-dir`/`init`/`claim` stamp sidecar
#     `owner`/`owner_session`; `list --owners` adds a 6th OWNER column.
#   • v2.24.0 (impact tier): the sidecar carries `priority` — a CLOSED vocabulary
#     (critical|high|medium|low|noise), written by `init --priority` and
#     `set-priority`, surfaced on every `query` entry. Unset stays null
#     and never defaults into a tier; an invalid value is a usage error (exit 1,
#     nothing written), not a fail-soft skip; and `list`'s column count is
#     unchanged in both its shapes.
#
# Runs against a SANDBOX $HOME and CLAUDE_CONFIG_DIR so it never touches real user
# state and never finds a real session transcript.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
PLANSTATE="$HOOKS/plan-state.sh"
[ -f "$PLANSTATE" ] || { echo "FATAL: not found: $PLANSTATE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }
# shellcheck source=../lib/state.sh
. "$HOOKS/lib/state.sh"   # only for mentor_worktree_id, to derive wt-ids the same way begin-plan.sh does

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX/.claude/projects/proj"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
git -C "$REPO" worktree add -q "$ROOT/wt-b" -b wtb >/dev/null 2>&1
git -C "$REPO" worktree add -q "$ROOT/wt-c" -b wtc >/dev/null 2>&1
BARE="$ROOT/bare-repo"          # a repo that has never planned
git init -q -b main "$BARE" >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

# Second/third linked worktrees of the SAME repo (plans stay shared — one plans/
# dir — but the plan-gate marker is per-worktree, v2.23.0). Ids derived with the
# exact production recipe so a marker suffix here can never drift from what
# begin-plan.sh would actually write.
WTB="$ROOT/wt-b"
WTC="$ROOT/wt-c"
WTA_ID="$(mentor_worktree_id "$REPO")"
WTB_ID="$(mentor_worktree_id "$WTB")"
WTC_ID="$(mentor_worktree_id "$WTC")"
[ -n "$WTA_ID" ] && [ -n "$WTB_ID" ] && [ -n "$WTC_ID" ] || { echo "FATAL: could not derive worktree ids for the fixture repo" >&2; exit 1; }

# A PATH with real `git`/`dirname` but NO jq — for query's fail-soft-without-jq
# check. Only those two externals run before query's own require_jq_read guard
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

# Marker paths (v2.23.0): one per worktree, plus the reserved legacy repo-global
# bare marker. Sections that exercise `gate` write these directly.
LEGACY_MARKER="$PLANS/.planning"
OWN_MARKER="$PLANS/.planning.${WTA_ID}"
SIB_MARKER="$PLANS/.planning.${WTB_ID}"
SIB_MARKER_C="$PLANS/.planning.${WTC_ID}"

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
# Same as ps(), but with an explicit CLAUDE_CODE_SESSION_ID — for the owner_session
# stamping checks (ps()/psout() deliberately strip it via _env above).
ps_sess() { local sess="$1"; shift
  ( cd "${CWD:-$REPO}" && env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
        HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" CLAUDE_CODE_SESSION_ID="$sess" bash "$PLANSTATE" "$@" 2>&1 );
}
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

echo "== C2. init/claim re-stamp ownership — last-init-wins (v2.23.0) =="
plan reown
CWD="$WTB"; ps init reown >/dev/null; CWD="$REPO"
chk "reown initially owned by the worktree that inited it (B)" test "$(sidecar reown '.owner')" = "$WTB_ID"
ps init reown >/dev/null   # re-init from A (this worktree) — re-owns
chk "re-init from a different worktree re-owns it (last-init-wins)" test "$(sidecar reown '.owner')" = "$WTA_ID"
ps set reown approved >/dev/null
chk "a plain set leaves ownership exactly as it was" test "$(sidecar reown '.owner')" = "$WTA_ID"

plan reclaim
ps init reclaim --deferred >/dev/null
chk "reclaim initially owned by A (inited here)" test "$(sidecar reclaim '.owner')" = "$WTA_ID"
CWD="$WTB"; ps claim reclaim >/dev/null; CWD="$REPO"
chk "claim from a different worktree re-owns it too" test "$(sidecar reclaim '.owner')" = "$WTB_ID"

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

echo "== G3. current: scoped to this worktree's owned/unowned plans; --any is unfiltered (v2.23.0) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan cur-a-owned; plan cur-unowned; plan cur-b-owned
ps init cur-a-owned >/dev/null                            # owned by A (this worktree)
CWD="$WTB"; ps init cur-b-owned >/dev/null; CWD="$REPO"    # owned by B
sleep 1; touch "$PLANS/cur-a-owned/plan.md"
sleep 1; touch "$PLANS/cur-unowned/plan.md"
sleep 1; touch "$PLANS/cur-b-owned/plan.md"   # B-owned is now the true mtime-newest
out="$(psout current)"
chk "current (scoped): skips the sibling-owned newest, picks next eligible" has "SLUG: cur-unowned" "$out"
chk "current (scoped): never names the sibling-owned plan"                  hasnt "SLUG: cur-b-owned" "$out"
out="$(psout current --any)"
chk "current --any: unfiltered, reports the true mtime-newest (sibling-owned)" has "SLUG: cur-b-owned" "$out"

rm -rf "$PLANS"; mkdir -p "$PLANS"
plan only-b-owned
CWD="$WTB"; ps init only-b-owned >/dev/null; CWD="$REPO"
out="$(ps current)"; rc=$?
chk "current (scoped), only a sibling-owned plan exists → exit 0" test "$rc" = "0"
chk "current (scoped) → ownership-aware refusal names it"          has "owned by another worktree" "$out"
out="$(ps current --any)"; rc=$?
chk "current --any still finds the sibling-owned plan"             has "SLUG: only-b-owned" "$out"

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
chk "current with no plans → reason (ownership-scoped wording, v2.23.0)" \
  has "No plan owned by this worktree found" "$out"
out="$(ps current --any)"; rc=$?
chk "current --any with no plans → exit 0"   test "$rc" = "0"
chk "current --any with no plans → reason"   has "No plan found" "$out"

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
# The target above (plans/ed-topic/handoffs) is a GRANDCHILD of plans/, not a direct
# child — ownership is stamped on the plan TOPIC dir only (see ensure-dir2 below).
chk "ensure-dir on a nested (non-direct-child) target stamps no owner" \
  test ! -f "$ed_mdir/plans/ed-topic/.state.json"

out="$(ps ensure-dir "$ROOT/escape-me")"; rc=$?
chk "ensure-dir outside the mentor dir → exit 1" test "$rc" = "1"
chk "ensure-dir refusal says so"                 has "refuses a path outside" "$out"
chk "ensure-dir created nothing outside"         test ! -d "$ROOT/escape-me"

out="$(ps ensure-dir "$ed_mdir/plans/../../../escape-dots")"; rc=$?
chk "ensure-dir rejects a .. escape"             test "$rc" = "1"
chk "..-escape created nothing"                  test ! -d "$ROOT/escape-dots"

out="$(ps ensure-dir)"; rc=$?
chk "ensure-dir with no path → exit 1"           test "$rc" = "1"

echo "== ensure-dir2 — a direct child of plans/ gets owner/owner_session stamped (v2.23.0) =="
out="$(ps_sess owner-sess ensure-dir "$ed_mdir/plans/owner-topic")"; rc=$?
chk "ensure-dir (direct child of plans/) → exit 0"  test "$rc" = "0"
chk "ensure-dir stamps owner"                        test "$(sidecar owner-topic '.owner')" = "$WTA_ID"
chk "ensure-dir stamps owner_session"                test "$(sidecar owner-topic '.owner_session')" = "owner-sess"

echo "== HP. handoff-path <topic> <slug> — the ONE call handoff-note Step 2 needs =="
out="$(ps handoff-path hp-topic hp-slug)"; rc=$?
chk "handoff-path → exit 0"                       test "$rc" = "0"
chk "handoff-path echoes a path under handoffs/"  has "plans/hp-topic/handoffs/" "$out"
chk "handoff-path echoes the slug"                has "-hp-slug.md" "$out"
chk "handoff-path filename matches /mentor:resume's pattern" \
  bash -c '[[ "$(basename "$1")" =~ ^[0-9]{8}-[0-9]{6}-hp-slug\.md$ ]]' _ "$out"
chk "handoff-path created the handoffs dir"       test -d "$ed_mdir/plans/hp-topic/handoffs"
chk "handoff-path locked handoffs/ to 700" \
  test "$(ls -ld "$ed_mdir/plans/hp-topic/handoffs" | cut -c1-10)" = "drwx------"
chk "handoff-path locked the topic dir to 700" \
  test "$(ls -ld "$ed_mdir/plans/hp-topic" | cut -c1-10)" = "drwx------"
chk "handoff-path wrote the mentor-dir gitignore" test -f "$ed_mdir/.gitignore"

out="$(ps handoff-path)"; rc=$?
chk "handoff-path with no args → exit 1"          test "$rc" = "1"
out="$(ps handoff-path hp-topic)"; rc=$?
chk "handoff-path with only <topic> → exit 1"     test "$rc" = "1"

out="$(ps handoff-path "my/topic" slug)"; rc=$?
chk "handoff-path refuses a topic with '/' → exit 1" test "$rc" = "1"
chk "..refusal named on stderr"                       has "refuses a topic" "$out"
chk "..created nothing under a slash-topic dir"       test ! -d "$ed_mdir/plans/my"

out="$(ps handoff-path ".." slug)"; rc=$?
chk "handoff-path refuses topic '..' → exit 1"    test "$rc" = "1"

out="$(ps handoff-path topic "a/b")"; rc=$?
chk "handoff-path refuses a slug with '/' → exit 1" test "$rc" = "1"

out="$(ps handoff-path "<topic>" slug)"; rc=$?
chk "handoff-path refuses an unreplaced <topic> placeholder → exit 1" test "$rc" = "1"
chk "..refusal names the placeholder"                                 has "placeholder" "$out"

echo "== HS. handoff-selfcheck <note-path> — the ONE call handoff-note Step 5 needs =="
note1="$(ps handoff-path hs-topic session)"
cat > "$note1" << 'EOF'
## Goal / next-session focus
x

## Recommended mentor commands for the next agent
x

## Current state
ARMED marker=owner. TaskList found 0 live tasks.
EOF
out="$(ps handoff-selfcheck "$note1")"; rc=$?
chk "handoff-selfcheck (first note, nothing to supersede) → exit 0" test "$rc" = "0"
chk "..reports live notes now 1"      has "CHECK: live notes now 1" "$out"
chk "..reports headings none missing" has "CHECK: headings missing: none" "$out"
chk "..reports evidence none missing" has "CHECK: current-state evidence missing: none" "$out"
chk "..nothing superseded (none printed)" hasnt "superseded" "$out"

sleep 1
note2="$(ps handoff-path hs-topic session2)"
cat > "$note2" << 'EOF'
## Goal / next-session focus
y

## Recommended mentor commands for the next agent
y
EOF
out="$(ps handoff-selfcheck "$note2")"; rc=$?
chk "handoff-selfcheck (second note) → exit 0"      test "$rc" = "0"
chk "..supersedes the first note"                    has "superseded → resolved: $(basename "$note1")" "$out"
chk "..first note now lives under resolved/"         test -f "$(dirname "$note1")/resolved/$(basename "$note1")"
chk "..reports live notes now 1"                     has "CHECK: live notes now 1" "$out"
chk "..evidence check names both (note has neither)" \
  has "CHECK: current-state evidence missing: gate-verdict TaskList-evidence" "$out"

echo "junk" > "$(dirname "$note2")/README.md"
out="$(ps handoff-selfcheck "$note2")"
chk "handoff-selfcheck skips a non-conforming filename" has "skipping non-conforming file: README.md" "$out"
chk "..non-conforming file NOT moved"                    test -f "$(dirname "$note2")/README.md"

sleep 1
badnote="$(dirname "$note2")/$(date +%Y%m%d-%H%M%S)-broken.md"
echo "no headings here" > "$badnote"
out="$(ps handoff-selfcheck "$badnote")"; rc=$?
chk "handoff-selfcheck (headings missing) → exit 1" test "$rc" = "1"
chk "..names both missing headings" \
  has "CHECK: headings missing: Goal/next-session-focus Recommended-mentor-commands" "$out"
chk "..still supersedes the prior live note (session2)" has "superseded → resolved: $(basename "$note2")" "$out"

# CRITICAL: a wrong/hallucinated note path (the agent re-typing $out across a Bash-call
# boundary, per Step 5) must NOT supersede/sweep the real live note — validating $out is
# on disk happens BEFORE the supersede loop runs, not after.
ghost="$(dirname "$badnote")/99999999-999999-ghost.md"
out="$(ps handoff-selfcheck "$ghost")"; rc=$?
chk "handoff-selfcheck (note not on disk) → exit 1" test "$rc" = "1"
chk "..reports \$out is not a file"                   has "is not a file" "$out"
chk "..did NOT touch the real live note"              test -f "$badnote"
chk "..real live note NOT swept into resolved/" \
  test ! -f "$(dirname "$badnote")/resolved/$(basename "$badnote")"

out="$(ps handoff-selfcheck)"; rc=$?
chk "handoff-selfcheck with no args → exit 1" test "$rc" = "1"

out="$(ps handoff-selfcheck "$ROOT/outside-mentor/20260101-000000-x.md")"; rc=$?
chk "handoff-selfcheck refuses a path outside the mentor dir → exit 1" test "$rc" = "1"
chk "..refusal named on stderr"      has "refuses a note path outside" "$out"
chk "..created nothing outside"      test ! -d "$ROOT/outside-mentor"

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

echo "== K2. init --priority / set-priority: closed vocabulary, clear-on-empty, survives unrelated writes (v2.24.0) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan pr-a '# a' '## Implementation steps' '1. one' '2. two'
plan pr-b
out="$(ps init pr-a --priority critical)"; rc=$?
chk "init --priority → exit 0"               test "$rc" = "0"
chk "init --priority echoes the tier"        has "priority=critical" "$out"
chk "init --priority stores it"              test "$(sidecar pr-a '.priority')" = "critical"
# A typo'd tier is a USAGE error (exit 1, nothing written), not a fail-soft skip — a
# tiering pass over N plans must never report success having dropped one silently.
ps init pr-b >/dev/null
out="$(ps init pr-b --priority hgih)"; rc=$?
chk "init: invalid priority → exit 1"        test "$rc" = "1"
chk "init: invalid priority names the set"   has "critical high medium low noise" "$out"
chk "init: invalid priority wrote nothing"   test "$(sidecar pr-b '.priority')" = "null"
# init never CLEARS — an empty value preserves, like every other init flag.
ps set-priority pr-b low >/dev/null
ps init pr-b --order 3 >/dev/null
chk "init with no --priority preserves it"   test "$(sidecar pr-b '.priority')" = "low"
ps init pr-b --priority "" >/dev/null
chk "init --priority '' preserves (never clears)" test "$(sidecar pr-b '.priority')" = "low"

out="$(ps set-priority pr-b noise)"; rc=$?
chk "set-priority → exit 0"                  test "$rc" = "0"
chk "set-priority reports the tier"          has "priority = noise" "$out"
chk "set-priority stores it"                 test "$(sidecar pr-b '.priority')" = "noise"
out="$(ps set-priority pr-b bogus)"; rc=$?
chk "set-priority: invalid → exit 1"         test "$rc" = "1"
chk "set-priority: invalid wrote nothing"    test "$(sidecar pr-b '.priority')" = "noise"
# A dropped shell argument must not decay into a silent clear — the value is required
# as a positional even when it is the empty string.
out="$(ps set-priority pr-b)"; rc=$?
chk "set-priority with no value → exit 1"    test "$rc" = "1"
chk "set-priority with no value: no write"   test "$(sidecar pr-b '.priority')" = "noise"
out="$(ps set-priority pr-b low extra)"; rc=$?
chk "set-priority: extra argument → exit 1"  test "$rc" = "1"
out="$(ps set-priority no-such-plan low)"; rc=$?
chk "set-priority: unknown slug → exit 1"    test "$rc" = "1"
out="$(ps set-priority pr-b "")"; rc=$?
chk "set-priority '' → exit 0"               test "$rc" = "0"
chk "set-priority '' reports unset"          has "priority = (unset)" "$out"
chk "set-priority '' clears to null"         test "$(sidecar pr-b '.priority')" = "null"

# The whole point of the omitted-preserves contract: a tier set once must ride through
# every later state transition instead of being clobbered back to null.
ps set-priority pr-a high >/dev/null
ps set pr-a approved --note "n1" >/dev/null
chk "priority survives set <slug> approved"  test "$(sidecar pr-a '.priority')" = "high"
ps set pr-a in_progress >/dev/null
chk "priority survives a note-clearing set"  test "$(sidecar pr-a '.priority')" = "high"
ps set-deps pr-a pr-b >/dev/null
chk "priority survives set-deps"             test "$(sidecar pr-a '.priority')" = "high"
ps claim pr-a >/dev/null
chk "priority survives claim"                test "$(sidecar pr-a '.priority')" = "high"
ps tick pr-a 1 >/dev/null
chk "priority survives tick"                 test "$(sidecar pr-a '.priority')" = "high"
# …and set-priority is a priority-ONLY write: it must not disturb its neighbours.
ps set pr-a failed --note "broke here" >/dev/null
ps set-priority pr-a medium >/dev/null
chk "set-priority preserves the note"        test "$(sidecar pr-a '.note')" = "broke here"
chk "set-priority preserves stored state"    test "$(sidecar pr-a '.state')" = "failed"
chk "set-priority preserves effective state" test "$(state_of pr-a)" = "failed"
chk "set-priority preserves deps"            test "$(sidecar pr-a '(.deps//[])|join(",")')" = "pr-b"

# A pre-v2.24.0 sidecar (no `priority` key at all) reads back unprioritized with no
# migration, and a later write upgrades it in place without touching anything else.
mkdir -p "$PLANS/pr-old"; printf '# old\n' > "$PLANS/pr-old/plan.md"
cat > "$PLANS/pr-old/.state.json" <<'JSON'
{"state":"approved","group":null,"order":null,"note":"n","deps":[],"origin":null}
JSON
chk "old sidecar: priority reads null"       test "$(sidecar pr-old '.priority // "null"')" = "null"
chk "old sidecar: state still reads back"    test "$(state_of pr-old)" = "approved"
ps set-priority pr-old critical >/dev/null
chk "upgrading write adds the priority"      test "$(sidecar pr-old '.priority')" = "critical"
chk "upgrading write preserves the state"    test "$(sidecar pr-old '.state')" = "approved"
chk "upgrading write preserves the note"     test "$(sidecar pr-old '.note')" = "n"

echo "== K3. init --category / set-category: closed vocabulary, clear-on-empty, survives unrelated writes (v2.25.0) =="
plan cat-a '# a' '## Implementation steps' '1. one' '2. two'
plan cat-b
out="$(ps init cat-a --category fix)"; rc=$?
chk "init --category → exit 0"               test "$rc" = "0"
chk "init --category echoes the kind"        has "category=fix" "$out"
chk "init --category stores it"              test "$(sidecar cat-a '.category')" = "fix"
# A typo'd (or deliberately EXCLUDED, like "verify") category is a USAGE error (exit
# 1, nothing written), not a fail-soft skip — the vocabulary excludes anything
# test/verify-shaped on purpose (the scope rule: a category classifies work to BUILD),
# so this also pins that exclusion.
ps init cat-b >/dev/null
out="$(ps init cat-b --category verify)"; rc=$?
chk "init: invalid category → exit 1"        test "$rc" = "1"
chk "init: invalid category names the set"   has "feature fix refactor docs tooling" "$out"
chk "init: invalid category wrote nothing"   test "$(sidecar cat-b '.category')" = "null"
# init never CLEARS — an empty value preserves, like every other init flag.
ps set-category cat-b docs >/dev/null
ps init cat-b --order 3 >/dev/null
chk "init with no --category preserves it"   test "$(sidecar cat-b '.category')" = "docs"
ps init cat-b --category "" >/dev/null
chk "init --category '' preserves (never clears)" test "$(sidecar cat-b '.category')" = "docs"

out="$(ps set-category cat-b tooling)"; rc=$?
chk "set-category → exit 0"                  test "$rc" = "0"
chk "set-category reports the kind"          has "category = tooling" "$out"
chk "set-category stores it"                 test "$(sidecar cat-b '.category')" = "tooling"
out="$(ps set-category cat-b bogus)"; rc=$?
chk "set-category: invalid → exit 1"         test "$rc" = "1"
chk "set-category: invalid wrote nothing"    test "$(sidecar cat-b '.category')" = "tooling"
# A dropped shell argument must not decay into a silent clear — the value is required
# as a positional even when it is the empty string.
out="$(ps set-category cat-b)"; rc=$?
chk "set-category with no value → exit 1"    test "$rc" = "1"
chk "set-category with no value: no write"   test "$(sidecar cat-b '.category')" = "tooling"
out="$(ps set-category cat-b docs extra)"; rc=$?
chk "set-category: extra argument → exit 1"  test "$rc" = "1"
out="$(ps set-category no-such-plan docs)"; rc=$?
chk "set-category: unknown slug → exit 1"    test "$rc" = "1"
out="$(ps set-category cat-b "")"; rc=$?
chk "set-category '' → exit 0"               test "$rc" = "0"
chk "set-category '' reports unset"          has "category = (unset)" "$out"
chk "set-category '' clears to null"         test "$(sidecar cat-b '.category')" = "null"

# The whole point of the omitted-preserves contract: a category set once must ride
# through every later state transition instead of being clobbered back to null.
ps set-category cat-a feature >/dev/null
ps set cat-a approved --note "n1" >/dev/null
chk "category survives set <slug> approved"  test "$(sidecar cat-a '.category')" = "feature"
ps set cat-a in_progress >/dev/null
chk "category survives a note-clearing set"  test "$(sidecar cat-a '.category')" = "feature"
ps set-deps cat-a cat-b >/dev/null
chk "category survives set-deps"             test "$(sidecar cat-a '.category')" = "feature"
ps claim cat-a >/dev/null
chk "category survives claim"                test "$(sidecar cat-a '.category')" = "feature"
ps tick cat-a 1 >/dev/null
chk "category survives tick"                 test "$(sidecar cat-a '.category')" = "feature"
# …and set-category is a category-ONLY write: it must not disturb its neighbours.
ps set cat-a failed --note "broke here" >/dev/null
ps set-category cat-a refactor >/dev/null
chk "set-category preserves the note"        test "$(sidecar cat-a '.note')" = "broke here"
chk "set-category preserves stored state"    test "$(sidecar cat-a '.state')" = "failed"
chk "set-category preserves effective state" test "$(state_of cat-a)" = "failed"
chk "set-category preserves deps"            test "$(sidecar cat-a '(.deps//[])|join(",")')" = "cat-b"

# A pre-v2.25.0 sidecar (no `category` key at all) reads back uncategorized with no
# migration, and a later write upgrades it in place without touching anything else.
mkdir -p "$PLANS/cat-old"; printf '# old\n' > "$PLANS/cat-old/plan.md"
cat > "$PLANS/cat-old/.state.json" <<'JSON'
{"state":"approved","group":null,"order":null,"note":"n","deps":[],"origin":null,"priority":"high"}
JSON
chk "old sidecar: category reads null"       test "$(sidecar cat-old '.category // "null"')" = "null"
chk "old sidecar: state still reads back"    test "$(state_of cat-old)" = "approved"
ps set-category cat-old tooling >/dev/null
chk "upgrading write adds the category"      test "$(sidecar cat-old '.category')" = "tooling"
chk "upgrading write preserves the state"    test "$(sidecar cat-old '.state')" = "approved"
chk "upgrading write preserves the note"     test "$(sidecar cat-old '.note')" = "n"
chk "upgrading write preserves the (unrelated) priority field too" \
  test "$(sidecar cat-old '.priority')" = "high"

echo "== K4. init --from → deferred_from: unvalidated pass-through, no set-deferred-from subcommand (v2.25.0) =="
plan from-a
ps init from-a >/dev/null
chk "no --from → deferred_from stays null" test "$(sidecar from-a '.deferred_from // "null"')" = "null"

plan from-b
out="$(ps init from-b --from from-a)"; rc=$?
chk "init --from → exit 0"                 test "$rc" = "0"
chk "init --from echoes the source plan"   has "from=from-a" "$out"
chk "init --from stores deferred_from"     test "$(sidecar from-b '.deferred_from')" = "from-a"
# UNVALIDATED, like a `deps` target — a slug for a plan that doesn't exist (yet, or
# ever) is accepted without complaint; a dangling deferred_from is resolved at render
# time by the consumer (plan-track's `(missing)` marker), not by this script.
plan from-c
out="$(ps init from-c --from no-such-plan)"; rc=$?
chk "init --from accepts a dangling slug (unvalidated)" test "$rc" = "0"
chk "init --from stores the dangling slug anyway"       test "$(sidecar from-c '.deferred_from')" = "no-such-plan"
# init never CLEARS deferred_from — same preserve-on-empty contract as --priority/
# --category, and (there being no set-deferred-from subcommand) init --from is the
# ONLY way to write it at all.
ps init from-b --order 2 >/dev/null
chk "init with no --from preserves it"        test "$(sidecar from-b '.deferred_from')" = "from-a"
ps init from-b --from "" >/dev/null
chk "init --from '' preserves (never clears)" test "$(sidecar from-b '.deferred_from')" = "from-a"
# deferred_from survives ordinary writes exactly like priority/category do.
ps set from-b approved >/dev/null
chk "deferred_from survives set <slug> approved" test "$(sidecar from-b '.deferred_from')" = "from-a"
ps claim from-b >/dev/null
chk "deferred_from survives claim"               test "$(sidecar from-b '.deferred_from')" = "from-a"

echo "== K5. init --parent / set-parent: existence + cycle validated (fail-soft, mirrors --deps), clear-on-empty, preserve-on-omit (v2.29.0) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan pt-root '# root' '## Implementation steps' '1. one' '2. two'
plan pt-child
ps init pt-root >/dev/null
out="$(ps init pt-child --parent pt-root)"; rc=$?
chk "init --parent → exit 0"                 test "$rc" = "0"
chk "init --parent echoes it"                has "parent=pt-root" "$out"
chk "init --parent stores it"                test "$(sidecar pt-child '.parent')" = "pt-root"

plan pt-noparent
out="$(ps init pt-noparent --parent no-such-plan)"; rc=$?
chk "init --parent nonexistent → exit 0 (fail-soft)"       test "$rc" = "0"
chk "init --parent nonexistent refused on stderr"           has "does not exist" "$out"
chk "init --parent nonexistent: parent NOT set"             test "$(sidecar pt-noparent '.parent')" = "null"

plan pt-self
out="$(ps init pt-self --parent pt-self --priority high)"; rc=$?
chk "init --parent self-cycle → exit 0 (fail-soft)"         test "$rc" = "0"
chk "init --parent self-cycle refused on stderr"             has "parent cycle" "$out"
chk "init --parent self-cycle: parent NOT set"               test "$(sidecar pt-self '.parent')" = "null"
chk "init --parent self-cycle: sibling flags still applied"  test "$(sidecar pt-self '.priority')" = "high"

# init never CLEARS parent — an empty value preserves, like every other init flag.
ps init pt-child --order 3 >/dev/null
chk "init with no --parent preserves it"        test "$(sidecar pt-child '.parent')" = "pt-root"
ps init pt-child --parent "" >/dev/null
chk "init --parent '' preserves (never clears)" test "$(sidecar pt-child '.parent')" = "pt-root"

plan pt-child2
ps init pt-child2 >/dev/null
out="$(ps set-parent pt-child2 no-such-plan)"; rc=$?
chk "set-parent nonexistent → exit 0 (fail-soft)"           test "$rc" = "0"
chk "set-parent nonexistent refused on stderr"                has "no such plan" "$out"
chk "set-parent nonexistent: no write"                        test "$(sidecar pt-child2 '.parent')" = "null"

out="$(ps set-parent pt-child2 pt-child2)"; rc=$?
chk "set-parent self-cycle → exit 0 (fail-soft)"             test "$rc" = "0"
chk "set-parent self-cycle refused on stderr"                 has "parent cycle" "$out"
chk "set-parent self-cycle: no write"                          test "$(sidecar pt-child2 '.parent')" = "null"

# 2-node cycle: pt-child's parent is already pt-root. Refuse giving pt-root a parent
# of pt-child (would close pt-root → pt-child → pt-root).
out="$(ps set-parent pt-root pt-child)"; rc=$?
chk "set-parent 2-node cycle → exit 0 (fail-soft)"           test "$rc" = "0"
chk "set-parent 2-node cycle refused on stderr"                has "parent cycle" "$out"
chk "set-parent 2-node cycle: no write"                         test "$(sidecar pt-root '.parent')" = "null"

# 3-node cycle: pt-grandchild's parent is pt-child (parent pt-root). Refuse giving
# pt-root a parent of pt-grandchild (pt-root → pt-grandchild → pt-child → pt-root).
plan pt-grandchild
ps init pt-grandchild --parent pt-child >/dev/null
out="$(ps set-parent pt-root pt-grandchild)"; rc=$?
chk "set-parent 3-node transitive cycle → exit 0 (fail-soft)" test "$rc" = "0"
chk "set-parent 3-node cycle refused on stderr"                 has "parent cycle" "$out"
chk "set-parent 3-node cycle: no write"                          test "$(sidecar pt-root '.parent')" = "null"

out="$(ps set-parent pt-child2)"; rc=$?
chk "set-parent with no value → exit 1"      test "$rc" = "1"
out="$(ps set-parent pt-child2 x extra)"; rc=$?
chk "set-parent: extra argument → exit 1"    test "$rc" = "1"
out="$(ps set-parent no-such-plan x)"; rc=$?
chk "set-parent: unknown slug → exit 1"      test "$rc" = "1"

out="$(ps set-parent pt-child "")"; rc=$?
chk "set-parent '' → exit 0"                 test "$rc" = "0"
chk "set-parent '' reports unset"            has "parent = (unset)" "$out"
chk "set-parent '' clears to null"           test "$(sidecar pt-child '.parent')" = "null"
out="$(ps set-parent pt-child pt-root)"; rc=$?
chk "set-parent re-set after a clear → exit 0"   test "$rc" = "0"
chk "set-parent re-set reports the value"        has "parent = pt-root" "$out"
chk "set-parent re-set stores it"                test "$(sidecar pt-child '.parent')" = "pt-root"

echo "== K6. parent survives every other write (set, set-priority, set-category, tick, claim, …); combined group/order + parent matrix (v2.29.0) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan pv-root '# root' '## Implementation steps' '1. one'
plan pv-child '# child' '## Implementation steps' '1. one' '2. two'
ps init pv-root >/dev/null
ps init pv-child --parent pv-root >/dev/null
chk "fixture: pv-child carries a parent"     test "$(sidecar pv-child '.parent')" = "pv-root"

ps set pv-child approved --note "n1" >/dev/null
chk "parent survives set <slug> approved"    test "$(sidecar pv-child '.parent')" = "pv-root"
ps set pv-child in_progress >/dev/null
chk "parent survives a note-clearing set"    test "$(sidecar pv-child '.parent')" = "pv-root"
ps set-deps pv-child pv-root >/dev/null
chk "parent survives set-deps"               test "$(sidecar pv-child '.parent')" = "pv-root"
ps set-priority pv-child high >/dev/null
chk "parent survives set-priority"           test "$(sidecar pv-child '.parent')" = "pv-root"
ps set-category pv-child fix >/dev/null
chk "parent survives set-category"           test "$(sidecar pv-child '.parent')" = "pv-root"
ps tick pv-child 1 >/dev/null
chk "parent survives tick"                   test "$(sidecar pv-child '.parent')" = "pv-root"
ps claim pv-child >/dev/null
chk "parent survives claim"                  test "$(sidecar pv-child '.parent')" = "pv-root"
# …and set-parent is a parent-ONLY write: it must not disturb its neighbours.
ps set pv-child failed --note "broke here" >/dev/null
ps set-parent pv-child pv-root >/dev/null
chk "set-parent preserves the note"          test "$(sidecar pv-child '.note')" = "broke here"
chk "set-parent preserves stored state"      test "$(sidecar pv-child '.state')" = "failed"
chk "set-parent preserves priority"          test "$(sidecar pv-child '.priority')" = "high"
chk "set-parent preserves category"          test "$(sidecar pv-child '.category')" = "fix"
chk "set-parent preserves deps"              test "$(sidecar pv-child '(.deps//[])|join(",")')" = "pv-root"

# Combined axes: one plan carrying BOTH group/order (the /plan-split isolation
# machinery) AND parent (the v2.29.0 nesting machinery) — both survive every write
# neither axis was designed with the other in mind for.
plan cx-parent
plan cx-a
ps init cx-parent >/dev/null
ps init cx-a --group split-group --order 1 --parent cx-parent >/dev/null
chk "combined fixture: group set"    test "$(sidecar cx-a '.group')" = "split-group"
chk "combined fixture: order set"    test "$(sidecar cx-a '.order')" = "1"
chk "combined fixture: parent set"   test "$(sidecar cx-a '.parent')" = "cx-parent"
ps claim cx-a >/dev/null
chk "claim: group survives"          test "$(sidecar cx-a '.group')" = "split-group"
chk "claim: order survives"          test "$(sidecar cx-a '.order')" = "1"
chk "claim: parent survives"         test "$(sidecar cx-a '.parent')" = "cx-parent"
ps set cx-a approved >/dev/null
chk "set approved: group survives"   test "$(sidecar cx-a '.group')" = "split-group"
chk "set approved: order survives"   test "$(sidecar cx-a '.order')" = "1"
chk "set approved: parent survives"  test "$(sidecar cx-a '.parent')" = "cx-parent"
ps set-priority cx-a critical >/dev/null
chk "set-priority: group survives"   test "$(sidecar cx-a '.group')" = "split-group"
chk "set-priority: order survives"   test "$(sidecar cx-a '.order')" = "1"
chk "set-priority: parent survives"  test "$(sidecar cx-a '.parent')" = "cx-parent"
out="$(psout list)"
chk "combined fixture still surfaces in bare 'list' (group/order shape unaffected)" \
  has "cx-a" "$out"

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

echo "== L3. claim keeps category/priority/deferred_from/parent — only origin clears (v2.25.0/v2.29.0) =="
plan clm3-root
ps init clm3-root >/dev/null
plan clm3
ps init clm3 --deferred --priority high --category fix --from some-source --parent clm3-root >/dev/null
chk "clm3 fixture carries priority"        test "$(sidecar clm3 '.priority')" = "high"
chk "clm3 fixture carries category"        test "$(sidecar clm3 '.category')" = "fix"
chk "clm3 fixture carries deferred_from"   test "$(sidecar clm3 '.deferred_from')" = "some-source"
chk "clm3 fixture carries parent"          test "$(sidecar clm3 '.parent')" = "clm3-root"
out="$(ps claim clm3)"; rc=$?
chk "claim → exit 0"                       test "$rc" = "0"
chk "claim clears origin"                  test "$(sidecar clm3 '.origin')" = "null"
chk "claim keeps priority — a claimed stub's triage history stays readable" \
  test "$(sidecar clm3 '.priority')" = "high"
chk "claim keeps category"                 test "$(sidecar clm3 '.category')" = "fix"
chk "claim keeps deferred_from"            test "$(sidecar clm3 '.deferred_from')" = "some-source"
chk "claim keeps parent — a claimed fix must not silently detach from its root" \
  test "$(sidecar clm3 '.parent')" = "clm3-root"

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

echo "== L3. verify <slug>: plan.md structural checks + folded CONTEXT read =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan vf '# Verify test' '' 'Rev 1: initial draft' 'Rev 2: added scope' '' \
  '## Decisions' '' '| A | B |' '|---|---|' '| 1 | 2 |' '' \
  '```bash' 'echo hi' '```'
out="$(ps verify vf)"; rc=$?
chk "verify (clean plan) → exit 0"                 test "$rc" = "0"
chk "..reports fences balanced"                     has "CHECK: fences balanced (2 markers)" "$out"
chk "..reports tables uniform"                      has "CHECK: tables uniform" "$out"
chk "..reports Rev-note order monotonic"            has "CHECK: Rev-note order monotonic (1,2)" "$out"
chk "..reports a context line (informational)"      has "CHECK: context" "$out"

plan vf-fence '# t' '```bash' 'echo hi' '```' '```python' 'never closed'
out="$(ps verify vf-fence)"; rc=$?
chk "verify (unbalanced fence) → exit 1"            test "$rc" = "1"
chk "..names the odd marker count"                  has "CHECK: fences UNBALANCED (3 markers" "$out"

plan vf-table '# t' '| A | B |' '|---|---|' '| 1 | 2 | 3 |'
out="$(ps verify vf-table)"; rc=$?
chk "verify (mismatched table) → exit 1"            test "$rc" = "1"
chk "..names the mismatched line"                   has "CHECK: table pipe-count MISMATCH:" "$out"
chk "..points at the block's start line"            has "line 2: pipe-count mismatch" "$out"

plan vf-revs '# t' '' 'Rev 3: third' 'Rev 1: first' 'Rev 2: second' '' '## Section'
out="$(ps verify vf-revs)"; rc=$?
chk "verify (non-monotonic Rev order) → still exit 0 (informational only)" test "$rc" = "0"
chk "..reports the non-monotonic sequence"          has "CHECK: Rev-note order NOT monotonic (3,1,2)" "$out"

plan vf-norevs '# t' 'No Rev headers here at all — the content spec never mandates one.'
out="$(ps verify vf-norevs)"; rc=$?
chk "verify (no Rev lines at all) → exit 0"         test "$rc" = "0"
chk "..prints no Rev-note CHECK line (never a false positive on an unspec'd format)" \
  hasnt "Rev-note order" "$out"

echo "== L3b. verify <slug>: step-structure checks (Done when: GATES; stray ✅ / ### report) =="
plan vf-steps '# t' '## Implementation steps' '' 'Step 1 — one' '  Done when: `true` exits 0' '' 'Step 2 — two' '  Done when: `true` exits 0' '' '## Verification'
out="$(ps verify vf-steps)"; rc=$?
chk "verify (every step body carries a Done when:) → exit 0" test "$rc" = "0"
chk "..reports the step count"                      has "CHECK: step bodies complete (2 step(s)" "$out"

plan vf-nodw '# t' '## Implementation steps' '' 'Step 1 — one' '  Done when: `true` exits 0' '' 'Step 2 — no criterion at all' '  Goal: something' '' '## Verification'
out="$(ps verify vf-nodw)"; rc=$?
chk "verify (a step body with no Done when:) → exit 1" test "$rc" = "1"
chk "..flags it as INCOMPLETE"                      has "CHECK: step body INCOMPLETE" "$out"
chk "..names the offending step, not just a count"  has "Step 2 — no criterion at all" "$out"

plan vf-nosteps '# t' '## Goal' 'A deferred stub carries no Implementation steps section.'
out="$(ps verify vf-nosteps)"; rc=$?
chk "verify (deferred stub, no steps section) → exit 0" test "$rc" = "0"
chk "..says so rather than reporting zero steps"    has "no ## Implementation steps section" "$out"

plan vf-stray '# t' '## Implementation steps' '' 'Step 1 — one' '  Inputs: Step 0 output. ✅' '  Done when: `true` exits 0' '' '## Verification'
out="$(ps verify vf-stray)"; rc=$?
chk "verify (✅ on a non-step line) → exit 0, informational only" test "$rc" = "0"
chk "..reports the tick the counter cannot see"     has "✅ on a non-step line" "$out"

plan vf-glue '# t' '## Implementation steps' '' 'Step 1 — one' '  Done when: `true` exits 0' '' '### Release' '- ship it' '' '## Verification'
out="$(ps verify vf-glue)"; rc=$?
chk "verify (### inside the steps section) → exit 0, informational only" test "$rc" = "0"
chk "..reports the heading that gets glued on"      has "### heading inside ## Implementation steps" "$out"

# Ties verify to lib/state.sh's `[.]` delimiter (v2.36.0): a wrapped `Inputs:` line
# beginning `48, ` must not read as its own step — under the old `\.` form it did,
# which both inflated the count and stranded the real step's Done when: beneath a
# phantom successor.
plan vf-wrapped '# t' '## Implementation steps' '' 'Step 1 — one' '  Inputs: rows 7, 17, 42,' '    48, 55, 61, 66); final descriptions.' '  Done when: `true` exits 0' '' '## Verification'
out="$(ps verify vf-wrapped)"; rc=$?
chk "verify (wrapped '48, ' continuation) → exit 0" test "$rc" = "0"
chk "..counts one step, not two"                    has "CHECK: step bodies complete (1 step(s)" "$out"

out="$(ps verify)"; rc=$?
chk "verify with no slug → exit 1"                  test "$rc" = "1"
chk "..names the required argument"                 has "a <slug> is required" "$out"

out="$(ps verify nope)"; rc=$?
chk "verify unknown slug → exit 1"                  test "$rc" = "1"
chk "..points at list"                              has "plan-state.sh list" "$out"

mkdir -p "$PLANS/vf-noplanmd"
out="$(ps verify vf-noplanmd)"; rc=$?
chk "verify a plan dir with no plan.md → exit 1"    test "$rc" = "1"
chk "..names the missing file"                      has "no plan.md at" "$out"

out="$(ps verify vf extra)"; rc=$?
chk "verify with a stray extra argument → exit 1"   test "$rc" = "1"

echo "== M. query: the ONE filterable read surface (v2.33.0 — replaced overview --json + subtree) =="
rm -rf "$PLANS" "$REPO/.mentor/handoffs"; mkdir -p "$PLANS"
out="$(psout query)"; rc=$?
chk "query on an empty repo → exit 0" test "$rc" = "0"
chk "query on an empty repo → []"     test "$out" = "[]"

plan ov-a '# a' '## Implementation steps' '1. one ✅' '2. two ✅'
mkdir -p "$PLANS/ov-a/handoffs/resolved"
: > "$PLANS/ov-a/handoffs/live-note.md"
: > "$PLANS/ov-a/handoffs/resolved/old-note.md"
ps init ov-a >/dev/null

plan ov-b '# b' '## Implementation steps' '1. one ✅' '2. two'
# --from is stamped here WITHOUT --deferred — deliberately, to prove `goal` gates on
# `origin == "deferred"`, not on `deferred_from` merely being set.
ps init ov-b --priority critical --category fix --from ov-a >/dev/null
ps set-deps ov-b "ov-a,ov-missing" >/dev/null

# A deferred stub whose `## Goal` first paragraph WRAPS across three physical lines —
# the exact text mentor_plan_goal_line's own unit test in test-state-lib.sh pins, so
# the two suites verify the same reflow+truncation at different layers (lib helper vs.
# the CLI's query plumbing).
plan ov-deferred '# stub' '' '## Goal' '' \
  '`claim_order()` in `daily-run.sh` orders concurrent learn slots by key that' \
  'reflects real lock-acquisition order, so the plan promise that the oldest backlog' \
  'session gets first crack at merging is actually true under three-way concurrency.' '' \
  '## Context' 'more prose here'
ps init ov-deferred --deferred --priority medium --category fix --from ov-a >/dev/null

# A three-level parent chain: ov-a → ov-child → ov-grand. Depth matters — a walk that
# only looks one level down still passes every single-level assertion.
plan ov-child '# child, parented under ov-a (v2.29.0)'
ps init ov-child --parent ov-a >/dev/null
plan ov-grand '# grandchild, parented under ov-child'
ps init ov-grand --parent ov-child >/dev/null

# A deferred fix whose SOURCE plan does not exist — the case `--deferred-from-exists`
# is for, and the one that used to need the whole slug universe rebuilt in jq.
plan ov-orphan '# orphan stub'
ps init ov-orphan --deferred --category fix --from ov-vanished >/dev/null

# Two split-group siblings — `--group` is the only filter with a meaningful EMPTY
# value (`--group ""` means "ungrouped"), so it needs both a grouped and an ungrouped
# plan present to be tested at all.
plan ov-g1 '# sibling 1'
plan ov-g2 '# sibling 2'
ps init ov-g1 --group ov-split --order 1 >/dev/null
ps init ov-g2 --group ov-split --order 2 >/dev/null

mkdir -p "$PLANS/ov-topic/handoffs"
: > "$PLANS/ov-topic/handoffs/nudge.md"

mkdir -p "$REPO/.mentor/handoffs"
: > "$REPO/.mentor/handoffs/legacy-note.md"

out="$(psout query)"; rc=$?
chk "query → exit 0"    test "$rc" = "0"
chk "query → valid JSON" sh -c 'printf "%s" "$0" | jq . >/dev/null 2>&1' "$out"
chk "query → 10 entries (8 plans + plan-less topic + legacy)" test "$(printf '%s' "$out" | jq 'length')" = "10"

ov_a="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-a")')"
chk "ov-a: kind plan"                   test "$(printf '%s' "$ov_a" | jq -r '.kind')" = "plan"
chk "ov-a: effective state implemented" test "$(printf '%s' "$ov_a" | jq -r '.state')" = "implemented"
chk "ov-a: step counts 2/2"             test "$(printf '%s' "$ov_a" | jq -r '.steps.ticked,.steps.total' | tr '\n' ' ')" = "2 2 "
chk "ov-a: live handoff only, resolved excluded" test "$(printf '%s' "$ov_a" | jq -c '.handoffs')" = '["live-note.md"]'
chk "ov-a: no deps"                     test "$(printf '%s' "$ov_a" | jq -c '.deps')" = '[]'
chk "ov-a: origin null"                 test "$(printf '%s' "$ov_a" | jq -r '.origin')" = "null"
chk "ov-a: owner carries this worktree's wt-id (v2.23.0)" test "$(printf '%s' "$ov_a" | jq -r '.owner')" = "$WTA_ID"
chk "ov-a: unprioritized → priority null, never a default tier (v2.24.0)" \
  test "$(printf '%s' "$ov_a" | jq -r '.priority')" = "null"
chk "ov-a: uncategorized → category null (v2.25.0)" test "$(printf '%s' "$ov_a" | jq -r '.category')" = "null"
chk "ov-a: no deferred_from"                        test "$(printf '%s' "$ov_a" | jq -r '.deferred_from')" = "null"
chk "ov-a: goal null on a non-deferred plan"        test "$(printf '%s' "$ov_a" | jq -r '.goal')" = "null"
chk "ov-a: no parent (root-level plan) → parent null" test "$(printf '%s' "$ov_a" | jq -r '.parent')" = "null"

ov_b="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-b")')"
chk "ov-b: step counts 1/2"                  test "$(printf '%s' "$ov_b" | jq -r '.steps.ticked,.steps.total' | tr '\n' ' ')" = "1 2 "
chk "ov-b: deps carry both slugs, in order"  test "$(printf '%s' "$ov_b" | jq -c '.deps | map(.slug)')" = '["ov-a","ov-missing"]'
chk "ov-b: known dep marked not missing"     test "$(printf '%s' "$ov_b" | jq -r '.deps[0].missing')" = "false"
chk "ov-b: unknown dep marked missing"       test "$(printf '%s' "$ov_b" | jq -r '.deps[1].missing')" = "true"
chk "ov-b: no handoffs"                      test "$(printf '%s' "$ov_b" | jq -c '.handoffs')" = '[]'
chk "ov-b: owner carries this worktree's wt-id (v2.23.0)" test "$(printf '%s' "$ov_b" | jq -r '.owner')" = "$WTA_ID"
chk "ov-b: priority carries the tier (v2.24.0)" test "$(printf '%s' "$ov_b" | jq -r '.priority')" = "critical"
chk "ov-b: category carries the kind (v2.25.0)" test "$(printf '%s' "$ov_b" | jq -r '.category')" = "fix"
chk "ov-b: goal null — deferred_from alone does not compute a goal (origin gates it)" \
  test "$(printf '%s' "$ov_b" | jq -r '.goal')" = "null"

echo "-- M1. deferred_from/parent resolve to {slug, missing}, the shape deps[] already had --"
chk "ov-b: deferred_from is an object, not a bare string" \
  test "$(printf '%s' "$ov_b" | jq -r '.deferred_from | type')" = "object"
chk "ov-b: deferred_from.slug carries the source plan" \
  test "$(printf '%s' "$ov_b" | jq -r '.deferred_from.slug')" = "ov-a"
chk "ov-b: deferred_from.missing false — ov-a exists" \
  test "$(printf '%s' "$ov_b" | jq -r '.deferred_from.missing')" = "false"
ov_orph="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-orphan")')"
chk "ov-orphan: deferred_from.missing true — the source plan is gone" \
  test "$(printf '%s' "$ov_orph" | jq -r '.deferred_from.missing')" = "true"
ov_child="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-child")')"
chk "ov-child: kind still plan"                       test "$(printf '%s' "$ov_child" | jq -r '.kind')" = "plan"
chk "ov-child: parent is an object too"               test "$(printf '%s' "$ov_child" | jq -r '.parent | type')" = "object"
chk "ov-child: parent.slug carries the containing plan (v2.29.0)" \
  test "$(printf '%s' "$ov_child" | jq -r '.parent.slug')" = "ov-a"
chk "ov-child: parent.missing false"                  test "$(printf '%s' "$ov_child" | jq -r '.parent.missing')" = "false"

ov_def="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-deferred")')"
chk "ov-deferred: origin deferred"          test "$(printf '%s' "$ov_def" | jq -r '.origin')" = "deferred"
chk "ov-deferred: priority medium"          test "$(printf '%s' "$ov_def" | jq -r '.priority')" = "medium"
chk "ov-deferred: category fix"             test "$(printf '%s' "$ov_def" | jq -r '.category')" = "fix"
chk "ov-deferred: deferred_from.slug ov-a"  test "$(printf '%s' "$ov_def" | jq -r '.deferred_from.slug')" = "ov-a"
chk "ov-deferred: goal reflowed to one line, word-boundary truncated at ~85 chars" \
  test "$(printf '%s' "$ov_def" | jq -r '.goal')" = '`claim_order()` in `daily-run.sh` orders concurrent learn slots by key that reflects…'

ov_topic="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-topic")')"
chk "plan-less topic: kind no_plan_topic"  test "$(printf '%s' "$ov_topic" | jq -r '.kind')" = "no_plan_topic"
chk "plan-less topic: state 'no plan yet'" test "$(printf '%s' "$ov_topic" | jq -r '.state')" = "no plan yet"
chk "plan-less topic: live handoff listed" test "$(printf '%s' "$ov_topic" | jq -c '.handoffs')" = '["nudge.md"]'
chk "plan-less topic: zero step counts"    test "$(printf '%s' "$ov_topic" | jq -c '.steps')" = '{"ticked":0,"total":0}'
chk "plan-less topic: owner null (no sidecar)" test "$(printf '%s' "$ov_topic" | jq -r '.owner')" = "null"
chk "plan-less topic: category/deferred_from/parent/goal all null too (uniform shape)" \
  test "$(printf '%s' "$ov_topic" | jq -r '.category,.deferred_from,.parent,.goal' | tr '\n' ' ')" = "null null null null "

ov_legacy="$(printf '%s' "$out" | jq -c '.[] | select(.kind=="legacy_handoffs")')"
chk "legacy dir: topic-less (slug null)" test "$(printf '%s' "$ov_legacy" | jq -r '.slug')" = "null"
chk "legacy dir: state null"             test "$(printf '%s' "$ov_legacy" | jq -r '.state')" = "null"
chk "legacy dir: steps null"             test "$(printf '%s' "$ov_legacy" | jq -r '.steps')" = "null"
chk "legacy dir: lists the flat note"    test "$(printf '%s' "$ov_legacy" | jq -c '.handoffs')" = '["legacy-note.md"]'
chk "legacy dir: owner null"             test "$(printf '%s' "$ov_legacy" | jq -r '.owner')" = "null"
chk "legacy dir: category/deferred_from/parent/goal all null too (uniform shape)" \
  test "$(printf '%s' "$ov_legacy" | jq -r '.category,.deferred_from,.parent,.goal' | tr '\n' ' ')" = "null null null null "

chk "plan dirs never double as a plan-less topic" \
  test -z "$(printf '%s' "$out" | jq -r '.[] | select(.kind=="no_plan_topic" and (.slug=="ov-a" or .slug=="ov-b"))')"

echo "-- M2. filters: each one against an independent jq over the unfiltered array --"
# Every assertion compares `query <filter>` to the same predicate evaluated in jq over
# the FULL array — so a filter that silently returns everything, or nothing, fails.
# `[.[] | (.slug // "-")]`, never `[.[].slug // "-"]`: jq's `//` yields its default when
# the LEFT side produces no outputs at all, so the second form renders an empty result
# as "-" and quietly turns a broken filter into a passing test.
qslugs() { psout query "$@" | jq -r '[.[] | (.slug // "-")] | sort | join(",")'; }
jslugs() { printf '%s' "$out" | jq -r "[.[] | select($1) | (.slug // \"-\")] | sort | join(\",\")"; }
chk "--kind plan"              test "$(qslugs --kind plan)"          = "$(jslugs '.kind=="plan"')"
chk "--state draft"            test "$(qslugs --state draft)"        = "$(jslugs '.state=="draft"')"
chk "--state draft,implemented ORs within one flag" \
                               test "$(qslugs --state draft,implemented)" = "$(jslugs '.state|IN("draft","implemented")')"
chk "--open"                   test "$(qslugs --open)"               = "$(jslugs '(.state|IN("implemented","superseded"))|not')"
chk "--closed"                 test "$(qslugs --closed)"             = "$(jslugs '.state|IN("implemented","superseded")')"
chk "--priority critical"      test "$(qslugs --priority critical)"  = "$(jslugs '.priority=="critical"')"
chk "--category fix"           test "$(qslugs --category fix)"       = "$(jslugs '.category=="fix"')"
chk "--origin deferred"        test "$(qslugs --origin deferred)"    = "$(jslugs '.origin=="deferred"')"
chk "--parent ov-a"            test "$(qslugs --parent ov-a)"        = "$(jslugs '.parent!=null and .parent.slug=="ov-a"')"
chk "--no-parent"              test "$(qslugs --no-parent)"          = "$(jslugs '.parent==null')"
chk "--group <name>"           test "$(qslugs --group ov-split)"     = "$(jslugs '.group=="ov-split"')"
chk "--group <name> really selects both siblings" test "$(qslugs --group ov-split)" = "ov-g1,ov-g2"
chk "--group \"\" means UNGROUPED, not unfiltered" \
                               test "$(qslugs --group "")"           = "$(jslugs '.group==null')"
chk "--group \"\" is a strict subset (the grouped siblings are excluded)" \
  sh -c 'case ",$0," in *,ov-g1,*) exit 1 ;; *) exit 0 ;; esac' "$(qslugs --group "")"
chk "--group order field survives the round trip" \
                               test "$(psout query --slug ov-g2 --format tsv --fields order)" = "2"
chk "--deferred-from ov-a"     test "$(qslugs --deferred-from ov-a)" = "$(jslugs '.deferred_from!=null and .deferred_from.slug=="ov-a"')"
chk "--deferred-from-exists drops the dangling one" \
                               test "$(qslugs --deferred-from-exists)" = "$(jslugs '.deferred_from!=null and (.deferred_from.missing|not)')"
chk "--deferred-from-exists really excludes ov-orphan" \
  sh -c 'case ",$0," in *,ov-orphan,*) exit 1 ;; *) exit 0 ;; esac' "$(qslugs --deferred-from-exists)"
chk "--owner <this worktree>"  test "$(qslugs --owner "$WTA_ID")"    = "$(jslugs ".owner==\"$WTA_ID\"")"
chk "--unowned"                test "$(qslugs --unowned)"            = "$(jslugs '.owner==null')"
chk "--has-handoff"            test "$(qslugs --has-handoff)"        = "$(jslugs '(.handoffs|length)>0')"
chk "--deps-missing"           test "$(qslugs --deps-missing)"       = "$(jslugs '([.deps[]|select(.missing)]|length)>0')"
chk "--match glob"             test "$(qslugs --match 'ov-d*')"      = "$(jslugs '(.slug//"")|test("^ov-d.*$")')"
chk "--slug picks exactly one" test "$(qslugs --slug ov-b)"          = "ov-b"

# Comma-as-OR is documented for EVERY value-taking filter, but only --state was ever
# covered here — so --group/--parent/--owner compiled to a plain `==` against the whole
# "a,b" string and returned NOTHING, silently, for a comma value. A false empty is the
# worst shape for a read API (it reads as "no matches", not as an error), so each of the
# three is pinned twice: once against a real+bogus pair (which must equal the real value
# alone) and once as a true union, plus a non-empty guard so a filter that breaks by
# returning nothing again cannot pass this vacuously on both sides.
chk "--group ORs within one flag (real + bogus == real alone)" \
                               test "$(qslugs --group ov-split,no-such-group)" = "$(qslugs --group ov-split)"
chk "--group comma form is not silently empty" \
                               test "$(qslugs --group ov-split,no-such-group)" = "ov-g1,ov-g2"
chk "--parent ORs within one flag (union of two real parents)" \
                               test "$(qslugs --parent ov-a,ov-child)" = "$(jslugs '.parent!=null and (.parent.slug|IN("ov-a","ov-child"))')"
chk "--parent comma form is not silently empty" \
                               test "$(qslugs --parent ov-a,ov-child)" = "ov-child,ov-grand"
chk "--owner ORs within one flag (real + bogus == real alone)" \
                               test "$(qslugs --owner "$WTA_ID",no-such-worktree)" = "$(qslugs --owner "$WTA_ID")"
chk "--owner comma form is not silently empty" \
  sh -c '[ -n "$0" ] && [ "$0" != "-" ]' "$(qslugs --owner "$WTA_ID",no-such-worktree)"
# The comma fix must not cost the empty-value selectors their meaning: for --group and
# --owner an empty value still means "the null one", which a naive csv rewrite drops.
chk "--group \"\" still means UNGROUPED after the comma fix" \
                               test "$(qslugs --group "")"  = "$(jslugs '.group==null')"
chk "--owner \"\" still means UNOWNED after the comma fix" \
                               test "$(qslugs --owner "")"  = "$(jslugs '.owner==null')"
chk "two filters AND (intersection, never union)" \
  test "$(qslugs --category fix --origin deferred)" = "$(jslugs '.category=="fix" and .origin=="deferred"')"
chk "AND is never a superset of either operand" \
  sh -c '[ "$(printf "%s" "$0" | tr "," "\n" | grep -c .)" -le "$(printf "%s" "$1" | tr "," "\n" | grep -c .)" ]' \
    "$(qslugs --category fix --origin deferred)" "$(qslugs --category fix)"

echo "-- M3. graph layer: --subtree / --roots / --open-counts, from one parent-graph pass --"
chk "--subtree ov-a → transitive descendants, breadth-first, never ov-a itself" \
  test "$(psout query --subtree ov-a --format slug | tr '\n' ',')" = "ov-child,ov-grand,"
chk "--subtree ov-child → the grandchild only" \
  test "$(psout query --subtree ov-child --format slug | tr '\n' ',')" = "ov-grand,"
chk "--subtree on a leaf → empty" test "$(psout query --subtree ov-grand --format count)" = "0"
chk "--roots → only kind plan with no parent" \
  test "$(psout query --roots --format slug | sort | tr '\n' ',')" = "ov-a,ov-b,ov-deferred,ov-g1,ov-g2,ov-orphan,"
chk "--open-counts: ov-a counts BOTH levels of its chain" \
  test "$(psout query --slug ov-a --open-counts --format tsv --fields open_descendants)" = "2"
chk "--open-counts: ov-child counts its own one descendant" \
  test "$(psout query --slug ov-child --open-counts --format tsv --fields open_descendants)" = "1"
chk "--open-counts: a leaf counts 0" \
  test "$(psout query --slug ov-grand --open-counts --format tsv --fields open_descendants)" = "0"
ps set ov-grand implemented >/dev/null
chk "--open-counts: closing the leaf drops the root's count (open ≠ merely present)" \
  test "$(psout query --slug ov-a --open-counts --format tsv --fields open_descendants)" = "1"
chk "--subtree still lists the CLOSED descendant (membership is structural)" \
  test "$(psout query --subtree ov-a --format count)" = "2"
ps set ov-grand draft >/dev/null
chk "--open-counts absent unless asked for" \
  test "$(psout query --slug ov-a | jq -r '.[0] | has("open_descendants")')" = "false"

echo "-- M4. output layer: --format / --fields / --sort / --limit --"
chk "--format count equals --format slug | wc -l" \
  test "$(psout query --kind plan --format count)" = "$(psout query --kind plan --format slug | wc -l | tr -d ' ')"
chk "--format slug omits the slugless legacy entry rather than inventing a placeholder" \
  test "$(psout query --kind legacy_handoffs --format slug)" = ""
chk "--format tsv: one row per entry"  test "$(psout query --format tsv | wc -l | tr -d ' ')" = "$(psout query --format count)"
chk "--format tsv: default 4 columns"  test "$(psout query --format tsv | head -1 | awk -F'\t' '{print NF}')" = "4"
chk "--format tsv: null renders as the - placeholder, never an empty field" \
  test "$(psout query --slug ov-a --format tsv --fields slug,group)" = "$(printf 'ov-a\t-')"
chk "--format table: prints a header row" has "STATE" "$(psout query --format table)"
chk "--fields dot path pulls one nested scalar" \
  test "$(psout query --slug ov-b --format tsv --fields steps.total)" = "2"
chk "--fields dot path reaches into a ref object" \
  test "$(psout query --slug ov-child --format tsv --fields parent.slug)" = "ov-a"
chk "--fields json projection emits ONLY the requested keys" \
  test "$(psout query --slug ov-b --fields steps.total | jq -c '.[0]|keys')" = '["steps.total"]'
chk "--limit truncates"    test "$(psout query --limit 2 --format count)" = "2"
chk "--limit 0 is empty"   test "$(psout query --limit 0 --format count)" = "0"
chk "--sort slug ascends"  test "$(psout query --kind plan --sort slug --format slug | tr '\n' ',')" = "$(psout query --kind plan --format slug | sort | tr '\n' ',')"
out="$(ps query --format bogus)"; rc=$?
chk "--format rejects an unknown value (exit 1)"        test "$rc" = "1"
chk "--format error names the valid set"                has "json|table|slug|count|tsv" "$out"
ps query --limit abc >/dev/null 2>&1; rc=$?
chk "--limit rejects a non-integer (exit 1)"            test "$rc" = "1"
out="$(ps query --state)"; rc=$?
chk "a flag missing its value is a usage error"         test "$rc" = "1"
chk "  ...and says which flag"                          has -- "--state needs a value" "$out"
ps query --slug ov-a --subtree ov-a >/dev/null 2>&1; rc=$?
chk "--slug and --subtree together are refused"         test "$rc" = "1"
ps query --open --closed >/dev/null 2>&1; rc=$?
chk "--open and --closed together are refused"          test "$rc" = "1"
ps query --frobnicate >/dev/null 2>&1; rc=$?
chk "an unknown flag is a usage error"                  test "$rc" = "1"
ps query --slug nope >/dev/null 2>&1; rc=$?
chk "--slug on a nonexistent plan is a usage error"     test "$rc" = "1"

echo "-- M5. --kind handoff: notes as first-class items, opt-in only --"
chk "bare query returns NO handoff entries" \
  test "$(psout query | jq '[.[]|select(.kind=="handoff")]|length')" = "0"
disk_notes="$(find "$REPO/.mentor" -type f -name '*.md' -path '*/handoffs/*' | wc -l | tr -d ' ')"
chk "--kind handoff count equals the on-disk note count (live AND resolved)" \
  test "$(psout query --kind handoff --format count)" = "$disk_notes"
chk "--kind handoff: live/resolved both present and labelled" \
  test "$(psout query --kind handoff | jq -r '[.[].handoff_state]|unique|join(",")')" = "live,resolved"
chk "--kind handoff: a note carries its topic" \
  test "$(psout query --kind handoff | jq -r 'map(select(.path|endswith("live-note.md")))[0].topic')" = "ov-a"
chk "--kind handoff: the legacy flat note has a null topic" \
  test "$(psout query --kind handoff | jq -r 'map(select(.path|endswith("legacy-note.md")))[0].topic')" = "null"
chk "--kind handoff: path is repo-relative, not absolute" \
  test "$(psout query --kind handoff | jq -r '[.[]|select(.path|startswith("/"))]|length')" = "0"
chk "--kind handoff: mtime is an ISO-8601 Z timestamp" \
  sh -c 'printf "%s" "$0" | jq -e "all(.[]; .mtime|test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$\"))" >/dev/null' \
    "$(psout query --kind handoff)"
chk "--kind handoff: the resolved/ note is labelled, not dropped (anchored exclusion)" \
  test "$(psout query --kind handoff | jq -r '[.[]|select(.handoff_state=="resolved")]|length')" = "1"
chk "--kind handoff: that resolved note is the one under ov-a/handoffs/resolved/" \
  test "$(psout query --kind handoff | jq -r 'map(select(.handoff_state=="resolved"))[0].path|endswith("resolved/old-note.md")')" = "true"
chk "a plan entry's own handoffs array still excludes resolved notes" \
  test "$(psout query --slug ov-a | jq -c '.[0].handoffs')" = '["live-note.md"]'

echo "== N. query is fail-soft when jq is absent from PATH =="
out="$(psq_nojq_out query)"
err="$(psq_nojq_err query)"
rc=0; psq_nojq_rc query || rc=$?
chk "no jq → exit 0"                  test "$rc" = "0"
chk "no jq → empty stdout"            test -z "$out"
chk "no jq → one-line stderr notice"  test "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = "1"
chk "no jq → notice names the problem" has "jq not found" "$err"

echo "== N2. overview and subtree are RETIRED: they fail loudly and name query, never no-op =="
for retired in overview subtree; do
  out="$(ps "$retired" --json)"; rc=$?
  chk "$retired → exit 1 (not a silent success)" test "$rc" = "1"
  chk "$retired → says it was retired"           has "was retired" "$out"
  chk "$retired → names query as the replacement" has "query" "$out"
  chk "$retired → is NOT reported as an unknown subcommand" hasnt "Unknown subcommand" "$out"
done
out="$(ps subtree ov-a)"; rc=$?
chk "subtree <slug> → exit 1 even with a real slug"      test "$rc" = "1"
chk "subtree <slug> → points at the --subtree flag"      has -- "--subtree" "$out"
chk "subtree <slug> → also points at --roots --open-counts for the all-roots case" \
  has -- "--roots --open-counts" "$out"
out="$(ps)"; 
chk "usage block lists query"                   has "query \[select\]" "$out"
chk "usage block no longer lists overview"      hasnt "^  overview " "$out"
chk "usage block no longer lists subtree"       hasnt "^  subtree " "$out"
# The whole point of retiring them: ov-b keeps its priority for section O below.
ps init ov-b --priority critical >/dev/null

echo "== O. list stays byte-compatible even when a plan carries deps/origin/priority/category/deferred_from (v2.25.0: 3 more append-last fields) =="
ps init ov-b --deferred >/dev/null   # give ov-b an origin too, alongside its deps
chk "the fixture plan really does carry a priority" test "$(sidecar ov-b '.priority')" = "critical"
chk "the fixture plan really does carry a category (v2.25.0)"      test "$(sidecar ov-b '.category')" = "fix"
chk "the fixture plan really does carry a deferred_from (v2.25.0)" test "$(sidecar ov-b '.deferred_from')" = "ov-a"
out="$(psout list)"
row="$(printf '%s' "$out" | awk -v s="ov-b" '$3 == s')"
chk "row for a deps+origin+priority+category+deferred_from plan is still found" test -n "$row"
chk "row is still exactly 5 whitespace-separated columns" \
  test "$(printf '%s' "$row" | awk '{print NF}')" = "5"
chk "row carries no stray JSON from deps/origin" \
  sh -c '! printf "%s" "$0" | grep -qE "[][{}]"' "$row"
chk "row carries no stray text from category/deferred_from either" \
  sh -c '! printf "%s" "$0" | grep -qE "fix|ov-a"' "$row"

# Byte-compat proper: a fixture WITHOUT any of the new fields set produces the exact
# same bare `list` row today as before this plan's row-append (fields 12-14) landed —
# proving the 3 appended _plan_walk fields never disturb list_rows' 5-column shape.
plan byte-compat
ps init byte-compat >/dev/null
row_plain="$(psout list | awk -v s="byte-compat" '$3 == s')"
chk "row-append safety: an unset-new-fields plan's bare list row is exactly 5 columns" \
  test "$(printf '%s' "$row_plain" | awk '{print NF}')" = "5"
chk "row-append safety: that row matches the pre-v2.25.0 shape exactly" \
  test "$(printf '%s' "$row_plain" | awk '{print $2, $3, $4, $5}')" = "draft byte-compat - -"

echo "== O2. list --owners adds a 6th OWNER column; bare list stays 5 (v2.23.0) =="
row_default="$(psout list | awk -v s="ov-b" '$3 == s')"
chk "list (default) row is still exactly 5 columns" test "$(printf '%s' "$row_default" | awk '{print NF}')" = "5"
row_owners="$(psout list --owners | awk -v s="ov-b" '$3 == s')"
chk "list --owners row is exactly 6 columns"      test "$(printf '%s' "$row_owners" | awk '{print NF}')" = "6"
chk "list --owners 6th column is the owner wt-id" test "$(printf '%s' "$row_owners" | awk '{print $6}')" = "$WTA_ID"

echo "== O3. list --parent adds its own PARENT column; composes with --owners in fixed order (v2.29.0) =="
row_parent="$(psout list --parent | awk -v s="ov-child" '$3 == s')"
chk "list --parent row is exactly 6 columns"        test "$(printf '%s' "$row_parent" | awk '{print NF}')" = "6"
chk "list --parent 6th column is the parent slug"   test "$(printf '%s' "$row_parent" | awk '{print $6}')" = "ov-a"
row_noparent="$(psout list --parent | awk -v s="ov-a" '$3 == s')"
chk "a plan with no parent shows '-' in the PARENT column" test "$(printf '%s' "$row_noparent" | awk '{print $6}')" = "-"
row_both="$(psout list --owners --parent | awk -v s="ov-child" '$3 == s')"
chk "list --owners --parent composes: 7 columns"     test "$(printf '%s' "$row_both" | awk '{print NF}')" = "7"
chk "..6th column owner, 7th column parent (fixed order)" \
  test "$(printf '%s' "$row_both" | awk '{print $6, $7}')" = "$WTA_ID ov-a"
row_default2="$(psout list | awk -v s="ov-child" '$3 == s')"
chk "bare list stays 5 columns even when the plan carries a parent" \
  test "$(printf '%s' "$row_default2" | awk '{print NF}')" = "5"

echo "== P. gate: read-only plan-gate marker status, before every guard (v2.23.0 4-token contract) =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
chk "no marker anywhere → RELEASED"            test "$(psout gate)" = "RELEASED"

: > "$OWN_MARKER"
chk "own marker live → ARMED"                  test "$(psout gate)" = "ARMED"
rm -f "$OWN_MARKER"

: > "$LEGACY_MARKER"
chk "legacy marker live → ARMED"               test "$(psout gate)" = "ARMED"
rm -f "$LEGACY_MARKER"

: > "$SIB_MARKER"
chk "sibling-only live → ARMED_ELSEWHERE"      test "$(psout gate)" = "ARMED_ELSEWHERE"

: > "$OWN_MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$OWN_MARKER" 2>/dev/null || true
chk "own-stale + sibling-live → STALE (own_exists outranks the sibling check)" \
  test "$(psout gate)" = "STALE"
chk "gate never deletes the own marker"        test -e "$OWN_MARKER"
chk "gate never deletes the sibling marker"    test -e "$SIB_MARKER"
rm -f "$OWN_MARKER" "$SIB_MARKER"

CWD="$BARE"
chk "gate in a never-planned repo → RELEASED"  test "$(psout gate)" = "RELEASED"
CWD="$NONGIT"
chk "gate outside a repo → RELEASED"           test "$(psout gate)" = "RELEASED"
CWD="$REPO"
out="$(ps gate extra)"; rc=$?
chk "gate rejects a stray argument → exit 1"   test "$rc" = "1"
chk "gate rejects a stray argument → names it" has "unexpected argument" "$out"

echo "== P2. gate --verbose: ARMED (own marker) — exactly marker/owner_session/owner_cwd/owner_worktree/age_min/affected_plans, ownership-filtered =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
plan gv-old "old plan — written BEFORE the marker, must not show as affected"
sleep 1
{ echo "session=test-session-xyz"; echo "cwd=/some/other/repo"; echo "worktree=$REPO"; } > "$OWN_MARKER"
sleep 1
plan gv-new "new plan — written AFTER the marker, exactly what approve-plan.sh would promote"
ps init gv-new >/dev/null   # owned by THIS worktree — must appear in affected_plans
plan gv-b-owned "written after the marker too, but owned by the sibling worktree — must be excluded (ownership-filtered)"
CWD="$WTB"; ps init gv-b-owned >/dev/null; CWD="$REPO"
out="$(psout gate --verbose)"
chk "gate --verbose (own): line 1 is still the bare token" \
  test "$(printf '%s\n' "$out" | sed -n '1p')" = "ARMED"
chk "gate --verbose (own): exactly 7 lines total (token + 6 fields)" \
  test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "7"
chk "gate --verbose (own): field order/names are exactly the normative six" \
  test "$(printf '%s\n' "$out" | sed -n '2,7p' | sed -E 's/=.*//' | tr '\n' ',')" \
  = "marker,owner_session,owner_cwd,owner_worktree,age_min,affected_plans,"
chk "gate --verbose (own): reports the marker path"     has "marker=${OWN_MARKER}" "$out"
chk "gate --verbose (own): reports the owning session"  has "owner_session=test-session-xyz" "$out"
chk "gate --verbose (own): reports the owning cwd"      has "owner_cwd=/some/other/repo" "$out"
chk "gate --verbose (own): reports the owning worktree" has "owner_worktree=${REPO}" "$out"
chk "gate --verbose (own): reports a numeric age" \
  sh -c 'printf "%s" "$0" | grep -qE "age_min=[0-9]+"' "$out"
chk "gate --verbose (own): affected_plans is ownership-filtered to gv-new only" \
  test "$(printf '%s\n' "$out" | grep '^affected_plans=')" = "affected_plans=gv-new"
rm -rf "$PLANS/gv-old" "$PLANS/gv-new" "$PLANS/gv-b-owned" "$OWN_MARKER"

echo "== P3. gate --verbose: ARMED (legacy marker) — affected_plans UNFILTERED, mirroring approve-plan.sh's legacy_mode =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
{ echo "session=legacy-sess"; echo "cwd=/legacy/cwd"; } > "$LEGACY_MARKER"
sleep 1
plan lg-a-owned "owned by this worktree"
ps init lg-a-owned >/dev/null
plan lg-b-owned "owned by the sibling worktree"
CWD="$WTB"; ps init lg-b-owned >/dev/null; CWD="$REPO"
plan lg-unowned "never init'd — unowned"
out="$(psout gate --verbose)"
chk "gate --verbose (legacy): line 1 ARMED"        test "$(printf '%s\n' "$out" | sed -n '1p')" = "ARMED"
chk "gate --verbose (legacy): marker= is the bare legacy path" has "marker=${LEGACY_MARKER}" "$out"
chk "gate --verbose (legacy): affected_plans includes ALL three, unfiltered by ownership" \
  sh -c 'line=$(printf "%s\n" "$0" | grep "^affected_plans="); sorted=$(printf "%s" "${line#affected_plans=}" | tr " " "\n" | sort | tr "\n" ","); [ "$sorted" = "lg-a-owned,lg-b-owned,lg-unowned," ]' "$out"
rm -f "$LEGACY_MARKER"; rm -rf "$PLANS/lg-a-owned" "$PLANS/lg-b-owned" "$PLANS/lg-unowned"

echo "== P4. gate --verbose: ARMED_ELSEWHERE — one elsewhere= line per live sibling, nothing else =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
{ echo "session=sib-sess-b"; echo "cwd=$WTB"; echo "worktree=$WTB"; } > "$SIB_MARKER"
{ echo "session=sib-sess-c"; echo "cwd=$WTC"; echo "worktree=$WTC"; } > "$SIB_MARKER_C"
out="$(psout gate --verbose)"
chk "gate --verbose (elsewhere): line 1 ARMED_ELSEWHERE" test "$(printf '%s\n' "$out" | sed -n '1p')" = "ARMED_ELSEWHERE"
chk "gate --verbose (elsewhere): exactly 3 lines total (token + one per sibling)" \
  test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "3"
chk "gate --verbose (elsewhere): sibling B's line present with all four fields" \
  has "elsewhere=${WTB_ID} session=sib-sess-b worktree=${WTB} age_min=" "$out"
chk "gate --verbose (elsewhere): sibling C's line present with all four fields" \
  has "elsewhere=${WTC_ID} session=sib-sess-c worktree=${WTC} age_min=" "$out"
rm -f "$SIB_MARKER" "$SIB_MARKER_C"

echo "== P5. gate --verbose on STALE/RELEASED: still exactly the bare token, no fields =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
chk "gate --verbose on RELEASED: still exactly one line" \
  test "$(psout gate --verbose | wc -l | tr -d ' ')" = "1"
chk "gate --verbose on RELEASED: bare token" \
  test "$(psout gate --verbose)" = "RELEASED"
: > "$OWN_MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$OWN_MARKER" 2>/dev/null || true
chk "gate --verbose on STALE: still exactly one line" \
  test "$(psout gate --verbose | wc -l | tr -d ' ')" = "1"
chk "gate --verbose on STALE: bare token" \
  test "$(psout gate --verbose)" = "STALE"
rm -f "$OWN_MARKER"

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

# Regression for the before_stored fix: a plan whose ✅ ticks alone already self-heal
# mentor_plan_effective_state to "implemented" — with NO prior `set` call, so the
# sidecar was never actually written — must still get this reminder on its real
# first `set … implemented`. Pre-fix, `before` (effective) already read "implemented"
# here, `before == state`, and the whole block was skipped as a false idempotent
# re-close.
tx_agent_only
plan cc-selfheal '## Implementation steps' '1. one ✅' '2. two ✅'
merged="$(ps set cc-selfheal implemented)"; rc=$?
chk "ticks alone self-heal effective state → reminder still fires" has "Closing checklist" "$merged"
chk "self-heal case → still reports the state transition"          has "implemented → implemented" "$merged"
chk "self-heal reminder path still exits 0"                        test "$rc" = "0"

echo "== R. set … implemented: verification-artifact reminder (verification_artifact_reminder) =="
tx_no_agent   # this section only cares about the verification line, not the checklist above it
plan va-empty '# a' '## Implementation steps' '1. one'
out="$(ps set va-empty implemented)"
chk "no Verification section at all → silent"        hasnt "not actually verified yet" "$out"

plan va-blank '# a' '## Implementation steps' '1. one' '## Verification' '' '## Notes' 'x'
out="$(ps set va-blank implemented)"
chk "empty Verification section (blank before next ##) → silent" hasnt "not actually verified yet" "$out"

plan va-missing '# a' '## Implementation steps' '1. one' \
  '## Verification' '1. real criteria, never actually checked'
out="$(ps set va-missing implemented)"
chk "non-empty Verification, no *verify.md → warning fires"      has "not actually verified yet" "$out"
chk "warning → names the plan dir"                                has "$PLANS/va-missing" "$out"
chk "warning → cites the no-self-check rule"                      has "never a main-thread self-check" "$out"
chk "warning path still exits 0"                                  test "$?" = "0"

plan va-present '# a' '## Implementation steps' '1. one' \
  '## Verification' 'Topic 1 — real criteria'
: > "$PLANS/va-present/topic-1-verify.md"
out="$(ps set va-present implemented)"
chk "non-empty Verification, *verify.md present → silent"        hasnt "not actually verified yet" "$out"

plan va-legacy '# a' '## Implementation steps' '1. one' \
  '## Verification' '1. legacy prose criterion, derived into a topic at dispatch time'
: > "$PLANS/va-legacy/topic-1-verify.md"   # legacy prose derives topics too — same verifier naming
out="$(ps set va-legacy implemented)"
chk "legacy prose Verification, derived topic-verify.md present → silent" hasnt "not actually verified yet" "$out"

plan va-failed '# a' '## Implementation steps' '1. one' \
  '## Verification' '1. real criteria, never checked'
out="$(ps set va-failed failed --note "blocked")"
chk "transition to failed (not implemented) → no verification warning" hasnt "not actually verified yet" "$out"

plan va-refire '# a' '## Implementation steps' '1. one' \
  '## Verification' '1. real criteria, never checked'
ps set va-refire implemented >/dev/null           # first close — the fresh transition
out="$(pserr set va-refire implemented)"          # idempotent re-close (e.g. ship re-running set)
chk "idempotent re-close → no re-fired verification warning" hasnt "not actually verified yet" "$out"

echo "== S. set … implemented: tick-reconciliation reminder (tick_reconciliation_reminder) =="
plan tr-partial '## Implementation steps' '1. one ✅' '2. two' '3. three'
merged="$(ps set tr-partial implemented)"; rc=$?
chk "1/3 ticked → warning fires"                    has "steps ticked" "$merged"
chk "warning → names the ratio"                     has "1/3 steps ticked" "$merged"
chk "warning → names the plan slug"                 has "tr-partial" "$merged"
chk "warning → gives the tick remediation command"  has "plan-state.sh tick tr-partial" "$merged"
chk "reminder path still exits 0"                   test "$rc" = "0"

# The reminder gate is judged off the STORED sidecar (before_stored), not the
# tick-derived effective read, so a plan whose ✅ ticks alone would already self-heal
# the effective state to "implemented" still reaches this function on its first real
# `set … implemented` — no detour through another stored state required.
plan tr-full '## Implementation steps' '1. one ✅' '2. two ✅'
out="$(ps set tr-full implemented)"
chk "2/2 ticked (no prior close) → silent"          hasnt "steps ticked" "$out"

plan tr-empty '## Notes' 'no Implementation steps section at all'
out="$(ps set tr-empty implemented)"
chk "no recognizable step lines (0 total) → silent" hasnt "steps ticked" "$out"

plan tr-failed '## Implementation steps' '1. one' '2. two'
out="$(ps set tr-failed failed --note "blocked")"
chk "transition to failed (not implemented) → silent" hasnt "steps ticked" "$out"

plan tr-refire '## Implementation steps' '1. one'
ps set tr-refire implemented >/dev/null            # first close — the fresh transition
out="$(pserr set tr-refire implemented)"           # idempotent re-close (e.g. ship re-running set)
chk "idempotent re-close → no re-fired tick warning" hasnt "steps ticked" "$out"

echo "== T. query --subtree / --open-counts: transitive descendants via parent chains, open/closed verdicts, counts (v2.33.0, was `subtree`) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan st-root '# root' '## Implementation steps' '1. one' '2. two'
plan st-child '# child' '## Implementation steps' '1. one' '2. two'
plan st-grandchild '# grandchild' '## Implementation steps' '1. one' '2. two'
plan st-other
ps init st-root >/dev/null
ps init st-child --parent st-root >/dev/null
ps init st-grandchild --parent st-child >/dev/null
ps init st-other >/dev/null

# `subtree <slug>` printed an indented tree plus a trailing "N open descendant(s)." line;
# `query --subtree` returns the same descendant SET as data, and `--open-counts` returns
# the same N as a field. Depth is no longer rendered as indentation — a consumer that
# wants the branch shape reads each entry's own `parent`, which is the same
# consumer-side reconstruction lib/state.sh's mentor_plan_descendants always documented.
out="$(psout query --subtree st-other --format count)"; rc=$?
chk "--subtree with no descendants → exit 0"    test "$rc" = "0"
chk "--subtree with no descendants → count 0"   test "$out" = "0"

out="$(psout query --subtree st-root)"; rc=$?
chk "--subtree → exit 0"                        test "$rc" = "0"
chk "--subtree lists the direct child"          has "st-child" "$out"
chk "--subtree lists the transitive grandchild" has "st-grandchild" "$out"
chk "--subtree returns breadth-first: child before grandchild" \
  test "$(psout query --subtree st-root --format slug | tr '\n' ',')" = "st-child,st-grandchild,"
chk "--subtree never includes the root itself" \
  sh -c 'case ",$0," in *,st-root,*) exit 1 ;; *) exit 0 ;; esac' "$(psout query --subtree st-root --format slug | tr '\n' ',')"
chk "both descendants are open (draft, not implemented/superseded)" \
  test "$(psout query --subtree st-root --open --format count)" = "2"
chk "--open-counts reports the same N the trailing count used to" \
  test "$(psout query --slug st-root --open-counts --format tsv --fields open_descendants)" = "2"
chk "depth is readable from each entry's own parent field" \
  test "$(psout query --subtree st-root --format tsv --fields slug,parent.slug | tr '\n' ';')" \
     = "$(printf 'st-child\tst-root;st-grandchild\tst-child;')"

# Close the grandchild → it verdicts closed, the open count drops to 1.
ps set st-grandchild implemented >/dev/null
chk "closing the grandchild flips its own verdict to closed" \
  test "$(psout query --subtree st-root --closed --format slug)" = "st-grandchild"
chk "open count now reflects only the still-open child" \
  test "$(psout query --slug st-root --open-counts --format tsv --fields open_descendants)" = "1"

# Close the direct child too → zero open, but descendants still list.
ps set st-child implemented >/dev/null
chk "all descendants closed → open count 0" \
  test "$(psout query --slug st-root --open-counts --format tsv --fields open_descendants)" = "0"
chk "closed descendants still listed (membership is structural, not a verdict)" \
  test "$(psout query --subtree st-root --format count)" = "2"

rc=0; ps query --subtree no-such-plan >/dev/null 2>&1 || rc=$?
chk "--subtree unknown slug → exit 1"           test "$rc" = "1"
rc=0; ps query --subtree >/dev/null 2>&1 || rc=$?
chk "--subtree with no value → exit 1"          test "$rc" = "1"
rc=0; ps query --subtree st-root extra >/dev/null 2>&1 || rc=$?
chk "--subtree with a stray extra argument → exit 1" test "$rc" = "1"

echo "== U. set <slug> implemented: unconditional soft WARN when open descendants exist (write still succeeds); no warn once all close (v2.29.0) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan wr-root
plan wr-child-a
plan wr-child-b
ps init wr-root >/dev/null
ps init wr-child-a --parent wr-root >/dev/null
ps init wr-child-b --parent wr-root >/dev/null

out="$(ps set wr-root implemented)"; rc=$?
chk "set implemented with open descendants → exit 0 (write still succeeds)" test "$rc" = "0"
chk "..the write actually landed"                     test "$(state_of wr-root)" = "implemented"
chk "..prints the soft WARN with the open count"      has "WARN: 2 open descendant(s)" "$out"
chk "..the WARN names wr-child-a"                      has "wr-child-a" "$out"
chk "..the WARN names wr-child-b"                      has "wr-child-b" "$out"

# Close one descendant → the warn count drops but still fires (one remains open).
ps set wr-child-a implemented >/dev/null
out="$(pserr set wr-root implemented)"   # idempotent re-close of wr-root itself
chk "one descendant closed → WARN count drops to 1"   has "WARN: 1 open descendant(s)" "$out"
chk "..no longer names the now-closed child"          hasnt "wr-child-a" "$out"
chk "..still names the still-open child"              has "wr-child-b" "$out"

# Close the last one → no WARN at all, even on a re-close.
ps set wr-child-b implemented >/dev/null
out="$(pserr set wr-root implemented)"
chk "every descendant closed → no WARN"                hasnt "open descendant(s)" "$out"

# A plan with no descendants at all never warns.
plan wr-leaf
ps init wr-leaf >/dev/null
out="$(pserr set wr-leaf implemented)"
chk "no descendants at all → no WARN"                  hasnt "open descendant(s)" "$out"

# Transitioning to a state OTHER than implemented never triggers this warn, even with
# open descendants.
plan wr-root2
plan wr-child2
ps init wr-root2 >/dev/null
ps init wr-child2 --parent wr-root2 >/dev/null
out="$(pserr set wr-root2 approved)"
chk "set to a non-implemented state → no WARN, ever"   hasnt "open descendant(s)" "$out"

echo "== V. relocate <src-plan-dir>: copy a plan from a DIFFERENT repo into this one, re-own it here (v2.29.0 — previously zero coverage) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
SRC_REPO="$ROOT/src-repo"
git init -q -b main "$SRC_REPO" >/dev/null 2>&1
( cd "$SRC_REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
SRC_PLANS="$SRC_REPO/.mentor/plans"
mkdir -p "$SRC_PLANS/rl-slug"
printf '# Relocate me\n\n## Implementation steps\n1. one\n\n## Suggested first steps\n- src/somefile.ts\n- lib/other.py\n' > "$SRC_PLANS/rl-slug/plan.md"
CWD="$SRC_REPO"; ps init rl-slug --priority high >/dev/null; CWD="$REPO"

out="$(ps relocate "$SRC_PLANS/rl-slug")"; rc=$?
chk "relocate → exit 0"                              test "$rc" = "0"
chk "relocate reports the move"                      has "relocated from" "$out"
chk "relocate copied plan.md"                        test -f "$PLANS/rl-slug/plan.md"
chk "relocate copied .state.json"                    test -f "$PLANS/rl-slug/.state.json"
chk "relocate preserves unrelated fields (priority)" test "$(sidecar rl-slug '.priority')" = "high"
chk "relocate re-owns to this worktree"              test "$(sidecar rl-slug '.owner')" = "$WTA_ID"
chk "relocate never deletes the source"              test -f "$SRC_PLANS/rl-slug/plan.md"
chk "relocate reports the source is kept"            has "source NOT deleted" "$out"
chk "relocate warns about the source gate (informational)" \
  has "if the source repo's plan-gate marker is still armed" "$out"
# "Suggested first steps" names repo-relative-looking paths → the stale-paths WARNING.
chk "relocate flags stale-looking paths in Suggested first steps" \
  has "still names repo-relative paths that may be stale" "$out"
chk "..lists the paths it found"                     has "src/somefile.ts" "$out"

echo "== V2. relocate: no 'Suggested first steps' section — must complete without aborting (pre-existing set -euo pipefail bug fixed alongside v2.29.0) =="
mkdir -p "$SRC_PLANS/rl-nosteps"
printf '# No suggested steps here\n\n## Implementation steps\n1. one\n' > "$SRC_PLANS/rl-nosteps/plan.md"
CWD="$SRC_REPO"; ps init rl-nosteps >/dev/null; CWD="$REPO"
out="$(ps relocate "$SRC_PLANS/rl-nosteps")"; rc=$?
chk "relocate (no Suggested first steps section) → exit 0, does not abort" test "$rc" = "0"
chk "relocate (no Suggested first steps) still relocated"                  test -f "$PLANS/rl-nosteps/plan.md"
chk "relocate (no Suggested first steps) → no stale-paths warning printed" \
  hasnt "still names repo-relative paths" "$out"

echo "== V3. relocate: children left in the source repo → warns (does NOT copy the subtree) =="
mkdir -p "$SRC_PLANS/rl-parent"
printf '# Parent to relocate\n\n## Implementation steps\n1. one\n' > "$SRC_PLANS/rl-parent/plan.md"
CWD="$SRC_REPO"
ps init rl-parent >/dev/null
mkdir -p "$SRC_PLANS/rl-parent-child"
printf '# Child stays behind\n\n## Implementation steps\n1. one\n' > "$SRC_PLANS/rl-parent-child/plan.md"
ps init rl-parent-child --parent rl-parent >/dev/null
CWD="$REPO"
out="$(ps relocate "$SRC_PLANS/rl-parent")"; rc=$?
chk "relocate (with a child left behind) → exit 0" test "$rc" = "0"
chk "relocate warns about the child left in the source" has "has children still only in the SOURCE repo" "$out"
chk "..names the child slug"                            has "rl-parent-child" "$out"
chk "relocate does NOT copy the child"                  test ! -e "$PLANS/rl-parent-child"
chk "the child is still in the source, untouched"       test -f "$SRC_PLANS/rl-parent-child/plan.md"

echo "== V4. relocate: usage/edge-case errors =="
out="$(ps relocate)"; rc=$?
chk "relocate with no src → exit 1"            test "$rc" = "1"
out="$(ps relocate "$SRC_PLANS/rl-slug" extra)"; rc=$?
chk "relocate with a stray extra arg → exit 1" test "$rc" = "1"
out="$(ps relocate "$SRC_PLANS/does-not-exist")"; rc=$?
chk "relocate: nonexistent source → exit 1"    test "$rc" = "1"
out="$(ps relocate "$SRC_PLANS/rl-slug")"; rc=$?   # already relocated once in section V
chk "relocate: destination already exists → exit 1" test "$rc" = "1"
chk "..names the collision"                          has "already exists" "$out"
mkdir -p "$SRC_PLANS/rl-notaplan"    # missing plan.md/.state.json
out="$(ps relocate "$SRC_PLANS/rl-notaplan")"; rc=$?
chk "relocate: not a real plan dir → exit 1"   test "$rc" = "1"
chk "..names the reason"                        has "not a real plan dir" "$out"

echo "== W. start <slug>: ensure-dir + init + claim in ONE call (v2.34.0) =="
# The contract that matters is stdout purity: callers write
# `plan_md="$(plan-state.sh start "$slug")"`, so anything init or claim print has to go
# to stderr or the capture is unusable. Every other assertion here is about the three
# folded steps actually having run.
CWD="$REPO"
out="$(psout start st-fresh --priority high --category feature)"; rc=$?
chk "start: exit 0"                              test "$rc" = "0"
chk "start: stdout is EXACTLY one line"          test "$(printf '%s\n' "$out" | grep -c .)" = "1"
chk "start: stdout is the plan.md path"          has "/.mentor/plans/st-fresh/plan.md$" "$out"
chk "start: created the plan dir"                test -d "$REPO/.mentor/plans/st-fresh"
chk "start: dir locked to 700 (ensure-dir ran)"  test "$(stat -f '%Lp' "$REPO/.mentor/plans/st-fresh" 2>/dev/null || stat -c '%a' "$REPO/.mentor/plans/st-fresh")" = "700"
chk "start: sidecar written (init ran)"          test -f "$REPO/.mentor/plans/st-fresh/.state.json"
chk "start: init flags forwarded — priority"     test "$(jq -r .priority "$REPO/.mentor/plans/st-fresh/.state.json")" = "high"
chk "start: init flags forwarded — category"     test "$(jq -r .category "$REPO/.mentor/plans/st-fresh/.state.json")" = "feature"
chk "start: state is draft"                      test "$(jq -r .state "$REPO/.mentor/plans/st-fresh/.state.json")" = "draft"
err="$(pserr start st-fresh)"
chk "start: init summary goes to stderr, not stdout" has "st-fresh: draft" "$err"
chk "start: no-op claim notice is suppressed"    hasnt "nothing to claim" "$err"
out2="$(psout start st-fresh)"
chk "start: idempotent re-run → same path"       test "$out2" = "$out"
chk "start: idempotent re-run → still draft"     test "$(jq -r .state "$REPO/.mentor/plans/st-fresh/.state.json")" = "draft"

# The claim half is the reason claim is folded in at all: a /mentor:defer stub being
# fleshed out must stop being shielded from the approval sweep, without the caller
# having to know which case they are in.
# ensure-dir first: bare `init` runs require_slug and refuses a dir that does not exist
# yet — which is precisely the three-step dance `start` exists to fold away.
ps ensure-dir "$REPO/.mentor/plans/st-stub" >/dev/null
ps init st-stub --deferred >/dev/null
chk "start: fixture stub really is deferred"     test "$(jq -r .origin "$REPO/.mentor/plans/st-stub/.state.json")" = "deferred"
err="$(pserr start st-stub)"
chk "start: real claim IS surfaced (stderr)"     has "claimed — origin cleared" "$err"
chk "start: origin cleared on the stub"          test "$(jq -r '.origin // "null"' "$REPO/.mentor/plans/st-stub/.state.json")" = "null"

out="$(ps start)"; rc=$?
chk "start: no slug → exit 1"                    test "$rc" = "1"
chk "..names the usage"                          has "start needs <slug>" "$out"
out="$(ps start --priority high)"; rc=$?
chk "start: flag in the slug position → exit 1"  test "$rc" = "1"
CWD="$ROOT"; out="$(ps start outside-a-repo)"; rc=$?
chk "start: outside a git repo → exit 1"         test "$rc" = "1"
chk "..names the reason"                         has "Not inside a git repo" "$out"
CWD="$REPO"

echo "== X. policy: the pre-dispatch preflight — POLICY + CONTRACT in one call (v2.34.0) =="
# The printed token is the verdict, not the exit code (that is the whole difference from
# `sweep`, whose grep-shaped codes exist because a bare hit count cannot tell "no match"
# from "read nothing"). Exit 2 is reserved for the one case the check could NOT run.
rm -f "$REPO/CLAUDE.md"; rm -rf "$REPO/.claude"
out="$(ps policy)"; rc=$?
chk "policy: repo with plans dir, no policy → exit 0" test "$rc" = "0"
chk "..verdict is NONE"                          has "POLICY: NONE" "$out"
chk "..reports the denominator"                  has "files=" "$out"
chk "..CONTRACT line always present"             has "CONTRACT: active" "$out"

printf 'Rules\n\nPlease use no subagents on this project.\n' > "$REPO/CLAUDE.md"
out="$(ps policy)"; rc=$?
chk "policy: standing policy recorded → exit 0"  test "$rc" = "0"
chk "..verdict is FOUND"                         has "POLICY: FOUND" "$out"
chk "..tells the caller to ask ONCE"             has "Ask the user ONCE" "$out"
chk "..points at recording the answer"           has "set-mode.sh" "$out"
chk "..prints the hit with its file:line"        has "CLAUDE.md:3:" "$out"
chk "..case-insensitive by default"              test "$(printf 'Rules\n\nUse NO SUBAGENTS here.\n' > "$REPO/CLAUDE.md"; ps policy | grep -c 'POLICY: FOUND')" = "1"
rm -f "$REPO/CLAUDE.md"

# The pattern is ERE over the phrasings people actually write. The single literal this
# replaced ('no subagents') missed every one of these but the first — including the real
# wording measured in the wild, "Default to solo in-thread review over dispatching
# background agents", which is why a repo could carry a policy and still sweep clean.
for phrasing in \
  'No subagents by default.' \
  'Default to solo in-thread review over dispatching background agents.' \
  'Do not use the Agent tool here.' \
  'Never dispatch subagents in this repo.' \
  'Prefer no fan-out.' \
  'Background teammates are barred here.' \
  'Please use no sub-agents.' ; do
  printf 'Rules\n\n%s\n' "$phrasing" > "$REPO/CLAUDE.md"
  chk "policy: matches phrasing → FOUND [${phrasing:0:34}]" has "POLICY: FOUND" "$(ps policy)"
done
rm -f "$REPO/CLAUDE.md"

# AGENTS.md is its own root. A CLAUDE.md that is just `@AGENTS.md` keeps every real rule
# in the imported file, so a root set without it reads the pointer and reports a clean zero.
printf '@AGENTS.md\n' > "$REPO/CLAUDE.md"
printf '# Charter\n\nDefault to solo in-thread review over dispatching background agents.\n' > "$REPO/AGENTS.md"
out="$(ps policy)"
chk "policy: AGENTS.md is swept"                 has "POLICY: FOUND" "$out"
chk "..the hit names AGENTS.md, not the pointer" has "AGENTS.md:3:" "$out"

# Evidence is capped: a repo that lived under such a policy accumulates the phrase in
# every handoff note, and an uncapped list costs the orchestrator context on a preflight
# that runs before every fan-out.
printf '# Charter\n\n%s\n' "$(for i in 1 2 3 4 5 6 7 8; do echo "No subagents rule $i."; done)" > "$REPO/AGENTS.md"
out="$(ps policy)"
chk "policy: >5 hits → sample line shown"        has "hits total; the 5 above are a sample" "$out"
chk "..evidence really is capped at 5"           test "$(printf '%s\n' "$out" | grep -c 'AGENTS.md:')" = "5"

# --- POLICY: SET — a recorded preference ends the question outright ------------
# This is the branch the whole key exists for: it must win even while a standing
# instruction IS on record, because that instruction is what the user already answered.
# set-mode.sh is per-repo like plan-state.sh, so it has to run from the same cwd ps() uses.
sm() { ( cd "${CWD:-$REPO}" && _env bash "$(dirname "$PLANSTATE")/set-mode.sh" "$@" 2>&1 ); }
for v in agents solo verify-only; do
  sm "$v" >/dev/null 2>&1
  out="$(ps policy)"; rc=$?
  chk "policy: dispatch=$v → exit 0"             test "$rc" = "0"
  chk "..verdict is SET (dispatch=$v)"           has "POLICY: SET (dispatch=$v)" "$out"
  chk "..SET outranks a recorded policy"         sh -c '! printf "%s" "$1" | grep -q "POLICY: FOUND"' _ "$out"
  chk "..tells the caller not to ask [$v]"       has "Do NOT ask" "$out"
  chk "..CONTRACT still reported [$v]"           has "CONTRACT:" "$out"
done
# solo gives up independent grading, so the verdict has to say the report must disclose it
sm solo >/dev/null 2>&1
chk "policy: solo names the disclosure duty"     has "no independent verification" "$(ps policy)"

# An unrecognized value must never launder into "no policy" — the user meant something.
python3 - "$REPO/.mentor/config.json" <<'PY' 2>/dev/null || python3 -c "import json,sys;p=sys.argv[1];d=json.load(open(p));d['dispatch']='sometimes';json.dump(d,open(p,'w'))" "$REPO/.mentor/config.json"
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['dispatch']='sometimes'; json.dump(d,open(p,'w'))
PY
out="$(ps policy)"; rc=$?
chk "policy: bad dispatch value → exit 2"        test "$rc" = "2"
chk "..verdict is UNRESOLVED, not NONE"          has "POLICY: UNRESOLVED" "$out"
chk "..names the offending value"                has 'dispatch="sometimes"' "$out"
chk "..names the fix"                            has "/mentor:mode" "$out"
python3 -c "import json,sys;p=sys.argv[1];d=json.load(open(p));d.pop('dispatch',None);json.dump(d,open(p,'w'))" "$REPO/.mentor/config.json"
rm -f "$REPO/CLAUDE.md" "$REPO/AGENTS.md"

# roots=0 is a POSITIVE finding, not a failed search: none of the three durable
# locations exists, so there is nowhere a standing instruction could be recorded. Getting
# this wrong would stop every dispatch in every repo that has no CLAUDE.md.
BARE="$ROOT/bare-repo"; git init -q -b main "$BARE" >/dev/null 2>&1
( cd "$BARE"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
CWD="$BARE"; out="$(ps policy)"; rc=$?
chk "policy: no durable location exists → exit 0" test "$rc" = "0"
chk "..verdict is NONE, not UNRESOLVED"          has "POLICY: NONE (roots=0)" "$out"
chk "..says why it is sound"                     has "nowhere a standing instruction could be recorded" "$out"

# roots>0 with files=0 IS unresolved — an existing but unreadable/empty root is as
# consistent with a swallowed find error as with an empty dir.
mkdir -p "$BARE/.claude"
out="$(ps policy)"; rc=$?
chk "policy: root exists but no file read → exit 2" test "$rc" = "2"
chk "..verdict is UNRESOLVED"                    has "POLICY: UNRESOLVED" "$out"
chk "..refuses to be read as evidence"           has "NOT evidence" "$out"
rmdir "$BARE/.claude"
CWD="$REPO"

# CONTRACT is the alarm for dispatch-contract.sh's silent fail-soft. Since no skill
# pastes the block by hand any more, this line is the only thing that would say so.
CT="$(dirname "$PLANSTATE")/dispatch-contract.txt"
cp "$CT" "$ROOT/ct.bak"; : > "$CT"
out="$(ps policy)"
chk "policy: empty contract file → CONTRACT MISSING" has "CONTRACT: MISSING" "$out"
chk "..names the file"                           has "dispatch-contract.txt" "$out"
chk "..still answers the POLICY half"            has "POLICY: " "$out"
cp "$ROOT/ct.bak" "$CT"
out="$(psq_nojq_out policy)"
chk "policy: no jq on PATH → CONTRACT MISSING"   has "CONTRACT: MISSING" "$out"
chk "..names jq as the cause"                    has "jq is absent" "$out"

out="$(ps policy extra-arg)"; rc=$?
chk "policy: takes no arguments → exit 2"        test "$rc" = "2"

# --- query --format tree: the rendered hierarchy (v2.38.0) --------------------
# The layout /mentor:track prints used to live as ~9.5KB of prose in the skill,
# re-derived by the model on every run. These assertions are what stops it drifting
# back: they pin the numbering contract Step 2's ordinal selection resolves against,
# and the two roll-up clauses that are the whole reason the view is trusted for
# "is this really done?".
echo; echo "== query --format tree =="
TREE="$ROOT/tree-repo"
git init -q -b main "$TREE" >/dev/null 2>&1
( cd "$TREE"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
TPLANS="$TREE/.mentor/plans"
tplan() { # <slug> [--steps N ticked] — a plan dir with a plan.md carrying N step lines
  mkdir -p "$TPLANS/$1"
  printf '# %s\n\n## Context\n\nctx\n\n## Implementation steps\n\n' "$1" > "$TPLANS/$1/plan.md"
  local n="${2:-0}" tick="${3:-0}" i=1
  while [ "$i" -le "$n" ]; do
    if [ "$i" -le "$tick" ]; then printf '### %s. step ✅\n\nDone when: ok\n\n' "$i" >> "$TPLANS/$1/plan.md"
    else printf '### %s. step\n\nDone when: ok\n\n' "$i" >> "$TPLANS/$1/plan.md"; fi
    i=$((i+1))
  done
}
tps() { ( cd "$TREE" && _env bash "$PLANSTATE" "$@" 2>/dev/null ); }
# grep -F: the rendered line is full of [brackets] that a BRE would read as classes.
hasF()  { printf '%s' "$2" | grep -qF -- "$1"; }
hasntF(){ ! printf '%s' "$2" | grep -qF -- "$1"; }

tplan root-plan 2 2;        tps init root-plan --priority high --category feature >/dev/null
tplan fix-auth 1 0;         tps init fix-auth --parent root-plan --category fix --deferred --from root-plan --priority critical >/dev/null
tplan fix-retry 1 0;        tps init fix-retry --parent fix-auth --category fix >/dev/null
tplan split-a 4 1;          tps init split-a --group gfeat --order 1 >/dev/null
tplan split-b 1 0;          tps init split-b --group gfeat --order 2 >/dev/null
tplan flat-fix 1 0;         tps init flat-fix --category fix --deferred --from root-plan >/dev/null
tplan gated-fix 1 0;        tps init gated-fix --category fix --deferred --from root-plan >/dev/null
tplan dep-plan 1 0;         tps init dep-plan --deps ghost-plan >/dev/null
tps set split-a in_progress >/dev/null
tps set gated-fix draft --note 'gate: left uncontained' >/dev/null
mkdir -p "$TPLANS/topic-only/handoffs"; printf '# h\n' > "$TPLANS/topic-only/handoffs/20260801-000000-explore.md"
mkdir -p "$TREE/.mentor/handoffs"; printf '# old\n' > "$TREE/.mentor/handoffs/20260701-000000-legacy.md"
TOUT="$(tps query --open-counts --format tree)"

chk "tree: --format tree is accepted"        test -n "$TOUT"
out="$( cd "$TREE" && _env bash "$PLANSTATE" query --format bogus 2>&1 >/dev/null )"
chk "tree: bad --format names tree as valid" has "json|table|slug|count|tsv|tree" "$out"

chk "tree: implemented glyph"                hasF "● [high]" "$TOUT"
chk "tree: in_progress glyph"                hasF "◐" "$TOUT"
chk "tree: draft glyph"                      hasF "○" "$TOUT"
chk "tree: step counts render"               hasF "(1/4 steps)" "$TOUT"
chk "tree: deferred names its source"        hasF "(deferred, from: root-plan)" "$TOUT"
chk "tree: fix child is labelled"            hasF "(fix child" "$TOUT"
chk "tree: missing dep marked"               hasF "deps: ghost-plan (missing)" "$TOUT"

# Blank padding, never an invented tag: nobody judged these, which is a different
# fact from judging them medium/feature.
chk "tree: no tier invented when null"       hasntF "[med]" "$TOUT"
chk "tree: no category invented when null"   hasntF "[tool]" "$TOUT"

chk "tree: group header rendered"            hasF "▸ group: gfeat" "$TOUT"
chk "tree: group members indented"           has "^  [0-9]*\. .*split-a" "$TOUT"

# A root already reading implemented while fixes stay open is the single answer this
# view exists to get right — nothing re-checks it after the write-time warn.
chk "tree: done-with-open-descendants warns" hasF "⚠ ●" "$TOUT"
chk "tree: ..and says not really done"       hasF "not really done, 2 open descendant(s)" "$TOUT"

# flat-fix counts (lineage, no containment); gated-fix does not (the user already
# said flat was the answer at the non-goal gate).
chk "tree: unparented fix counted"           hasF "⚠ 1 unparented open fix(es) trace here" "$TOUT"
chk "tree: gate-dispositioned stub excluded" hasntF "⚠ 2 unparented open fix(es)" "$TOUT"
chk "tree: repair hint follows the clause"   hasF "set-parent <stub-slug> <owning-plan>" "$TOUT"

chk "tree: no_plan_topic uses its own kind"  hasF "▷ topic-only" "$TOUT"
chk "tree: ..labelled no plan yet"           hasF "no plan yet" "$TOUT"
chk "tree: live handoff rendered as subline" hasF "└ handoff: 20260801-000000-explore.md (live)" "$TOUT"
chk "tree: legacy handoffs render last"      test "$(printf '%s' "$TOUT" | grep -c '^▽ (untracked) legacy handoffs:')" = "1"

# Ordinals are the selection surface: a header or subline stealing one would make
# "build number 4" resolve to a different plan than the user pointed at.
tree_ords() { printf '%s' "$TOUT" | sed -n 's/^ *\([0-9][0-9]*\)\..*/\1/p' | tr '\n' ' '; }
chk "tree: ordinals are dense and in order"  test "$(tree_ords)" = "1 2 3 4 5 6 7 8 9 "
chk "tree: group header takes no ordinal"    hasnt "^ *[0-9][0-9]*\. *▸" "$TOUT"
chk "tree: handoff subline takes no ordinal" hasnt "^ *[0-9][0-9]*\. *└" "$TOUT"
# Depth-first: a root's fixes number immediately after it, before the next top-level
# entry, so the ordinal a user reads off the tree is the one Step 2 resolves.
chk "tree: fix child numbers under its root" test \
  "$(printf '%s' "$TOUT" | grep -n 'fix-auth' | cut -d: -f1)" \
  -gt "$(printf '%s' "$TOUT" | grep -n 'root-plan  *implemented' | cut -d: -f1)"
chk "tree: grandchild nests one level deeper" has "^    [0-9]*\. .*fix-retry" "$TOUT"

# An absent tag beats a wrong one: with no owner recorded there is nothing to compare.
chk "tree: own/unowned plans carry no worktree tag" hasntF "[worktree:" "$TOUT"
jq '.owner = "some-other-wt"' "$TPLANS/dep-plan/.state.json" > "$TPLANS/dep-plan/.tmp" && mv "$TPLANS/dep-plan/.tmp" "$TPLANS/dep-plan/.state.json"
chk "tree: a foreign owner IS tagged"        hasF "[worktree: some-other-wt]" "$(tps query --open-counts --format tree)"

chk "tree: repo that never planned prints nothing" test -z "$( cd "$BARE" && _env bash "$PLANSTATE" query --format tree 2>/dev/null )"
chk "tree: no jq on PATH is fail-soft"       test -z "$( cd "$TREE" && _env PATH="$NOJQ_DIR" "$BASH_BIN" "$PLANSTATE" query --format tree 2>/dev/null )"

# The point of the format: the model prints this instead of re-rendering JSON.
chk "tree: renders smaller than the JSON it replaces" test \
  "$(printf '%s' "$TOUT" | wc -c)" -lt "$(tps query --open-counts | wc -c)"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
