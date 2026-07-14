#!/usr/bin/env bash
# begin-plan.sh — arm the mentor plan gate.
#
# Invoked by the /mentor:plan command body as its FIRST action, before any
# drafting. It writes the repo-scoped `.planning` marker (which CLOSES the edit
# gate — plan-gate.sh) and clears stale sidecars from a prior planning session.
# It runs as a normal Bash call and is allowed precisely because the gate never
# matches Bash.
#
# The marker's mtime is the SESSION START: approve-plan.sh only accepts a plan
# file NEWER than the marker, so a stale plan from a prior session can never
# release the gate.
#
# Fail-soft: if we cannot resolve a git repo, print a notice and exit 0 — the
# skill still runs; the gate simply isn't armed outside a repo.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  echo "[mentor] Not inside a git repo — plan gate NOT armed (planning still proceeds)."
  exit 0
fi
plans_dir="$(mentor_plans_dir "$repo_root")"

mkdir -p -m 700 "$plans_dir"

# Clear per-plan ".opened" sidecars: plan paths are slug-derived, so a stale
# "<slug>.md.opened" from a prior session would suppress plan-open.sh's
# first-creation open for the same slug.
rm -f "${plans_dir}"/*.opened 2>/dev/null || true

: > "${plans_dir}/.planning"

cat <<EOF
[mentor] Plan phase ARMED.
  marker: ${plans_dir}/.planning
  edits:  repo source writes are now BLOCKED until the plan is approved
          (plan-gate.sh — holds even under bypassPermissions).

Now follow the plan skill. Do NOT edit repo files until approval.
EOF

mode="$(mentor_get_mode "$repo_root")"
case "$mode" in
  plan-only)
    echo "MODE: plan-only"
    cat <<'EOF'
plan-only — after approval the plan file is the DELIVERABLE. Do NOT implement
and do NOT dispatch implementation agents; the approval step will soft-stop.
EOF
    ;;
  "")
    echo "MODE: UNSET"
    cat <<'EOF'
No repo mode is set. After entering the plan skill, FIRST ask the user via
AskUserQuestion which mode to persist for this repo — plan (default: plan then
execute on approval) / plan-only (plans are deliverables; no execution) — then run:
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <choice>
and continue planning.
EOF
    ;;
  *)
    echo "MODE: ${mode}"
    ;;
esac
exit 0
