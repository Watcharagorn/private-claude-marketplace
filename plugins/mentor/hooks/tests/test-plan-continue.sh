#!/usr/bin/env bash
# Regression tests for hooks/plan-continue.sh — the Stop hook that keeps an approved
# run going until a terminal state (v6.0.0). One section per row of its first-match
# table, plus the fail-open edges.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$HOOKS/plan-continue.sh"
for dep in "$HOOK" "$HOOKS/lib/state.sh"; do
  [ -f "$dep" ] || { echo "FATAL: $dep not found"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required"; exit 1; }

ROOT="$(mktemp -d)"
SANDBOX="$ROOT/home"
REPO="$ROOT/repo"
mkdir -p "$SANDBOX" "$REPO"
trap 'rm -rf "$ROOT"' EXIT

git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
STATE="$REPO/.mentor"
PLAN="$STATE/plans/demo"
mkdir -p "$PLAN"

PASS=0; FAIL=0
chk() {  # chk <description> <command...>
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   — $desc"
  else FAIL=$((FAIL+1)); echo "FAIL — $desc"; fi
}
has()   { printf '%s' "$2" | grep -q -- "$1"; }
hasnt() { ! printf '%s' "$2" | grep -q -- "$1"; }

SID="sess-1"
input() {  # input [stop_hook_active] [session_id]
  jq -nc --arg cwd "$REPO" --arg sid "${2-$SID}" --argjson a "${1:-false}" \
    '{session_id: $sid, cwd: $cwd, hook_event_name: "Stop", stop_hook_active: $a}'
}
run() {  # run [stop_hook_active] [session_id] — prints stdout, sets RC
  OUT="$(input "${1:-false}" "${2-$SID}" | HOME="$SANDBOX" env -u MENTOR_CONTINUE bash "$HOOK" 2>/dev/null)"; RC=$?
}
blocks() { [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.decision // empty' 2>/dev/null)" = "block" ]; }
allows() { [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.decision // empty' 2>/dev/null)" != "block" ]; }

write_plan() {  # write_plan <ticked-steps e.g. "1">
  {
    printf '# Demo\n\n## Implementation steps\n\n'
    for n in 1 2 3; do
      if printf '%s' "$1" | grep -q "$n"; then printf '%s. Step %s ✅\n' "$n" "$n"; else printf '%s. Step %s\n' "$n" "$n"; fi
      printf '   - Done when: `true`\n\n'
    done
    printf '## Goal check\n\n`true`\n\n## Decision log\n\n'
  } > "$PLAN/plan.md"
}
set_state() { printf '{"state":"%s"}\n' "$1" > "$PLAN/.state.json"; }
mark() { printf 'slug=demo\nstarted=2026-11-01T00:00:00Z\n' > "$STATE/.run-$SID"; rm -f "$STATE/.run-$SID.idle"; }
reset() { rm -f "$STATE"/.run-* "$STATE/config.json"; write_plan "1"; set_state in_progress; mark; }

echo "== Row 6. in_progress + marker → block naming the next step =="
reset; run
chk "blocks the stop"                          blocks
chk "reason names the slug and next step 2"    has "continue demo: next step 2" "$OUT"
chk "reason points at After Proceed + verifier contract" has "After Proceed.*verifier-contract.md" "$OUT"
write_plan "1 2"; run true
chk "stop_hook_active:true still blocks under the cap" blocks
chk "..and names the new next step 3"          has "next step 3" "$OUT"
write_plan "1 2 3"; run
chk "all steps ticked → still blocks (stored state rules, not ticks)" blocks
chk "..reason asks for Done review, then Goal check" has "Done review.*Goal check" "$OUT"

echo "== Row 1. off switch =="
reset; OUT="$(input | HOME="$SANDBOX" MENTOR_CONTINUE=off bash "$HOOK" 2>/dev/null)"; RC=$?
chk "MENTOR_CONTINUE=off → allows"             allows
reset; printf '{"continue":"off"}\n' > "$STATE/config.json"; run
chk "\"continue\":\"off\" in config → allows"  allows

echo "== Row 2. no run marker =="
reset; rm -f "$STATE/.run-$SID"; run
chk "no marker → allows"                       allows
chk "..silently"                               test -z "$OUT"
reset; run false "other-session"
chk "another session's marker does not trap this one" allows
reset; run false ""
chk "no session_id → allows"                   allows

echo "== Row 3. stored state other than in_progress =="
for st in approved implemented failed draft; do
  reset; set_state "$st"; run
  chk "stored $st → allows"                    allows
done
reset; rm -f "$PLAN/plan.md"; run
chk "marker names a plan with no plan.md → allows" allows
chk "..and drops the dead marker"              test ! -f "$STATE/.run-$SID"

echo "== Row 4. stale run =="
reset; touch -t 202001010000 "$STATE/.run-$SID" "$PLAN/plan.md"; run
chk "marker + plan.md older than the stale threshold → allows" allows
chk "..and deletes the marker"                 test ! -f "$STATE/.run-$SID"
reset; touch -t 202001010000 "$PLAN/plan.md"; run
chk "plan.md alone past the threshold → allows" allows
two_h_ago="$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)"
reset; touch -t "$two_h_ago" "$STATE/.run-$SID"; run
chk "fresh plan.md → blocks"                   blocks
chk "..and the block refreshes the marker's mtime" test -z "$(find "$STATE/.run-$SID" -mmin +5)"

echo "== Row 5. idle cap =="
reset
run; chk "idle 0 → blocks"  blocks
run; chk "idle 1 → blocks"  blocks
run; chk "idle 2 → blocks"  blocks
run
chk "3rd no-progress continuation → allows"   allows
chk "..with a notice to write a paused row"    has "paused" "$OUT"
reset
run; run
write_plan "1 2"; run
chk "progress (a tick) resets the count → blocks" blocks
run; run
chk "two idle blocks after progress → still blocks" blocks
reset; printf '{"continue_max_idle_blocks":1}\n' > "$STATE/config.json"
run; run
chk "continue_max_idle_blocks:1 → allows on first repeat" allows
reset
run; echo "work" > "$REPO/new-file.txt"; run
chk "a working-tree change counts as progress" blocks
rm -f "$REPO/new-file.txt"

echo "== Fail-open edges =="
reset; OUT="$(printf 'not json' | HOME="$SANDBOX" bash "$HOOK" 2>/dev/null)"; RC=$?
chk "malformed stdin → exit 0, no block"       allows
OUT="$(jq -nc --arg cwd "$ROOT" '{session_id:"sess-1", cwd:$cwd}' | HOME="$SANDBOX" bash "$HOOK" 2>/dev/null)"; RC=$?
chk "cwd outside a git repo → allows"          allows
reset; printf 'started=x\n' > "$STATE/.run-$SID"; run
chk "marker with no slug= → allows"            allows
reset
NOJQ="$ROOT/nojq"; mkdir -p "$NOJQ"
for b in bash cat dirname git sed find head awk cksum cut rm printf grep; do
  p="$(command -v "$b" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$NOJQ/$b"
done
OUT="$(input | HOME="$SANDBOX" PATH="$NOJQ" "$NOJQ/bash" "$HOOK" 2>/dev/null)"; RC=$?
chk "no jq on PATH → exit 0, no block"         allows

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
