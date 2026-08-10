#!/usr/bin/env bash
# test-state-lib.sh — regression tests for hooks/lib/state.sh (v2.0.0).
#
# The lib backs every hook, so it gets its own suite: project-scoped state-dir
# derivation (<repo>/.mentor), `set -e` caller safety (sourced functions must never
# abort a set -e hook), the config/mode readers, the .gitignore bootstrap, and the
# context-gate helpers (threshold precedence, kill switch, token extraction).
#
# Runs against a SANDBOX $HOME so it never touches real user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$(dirname "$SCRIPT_DIR")/lib/state.sh"
[ -f "$LIB" ] || { echo "FATAL: lib not found at $LIB" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
# Run a snippet with the lib sourced, sandbox HOME, under set -euo pipefail (the
# caller contract). Echoes the snippet's stdout; non-zero rc = the snippet aborted.
libsh() { HOME="$SANDBOX" bash -c "set -euo pipefail; . '$LIB'; $1"; }

echo "== A. Project-scoped state-dir derivation (<repo>/.mentor) =="
old_root() {
  local gc abs
  gc="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null || true)"
  [ -z "$gc" ] && { echo ""; return 0; }
  case "$gc" in /*) abs="$gc";; *) abs="$1/$gc";; esac
  cd "$(dirname "$abs")" && pwd
}
expect_root="$(old_root "$REPO")"
got_root="$(libsh "mentor_repo_root '$REPO'")"
chk "repo root matches inline derivation" test "$got_root" = "$expect_root"
got_state="$(libsh "mentor_state_dir '$expect_root'")"
chk "state dir is <repo_root>/.mentor" test "$got_state" = "$expect_root/.mentor"
got_plans="$(libsh "mentor_plans_dir '$expect_root'")"
chk "plans dir is {state}/plans" test "$got_plans" = "$got_state/plans"
chk "no repo → empty root" test -z "$(libsh "mentor_repo_root '$NONGIT'")"
chk "empty root → empty state dir" test -z "$(libsh "mentor_state_dir ''")"
chk "empty root → empty plans dir" test -z "$(libsh "mentor_plans_dir ''")"

echo "== B. Linked worktrees share one state dir =="
WT="$ROOT/linked-wt"
git -C "$REPO" worktree add -q "$WT" -b wt-branch >/dev/null 2>&1
wt_root="$(libsh "mentor_repo_root '$WT'")"
chk "linked worktree resolves to main repo root" test "$wt_root" = "$expect_root"

echo "== C. set -e caller safety (functions must not abort the hook) =="
chk "mentor_get_mode on nonexistent root" \
  libsh 'm="$(mentor_get_mode /nonexistent/path)"; [ -z "$m" ]; echo done >/dev/null'
chk "mentor_get_mode with no config"      libsh 'm="$(mentor_get_mode "'"$expect_root"'")"; [ -z "$m" ]'
chk "mentor_config_get bad input"         libsh 'v="$(mentor_config_get "" "")"; [ -z "$v" ]'
chk "mentor_context_tokens no file"       libsh 'v="$(mentor_context_tokens /nope.jsonl)"; [ -z "$v" ]'
chk "mentor_context_gate_state no repo"   libsh 's="$(mentor_context_gate_state "")"; [ "$s" = "on" ]'
chk "mentor_ensure_gitignore empty"       libsh 'mentor_ensure_gitignore ""; echo ok >/dev/null'
chk "mentor_cwd on empty input"           libsh 'c="$(mentor_cwd "")"; [ -n "$c" ]'
chk "mentor_cwd on garbage input"         libsh 'c="$(mentor_cwd "not json")"; [ -n "$c" ]'
chk "mentor_cwd extracts cwd"             libsh 'c="$(mentor_cwd "{\"cwd\":\"/tmp/x\"}")"; [ "$c" = "/tmp/x" ]'

echo "== B2. mentor_newest_plan (per-plan <slug>/plan.md dirs) =="
PLANS="$expect_root/.mentor/plans"
mkdir -p "$PLANS"
chk "empty plans dir → empty"        test -z "$(libsh "mentor_newest_plan '$PLANS'")"
chk "empty arg → empty"              test -z "$(libsh "mentor_newest_plan ''")"
mkdir -p "$PLANS/older-plan" "$PLANS/newer-plan"
printf '# old\n' > "$PLANS/older-plan/plan.md"
sleep 1
printf '# new\n' > "$PLANS/newer-plan/plan.md"
chk "newest of several wins"         test "$(libsh "mentor_newest_plan '$PLANS'")" = "$PLANS/newer-plan/plan.md"
sleep 1
printf '# flat legacy\n' > "$PLANS/legacy-flat.md"   # newer mtime, but flat → ignored
chk "legacy flat .md ignored"        test "$(libsh "mentor_newest_plan '$PLANS'")" = "$PLANS/newer-plan/plan.md"
rm -rf "$PLANS"

echo "== B3. Plan state: the sidecar is a cache, the ✅ ticks are the backstop (v2.4.0) =="
mkdir -p "$PLANS/alpha" "$PLANS/beta" "$PLANS/gamma"
printf '# a\n## Implementation steps\n1. one ✅\n2. two ✅\n## Verification\n1. not a step\n' > "$PLANS/alpha/plan.md"
printf '# b\n## Implementation steps\n1. one ✅\n2. two\n'                                    > "$PLANS/beta/plan.md"
printf '# g\n## Context\nnothing tickable here ✅\n'                                          > "$PLANS/gamma/plan.md"
chk "all steps ticked → implemented"   test "$(libsh "mentor_plan_tick_state '$PLANS/alpha/plan.md'")" = "implemented"
chk "some steps ticked → in_progress"  test "$(libsh "mentor_plan_tick_state '$PLANS/beta/plan.md'")" = "in_progress"
chk "ticks outside the section ignored" test -z "$(libsh "mentor_plan_tick_state '$PLANS/gamma/plan.md'")"
chk "missing plan file → empty"        test -z "$(libsh "mentor_plan_tick_state '/nope.md'")"
chk "empty arg → empty"                test -z "$(libsh "mentor_plan_tick_state ''")"
chk "no sidecar, no ticks → unknown"   test "$(libsh "mentor_plan_effective_state '$PLANS/gamma'")" = "unknown"
chk "no sidecar + ticks → implemented" test "$(libsh "mentor_plan_effective_state '$PLANS/alpha'")" = "implemented"
chk "empty dir arg → unknown"          test "$(libsh "mentor_plan_effective_state ''")" = "unknown"
chk "state file path derivation"       test "$(libsh "mentor_plan_state_file '$PLANS/alpha'")" = "$PLANS/alpha/.state.json"
chk "empty arg → empty state path"     test -z "$(libsh "mentor_plan_state_file ''")"
chk "valid state accepted"             libsh "mentor_plan_state_valid approved"
chk "invalid state rejected"           libsh "! mentor_plan_state_valid bogus"
chk "empty state rejected"             libsh "! mentor_plan_state_valid ''"
# set -e caller safety: a write must never abort the hook that called it.
chk "write on a missing dir is safe"   libsh "mentor_plan_state_write /nope/nope --state approved; echo ok >/dev/null"
chk "write with a bad state is safe"   libsh "mentor_plan_state_write '$PLANS/gamma' --state bogus; echo ok >/dev/null"
chk "bad state wrote nothing"          test ! -f "$PLANS/gamma/.state.json"
chk "field read with no sidecar"       test -z "$(libsh "mentor_plan_state_field '$PLANS/gamma' state")"
libsh "mentor_plan_state_write '$PLANS/gamma' --state draft --group grp --order 3 --note 'a note'"
chk "write stores state"               test "$(libsh "mentor_plan_state_field '$PLANS/gamma' state")" = "draft"
chk "write stores group"               test "$(libsh "mentor_plan_state_field '$PLANS/gamma' group")" = "grp"
chk "write stores order"               test "$(libsh "mentor_plan_state_field '$PLANS/gamma' order")" = "3"
libsh "mentor_plan_state_write '$PLANS/gamma' --state approved"
chk "group persists across a plain write" test "$(libsh "mentor_plan_state_field '$PLANS/gamma' group")" = "grp"
chk "order persists across a plain write" test "$(libsh "mentor_plan_state_field '$PLANS/gamma' order")" = "3"
chk "note is replaced, never merged"      test -z "$(libsh "mentor_plan_state_field '$PLANS/gamma' note")"
printf 'not json' > "$PLANS/gamma/.state.json"
chk "corrupt sidecar reads unknown"    test "$(libsh "mentor_plan_effective_state '$PLANS/gamma'")" = "unknown"
libsh "mentor_plan_state_write '$PLANS/gamma' --state draft"
chk "corrupt sidecar is repaired, not stuck" test "$(libsh "mentor_plan_effective_state '$PLANS/gamma'")" = "draft"
# Rank: the derived state wins only when it is strictly more advanced — and a
# DERIVATION must never overrule an explicitly recorded failure, however many ticks
# the plan body carries.
chk "failed outranks the derivable implemented" \
  libsh '[ "$(mentor_plan_state_rank failed)" -gt "$(mentor_plan_state_rank implemented)" ]'
libsh "mentor_plan_state_write '$PLANS/beta' --state failed"
chk "failed survives a tick-derived in_progress" test "$(libsh "mentor_plan_effective_state '$PLANS/beta'")" = "failed"
# End-to-end verification runs AFTER every step is ticked, so an orchestrator escalating
# to `failed` always faces an all-ticked plan. Ranking `implemented` higher here would
# resurface a genuinely failed plan to the next session as successfully completed.
libsh "mentor_plan_state_write '$PLANS/alpha' --state failed"
chk "failed survives an all-ticked implemented"  test "$(libsh "mentor_plan_effective_state '$PLANS/alpha'")" = "failed"
# Clearing a failure stays explicit: the orchestrator writes the new state, and a stored
# state wins ties against the derived one.
libsh "mentor_plan_state_write '$PLANS/alpha' --state implemented"
chk "explicit implemented + all ticked holds"    test "$(libsh "mentor_plan_effective_state '$PLANS/alpha'")" = "implemented"
libsh "mentor_plan_state_write '$PLANS/alpha' --state superseded"
chk "superseded outranks all-ticked"             test "$(libsh "mentor_plan_effective_state '$PLANS/alpha'")" = "superseded"
libsh "mentor_plan_state_write '$PLANS/beta' --state draft"
chk "stale draft loses to tick-derived progress" test "$(libsh "mentor_plan_effective_state '$PLANS/beta'")" = "in_progress"
libsh "mentor_plan_state_write '$PLANS/beta' --state approved"
chk "stale approved loses to tick-derived progress" test "$(libsh "mentor_plan_effective_state '$PLANS/beta'")" = "in_progress"
# mentor_newest_plan must skip superseded — a split parent is not "the current plan".
sleep 1; touch "$PLANS/alpha/plan.md"     # newest by mtime, but superseded
chk "newest_plan skips superseded"     test "$(libsh "mentor_newest_plan '$PLANS'")" != "$PLANS/alpha/plan.md"
libsh "mentor_plan_state_write '$PLANS/beta' --state superseded"
libsh "mentor_plan_state_write '$PLANS/gamma' --state superseded"
chk "all superseded → still returns one (never empty)" test -n "$(libsh "mentor_newest_plan '$PLANS'")"
rm -rf "$PLANS"

echo "== B4. The isolation header is the recovery path when a sidecar is lost =="
# /plan-split writes group + order into the child's header as well as its sidecar.
# Losing the sidecar must not silently drop a child out of its group — that would make
# "the current plan" start picking finished work.
mkdir -p "$PLANS/kid" "$PLANS/plain"
cat > "$PLANS/kid/plan.md" <<'MD'
# Child

> [!NOTE]
> **Plan 3 of 5** · group `multi-tenant-billing` · depends on `tenant-data-isolation`
> **Owns:** src/billing/invoice/**
> **Does NOT touch:** metering → `metering-pipeline`

## Implementation steps
1. **step**
MD
printf '# Plain\n\n## Implementation steps\n1. **step**\n' > "$PLANS/plain/plan.md"
chk "header group parsed"            test "$(libsh "mentor_plan_header_field '$PLANS/kid/plan.md' group")" = "multi-tenant-billing"
chk "header order parsed"            test "$(libsh "mentor_plan_header_field '$PLANS/kid/plan.md' order")" = "3"
chk "no header → empty group"        test -z "$(libsh "mentor_plan_header_field '$PLANS/plain/plan.md' group")"
chk "no header → empty order"        test -z "$(libsh "mentor_plan_header_field '$PLANS/plain/plan.md' order")"
chk "missing file → empty"           test -z "$(libsh "mentor_plan_header_field '/nope.md' group")"
chk "unknown key → empty"            test -z "$(libsh "mentor_plan_header_field '$PLANS/kid/plan.md' note")"
# With no sidecar at all, the resolvers fall back to the header.
chk "no sidecar → group from header" test "$(libsh "mentor_plan_group '$PLANS/kid'")" = "multi-tenant-billing"
chk "no sidecar → order from header" test "$(libsh "mentor_plan_order '$PLANS/kid'")" = "3"
chk "no sidecar, no header → empty"  test -z "$(libsh "mentor_plan_group '$PLANS/plain'")"
# The sidecar still wins when it has a value — a user who re-grouped by hand keeps it.
libsh "mentor_plan_state_write '$PLANS/kid' --state approved --group regrouped --order 9"
chk "sidecar group beats the header" test "$(libsh "mentor_plan_group '$PLANS/kid'")" = "regrouped"
chk "sidecar order beats the header" test "$(libsh "mentor_plan_order '$PLANS/kid'")" = "9"
rm -rf "$PLANS"

echo "== B5. Back-compat: pre-2.17.0 4-field sidecar reads deps=[]/origin=null, no migration =="
mkdir -p "$PLANS/legacy4"
printf '# legacy\n' > "$PLANS/legacy4/plan.md"
cat > "$PLANS/legacy4/.state.json" <<'JSON'
{"state":"approved","group":"old-parent","order":2,"note":"pre-existing note"}
JSON
chk "old 4-field sidecar: state reads back"        test "$(libsh "mentor_plan_state_field '$PLANS/legacy4' state")" = "approved"
chk "old 4-field sidecar: group reads back"        test "$(libsh "mentor_plan_group '$PLANS/legacy4'")" = "old-parent"
chk "old 4-field sidecar: order reads back"        test "$(libsh "mentor_plan_order '$PLANS/legacy4'")" = "2"
chk "old 4-field sidecar: deps defaults to []"     test -z "$(libsh "mentor_plan_deps '$PLANS/legacy4'")"
chk "old 4-field sidecar: origin defaults to null" test -z "$(libsh "mentor_plan_origin '$PLANS/legacy4'")"
chk "old 4-field sidecar: effective state unaffected" test "$(libsh "mentor_plan_effective_state '$PLANS/legacy4'")" = "approved"
# A later write upgrades it IN PLACE — no migration pass. state/group/order survive
# because an omitted flag preserves the stored value; --note still always replaces.
libsh "mentor_plan_state_write '$PLANS/legacy4' --deps upgrade-dep"
chk "upgrading write adds deps"                    test "$(libsh "mentor_plan_deps '$PLANS/legacy4'")" = "upgrade-dep"
chk "upgrading write preserves state"              test "$(libsh "mentor_plan_state_field '$PLANS/legacy4' state")" = "approved"
chk "upgrading write preserves group"              test "$(libsh "mentor_plan_group '$PLANS/legacy4'")" = "old-parent"
chk "upgrading write preserves order"              test "$(libsh "mentor_plan_order '$PLANS/legacy4'")" = "2"
chk "upgrading write clears note (--note always replaces)" test -z "$(libsh "mentor_plan_state_field '$PLANS/legacy4' note")"
rm -rf "$PLANS"

echo "== B6. mentor_plan_deps / mentor_plan_origin — dedicated array/scalar readers =="
mkdir -p "$PLANS/dr1" "$PLANS/dr2"
libsh "mentor_plan_state_write '$PLANS/dr1' --state draft --deps 'one,two,three'"
chk "deps: one per output line" \
  test "$(libsh "mentor_plan_deps '$PLANS/dr1'")" = "$(printf 'one\ntwo\nthree')"
chk "deps: empty when unset"           test -z "$(libsh "mentor_plan_deps '$PLANS/dr2'")"
chk "deps: empty when no sidecar"      test -z "$(libsh "mentor_plan_deps '$PLANS/nope'")"
chk "origin: unset reads empty"        test -z "$(libsh "mentor_plan_origin '$PLANS/dr1'")"
libsh "mentor_plan_state_write '$PLANS/dr1' --origin deferred"
chk "origin: deferred reads back"      test "$(libsh "mentor_plan_origin '$PLANS/dr1'")" = "deferred"
libsh "mentor_plan_state_write '$PLANS/dr1' --origin ''"
chk "origin: explicit empty clears it" test -z "$(libsh "mentor_plan_origin '$PLANS/dr1'")"
# A bad --origin is rejected outright — no write, existing (cleared) value untouched.
libsh "mentor_plan_state_write '$PLANS/dr1' --origin bogus"
chk "bad --origin rejected: still empty" test -z "$(libsh "mentor_plan_origin '$PLANS/dr1'")"
libsh "mentor_plan_state_write '$PLANS/dr1' --group g --deps ''"
chk "--deps explicit empty clears the array"      test -z "$(libsh "mentor_plan_deps '$PLANS/dr1'")"
chk "sibling field from the same write still lands" test "$(libsh "mentor_plan_group '$PLANS/dr1'")" = "g"
rm -rf "$PLANS"

echo "== B7. mentor_plan_would_cycle — BFS over stored deps, self AND multi-node =="
mkdir -p "$PLANS/c-a" "$PLANS/c-b" "$PLANS/c-c" "$PLANS/c-d"
libsh "mentor_plan_state_write '$PLANS/c-a' --state draft"
libsh "mentor_plan_state_write '$PLANS/c-b' --state draft"
libsh "mentor_plan_state_write '$PLANS/c-c' --state draft"
libsh "mentor_plan_state_write '$PLANS/c-d' --state draft"
chk "no cycle: unrelated plan"          test -z "$(libsh "mentor_plan_would_cycle '$PLANS' c-a 'c-d'")"
chk "direct self-cycle detected"        test "$(libsh "mentor_plan_would_cycle '$PLANS' c-a 'c-a'")" = "cycle"
# Build a chain b→c (stored). Tentatively giving a deps=[b] does NOT cycle yet —
# nothing in the chain points back to a.
libsh "mentor_plan_state_write '$PLANS/c-b' --deps c-c"
chk "no cycle yet: b→c doesn't loop back to a" test -z "$(libsh "mentor_plan_would_cycle '$PLANS' c-a 'c-b'")"
# Close it: c→a (stored). Now a→b→c→a would be a cycle.
libsh "mentor_plan_state_write '$PLANS/c-c' --deps c-a"
chk "3-node transitive cycle detected"  test "$(libsh "mentor_plan_would_cycle '$PLANS' c-a 'c-b'")" = "cycle"
chk "unknown dep slug is a dead end, not an error" test -z "$(libsh "mentor_plan_would_cycle '$PLANS' c-a 'does-not-exist'")"
chk "fail-soft: no plans_dir → empty"   test -z "$(libsh "mentor_plan_would_cycle '' c-a 'c-b'")"
chk "fail-soft: no slug → empty"        test -z "$(libsh "mentor_plan_would_cycle '$PLANS' '' 'c-b'")"
rm -rf "$PLANS"

echo "== B8. mentor_plan_live_handoffs — excludes handoffs/resolved/*, anchored =="
mkdir -p "$PLANS/hf/handoffs/resolved"
chk "no handoffs dir → empty"           test -z "$(libsh "mentor_plan_live_handoffs '$PLANS/nope'")"
: > "$PLANS/hf/handoffs/live-one.md"
: > "$PLANS/hf/handoffs/resolved/old-one.md"
got="$(libsh "mentor_plan_live_handoffs '$PLANS/hf'")"
chk "live handoff listed"               test "$got" = "live-one.md"
chk "resolved handoff excluded"         sh -c '! printf "%s" "$0" | grep -q old-one' "$got"
rm -rf "$PLANS"

echo "== B9. mentor_plan_tick_counts — raw ticked/total (overview's step-count rung) =="
mkdir -p "$PLANS/tc"
printf '# t\n## Implementation steps\n1. one ✅\n2. two ✅\n3. three\n' > "$PLANS/tc/plan.md"
chk "counts reflect ticked/total"       test "$(libsh "mentor_plan_tick_counts '$PLANS/tc/plan.md'")" = "2 3"
chk "missing file → 0 0"                test "$(libsh "mentor_plan_tick_counts '/nope.md'")" = "0 0"
chk "empty arg → 0 0"                   test "$(libsh "mentor_plan_tick_counts ''")" = "0 0"
rm -rf "$PLANS"

echo "== B9b. mentor_plan_tick_counts — H3-heading step format (### N. Title), real plans use this =="
mkdir -p "$PLANS/tch"
printf '# t\n## Implementation steps\n### 1. One ✅\nbody\n### 2. Two\nbody\n## Verification\n### 1. not a step (wrong section)\n' > "$PLANS/tch/plan.md"
chk "H3 headings counted like bare steps" test "$(libsh "mentor_plan_tick_counts '$PLANS/tch/plan.md'")" = "1 2"
rm -rf "$PLANS"

echo "== B10. mentor_plan_tick_step — the write-side counterpart, sharing B9's pattern =="
mkdir -p "$PLANS/ts"
printf '# t\n## Implementation steps\n1. one\n2. two\n## Verification\n1. not a step\n' > "$PLANS/ts/plan.md"
chk "tick step 1 → status line" test "$(libsh "mentor_plan_tick_step '$PLANS/ts/plan.md' 1")" = "ticked 1 2"
chk "tick step 1 → the ✅ landed on line 3, not line 5's lookalike" \
  bash -c "sed -n '3p' '$PLANS/ts/plan.md' | grep -qF '✅' && ! sed -n '6p' '$PLANS/ts/plan.md' | grep -qF '✅'"
chk "re-tick the same step → already, no rewrite" test "$(libsh "mentor_plan_tick_step '$PLANS/ts/plan.md' 1")" = "already 1 2"
chk "tick counts now read 1 2 back"     test "$(libsh "mentor_plan_tick_counts '$PLANS/ts/plan.md'")" = "1 2"
out="$(libsh "mentor_plan_tick_step '$PLANS/ts/plan.md' 99" 2>/dev/null)"; rc=$?
chk "step past the end → no-such-step"  test "$out" = "no-such-step 2"
chk "step past the end → rc 1"          test "$rc" = "1"
out="$(libsh "mentor_plan_tick_step '$PLANS/ts/plan.md' 0" 2>/dev/null)"; rc=$?
chk "step 0 → rejected, rc 1"           test "$rc" = "1"
out="$(libsh "mentor_plan_tick_step '$PLANS/ts/plan.md' abc" 2>/dev/null)"; rc=$?
chk "non-numeric step → rejected, rc 1" test "$rc" = "1"
out="$(libsh "mentor_plan_tick_step '/nope.md' 1" 2>/dev/null)"; rc=$?
chk "missing plan_md → rc 1, no crash"  test "$rc" = "1"
rm -rf "$PLANS"

echo "== B10b. mentor_plan_tick_step — H3-heading step format, sharing B9b's pattern =="
mkdir -p "$PLANS/tsh"
printf '# t\n## Implementation steps\n### 1. One\n### 2. Two\n' > "$PLANS/tsh/plan.md"
chk "tick H3 step 1 → status line" test "$(libsh "mentor_plan_tick_step '$PLANS/tsh/plan.md' 1")" = "ticked 1 2"
chk "tick H3 step 1 → the ✅ landed on the heading line" \
  bash -c "sed -n '3p' '$PLANS/tsh/plan.md' | grep -qF '✅'"
rm -rf "$PLANS"

echo "== D. mentor_get_mode / mentor_config_get =="
STATE="$expect_root/.mentor"
RCONF="$STATE/config.json"
mkdir -p "$STATE"
printf '{"mode": "plan"}\n'      > "$RCONF"
chk "mode=plan read back"      test "$(libsh "mentor_get_mode '$expect_root'")" = "plan"
printf '{"mode": "plan-only"}\n' > "$RCONF"
chk "mode=plan-only read back" test "$(libsh "mentor_get_mode '$expect_root'")" = "plan-only"
printf '{"other": 1}\n'          > "$RCONF"
chk "absent mode key → empty"  test -z "$(libsh "mentor_get_mode '$expect_root'")"
printf '{"context_block_tokens": 300000, "context_gate": "off"}\n' > "$RCONF"
chk "config_get numeric coerced to string" test "$(libsh "mentor_config_get '$expect_root' context_block_tokens")" = "300000"
chk "config_get string value"              test "$(libsh "mentor_config_get '$expect_root' context_gate")" = "off"
chk "config_get missing key → empty"       test -z "$(libsh "mentor_config_get '$expect_root' nope")"
rm -f "$RCONF"
chk "no config file → empty mode"   test -z "$(libsh "mentor_get_mode '$expect_root'")"

echo "== E. mentor_context_threshold precedence (env > config > default) =="
printf '{"context_block_tokens": 250000}\n' > "$RCONF"
chk "config wins over default"  test "$(libsh "mentor_context_threshold '$expect_root' '' context_block_tokens 270000")" = "250000"
chk "env wins over config"      test "$(libsh "mentor_context_threshold '$expect_root' 999 context_block_tokens 270000")" = "999"
chk "non-numeric env falls through to config" test "$(libsh "mentor_context_threshold '$expect_root' abc context_block_tokens 270000")" = "250000"
rm -f "$RCONF"
chk "no env/config → default"   test "$(libsh "mentor_context_threshold '$expect_root' '' context_block_tokens 270000")" = "270000"

echo "== F. mentor_context_gate_state kill switch =="
chk "env off"          test "$(libsh "MENTOR_CONTEXT_GATE=off mentor_context_gate_state '$expect_root'")" = "off"
chk "env 0"            test "$(libsh "MENTOR_CONTEXT_GATE=0 mentor_context_gate_state '$expect_root'")" = "off"
printf '{"context_gate": "off"}\n' > "$RCONF"
chk "config off"       test "$(libsh "mentor_context_gate_state '$expect_root'")" = "off"
printf '{"context_gate": "on"}\n' > "$RCONF"
chk "config on → on"   test "$(libsh "mentor_context_gate_state '$expect_root'")" = "on"
rm -f "$RCONF"

echo "== G. mentor_ensure_gitignore (commit config.json + constitution.md; idempotent) =="
GI="$STATE/.gitignore"
rm -f "$GI"
libsh "mentor_ensure_gitignore '$STATE'"
chk ".gitignore created"                     test -f "$GI"
chk ".gitignore ignores everything (*)"       grep -qx '\*' "$GI"
chk ".gitignore un-ignores config.json"       grep -qx '!config.json' "$GI"
chk ".gitignore un-ignores constitution.md"   grep -qx '!constitution.md' "$GI"
printf 'CUSTOM\n' > "$GI"
libsh "mentor_ensure_gitignore '$STATE'"
chk "never overwrites an existing .gitignore"  test "$(cat "$GI")" = "CUSTOM"

echo "== H. mentor_context_tokens extraction =="
TX="$ROOT/tx.jsonl"
python3 - "$TX" <<'PY'
import json,sys
lines=[
 {"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":100000,"cache_creation_input_tokens":8000}}},
 {"type":"assistant","isSidechain":True,"message":{"usage":{"input_tokens":5,"cache_read_input_tokens":5,"cache_creation_input_tokens":5}}},
 {"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}},
]
open(sys.argv[1],"w").write("\n".join(json.dumps(l) for l in lines)+"\n")
PY
chk "sums input+cache, skips sidechain + <synthetic>" test "$(libsh "mentor_context_tokens '$TX'")" = "108010"
python3 - "$TX" <<'PY'
import json,sys
lines=[
 {"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":228000,"cache_creation_input_tokens":0}}},
 {"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":7000}},
]
open(sys.argv[1],"w").write("\n".join(json.dumps(l) for l in lines)+"\n")
PY
chk "compact_boundary postTokens wins after usage" test "$(libsh "mentor_context_tokens '$TX'")" = "7000"
printf 'not json\n{"type":"user"}\n' > "$TX"
chk "no usage record → empty" test -z "$(libsh "mentor_context_tokens '$TX'")"

echo "== I. mentor_latest_handoff (plan-topic + legacy flat; resolved stamped notes skipped) =="
HAND_T="$STATE/plans/some-topic/handoffs"
HAND_L="$STATE/handoffs"
mkdir -p "$HAND_T" "$HAND_L"
chk "no notes → empty"            test -z "$(libsh "mentor_latest_handoff '$expect_root'")"
: > "$HAND_L/20260101-000000-legacy-note.md"
chk "legacy flat note found"      test "$(libsh "mentor_latest_handoff '$expect_root'")" = "$HAND_L/20260101-000000-legacy-note.md"
sleep 1
: > "$HAND_T/20260102-000000-topic-note.md"
chk "newest wins across locations" test "$(libsh "mentor_latest_handoff '$expect_root'")" = "$HAND_T/20260102-000000-topic-note.md"
sleep 1
: > "$HAND_T/not-a-handoff.md"    # newest mtime, but non-conforming name → skipped
chk "non-conforming name skipped" test "$(libsh "mentor_latest_handoff '$expect_root'")" = "$HAND_T/20260102-000000-topic-note.md"
mkdir -p "$HAND_T/resolved"
mv "$HAND_T/20260102-000000-topic-note.md" "$HAND_T/resolved/"   # the resolve stamp
chk "resolved-stamped note skipped" test "$(libsh "mentor_latest_handoff '$expect_root'")" = "$HAND_L/20260101-000000-legacy-note.md"
rm -rf "$STATE/plans" "$HAND_L"
# No repo → falls back to ~/.claude/mentor/_no-repo (where the handoff skill writes no-repo notes).
chk "no repo + no _no-repo notes → empty" test -z "$(libsh "mentor_latest_handoff ''")"
NR="$SANDBOX/.claude/mentor/_no-repo/plans/nr-topic/handoffs"
mkdir -p "$NR"
: > "$NR/20260103-000000-nr-note.md"
chk "no repo → _no-repo fallback note found" test "$(libsh "mentor_latest_handoff ''")" = "$NR/20260103-000000-nr-note.md"
rm -rf "$SANDBOX/.claude/mentor"
echo "== J. mentor_find_transcript / mentor_context_verdict (the shared ask-first check) =="
# One implementation, two callers: begin-plan.sh at arm time and `plan-state.sh
# context`, which /mentor:track runs before it dispatches. The tiers mirror the gate's
# own policy — over the ask threshold the USER decides (ASK), unless they already chose
# to continue this session (HANDOFF). A caller must never be stricter than the gate.
CFG="$ROOT/cfg"; mkdir -p "$CFG/projects/proj"
mkverdict_tx() { python3 - "$CFG/projects/proj/sess.jsonl" "$1" <<'PY'
import json,sys
open(sys.argv[1],"w").write(json.dumps({"type":"assistant","message":{"usage":{
  "input_tokens":10,"cache_read_input_tokens":int(sys.argv[2])-10,
  "cache_creation_input_tokens":0}}})+"\n")
PY
}
# Pin the environment: a developer's own MENTOR_CONTEXT_* must not move an assertion.
CLEAN="unset MENTOR_CONTEXT_GATE MENTOR_CONTEXT_BLOCK_TOKENS MENTOR_CONTEXT_WARN_TOKENS CLAUDE_CODE_SESSION_ID || true;"
chk "no transcript → empty path" \
  test -z "$(libsh "$CLEAN CLAUDE_CONFIG_DIR='$CFG' mentor_find_transcript '$expect_root'")"
V="CLAUDE_CONFIG_DIR='$CFG' CLAUDE_CODE_SESSION_ID=sess"
BYPASS="$STATE/.context-bypass-sess"
mkverdict_tx 400000
chk "session id locates the transcript exactly" \
  test "$(libsh "$CLEAN $V mentor_find_transcript '$expect_root'")" = "$CFG/projects/proj/sess.jsonl"
chk "over ask, no bypass → ASK (user decides)" \
  test "$(libsh "$CLEAN $V mentor_context_verdict '$expect_root'")" = "ASK 400000 200000 350000"
: > "$BYPASS"
chk "over ask, bypassed → HANDOFF, never a refusal" \
  test "$(libsh "$CLEAN $V mentor_context_verdict '$expect_root'")" = "HANDOFF 400000 200000 350000"
chk "bypass predicate true with the marker"  libsh "$CLEAN $V mentor_context_bypassed '$expect_root'"
rm -f "$BYPASS"
# `!` cannot follow env assignments, so negate a subshell instead of `VAR=x ! cmd`.
chk "bypass predicate false without it"      libsh "$CLEAN ! ( $V mentor_context_bypassed '$expect_root' )"
chk "bypass predicate false with no repo"    libsh "$CLEAN ! ( $V mentor_context_bypassed '' )"
mkverdict_tx 230000
chk "between warn and ask → WARN" \
  test "$(libsh "$CLEAN $V mentor_context_verdict '$expect_root'")" = "WARN 230000 200000 350000"
mkverdict_tx 50000
chk "under warn → OK" \
  test "$(libsh "$CLEAN $V mentor_context_verdict '$expect_root'")" = "OK 50000 200000 350000"
chk "env threshold override honored" \
  test "$(libsh "$CLEAN $V MENTOR_CONTEXT_BLOCK_TOKENS=1000 mentor_context_verdict '$expect_root'")" = "ASK 50000 200000 1000"
chk "kill switch → empty verdict" \
  test -z "$(libsh "$CLEAN $V MENTOR_CONTEXT_GATE=off mentor_context_verdict '$expect_root'")"
chk "unmeasurable → empty verdict" \
  test -z "$(libsh "$CLEAN CLAUDE_CONFIG_DIR='$ROOT/nothing' mentor_context_verdict '$expect_root'")"
chk "verdict is set -e safe with no repo" \
  libsh "$CLEAN CLAUDE_CONFIG_DIR='$ROOT/nothing' v=\"\$(mentor_context_verdict '')\"; echo ok >/dev/null"

echo "== mentor_ensure_private_dir — 700 down the whole path, self-healing =="
# `mkdir -p -m 700 a/b/c` modes only `c`; the helper exists because that can never
# deliver the "plans may carry sensitive paths" promise, and a tree that starts wrong
# stays wrong (a later -m 700 on an existing dir is a no-op).
PRIV="$ROOT/priv"; PSTATE="$PRIV/.mentor"
mode() { ls -ld "$1" 2>/dev/null | cut -c1-10; }
libsh "umask 022; mentor_ensure_private_dir '$PSTATE' '$PSTATE/plans/slug/handoffs'" >/dev/null
chk "leaf is 700"                    test "$(mode "$PSTATE/plans/slug/handoffs")" = "drwx------"
chk "intermediate slug/ is 700"      test "$(mode "$PSTATE/plans/slug")" = "drwx------"
chk "plans/ itself is 700"           test "$(mode "$PSTATE/plans")" = "drwx------"
chk ".mentor/ left alone"            test "$(mode "$PSTATE")" != "drwx------"

# Self-heal: an already-wrong tree is repaired by the next call, which is what makes
# begin-plan.sh fix drift that predates this helper.
chmod 755 "$PSTATE/plans" "$PSTATE/plans/slug"
libsh "mentor_ensure_private_dir '$PSTATE' '$PSTATE/plans/slug/handoffs'" >/dev/null
chk "pre-existing 755 repaired"      test "$(mode "$PSTATE/plans/slug")" = "drwx------"
chk "pre-existing 755 plans/ repaired" test "$(mode "$PSTATE/plans")" = "drwx------"

chk "fail-soft on empty args"        libsh "mentor_ensure_private_dir '' ''"
chk "fail-soft on unwritable parent" libsh "mentor_ensure_private_dir '$PSTATE' '/proc/nope/x'"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
