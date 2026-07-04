# lib/state.sh — shared per-repo state derivation for mentor hooks. SOURCED, never executed.
#
# Source from a hook (hooks.json invokes hooks by absolute path, so this resolves):
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
#
# Layout (v0.37.0):
#   ~/.claude/mentor/config.json               # {"orchestrator": true|false} — GLOBAL policy
#   ~/.claude/mentor/{repo_base}-{repo_hash}/
#   ├── config.json   # {"mode": "plan|plan-only", "orchestrator": true|false, "format": "md|html"} — repo policy
#   └── plans/        # plan file (HTML or Markdown) + markers (.planning, .research-dispatched, …)
# `orchestrator` is an orthogonal toggle (commander was a mode pre-0.37; auto-migrated).
# Precedence: explicit repo value > legacy mode:commander > global value > OFF.
# Legacy (pre-0.33) ~/.claude/mentor/plans/{base}-{hash}/ is auto-migrated once by
# mentor_state_dir (atomic mv; a concurrent loser's mv fails silently).
#
# CONTRACT: callers run under `set -euo pipefail`. Every function here exits with
# status 0 unless its return value IS the status (mentor_orchestrator_on /
# mentor_marker_fresh — call those ONLY in condition position, e.g.
# `mentor_orchestrator_on "$root" || exit 0`). All helpers are fail-soft: bad input
# echoes empty / returns 1, never aborts the caller.

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

# mentor_state_dir <repo_root> — echo ~/.claude/mentor/{base}-{hash} for the repo,
# auto-migrating the legacy plans dir into it (one-shot, race-safe). Empty on bad input.
mentor_state_dir() {
  local repo_root="${1:-}" repo_base repo_hash state_dir legacy
  if [ -z "$repo_root" ]; then echo ""; return 0; fi
  repo_base="$(basename "$repo_root")"
  repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
  state_dir="${HOME}/.claude/mentor/${repo_base}-${repo_hash}"
  legacy="${HOME}/.claude/mentor/plans/${repo_base}-${repo_hash}"
  # One-shot migration (drop the legacy check in 0.34): markers + HTML move together.
  if [ -d "$legacy" ] && [ ! -d "${state_dir}/plans" ]; then
    mkdir -p -m 700 "$state_dir" 2>/dev/null || true
    mv "$legacy" "${state_dir}/plans" 2>/dev/null || true
  fi
  echo "$state_dir"
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
# NOTE: reads the config WITHOUT triggering migration (hot path — see mentor_orchestrator_on).
# A lingering legacy "commander" value may still be echoed pre-migration; readers should
# treat it as plan (orchestration is governed by mentor_orchestrator_on, not the mode).
mentor_get_mode() {
  local repo_root="${1:-}" repo_base repo_hash config
  if [ -z "$repo_root" ]; then echo ""; return 0; fi
  repo_base="$(basename "$repo_root")"
  repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
  config="${HOME}/.claude/mentor/${repo_base}-${repo_hash}/config.json"
  if [ ! -f "$config" ]; then echo ""; return 0; fi
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  jq -r '.mode // ""' "$config" 2>/dev/null || true
  return 0
}

# mentor_get_format <repo_root> — echo the effective plan output format ("md" | "html")
# or empty when unset (caller asks the user / falls back to default behavior).
# Resolution precedence: env MENTOR_PLAN_FORMAT (validated) > repo config .format
# (clamped to md|html) > "" (unset).
#
# CRITICAL — both the env override and the config value are VALIDITY-CHECKED against
# {md,html}. The format word doubles as the deliverable file extension (*.md / *.html)
# in the existence gates, so an invalid value (a typo, "markdown", "htm") MUST NOT win:
# it would yield an unsatisfiable `*.${fmt}` glob and a permanent, escape-less exit-2
# block. An invalid/empty env value falls through to config; an invalid config value
# is treated as unset. Uses `[ -n "${MENTOR_PLAN_FORMAT:-}" ]` so an empty env var
# falls through rather than overriding to "". Fail-soft: no path/file/jq → "".
mentor_get_format() {
  local repo_root="${1:-}" repo_base repo_hash config val
  if [ -n "${MENTOR_PLAN_FORMAT:-}" ]; then
    case "$MENTOR_PLAN_FORMAT" in
      md|html) echo "$MENTOR_PLAN_FORMAT"; return 0 ;;   # valid env override wins
      *) ;;                                              # invalid → fall through to config
    esac
  fi
  if [ -z "$repo_root" ]; then echo ""; return 0; fi
  repo_base="$(basename "$repo_root")"
  repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
  config="${HOME}/.claude/mentor/${repo_base}-${repo_hash}/config.json"
  if [ ! -f "$config" ]; then echo ""; return 0; fi
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  val="$(jq -r '.format // ""' "$config" 2>/dev/null || true)"
  case "$val" in
    md|html) echo "$val" ;;
    *) echo "" ;;                                        # absent / invalid → unset
  esac
  return 0
}

# mentor_plan_ext <repo_root> — echo the plan deliverable's file extension for the repo's
# configured output format: "md" when format=md, else "html" (the default / back-compat
# deliverable, also covering unset/invalid). This is the ONE place the format→extension
# mapping lives; the existence gates (strategy-guard, plan-author-gate, plan-html-stop-gate)
# call it instead of re-deriving the same case, so a future third format touches one line.
# Fail-soft: inherits mentor_get_format's soft failures (no path/config/jq → html).
mentor_plan_ext() {
  case "$(mentor_get_format "${1:-}")" in
    md) echo "md" ;;
    *)  echo "html" ;;
  esac
}

# mentor_extract_plan_source — stdin filter: emit the canonical Markdown inside an HTML
# plan's <script type="text/markdown" id="plan-source">…</script> block (the two sed
# passes drop the open/close tag lines). Emits nothing when no block is present. This is
# THE extraction — strategy-guard.sh, dispatch-executor.sh, and plan-finalize.sh all call
# it, so the finalized .md is byte-identical to what the guard validated (no regex drift).
mentor_extract_plan_source() {
  sed -n '/<script[^>]*id="plan-source"/,/<\/script>/p' | sed '1d;$d'
}

# mentor_config_bool <config_path> <key> — echo "true" | "false" | "unset".
# Distinguishes an absent key from an explicit false (jq's `// ` cannot — `false // x`
# yields x — so we test has($k)). Fail-soft: no path/key/file/jq → "unset".
mentor_config_bool() {
  local cfg="${1:-}" key="${2:-}"
  { [ -z "$cfg" ] || [ -z "$key" ] || [ ! -f "$cfg" ]; } && { echo "unset"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "unset"; return 0; }
  jq -r --arg k "$key" 'if has($k) then (.[$k]|tostring) else "unset" end' "$cfg" 2>/dev/null || echo "unset"
}

# mentor_orchestrator_on <repo_root> — status 0 iff orchestrator is ON.
# Condition position only: `mentor_orchestrator_on "$root" || exit 0`.
# Precedence: explicit repo value > legacy mode:commander > global value > OFF.
# Every branch is `<test> && return <code>` (never a bare test — that would abort the
# caller under `set -e`); config reads are captured via $(...) where set -e is masked.
mentor_orchestrator_on() {
  local root="${1:-}" repo_cfg repo glob
  repo_cfg="${HOME}/.claude/mentor/$(basename "$root")-$(printf '%s' "$root" | shasum | cut -c1-8)/config.json"
  repo="$(mentor_config_bool "$repo_cfg" orchestrator)"
  [ "$repo" = "true" ]  && return 0
  [ "$repo" = "false" ] && return 1                          # explicit repo override beats global
  [ "$(mentor_get_mode "$root")" = "commander" ] && return 0 # legacy, pre-rewrite
  glob="$(mentor_config_bool "${HOME}/.claude/mentor/config.json" orchestrator)"
  [ "$glob" = "true" ]                                       # final return value
}

# mentor_migrate_legacy_commander <repo_root> — one-shot: rewrite a legacy
# {"mode":"commander"} repo config to {"mode":"plan", "orchestrator":true}. Never clobbers
# an explicit `orchestrator` value (a user may have set commander+orchestrator:false). The
# mode==commander guard makes it a no-op after the first run. Atomic (mktemp+mv); fail-soft.
mentor_migrate_legacy_commander() {
  local root="${1:-}" cfg tmp state_dir
  [ -z "$root" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  state_dir="${HOME}/.claude/mentor/$(basename "$root")-$(printf '%s' "$root" | shasum | cut -c1-8)"
  cfg="${state_dir}/config.json"
  [ -f "$cfg" ] || return 0
  [ "$(jq -r '.mode // ""' "$cfg" 2>/dev/null || true)" = "commander" ] || return 0
  tmp="$(mktemp "${state_dir}/.config.XXXXXX" 2>/dev/null)" || return 0
  if jq 'if has("orchestrator") then .mode="plan" else (.mode="plan" | .orchestrator=true) end' "$cfg" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$cfg" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# mentor_marker_fresh <file> [mins=480] — status 0 iff the file exists and its
# mtime is within the window. Condition position only.
mentor_marker_fresh() {
  local f="${1:-}" mins="${2:-480}"
  [ -n "$f" ] && [ -f "$f" ] && [ -z "$(find "$f" -mmin "+${mins}" 2>/dev/null)" ]
}

# mentor_session_id <input_json> — echo the session id ("default" fallback).
mentor_session_id() {
  local sid
  sid="$(printf '%s' "${1:-}" | jq -r '.session_id // .sessionId // "default"' 2>/dev/null || true)"
  [ -z "$sid" ] && sid="default"
  echo "$sid"
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
