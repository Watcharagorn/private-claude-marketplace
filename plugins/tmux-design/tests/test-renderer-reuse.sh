#!/usr/bin/env bash
# test-renderer-reuse.sh — regression tests for rule 7's kit-reuse check
# (skills/console/SKILL.md, "Renderer scripts stay dependency-free").
#
# Why this suite exists: the check's whole job is to fire on a renderer that re-derived the
# kit's width math, and to stay silent on one that copied the kit wholesale. Both halves are
# load-bearing. A check that flags a correct file is one you learn to ignore, which is the
# same defect as not having it — and the plugin says so out loud in the audit sweep. The
# discriminator is subtle enough to be worth pinning: the copied kit DOES define vlen(), so
# `def vlen` alone can't be the signal; `cluster_width` is what tells them apart.
#
# Runs entirely in a mktemp scratch dir; touches no user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONSOLE="$ROOT_DIR/skills/console/SKILL.md"
KIT="$ROOT_DIR/scripts/renderer_template.py"
[ -f "$CONSOLE" ] || { echo "FATAL: not found: $CONSOLE" >&2; exit 1; }
[ -f "$KIT" ]     || { echo "FATAL: not found: $KIT" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() { desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}

# The idiom under test, kept byte-for-byte in step with the one documented in the skill
# (section D below fails if the skill drifts away from this shape).
reuse_check() {
  r="$1"
  [ -f "$r" ] || echo "MISSING: $r"
  grep -q 'def cluster_width' "$r" \
    || grep -nE '^ *def (vlen|pad|trunc)\b' "$r" | sed 's/^/re-derived width math /'
  grep -nE '^[A-Z][A-Z0-9_]* *= *"[0-9]+(;[0-9]+)+"' "$r" | sed 's/^/raw SGR palette /'
}

W="$ROOT/scripts"; mkdir -p "$W"

# A faithful copy of the bundled kit — the branch rule 7 tells you to take.
cp "$KIT" "$W/copied_view.py"

# A renderer that imports the kit instead of copying it.
cat > "$W/imported_view.py" <<'EOF'
from renderer_template import vlen, pad, table
TITLE = "title"
def render(rows):
    return table(rows)
EOF

# The session's actual failure: its own char-counting vlen(), plus SGR palette literals.
cat > "$W/handrolled_view.py" <<'EOF'
import re
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
TITLE = "1;38;5;212"
HEAD = "38;5;117"
def vlen(s):
    return len(ANSI_RE.sub("", str(s)))
def pad(s, n):
    return s + " " * (n - vlen(s))
EOF

# A pre-existing project renderer extended per rule 7's other branch: it legitimately owns
# a pad() built on its own width model. Named here to document that the check is scoped to
# the copy branch — the skill says so in prose, since no grep can tell these apart.
cat > "$W/extended_view.py" <<'EOF'
TITLE = "title"
def pad(s, n):
    return s.ljust(n)
EOF

# Non-color all-caps constants — the false-positive class the `;` requirement rules out.
cat > "$W/config_view.py" <<'EOF'
from renderer_template import vlen, pad
PORT = "8080"
TIMEOUT = "30"
RETRIES = "3"
EOF

# Capture once and match in-shell rather than piping into `grep -q`. Under `pipefail`, a
# `grep -q` that matches an EARLY line exits immediately, SIGPIPEs reuse_check mid-output,
# and the pipeline reports 141 — so a correct hit on the first line reads as a failed
# assertion while a hit on the last line passes. Exactly the kind of pass/fail inversion
# this suite exists to catch, so it must not live in the harness itself.
out_of() { reuse_check "$W/$1" 2>/dev/null; }
fires()  { [ -n "$(out_of "$1")" ]; }
silent() { [ -z "$(out_of "$1")" ]; }
says()   { case "$(out_of "$1")" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "== A. compliant renderers are not flagged =="
chk "wholesale copy of the kit stays silent"        silent copied_view.py
chk "renderer importing the kit stays silent"       silent imported_view.py
chk "PORT/TIMEOUT/RETRIES are not colors"           silent config_view.py

echo
echo "== B. the re-derived renderer is caught, and named =="
chk "hand-rolled vlen/pad fires"                    fires handrolled_view.py
chk "reported as re-derived width math"             says handrolled_view.py 're-derived width math'
chk "raw SGR palette reported separately"           says handrolled_view.py 'raw SGR palette'

echo
echo "== C. degenerate inputs don't produce a false all-clear =="
chk "missing file reports MISSING, not silence"     says nope_view.py 'MISSING: '
EMPTY="$W/empty_view.py"; : > "$EMPTY"
chk "empty file stays silent (nothing re-derived)"  silent empty_view.py

echo
echo "== D. the kit still satisfies the discriminator the check depends on =="
# If the kit is ever refactored so cluster_width() is renamed or inlined, section A's first
# case starts failing here rather than in someone's project six months later.
chk "kit defines cluster_width"                     grep -q '^def cluster_width' "$KIT"
chk "kit defines vlen (so vlen alone can't be the signal)" \
  grep -q '^def vlen' "$KIT"
chk "kit's palette constants are role names, not SGR" \
  sh -c '! grep -qE "^[A-Z][A-Z0-9_]* *= *\"[0-9]+(;[0-9]+)+\"" "$0"' "$KIT"

echo
echo "== E. the skill still documents this idiom =="
chk "skill guards on cluster_width" \
  grep -q "grep -q 'def cluster_width'" "$CONSOLE"
chk "skill's palette pattern requires a ';'" \
  grep -qF '[0-9]+(;[0-9]+)+' "$CONSOLE"
chk "skill handles the missing-file case" \
  grep -q 'MISSING: \$r' "$CONSOLE"

# ── The non-Python half ───────────────────────────────────────────────────────────────────
# The two patterns above are Python-shaped, so they report a clean run on the file that
# commits this rule's violation most often: a bash renderer whose palette is
# RED=$'\033[38;5;203m' and whose width math is printf '%-44s'. A check that is silent on
# the worst case is the pass-shaped failure this plugin exists to hunt, so the shell/jq
# patterns get the same both-halves treatment — they must fire on hand-rolled shell width
# math and stay silent on the kit and on fixed-width ASCII padding.
foreign_check() {
  r="$1"
  grep -nE '\\033\[|\\e\[[0-9;]*m' "$r" | sed 's/^/raw SGR palette /'
  grep -nE '%-[0-9]+s|\$\{#|\$\{[A-Za-z_][A-Za-z0-9_]*: *-?[0-9]' "$r" \
    | sed 's/^/shell width math /'
  grep -nE '\.\[0:[^]]+\]|\+ *" +"\)' "$r" | sed 's/^/jq width math /'
}
fout_of() { foreign_check "$W/$1" 2>/dev/null; }
ffires()  { [ -n "$(fout_of "$1")" ]; }
fsilent() { [ -z "$(fout_of "$1")" ]; }
fsays()   { case "$(fout_of "$1")" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# The session's actual bash failure: char-slicing truncation, byte-padding printf, raw SGR.
cat > "$W/handrolled_view.sh" <<'EOF'
#!/bin/bash
RED=$'\033[38;5;203m'
_wt_row() {
  short="$1"
  [ ${#short} -gt 44 ] && short="${short: -44}"
  printf '%-44s %s\n' "$short" "$2"
}
EOF

# jq-side padding — a different language, same class, and routinely in the same file.
cat > "$W/jqrow_view.sh" <<'EOF'
#!/bin/bash
row() { jq -r '((.status + "         ")[0:9]) + ((.jobName // "?")[0:32])'; }
EOF

# The credibility case: padding a fixed-width ASCII id is correct and must not be flagged.
cat > "$W/fixedwidth_view.sh" <<'EOF'
#!/bin/bash
render() { printf '%s %s\n' "$sha" "$region"; }
EOF

echo
echo "== F. the shell/jq patterns catch what the Python ones can't see =="
chk "bash char-slice + byte-pad fires"              ffires handrolled_view.sh
chk "reported as shell width math"                  fsays handrolled_view.sh 'shell width math'
chk "bash \$'\\033[' palette reported as raw SGR"     fsays handrolled_view.sh 'raw SGR palette'
chk "jq code-point padding fires"                   ffires jqrow_view.sh
chk "reported as jq width math"                     fsays jqrow_view.sh 'jq width math'
chk "no printf padding at all → silent"             fsilent fixedwidth_view.sh
chk "the Python-shaped check is BLIND to the bash file (why F exists)" \
  silent handrolled_view.sh
chk "kit stays silent under the shell patterns too"  fsilent copied_view.py

echo
echo "== F2. the kit's width source stays tmux, not the environment =="
# COLUMNS reads like a free convenience, and under viddy it even returns the right number —
# viddy injects it at the full pane size and keeps it current. That is what makes restoring it
# tempting and wrong: when it is wrong instead it carries the *client's* width, and nothing in
# the render says so. A sandbox can't catch that, so pin it here.
chk "kit does not trust COLUMNS/LINES while inside a pane" \
  sh -c '! grep -nE "^ *(val|_PANE[A-Z_]*) *= *_?env_?int\(\"(COLUMNS|LINES)\"\)" "$1" \
         && grep -q "if val is None and not pane" "$1"' _ "$KIT"
chk "kit asks tmux about THIS pane (-t \$TMUX_PANE), not the active one" \
  grep -qF '"display", "-p", "-t", pane' "$KIT"
chk "kit ships both axes and a cache invalidator" \
  sh -c 'grep -q "^def pane_width" "$1" && grep -q "^def pane_height" "$1" \
         && grep -q "^def invalidate_pane_size" "$1"' _ "$KIT"

echo
echo "== G. the skill documents the non-Python branch and its fixture =="
chk "skill carries the shell width-math pattern" \
  grep -qF '%-[0-9]+s|\$\{#' "$CONSOLE"
chk "skill carries the shell SGR palette pattern" \
  grep -qF "grep -nE '\\\\033\\[" "$CONSOLE"
chk "skill carries the jq width-math pattern" \
  grep -qF '.[0:' "$CONSOLE"
# Prose alone can't separate a correct width model from ${#s} — only a row with a wide
# glyph can, and it has to reach the renderer. Pin the fixture so it can't quietly vanish.
chk "skill prescribes a wide-glyph fixture row" \
  grep -q 'WIDTH_FIXTURE' "$CONSOLE"
chk "fixture carries a wide glyph, a VS/ZWJ sequence and a mark" \
  sh -c 'grep -A0 "WIDTH_FIXTURE=" "$0" | grep -q "⛔" && grep -A0 "WIDTH_FIXTURE=" "$0" | grep -q "日本語"' "$CONSOLE"
chk "skill says shell printf pads by bytes" \
  grep -q 'budgets \*\*bytes\*\*' "$CONSOLE"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
