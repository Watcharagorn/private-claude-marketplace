#!/usr/bin/env bash
# test-mode.sh — regression tests for set-mode.sh + begin-plan.sh's mode-aware output
# and per-worktree arming (v2.23.0).
#
# Runs against a SANDBOX $HOME so it never touches real user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
SETMODE="$HOOKS/set-mode.sh"
BEGIN="$HOOKS/begin-plan.sh"
STATE_LIB="$HOOKS/lib/state.sh"
for f in "$SETMODE" "$BEGIN" "$STATE_LIB"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

# A second, linked worktree of the SAME repo — the fixture the sibling-marker cases
# below need. Shares $REPO's .mentor/ (git-common-dir), but derives its own wt-id
# from its own --show-toplevel.
WTB="$ROOT/wt-b"
git -C "$REPO" worktree add -q "$WTB" -b wtb >/dev/null 2>&1

trap 'rm -rf "$ROOT"' EXIT

repo_root="$(cd "$REPO" && pwd -P)"
STATE_DIR="$repo_root/.mentor"   # project-scoped, in-repo (v2.0.0)
PLANS_DIR="$STATE_DIR/plans"
CONF="$STATE_DIR/config.json"

# wt-ids via the production recipe (sourced in a subshell so this script's own
# variables/functions stay untouched).
wt_id_of() { ( . "$STATE_LIB"; mentor_worktree_id "$1" ); }
MAIN_WT_ID="$(wt_id_of "$REPO")"
WTB_WT_ID="$(wt_id_of "$WTB")"
[ -n "$MAIN_WT_ID" ] && [ -n "$WTB_WT_ID" ] && [ "$MAIN_WT_ID" != "$WTB_WT_ID" ] \
  || { echo "FATAL: wt-id fixture broken (main='$MAIN_WT_ID' wtb='$WTB_WT_ID')" >&2; exit 1; }

MARKER="$PLANS_DIR/.planning.$MAIN_WT_ID"       # $REPO's (main's) own marker
WTB_MARKER="$PLANS_DIR/.planning.$WTB_WT_ID"    # the linked worktree's own marker
LEGACY_MARKER="$PLANS_DIR/.planning"            # pre-upgrade repo-global marker

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
count_eq() {  # <expected-count> <needle> <haystack> — exact grep -c match
  local want="$1" needle="$2" haystack="$3" got
  got="$(printf '%s' "$haystack" | command grep -c -- "$needle" 2>/dev/null || true)"
  [ "$got" = "$want" ]
}
sm() { ( cd "$REPO" && HOME="$SANDBOX" bash "$SETMODE" "$@" 2>&1 ); }

echo "== A. set-mode.sh status / set / invalid / key preservation =="
out="$(sm status)"; rc=$?
chk "unset → exits 0"                  test "$rc" = "0"
chk "unset → prints UNSET token"       sh -c "printf '%s' \"\$0\" | grep -q '^UNSET'" "$out"

out="$(sm plan-only)"
chk "set plan-only → confirmation"     sh -c "printf '%s' \"\$0\" | grep -q 'mode set: plan-only'" "$out"
chk "plan-only → no legacy SOFT-STOPS" sh -c "! printf '%s' \"\$0\" | grep -q 'SOFT-STOPS'" "$out"
chk "config.json written"              test -f "$CONF"
chk "config mode is plan-only"         test "$(jq -r .mode "$CONF")" = "plan-only"

out="$(sm status)"
chk "status → mode: plan-only"         sh -c "printf '%s' \"\$0\" | grep -q '^mode: plan-only'" "$out"

# Key preservation: foreign keys must survive a mode change.
jq '. + {custom: "keep-me"}' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
out="$(sm plan)"
chk "set plan → confirmation"          sh -c "printf '%s' \"\$0\" | grep -q 'mode set: plan'" "$out"
chk "config mode is plan"              test "$(jq -r .mode "$CONF")" = "plan"
chk "foreign config key preserved"     test "$(jq -r .custom "$CONF")" = "keep-me"
out="$(sm status)"
chk "status → mode: plan"              sh -c "printf '%s' \"\$0\" | grep -q '^mode: plan'" "$out"

out="$(sm bogus)"; rc=$?
chk "invalid mode → exit 1"            test "$rc" = "1"
chk "invalid mode → usage printed"     sh -c "printf '%s' \"\$0\" | grep -q 'Usage:'" "$out"
chk "usage names the dispatch axis"    sh -c "printf '%s' \"\$0\" | grep -q 'verify-only'" "$out"

echo "== A2. the dispatch axis is independent of mode =="
# Two axes in one config file. The whole reason the write path is shared (write_key) is
# that a second hand-rolled merge is where one axis silently clobbers the other.
out="$(sm verify-only)"
chk "set verify-only → confirmation"   sh -c "printf '%s' \"\$0\" | grep -q 'dispatch set: verify-only'" "$out"
chk "..promises the question stops"    sh -c "printf '%s' \"\$0\" | grep -q 'POLICY: SET'" "$out"
chk "config dispatch is verify-only"   test "$(jq -r .dispatch "$CONF")" = "verify-only"
chk "..mode axis untouched"            test "$(jq -r .mode "$CONF")" = "plan"
chk "..foreign key still preserved"    test "$(jq -r .custom "$CONF")" = "keep-me"

out="$(sm plan-only)"
chk "mode change keeps dispatch"       test "$(jq -r .dispatch "$CONF")" = "verify-only"
out="$(sm solo)"
chk "dispatch change keeps mode"       test "$(jq -r .mode "$CONF")" = "plan-only"
chk "solo warns it drops grading"      sh -c "printf '%s' \"\$0\" | grep -q 'independent grader'" "$out"

out="$(sm status)"
chk "status → both axes reported"      sh -c "printf '%s' \"\$0\" | grep -q '^mode: plan-only' && printf '%s' \"\$0\" | grep -q '^dispatch: solo'" "$out"

# Unset dispatch must read as "no override", never as an answer the user never gave.
jq 'del(.dispatch)' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
out="$(sm status)"
chk "dispatch unset → UNSET line"      sh -c "printf '%s' \"\$0\" | grep -q '^dispatch: UNSET'" "$out"
chk "..names it as no override"        sh -c "printf '%s' \"\$0\" | grep -q 'no override'" "$out"
chk "..mode line still leads"          sh -c "printf '%s' \"\$0\" | grep -q '^mode: plan-only'" "$out"
sm plan >/dev/null

rc=0; ( cd "$NONGIT" && HOME="$SANDBOX" bash "$SETMODE" status >/dev/null 2>&1 ) || rc=$?
chk "non-repo → exit 1"                test "$rc" = "1"

echo "== B. begin-plan.sh mode-aware output + arming =="
sm plan-only >/dev/null
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" 2>&1 )"
chk "plan-only → MODE: plan-only line" sh -c "printf '%s' \"\$0\" | grep -q '^MODE: plan-only$'" "$out"
chk "plan-only → no hard directive"    sh -c "! printf '%s' \"\$0\" | grep -q 'do NOT implement'" "$out"
chk "marker armed"                     test -f "$MARKER"
sm plan >/dev/null
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" 2>&1 )"
chk "plan → MODE: plan line"           sh -c "printf '%s' \"\$0\" | grep -q '^MODE: plan$'" "$out"
rm -f "$CONF"
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" 2>&1 )"
chk "unset → UNSET defaults to plan"   sh -c "printf '%s' \"\$0\" | grep -qF 'MODE: UNSET (default: plan)'" "$out"
chk "unset → no upfront ask"           sh -c "! printf '%s' \"\$0\" | grep -qE 'AskUserQuestion|set-mode.sh'" "$out"
# .opened sidecars are cleared on arm — recursively (dot-hidden in plan dirs,
# the zooms tree) + legacy flat. A legacy plans/<slug>/zoom/ sidecar is first
# RELOCATED to zooms/<slug>/ (v2.12.0) and then swept — gone either way.
ZOOMS_DIR="$STATE_DIR/zooms"
mkdir -p "$PLANS_DIR/some-plan/zoom" "$ZOOMS_DIR/some-plan"
: > "$PLANS_DIR/some-plan/.plan.md.opened"
: > "$PLANS_DIR/some-plan/zoom/.checkout-end-user.html.opened"
: > "$ZOOMS_DIR/some-plan/.billing-implementor.html.opened"
: > "$PLANS_DIR/legacy-flat.md.opened"
( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" >/dev/null 2>&1 )
chk "nested .opened sidecar cleared"      test ! -f "$PLANS_DIR/some-plan/.plan.md.opened"
chk "legacy zoom .opened sidecar gone (relocated + swept)" sh -c "test ! -f '$PLANS_DIR/some-plan/zoom/.checkout-end-user.html.opened' && test ! -f '$ZOOMS_DIR/some-plan/.checkout-end-user.html.opened'"
chk "zooms tree .opened sidecar cleared"  test ! -f "$ZOOMS_DIR/some-plan/.billing-implementor.html.opened"
chk "legacy flat .opened sidecar cleared" test ! -f "$PLANS_DIR/legacy-flat.md.opened"
# Outside a repo: fail-soft (exit 0, notice printed, no marker anywhere).
out="$( cd "$NONGIT" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" 2>&1 )"; rc=$?
chk "non-repo begin-plan exits 0"      test "$rc" = "0"
chk "non-repo → NOT-armed notice"      sh -c "printf '%s' \"\$0\" | grep -q 'NOT armed'" "$out"

echo "== C. Flat-layout migration on arm (v2.2.0 hop + v2.12.0 relocation) =="
rm -rf "$PLANS_DIR" "$ZOOMS_DIR"; mkdir -p "$PLANS_DIR"
printf '# Demo\n'      > "$PLANS_DIR/demo.md"
: > "$PLANS_DIR/demo-checkout-end-user.html"
# prefix collision: "auth-retry"'s zoom must not be captured by the shorter "auth" plan
printf '# Auth\n'      > "$PLANS_DIR/auth.md"
printf '# AuthRetry\n' > "$PLANS_DIR/auth-retry.md"
: > "$PLANS_DIR/auth-retry-x-y.html"
( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" >/dev/null 2>&1 )
chk "demo.md → demo/plan.md"                       test -f "$PLANS_DIR/demo/plan.md"
chk "demo zoom → zooms/demo/checkout-end-user.html (both hops)" test -f "$ZOOMS_DIR/demo/checkout-end-user.html"
chk "auth.md → auth/plan.md"                       test -f "$PLANS_DIR/auth/plan.md"
chk "auth-retry.md → auth-retry/plan.md"           test -f "$PLANS_DIR/auth-retry/plan.md"
chk "collision zoom → zooms/auth-retry/x-y.html"   test -f "$ZOOMS_DIR/auth-retry/x-y.html"
chk "auth has no captured zoom"                    sh -c "test ! -e '$PLANS_DIR/auth/zoom' && test ! -e '$ZOOMS_DIR/auth'"
chk "no plans/<slug>/zoom/ dirs left"              test -z "$(ls -d "$PLANS_DIR"/*/zoom 2>/dev/null)"
chk "no flat .md left"                             test -z "$(ls "$PLANS_DIR"/*.md 2>/dev/null)"
chk "no flat .html left"                           test -z "$(ls "$PLANS_DIR"/*.html 2>/dev/null)"
chk "marker armed after migration"                 test -f "$MARKER"

echo "== C2. v2.12.0 relocation alone (per-plan zoom/ → zooms/<slug>/) =="
mkdir -p "$PLANS_DIR/demo/zoom"
: > "$PLANS_DIR/demo/zoom/billing-implementor.html"
: > "$ZOOMS_DIR/demo/existing.html"   # pre-existing target content must survive (mv -n)
( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" >/dev/null 2>&1 )
chk "per-plan zoom html relocated"        test -f "$ZOOMS_DIR/demo/billing-implementor.html"
chk "emptied zoom/ dir removed"           test ! -e "$PLANS_DIR/demo/zoom"
chk "pre-existing zooms file untouched"   test -f "$ZOOMS_DIR/demo/existing.html"
# idempotent: a second arm with nothing to relocate must not fail or invent dirs
( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off bash "$BEGIN" >/dev/null 2>&1 ); rc=$?
chk "second arm (nothing to relocate) exits 0" test "$rc" = "0"

echo "== D. Marker metadata + foreign-marker guard =="
rm -f "$MARKER"
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-A bash "$BEGIN" 2>&1 )"
chk "fresh arm → marker carries session= line" sh -c "command grep -q '^session=sess-A$' '$MARKER'"
chk "fresh arm → marker carries cwd= line"     sh -c "command grep -q '^cwd=' '$MARKER'"
chk "fresh arm → marker carries worktree= line" sh -c "command grep -q '^worktree=' '$MARKER'"
chk "fresh arm → ARMED banner still printed"   sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"

# Same session re-arming (the CONTEXT: ASK -> bypass-context.sh -> re-run path, or an
# accidental double /mentor:plan) must NOT be treated as a foreign collision.
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-A bash "$BEGIN" 2>&1 )"
chk "same-session re-arm → ARMED (not blocked)" sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "same-session re-arm → no collision notice" sh -c "! printf '%s' \"\$0\" | grep -q 'NOT armed'" "$out"

# A DIFFERENT, still-live (non-stale) session's marker must block re-arming outright —
# begin-plan.sh used to truncate unconditionally, which resets the marker's mtime and
# strands the other session's plan.md (approve-plan.sh then refuses it as predating
# the marker). The marker content must be left untouched.
before="$(cat "$MARKER")"
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-B bash "$BEGIN" 2>&1 )"; rc=$?
chk "foreign live marker → exits 0 (fail-soft, not an error)" test "$rc" = "0"
chk "foreign live marker → NOT armed notice"        sh -c "printf '%s' \"\$0\" | grep -q 'NOT armed'" "$out"
chk "foreign live marker → names the owning session" sh -c "printf '%s' \"\$0\" | grep -q 'session sess-A'" "$out"
chk "foreign live marker → marker untouched"        test "$(cat "$MARKER")" = "$before"

# A STALE foreign marker (>8h) is effectively released — the guard must not block a
# fresh arm over it (plan-gate.sh's own self-heal treats it the same way).
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-B bash "$BEGIN" 2>&1 )"
chk "stale foreign marker → arms anyway"        sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "stale foreign marker → now owned by sess-B" sh -c "command grep -q '^session=sess-B$' '$MARKER'"

# (a) Empty OWN marker (pre-metadata, no session= line at all — this is THIS
# worktree's own suffixed marker planted with no body, NOT the bare legacy marker;
# see (b) below for that) has nothing to compare against for the foreign-session
# guard, so it fails soft: arm anyway — unchanged behavior.
: > "$MARKER"
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-C bash "$BEGIN" 2>&1 )"
chk "(a) empty OWN marker → arms anyway (no attribution to compare)" sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "(a) empty OWN marker → now stamped with sess-C" sh -c "command grep -q '^session=sess-C$' '$MARKER'"

# (b) A FRESH bare legacy `.planning` marker (no worktree suffix — the pre-upgrade
# repo-global marker) refuses to arm THIS worktree's own marker at all: distinct
# first line, own marker left untouched, legacy marker untouched.
rm -f "$MARKER"
: > "$LEGACY_MARKER"
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-D bash "$BEGIN" 2>&1 )"; rc=$?
chk "(b) live legacy marker → begin-plan exits 0 (fail-soft refusal)" test "$rc" = "0"
chk "(b) live legacy marker → distinct refusal first line" sh -c "printf '%s' \"\$0\" | head -1 | grep -qF 'Plan gate NOT armed — a legacy repo-wide plan gate marker is still active.'" "$out"
chk "(b) live legacy marker → own marker NOT created"           test ! -f "$MARKER"
chk "(b) live legacy marker → legacy marker untouched (still empty)" sh -c "[ ! -s '$LEGACY_MARKER' ]"
rm -f "$LEGACY_MARKER"

# (c) Empty-wt-id simulation: from a cwd where `git rev-parse --show-toplevel` fails
# (inside .git/) but `mentor_repo_root` still resolves (via --git-common-dir), the
# NEW legacy guard is SKIPPED entirely (wt_id empty — own marker IS the legacy path,
# mentor_plan_marker's one fallback site). Re-arming then depends only on the
# pre-existing foreign-session guard, which fail-softs on a same-session match —
# same-session re-arm must still work. Without this skip a session that armed via
# the legacy path could never re-arm its own gate (converts back into an
# un-armable repo-global lock).
rm -rf "$REPO/.git/.mentor"
ALT_MARKER="$REPO/.git/.mentor/plans/.planning"   # mentor_plan_marker's empty-wt_id fallback
out="$( cd "$REPO/.git" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-E bash "$BEGIN" 2>&1 )"
chk "(c) empty-wt-id → first arm succeeds"                       sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "(c) empty-wt-id → marker created at the bare (legacy-shaped) path" test -f "$ALT_MARKER"
out2="$( cd "$REPO/.git" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-E bash "$BEGIN" 2>&1 )"
chk "(c) empty-wt-id → same-session re-arm still ARMED (legacy guard skipped)" sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out2"
chk "(c) empty-wt-id → not refused as a live legacy marker"       sh -c "! printf '%s' \"\$0\" | grep -q 'legacy repo-wide plan gate marker'" "$out2"
rm -rf "$REPO/.git/.mentor"

echo "== E. Sibling worktree marker: informational banner + same-slug ownership WARNING =="
rm -f "$MARKER" "$LEGACY_MARKER"
printf 'session=sess-WTB\ncwd=%s\nworktree=%s\n' "$WTB" "$WTB" > "$WTB_MARKER"
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-F bash "$BEGIN" 2>&1 )"
chk "sibling marker live → main still arms"                sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "sibling marker live → banner notes 'also armed elsewhere'" sh -c "printf '%s' \"\$0\" | grep -q 'also armed elsewhere'" "$out"
chk "sibling marker live → names the sibling's suffix"     sh -c "printf '%s' \"\$0\" | grep -qF '$WTB_WT_ID'" "$out"

# Same-slug collision WARNING: an existing plan dir owned by the LIVE sibling
# worktree, when begin-plan.sh is told (via $1) that THIS is the slug about to be
# planned, must warn — two worktrees may be drafting the same slug concurrently.
mkdir -p "$PLANS_DIR/shared-slug"
printf '{"owner":"%s"}\n' "$WTB_WT_ID" > "$PLANS_DIR/shared-slug/.state.json"
rm -f "$MARKER"
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-G bash "$BEGIN" shared-slug 2>&1 )"
chk "same-slug owned by live sibling → WARNING fires" sh -c "printf '%s' \"\$0\" | grep -q \"WARNING: slug 'shared-slug' is owned by worktree ${WTB_WT_ID}\"" "$out"
rm -f "$WTB_MARKER" "$MARKER"

echo "== F. A sibling-owned plan's .opened sidecar survives an arm (ownership-scoped sweep) =="
mkdir -p "$PLANS_DIR/sibling-plan"
printf '{"owner":"%s"}\n' "$WTB_WT_ID" > "$PLANS_DIR/sibling-plan/.state.json"
: > "$PLANS_DIR/sibling-plan/.plan.md.opened"
mkdir -p "$PLANS_DIR/own-plan"
: > "$PLANS_DIR/own-plan/.plan.md.opened"
( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-H bash "$BEGIN" >/dev/null 2>&1 )
chk "sibling-owned .opened sidecar survives"     test -f "$PLANS_DIR/sibling-plan/.plan.md.opened"
chk "unowned .opened sidecar still cleared"      test ! -f "$PLANS_DIR/own-plan/.plan.md.opened"
rm -f "$MARKER"

echo "== G. Stale sibling prune: one notice per pruned marker; fresh siblings + legacy spared by the glob =="
rm -f "$MARKER" "$WTB_MARKER" "$LEGACY_MARKER"
FAKE_STALE="$PLANS_DIR/.planning.fake-wt-stale"
FAKE_FRESH="$PLANS_DIR/.planning.fake-wt-fresh"
printf 'session=sess-stale\n' > "$FAKE_STALE"
printf 'session=sess-fresh\n' > "$FAKE_FRESH"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$FAKE_STALE" 2>/dev/null || true
: > "$LEGACY_MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$LEGACY_MARKER" 2>/dev/null || true
out="$( cd "$REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-I bash "$BEGIN" 2>&1 )"
chk "stale legacy heals via its OWN notice (legacy-guard path, not the sibling loop)" \
    count_eq 1 'Pruned stale legacy plan gate marker .planning ' "$out"
chk "stale sibling pruned with exactly ONE notice" \
    count_eq 1 'Pruned stale sibling plan gate marker .planning.fake-wt-stale ' "$out"
# The fresh sibling IS still live, so it legitimately shows up in the "also armed
# elsewhere" informational line — only a PRUNE notice naming it would be wrong.
chk "fresh sibling produces NO prune notice" sh -c "! printf '%s' \"\$0\" | grep -q 'Pruned stale sibling plan gate marker .planning.fake-wt-fresh'" "$out"
chk "fresh sibling still reported live (also armed elsewhere)" sh -c "printf '%s' \"\$0\" | grep -q 'also armed elsewhere: fake-wt-fresh'" "$out"
chk "stale sibling marker file removed"   test ! -f "$FAKE_STALE"
chk "fresh sibling marker file untouched" test -f "$FAKE_FRESH"
chk "bare legacy marker healed (gone)"    test ! -f "$LEGACY_MARKER"
chk "own marker armed after all this"     test -f "$MARKER"
rm -f "$MARKER" "$FAKE_FRESH"

echo "== H. First-ever arm with no .mentor tree at all doesn't crash (set -e regression) =="
FRESH_REPO="$ROOT/fresh-repo"
git init -q -b main "$FRESH_REPO" >/dev/null 2>&1
( cd "$FRESH_REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
out="$( cd "$FRESH_REPO" && HOME="$SANDBOX" MENTOR_CONTEXT_GATE=off CLAUDE_CODE_SESSION_ID=sess-J bash "$BEGIN" 2>&1 )"; rc=$?
chk "first-ever arm (no plans/ dir yet) exits 0"          test "$rc" = "0"
chk "first-ever arm → ARMED banner (no crash)"            sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "first-ever arm → no bash 'No such file' crash text"  sh -c "! printf '%s' \"\$0\" | grep -qi 'no such file or directory'" "$out"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
