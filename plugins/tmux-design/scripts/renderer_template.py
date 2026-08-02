#!/usr/bin/env python3
"""Starter ANSI renderer for a tmux pane — copy into the project's scripts/ and adapt.

Stdlib only, no dependencies. Provides the tmux-design standard's building blocks:
colored section titles, ANSI-safe aligned tables, proximity gauges, and localized
timestamps. A renderer built from this runs ONE-SHOT (print and exit) and lives
under viddy for refresh:

    exec viddy -p -n <secs> -- python3 scripts/<your_view>.py <mode>

Try the standard instantly (e.g. inside a sandbox tmux session):

    python3 renderer_template.py demo
"""

import os
import re
import sys
from datetime import datetime, timezone

# Machine-local zone — panes are read at a glance, so mentally converting UTC costs
# more than the timestamp saves. Pin a fixed zone (e.g. timezone(timedelta(hours=7)))
# only when the pane tracks one market's clock, and label it in the header when you do.
LOCAL_TZ = datetime.now().astimezone().tzinfo
COLOR = "NO_COLOR" not in os.environ     # panes aren't TTYs — always emit unless opted out
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# The standard palette (ANSI 256)
TITLE = "1;38;5;212"   # pink bold — section titles
HEAD = "1;38;5;117"    # cyan bold — table headers
DIM = "2"              # dim — borders, secondary text, empty states
GREEN = "38;5;114"     # positive / OK / fresh
RED = "38;5;203"       # negative / error / stale
YELLOW = "38;5;221"    # pending / warning
HOT = "1;38;5;208"     # orange bold — imminent / hot zone


def c(code, s):
    """Wrap s in an ANSI color unless NO_COLOR is set."""
    return f"\x1b[{code}m{s}\x1b[0m" if COLOR else str(s)


def vlen(s):
    """Visible length — measure AFTER stripping ANSI codes, or padding breaks."""
    return len(ANSI_RE.sub("", str(s)))


def trunc(s, n):
    s = str(s or "")
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def num(s):
    """Strip exchange-style trailing zeros: '60800.00000000' -> '60800'."""
    s = str(s or "-")
    if re.fullmatch(r"\d+\.\d*0", s):
        s = s.rstrip("0").rstrip(".")
    return s


def local_ts(ts_utc, fmt="%d %b %H:%M"):
    """'2026-07-12T12:55:21Z' -> short local-time form."""
    try:
        dt = datetime.strptime(ts_utc, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        return dt.astimezone(LOCAL_TZ).strftime(fmt)
    except Exception:
        return ts_utc or "-"


def title(text):
    print(c(TITLE, f"▌ {text}"))


def none_line(msg="none"):
    print(c(DIM, f"  ∅ {msg}"))
    print()


def table(headers, rows, ralign=()):
    """Aligned columns: bold header, thin dim rule, 2-space gaps, ANSI-safe padding.
    ralign = set of column indexes to right-align (numerics)."""
    widths = [vlen(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], vlen(cell))

    def fmt(cells, colorize=None):
        out = []
        for i, cell in enumerate(cells):
            pad = " " * (widths[i] - vlen(cell))
            text = f"{pad}{cell}" if i in ralign else f"{cell}{pad}"
            out.append(colorize(text) if colorize else text)
        return "  " + "  ".join(out)

    print(fmt(headers, colorize=lambda s: c(HEAD, s)))
    print(c(DIM, "  " + "─" * (sum(widths) + 2 * (len(widths) - 1))))
    for row in rows:
        print(fmt(row))
    print()


def gauge(pct, hot_at=5, warm_at=12, span=20, cells=8):
    """Proximity gauge: 0% -> full bar (imminent), >=span% -> empty (far).
    Renders like '▰▰▰▰▰▰▱▱ +3.4%' with heat coloring."""
    filled = max(0, min(cells, round((1 - pct / span) * cells)))
    col = HOT if pct <= hot_at else YELLOW if pct <= warm_at else DIM
    return c(col, "▰" * filled) + c(DIM, "▱" * (cells - filled)) + f" {pct:+.1f}%"


def demo():
    title("DEMO · tmux-design console standard")
    print("  freshness " + c(GREEN, "● 14:32 (2m ago)") + "  ·  state: " + c(DIM, "idle"))
    print()
    table(
        ["item", "state", "value", "delta", "signal"],
        [
            [c("1", "ALPHA"), c(GREEN, "OK"), "1,234.56", c(GREEN, "+$31.57"), gauge(3.4)],
            [c("1", "BETA"), c(YELLOW, "PENDING"), num("60800.00000000"), c(RED, "-$150.78"), gauge(14.1)],
            [c("1", "GAMMA"), c(DIM, "off"), "-", c(DIM, "untracked"), c(RED, "⛔ blocked")],
        ],
        ralign={2, 3},
    )
    none_line("empty-section example")
    print("  " + c(DIM, "legend: ") + gauge(2.0) + c(DIM, "  hot · ") + gauge(18.0) + c(DIM, "  far"))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "demo":
        demo()
    else:
        sys.exit("usage: renderer_template.py demo   (copy & adapt for real views)")
