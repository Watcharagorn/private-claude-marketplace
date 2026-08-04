#!/usr/bin/env bash
# test-pane-size.sh — regression tests for the kit's pane-size primitives
# (scripts/renderer_template.py: pane_width(), pane_height(), invalidate_pane_size()).
#
# Why this suite exists: every failure this file pins is a *plausible wrong number*, which is
# the worst shape a failure can take in a pane. Nothing raises, nothing looks broken — the
# table is simply sized to something other than the pane you are looking at, and you find out
# when a production row wraps. Two of these were live bugs:
#
#   * `tmux display -p '#{pane_width}'` with no `-t` answers about the server's ACTIVE pane. A
#     renderer running outside tmux therefore returned a stranger's window width instead of its
#     documented default, and one in an unfocused pane returned the focused pane's.
#   * COLUMNS/LINES were consulted before tmux. Under viddy that is even correct — viddy injects
#     them at the full pane size and keeps them current — which is exactly why it survived: the
#     value is right until the day it carries the launching terminal's width instead.
#
# Everything runs against a STUB tmux on PATH. That is not tidiness — a suite that asked the
# real server would pass or fail depending on which window the developer happened to have
# focused, i.e. it would be the same class of bug it is meant to catch.
#
# Runs entirely in a mktemp scratch dir; touches no user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
KIT="$ROOT_DIR/scripts/renderer_template.py"
CHECK="$ROOT_DIR/scripts/check_cols.py"
[ -f "$KIT" ]   || { echo "FATAL: not found: $KIT" >&2; exit 1; }
[ -f "$CHECK" ] || { echo "FATAL: not found: $CHECK" >&2; exit 1; }

PY="$(command -v python3)" || { echo "FATAL: python3 not on PATH" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() { desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}

# The kit is copied rather than imported in place so nothing can land in the plugin's own
# scripts/ dir. `-B` is belt-and-braces on top of that.
mkdir -p "$ROOT/kit" "$ROOT/bin" "$ROOT/nobin"
cp "$KIT" "$ROOT/kit/renderer_template.py"
LOG="$ROOT/tmux-argv.log"

# Stub tmux: records how it was called, answers from STUB_W/STUB_H. A real server is never
# contacted, so the answers are known and the argv is assertable.
cat > "$ROOT/bin/tmux" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG"
for a in "$@"; do
  case "$a" in
    '#{pane_width}')  echo "${STUB_W:-40}";  exit 0 ;;
    '#{pane_height}') echo "${STUB_H:-14}";  exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "$ROOT/bin/tmux"

DIMS='import sys; sys.path.insert(0, sys.argv[1]); import renderer_template as r; print(r.pane_width(), r.pane_height())'

# dims <PATH-to-use> [VAR=VAL ...] → "<width> <height>", with every size-bearing var cleared first
dims() {
  p="$1"; shift
  env -u TMUX -u TMUX_PANE -u COLUMNS -u LINES -u TMUX_PANE_WIDTH -u TMUX_PANE_HEIGHT \
      PATH="$p" STUB_LOG="$LOG" "$@" "$PY" -B -c "$DIMS" "$ROOT/kit"
}
want() { desc="$1"; expect="$2"; shift 2
  got="$(dims "$@")"
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s (want '%s', got '%s')\n" "$desc" "$expect" "$got"; fi
}

echo "== A. precedence: knob > tmux(this pane) > COLUMNS/LINES(no pane) > default =="
want "explicit knob outranks everything (the verify loop's width sweep)" \
  "77 33" "$ROOT/bin" TMUX_PANE=%3 STUB_W=40 STUB_H=14 COLUMNS=999 LINES=999 \
  TMUX_PANE_WIDTH=77 TMUX_PANE_HEIGHT=33
# The assertion this suite was written for: inside a pane, an injected COLUMNS must lose to tmux.
want "inside a pane, tmux wins over an injected COLUMNS/LINES" \
  "40 14" "$ROOT/bin" TMUX_PANE=%3 STUB_W=40 STUB_H=14 COLUMNS=999 LINES=999
want "outside a pane, COLUMNS/LINES are the only signal left, so they are used" \
  "120 44" "$ROOT/bin" COLUMNS=120 LINES=44
# Reachability of the documented default, with a server that WOULD answer. This is the -t bug
# in hermetic form: outside a pane there is no pane to ask about, so tmux must not be asked at
# all. Asking anyway returns whichever pane happens to be active — a live stranger's width —
# which made `default=80` unreachable on any machine running tmux. The stub stands in for that
# stranger, so this fails against the pre-fix kit (it answered 40) rather than only on a
# developer's box that happens to have a session open.
want "outside a pane, tmux is not asked at all — even when a server would answer" \
  "80 24" "$ROOT/bin" STUB_W=40 STUB_H=14
want "a pane whose tmux query fails falls back to the default, never to COLUMNS" \
  "80 24" "$ROOT/nobin" TMUX_PANE=%3 COLUMNS=999 LINES=999

echo
echo "== B. the query names THIS pane =="
: > "$LOG"
dims "$ROOT/bin" TMUX_PANE=%7 STUB_W=51 STUB_H=17 >/dev/null
chk "width query passes -t \$TMUX_PANE" \
  grep -qF -- '-t %7 #{pane_width}' "$LOG"
chk "height query passes -t \$TMUX_PANE" \
  grep -qF -- '-t %7 #{pane_height}' "$LOG"
chk "no untargeted query is ever issued" \
  sh -c '! grep -qE "^display -p #\{pane_(width|height)\}$" "$1"' _ "$LOG"

echo
echo "== C. caching, and the invalidation the own-loop shape needs =="
# An own-loop renderer must refetch on resize (primitives.md). A cached height makes it keep
# painting the pre-resize row count — a clean, well-aligned frame with its last rows missing.
cache_behavior() {
  env -u TMUX -u TMUX_PANE -u COLUMNS -u LINES -u TMUX_PANE_WIDTH -u TMUX_PANE_HEIGHT \
      PATH="$ROOT/bin" STUB_LOG="$LOG" TMUX_PANE=%1 STUB_W=40 STUB_H=14 \
      "$PY" -B - "$ROOT/kit" "$ROOT/bin/tmux" <<'PY'
import os, sys, pathlib
sys.path.insert(0, sys.argv[1])
import renderer_template as r
first = r.pane_width()
# Repoint the stub at a new size, as a live resize would.
os.environ["STUB_W"] = "90"; os.environ["STUB_H"] = "50"
cached = r.pane_width()
refreshed = r.pane_width(refresh=True)
r.invalidate_pane_size()
after_invalidate = r.pane_height()
print(first, cached, refreshed, after_invalidate)
PY
}
got="$(cache_behavior)"
chk "second call is cached (no fork per redraw), refresh= and invalidate_pane_size() re-ask" \
  test "$got" = "40 40 90 50"

echo
echo "== D. the shipped starter passes the plugin's own checks =="
# The demo is this plugin's rendered specification, so "the standard's own artifact satisfies
# the standard's own check" is an assertion worth making rather than assuming. It did not:
# title() never truncated (69 cols in a 60-col pane) and demo() drew to the full pane width,
# so this failed at w=60 with the reserve applied.
sweep() {
  rc=0
  for w in 60 100 160; do
    TMUX_PANE_WIDTH=$w "$PY" -B "$KIT" demo 2>/dev/null \
      | "$PY" -B "$CHECK" "$w" --reserve 1 >/dev/null 2>&1 || rc=1
  done
  return $rc
}
chk "demo fits its own check_cols budget at 60, 100 and 160 (with viddy's reserve)" sweep

# A fixture the renderer ignores is a check that always passes — the skill says so where it
# prescribes WIDTH_FIXTURE, so the starter has to actually read it.
fixture_read() {
  WIDTH_FIXTURE='⛔ blocked  日本語製品  🧑‍🌾 farmer' TMUX_PANE_WIDTH=100 \
    "$PY" -B "$KIT" demo 2>/dev/null | grep -q 'FIXTURE'
}
fixture_fits() {
  WIDTH_FIXTURE='⛔ blocked  日本語製品  🧑‍🌾 farmer' TMUX_PANE_WIDTH=60 \
    "$PY" -B "$KIT" demo 2>/dev/null | "$PY" -B "$CHECK" 60 --reserve 1 >/dev/null 2>&1
}
chk "demo reads WIDTH_FIXTURE into a row" fixture_read
chk "the wide-glyph fixture row still fits the budget at w=60" fixture_fits

# title() is the primitive that used to have no width awareness at all.
title_caps() {
  "$PY" -B - "$ROOT/kit" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import renderer_template as r
r.DEPTH, r.COLOR = "none", False
import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    r.title("x" * 200, width=40)
line = buf.getvalue().rstrip("\n")
sys.exit(0 if r.vlen(line) <= 40 else 1)
PY
}
chk "title() truncates to its width budget" title_caps

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
