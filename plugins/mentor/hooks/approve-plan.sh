#!/usr/bin/env bash
# approve-plan.sh — validate the plan, release the plan gate.
#
# Run by the plan skill when the user makes an approval choice. Flags map 1:1
# to the approval options — the persisted repo mode is NOT read here; the
# user's explicit choice decides:
#   (no arg)   — approve: validate, release the gate, implementation begins.
#   --deliver  — approve, but the plan file is the DELIVERABLE: prints a
#                DELIVER-ONLY soft-stop directive (no implementation).
#   --handoff  — approve, then hand off: prints a directive to write a
#                /mentor:handoff doc for the next agent and STOP.
#   anything else — usage error, exit 1, marker untouched.
#
# Validation (only while the gate is armed): the newest Markdown plan must be
# non-empty AND newer than the `.planning` marker (the marker's mtime is the
# session start — begin-plan.sh — so a stale plan from a prior session can
# never release the gate). On failure the marker stays (gate CLOSED), exit 1.
#
# Idempotent-directive rule: when the gate is already open, validation and
# release are skipped, but --deliver/--handoff STILL print their directive —
# a re-run must never silently downgrade a no-implementation instruction.

set -euo pipefail

flag="${1:-}"
case "$flag" in
  ""|--handoff|--deliver) ;;
  *)
    echo "[mentor approve-plan] Unknown flag: ${flag}" >&2
    echo "Usage: approve-plan.sh [--deliver | --handoff]" >&2
    exit 1
    ;;
esac

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

if [ -f "$marker" ]; then
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
else
  # Idempotency: gate already open (already approved, or never armed). Skip
  # validation/release but still honor the flag directive below.
  echo "[mentor approve-plan] Gate is already open — nothing to release."
  [ -n "$newest_plan" ] && echo "  plan: ${newest_plan}"
fi

if [ "$flag" = "--handoff" ]; then
  cat <<EOF

HAND-OFF REQUESTED — plan APPROVED and gate released. Do NOT implement and do NOT
dispatch implementation agents in this session. The approved plan file is:
  ${newest_plan:-(no plan file on record)}
Invoke Skill(skill="mentor:handoff") now to write the handoff document so the next
agent can pick up implementation from this plan, then STOP.
EOF
  exit 0
fi

if [ "$flag" = "--deliver" ]; then
  cat <<EOF

DELIVER-ONLY — plan APPROVED and gate released. The plan file is the deliverable:
  ${newest_plan:-(no plan file on record)}
Do NOT implement and do NOT dispatch implementation agents in this session.
Report where the plan lives and STOP. (The user can run /mentor:handoff to brief
a fresh agent, or ask to proceed later — the gate is already open.)
EOF
  exit 0
fi

exit 0
