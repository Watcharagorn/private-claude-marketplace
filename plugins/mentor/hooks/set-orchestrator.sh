#!/usr/bin/env bash
# set-orchestrator.sh — read/write the mentor "orchestrator" toggle (repo or global).
#
# Usage: set-orchestrator.sh [on|off|status|clear] [--global]    (bare = status)
#
# orchestrator is an ORTHOGONAL toggle (NOT a working mode). It lives as
# {"orchestrator": true|false} in:
#   • repo:   ~/.claude/mentor/{repo_base}-{repo_hash}/config.json
#   • global: ~/.claude/mentor/config.json
# Resolution (mentor_orchestrator_on): explicit repo value > legacy mode:commander >
# global value > OFF. A repo `off` therefore overrides a global `on`; `clear` deletes
# the scope's key so it re-inherits the lower scope (the only way back from repo `off`).
#
# Ownership: this script owns ONLY the `.orchestrator` key — it MERGES (never clobbers
# `.mode`). set-mode.sh owns `.mode`. Both write atomically (mktemp+mv). The only residual
# lost-update window is a simultaneous first-time file creation by both — accepted, since
# both are interactive, human-driven commands (not hot-path hooks).

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "[mentor orchestrator] jq is required." >&2; exit 1; }

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${hook_dir}/lib/state.sh"

# --- parse args (action-first; optional global scope token) ---
action="status"
scope="repo"
for a in "$@"; do
  case "$a" in
    on|off|status|clear) action="$a" ;;
    --global|global)     scope="global" ;;
    --repo|repo)         scope="repo" ;;
    *) echo "[mentor orchestrator] Unknown arg: ${a}" >&2
       echo "Usage: set-orchestrator.sh [on|off|status|clear] [--global]" >&2
       exit 1 ;;
  esac
done

global_cfg="${HOME}/.claude/mentor/config.json"
repo_root="$(mentor_repo_root "$(pwd)")"
[ -n "$repo_root" ] && mentor_migrate_legacy_commander "$repo_root"
repo_cfg=""
[ -n "$repo_root" ] && repo_cfg="$(mentor_state_dir "$repo_root")/config.json"

# write a boolean into a config file, merge-safe (creates dir + file if needed).
write_bool() {  # <config_path> <true|false>
  local cfg="$1" val="$2" dir tmp
  dir="$(dirname "$cfg")"
  mkdir -p -m 700 "$dir"
  if [ -f "$cfg" ]; then
    tmp="$(mktemp "${dir}/.config.XXXXXX")"
    jq --argjson v "$val" '.orchestrator = $v' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  else
    jq -n --argjson v "$val" '{orchestrator: $v}' > "$cfg"   # merge-safe create (NOT printf)
  fi
}

# delete the .orchestrator key so the scope re-inherits the lower one (no-op if absent).
clear_key() {  # <config_path>
  local cfg="$1" dir tmp
  [ -f "$cfg" ] || return 0
  dir="$(dirname "$cfg")"
  tmp="$(mktemp "${dir}/.config.XXXXXX")"
  jq 'del(.orchestrator)' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

print_status() {
  local repo_raw="unset" global_raw resolved winner
  global_raw="$(mentor_config_bool "$global_cfg" orchestrator)"
  if [ -n "$repo_root" ]; then
    repo_raw="$(mentor_config_bool "$repo_cfg" orchestrator)"
    if mentor_orchestrator_on "$repo_root"; then resolved="ON"; else resolved="OFF"; fi
    case "$repo_raw" in
      true|false) winner="repo" ;;
      *) if [ "$(mentor_get_mode "$repo_root")" = "commander" ]; then winner="legacy(mode:commander)"
         elif [ "$global_raw" = "true" ] || [ "$global_raw" = "false" ]; then winner="global"
         else winner="default"; fi ;;
    esac
    echo "orchestrator: ${resolved}  (winning scope: ${winner})"
    echo "  repo:   ${repo_raw}  (${repo_cfg})"
    echo "  global: ${global_raw}  (${global_cfg})"
  else
    echo "orchestrator (global): ${global_raw}  (${global_cfg})"
    echo "  Not inside a git repo — resolved state requires a repo (the gate is repo-scoped)."
  fi
}

case "$action" in
  status)
    print_status
    exit 0
    ;;
  on|off|clear)
    if [ "$scope" = "repo" ]; then
      if [ -z "$repo_root" ]; then
        echo "[mentor orchestrator] Not inside a git repo — repo scope needs a repo." >&2
        echo "  Use '--global' to set the global toggle, or cd into a repo." >&2
        exit 1
      fi
      target="$repo_cfg"; label="repo"
    else
      target="$global_cfg"; label="global"
    fi
    case "$action" in
      on)
        write_bool "$target" true
        echo "[mentor orchestrator] ${label}: ON"
        echo "  config: ${target}"
        echo "  Live immediately — the gate reads config on every call."
        echo "  (Just installed/updated mentor this session? Hooks register at session start — restart so the gate activates.)"
        [ "$label" = "global" ] && echo "  Applies to every repo (unless that repo sets an explicit value); effective only inside a git repo."
        ;;
      off)
        write_bool "$target" false
        echo "[mentor orchestrator] ${label}: OFF"
        echo "  config: ${target}"
        [ "$label" = "repo" ] && echo "  Explicit repo OFF overrides a global ON. To re-inherit global, run /mentor:orchestrator clear."
        ;;
      clear)
        clear_key "$target"
        echo "[mentor orchestrator] ${label}: cleared — re-inherits the lower scope (repo→global→OFF)."
        echo "  config: ${target}"
        ;;
    esac
    echo "---"
    print_status
    exit 0
    ;;
esac
