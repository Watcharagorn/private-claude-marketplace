---
name: console
description: >-
  Set up, redesign, and audit tmux windows/panes so every console surface shows formatted,
  live-refreshing content (tables, gauges, TUIs) — never raw text. Owns pane WIRING and
  verification: tmuxp layouts, viddy/watch refresh, renderer wrappers, lnav log formats, and the
  sandbox → respawn-pane → capture-pane loop that makes pane edits actually appear. Use whenever
  the task touches tmux or tmuxp — adding or changing a window, pane, or layout; redesigning what
  a pane displays; making terminal output "a table"; fixing a flickering, raw, stale, or
  monochrome pane; building an lnav log format; or when an edited pane script "isn't showing
  changes". Reach for it even when the user never says "tmux" — "why is my watch pane stale"
  counts. Trigger phrases — "audit my tmux panes", /tmux-design:console
  [setup|redesign|audit]. For how a surface should LOOK — themes, boxes, bars, sparklines,
  badges, status-bar and border styling — use tmux-design:decorate; a whole-workspace polish
  runs both.
---

# Console design for tmux panes

Set up, modify, and enforce a design standard for tmux windows and the content rendered inside
their panes. The goal of every action: **no pane ever shows raw, monochrome, flickering text** —
everything renders through a formatter (a table renderer, gum, lnav, viddy) with color, alignment,
and in-place refresh. A pane is glanced at hundreds of times a day; every formatting decision
below exists to make that glance faster.

## When NOT to use

- Styling *decisions* — themes, palettes, boxes, charts, status-bar or pane-border appearance,
  popups (use `tmux-design:decorate`; this skill wires panes up, that one decides how they look).
  A whole-workspace request — "make my panes nicer", "maximize the UX of this session" — is
  normally **both** skills in sequence rather than a reason to stop here: wire and verify in this
  skill, and load `decorate` for the look instead of inventing one inline
- Web/GUI frontend work (use frontend-design)
- One-shot script output that never lives in a persistent pane

## The design standard

Enforce these in every pane you create or touch:

1. **No raw text.** Every pane renders via a formatter: an ANSI table renderer script, a gum TUI,
   lnav with a proper format, or viddy wrapping a one-shot renderer.
2. **No `clear`-loop refreshers** (`while :; do clear; …; sleep N; done`) — they flicker, hide
   staleness, and swallow Ctrl-C mid-child-call. Wrap a one-shot renderer with
   `viddy -p --unfold -n <secs> -- <cmd>` instead: in-place redraw, diff-highlight (`-d`) that
   "pulses" changed cells, and scrollable snapshot history for free — its scroll keys are in
   "Motion, repaint, and the wrapper's cut" in `decorate/references/primitives.md`, because
   `viddy --help` documents none of them. `--unfold` (`-w`) is not
   optional: without it, a live pane resize makes viddy WRAP its last (stale-width) frame instead
   of cropping it, visibly garbling a 3-row header into 5 for up to a full refresh cycle —
   confirmed by shrinking a sandbox pane mid-render. Add `--no-title` (`-t`) only when the
   renderer draws its own liveness signal (`freshness()` or a pane title): viddy's own header does
   not actually count down (two captures 6s apart come back byte-identical), so don't keep it "for
   the countdown" — keep it only when nothing else marks the pane alive.
   A renderer may own the redraw itself rather than being wrapped — but only when motion **encodes
   data** *and* the paint cadence must exceed the data cadence. Anything short of both: use viddy.
   See "Status-driven animated glyphs" in `decorate/references/primitives.md` for what that owes
   you, and "Verifying an own-loop pane" below for how to check it.

   A pane the user **types into** — gum prompts, a menu loop — is a third shape, and neither the
   wrapper nor the own-loop carve-out covers it: it repaints on input, not on a clock, so there is no
   interval to get right and nothing for viddy to wrap. It is still bound by rules 1, 3, 4 and 5; a
   prompt-driven TUI shows raw monochrome text as easily as a `cat` pane does. Two things follow from
   its having no wrapper. The tmuxp entry launches the TUI directly, so the force-color and theme
   environment a `watch-*` wrapper would have carried (`CLICOLOR_FORCE=1` for gum,
   `TMUX_DESIGN_THEME`) has to be set on that entry or inside the TUI script — otherwise rule 3 fails
   the moment the pane isn't a TTY, with nowhere left to fix it. And it can't be verified by capturing
   a settled frame, because the frame is a function of what has been typed: see "Verifying a
   keystroke-driven pane" below.
3. **Always emit color.** Panes aren't TTYs — never rely on a library's auto-detection, it will
   silently strip everything. `NO_COLOR` (non-empty) is the opt-out, and `FORCE_COLOR=0` or an empty/`dumb` `TERM` also
   disable it. *Which* colors is
   `tmux-design:decorate`'s call: it owns the semantic roles, the named themes, and the
   truecolor→256→16 degradation. A pane that emits raw color codes instead of naming a role
   can't be re-themed, so route palette questions there rather than hardcoding here.

   That routing is easy to skip once you are already deep in a console task and chrome is the last
   thing left, so treat these three as the moment to load `tmux-design:decorate` *before* typing the
   next command: you are about to set `status-*`, `window-status-*`, or `pane-border-*`; you are
   about to write a literal `colour###` or `#rrggbb` anywhere; or you are writing a `#()` helper
   whose stdout lands in the status line. That last one hides the most — a `scripts/status-<name>`
   sets no tmux option and lives in no config, so it looks like plain scripting right up until it
   is the one thing a theme swap cannot reach. Have it emit plain text and let the format color it,
   or use `#[fg=…]` resolved from the loaded theme. Two answers from `decorate` are cheap now and
   expensive to retrofit: which theme (it asks whether the terminal is light or dark, because that
   genuinely cannot be detected) and `tmux setenv -g TMUX_DESIGN_THEME <name>`, which is what makes
   the panes and the chrome agree instead of drifting apart.
4. **Tables**: bold header row, thin rule under it, two-space column gaps, right-aligned
   numerics. Pad with **display-column** width math, not `len()` — `⛔ blocked` is 9 characters
   and 10 columns, and colored or hyperlinked cells are mostly invisible bytes. Use the kit's
   `vlen()`/`pad()`; see `${CLAUDE_PLUGIN_ROOT}/skills/decorate/references/primitives.md`. Strip trailing zeros from exchange
   decimals (`60800.00000000` → `60800`). Negative money as `-$150.78`, never `$-150.78`.
5. **Semantic marks**: a mark is read faster than a word — `▰▱` proximity gauges, category dots,
   `∅ none` (dim) for empty sections. Prefer marks that are one column wide in every locale;
   `${CLAUDE_PLUGIN_ROOT}/skills/decorate/references/primitives.md`
   has the safe set and the emoji-width trap.
6. **Timestamps in the reader's local timezone**, short form `12 Jul 19:55` — a pane is glanced
   at, and mentally converting UTC costs more than the timestamp saves. Color heartbeats by
   freshness with `(Xm ago)` — name the `ok`/`warn`/`err` roles, as `freshness()` does, rather
   than the hues, so a theme swap still reads correctly. Pin a fixed zone only when
   the pane tracks one market's clock, and label it when you do.
7. **Renderer scripts stay dependency-free** (Python stdlib ANSI). Before writing one, look for a
   renderer the project — or the sibling workspace you were asked to copy a pane from — already has:
   `ls scripts/` for a `*view*.py` / `*pane*.py`, `scripts/watch-*`
   wrappers, or read what the tmux/tmuxp config already launches. Extend that instead of
   duplicating its data-loading logic; keep its default output unchanged and add a flag or
   subcommand for the new view so other consumers don't break. What you inherit is the *loader*,
   not the invocation: a `scripts/watch-*` written before this standard is no evidence its flags
   are right, and copying a sibling's command line is how rule 2's mandatory `-w` goes missing
   from a brand-new pane while every visible sign says you matched the house style. Re-check the
   flags against rule 2 after mirroring the shape. If there is none, copy the bundled
   starter into the project's `scripts/` and adapt it:
   ```bash
   cp "${CLAUDE_PLUGIN_ROOT}/scripts/renderer_template.py" scripts/<name>_view.py
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/renderer_template.py" demo   # see the standard rendered
   ```
   It ships `c() vlen() pad() trunc() sanitize() table() panel() divider() spread() bar() sparkline() badge() kv()
   gauge() freshness()` plus theme resolution and local-timezone handling, so the fiddly parts
   (display-column padding, palette, degradation) are already right. Richer tools only if already
   installed — `command -v gum viddy lnav jq bat glow`; `${CLAUDE_PLUGIN_ROOT}/skills/decorate/references/tooling.md` has the
   invocations and the force-color rules that make them work in a pane.

   Adapting the starter means importing or copying its helpers, **not re-deriving them** — and
   re-deriving looks exactly like diligence while you do it. A fresh renderer grows its own
   `vlen(s) = len(ANSI_RE.sub("", s))`, which counts *characters* after stripping SGR: `⛔ blocked`
   measures 9 instead of 10, and an OSC-8 linked cell measures its whole URL. Every column padded
   with it is crooked in the exact way rule 4 exists to prevent, and it stays invisible for as long
   as the data is ASCII — which is why the verify loop's width check can't stand in for this one.
   Step 2 proves the file fits *today's* rows; it says nothing about the row that arrives next month
   carrying an emoji or a CJK product name. So check the file you just made from the starter:
   ```bash
   r=scripts/<name>_view.py                    # the copy you just created, not a renderer you extended
   [ -f "$r" ] || echo "MISSING: $r"           # a typo'd path must not read as a clean run
   grep -q 'def cluster_width' "$r" \
     || grep -nE '^ *def (vlen|pad|trunc)\b' "$r" | sed 's/^/re-derived width math /'
   grep -nE '^[A-Z][A-Z0-9_]* *= *"[0-9]+(;[0-9]+)+"' "$r" | sed 's/^/raw SGR palette /'
   ```
   The `cluster_width` guard is what keeps this quiet on a renderer that copied the kit wholesale —
   that file defines `vlen` legitimately, and a check that flags correct files is one you learn to
   ignore. It also fixes the scope: run this on the copy, not on a pre-existing project renderer you
   extended, whose own `pad()` is built on its own width model. The `;` in the palette pattern earns
   its place the same way — `PORT = "8080"` is not a color, and flagging it would spend the check's
   credibility on a constant. A hit on either line means you re-derived: take the width helpers from
   the kit, and the color literal to `tmux-design:decorate` as a named role. A silent run still owes
   you one look at the padding path, because no name-based grep can see a file that defines *two*
   width functions and pads with the ASCII-only one while a correct one sits unused beside it.
8. **Refresh cadence matches data cadence** — 90s for fast-moving state, 120s+ for slow. Render
   only the data the pane needs: never run a full fetch to display one section (the pane refreshes
   forever; wasted calls compound).

A finished workspace has three moving parts: a declarative `.tmuxp.yaml` (or tmux config), one
small `scripts/watch-<name>` wrapper per non-interactive pane, and one renderer that each wrapper
invokes with a different mode argument.

## If viddy isn't installed

`viddy` is the one real dependency of rule 2, so check `command -v viddy` before promising a
refresh loop. If it's missing, offer to install it (`brew install viddy`, or
`go install github.com/sachaos/viddy@latest`) — it's worth the install. Until then fall back in
this order, both of which redraw in place rather than blanking the screen:

1. `watch -c -n <secs> <cmd>` — `-c` is what keeps the ANSI codes; without it the pane goes
   monochrome and you've violated rule 3 while thinking you fixed rule 2.
2. `while :; do tput cup 0 0; <cmd>; tput ed; sleep <secs>; done` — homes the cursor and erases
   from there down, so the screen is overwritten rather than emptied and refilled. Never `clear`;
   that blank frame between redraws *is* the flicker.

If a redraw still tears — half the old frame visible under half the new one — wrap it in
synchronized output: `printf '\033[?2026h'` before, `printf '\033[?2026l'` after. tmux passes
this through from 3.7 onward and ignores it harmlessly before that.

## Actions

### setup — add a window or pane

1. Read the workspace's `.tmuxp.yaml` (or create one; session launched via a `tmuxp load`
   launcher script).
2. Choose layout: `main-vertical` + `main-pane-width` for an interactive-focus window;
   `main-horizontal` + `main-pane-height` for a log-dominant window.
3. Give each non-interactive pane a small `scripts/watch-<name>` wrapper — the yaml stays
   declarative and the command is testable outside tmux:
   ```zsh
   #!/bin/zsh
   # <what this pane shows>, refreshed in place by viddy every <N>s.
   cd "$(dirname "$0")/.." || exit 1
   exec viddy -p --unfold -n <N> -- <one-shot renderer command>
   ```
4. Build the renderer per the standard above, then run the **verify loop** (below).

**Splitting a pane into an already-running window** is the same job with a sibling to pay for.
`tmux split-window` takes the new pane's rows entirely from the pane it split, and tmux rebalances
nothing afterwards — a 32-row pane becomes a 16 and a 15, and the one you weren't looking at is now
half the height its renderer was sized for. So resize the column explicitly rather than leaving the
accidental ratio (`tmux resize-pane -t <pane> -y <rows>`, or `select-layout` for an even column),
then persist it, or the next `tmuxp load` hands the ratio back to chance: tmuxp splits panes with no
size argument of its own (1.74.0, `workspace/builder/classic.py`), so the number lives in the
**window's** `options:` — `main-pane-height` for a horizontal main, `main-pane-width` for a vertical
one — and not on the pane entry. Finish with the sibling check in the verify loop, since the pane
that shrank is the one nobody captures.

### redesign — reformat an existing pane

1. Locate the pane: `tmux list-panes -s -t <session> -F "#{window_name} #{pane_id} #{pane_current_command}"`.
2. Read its current wrapper/command and identify the data source; measure the real estate with
   `tmux display -p -t <pane> "#{pane_width}x#{pane_height}"` and size tables/truncation to fit —
   a table that wraps is worse than the raw text it replaced. That figure is the **pane**, not what
   your renderer gets to draw in: the refresher wrapping it keeps some for itself (under viddy, 4
   rows always, plus the right-hand column once your content fills the pane), and
   `pane-border-status top` costs another row per pane. Subtract the wrapper's cut before sizing
   anything, and measure *after* loading chrome rather than before — see "Motion, repaint, and the
   wrapper's cut" in `${CLAUDE_PLUGIN_ROOT}/skills/decorate/references/primitives.md`.
3. Write or update the one-shot renderer (import/reuse the project's existing loader functions —
   don't duplicate parsing logic).
4. Rewire the wrapper to `exec viddy … -- <renderer>` and run the **verify loop**.

### audit — enforce the standard across a session

1. `tmux list-panes -s -t <session> -F "#{window_name} #{pane_id} #{pane_current_command}"`.
2. `tmux capture-pane -e -p -t <pane>` for each; flag violations: no ANSI colors in output,
   `clear`-loop wrappers, wall-of-text (no table/section structure), raw `tail`/`cat` panes,
   non-local timestamps, flicker-prone full-redraw loops, hand-rolled width math in a renderer script
   (rule 7's reuse check finds it), and `viddy` invoked without `-w`/`--unfold`
   — which the wrappers answer faster than the panes do:
   ```bash
   for f in scripts/watch-*; do
     line=$(grep -m1 'viddy' "$f") || continue          # non-viddy wrappers aren't rule 2 violations
     printf '%s\n' "${line%% -- *}" \
       | grep -qE -- '--unfold|(^|[[:space:]])-[a-z]*w([[:space:]]|$)' || echo "$f"
   done
   ```
   Three details carry this, and dropping any one makes the sweep lie. Match **both** spellings and
   allow the clustered short form (`-pw`), or it reports wrappers that are already correct and you
   learn to ignore it. Skip files that never invoke viddy, or the skill's own sanctioned `watch`
   fallback gets flagged as a violation. And cut the line at ` -- ` before matching, because
   everything after it is the renderer's own argv: `viddy -p -n 90 -- wc -w file` has no `--unfold`
   anywhere, yet a whole-line match sees the payload's `-w` and reports it compliant — a false pass
   in the check meant to find false passes. This violation is worth sweeping for even when every
   pane looks fine: it renders correctly right up until the pane is resized, and wrappers copied
   from one another share the omission, so one pass clears the whole set.
3. Report a per-pane verdict table (rendered to the standard, naturally), then fix via
   **redesign** on request.

## The verify loop (critical — do not skip)

Editing a script **never** changes a running pane; tmux panes keep executing the process they
were launched with, which is why "I edited it but nothing changed" happens. After any change:

1. **Sandbox first, on an isolated server** — render in a disposable session sized like the
   target, confirm colors render as real SGR output (not literal `[38;5;…m` garbage), then kill
   it. Use an explicit `-L` socket, not the ambient server — a bare `tmux new-session`/
   `kill-session` here creates and destroys `_sbx` on the user's **live** server, the same class
   of leak as the theming sandbox documented in `decorate/references/tmux-chrome.md`:
   ```bash
   tmux -L _tmuxdesign_sbx -f /dev/null new-session -d -s _sbx -x <w> -y <h> \
     "<renderer command> | cat; sleep 60" \
     && sleep 5 && tmux -L _tmuxdesign_sbx capture-pane -e -p -t _sbx | head -30
   tmux -L _tmuxdesign_sbx kill-server
   ```
   The `| cat; sleep 60` is doing real work, not padding. Renderers here are one-shot by rule 7, so
   the command exits the instant it has printed, tmux tears the session down with it, and the
   capture fails with `can't find pane: _sbx` — the sleep just holds the session open long enough
   to look at. The `| cat` matters as much: it puts stdout behind a pipe, which is the condition
   the renderer actually runs under inside viddy, so the sandbox exercises the same color-detection
   path as production instead of a friendlier one that hides rule 3 bugs.

   `capture-pane` only ever shows pane *content* — never the status bar or pane borders (a client
   draws those). For chrome verification, use the read-only-attach probe in
   `decorate/references/tmux-chrome.md`'s "Verifying rendered chrome" section instead.
2. **Check width and resize behavior**, same isolated server. A single-size render misses two
   real classes of bug: overflow at other pane widths, and viddy re-wrapping a stale frame on a
   live resize (rule 2) — both are cheap to catch here rather than after they ship.

   Improvising the assertion is where this step quietly fails: `awk`'s `length()` counts bytes and
   Python's `len()` counts code points, so a 96-column `─` divider measures 288 or 96 and a
   byte-counting check reports "no line exceeds 106" about rows that visibly wrap. That is rule 4's
   `vlen()` problem reappearing inside the harness meant to catch it — and a hand-rolled fix
   reappears one layer down, because "strip the color codes and count characters" is wrong too:
   an SGR-only strip leaves an OSC-8 hyperlink's URL in the count, measuring a 10-column linked
   cell at 43 and failing a row that fits. So don't measure by hand. `check_cols.py` measures with
   the kit's own `vlen()` — the same function the renderers pad and truncate with — and budgets
   against the pane **minus the wrapper's cut** rather than the pane:
   ```bash
   check="${CLAUDE_PLUGIN_ROOT:?unset — the plugin loader sets it}/scripts/check_cols.py"
   for w in 60 100 160; do
     TMUX_PANE_WIDTH=$w <renderer command> | python3 "$check" "$w" --reserve 1   # 1: viddy's scrollbar
   done
   # Resize half. Step 1 killed the server, so start a fresh one — and run the REAL wrapper here,
   # not the bare renderer: tmux reflows already-printed static text identically with and without
   # --unfold, so a sandbox running the one-shot renderer cannot catch the rule 2 bug this checks.
   tmux -L _tmuxdesign_sbx -f /dev/null new-session -d -s _sbx -x 100 -y 30 \
     "viddy -p --unfold -n 2 -- <renderer command>" && sleep 3 \
     && tmux -L _tmuxdesign_sbx capture-pane -e -p -t _sbx | head -5   # header rows before
   tmux -L _tmuxdesign_sbx resize-window -t _sbx -x 60 && sleep 3 \
     && tmux -L _tmuxdesign_sbx capture-pane -e -p -t _sbx | head -5   # header row count unchanged?
   tmux -L _tmuxdesign_sbx kill-server
   ```
   Silence **and a zero exit** is the pass — `check_cols.py` exits non-zero when any line is over,
   so the check is assertable rather than eyeballed. A check that prints its own "looks clean"
   banner will print it underneath the offending lines too, and that reads as a pass at a glance.

   Two things a silent run does **not** prove. It doesn't prove the columns line up: an
   over-measured cell makes a row too *short*, which fits the budget and still looks crooked. And
   it only means anything on the renderer's **stdout** — piping a `capture-pane` capture into it
   always passes, because without `-J` a capture returns the pane's screen grid already hard-wrapped
   at pane width, so no line can exceed it.
3. **Respawn the live pane** — `tmux respawn-pane -k -t <pane_id> "<command with absolute path>"`.
   Don't Ctrl-C + retype via send-keys: if the old process is mid-child-call the interrupt is
   swallowed and the typed command lands as inert text. Respawn is deterministic. Caveat: a
   respawned pane runs the command directly (no shell under it), so quitting it shows
   "Pane is dead" until the next full workspace launch.
4. **Verify live** — `sleep 5 && tmux capture-pane -e -p -t <pane_id>`; confirm the new render
   and that `#{pane_current_command}` is the expected process (e.g. `viddy`). Iterate on failure.
5. **If the change split a pane, verify the siblings too** — the loop above only ever looks at the
   pane you touched, and a split is the one edit that changes a pane you didn't. Diff the
   `list-panes` geometry against what it was before the split and `capture-pane -e -p` every pane
   whose size moved. No respawn is needed: a renderer that reads `$TMUX_PANE` picks the new size up
   on its next refresh. The capture is still worth its five seconds, because a content-fit renderer
   *truncates* rather than scrolls — a halved sibling paints a clean, plausible, well-aligned frame
   with its last rows simply absent, which passes every glance until someone asks why a row they
   expect isn't there.

### Verifying an own-loop pane

A pane whose renderer owns its own paint loop (rule 2) never settles, so three things above change:

- **Step 1 has nothing stable to sample.** Capturing after a sleep returns whichever animation
  frame happened to be on screen — a different one each run, so there is nothing to diff. Such a
  renderer must ship a **one-shot frame mode** (`<renderer> --frame <name>`, or an equivalent env
  flag: one synchronous fetch, one paint, exit); that is the artifact to sandbox. Because it exits
  by itself, the `| cat; sleep 60` + `sleep 5` scaffolding collapses to `| cat` and an immediate
  capture — keep the `| cat`, for the same reason as above.
- **The one-shot must bypass the inactive-window paint skip.** A sandbox session is detached, so a
  loop that declines to paint an inactive window paints *nothing* here and the capture comes back
  empty — a pass-shaped failure in the one step meant to catch it. Gate that skip on "not
  one-shot".
- **Step 4's process assertion changes.** `#{pane_current_command}` is the loop's own process, never
  `viddy` — assert that instead, and assert the frame *differs* between two captures a second
  apart, which is the only direct evidence the loop is still running rather than stopped on a
  plausible-looking frame.

If Ctrl-C is wired to force an immediate refresh instead of exiting — reasonable for a monitoring
pane — then `respawn-pane`/`kill-pane` is the only way to stop it, and step 3's "Pane is dead"
caveat applies with nothing to work around it.

### Verifying a keystroke-driven pane

Rule 2's third shape can't be verified by capturing a settled frame — what it shows depends on what
has been typed, so you have to drive it. `send-keys` is the only way in: the widgets these panes are
built from read their keys from the terminal rather than stdin, so nothing can be piped at them (the
"TTY safety" table in `decorate/references/tooling.md` has which gum commands this hits). That does
not undo step 3's prohibition — driving a program that is already reading is fine; using `send-keys`
to *restart* one is what gets swallowed mid-child-call and lands as inert text.

Drive it on step 1's isolated server, and point it at a **scratch copy of the datastore**. This is
the only step in the whole loop that writes, so aiming it at the real file means the verification
mutates the thing it was verifying.

```bash
scratch="$(mktemp)"; cp <the real datastore> "$scratch"   # verification writes — never to the original
sbx() { tmux -L _tmuxdesign_sbx "$@"; }
await() {   # await <marker> — no -e here: SGR bytes can split a marker mid-word
  for _ in $(seq 40); do
    sbx capture-pane -p -t _sbx | grep -qF "$1" && return 0
    sleep 0.25
  done
  echo "timeout waiting for: $1" >&2; sbx capture-pane -e -p -t _sbx >&2; return 1
}
sbx -f /dev/null new-session -d -s _sbx -x 100 -y 30 \
  "<tui command, its datastore pointed at $scratch>; echo __DONE__; sleep 60"
await 'Title:' && sbx send-keys -t _sbx -l 'buy milk' && sbx send-keys -t _sbx Enter
await __DONE__ && grep -q 'buy milk' "$scratch"      # the write, not the frame
sbx kill-server
```

**Poll, don't sleep.** A hand-picked `sleep` is guesswork that passes on a fast machine and lands the
next keystroke in the wrong prompt on a slow one, and the run still reports a pass — so `await` has
to *fail* at its timeout rather than fall through. `grep -qF`, not `grep -q`, because prompts
routinely contain `?`, `[` and `(`. And `; echo __DONE__; sleep 60` is there for step 1's reason: the
TUI exits, tmux tears the session down with it, and the final assertion races a pane that no longer
exists — the marker gives you something to wait for and the sleep holds the session open to read it.

Assert the **side effect**, not the frame: a TUI paints a plausible "saved" frame whether or not the
write landed, and the datastore row is the only evidence that it did.

## Log-viewer panes (lnav)

Raw log lines in an lnav pane still violate the standard — the fix is a format file, so fields
parse, identifiers get identity colors, and warn/error levels colorize. Read
`references/lnav-formats.md` when a pane tails a log; it covers the schema, the
mutually-exclusive-regex trap that silently NULLs your captures, and the headless install +
SQL validation loop.

## Done when

- Every touched pane shows colored, structured content live in the real session (verified by
  `capture-pane -e`, not assumed from a successful file edit).
- `.tmuxp.yaml` + wrapper scripts reproduce the design on the next `tmuxp load`.
- No `clear`-loops, no raw-text panes, timestamps localized, palette consistent.
