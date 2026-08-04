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

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
