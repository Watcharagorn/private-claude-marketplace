# lib/state.sh — shared per-repo state derivation for mentor hooks. SOURCED, never executed.
#
# Source from a hook (hooks.json invokes hooks by absolute path, so this resolves):
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
#
# Layout (v1.0.0):
#   ~/.claude/mentor/{repo_base}-{repo_hash}/
#   ├── config.json   # {"mode": "plan|plan-only"}
#   └── plans/        # <slug>.md plan file + the .planning marker (+ *.opened sidecars)
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

# mentor_state_dir <repo_root> — echo ~/.claude/mentor/{base}-{hash} for the repo.
# Empty on bad input. Not mkdir'd.
mentor_state_dir() {
  local repo_root="${1:-}" repo_base repo_hash
  if [ -z "$repo_root" ]; then echo ""; return 0; fi
  repo_base="$(basename "$repo_root")"
  repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
  echo "${HOME}/.claude/mentor/${repo_base}-${repo_hash}"
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

# mentor_get_mode <repo_root> — echo the persisted repo mode (plan|plan-only)
# or empty when unset / no repo / no jq (fail-open to default behavior).
mentor_get_mode() {
  local repo_root="${1:-}" config
  if [ -z "$repo_root" ]; then echo ""; return 0; fi
  config="$(mentor_state_dir "$repo_root")/config.json"
  if [ ! -f "$config" ]; then echo ""; return 0; fi
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  jq -r '.mode // ""' "$config" 2>/dev/null || true
  return 0
}

# mentor_cwd <input_json> — echo the hook cwd ($PWD fallback).
mentor_cwd() {
  local cwd
  cwd="$(printf '%s' "${1:-}" | jq -r '.cwd // empty' 2>/dev/null || true)"
  [ -z "$cwd" ] && cwd="$PWD"
  echo "$cwd"
  return 0
}
