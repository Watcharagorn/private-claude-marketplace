#!/usr/bin/env bash
# PostToolUse:Write|Edit
#
# Opens the mentor plan document (the Markdown plan, or an opt-in HTML zoom
# artifact) for review ONCE, the first time it is created;
# later Write/Edits refresh it in place (the document self-refreshes on return to the tab,
# and Live Preview / the browser reloads when the file changes on disk).
#
# Opener precedence — set MENTOR_PLAN_OPENER in ~/.claude/settings.json env (default "auto"):
#   auto   - if running INSIDE VSCode (integrated terminal), open the plan as a focused
#            editor tab via the VSCode CLI (`code -r`), so you can render it in the integrated
#            browser with one keystroke (install Microsoft's "Live Preview" extension, then
#            Show Preview / ⇧⌘P → "Live Preview: Show Preview"). If not in VSCode (or no VSCode
#            CLI), open in Google Chrome, then the OS default browser.
#   vscode - force the VSCode editor-tab path (falls back to Chrome → system if no VSCode CLI).
#   chrome - force Google Chrome (falls back to the OS default browser).
#   system - legacy: OS default opener (open / xdg-open / wslview).
#
# VSCode CLI is auto-detected (code, code-insiders, cursor, windsurf, codium); override with
# MENTOR_PLAN_VSCODE_BIN. Set MENTOR_PLAN_OPEN=off to disable opening entirely.
# MENTOR_PLAN_OPEN_DRYRUN=1 makes each opener print its name instead of launching (for tests).
#
# Scoped strictly to the plugin's own plan files — any other Write/Edit is ignored.
# Non-blocking: always exit 0.

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)

# Off-switch: set MENTOR_PLAN_OPEN=off in ~/.claude/settings.json env to disable auto-open.
case "${MENTOR_PLAN_OPEN:-}" in off|0|false|no) exit 0 ;; esac

# Only act on the plugin's own plan files: the canonical Markdown plan, or an
# opt-in HTML zoom artifact written beside it.
case "$file" in
  */.mentor/plans/*.html) ;;
  */.mentor/plans/*.md) ;;
  *) exit 0 ;;
esac

[ -f "$file" ] || exit 0

# Open-once: don't re-open the same plan on every later Write/Edit (sidecar marker lives beside
# the plan file under <repo>/.mentor/plans/, gitignored). The open tab/preview self-refreshes.
marker="${file}.opened"
[ -e "$marker" ] && exit 0

# --- openers ---------------------------------------------------------------
# Each prints its name and returns 0 under MENTOR_PLAN_OPEN_DRYRUN (so the fallback chain stops
# at the first), otherwise launches the target and returns its success/failure for fallthrough.

in_vscode() {
  [ "${TERM_PROGRAM:-}" = "vscode" ] && return 0
  [ -n "${VSCODE_PID:-}${VSCODE_GIT_IPC_HANDLE:-}${VSCODE_IPC_HOOK_CLI:-}${VSCODE_INJECTION:-}" ] && return 0
  return 1
}

vscode_bin() {
  if [ -n "${MENTOR_PLAN_VSCODE_BIN:-}" ] && command -v "$MENTOR_PLAN_VSCODE_BIN" >/dev/null 2>&1; then
    printf '%s' "$MENTOR_PLAN_VSCODE_BIN"; return 0
  fi
  local b
  for b in code code-insiders cursor windsurf codium; do
    command -v "$b" >/dev/null 2>&1 && { printf '%s' "$b"; return 0; }
  done
  return 1
}

open_vscode() {   # open the plan as a focused editor tab; user renders it via Live Preview
  [ -n "${MENTOR_PLAN_OPEN_DRYRUN:-}" ] && { echo vscode; return 0; }
  local bin; bin="$(vscode_bin)" || return 1
  "$bin" -r "$file" >/dev/null 2>&1
}

open_chrome() {
  [ -n "${MENTOR_PLAN_OPEN_DRYRUN:-}" ] && { echo chrome; return 0; }
  if command -v open >/dev/null 2>&1; then               # macOS
    open -a "Google Chrome" "$file" >/dev/null 2>&1; return
  fi
  local b
  for b in google-chrome google-chrome-stable chromium chromium-browser; do
    command -v "$b" >/dev/null 2>&1 && { "$b" "$file" >/dev/null 2>&1 & return 0; }
  done
  return 1
}

open_system() {
  [ -n "${MENTOR_PLAN_OPEN_DRYRUN:-}" ] && { echo system; return 0; }
  { command -v open    >/dev/null 2>&1 && open    "$file"; } \
    || { command -v xdg-open >/dev/null 2>&1 && xdg-open "$file"; } \
    || { command -v wslview  >/dev/null 2>&1 && wslview  "$file"; } \
    || return 1
}

# --- dispatch --------------------------------------------------------------
# Markdown plans render as plain text in a browser, so for *.md we prefer a VSCode editor
# tab (the user toggles Markdown preview with ⇧⌘V) and fall back to the OS default handler
# (file association) — NEVER Chrome. HTML plans keep the original browser-first behavior.
case "$file" in
  *.md)
    case "${MENTOR_PLAN_OPENER:-auto}" in
      system) open_system ;;
      chrome) open_system ;;                  # Chrome can't render raw Markdown → OS default
      vscode) open_vscode || open_system ;;
      *)      open_vscode || open_system ;;   # auto: VSCode tab if installed, else OS default
    esac
    ;;
  *)
    case "${MENTOR_PLAN_OPENER:-auto}" in
      system) open_system ;;
      chrome) open_chrome || open_system ;;
      vscode) open_vscode || open_chrome || open_system ;;
      *)      if in_vscode; then open_vscode || open_chrome || open_system
              else                open_chrome || open_system; fi ;;
    esac
    ;;
esac

: > "$marker" 2>/dev/null || true   # mark as opened so subsequent edits don't re-open

exit 0
