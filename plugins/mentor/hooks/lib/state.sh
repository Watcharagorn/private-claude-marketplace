# lib/state.sh — shared per-repo state derivation for mentor hooks. SOURCED, never executed.
#
# Source from a hook (hooks.json invokes hooks by absolute path, so this resolves):
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
#
# Layout (v2.2.0 — project-scoped, one directory per plan):
#   <repo_root>/.mentor/
#   ├── .gitignore        # commit config.json + constitution.md; ignore transient state
#   ├── config.json       # {"mode": "plan|plan-only", "context_gate", "context_*_tokens" ...}
#   ├── constitution.md   # governing principles (committed; managed by /mentor:constitution)
#   ├── plans/            # the .planning marker + one <slug>/ dir per plan:
#   │   └── <slug>/       #   plan.md (+ hidden .plan.md.opened sidecar)
#   │       └── zoom/     #   <topic>-<perspective>.html (+ hidden .*.opened sidecars)
#   └── handoffs/         # <ts>-<slug>.md
#   (.context-warned-<session_id> markers live at the .mentor/ root.)
#   Not inside a git repo → callers fall back to ~/.claude/mentor/_no-repo/.
#
# CONTRACT: callers run under `set -euo pipefail`. Every function here exits with
# status 0. All helpers are fail-soft: bad input echoes empty, never aborts the caller.

# mentor_repo_root <cwd> — echo the repo root (main worktree, via git-common-dir,
# so linked worktrees share one state dir). Echoes empty when not in a repo.
mentor_repo_root() {
  local cwd="${1:-$PWD}" git_common common_abs root
  git_common="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -z "$git_common" ]; then echo ""; return 0; fi
  case "$git_common" in
    /*) common_abs="$git_common" ;;
    *)  common_abs="${cwd}/${git_common}" ;;
  esac
  root="$(cd "$(dirname "$common_abs")" 2>/dev/null && pwd || true)"
  echo "$root"
  return 0
}

# mentor_state_dir <repo_root> — echo <repo_root>/.mentor (project-scoped state dir).
# Empty on bad input (callers fall back to ~/.claude/mentor/_no-repo/). Not mkdir'd.
mentor_state_dir() {
  local repo_root="${1:-}"
  if [ -z "$repo_root" ]; then echo ""; return 0; fi
  echo "${repo_root}/.mentor"
  return 0
}

# mentor_plans_dir <repo_root> — echo the plans/markers dir (state_dir/plans). Not mkdir'd.
mentor_plans_dir() {
  local state_dir
  state_dir="$(mentor_state_dir "${1:-}")"
  if [ -z "$state_dir" ]; then echo ""; return 0; fi
  echo "${state_dir}/plans"
  return 0
}

# mentor_newest_plan <plans_dir> — echo the current plan file: the mtime-newest
# <plans_dir>/<slug>/plan.md, or empty when none exist. Legacy flat
# <plans_dir>/*.md files are ignored (begin-plan.sh migrates them on arm).
mentor_newest_plan() {
  local plans_dir="${1:-}"
  if [ -z "$plans_dir" ]; then echo ""; return 0; fi
  ls -t "${plans_dir}"/*/plan.md 2>/dev/null | head -1 || true
  return 0
}

# mentor_ensure_gitignore <state_dir> — idempotently write <state_dir>/.gitignore so
# only config.json is committed and transient session state (plans, handoffs, markers)
# stays out of `git status`. Never overwrites an existing file — a user may un-ignore
# plans/ to version-control plans. Fail-soft: bad input / unwritable → status 0.
mentor_ensure_gitignore() {
  local state_dir="${1:-}"
  [ -z "$state_dir" ] && return 0
  [ -e "${state_dir}/.gitignore" ] && return 0
  cat > "${state_dir}/.gitignore" 2>/dev/null <<'GITIGNORE' || true
# mentor — project-scoped state. Committed: config.json, constitution.md (+ this file).
# Ignored: transient session state (plans, handoffs, markers).
*
!.gitignore
!config.json
!constitution.md
GITIGNORE
  return 0
}

# mentor_config_get <repo_root> <key> — echo the string value of config.json[<key>]
# (numbers coerced to text), or empty when no repo / no file / no jq / unset.
mentor_config_get() {
  local repo_root="${1:-}" key="${2:-}" config
  if [ -z "$repo_root" ] || [ -z "$key" ]; then echo ""; return 0; fi
  config="$(mentor_state_dir "$repo_root")/config.json"
  if [ ! -f "$config" ]; then echo ""; return 0; fi
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  jq -r --arg k "$key" '.[$k] // "" | tostring' "$config" 2>/dev/null || true
  return 0
}

# mentor_get_mode <repo_root> — echo the persisted approval-gate default (plan|plan-only)
# or empty when unset / no repo / no jq (fail-open: unset behaves as plan).
mentor_get_mode() {
  mentor_config_get "${1:-}" "mode"
}

# mentor_cwd <input_json> — echo the hook cwd ($PWD fallback).
mentor_cwd() {
  local cwd
  cwd="$(printf '%s' "${1:-}" | jq -r '.cwd // empty' 2>/dev/null || true)"
  [ -z "$cwd" ] && cwd="$PWD"
  echo "$cwd"
  return 0
}

# --- context gate -----------------------------------------------------------

# mentor_context_tokens <transcript_path> — echo the current main-chain context size
# in tokens (the last assistant usage record, or the postTokens of a later
# compact_boundary), or empty when unmeasurable (no file / no jq / no usage in the tail
# window). Skips subagent sidechains and <synthetic> all-zero API-error placeholders.
mentor_context_tokens() {
  local tx="${1:-}" last
  [ -z "$tx" ] && { echo ""; return 0; }
  [ -f "$tx" ] || { echo ""; return 0; }
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  last="$(tail -n "${MENTOR_CONTEXT_TAIL_LINES:-400}" "$tx" 2>/dev/null | jq -R -r '
    fromjson? | select(type == "object") | select(.isSidechain != true)
    | if .type == "assistant" then
        (.message.usage? // empty) | select(type == "object")
        | select(.input_tokens != null)
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
        | select(. > 0)
      elif .type == "system" and .subtype == "compact_boundary" then
        (.compactMetadata.postTokens // 0) | select(. > 0)
      else empty end' 2>/dev/null | tail -n 1)"
  case "$last" in
    ''|*[!0-9]*) echo ""; return 0 ;;
  esac
  echo "$last"
  return 0
}

# mentor_context_threshold <repo_root> <env_value> <config_key> <default> — resolve a
# numeric threshold with precedence env > config.json > default. A candidate wins only
# if all-digits; otherwise fall through. Echoes the chosen integer.
mentor_context_threshold() {
  local repo_root="${1:-}" env_value="${2:-}" config_key="${3:-}" default="${4:-}" cfg
  case "$env_value" in
    ''|*[!0-9]*) ;;
    *) echo "$env_value"; return 0 ;;
  esac
  cfg="$(mentor_config_get "$repo_root" "$config_key")"
  case "$cfg" in
    ''|*[!0-9]*) ;;
    *) echo "$cfg"; return 0 ;;
  esac
  echo "$default"
  return 0
}

# mentor_context_gate_state <repo_root> — echo "off" when the gate is disabled via env
# MENTOR_CONTEXT_GATE (off|0|false|no) or config context_gate == "off"; else "on".
mentor_context_gate_state() {
  local repo_root="${1:-}" cfg
  case "${MENTOR_CONTEXT_GATE:-}" in
    off|0|false|no) echo "off"; return 0 ;;
  esac
  cfg="$(mentor_config_get "$repo_root" "context_gate")"
  if [ "$cfg" = "off" ]; then echo "off"; return 0; fi
  echo "on"
  return 0
}
