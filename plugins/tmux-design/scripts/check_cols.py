#!/usr/bin/env python3
"""Report lines that exceed a pane's column budget. Silence (and exit 0) is the pass.

Usage:
    <renderer command> | check_cols.py <budget> [--reserve N]

    <budget>       columns available, normally the pane width
    --reserve N    columns to subtract from <budget> before checking (default 0).
                   Use --reserve 1 for a viddy pane: viddy keeps the right-hand
                   column for its scrollbar once content fills the pane, so the
                   real content area is one narrower than the pane. Getting this
                   subtraction wrong by hand is the usual reason a "passing"
                   renderer still wraps in production.

Exit status:
    0  every line fits            (prints nothing)
    1  at least one line is over  (prints "line N: X cols > B" per offender)
    2  bad usage

Why this exists as a shipped script rather than a snippet in the skill:
width in terminal columns is not len(), not `awk length()`, and not "strip
\\x1b[...m and count characters". Each of those has been improvised into this
plugin's verify loop and each was wrong — the last one measured a 10-column
OSC-8 hyperlinked cell at 43 columns, because it stripped SGR but not OSC.
So this measures with the kit's own vlen(), which is the same function the
renderers pad and truncate with.

The oracle is deliberately THIS plugin's renderer_template.vlen(), not the
project's adapted copy (rule 7's scripts/<name>_view.py). A checker that
imported the project's copy would let a renderer with a broken width model
grade its own homework: both sides would agree on the wrong number and the
crooked table would pass.

Scope — what a silent run does and does not prove:
  * It proves no line OVERFLOWS the budget.
  * It does NOT prove the columns line up. An over-measured cell makes a row
    too SHORT, which fits fine and still looks crooked.
  * Feed it the renderer's stdout, never a `capture-pane` capture. Without -J
    a capture returns the pane's screen grid, already hard-wrapped at pane
    width, so every line fits by construction and the check cannot fail.
"""

import sys

# Importing a sibling would otherwise scatter __pycache__/ through the installed
# plugin dir, which is read-mostly and not ours to litter.
sys.dont_write_bytecode = True

# sys.path[0] is this script's own directory, so the sibling resolves at any
# install location regardless of cwd. Imported at module level on purpose: a
# missing sibling should fail loudly here, not silently mid-check.
from renderer_template import vlen  # noqa: E402


def main(argv):
    args = argv[1:]
    reserve = 0
    if "--reserve" in args:
        i = args.index("--reserve")
        try:
            reserve = int(args[i + 1])
        except (IndexError, ValueError):
            print("check_cols.py: --reserve needs an integer", file=sys.stderr)
            return 2
        del args[i:i + 2]

    if len(args) != 1:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        budget = int(args[0]) - reserve
    except ValueError:
        print(f"check_cols.py: bad budget {args[0]!r}", file=sys.stderr)
        return 2

    over = 0
    stream = open(sys.stdin.fileno(), encoding="utf-8", errors="replace")
    for i, line in enumerate(stream, 1):
        # Tabs measure zero columns once escapes are stripped, so a tab-indented
        # line would report clean while it visibly wraps.
        n = vlen(line.rstrip("\n").expandtabs(8))
        if n > budget:
            print(f"line {i}: {n} cols > {budget}")
            over += 1
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
