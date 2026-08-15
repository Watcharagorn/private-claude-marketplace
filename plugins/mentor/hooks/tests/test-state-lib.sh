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

echo "== B11. mentor_plan_goal_line — ## Goal first paragraph, reflowed + word-boundary truncated (v2.25.0) =="
# A real wrapped-Goal shape: the first paragraph spans THREE physical lines. Pinning
# this exact output proves reflow crosses the original line breaks (the cut lands on
# "reflects", the first word of physical line 2 — it could only appear here if the
# three lines were joined before truncating) rather than truncating line 1 alone.
# The same fixture text is used by test-plan-state.sh's overview-level assertion, so
# the two suites pin the identical reflow+truncation at different layers.
mkdir -p "$PLANS/goalw"
printf '# stub\n\n## Goal\n\n`claim_order()` in `daily-run.sh` orders concurrent learn slots by key that\nreflects real lock-acquisition order, so the plan promise that the oldest backlog\nsession gets first crack at merging is actually true under three-way concurrency.\n\n## Context\nmore prose here\n' > "$PLANS/goalw/plan.md"
chk "wrapped Goal: reflowed to one line, word-boundary truncated at ~85 chars + …" \
  test "$(libsh "mentor_plan_goal_line '$PLANS/goalw/plan.md'")" = '`claim_order()` in `daily-run.sh` orders concurrent learn slots by key that reflects…'

# A short first paragraph (well under the truncation limit) comes back byte-identical,
# with NO trailing `…` — truncation only ever fires when it actually truncates.
mkdir -p "$PLANS/goals"
printf '# t\n\n## Goal\n\nAdd a set-category subcommand mirroring set-priority exactly.\n\n## Context\nx\n' > "$PLANS/goals/plan.md"
chk "short Goal: returned untruncated, no trailing …" \
  test "$(libsh "mentor_plan_goal_line '$PLANS/goals/plan.md'")" = "Add a set-category subcommand mirroring set-priority exactly."

# Tabs inside the paragraph are replaced by spaces — the hygiene rule that keeps this
# text safe to sit in _plan_walk's tab-separated row downstream.
mkdir -p "$PLANS/goalt"
printf '# t\n\n## Goal\n\nLine one with\ttab\tchars.\nLine two continues without any.\n\n## Context\nx\n' > "$PLANS/goalt/plan.md"
chk "tabs in the paragraph become spaces" \
  test "$(libsh "mentor_plan_goal_line '$PLANS/goalt/plan.md'")" = "Line one with tab chars. Line two continues without any."

# A `## Goal` heading with no first paragraph (goes straight to the next section) →
# empty, not an error.
mkdir -p "$PLANS/goale"
printf '# t\n\n## Goal\n\n## Context\nno paragraph in goal\n' > "$PLANS/goale/plan.md"
chk "## Goal with no paragraph → empty" test -z "$(libsh "mentor_plan_goal_line '$PLANS/goale/plan.md'")"

# No `## Goal` section at all → empty, same as an old plan.md predating this convention.
mkdir -p "$PLANS/goaln"
printf '# t\n\n## Context\nno goal section at all\n' > "$PLANS/goaln/plan.md"
chk "no ## Goal section → empty" test -z "$(libsh "mentor_plan_goal_line '$PLANS/goaln/plan.md'")"

chk "missing plan_md → empty, no crash" test -z "$(libsh "mentor_plan_goal_line '/nope.md'")"
chk "empty arg → empty, no crash"       test -z "$(libsh "mentor_plan_goal_line ''")"

# B11b. The `section` parameter — a plan-track "broader ask" digest reads an
# ordinary plan's `## Context` instead of the `## Goal` no ordinary plan has.
mkdir -p "$PLANS/ctxonly"
printf '# recommended-first-clean\n\n## Context\nRe-baselines the spec doc after the 4-phase split, adds a checklist.\n\n## Use case scenarios\nirrelevant here\n' > "$PLANS/ctxonly/plan.md"
chk "no arg (default 'goal') on a plan with only ## Context → empty, unchanged from before this parameter existed" \
  test -z "$(libsh "mentor_plan_goal_line '$PLANS/ctxonly/plan.md'")"
chk "explicit 'goal' behaves identically to the default (backward-compat)" \
  test "$(libsh "mentor_plan_goal_line '$PLANS/ctxonly/plan.md' goal")" = "$(libsh "mentor_plan_goal_line '$PLANS/ctxonly/plan.md'")"
chk "'context' pulls the ## Context section's first paragraph on a plan with no ## Goal" \
  test "$(libsh "mentor_plan_goal_line '$PLANS/ctxonly/plan.md' context")" = "Re-baselines the spec doc after the 4-phase split, adds a checklist."

# A plan carrying BOTH sections (the deferred-stub shape) must still pick only the
# requested one — proves the section gate actually scopes the paragraph scan rather
# than just grabbing "the first paragraph found anywhere".
mkdir -p "$PLANS/both"
printf '# t\n\n## Goal\n\nGoal text only.\n\n## Context\n\nContext text only.\n' > "$PLANS/both/plan.md"
chk "default/'goal' on a plan with both sections → the Goal paragraph, not Context" \
  test "$(libsh "mentor_plan_goal_line '$PLANS/both/plan.md'")" = "Goal text only."
chk "'context' on the same plan → the Context paragraph, not Goal" \
  test "$(libsh "mentor_plan_goal_line '$PLANS/both/plan.md' context")" = "Context text only."
chk "section name is case-insensitive ('GOAL' matches '## Goal')" \
  test "$(libsh "mentor_plan_goal_line '$PLANS/both/plan.md' GOAL")" = "Goal text only."

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

echo "== I. mentor_latest_handoff / mentor_live_handoff_count (plan-topic + legacy flat; resolved stamped notes skipped) =="
HAND_T="$STATE/plans/some-topic/handoffs"
HAND_L="$STATE/handoffs"
mkdir -p "$HAND_T" "$HAND_L"
chk "no notes → empty"            test -z "$(libsh "mentor_latest_handoff '$expect_root'")"
chk "no notes → count 0"          test "$(libsh "mentor_live_handoff_count '$expect_root'")" = "0"
: > "$HAND_L/20260101-000000-legacy-note.md"
chk "legacy flat note found"      test "$(libsh "mentor_latest_handoff '$expect_root'")" = "$HAND_L/20260101-000000-legacy-note.md"
chk "one legacy note → count 1"   test "$(libsh "mentor_live_handoff_count '$expect_root'")" = "1"
sleep 1
: > "$HAND_T/20260102-000000-topic-note.md"
chk "newest wins across locations" test "$(libsh "mentor_latest_handoff '$expect_root'")" = "$HAND_T/20260102-000000-topic-note.md"
chk "two conforming notes → count 2" test "$(libsh "mentor_live_handoff_count '$expect_root'")" = "2"
sleep 1
: > "$HAND_T/not-a-handoff.md"    # newest mtime, but non-conforming name → skipped
chk "non-conforming name skipped" test "$(libsh "mentor_latest_handoff '$expect_root'")" = "$HAND_T/20260102-000000-topic-note.md"
chk "non-conforming name not counted" test "$(libsh "mentor_live_handoff_count '$expect_root'")" = "2"
mkdir -p "$HAND_T/resolved"
mv "$HAND_T/20260102-000000-topic-note.md" "$HAND_T/resolved/"   # the resolve stamp
chk "resolved-stamped note skipped" test "$(libsh "mentor_latest_handoff '$expect_root'")" = "$HAND_L/20260101-000000-legacy-note.md"
chk "resolved note drops out of count" test "$(libsh "mentor_live_handoff_count '$expect_root'")" = "1"
rm -rf "$STATE/plans" "$HAND_L"
# No repo → falls back to ~/.claude/mentor/_no-repo (where the handoff skill writes no-repo notes).
chk "no repo + no _no-repo notes → empty" test -z "$(libsh "mentor_latest_handoff ''")"
chk "no repo + no _no-repo notes → count 0" test "$(libsh "mentor_live_handoff_count ''")" = "0"
NR="$SANDBOX/.claude/mentor/_no-repo/plans/nr-topic/handoffs"
mkdir -p "$NR"
: > "$NR/20260103-000000-nr-note.md"
chk "no repo → _no-repo fallback note found" test "$(libsh "mentor_latest_handoff ''")" = "$NR/20260103-000000-nr-note.md"
chk "no repo → _no-repo fallback count 1" test "$(libsh "mentor_live_handoff_count ''")" = "1"
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

echo "== mentor_confine_path — canonicalize + refuse anything outside <state_dir> =="
# Shared by handoff-path/handoff-selfcheck (ensure-dir keeps its own older inline copy) —
# a model-chosen path segment (a plan slug, a handoff topic) reaches an mkdir/mv call site,
# so refusing anything that resolves outside <state_dir> is the one thing this must get right.
out="$(libsh "mentor_confine_path '$PSTATE' '$PSTATE/plans/slug'")"; rc=$?
chk "inside → exit 0"                     test "$rc" = "0"
chk "inside → prints the canonical path"  test "$out" = "$PSTATE/plans/slug"
out="$(libsh "mentor_confine_path '$PSTATE' '$PSTATE/plans/slug/handoffs'")"; rc=$?
chk "inside (nested) → exit 0"            test "$rc" = "0"

libsh "mentor_confine_path '$PSTATE' '$ROOT/outside'" >/dev/null 2>&1; rc=$?
chk "outside → nonzero exit"              test "$rc" != "0"
out="$(libsh "mentor_confine_path '$PSTATE' '$ROOT/outside'" 2>/dev/null)"
chk "outside → nothing on stdout"         test -z "$out"

libsh "mentor_confine_path '$PSTATE' '$PSTATE/../escape'" >/dev/null 2>&1; rc=$?
chk "a ..-escape that resolves outside → nonzero exit" test "$rc" != "0"

libsh "mentor_confine_path '' '$PSTATE/plans/slug'" >/dev/null 2>&1; rc=$?
chk "fail-soft: empty state_dir → nonzero, no crash" test "$rc" != "0"
libsh "mentor_confine_path '$PSTATE' ''" >/dev/null 2>&1; rc=$?
chk "fail-soft: empty target → nonzero, no crash"    test "$rc" != "0"

echo "== K. mentor_worktree_id — <name>-<crc>, fail-soft, sanitized, worktrees/-dir-name-safe (v2.23.0) =="
id_matches_charset()  { printf '%s' "$1" | grep -qE '^[A-Za-z0-9_-]+$'; }
id_starts_with()      { case "$1" in "$2"*) return 0 ;; *) return 1 ;; esac; }
id_not_starts_with()  { case "$1" in "$2"*) return 1 ;; *) return 0 ;; esac; }
id_has_no_raw_specials() { case "$1" in *'!'*|*' '*) return 1 ;; *) return 0 ;; esac; }
id_main="$(libsh "mentor_worktree_id '$REPO'")"
id_wt="$(libsh "mentor_worktree_id '$WT'")"
chk "main worktree id non-empty"          test -n "$id_main"
chk "linked worktree id non-empty"        test -n "$id_wt"
chk "main and linked worktree ids differ" test "$id_main" != "$id_wt"
chk "main id classified main-<crc>"       id_starts_with "$id_main" "main-"
chk "linked worktree id NOT classified main" id_not_starts_with "$id_wt" "main-"
id_main_again="$(libsh "mentor_worktree_id '$REPO'")"
chk "id stable across repeated calls"     test "$id_main" = "$id_main_again"
chk "main id matches safe charset ^[A-Za-z0-9_-]+\$ (catches the cksum two-field slip)" \
  id_matches_charset "$id_main"
chk "linked worktree id matches safe charset" id_matches_charset "$id_wt"
chk "non-repo dir → empty"                test -z "$(libsh "mentor_worktree_id '$NONGIT'")"

# Sanitization: a linked worktree whose git-internal dir name carries a character
# outside [A-Za-z0-9_-] (verified empirically: git folds a space to "-" itself but
# leaves e.g. "!" untouched) must still land in the safe charset, folded — never leak
# the raw character through into a marker filename.
WT_SPECIAL="$ROOT/wt special!name"
git -C "$REPO" worktree add -q "$WT_SPECIAL" -b wt-special-branch >/dev/null 2>&1
id_special="$(libsh "mentor_worktree_id '$WT_SPECIAL'")"
chk "special-char worktree id non-empty"            test -n "$id_special"
chk "special-char worktree id matches safe charset" id_matches_charset "$id_special"
chk "special-char worktree id has no raw '!' or space" id_has_no_raw_specials "$id_special"

# The "name" component is the `worktrees/<name>` path segment's PARENT BASENAME being
# exactly "worktrees" — never a substring test on the whole path. Prove the converse: a
# repo that merely LIVES under a directory literally named worktrees/ (this is its own
# main checkout, not a linked worktree of anything) must still classify as "main",
# because ITS git-dir's parent basename is the repo's own directory name.
HOSTED="$ROOT/worktrees/hosted-repo"
mkdir -p "$(dirname "$HOSTED")"
git init -q -b main "$HOSTED" >/dev/null 2>&1
( cd "$HOSTED"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
id_hosted="$(libsh "mentor_worktree_id '$HOSTED'")"
chk "repo living under a dir literally named worktrees/ still parses as main" \
  id_starts_with "$id_hosted" "main-"

echo "== L. mentor_plan_marker — suffixed path / the ONE empty-wt-id fallback site =="
chk "suffixed path"                test "$(libsh "mentor_plan_marker '/plans' 'main-123'")" = "/plans/.planning.main-123"
chk "empty wt-id → bare legacy path" test "$(libsh "mentor_plan_marker '/plans' ''")" = "/plans/.planning"
chk "empty plans_dir → empty"      test -z "$(libsh "mentor_plan_marker '' 'main-123'")"
chk "empty plans_dir + empty wt-id → empty" test -z "$(libsh "mentor_plan_marker '' ''")"

echo "== M. mentor_newest_plan_owned — ownership-filtered walk; all-superseded fallback stays WITHIN the filtered set =="
mkdir -p "$PLANS/own-a" "$PLANS/unowned" "$PLANS/own-b"
printf '# a\n' > "$PLANS/own-a/plan.md"
libsh "mentor_plan_state_write '$PLANS/own-a' --state draft --owner wt-a"
sleep 1
printf '# unowned\n' > "$PLANS/unowned/plan.md"
sleep 1
printf '# b\n' > "$PLANS/own-b/plan.md"
libsh "mentor_plan_state_write '$PLANS/own-b' --state draft --owner wt-b"
# own-b is the mtime-newest overall, but it's owned by wt-b — a wt-a-scoped read must
# never see it, so the pick falls to the newest wt-a-or-unowned candidate (unowned).
chk "wt-a filter skips wt-b's newer plan, returns unowned" \
  test "$(libsh "mentor_newest_plan_owned '$PLANS' wt-a")" = "$PLANS/unowned/plan.md"
chk "empty wt_id → unfiltered (newest overall = wt-b's)" \
  test "$(libsh "mentor_newest_plan_owned '$PLANS' ''")" = "$PLANS/own-b/plan.md"
# Now supersede everything a wt-a-scoped read can see. own-b (wt-b, non-superseded,
# still the mtime-newest overall) must NEVER be handed back as the fallback — the
# all-superseded fallback has to stay inside the ownership-filtered set, exactly the
# guarantee mentor_newest_plan (unfiltered) does NOT give.
libsh "mentor_plan_state_write '$PLANS/own-a' --state superseded"
libsh "mentor_plan_state_write '$PLANS/unowned' --state superseded"
got="$(libsh "mentor_newest_plan_owned '$PLANS' wt-a")"
chk "all-superseded fallback never returns a sibling's non-superseded plan" test "$got" != "$PLANS/own-b/plan.md"
chk "all-superseded fallback returns the newest WITHIN the filtered set"    test "$got" = "$PLANS/unowned/plan.md"
chk "empty plans_dir → empty"      test -z "$(libsh "mentor_newest_plan_owned '' wt-a")"
rm -rf "$PLANS"

echo "== N. mentor_newly_planned — the find -newer snapshot, same ownership filter, shared by approve-plan + gate --verbose =="
mkdir -p "$PLANS"
MARKER="$PLANS/.planning.wt-a"
: > "$MARKER"
sleep 1
mkdir -p "$PLANS/na" "$PLANS/nb" "$PLANS/nu"
printf '# a\n' > "$PLANS/na/plan.md"
libsh "mentor_plan_state_write '$PLANS/na' --state draft --owner wt-a"
printf '# b\n' > "$PLANS/nb/plan.md"
libsh "mentor_plan_state_write '$PLANS/nb' --state draft --owner wt-b"
printf '# u\n' > "$PLANS/nu/plan.md"
got="$(libsh "mentor_newly_planned '$PLANS' '$MARKER' wt-a" | sort)"
chk "filtered: only wt-a-owned + unowned newer than the marker" \
  test "$got" = "$(printf '%s\n' "$PLANS/na/plan.md" "$PLANS/nu/plan.md" | sort)"
got_unf="$(libsh "mentor_newly_planned '$PLANS' '$MARKER' ''" | sort)"
chk "empty wt_id → unfiltered (all three newer plans)" \
  test "$got_unf" = "$(printf '%s\n' "$PLANS/na/plan.md" "$PLANS/nb/plan.md" "$PLANS/nu/plan.md" | sort)"
chk "fail-soft: no marker → empty"      test -z "$(libsh "mentor_newly_planned '$PLANS' '' wt-a")"
chk "fail-soft: no plans_dir → empty"   test -z "$(libsh "mentor_newly_planned '' '$MARKER' wt-a")"
rm -rf "$PLANS"

echo "== O. mentor_plan_state_write --owner/--owner-session — set / preserve-on-omit / clear-on-explicit-empty; old-sidecar readback =="
mkdir -p "$PLANS/ow1"
libsh "mentor_plan_state_write '$PLANS/ow1' --state draft --owner wt-main-111 --owner-session sess-1"
chk "owner stored"         test "$(libsh "mentor_plan_owner '$PLANS/ow1'")" = "wt-main-111"
chk "owner_session stored" test "$(libsh "mentor_plan_state_field '$PLANS/ow1' owner_session")" = "sess-1"
# Omitted --owner on a plain write PRESERVES the stored value — the same
# omit=preserve contract --group/--order/--deps/--origin already carry.
libsh "mentor_plan_state_write '$PLANS/ow1' --state approved"
chk "owner preserved across a write that omits --owner"     test "$(libsh "mentor_plan_owner '$PLANS/ow1'")" = "wt-main-111"
chk "owner_session preserved too"                            test "$(libsh "mentor_plan_state_field '$PLANS/ow1' owner_session")" = "sess-1"
# Explicit empty CLEARS — the deliberate release-ownership path.
libsh "mentor_plan_state_write '$PLANS/ow1' --owner ''"
chk "explicit empty --owner clears it"                        test -z "$(libsh "mentor_plan_owner '$PLANS/ow1'")"
chk "clearing --owner alone leaves owner_session untouched"  test "$(libsh "mentor_plan_state_field '$PLANS/ow1' owner_session")" = "sess-1"
libsh "mentor_plan_state_write '$PLANS/ow1' --owner-session ''"
chk "explicit empty --owner-session clears it"                test -z "$(libsh "mentor_plan_state_field '$PLANS/ow1' owner_session")"
# Re-owning (the init/claim re-stamp path): a fresh --owner set wins outright.
libsh "mentor_plan_state_write '$PLANS/ow1' --owner wt-b-222 --owner-session sess-2"
chk "re-owning sets the new owner"         test "$(libsh "mentor_plan_owner '$PLANS/ow1'")" = "wt-b-222"
chk "re-owning sets the new owner_session" test "$(libsh "mentor_plan_state_field '$PLANS/ow1' owner_session")" = "sess-2"

# Readback of an OLD sidecar (pre-2.23.0, no owner/owner_session keys at all — or one an
# older cached plugin copy rewrote without them) must still work: mentor_plan_owner
# jq-defaults a missing key to unowned, same as deps/origin.
mkdir -p "$PLANS/oldsc"
cat > "$PLANS/oldsc/.state.json" <<'JSON'
{"state":"approved","group":null,"order":null,"note":"","deps":[],"origin":null}
JSON
chk "old sidecar (no owner key): state reads back"          test "$(libsh "mentor_plan_state_field '$PLANS/oldsc' state")" = "approved"
chk "old sidecar (no owner key): owner reads empty"         test -z "$(libsh "mentor_plan_owner '$PLANS/oldsc'")"
chk "old sidecar (no owner key): owner_session reads empty" test -z "$(libsh "mentor_plan_state_field '$PLANS/oldsc' owner_session")"
# A later write upgrades it in place — state survives (omit=preserve) while owner lands.
libsh "mentor_plan_state_write '$PLANS/oldsc' --owner wt-c-333"
chk "upgrading write preserves the pre-existing state" test "$(libsh "mentor_plan_state_field '$PLANS/oldsc' state")" = "approved"
chk "upgrading write adds the owner"                    test "$(libsh "mentor_plan_owner '$PLANS/oldsc'")" = "wt-c-333"
rm -rf "$PLANS"

echo "== O2. mentor_plan_state_write --priority — closed vocabulary, set / preserve-on-omit / clear-on-explicit-empty (v2.24.0) =="
chk "priority_valid accepts every tier" \
  libsh 'for p in critical high medium low noise; do mentor_plan_priority_valid "$p" || exit 1; done'
chk "priority_valid rejects a typo"     libsh '! mentor_plan_priority_valid hgih'
chk "priority_valid rejects empty"      libsh '! mentor_plan_priority_valid ""'
chk "priority_valid is a predicate, safe under set -e" \
  libsh 'if mentor_plan_priority_valid nope; then :; fi; echo ok >/dev/null'

mkdir -p "$PLANS/pr1"
libsh "mentor_plan_state_write '$PLANS/pr1' --state draft --priority critical --note 'n'"
chk "priority stored"                   test "$(libsh "mentor_plan_priority '$PLANS/pr1'")" = "critical"
# Omitted --priority on a plain write PRESERVES — the same omit=preserve contract
# --group/--order/--deps/--origin/--owner already carry. This is the property the
# whole feature rests on: a tier set once must survive every later state transition.
libsh "mentor_plan_state_write '$PLANS/pr1' --state approved"
chk "priority preserved across a write that omits it" test "$(libsh "mentor_plan_priority '$PLANS/pr1'")" = "critical"
chk "the state still moved"                            test "$(libsh "mentor_plan_state_field '$PLANS/pr1' state")" = "approved"
# Explicit empty CLEARS — the deliberate un-tier path.
libsh "mentor_plan_state_write '$PLANS/pr1' --priority ''"
chk "explicit empty --priority clears it"              test -z "$(libsh "mentor_plan_priority '$PLANS/pr1'")"
chk "clearing --priority leaves the state untouched"   test "$(libsh "mentor_plan_state_field '$PLANS/pr1' state")" = "approved"
# An INVALID tier rejects the WHOLE write, fail-soft (status 0, nothing changed) —
# same shape as an invalid --state or --origin. A half-applied write that dropped only
# the bad field would look to a caller exactly like a successful one.
libsh "mentor_plan_state_write '$PLANS/pr1' --priority high"
libsh "mentor_plan_state_write '$PLANS/pr1' --state draft --priority hgih"
chk "invalid --priority → whole write rejected (state unchanged)"    test "$(libsh "mentor_plan_state_field '$PLANS/pr1' state")" = "approved"
chk "invalid --priority → whole write rejected (priority unchanged)" test "$(libsh "mentor_plan_priority '$PLANS/pr1'")" = "high"
chk "invalid --priority never aborts a set -e caller" \
  libsh "mentor_plan_state_write '$PLANS/pr1' --priority nope; echo ok >/dev/null"

# Readback of an OLD sidecar (pre-2.24.0, no priority key at all — or one an older
# cached plugin copy rewrote without it) must read as UNPRIORITIZED, never a default.
mkdir -p "$PLANS/prold"
cat > "$PLANS/prold/.state.json" <<'JSON'
{"state":"implemented","group":null,"order":null,"note":"","deps":[],"origin":null,"owner":"wt-x","owner_session":"s"}
JSON
chk "old sidecar (no priority key): reads empty"    test -z "$(libsh "mentor_plan_priority '$PLANS/prold'")"
chk "old sidecar (no priority key): state reads back" test "$(libsh "mentor_plan_state_field '$PLANS/prold' state")" = "implemented"
libsh "mentor_plan_state_write '$PLANS/prold' --priority noise"
chk "upgrading write adds the priority"             test "$(libsh "mentor_plan_priority '$PLANS/prold'")" = "noise"
chk "upgrading write preserves the state"           test "$(libsh "mentor_plan_state_field '$PLANS/prold' state")" = "implemented"
chk "upgrading write preserves the owner"           test "$(libsh "mentor_plan_owner '$PLANS/prold'")" = "wt-x"
rm -rf "$PLANS"

echo "== O3. mentor_plan_state_write --category — closed vocabulary, set / preserve-on-omit / clear-on-explicit-empty (v2.25.0) =="
chk "category_valid accepts every kind" \
  libsh 'for c in feature fix refactor docs tooling; do mentor_plan_category_valid "$c" || exit 1; done'
chk "category_valid rejects a typo"     libsh '! mentor_plan_category_valid featur'
chk "category_valid rejects empty"      libsh '! mentor_plan_category_valid ""'
# The vocabulary deliberately excludes anything test/verify-shaped — the scope rule
# that keeps a deferred stub's Goal naming work to BUILD, never a check to run.
chk "category_valid rejects 'test'"     libsh '! mentor_plan_category_valid test'
chk "category_valid rejects 'verify'"   libsh '! mentor_plan_category_valid verify'
chk "category_valid is a predicate, safe under set -e" \
  libsh 'if mentor_plan_category_valid nope; then :; fi; echo ok >/dev/null'

mkdir -p "$PLANS/ct1"
libsh "mentor_plan_state_write '$PLANS/ct1' --state draft --category fix --note 'n'"
chk "category stored"                   test "$(libsh "mentor_plan_category '$PLANS/ct1'")" = "fix"
# Omitted --category on a plain write PRESERVES — the same omit=preserve contract
# --group/--order/--deps/--origin/--owner/--priority already carry.
libsh "mentor_plan_state_write '$PLANS/ct1' --state approved"
chk "category preserved across a write that omits it" test "$(libsh "mentor_plan_category '$PLANS/ct1'")" = "fix"
chk "the state still moved"                            test "$(libsh "mentor_plan_state_field '$PLANS/ct1' state")" = "approved"
# Explicit empty CLEARS — the deliberate un-categorize path.
libsh "mentor_plan_state_write '$PLANS/ct1' --category ''"
chk "explicit empty --category clears it"              test -z "$(libsh "mentor_plan_category '$PLANS/ct1'")"
chk "clearing --category leaves the state untouched"   test "$(libsh "mentor_plan_state_field '$PLANS/ct1' state")" = "approved"
# An INVALID category rejects the WHOLE write, fail-soft (status 0, nothing changed) —
# same shape as an invalid --state/--origin/--priority. A half-applied write that
# dropped only the bad field would look to a caller exactly like a successful one.
libsh "mentor_plan_state_write '$PLANS/ct1' --category tooling"
libsh "mentor_plan_state_write '$PLANS/ct1' --state draft --category verify"
chk "invalid --category → whole write rejected (state unchanged)"    test "$(libsh "mentor_plan_state_field '$PLANS/ct1' state")" = "approved"
chk "invalid --category → whole write rejected (category unchanged)" test "$(libsh "mentor_plan_category '$PLANS/ct1'")" = "tooling"
chk "invalid --category never aborts a set -e caller" \
  libsh "mentor_plan_state_write '$PLANS/ct1' --category nope; echo ok >/dev/null"

# Readback of an OLD sidecar (pre-2.25.0, no category key at all) must read as
# UNCATEGORIZED, never a default.
mkdir -p "$PLANS/ctold"
cat > "$PLANS/ctold/.state.json" <<'JSON'
{"state":"implemented","group":null,"order":null,"note":"","deps":[],"origin":null,"priority":"critical"}
JSON
chk "old sidecar (no category key): reads empty"      test -z "$(libsh "mentor_plan_category '$PLANS/ctold'")"
chk "old sidecar (no category key): state reads back" test "$(libsh "mentor_plan_state_field '$PLANS/ctold' state")" = "implemented"
libsh "mentor_plan_state_write '$PLANS/ctold' --category docs"
chk "upgrading write adds the category"             test "$(libsh "mentor_plan_category '$PLANS/ctold'")" = "docs"
chk "upgrading write preserves the state"           test "$(libsh "mentor_plan_state_field '$PLANS/ctold' state")" = "implemented"
chk "upgrading write preserves the (unrelated) priority field too" \
  test "$(libsh "mentor_plan_priority '$PLANS/ctold'")" = "critical"
rm -rf "$PLANS"

echo "== O4. mentor_plan_state_write --deferred-from / mentor_plan_deferred_from — UNVALIDATED pass-through, set / preserve-on-omit / clear-on-explicit-empty (v2.25.0) =="
mkdir -p "$PLANS/df1"
chk "unset deferred_from reads empty" test -z "$(libsh "mentor_plan_deferred_from '$PLANS/df1'")"
libsh "mentor_plan_state_write '$PLANS/df1' --state draft --deferred-from some-plan --note 'n'"
chk "deferred_from stored"            test "$(libsh "mentor_plan_deferred_from '$PLANS/df1'")" = "some-plan"
# UNVALIDATED, like a `deps` target — any string is accepted, including a slug for a
# plan dir that doesn't exist; the dangle is a render-time concern, not this layer's.
libsh "mentor_plan_state_write '$PLANS/df1' --deferred-from no-such-plan-at-all"
chk "deferred_from accepts a dangling slug (unvalidated)" \
  test "$(libsh "mentor_plan_deferred_from '$PLANS/df1'")" = "no-such-plan-at-all"
# Omitted --deferred-from on a plain write PRESERVES — the same omit=preserve
# contract every other field here carries.
libsh "mentor_plan_state_write '$PLANS/df1' --state approved"
chk "deferred_from preserved across a write that omits it" \
  test "$(libsh "mentor_plan_deferred_from '$PLANS/df1'")" = "no-such-plan-at-all"
chk "the state still moved"                                  test "$(libsh "mentor_plan_state_field '$PLANS/df1' state")" = "approved"
# Explicit empty CLEARS.
libsh "mentor_plan_state_write '$PLANS/df1' --deferred-from ''"
chk "explicit empty --deferred-from clears it"              test -z "$(libsh "mentor_plan_deferred_from '$PLANS/df1'")"
chk "clearing --deferred-from leaves the state untouched"   test "$(libsh "mentor_plan_state_field '$PLANS/df1' state")" = "approved"

# Readback of an OLD sidecar (pre-2.25.0, no deferred_from key at all) reads empty,
# same as every other jq-defaulted field; a later write upgrades it in place.
mkdir -p "$PLANS/dfold"
cat > "$PLANS/dfold/.state.json" <<'JSON'
{"state":"draft","group":null,"order":null,"note":"","deps":[],"origin":"deferred"}
JSON
chk "old sidecar (no deferred_from key): reads empty"        test -z "$(libsh "mentor_plan_deferred_from '$PLANS/dfold'")"
chk "old sidecar (no deferred_from key): origin reads back"  test "$(libsh "mentor_plan_origin '$PLANS/dfold'")" = "deferred"
libsh "mentor_plan_state_write '$PLANS/dfold' --deferred-from origin-plan"
chk "upgrading write adds deferred_from"              test "$(libsh "mentor_plan_deferred_from '$PLANS/dfold'")" = "origin-plan"
chk "upgrading write preserves origin"                test "$(libsh "mentor_plan_origin '$PLANS/dfold'")" = "deferred"
rm -rf "$PLANS"

echo "== P. mentor_plan_would_cycle_parent — self/2-node/3-node parent-cycle detection (v2.29.0) =="
mkdir -p "$PLANS/p-a" "$PLANS/p-b" "$PLANS/p-c"
chk "no cycle: giving p-a a parent p-b when neither has a parent chain" \
  test -z "$(libsh "mentor_plan_would_cycle_parent '$PLANS' p-a p-b")"
chk "direct self-parent detected"       test "$(libsh "mentor_plan_would_cycle_parent '$PLANS' p-a p-a")" = "cycle"
# p-b's parent is p-a (stored). Giving p-a a parent of p-b would close p-a→p-b→p-a.
libsh "mentor_plan_state_write '$PLANS/p-b' --parent p-a"
chk "2-node cycle detected (p-b's parent already p-a)" \
  test "$(libsh "mentor_plan_would_cycle_parent '$PLANS' p-a p-b")" = "cycle"
# 3-node: p-c's parent is p-b, p-b's parent is p-a. Giving p-a a parent of p-c closes
# p-a → p-c → p-b → p-a.
libsh "mentor_plan_state_write '$PLANS/p-c' --parent p-b"
chk "3-node transitive cycle detected"  test "$(libsh "mentor_plan_would_cycle_parent '$PLANS' p-a p-c")" = "cycle"
chk "unknown tentative parent is a dead end, not an error" \
  test -z "$(libsh "mentor_plan_would_cycle_parent '$PLANS' p-a does-not-exist")"
chk "fail-soft: no plans_dir → empty"        test -z "$(libsh "mentor_plan_would_cycle_parent '' p-a p-b")"
chk "fail-soft: no slug → empty"             test -z "$(libsh "mentor_plan_would_cycle_parent '$PLANS' '' p-b")"
chk "fail-soft: no tentative parent → empty" test -z "$(libsh "mentor_plan_would_cycle_parent '$PLANS' p-a ''")"
rm -rf "$PLANS"

echo "== Q. mentor_plan_descendants — transitive descendants via parent chains, breadth-first (v2.29.0) =="
mkdir -p "$PLANS/root" "$PLANS/child1" "$PLANS/child2" "$PLANS/grandchild"
chk "no descendants → empty"  test -z "$(libsh "mentor_plan_descendants '$PLANS' root")"
libsh "mentor_plan_state_write '$PLANS/child1' --parent root"
libsh "mentor_plan_state_write '$PLANS/child2' --parent root"
libsh "mentor_plan_state_write '$PLANS/grandchild' --parent child1"
got="$(libsh "mentor_plan_descendants '$PLANS' root" | sort)"
chk "descendants: children + grandchild, one per line" \
  test "$got" = "$(printf '%s\n' child1 child2 grandchild | sort)"
chk "a leaf slug (grandchild) has no descendants of its own" \
  test -z "$(libsh "mentor_plan_descendants '$PLANS' grandchild")"
chk "fail-soft: no plans_dir → empty" test -z "$(libsh "mentor_plan_descendants '' root")"
chk "fail-soft: no slug → empty"      test -z "$(libsh "mentor_plan_descendants '$PLANS' ''")"
rm -rf "$PLANS"

echo "== R. mentor_plan_state_write --parent / mentor_plan_parent — set / preserve-on-omit / clear-on-explicit-empty, UNVALIDATED at this layer (v2.29.0) =="
mkdir -p "$PLANS/pt1"
chk "unset parent reads empty" test -z "$(libsh "mentor_plan_parent '$PLANS/pt1'")"
libsh "mentor_plan_state_write '$PLANS/pt1' --state draft --parent some-root --note 'n'"
chk "parent stored" test "$(libsh "mentor_plan_parent '$PLANS/pt1'")" = "some-root"
# UNVALIDATED at this layer, like deps/deferred_from targets — existence+cycle
# validation lives one layer up, in plan-state.sh's init/set-parent.
libsh "mentor_plan_state_write '$PLANS/pt1' --parent no-such-plan-at-all"
chk "parent accepts a dangling slug (unvalidated at this layer)" \
  test "$(libsh "mentor_plan_parent '$PLANS/pt1'")" = "no-such-plan-at-all"
# Omitted --parent on a plain write PRESERVES — the same omit=preserve contract
# --group/--order/--deps/--origin/--owner/--priority/--category/--deferred-from
# already carry.
libsh "mentor_plan_state_write '$PLANS/pt1' --state approved"
chk "parent preserved across a write that omits it" \
  test "$(libsh "mentor_plan_parent '$PLANS/pt1'")" = "no-such-plan-at-all"
chk "the state still moved" test "$(libsh "mentor_plan_state_field '$PLANS/pt1' state")" = "approved"
# Explicit empty CLEARS — the deliberate detach-from-parent path.
libsh "mentor_plan_state_write '$PLANS/pt1' --parent ''"
chk "explicit empty --parent clears it" test -z "$(libsh "mentor_plan_parent '$PLANS/pt1'")"
chk "clearing --parent leaves the state untouched" test "$(libsh "mentor_plan_state_field '$PLANS/pt1' state")" = "approved"

# Readback of an OLD sidecar (pre-2.29.0, no parent key at all) reads empty, same as
# every other jq-defaulted field; a later write upgrades it in place.
mkdir -p "$PLANS/ptold"
cat > "$PLANS/ptold/.state.json" <<'JSON'
{"state":"implemented","group":null,"order":null,"note":"","deps":[],"origin":null,"priority":"high"}
JSON
chk "old sidecar (no parent key): reads empty"       test -z "$(libsh "mentor_plan_parent '$PLANS/ptold'")"
chk "old sidecar (no parent key): state reads back"  test "$(libsh "mentor_plan_state_field '$PLANS/ptold' state")" = "implemented"
libsh "mentor_plan_state_write '$PLANS/ptold' --parent root-plan"
chk "upgrading write adds the parent"        test "$(libsh "mentor_plan_parent '$PLANS/ptold'")" = "root-plan"
chk "upgrading write preserves the state"    test "$(libsh "mentor_plan_state_field '$PLANS/ptold' state")" = "implemented"
chk "upgrading write preserves the (unrelated) priority field too" \
  test "$(libsh "mentor_plan_priority '$PLANS/ptold'")" = "high"
rm -rf "$PLANS"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
