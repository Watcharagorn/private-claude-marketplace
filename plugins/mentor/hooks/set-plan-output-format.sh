#!/usr/bin/env bash
# set-plan-output-format.sh — read/write the persisted per-repo PLAN OUTPUT FORMAT.
#
# Usage: set-plan-output-format.sh [md|html|status]    (bare = status)
#
# The format lives in ~/.claude/mentor/{repo_base}-{repo_hash}/config.json as
# {"format": "..."} :
#   html — the bespoke, self-contained styled HTML plan document (the original
#          deliverable). Rich CSS theme, live iframe mockups, animation.
#   md   — a self-contained Markdown plan. Visualization is Mermaid-first
#          (fenced ```mermaid), with ASCII diagrams, GFM tables and GFM alerts.
#          Renders richly on GitHub/GitLab and in a Mermaid-capable Markdown
#          preview. The .md file IS its own canonical source (footer markers at
#          EOF, dispatch annotations inline — no embedded plan-source block).
#
# There is NO baked-in default: when unset, the plan harness asks the user once
# (Markdown / HTML) and persists the choice here. An env override
# MENTOR_PLAN_FORMAT=md|html takes precedence over this file (resolved in
# lib/state.sh mentor_get_format) but is NOT written here.
#
# Ownership: this script owns the `.format` key (merges atomically, preserving
# `.mode` / `.orchestrator`). set-mode.sh owns `.mode`; set-orchestrator.sh owns
# `.orchestrator`. Neither touches /tmp flags.
#
# Status output contract (consumed by commands/plan-output-format.md and
# begin-plan.sh / mentor-plan SKILL): "format: <fmt>" or the literal token
# "UNSET" when no format is persisted.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "[mentor format] jq is required." >&2; exit 1; }

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${hook_dir}/lib/state.sh"

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  echo "[mentor format] Not inside a git repo — the plan output format is per-repo. cd into a repo first." >&2
  exit 1
fi

state_dir="$(mentor_state_dir "$repo_root")"
config="${state_dir}/config.json"
arg="$(printf '%s' "${1:-status}" | tr '[:upper:]' '[:lower:]')"

# Normalize a couple of forgiving aliases to the canonical tokens.
case "$arg" in
  markdown) arg="md" ;;
  htm)      arg="html" ;;
esac

print_status() {
  # Show the PERSISTED repo value (not the env-resolved effective value) so the
  # user sees what is written here; then note an env override if one is active.
  local persisted="" env_note=""
  if [ -f "$config" ]; then
    persisted="$(jq -r '.format // ""' "$config" 2>/dev/null || true)"
  fi
  case "$persisted" in md|html) ;; *) persisted="" ;; esac

  if [ -z "$persisted" ]; then
    echo "UNSET — no plan output format persisted for this repo."
    echo "  config: ${config}"
    echo "  Set one with: /mentor:plan-output-format md | html"
  else
    echo "format: ${persisted}"
    echo "  config: ${config}"
  fi
  # Surface an active env override (it wins over the file at plan time).
  if [ -n "${MENTOR_PLAN_FORMAT:-}" ]; then
    case "$MENTOR_PLAN_FORMAT" in
      md|html) echo "  env override: MENTOR_PLAN_FORMAT=${MENTOR_PLAN_FORMAT} (wins over the config value above)" ;;
      *) echo "  env override: MENTOR_PLAN_FORMAT=${MENTOR_PLAN_FORMAT} is INVALID (ignored — must be md|html)" ;;
    esac
  fi
}

case "$arg" in
  status)
    print_status
    exit 0
    ;;
  md|html)
    mkdir -p -m 700 "$state_dir"
    if [ -f "$config" ]; then
      tmp="$(mktemp "${state_dir}/.config.XXXXXX")"
      jq --arg f "$arg" '.format = $f' "$config" > "$tmp" && mv "$tmp" "$config"
    else
      jq -n --arg f "$arg" '{format: $f}' > "$config"   # merge-safe create
    fi
    echo "[mentor format] plan output format set: ${arg}"
    echo "  config: ${config}"
    case "$arg" in
      html)
        echo "  html — bespoke, self-contained styled HTML plan (rich CSS theme, live"
        echo "  iframe mockups, animation). Auto-opens for review in a browser / VSCode tab."
        ;;
      md)
        echo "  md — self-contained Markdown plan. Mermaid-first visualization (+ ASCII"
        echo "  diagrams, GFM tables, GFM alerts). The .md file is its own canonical source."
        echo "  Tip: VSCode's built-in Markdown preview needs a Mermaid extension to render"
        echo "  diagrams (GitHub/GitLab render them natively)."
        ;;
    esac
    exit 0
    ;;
  *)
    echo "[mentor format] Unknown format: ${arg}" >&2
    echo "Usage: set-plan-output-format.sh [md | html | status]" >&2
    exit 1
    ;;
esac
