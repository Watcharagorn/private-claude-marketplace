#!/usr/bin/env bash
# test-unfold-sweep.sh — regression tests for the audit action's `-w`/`--unfold` wrapper
# sweep (skills/console/SKILL.md, "audit — enforce the standard across a session").
#
# Why this suite exists: the sweep is sold as the FASTER substitute for looking at every
# pane, so a wrong answer here is worse than no sweep at all. The idiom has two failure
# modes that both look like success — a wrapper whose renderer payload happens to contain
# a `-w` token reads as compliant, and the skill's own sanctioned viddy-less `watch`
# fallback reads as a violation. Both are pinned below.
#
# Runs entirely in a mktemp scratch dir; touches no user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONSOLE="$ROOT_DIR/skills/console/SKILL.md"
[ -f "$CONSOLE" ] || { echo "FATAL: not found: $CONSOLE" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() { desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}

# The idiom under test, kept byte-for-byte in step with the one documented in the skill
# (section D below fails if the skill drifts away from this shape). The live-pane enumeration
# the skill puts first can't run here, so this exercises the glob fallback plus the zero-file
# guard — which is the half that decides whether an empty sweep reads as a pass.
sweep() {
  files=$(find "$1" -maxdepth 1 -name 'watch-*' 2>/dev/null)
  [ -z "$files" ] && echo "SWEEP FOUND NO FILES — enumerate from the launcher before reporting a pass"
  for f in $files; do
    [ -f "$f" ] || continue
    line=$(grep -m1 'viddy' "$f") || continue
    printf '%s\n' "${line%% -- *}" \
      | grep -qE -- '--unfold|(^|[[:space:]])-[a-z]*w([[:space:]]|$)' || echo "$(basename "$f")"
  done
}

W="$ROOT/scripts"; mkdir -p "$W"
printf 'exec viddy -p --unfold -n 30 -- python3 scripts/x.py\n' > "$W/watch-longflag"
printf 'exec viddy -pw -n 30 -- python3 scripts/x.py\n'         > "$W/watch-clustered"
printf 'exec viddy -p -w -n 30 -- python3 scripts/x.py\n'       > "$W/watch-shortflag"
printf 'exec viddy -p -n 30 -- python3 scripts/x.py\n'          > "$W/watch-missing"
printf 'exec viddy -p -n 90 -- wc -w report.txt\n'              > "$W/watch-payload"
printf 'exec watch -c -n 30 python3 scripts/x.py\n'             > "$W/watch-fallback"
printf '#!/bin/sh\n# sets up the pane\nexec viddy -p --unfold -n 5 -- ./r.py\n' > "$W/watch-multiline"

out="$(sweep "$W")"
has()  { printf '%s\n' "$out" | grep -qx "$1"; }
lacks() { ! printf '%s\n' "$out" | grep -qx "$1"; }

echo "== A. compliant wrappers are not flagged =="
chk "--unfold long form"                    lacks watch-longflag
chk "clustered short form (-pw)"            lacks watch-clustered
chk "separate short form (-w)"              lacks watch-shortflag
chk "flag found past a leading comment"     lacks watch-multiline

echo
echo "== B. violations are flagged, including the two that used to hide =="
chk "plain missing flag"                              has watch-missing
chk "payload's own -w does not mask the omission"     has watch-payload
chk "non-viddy fallback is not a rule 2 violation"    lacks watch-fallback

echo
echo "== C. degenerate inputs don't produce a false all-clear =="
# The distinction this section pins: "examined files, found no violations" is a pass, while
# "examined nothing" is not — and the two used to be the same empty output. A workspace whose
# layout lives in a launcher script rather than .tmuxp.yaml has no scripts/watch-* at all, so
# the sweep that silently examined zero files was reporting a clean bill on every pane.
EMPTY="$ROOT/empty"; mkdir -p "$EMPTY"
out_empty="$(sweep "$EMPTY" 2>/dev/null)"; rc=$?
chk "no wrappers → still exits 0 (a notice, not a crash)"  test "$rc" = "0"
chk "no wrappers → says it examined nothing"               sh -c 'printf "%s" "$0" | grep -q "SWEEP FOUND NO FILES"' "$out_empty"
chk "no wrappers → does NOT read as a clean pass"          test -n "$out_empty"
ONLYNON="$ROOT/onlynon"; mkdir -p "$ONLYNON"
printf 'exec tail -f /var/log/x\n' > "$ONLYNON/watch-tail"
out_non="$(sweep "$ONLYNON")"
chk "wrappers present but none use viddy → prints nothing (a real pass)" test -z "$out_non"
chk "that pass is not the zero-file notice"  sh -c '! printf "%s" "$0" | grep -q "SWEEP FOUND NO FILES"' "$out_non"

echo
echo "== D. the skill still documents this idiom, not the old whole-line one =="
chk "skill scopes the sweep to viddy wrappers" \
  grep -q "grep -m1 'viddy'" "$CONSOLE"
chk "skill cuts the renderer payload at ' -- '" \
  grep -q 'line%% -- \*' "$CONSOLE"
chk "skill no longer greps whole wrapper files" \
  sh -c '! grep -q "grep -LE -- .--unfold" "$0"' "$CONSOLE"
chk "skill guards against a zero-file sweep" \
  grep -q 'SWEEP FOUND NO FILES' "$CONSOLE"
chk "skill enumerates from live panes before the glob" \
  grep -q 'pane_start_command' "$CONSOLE"
chk "skill uses find, not a bare glob (zsh nomatch aborts)" \
  grep -q "find scripts -maxdepth 1 -name 'watch-\*'" "$CONSOLE"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
