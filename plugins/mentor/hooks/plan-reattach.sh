#!/usr/bin/env bash
# SessionStart: point fresh context at this worktree's live plan, without owning a run.
# Exact-session run markers survive resume/compact; clear/fork mint a new session id.
# Read-only and fail-open: this hook never creates, transfers or deletes a marker.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh" 2>/dev/null || exit 0
INPUT="$(cat)" || exit 0
# NUL-delimited fields preserve whitespace in paths/session ids. The final token
# confirms jq validated the whole input, including a possible trailing parse error.
{
  IFS= read -r -d '' CWD &&
  IFS= read -r -d '' session_id &&
  IFS= read -r -d '' source &&
  IFS= read -r -d '' cwd_type &&
  IFS= read -r -d '' parsed
} < <(
  printf '%s' "$INPUT" | jq -jse '
    select(length > 0 and (.[-1] | type == "object"))
    | (map(.cwd // empty | tostring) | join("\n")),
      (map(.session_id // "" | select(type == "string")) | join("\n")),
      (map(.source // "" | select(type == "string")) | join("\n")),
      (if any(.[]; (.cwd // "" | type) == "object" or (.cwd // "" | type) == "array")
       then "complex" else "scalar" end)
    | gsub("\u0000"; "") | sub("\n+$"; "") | . + "\u0000"
  ' 2>/dev/null && printf 'ok\0'
) || exit 0
[ "$parsed" = ok ] || exit 0
# Keep mentor_cwd's pretty-printed handling of exceptional non-scalar cwd values.
case "$cwd_type" in complex) CWD="$(mentor_cwd "$INPUT")" ;; esac
[ -n "$CWD" ] || CWD="$PWD"

repo_root="$(mentor_repo_root "$CWD")"
[ -n "$repo_root" ] || exit 0
state_dir="$(mentor_state_dir "$repo_root")"
plans_dir="$(mentor_plans_dir "$repo_root")"
wt_id=""
[ ! -d "$plans_dir" ] || wt_id="$(mentor_worktree_id "$CWD")"

# A live own/legacy gate applies here; a sibling worktree's gate does not.
armed=0
gate="$(mentor_live_gate "$plans_dir" "$wt_id")"
[ -z "$gate" ] || armed=1
slug=""; owns_run=0
IFS=$'\t' read -r selection candidate <<<"$(mentor_live_plan "$plans_dir" "$wt_id" "$session_id" "$gate")"
if [ -n "$candidate" ]; then slug="$(basename "$(dirname "$candidate")")"; fi
[ "$selection" != run ] || owns_run=1
[ -n "$slug" ] || [ "$armed" -eq 1 ] || exit 0

if [ -z "$slug" ]; then
  # The gate can predate research's first skeleton; do not invent a plan slug.
  block="$(printf 'mentor plan: drafting\npath: .mentor/plans/ (no plan.md yet)\nstate: unknown\nticks: 0/0\nnext: drafting')"
else
  plan_dir="${plans_dir}/${slug}"
  plan_md="${plan_dir}/plan.md"
  stored="$(mentor_plan_state_stored "$plan_dir")"
  stored="${stored:-unknown}"
  scan_md="$plan_md"; recovery=""
  if [ ! -f "$plan_md" ]; then
    # Review snapshots are copies of this slug, never another plan's history.
    copy=""
    while IFS= read -r f; do
      if [ -z "$copy" ] || [ "$f" -nt "$copy" ]; then copy="$f"; fi
    done < <(find "${state_dir}/reviews/${slug}" -type f -name _plan.md 2>/dev/null || true)
    if [ -n "$copy" ]; then
      recovery="plan.md missing: .mentor/plans/${slug}/plan.md; fallback: ${copy#"${repo_root}/"} (sidecar state retained)"
      scan_md="$copy"
    else
      recovery="plan.md missing: .mentor/plans/${slug}/plan.md; fallback: no copy found (sidecar state retained)"
    fi
  fi
  # The shared step scan is also used by plan-continue.sh: ticks never finish a run.
  IFS=$'\t' read -r ticked total next title <<<"$(mentor_plan_scan_summary "$scan_md" 2>/dev/null)"
  if [ ! -f "$scan_md" ]; then where="unavailable (plan.md missing)"
  elif [ "$stored" = draft ]; then where=drafting
  elif [ "$total" -eq 0 ] && [ "$stored" != approved ] && [ "$stored" != in_progress ]; then where=drafting
  elif [ "$next" -gt 0 ]; then where="step ${next}/${total}"
  else where="goal check"; fi
  block="$(printf 'mentor plan: %s\npath: .mentor/plans/%s/plan.md\nstate: %s\nticks: %s/%s\nnext: %s' "$slug" "$slug" "$stored" "$ticked" "$total" "$where")"
  [ -z "$recovery" ] || block="${block}"$'\n'"${recovery}"
  if [ "$(mentor_plan_drift "$plan_md")" = changed ]; then
    block="${block}"$'\n'"plan.md changed since mentor last wrote it — read it before editing it further"
  fi
  if [ "$source" != fork ] && [ "$owns_run" -eq 0 ] && [ "$stored" = in_progress ]; then
    block="${block}"$'\n'"resume with /mentor:plan ${slug}"
  fi
fi
if [ "$source" = fork ]; then
  block="${block}"$'\n'"this fork owns no run — the run belongs to the original session"
fi
jq -n --arg context "$block" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}' 2>/dev/null || true
exit 0
