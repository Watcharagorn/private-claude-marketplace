#!/usr/bin/env python3
"""Starter ANSI renderer for a tmux pane — copy into the project's scripts/ and adapt.

Stdlib only, no dependencies. Provides the tmux-design standard's building blocks:
themed semantic colors, column-correct width math, aligned tables, panels, bars,
sparklines, badges, and localized timestamps. A renderer built from this runs
ONE-SHOT (print and exit) and lives under viddy for refresh:

    exec viddy -p --unfold -n <secs> -- python3 scripts/<your_view>.py <mode>

See the whole vocabulary rendered:

    python3 renderer_template.py demo
    python3 renderer_template.py demo --theme catppuccin-mocha
    python3 renderer_template.py demo --depth 16 --ascii

Call sites should name a semantic ROLE (`c(OK, "healthy")`), never a raw color.
That indirection is what lets one theme change restyle every pane at once, and
what makes the 256-color and 16-color fallbacks possible at all.
"""

import os
import re
import sys
import unicodedata
from datetime import datetime, timezone

# Machine-local zone — panes are read at a glance, so mentally converting UTC costs
# more than the timestamp saves. Pin a fixed zone (e.g. timezone(timedelta(hours=7)))
# only when the pane tracks one market's clock, and label it in the header when you do.
LOCAL_TZ = datetime.now().astimezone().tzinfo

# Matches EVERY escape a renderer can emit, not just SGR: CSI sequences (cursor
# moves, erases, colors) and OSC strings (notably OSC 8 hyperlinks, whose text is
# visible but whose wrapper is not). An SGR-only pattern makes a hyperlinked cell
# measure ~30 columns too wide, which silently destroys table alignment.
ANSI_RE = re.compile(
    r"\x1b\][\s\S]*?(?:\x07|\x1b\\)"          # OSC ... BEL | ST
    r"|[\x1b\x9b][\[\]()#;?]*"                 # CSI (and 8-bit CSI)
    r"(?:\d{1,4}(?:[;:]\d{0,4})*)?"
    r"[\dA-PR-TZcf-nq-uy=><~]"
)

# Bidi overrides and isolates. They measure zero columns but visually reverse
# everything after them — a layout bug and a spoofing vector when the text came
# from a branch name, a log line, or a commit message.
_BIDI = "".join(chr(cp) for cp in
                [0x061C, 0x200E, 0x200F, *range(0x202A, 0x202F), *range(0x2066, 0x206A)])
_BIDI_RE = re.compile("[" + _BIDI + "]")
_CTRL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")

# ---------------------------------------------------------------- color depth

_FORCE_MAP = {"0": "none", "false": "none", "1": "16", "2": "256", "3": "truecolor"}


def _detect_depth():
    """Resolve how much color this pane can carry.

    Deliberately does NOT check isatty(). A tmux pane is not a TTY from the
    renderer's point of view, so every library that auto-detects will strip
    color and leave you with a monochrome pane. Emitting color unconditionally
    is the correct default here; NO_COLOR is the opt-out.
    """
    if os.environ.get("NO_COLOR", ""):        # spec: present and non-empty wins
        return "none"
    forced = os.environ.get("FORCE_COLOR")
    if forced is not None:
        return _FORCE_MAP.get(forced.lower(), "256")
    term = os.environ.get("TERM", "")
    if term in ("", "dumb"):
        return "none"
    colorterm = os.environ.get("COLORTERM", "").lower()
    if "truecolor" in colorterm or "24bit" in colorterm:
        return "truecolor"
    if "-direct" in term:
        return "truecolor"
    if "256color" in term:
        return "256"
    return "16"


DEPTH = _detect_depth()

# ------------------------------------------------------------------- themes

# Semantic roles. Name these at call sites; never a raw color code.
TITLE = "title"      # section headings
HEAD = "head"        # table header row
TEXT = "text"        # body text
DIM = "dim"          # secondary text, empty states
MUTED = "muted"      # labels, units
BORDER = "border"    # rules, frames, panel edges
OK = "ok"            # positive / healthy / fresh
WARN = "warn"        # pending / aging
ERR = "err"          # negative / error / stale
HOT = "hot"          # imminent / needs attention now
ACCENT = "accent"    # highlight, links, selected
SEL_BG = "sel_bg"    # selected-row background
BANNER_BG = "banner_bg"  # banner / header strip background

# Attributes are theme-independent: they carry emphasis, not hue, so they
# survive every degradation step including 16-color terminals.
ROLE_ATTRS = {TITLE: ("bold",), HEAD: ("bold",), HOT: ("bold",)}

THEMES = {
    # The palette this plugin shipped originally, reproduced byte-for-byte so
    # renderers already copied into projects keep rendering identically.
    "ansi256-legacy": {
        TITLE: 212, HEAD: 117, TEXT: None, DIM: "@dim", MUTED: "@dim",
        BORDER: "@dim", OK: 114, ERR: 203, WARN: 221, HOT: 208,
        ACCENT: 212, SEL_BG: 238, BANNER_BG: 236,
    },
    "catppuccin-mocha": {
        TITLE: "#f5c2e7", HEAD: "#89b4fa", TEXT: "#cdd6f4", DIM: "#6c7086",
        MUTED: "#a6adc8", BORDER: "#45475a", OK: "#a6e3a1", WARN: "#f9e2af",
        ERR: "#f38ba8", HOT: "#fab387", ACCENT: "#cba6f7",
        SEL_BG: "#313244", BANNER_BG: "#181825",
    },
    # The light counterpart is not optional. Mocha's accents are invisible on a
    # light background; Latte's are deliberately much darker, which is the whole
    # reason a light theme has to be authored rather than derived.
    "catppuccin-latte": {
        TITLE: "#ea76cb", HEAD: "#1e66f5", TEXT: "#4c4f69", DIM: "#9ca0b0",
        MUTED: "#6c6f85", BORDER: "#bcc0cc", OK: "#40a02b", WARN: "#df8e1d",
        ERR: "#d20f39", HOT: "#fe640b", ACCENT: "#8839ef",
        SEL_BG: "#ccd0da", BANNER_BG: "#e6e9ef",
    },
    "tokyo-night": {
        TITLE: "#bb9af7", HEAD: "#7aa2f7", TEXT: "#c0caf5", DIM: "#565f89",
        MUTED: "#a9b1d6", BORDER: "#3b4261", OK: "#9ece6a", WARN: "#e0af68",
        ERR: "#f7768e", HOT: "#ff9e64", ACCENT: "#7dcfff",
        SEL_BG: "#283457", BANNER_BG: "#16161e",
    },
    "nord": {
        TITLE: "#b48ead", HEAD: "#81a1c1", TEXT: "#eceff4", DIM: "#4c566a",
        MUTED: "#d8dee9", BORDER: "#434c5e", OK: "#a3be8c", WARN: "#ebcb8b",
        ERR: "#bf616a", HOT: "#d08770", ACCENT: "#88c0d0",
        SEL_BG: "#3b4252", BANNER_BG: "#2e3440",
    },
    "gruvbox-dark": {
        TITLE: "#d3869b", HEAD: "#83a598", TEXT: "#ebdbb2", DIM: "#928374",
        MUTED: "#bdae93", BORDER: "#504945", OK: "#b8bb26", WARN: "#fabd2f",
        ERR: "#fb4934", HOT: "#fe8019", ACCENT: "#8ec07c",
        SEL_BG: "#3c3836", BANNER_BG: "#282828",
    },
    # Rose Pine has no green in its palette, so OK maps to foam (cyan). That is a
    # real compromise, not an oversight — pair OK with a ✓ glyph in this theme so
    # the meaning does not rest on hue alone.
    "rose-pine": {
        TITLE: "#c4a7e7", HEAD: "#9ccfd8", TEXT: "#e0def4", DIM: "#6e6a86",
        MUTED: "#908caa", BORDER: "#403d52", OK: "#9ccfd8", WARN: "#f6c177",
        ERR: "#eb6f92", HOT: "#ebbcba", ACCENT: "#31748f",
        SEL_BG: "#26233a", BANNER_BG: "#1f1d2e",
    },
}

THEME_NAME = os.environ.get("TMUX_DESIGN_THEME", "ansi256-legacy")
if THEME_NAME not in THEMES:
    THEME_NAME = "ansi256-legacy"
THEME = THEMES[THEME_NAME]

# Kept for backwards compatibility with the original template's `COLOR` flag.
COLOR = DEPTH != "none"

# ------------------------------------------------------------ color plumbing

# xterm's canonical first 16, used to pick the nearest basic color on a
# 16-color terminal. Approximate by design — 16 colors cannot represent a theme.
_BASE16 = [
    (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
    (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
    (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
]


def _hex_rgb(h):
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def _rgb_to_256(r, g, b):
    """Quantize onto the xterm 256 cube. Note the grayscale ramp is separate —
    a theme's surface colors are near-gray and collapse toward the same few
    indices here, which is why the 256 fallback must be eyeballed, not assumed."""
    if r == g == b:
        if r < 8:
            return 16
        if r > 248:
            return 231
        return ((r - 8) * 24 // 247) + 232
    return 16 + 36 * (r * 5 // 255) + 6 * (g * 5 // 255) + (b * 5 // 255)


def _rgb_to_16(r, g, b):
    best, bestd = 7, None
    for i, (br, bg, bb) in enumerate(_BASE16):
        d = (r - br) ** 2 + (g - bg) ** 2 + (b - bb) ** 2
        if bestd is None or d < bestd:
            best, bestd = i, d
    return 30 + best if best < 8 else 90 + best - 8


def _idx_to_rgb(n):
    """Invert the xterm 256 cube so an explicit index can degrade to 16 colors."""
    if n < 16:
        return _BASE16[n]
    if n >= 232:
        v = 8 + 10 * (n - 232)
        return (v, v, v)
    i = n - 16
    levels = (0, 95, 135, 175, 215, 255)
    return (levels[i // 36], levels[(i % 36) // 6], levels[i % 6])


def _color_params(value, background=False):
    """Turn one theme value into SGR parameters for the current depth."""
    if value is None or DEPTH == "none":
        return []
    if value == "@dim":                        # attribute-only, no hue
        return ["2"]
    if isinstance(value, int):                 # explicit 256 index
        if DEPTH == "16":
            # Degrade rather than drop. Returning nothing here would leave a
            # 16-color terminal with no hue at all, which is the monochrome pane
            # the whole standard exists to prevent.
            code = _rgb_to_16(*_idx_to_rgb(value))
            return [str(code + 10 if background else code)]
        return [("48" if background else "38"), "5", str(value)]
    r, g, b = _hex_rgb(value)
    if DEPTH == "truecolor":
        return [("48" if background else "38"), "2", str(r), str(g), str(b)]
    if DEPTH == "256":
        return [("48" if background else "38"), "5", str(_rgb_to_256(r, g, b))]
    code = _rgb_to_16(r, g, b)
    return [str(code + 10 if background else code)]


_ATTR_CODES = {"bold": "1", "dim": "2", "italic": "3", "reverse": "7"}
_RAW_SGR_RE = re.compile(r"^[0-9;]+$")


def sgr(role, bg=None, attrs=()):
    """Build the SGR parameter string for a semantic role."""
    if DEPTH == "none":
        return ""
    params = [_ATTR_CODES[a] for a in tuple(ROLE_ATTRS.get(role, ())) + tuple(attrs)
              if a in _ATTR_CODES]
    params += _color_params(THEME.get(role))
    if bg is not None:
        params += _color_params(THEME.get(bg), background=True)
    return ";".join(p for p in params if p)


def role_index(role, colors=256):
    """Resolve a semantic role to a *color index*, for output APIs that take a
    number instead of an SGR string — curses (`init_pair`) above all.

    Returns None when the role carries no hue of its own: `TEXT` (terminal
    default) and the `@dim` sentinel, which is an attribute rather than a color.
    None is the correct argument to pass curses for "leave it alone" — pair it
    with `A_DIM` for the sentinel — so it is a value to forward, not an error.

    `colors` is the terminal's palette size (`curses.COLORS`); below 256 the
    role degrades to a basic 0-7 index the same way `_color_params` degrades to
    SGR 30-37, rather than dropping out. This exists so a curses renderer never
    has to re-derive quantization — that is rule 7's re-derivation trap in a
    third language, and the kit already owns the only correct converter."""
    value = THEME.get(role)
    if value is None or value == "@dim":
        return None
    if colors >= 256:
        return value if isinstance(value, int) else _rgb_to_256(*_hex_rgb(value))
    # Degrade from the ORIGINAL value, exactly as _color_params does — never from
    # the 256 index. Quantizing to the cube and inverting it back is lossy twice,
    # and it collapses a whole theme: measured on catppuccin-mocha, that route
    # sent title/head/ok/warn/err/hot all to 7 (white), destroying the very
    # ok/warn/err separation the 16-color tier is supposed to preserve.
    rgb = _idx_to_rgb(value) if isinstance(value, int) else _hex_rgb(value)
    code = _rgb_to_16(*rgb)                    # SGR 30-37 (dim) or 90-97 (bright)
    basic = code - 30 if code < 90 else code - 90 + 8
    return basic if basic < colors else basic % 8


def c(spec, s, bg=None, attrs=()):
    """Colorize `s`.

    `spec` is normally a semantic role (TITLE, OK, ERR …). A raw SGR parameter
    string such as "1;38;5;212" is also accepted so renderers written against
    the original template keep working unchanged.
    """
    if DEPTH == "none":
        return str(s)
    if isinstance(spec, str) and spec not in THEME and _RAW_SGR_RE.match(spec):
        code = spec                                   # legacy call site
    else:
        code = sgr(spec, bg=bg, attrs=attrs)
    if not code:
        return str(s)
    return f"\x1b[{code}m{s}\x1b[0m"


# ------------------------------------------------------------- width & text

_VS16, _VS15, _ZWJ = "\uFE0F", "\uFE0E", "\u200D"


def _base_width(ch):
    cat = unicodedata.category(ch)
    if cat in ("Mn", "Me", "Cf"):
        return 0
    if cat == "Cc":
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def _clusters(s):
    """Approximate UAX #29 grapheme clusters using only the stdlib.

    Exact segmentation needs Unicode tables Python does not expose, but the
    cases that actually break a pane are covered: combining marks, variation
    selectors, ZWJ sequences, skin-tone modifiers and regional-indicator pairs.
    """
    out, i, n = [], 0, len(s)
    while i < n:
        start = i
        i += 1
        while i < n:
            ch = s[i]
            cp = ord(ch)
            if unicodedata.category(ch) in ("Mn", "Mc", "Me"):
                i += 1
            elif ch in (_VS16, _VS15):
                i += 1
            elif 0x1F3FB <= cp <= 0x1F3FF:                 # skin tone modifier
                i += 1
            elif ch == _ZWJ:
                i += 2 if i + 1 < n else 1                 # ZWJ binds what follows
            elif 0x1F1E6 <= cp <= 0x1F1FF and 0x1F1E6 <= ord(s[start]) <= 0x1F1FF \
                    and i == start + 1:                    # flag = RI pair
                i += 1
            else:
                break
        out.append(s[start:i])
    return out


def cluster_width(cl):
    if len(cl) == 2 and all(0x1F1E6 <= ord(ch) <= 0x1F1FF for ch in cl):
        return 2                    # 🇯🇵 — a flag is one 2-column glyph
    w = _base_width(cl[0])
    if _VS16 in cl and w == 1:
        w = 2                       # ⚠ is 1 column, ⚠️ is 2
    elif _VS15 in cl and w == 2:
        w = 1
    if len(cl) > 1 and _ZWJ in cl:
        w = 2                       # 🧑‍🌾 renders as one 2-column glyph
    return max(0, min(2, w))        # every cluster occupies at most 2 cells


def vlen(s):
    """Visible width in TERMINAL COLUMNS, after stripping escapes.

    Not the same as len(): '⛔' is one character but occupies two columns, and
    a colored or hyperlinked cell is mostly invisible bytes. Padding computed
    from len() is the single most common cause of a table that looks crooked.
    """
    return sum(cluster_width(cl) for cl in _clusters(ANSI_RE.sub("", str(s))))


def trunc(s, n, ellipsis="…"):
    """Truncate to `n` display columns, preserving color and never cutting
    inside an escape sequence.

    Escapes are copied through verbatim because they cost zero columns; only
    printable clusters consume budget. Cutting mid-escape would spill raw
    `[38;5;` garbage into the pane, and dropping the escapes would leave the
    rest of the line wearing the truncated cell's color.
    """
    s = str(s or "")
    if vlen(s) <= n:
        return s
    budget = n - vlen(ellipsis)
    out, used, i, colored = [], 0, 0, False
    while i < len(s):
        m = ANSI_RE.match(s, i)
        if m:
            out.append(m.group())
            colored = True
            i = m.end()
            continue
        cl = _clusters(s[i:i + 8])[0]
        w = cluster_width(cl)
        if used + w > budget:
            break
        out.append(cl)
        used += w
        i += len(cl)
    return "".join(out) + ("\x1b[0m" if colored else "") + ellipsis


def sanitize(s):
    """Make untrusted text safe to lay out — branch names, log lines, commits.

    Strips bidi overrides (zero width, but they visually reverse the rest of the
    row) and control characters. ZWJ is deliberately preserved so emoji keep
    rendering as one glyph.
    """
    return _CTRL_RE.sub("", _BIDI_RE.sub("", str(s or "")))


def pad(s, width, right=False):
    """Pad to `width` display columns. Use instead of str.ljust on colored text."""
    fill = " " * max(0, width - vlen(s))
    return f"{fill}{s}" if right else f"{s}{fill}"


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


# ---------------------------------------------------------------- primitives

# Border sets. Weights never mix — there are no glyphs that join light to heavy,
# and rounded corners exist only in light. ASCII is the fallback for terminals
# in a CJK locale, where box-drawing characters are East-Asian-Ambiguous and
# render two columns wide, tearing every frame apart.
BORDERS = {
    "light":   "─│┌┐└┘",
    "rounded": "─│╭╮╰╯",
    "heavy":   "━┃┏┓┗┛",
    "double":  "═║╔╗╚╝",
    "ascii":   "-|++++",
}
BORDER_STYLE = os.environ.get("TMUX_DESIGN_BORDER", "rounded")


def _bset():
    return BORDERS.get(BORDER_STYLE, BORDERS["rounded"])


def title(text, width=None):
    """The pane's headline — capped like every other primitive.

    It was the one text helper with no width awareness, and it is the line most
    likely to be composed against a wide pane and read in a narrow one (a theme
    name and three flags is already 69 columns). A title that wraps costs a row
    and shoves the whole frame down; under viddy that is also how the
    scrollbar-feeds-wrapping cycle starts.
    """
    width = width or pane_width()
    print(c(TITLE, trunc(f"▌ {sanitize(text)}", width)))


def divider(label=None, width=None, style=None):
    """A horizontal rule, optionally labelled — the cheapest way to group rows."""
    h = (style or _bset())[0]
    width = width or pane_width()
    if not label:
        print(c(BORDER, h * width))
        return
    label = f" {sanitize(label)} "
    left = 2
    right = max(0, width - left - vlen(label))
    print(c(BORDER, h * left) + c(MUTED, label) + c(BORDER, h * right))


def spread(left, right, width=None, fill=" ", min_gap=3):
    """Left-label ... right-value, filled to width with a guaranteed min gap.

    RIGHT is the live/changing value (a timestamp, countdown, freshness stamp)
    and is never dropped to make room — LEFT truncates (down to nothing) first,
    so a header never silently loses its freshness signal. `fill` must measure
    as exactly 1 column via `vlen()` (catches an accidental CJK/emoji fill) —
    but like every primitive here it inherits the kit-wide EAW=Ambiguous
    caveat: a box-drawing fill such as '─' measures 1 by this kit's Western-
    locale default and passes the guard, yet may still render 2 columns wide
    in a CJK-locale terminal (see "East Asian Width Ambiguous" above). Prefer
    a plain space or an EAW=N mark as `fill`.
    """
    width = width or pane_width()
    left, right = str(left), str(right)
    if vlen(fill) != 1:
        raise ValueError("spread(): fill must be exactly 1 display column wide")
    room = max(0, width - vlen(right) - min_gap)
    if vlen(left) > room:
        left = trunc(left, room) if room > 0 else ""
    gap = max(min_gap, width - vlen(left) - vlen(right))
    print(left + fill * gap + right)


def panel(lines, heading=None, width=None, style=None):
    """Frame a block of content. Costs 2 columns and 2 rows — budget for it."""
    b = style or _bset()
    h, v, tl, tr, bl, br = b[0], b[1], b[2], b[3], b[4], b[5]
    inner = max(1, (width or pane_width()) - 2)
    lines = [trunc(x, inner) for x in lines]
    if heading:
        heading = trunc(f" {sanitize(heading)} ", inner - 1)
        fill = max(0, inner - 1 - vlen(heading))
        print(c(BORDER, tl + h) + c(TITLE, heading) + c(BORDER, h * fill + tr))
    else:
        print(c(BORDER, tl + h * inner + tr))
    for line in lines:
        print(c(BORDER, v) + pad(line, inner) + c(BORDER, v))
    print(c(BORDER, bl + h * inner + br))


def none_line(msg="none"):
    print(c(DIM, f"  ∅ {msg}"))
    print()


def table(headers, rows, ralign=(), width=None):
    """Aligned columns: bold header, thin rule, 2-space gaps, column-safe padding.

    ralign = set of column indexes to right-align (numerics).
    width  = hard cap in display columns, defaulting to the pane like every
             sibling primitive. When the natural width exceeds it the widest
             column is trimmed until it fits — a table that wraps is worse than
             the raw text it replaced, so truncating one cell beats letting the
             terminal fold every row. It used to cap only when a width was
             passed, so the helper whose docstring promises this most loudly was
             the one that silently wrapped: demo data fits and a long branch name
             or a CJK product name does not.
    """
    widths = [vlen(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], vlen(cell))

    width = width or pane_width()
    if width:
        gaps = 2 + 2 * (len(widths) - 1)
        while sum(widths) + gaps > width and max(widths) > 3:
            widths[widths.index(max(widths))] -= 1
        rows = [[trunc(c, widths[i]) for i, c in enumerate(r)] for r in rows]
        headers = [trunc(h, widths[i]) for i, h in enumerate(headers)]

    def fmt(cells, colorize=None):
        out = []
        for i, cell in enumerate(cells):
            text = pad(cell, widths[i], right=i in ralign)
            out.append(colorize(text) if colorize else text)
        return "  " + "  ".join(out)

    print(fmt(headers, colorize=lambda s: c(HEAD, s)))
    print(c(BORDER, "  " + _bset()[0] * (sum(widths) + 2 * (len(widths) - 1))))
    for row in rows:
        print(fmt(row))
    print()


def kv(pairs, indent="  "):
    """Label/value lines with the labels aligned — for single-value readouts."""
    if not pairs:
        return none_line()
    w = max(vlen(k) for k, _ in pairs)
    for k, v in pairs:
        print(indent + c(MUTED, pad(k, w)) + "  " + str(v))


# Horizontal eighths run DESCENDING in code point order (U+258F → U+2588); the
# sparkline set below runs ASCENDING. Mixing them up is a classic off-by-one.
_HBLOCKS = "▏▎▍▌▋▊▉█"
_SPARKS = "▁▂▃▄▅▆▇█"


def bar(pct, width=20, role=None, show_pct=True):
    """Determinate progress, 0.0–1.0, with sub-cell resolution.

    Eighth-blocks give a 20-cell bar the precision of a 160-cell one, which is
    what makes a narrow pane still show real movement instead of a stuck block.
    """
    pct = max(0.0, min(1.0, pct))
    role = role or (ERR if pct >= 0.9 else WARN if pct >= 0.75 else OK)
    cells = pct * width
    full = int(cells)
    eighths = int(round((cells - full) * 8))
    if eighths == 8:
        full, eighths = full + 1, 0
    filled = "█" * full + (_HBLOCKS[eighths - 1] if eighths else "")
    track = "░" * max(0, width - vlen(filled))
    out = c(role, filled) + c(BORDER, track)
    return out + (f" {pct * 100:5.1f}%" if show_pct else "")


def sparkline(values, role=None):
    """Compact trend for a time series — 1 column per sample, no axes.

    A true zero renders as a space rather than ▁, because ▁ already shows ink
    and would read as "small but present" when the value is actually nothing.
    """
    vals = [v for v in values if v is not None]
    if not vals:
        return c(DIM, "∅")
    lo, hi = min(vals), max(vals)
    out = []
    for v in values:
        if v is None:
            out.append(" ")
        elif v == 0 and lo >= 0:
            out.append(" ")
        elif hi == lo:
            out.append(_SPARKS[3])
        else:
            out.append(_SPARKS[int(round((v - lo) / (hi - lo) * 7))])
    return c(role or ACCENT, "".join(out))


def badge(text, role=OK):
    """A filled chip. Reads faster than colored text when scanning a column."""
    if DEPTH == "none":
        return f"[{text}]"
    return c(BANNER_BG, f" {text} ", bg=role, attrs=("bold",))


def gauge(pct, hot_at=5, warm_at=12, span=20, cells=8):
    """Proximity gauge: 0% -> full bar (imminent), >=span% -> empty (far).

    Deliberately inverted, and deliberately not bar(): this answers "how close
    is it?", where a progress bar answers "how much is done?".
    Renders like '▰▰▰▰▰▰▰▱ +3.4%' with heat coloring."""
    filled = max(0, min(cells, round((1 - pct / span) * cells)))
    col = HOT if pct <= hot_at else WARN if pct <= warm_at else DIM
    return c(col, "▰" * filled) + c(DIM, "▱" * (cells - filled)) + f" {pct:+.1f}%"


def freshness(age_s, ts=None, fresh_s=300, stale_s=900):
    """Colored heartbeat — the fastest way to see a pane has silently died."""
    role = OK if age_s <= fresh_s else WARN if age_s <= stale_s else ERR
    stamp = ts or datetime.now(LOCAL_TZ).strftime("%H:%M")
    ago = f"{int(age_s // 60)}m" if age_s >= 60 else f"{int(age_s)}s"
    return c(role, f"● {stamp}") + c(DIM, f" ({ago} ago)")


_PANE_SIZE = {}


def _pane_dim(axis, knob, fmt, envvar, default, refresh=False):
    """One precedence, two axes — the resolver behind pane_width()/pane_height().

    Both axes share this body on purpose: the order below is subtle enough that a
    second hand-written copy is where the two would drift apart.

    1. The explicit knob (`$TMUX_PANE_WIDTH` / `$TMUX_PANE_HEIGHT`). The verify
       loop drives it to sweep sizes, so nothing may outrank it.
    2. tmux, asked about **this** pane via `-t "$TMUX_PANE"`. Untargeted,
       `tmux display -p '#{pane_width}'` answers about the server's *active*
       pane — whichever window happens to be focused — so a renderer running
       outside tmux got a live stranger's width instead of `default`, and one in
       an unfocused pane got the focused pane's. Nothing raises; the table is
       just silently sized to a pane nobody was looking at.
    3. `$COLUMNS` / `$LINES`, and only when `$TMUX_PANE` is unset — when there
       is genuinely no pane to ask about, they are the only signal left. Inside
       a pane they are refused deliberately, and measuring them is what shows
       why: under viddy 1.3.1 they are *correct* (viddy sets the child's
       COLUMNS/LINES to the full pane size and updates them on resize), which is
       exactly what makes trusting them a trap. When they are wrong instead —
       exported by the terminal that launched the workspace, so carrying the
       client's size rather than the pane's — they are wrong silently and look
       just as plausible. tmux is right in both cases, so ask tmux.
    4. `default`.

    Cached per axis: a pane renderer re-runs every few seconds forever and one
    subprocess per call would be a wasted fork on every redraw. A renderer that
    owns its own paint loop has to refetch on resize — pass `refresh=True` or
    call `invalidate_pane_size()`, because a stale height makes the body keep
    painting the pre-resize row count, which reads as a clean frame with its
    last rows simply missing.
    """
    if not refresh and axis in _PANE_SIZE:
        return _PANE_SIZE[axis]

    def _env_int(name):
        try:
            return int(os.environ[name])
        except (KeyError, ValueError):
            return None

    val = _env_int(knob)
    pane = os.environ.get("TMUX_PANE")
    if val is None and pane:
        try:
            import subprocess
            out = subprocess.run(["tmux", "display", "-p", "-t", pane, fmt],
                                 capture_output=True, text=True, timeout=1)
            val = int(out.stdout.strip())
        except Exception:
            val = None
    if val is None and not pane:
        val = _env_int(envvar)
    _PANE_SIZE[axis] = default if val is None else val
    return _PANE_SIZE[axis]


def pane_width(default=80, refresh=False):
    """The pane's width in columns — the PANE, not the area you get to draw in.

    Subtract the refresh wrapper's cut yourself: 1 column under `viddy -p`, 0
    under `watch -c` or an own loop. The reserve depends on flags this function
    cannot see, and `check_cols.py --reserve` subtracts it once at check time, so
    pre-subtracting here would double-count it. See primitives.md, "Motion,
    repaint, and the wrapper's cut".
    """
    return _pane_dim("width", "TMUX_PANE_WIDTH", "#{pane_width}", "COLUMNS",
                     default, refresh)


def pane_height(default=24, refresh=False):
    """The pane's height in rows — the PANE, not the area you get to draw in.

    Same contract as pane_width(): subtract the wrapper's rows yourself (4 for a
    default-header viddy pane, 1 under `viddy -t`, 2 under `watch -c`), and
    derive that total once. The same number written twice misdimensions the body
    the first time a row is added or cut, silently and only at some heights.
    """
    return _pane_dim("height", "TMUX_PANE_HEIGHT", "#{pane_height}", "LINES",
                     default, refresh)


def invalidate_pane_size():
    """Drop the cached pane size so the next call re-asks tmux.

    For the own-loop shape: call it on SIGWINCH (or once a tick) so the body
    refits now rather than at the next slow redraw.
    """
    _PANE_SIZE.clear()


# ---------------------------------------------------------------------- demo

def demo():
    # This demo is the standard rendered, so it budgets the way the standard says
    # to: start from the pane, subtract the wrapper's cut ONCE, draw in the
    # remainder. The reserve is 1 because `viddy -p` claims the right-hand column
    # for its scrollbar as soon as content *reaches* the content area rather than
    # after it overflows (primitives.md, "Motion, repaint, and the wrapper's
    # cut"); a renderer under `watch -c`, or one owning its loop, sets it to 0.
    # Drawing to the full pane_width() instead is why the demo used to fail the
    # plugin's own `check_cols.py 60 --reserve 1`.
    VIDDY_RESERVE = 1
    w = min(pane_width() - VIDDY_RESERVE, 78)
    title(f"DEMO · tmux-design · theme={THEME_NAME} depth={DEPTH} border={BORDER_STYLE}",
          width=w)
    print("  " + freshness(120, "14:32") + c(DIM, "  ·  state: ") + badge("LIVE", OK))
    print()
    rows = [
        [c(TEXT, "ALPHA"), c(OK, "✓ ok"), "1,234.56", c(OK, "+$31.57"), gauge(3.4)],
        [c(TEXT, "BETA"), c(WARN, "◐ pending"), num("60800.00000000"),
         c(ERR, "-$150.78"), gauge(14.1)],
        [c(TEXT, "GAMMA"), c(DIM, "· off"), "-", c(DIM, "untracked"),
         c(ERR, "⛔ blocked")],
        [c(TEXT, "日本語"), c(OK, "✓ ok"), "42", c(OK, "+$1.00"), gauge(9.0)],
    ]
    # rule 7's wide-glyph fixture. The skill tells you to re-run the renderer with
    # WIDTH_FIXTURE set, and says in the same breath that a fixture the renderer
    # ignores is a check that always passes — so the shipped starter reads it,
    # or it fails its own instruction on the very first copy.
    fixture = os.environ.get("WIDTH_FIXTURE")
    if fixture:
        rows.append([c(TEXT, "FIXTURE"), c(WARN, "◐ wide"), sanitize(fixture),
                     c(DIM, "—"), gauge(11.0)])
    table(["item", "state", "value", "delta", "signal"], rows,
          ralign={2, 3}, width=w)
    spread(c(MUTED, "pane title"), freshness(12, "14:32"), width=w)
    divider("throughput", width=w)
    kv([
        ("requests", sparkline([3, 5, 4, 9, 12, 8, 14, 20, 17, 21]) + c(DIM, "  3→21")),
        ("error rate", bar(0.07, width=24)),
        ("disk", bar(0.93, width=24)),
    ])
    print()
    panel(
        ["  " + c(MUTED, "roles carry meaning, not raw codes:"),
         "  " + "  ".join(c(r, r) for r in (OK, WARN, ERR, HOT, ACCENT, MUTED)),
         c(DIM, "  legend: ") + gauge(2.0) + c(DIM, " hot · ") + gauge(18.0) + c(DIM, " far")],
        heading="palette", width=w,
    )
    print()
    none_line("empty-section example")


def _parse_argv(argv):
    """Tiny flag parser — argparse would be fine, this keeps the copy readable."""
    global THEME, THEME_NAME, DEPTH, COLOR, BORDER_STYLE
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--theme" and i + 1 < len(argv):
            name = argv[i + 1]
            if name not in THEMES:
                sys.exit(f"unknown theme '{name}' — have: {', '.join(sorted(THEMES))}")
            THEME_NAME, THEME = name, THEMES[name]
            i += 2
        elif a == "--depth" and i + 1 < len(argv):
            d = argv[i + 1]
            if d not in ("none", "16", "256", "truecolor"):
                sys.exit("--depth must be none|16|256|truecolor")
            DEPTH, COLOR = d, d != "none"
            i += 2
        elif a == "--ascii":
            BORDER_STYLE = "ascii"
            i += 1
        elif a == "--border" and i + 1 < len(argv):
            if argv[i + 1] not in BORDERS:
                sys.exit(f"unknown border '{argv[i + 1]}' — have: {', '.join(BORDERS)}")
            BORDER_STYLE = argv[i + 1]
            i += 2
        else:
            sys.exit(f"unexpected argument: {a}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "demo":
        _parse_argv(sys.argv[2:])
        demo()
    else:
        sys.exit(
            "usage: renderer_template.py demo [--theme NAME] [--depth none|16|256|truecolor]\n"
            "                                 [--border light|rounded|heavy|double|ascii] [--ascii]\n"
            f"themes: {', '.join(sorted(THEMES))}\n"
            "(copy & adapt this file for real views)"
        )
