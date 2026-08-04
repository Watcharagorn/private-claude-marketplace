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
  grep -nE '\.(ljust|rjust|center)\(|\{:[<>^][0-9]' "$r" | sed 's/^/hand-rolled padding /'
  grep -qE 'TMUX_DESIGN_THEME|role_index' "$r" \
    || grep -nE 'init_pair\(|init_color\(|COLOR_(BLACK|RED|GREEN|YELLOW|BLUE|MAGENTA|CYAN|WHITE)' "$r" \
       | sed 's/^/unthemed curses palette /'
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

# ── Curses + padding fixtures ─────────────────────────────────────────────────────────────
# The session that motivated these: an agent built a curses TUI, declared five color pairs
# from raw 256 indices, and never resolved TMUX_DESIGN_THEME. The three original patterns
# are all structurally incapable of seeing that file — it has no quoted-digit SGR constant,
# no `def vlen`, and it IS Python so the shell/jq half never runs on it.

# The session's actual failure: digits at the mkpair() CALL SITES, not at init_pair().
# This is why the check keys off the missing theme guard rather than off the digits — a
# digit pattern anchored to init_pair( would miss every one of these lines.
cat > "$W/bad_tui.py" <<'EOF'
import curses
def mkpair(idx, fg, bg):
    curses.init_pair(idx, fg, bg)
    return curses.color_pair(idx)
def setup():
    mkpair(1, 212, curses.COLOR_MAGENTA)
    mkpair(2, 117, curses.COLOR_BLUE)
EOF

# Compliant curses renderer #1: takes its numbers from the kit. Names role_index, never
# TMUX_DESIGN_THEME — so the guard must accept BOTH spellings or this correct file is flagged.
cat > "$W/good_tui.py" <<'EOF'
import curses
from renderer_template import role_index, OK, WARN, ERR
def setup(scr):
    curses.start_color(); curses.use_default_colors()
    for i, role in enumerate((OK, WARN, ERR), start=1):
        idx = role_index(role, curses.COLORS)
        curses.init_pair(i, -1 if idx is None else idx, -1)
EOF

# Compliant curses renderer #2: resolves the theme itself, by name.
cat > "$W/good2_tui.py" <<'EOF'
import curses, os
THEME = os.environ.get("TMUX_DESIGN_THEME", "ansi256-legacy")
def setup():
    curses.init_pair(1, ROLES[THEME]["ok"], -1)
EOF

# Hand-padding INSIDE a file that satisfies the cluster_width guard. This is the case the
# width branch cannot reach by construction: the guard silences it wholesale, so `.ljust`
# on a cell that may hold a glyph is invisible to every other pattern in the check.
cat > "$W/handpad_view.py" <<'EOF'
def cluster_width(s):
    return 1
def row(name, status):
    return name.ljust(20) + "{:<12}".format(status)
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
# Must be a shell function, not `sh -c '! reuse_check …'`: a subshell cannot see reuse_check,
# so that spelling reports "command not found", inverts to true, and passes while testing
# nothing — the pass-shaped failure this suite exists to catch, committed in the suite itself.
lacks()  { case "$(out_of "$1")" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

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
echo "== C2. the curses branch: fires on an unthemed TUI, silent on a themed one =="
chk "raw-256 curses TUI fires"                      fires bad_tui.py
chk "reported as unthemed curses palette"           says bad_tui.py 'unthemed curses palette'
# Both halves, as ever. A curses check that also flags the correct implementations is one
# an agent learns to silence by renaming 212 to COLOR_MAGENTA, which changes nothing.
chk "curses TUI using the kit's role_index stays silent"    silent good_tui.py
chk "curses TUI resolving TMUX_DESIGN_THEME stays silent"   silent good2_tui.py
chk "the kit itself stays silent under the curses pattern"  silent copied_view.py

echo
echo "== C3. hand-padding is caught INSIDE a compliant kit copy =="
# The cluster_width guard exists to keep the width branch quiet on a faithful copy — which
# means a copy that also hand-pads is the one file the width branch can never flag. The
# padding pattern therefore runs unguarded; that is the whole point of it.
chk "ljust/format padding fires despite cluster_width"  fires handpad_view.py
chk "reported as hand-rolled padding"                   says handpad_view.py 'hand-rolled padding'
chk "the width branch is BLIND to it (why C3 exists)" \
  lacks handpad_view.py 're-derived width math'
# Credibility: the kit and the checker must not trip the pattern, or it is noise from day one.
chk "kit does not hand-pad"                         silent copied_view.py
chk "check_cols.py does not hand-pad" \
  sh -c '! grep -qE "\.(ljust|rjust|center)\(|\{:[<>^][0-9]" "$0"' "$ROOT_DIR/scripts/check_cols.py"
# Scope, pinned: an extended project renderer legitimately owns .ljust — and the check is
# never RUN on one. The scope line in the skill is what excludes it, not a pattern guard,
# which is exactly the distinction that left a from-scratch TUI unchecked before.
chk "an extended renderer would fire — scope, not the pattern, excludes it" \
  fires extended_view.py

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
chk "skill carries the hand-rolled padding pattern" \
  grep -qF '.(ljust|rjust|center)\(' "$CONSOLE"
chk "skill carries the curses guard (both accepted spellings)" \
  grep -qF "grep -qE 'TMUX_DESIGN_THEME|role_index'" "$CONSOLE"
chk "skill carries the curses palette pattern" \
  grep -qF 'init_pair\(|init_color\(' "$CONSOLE"
# The check only pays off if the flag tells you where to go; otherwise it fires and the
# agent invents a palette anyway, which is the failure it was added to prevent.
chk "curses flag names its destination" \
  grep -q 'Curses renderers.*palette\.md' "$CONSOLE"
# The scope line is what makes every branch above reachable on a from-scratch TUI.
chk "skill scopes the check to any renderer written this pass" \
  grep -q 'any renderer you WROTE this pass' "$CONSOLE"

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
echo "== F3. role_index() is the numeric half of the role vocabulary =="
# Without this the curses guard above has nothing to point at, and a curses renderer's only
# routes to a color number are re-deriving quantization or reaching into a private helper.
chk "kit defines role_index"                        grep -q '^def role_index' "$KIT"
# It must agree with the SGR path exactly, or a curses pane and an ANSI pane in the same
# workspace render the same role as two different colors — the drift the shared vocabulary exists
# to prevent. Checked at BOTH tiers: the 16-color path is a separate branch and was wrong once,
# quantizing to the 256 cube and inverting it back, which flattened a whole theme to white.
chk "role_index agrees with _color_params at 256 and 16" \
  python3 -c '
import sys, os
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
bad = []
for theme in ("ansi256-legacy", "catppuccin-mocha", "catppuccin-latte", "nord"):
    os.environ["TMUX_DESIGN_THEME"] = theme
    import importlib, renderer_template as R
    importlib.reload(R)
    for name in ("TITLE", "HEAD", "TEXT", "DIM", "OK", "WARN", "ERR", "HOT"):
        role = getattr(R, name)
        # Roles with no hue of their own belong to the next assertion: _color_params answers
        # with an ATTRIBUTE ("2" for @dim) or nothing, which is not a color to compare against.
        if R.THEME.get(role) is None or R.THEME.get(role) == "@dim":
            continue
        R.DEPTH = "256"
        p = R._color_params(R.THEME.get(role))
        if p[:2] == ["38", "5"] and str(R.role_index(role)) != p[2]:
            bad.append((theme, name, "256"))
        R.DEPTH = "16"
        p = R._color_params(R.THEME.get(role))
        if p and p[0].isdigit() and len(p) == 1:
            code = int(p[0])
            basic = code - 30 if code < 90 else code - 90 + 8
            if R.role_index(role, colors=8) != basic % 8:
                bad.append((theme, name, "16"))
sys.exit(1 if bad else 0)
' "$ROOT_DIR/scripts"
chk "role_index returns None for the @dim sentinel (an attribute, not a hue)" \
  python3 -c '
import sys, os
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
os.environ["TMUX_DESIGN_THEME"] = "ansi256-legacy"
import renderer_template as R
sys.exit(0 if R.role_index(R.DIM) is None else 1)
' "$ROOT_DIR/scripts"

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
