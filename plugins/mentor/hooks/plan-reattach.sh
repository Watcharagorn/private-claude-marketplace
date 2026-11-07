#!/usr/bin/env bash
# SessionStart: point fresh context at this worktree's live plan, without owning a run.
# Exact-session run markers survive resume/compact; clear/fork mint a new session id.
# Read-only and fail-open: this hook never creates, transfers or deletes a marker.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh" 2>/dev/null || exit 0
INPUT="$(cat)" || exit 0
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"
[ -n "$repo_root" ] || exit 0
state_dir="$(mentor_state_dir "$repo_root")"
plans_dir="$(mentor_plans_dir "$repo_root")"
wt_id="$(mentor_worktree_id "$CWD")"
session_id="$(printf '%s' "$INPUT" | jq -r '.session_id // "" | select(type == "string")' 2>/dev/null)" || exit 0
source="$(printf '%s' "$INPUT" | jq -r '.source // "" | select(type == "string")' 2>/dev/null)" || exit 0

# Same key=value reader as plan-continue.sh. Never inspect another session's marker.
slug=""; owns_run=0
case "$session_id" in
  ''|*/*|.|..) ;;
  *) slug="$(mentor_marker_field "${state_dir}/.run-${session_id}" slug)" ;;
esac
case "$slug" in ''|*/*|.|..) slug="" ;; *) owns_run=1 ;; esac

# A live own/legacy gate applies here; a sibling worktree's gate does not.
armed=0
for marker in "$(mentor_plan_marker "$plans_dir" "$wt_id")" "${plans_dir}/.planning"; do
  if [ -f "$marker" ] && ! mentor_marker_stale "$marker"; then armed=1; break; fi
done
if [ -z "$slug" ] && [ "$armed" -eq 1 ]; then
  candidate="$(mentor_armed_draft "$plans_dir" "$wt_id")"
  if [ -n "$candidate" ]; then slug="$(basename "$(dirname "$candidate")")"; fi
fi

# Include sidecars even when plan.md is missing. Only an explicit worktree owner
# authorizes recovery without a gate; unowned/implemented plans are not live runs.
if [ -z "$slug" ] && [ "$armed" -eq 0 ]; then
  newest=""
  for dir in "${plans_dir}"/*; do
    [ -d "$dir" ] || continue
    owner="$(mentor_plan_owner "$dir")"
    stored="$(mentor_plan_state_stored "$dir")"
    [ -n "$wt_id" ] && [ "$owner" = "$wt_id" ] && [ "$stored" = in_progress ] || continue
    stamp="${dir}/plan.md"
    [ -f "$stamp" ] || stamp="${dir}/.state.json"
    [ -f "$stamp" ] || continue
    if [ -z "$newest" ] || [ "$stamp" -nt "$newest" ]; then newest="$stamp"; fi
  done
  if [ -n "$newest" ]; then slug="$(basename "$(dirname "$newest")")"; fi
fi
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
  facts="$(mentor_plan_step_scan "$scan_md" 2>/dev/null)"
  ticked="$(printf '%s\n' "$facts" | awk -F '\t' '$1 == "STEP" && $5 == 1 { n++ } END { print n+0 }')"
  total="$(printf '%s\n' "$facts" | awk -F '\t' '$1 == "TOTAL" { print $2 }')"
  total="${total:-0}"
  next="$(printf '%s\n' "$facts" | awk -F '\t' '$1 == "STEP" && $5 == 0 { print $2; exit }')"
  if [ ! -f "$scan_md" ]; then where="unavailable (plan.md missing)"
  elif [ "$stored" = draft ]; then where=drafting
  elif [ "$total" -eq 0 ] && [ "$stored" != approved ] && [ "$stored" != in_progress ]; then where=drafting
  elif [ -n "$next" ]; then where="step ${next}/${total}"
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
