# tmux chrome — status bar, tabs, borders, popups

Read when theming tmux itself rather than pane content. The generator
`scripts/tmux_theme.sh` emits all of this for a named theme; this file explains what it emits and
how to debug it.

## Prerequisites — truecolor

```tmux
set -g  default-terminal "tmux-256color"        # must be screen*/tmux*; this one adds italics
set -ga terminal-features ",xterm-256color:RGB"
set -ga terminal-features ",alacritty:RGB"
set -ga terminal-features ",*-256color:RGB"
```

Without the `RGB` feature every `#[fg=#89b4fa]` below is silently quantized to the 256 palette.
tmux auto-detects only a handful of terminals (mintty, tmux, urxvt, iTerm2, foot, WezTerm, Ghostty,
xterm) — **Alacritty, Konsole, VTE, Windows Terminal and VS Code all need the line above.**

`terminal-features` (3.2+) supersedes the older `set -ga terminal-overrides ",xterm-256color:Tc"`.
Both work; prefer features. The tmux FAQ is blunt that most display problems are an incorrect
`TERM`. If `infocmp tmux-256color` fails (macOS ships an old ncurses), `brew install ncurses` or
fall back to `screen-256color`.

Other useful features: `clipboard hyperlinks usstyle sync overline strikethrough sixel progressbar`.

## Status bar

```tmux
set -g status-left-length 100      # default is 10  ← the #1 truncation trap
set -g status-right-length 120     # default is 40
set -g status-interval 5
set -g status-style "bg=#1a1b26,fg=#c0caf5"
set -g status-justify left         # left | centre | right | absolute-centre
set -g status-position bottom      # top | bottom
```

`set -g status 2` (up to 5) adds extra rows filled by `status-format[N]`. `status-format[0]` is
always the topmost row of the block, in both positions. Since 3.6, indexes 1 and 2 have useful
built-in defaults — `set -g status 3` alone gives a pane list and a session list for free.

### The powerline separator rule

The separator glyph's **`fg` is the color of the segment being left; its `bg` is the color of the
segment being entered.** Left-hand separators reverse that. Get this backwards and you get a
notch of wrong color at every joint.

```tmux
set -g status-left "\
#[fg=#1a1b26,bg=#7aa2f7,bold] #S \
#[fg=#7aa2f7,bg=#292e42,nobold]\
#[fg=#c0caf5,bg=#292e42] #{b:pane_current_path} \
#[fg=#292e42,bg=#1a1b26]"
```

Use plain Unicode separators unless a Nerd Font is confirmed present — see `primitives.md`.

## Format language

Aliases: `#S` session · `#I` window index · `#W` window name · `#P` pane index · `#F` flags ·
`#h` short host · `#D` pane id. Escapes: `##` → `#`, `#,` → `,`, `#}` → `}`.

| Modifier | Meaning |
|---|---|
| `#{?cond,yes,no}` | conditional |
| `#{==:a,b}` `#{!=:}` `#{<:}` `#{>:}` | comparison → `0`/`1` |
| `#{\|\|:a,b}` `#{&&:a,b}` `#{!:x}` | logic |
| `#{=10:x}` `#{=-10:x}` `#{=/10/…:x}` | trim right / left / with ellipsis |
| `#{p10:x}` `#{p-10:x}` | pad right / left |
| `#{n:x}` vs **`#{w:x}`** | byte length vs **display cells** |
| `#{b:path}` `#{d:path}` | basename / dirname |
| `#{s\|a\|b\|:x}` | substitute (regex + backrefs supported) |
| `#{c:red}` | color name → hex |
| `#{E:opt}` `#{T:opt}` | expand an option (T also does strftime) |
| `#{@name}` | user option — per-pane with `set -p` |

**Escaping inside conditionals is the most common syntax error.** `,` and `}` must be written
`#,` and `#}`:

```tmux
set -g pane-border-format "#{?pane_active,#[fg=black#,bg=blue],#[fg=blue#,bg=black]}#W"
```

### `#{}` vs `#()` — the difference that bites

`#()` runs a shell command, and tmux **never waits for it**. From the man page: the previous result
is used, or a placeholder if it has not run yet. Consequences:

- Always **one tick stale**, and only the **last line** of output is used.
- Refresh is bounded by `status-interval` *and* a hard 1/second floor.
- Runs under **`/bin/sh`** — no bash or zsh syntax.
- Cache anything expensive to a file and `#(cat /tmp/x)`.
- `tmux refresh-client -S` forces an immediate status repaint.
- **Runs with the server's global environment, never a session's.** Verified directly: a
  `setenv -t <session> VAR val` is visible to `show-environment -t <session>`, but a running
  `#()` job still sees whatever `show-environment -g VAR` holds — session-scoped env never reaches
  it. Only `tmux setenv -g` changes what a `#()` command sees; check with
  `tmux display-message -p '#(printenv VAR)'` rather than assuming a session-scoped export reached it.

### Debugging

```bash
tmux display-message -a                      # EVERY variable and its live value ← start here
tmux display-message -p '#{E:status-left}'   # expand one option
tmux display-message -p '#{client_termfeatures}'   # what tmux thinks the terminal can do
tmux display-message -p '#{pane_width}x#{pane_height}'
tmux show -gv status                         # ONE option's value
```

`show` takes at most one option name — `tmux show -g status-left status-right` exits 1 with
`too many arguments (need at most 1)`. Dump everything with a bare `tmux show -g`, or read a
single value with `-gv` as above.

These answer "what does this option expand to". They cannot answer "is it clipped, and does it
look right at the real client width" — for that see *Verifying rendered chrome* below.

## Window tabs

```tmux
set -g window-status-separator ""
set -g window-status-format "#[fg=#565f89,bg=#1a1b26]  #I │ #W#{?window_flags,#{window_flags}, } "
set -g window-status-current-format "\
#[fg=#1a1b26,bg=#9ece6a,bold] #I │ #W#{?window_zoomed_flag, [Z],} \
#[fg=#9ece6a,bg=#1a1b26,nobold]"
```

## Pane borders

```tmux
set -g pane-border-status top          # off | top | bottom  — costs one row per pane
set -g pane-border-lines  single       # single | double | heavy | simple | number | spaces (3.6+)
set -g pane-border-indicators both     # off | colour | arrows | both
set -g pane-border-style        "fg=#3b4261"
set -g pane-active-border-style "#{?pane_in_mode,fg=#e0af68,#{?pane_synchronized,fg=#f7768e,fg=#7aa2f7}}"
```

**tmux ignores attributes in border styles — only `fg`/`bg` apply.** Bold or italics on a border
silently does nothing, which looks like a broken config when it is actually working as documented.

Per-pane labels are the useful trick: set a user option and read it in the format, falling back to
the running command.

```bash
tmux set -p -t %3 @label "api logs"
```
```tmux
set -g pane-border-format " #{pane_index} #{?#{@label},#{@label},#{pane_current_command}} "
```

`@label` is set out-of-band, so it does not survive a fresh `tmuxp load` into new panes. When each
pane already has a `scripts/watch-<name>` wrapper (console's setup shape), have the wrapper label
itself instead — it then re-labels on every launch *and* every respawn, for free, and the label
lives next to the thing it names:

```zsh
[ -n "$TMUX_PANE" ] && tmux select-pane -t "$TMUX_PANE" -T "fires · 2m"
```
```tmux
set -g pane-border-format " #{pane_index} #{?#{pane_title},#{pane_title},#{pane_current_command}} "
```

3.6+ also offers `pane-scrollbars [off|modal|on]` with `pane-scrollbars-position` and
`pane-scrollbars-style`.

## Popups and menus

```
display-popup [-BCEkN] [-b lines] [-d dir] [-e VAR=val] [-h height] [-s style]
              [-S border-style] [-T title] [-w width] [-x pos] [-y pos] [command]
```

- **`-E` closes when the command exits; `-EE` closes only on success** — the second keeps a failure
  on screen long enough to read, which is almost always what you want for a build or test popup.
- `-b single|rounded|double|heavy|simple|padded|none`, `-S` border style, `-s` body style.
- `-x`/`-y` accept `C`entre, `R`ight, `P`ane, `M`ouse, `W`indow, `S`tatus, or a format using
  `#{popup_centre_x}` / `#{popup_height}` / …
- Default size is half the terminal. `-k` (3.6+) dismisses on any key.

```tmux
bind g display-popup -E -w 90% -h 90% -b rounded \
  -S "fg=#7aa2f7" -s "bg=#16161e" \
  -T "#[fg=#7aa2f7,bold] lazygit · #{b:pane_current_path} " \
  -d "#{pane_current_path}" "lazygit"

bind T display-popup -EE -w 60% -h 40% -x P -y P -T " tests " -d "#{pane_current_path}" "npm test"
```

Session-wide defaults: `popup-style`, `popup-border-style`, `popup-border-lines`.

`display-menu` takes `name key command` triples; a name starting with `-` is disabled, an empty
name is a separator.

## Applying a theme safely

**Never rewrite `~/.tmux.conf` in place.** A theme the user cannot undo is worse than no theme.
Generate a separate file and let them own the one-line include:

```bash
mkdir -p ~/.config/tmux
"${CLAUDE_PLUGIN_ROOT}/scripts/tmux_theme.sh" tokyo-night > ~/.config/tmux/theme.tmux
tmux source-file ~/.config/tmux/theme.tmux && tmux refresh-client -S
```

To persist, they add `source-file ~/.config/tmux/theme.tmux` to their own config.

### Verify on a throwaway server, not a `TMUX_TMPDIR` sandbox

**A `TMUX_TMPDIR`-based "sandbox" does not isolate anything when run from inside a pane.** The
agent is normally inside a pane (`$TMUX` already set), and tmux resolves the socket from `$TMUX`
whenever it is set — `TMUX_TMPDIR` is ignored. A `new-session` "sandbox" under that env var lands
on the **live** server, `source-file` applies `set -g` chrome straight to the user's real session,
and the teardown `tmux kill-server` then **kills the entire live server** — every session, every
pane. Isolate by explicit socket instead, and confirm the isolation before anything destructive:

```bash
tmux -L _tmuxdesign_sbx -f /dev/null new-session -d -s _sbx -x 120 -y 30
tmux -L _tmuxdesign_sbx source-file ~/.config/tmux/theme.tmux && echo loaded
tmux -L _tmuxdesign_sbx display-message -p '#{socket_path}'   # ← confirm this is the sandbox
                                                                 #   socket before the next line
tmux -L _tmuxdesign_sbx kill-server
```

This proves the snippet **loads and expands** without risking the live server. It still does not
show what a client actually *draws* — `capture-pane` never returns the status bar or pane borders,
because a client draws them and they are not stored in any pane. For that, see *Verifying rendered
chrome* below, which probes the real session at the real client width (the width is the point:
clipping is a function of it).

`console`'s own sandbox-render step uses the same `-L` isolation for the same reason — see
"The verify loop" in `skills/console/SKILL.md`.

### Scoping chrome to one session

tmux options split across three scopes, and picking the wrong one is what causes a leak:

| Scope | Examples this generator emits | Scoped to one session? |
|---|---|---|
| **server** | `default-terminal`, `terminal-features` | No — always affects every session on the server |
| **session** | `status-*`, `message-*`, `popup-*` | Yes — `set -t "=<session>"` (exact match; a bare `-t <name>` prefix-matches, so `-t infra` also hits `infrastructure`) |
| **window** | `window-status-*`, `pane-border-*`, `mode-style` | Only per-window — `set -t "<session>:"` reaches just that session's *current* window; covering every window needs a `list-windows` loop, and a **new** window still inherits the global default unless re-applied |

**Prefer these two mechanisms over a hand-rolled scoping flag** — a flag degrades the moment a new
window is created, because window options can't be scoped for windows that don't exist yet:

1. **One tmux server per workspace** (`tmux -L <workspace> …`, or `tmuxp load -L <name>`) — `set -g`
   then never crosses a boundary, since there is no shared server to leak across.
2. **tmuxp's own declarative `options:` keys.** A per-session or per-window `options:` block in
   `.tmuxp.yaml` is scoped by tmuxp itself; only `global_options:` maps to `set -g`. A leak across
   sibling sessions is usually `global_options:` reached for where a plain `options:` key already
   existed.

This generator stays a `set -g`-only, one-theme, source-and-forget snippet by design (see the
header comment in `scripts/tmux_theme.sh`) — session-scoped chrome is a workspace-composition
decision for `.tmuxp.yaml`, not something this script should attempt.

**Un-leaking a live server.** Removing a `global_options:` line from `.tmuxp.yaml` does not
retroactively fix values already live on a running server — they persist until the server
restarts. Clear them explicitly before re-applying a corrected theme, or the stale global will
mask whether the fix actually worked: `tmux set -gwu <window-option>` / `tmux set -gu <option>`.

The generator also runs `setenv -g TMUX_DESIGN_THEME <name>` — global, not session-scoped; the
`#()` env-scope rule above applies to it too. Renderers built on `renderer_template.py` read it
from their own process environment at **start**, so a pane process already running when the theme
changes will not pick up the new value until it is respawned (`console`'s verify loop) — only a
newly created pane sees it immediately.

## Verifying rendered chrome

The sandbox above proves the snippet *loads and expands*. It does not show what a client actually
draws, so it cannot catch the most common chrome failure: a `status-left`/`status-right` that is
correct but clipped, because `status-left-length` defaults to 10 and `status-right-length` to 40.
`console`'s verify loop can't answer this either — it is pane-scoped, and the status bar is not in
any pane.

Work cheapest-first. `tmux display-message -p '#{E:status-right}'` (above) is free and
side-effect-free, and settles "did `#()` run" and "did it expand to the right text". Only the last
question — is it clipped at the real client width — needs a rendered capture:

```bash
sess=invest
sz=$(tmux list-clients -t "$sess" -F '#{client_width}x#{client_height}' | head -1)
if [ -n "$sz" ]; then                       # attached → match the real client exactly
  w=${sz%x*}; h=${sz#*x}
else                                        # detached → window size + however many status rows
  w=$(tmux display -p -t "$sess" '#{window_width}')
  h=$(tmux display -p -t "$sess" '#{window_height}')
  case "$(tmux show -gv status)" in off) r=0;; on) r=1;; *) r=$(tmux show -gv status);; esac
  h=$((h + r))
fi
tmux new-session -d -s _sbx_probe -x "$w" -y "$h" "TMUX= tmux attach -t $sess -r"
sleep 1; tmux capture-pane -e -p -t _sbx_probe | tail -3; tmux kill-session -t _sbx_probe
```

Three details keep this from being destructive, and each is easy to get wrong:

- **`-r` is load-bearing, not politeness.** `window-size` defaults to `latest`, so a client
  attaching makes the session follow *it*. On tmux 3.7b a read-only client is exempt from that —
  verified: an 80x24 probe attached with `-r` left a 120x30 session untouched, while the same
  attach *without* `-r` reflowed it to 80x23 and left it that way after the probe was killed. Drop
  the `-r` and you resize someone's live dashboard as a side effect of looking at it.
- **Get the size from `list-clients`, not `display -p`.** `tmux display -p -t <session>
  '#{client_width}'` reports the size of the client *you* are calling from, not the target's — it
  will happily hand back your own 239x63 for a 120x30 session. Matching the real width is the
  point rather than a precaution: clipping is a function of width, so a probe at the wrong width
  answers a question nobody asked.
- **Derive the status rows; don't just add 1.** `status` may be `off` (+0), `on` (+1), or `2`–`5`
  for a multi-row block, and `status-position top` puts the bar first — read the leading rows
  rather than the trailing ones when it does.

Capture with `-e` so the SGR sequences survive; without it you can check the layout but not whether
a single color landed, which is usually the reason you are looking.

## Theme frameworks (optional, not a dependency)

`catppuccin/tmux` v2.x, `dracula/tmux`, `rose-pine/tmux`, `erikw/tmux-powerline` and `gitmux` all
exist and are maintained, but they require tpm and bring their own option vocabulary. Catppuccin v2
in particular renamed nearly every v1 option and no longer builds the status line for you — you
compose it from modules. `tmux_theme.sh` exists so this plugin does not take that dependency; reach
for a framework only if the user already uses tpm.

If you do load `erikw/tmux-powerline`, it must sit near the **bottom** of the config — it
overwrites `status-left`/`status-right` — and `run '~/.tmux/plugins/tpm/tpm'` must be last.
