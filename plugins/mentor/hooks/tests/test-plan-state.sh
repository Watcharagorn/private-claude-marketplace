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
#     `set-priority`, surfaced on every `overview --json` entry. Unset stays null
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
ps init ov-b --priority critical >/dev/null
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
chk "ov-a: owner carries this worktree's wt-id (v2.23.0)" test "$(printf '%s' "$ov_a" | jq -r '.owner')" = "$WTA_ID"
chk "ov-a: unprioritized → priority null, never a default tier (v2.24.0)" \
  test "$(printf '%s' "$ov_a" | jq -r '.priority')" = "null"

ov_b="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-b")')"
chk "ov-b: step counts 1/2"                  test "$(printf '%s' "$ov_b" | jq -r '.steps.ticked,.steps.total' | tr '\n' ' ')" = "1 2 "
chk "ov-b: deps carry both slugs, in order"  test "$(printf '%s' "$ov_b" | jq -c '.deps | map(.slug)')" = '["ov-a","ov-missing"]'
chk "ov-b: known dep marked not missing"     test "$(printf '%s' "$ov_b" | jq -r '.deps[0].missing')" = "false"
chk "ov-b: unknown dep marked missing"       test "$(printf '%s' "$ov_b" | jq -r '.deps[1].missing')" = "true"
chk "ov-b: no handoffs"                      test "$(printf '%s' "$ov_b" | jq -c '.handoffs')" = '[]'
chk "ov-b: owner carries this worktree's wt-id (v2.23.0)" test "$(printf '%s' "$ov_b" | jq -r '.owner')" = "$WTA_ID"
chk "ov-b: priority carries the tier (v2.24.0)" test "$(printf '%s' "$ov_b" | jq -r '.priority')" = "critical"

ov_topic="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-topic")')"
chk "plan-less topic: kind no_plan_topic"  test "$(printf '%s' "$ov_topic" | jq -r '.kind')" = "no_plan_topic"
chk "plan-less topic: state 'no plan yet'" test "$(printf '%s' "$ov_topic" | jq -r '.state')" = "no plan yet"
chk "plan-less topic: live handoff listed" test "$(printf '%s' "$ov_topic" | jq -c '.handoffs')" = '["nudge.md"]'
chk "plan-less topic: zero step counts"    test "$(printf '%s' "$ov_topic" | jq -c '.steps')" = '{"ticked":0,"total":0}'
chk "plan-less topic: owner null (no sidecar)" test "$(printf '%s' "$ov_topic" | jq -r '.owner')" = "null"

ov_legacy="$(printf '%s' "$out" | jq -c '.[] | select(.kind=="legacy_handoffs")')"
chk "legacy dir: topic-less (slug null)" test "$(printf '%s' "$ov_legacy" | jq -r '.slug')" = "null"
chk "legacy dir: state null"             test "$(printf '%s' "$ov_legacy" | jq -r '.state')" = "null"
chk "legacy dir: steps null"             test "$(printf '%s' "$ov_legacy" | jq -r '.steps')" = "null"
chk "legacy dir: lists the flat note"    test "$(printf '%s' "$ov_legacy" | jq -c '.handoffs')" = '["legacy-note.md"]'
chk "legacy dir: owner null"             test "$(printf '%s' "$ov_legacy" | jq -r '.owner')" = "null"

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

echo "== O. list stays byte-compatible even when a plan carries deps/origin/priority =="
ps init ov-b --deferred >/dev/null   # give ov-b an origin too, alongside its deps
chk "the fixture plan really does carry a priority" test "$(sidecar ov-b '.priority')" = "critical"
out="$(psout list)"
row="$(printf '%s' "$out" | awk -v s="ov-b" '$3 == s')"
chk "row for a deps+origin+priority plan is still found" test -n "$row"
chk "row is still exactly 5 whitespace-separated columns" \
  test "$(printf '%s' "$row" | awk '{print NF}')" = "5"
chk "row carries no stray JSON from deps/origin" \
  sh -c '! printf "%s" "$0" | grep -qE "[][{}]"' "$row"

echo "== O2. list --owners adds a 6th OWNER column; bare list stays 5 (v2.23.0) =="
row_default="$(psout list | awk -v s="ov-b" '$3 == s')"
chk "list (default) row is still exactly 5 columns" test "$(printf '%s' "$row_default" | awk '{print NF}')" = "5"
row_owners="$(psout list --owners | awk -v s="ov-b" '$3 == s')"
chk "list --owners row is exactly 6 columns"      test "$(printf '%s' "$row_owners" | awk '{print NF}')" = "6"
chk "list --owners 6th column is the owner wt-id" test "$(printf '%s' "$row_owners" | awk '{print $6}')" = "$WTA_ID"

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

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
