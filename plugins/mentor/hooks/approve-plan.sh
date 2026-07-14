#!/usr/bin/env bash
# approve-plan.sh — validate the plan, release the plan gate.
#
# Run by the plan skill when the user chooses "Proceed". It:
#   1. locates the newest Markdown plan in the repo-scoped plans dir;
#   2. validates it: non-empty AND newer than the `.planning` marker (the marker's
#      mtime is the session start — begin-plan.sh — so a stale plan from a prior
#      session can never release the gate);
#   3. on success: deletes `.planning` (the gate OPENS — repo edits are allowed);
#   4. on failure: leaves `.planning` in place (the gate STAYS CLOSED), exits 1.
#
# --handoff mode: same validation + gate release, but INSTEAD of implementing it
# prints a hand-off directive (write a /mentor:handoff doc for the next agent and
# STOP). This printed directive is the single source of truth for the hand-off
# instruction.
#
# plan-only repo mode: gate is released but the plan file is the deliverable —
# the printed directive tells the agent to soft-stop.

set -euo pipefail

handoff_mode=0
[ "${1:-}" = "--handoff" ] && handoff_mode=1

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${hook_dir}/lib/state.sh"
cwd="$(pwd)"

repo_root="$(mentor_repo_root "$cwd")"
if [ -z "$repo_root" ]; then
  echo "[mentor approve-plan] Not in a git repo — nothing to release." >&2
  exit 1
fi
plans_dir="$(mentor_plans_dir "$repo_root")"
marker="${plans_dir}/.planning"

newest_plan="$(ls -t "${plans_dir}/"*.md 2>/dev/null | head -1 || true)"

if [ ! -f "$marker" ]; then
  # Idempotency: gate already open (already approved, or never armed).
  echo "[mentor approve-plan] Gate is already open — nothing to release."
  [ -n "$newest_plan" ] && echo "  plan: ${newest_plan}"
  exit 0
fi

if [ -z "$newest_plan" ] || [ ! -s "$newest_plan" ]; then
  echo "[mentor approve-plan] No Markdown plan found in ${plans_dir}." >&2
  echo "Write the plan (<slug>.md) before approving — the gate stays CLOSED." >&2
  exit 1
fi

# Staleness defense: the plan must be newer than the marker (i.e. written THIS
# planning session). begin-plan never purges prior sessions' approved plans, so
# "newest non-empty" alone would let a premature approve resurrect an old plan.
if [ ! "$newest_plan" -nt "$marker" ]; then
  echo "[mentor approve-plan] Newest plan predates this planning session:" >&2
  echo "  ${newest_plan}" >&2
  echo "Write the plan for THIS session before approving — the gate stays CLOSED." >&2
  exit 1
fi

# Release the gate.
rm -f "$marker" 2>/dev/null || true

echo "[mentor approve-plan] Plan APPROVED — gate released. Repo edits are now allowed."
echo "  plan: ${newest_plan}"

if [ "$handoff_mode" -eq 1 ]; then
  cat <<EOF

HAND-OFF REQUESTED — plan APPROVED and gate released. Do NOT implement and do NOT
dispatch implementation agents in this session. The approved plan file is:
  ${newest_plan}
Invoke Skill(skill="mentor:handoff") now to write the handoff document so the next
agent can pick up implementation from this plan, then STOP.
EOF
  exit 0
fi

if [ "$(mentor_get_mode "$repo_root")" = "plan-only" ]; then
  cat <<EOF

PLAN-ONLY MODE — gate released, but do NOT implement and do NOT dispatch
implementation agents. The plan file is the deliverable:
  ${newest_plan}
Summarize where it lives and STOP. (Switch with /mentor:mode plan to execute plans.)
EOF
  exit 0
fi

exit 0
