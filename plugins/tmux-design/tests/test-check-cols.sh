#!/usr/bin/env bash
# test-check-cols.sh — regression tests for scripts/check_cols.py, the verify loop's
# width assertion.
#
# Why this suite exists: the width check has now been hand-rolled into the skill twice
# and been wrong both times (awk length() counting bytes; an SGR-only strip counting an
# OSC-8 URL). The fixtures below are exactly the inputs that caught each one, so a third
# reinvention fails here instead of shipping.
#
# Runs entirely in a mktemp scratch dir; touches no user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CHECK="$ROOT_DIR/scripts/check_cols.py"
TEMPLATE="$ROOT_DIR/scripts/renderer_template.py"
CONSOLE="$ROOT_DIR/skills/console/SKILL.md"
for f in "$CHECK" "$TEMPLATE" "$CONSOLE"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() { desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}

# run <budget-args...> < fixture-file : returns the script's exit code, output in $out
run() { fixture="$1"; shift; out="$(python3 "$CHECK" "$@" < "$fixture" 2>&1)"; return $?; }

# Fixtures, written with printf so the escape bytes are real ESC, not the literal text.
F="$ROOT/fx"; mkdir -p "$F"
printf 'abcdefghij\n'                                             > "$F/ascii10"
printf '\033[38;5;114mabcdefghij\033[0m\n'                        > "$F/sgr10"
printf '\033]8;;https://example.com/a/very/long/url\007abcdefghij\033]8;;\007\n' > "$F/osc8_10"
printf '\xf0\x9f\xa7\x91\xe2\x80\x8d\xf0\x9f\x8c\xbe ok\n'        > "$F/zwj5"
printf 'テストト\n'                                                > "$F/cjk8"
printf '\033[2Kabcdefghij\n'                                      > "$F/erase10"
printf '\tabc\n'                                                  > "$F/tab11"
python3 -c 'print("─"*96)'                                   > "$F/div96"

echo "== A. escape-bearing lines measure their VISIBLE width =="
# Each of these is 10 visible columns. Budget 12 → must be silent and exit 0.
# osc8 is the one an SGR-only strip gets wrong (it counted the URL: 43 cols).
for fx in ascii10 sgr10 osc8_10 erase10; do
  run "$F/$fx" 12
  chk "$fx: fits budget 12 → exit 0"  test "$?" = "0"
  chk "$fx: fits budget 12 → silent"  test -z "$out"
done
run "$F/zwj5" 6
chk "zwj5: ZWJ cluster is one glyph, fits 6 → exit 0" test "$?" = "0"
chk "zwj5: silent"                                     test -z "$out"

echo
echo "== B. real overflow is reported, with a non-zero exit =="
# A byte/codepoint counter gets these wrong in the other direction.
run "$F/cjk8" 6
chk "cjk8: 8 cols > 6 → exit 1"       test "$?" = "1"
chk "cjk8: names the line and width"  sh -c 'printf "%s" "$0" | grep -q "line 1: 8 cols > 6"' "$out"
run "$F/div96" 60
chk "div96: 96-col divider > 60 → exit 1"  test "$?" = "1"
chk "div96: measured as 96, not 288"       sh -c 'printf "%s" "$0" | grep -q "96 cols"' "$out"
run "$F/tab11" 6
chk "tab11: tab expands, does not measure 0 → exit 1" test "$?" = "1"

echo
echo "== C. the budget arithmetic the doc relies on =="
run "$F/ascii10" 10
chk "10 cols in budget 10 → exit 0"              test "$?" = "0"
run "$F/ascii10" 10 --reserve 1
chk "--reserve 1 takes the scrollbar column → exit 1" test "$?" = "1"
run "$F/ascii10" 10 --reserve 0
chk "--reserve 0 is a no-op → exit 0"            test "$?" = "0"
out="$(python3 "$CHECK" < "$F/ascii10" 2>&1)"
chk "missing budget → exit 2"                    test "$?" = "2"
out="$(python3 "$CHECK" abc < "$F/ascii10" 2>&1)"
chk "non-numeric budget → exit 2"                test "$?" = "2"
out="$(python3 "$CHECK" 10 --reserve x < "$F/ascii10" 2>&1)"
chk "non-numeric --reserve → exit 2"             test "$?" = "2"

echo
echo "== D. the checker agrees with the kit's own vlen() =="
# Drift between these two is the actual bug class: the renderer pads with vlen(), so a
# checker measuring differently either passes crooked rows or fails straight ones.
# Assert the equality at its boundary: budget = vlen exactly → fits; budget = vlen-1 → over.
edge() {
  fx="$1"
  w="$(python3 - "$TEMPLATE" "$fx" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("rt", sys.argv[1])
rt = importlib.util.module_from_spec(spec); spec.loader.exec_module(rt)
print(rt.vlen(open(sys.argv[2], "rb").read().decode("utf-8").rstrip("\n").expandtabs(8)))
PY
)"
  python3 "$CHECK" "$w"             < "$fx" >/dev/null 2>&1 || return 1   # exactly fits
  python3 "$CHECK" $((w - 1))       < "$fx" >/dev/null 2>&1 && return 1   # one short → over
  return 0
}
for fx in ascii10 sgr10 osc8_10 zwj5 cjk8 erase10 div96; do
  chk "$fx: check_cols boundary == vlen()" edge "$F/$fx"
done

echo
echo "== E. no second width implementation in the skill =="
# The failure mode with a two-for-two track record is someone inlining a fresh width
# checker into the verify loop. Assert the skill delegates and does not re-derive.
chk "console/SKILL.md calls check_cols.py" \
  grep -q 'check_cols\.py' "$CONSOLE"
chk "console/SKILL.md re-derives no width math" \
  sh -c '! grep -q "east_asian_width" "$0"' "$CONSOLE"
chk "console/SKILL.md references the script via CLAUDE_PLUGIN_ROOT" \
  grep -q 'CLAUDE_PLUGIN_ROOT.*/scripts/check_cols\.py' "$CONSOLE"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
