#!/usr/bin/env bash
# approve-plan.sh — validate the plan, release the plan gate.
#
# Run by the plan skill when the user makes an approval choice. Flags map 1:1
# to the approval options — the persisted repo mode is NOT read here; the
# user's explicit choice decides:
#   (no arg)   — approve: validate, release the gate, implementation begins;
#                prints the subagents-first (SDD) execution directive.
#   --deliver  — approve, but the plan file is the DELIVERABLE: prints a
#                DELIVER-ONLY soft-stop directive (no implementation).
#   --handoff  — approve, then hand off: prints a directive to write a
#                /mentor:handoff doc for the next agent and STOP.
#   anything else — usage error, exit 1, marker untouched.
#
# Validation (only while the gate is armed): the newest Markdown plan
# (plans/<slug>/plan.md) must be non-empty AND newer than the `.planning`
# marker (the marker's mtime is the
# session start — begin-plan.sh — so a stale plan from a prior session can
# never release the gate). On failure the marker stays (gate CLOSED), exit 1.
#
# Idempotent-directive rule: when the gate is already open, validation and
# release are skipped, but --deliver/--handoff STILL print their directive —
# a re-run must never silently downgrade a no-implementation instruction.
#
# Plan state (v2.4.0, widened v2.14.0): EVERY approval path — no-arg, --handoff,
# --deliver — promotes this session's plans to `approved` in their .state.json
# sidecars. Approval is approval: the flags only change what happens NEXT
# (implement now / hand off / deliver), not whether the plan was approved. Leaving
# --handoff plans at `draft` made plan-track refuse them in the next session
# ("the gate never released" — but it did). See the promotion block for why the
# candidate set is snapshotted before the marker is deleted.

set -euo pipefail

flag="${1:-}"
case "$flag" in
  ""|--handoff|--deliver) ;;
  *)
    echo "[mentor approve-plan] Unknown flag: ${flag}" >&2
    echo "Usage: approve-plan.sh [--deliver | --handoff]" >&2
    echo "This script takes no plan argument — it releases the gate and promotes every" >&2
    echo "plan newer than the .planning marker. To approve ONE plan by slug, use:" >&2
    echo "  plan-state.sh set <slug> approved --note \"…\"" >&2
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

newest_plan="$(mentor_newest_plan "$plans_dir")"

# Plans written during THIS planning session — snapshotted BEFORE the marker is
# removed, because `[ a -nt b ]` and `find -newer b` are both TRUE when b is gone:
# asking "newer than the marker" after the release would match every plan dir in the
# repo, including months-old ones. Empty on the gate-already-open branch, which is
# correct — nothing was planned in this session, so nothing gets promoted.
newly_planned=""

if [ -f "$marker" ]; then
  if [ -z "$newest_plan" ] || [ ! -s "$newest_plan" ]; then
    echo "[mentor approve-plan] No Markdown plan found in ${plans_dir}." >&2
    echo "Write the plan (<slug>/plan.md) before approving — the gate stays CLOSED." >&2
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

  newly_planned="$(find "$plans_dir" -mindepth 2 -maxdepth 2 -name plan.md -newer "$marker" 2>/dev/null || true)"

  # Release the gate.
  rm -f "$marker" 2>/dev/null || true
  echo "[mentor approve-plan] Plan APPROVED — gate released. Repo edits are now allowed."
  echo "  plan: ${newest_plan}"
else
  # Idempotency: gate already open (already approved, or never armed). Skip
  # validation/release but still honor the flag directive below.
  echo "[mentor approve-plan] Gate is already open — nothing to release."
  echo "  (No approval this session? An 8h-stale marker may have self-released — plan-gate prints a notice when that happens.)"
  [ -n "$newest_plan" ] && echo "  plan: ${newest_plan}"
fi

# Promote plan state on EVERY approval path — this must run before the --handoff/
# --deliver early exits. `approved` records the user's decision; whether
# implementation happens now, next session (handoff), or never (deliver) is the
# directives' business. plan-track trusts this state: a stored `draft` reads as
# "the gate never released", so skipping promotion here falsely blocks the plan
# in the very next session.
#
# Only plans from $newly_planned are candidates (see the snapshot above), and only
# those whose effective state is `draft` or `unknown` — never `superseded` (a split
# parent's plan.md is also newer than the marker and would otherwise flip back),
# `implemented`, `failed` or `in_progress`. `unknown` is included because a plan
# written this session predates nothing: it just means Step 4 never ran `init`, and
# the approval should still land rather than depend on the model remembering.
#
# Fail-soft throughout: every helper here exits 0, so a state-write problem can never
# turn a successful gate release into an error.
#
# Report the outcome on EVERY path, including both "nothing to do" paths. Silence is
# ambiguous: it reads identically to the promotion block never running at all (a stale
# cached plugin predating it), which is exactly how a plan left at `draft` after a
# successful-looking approval went unnoticed until the next session refused to build it.
# One `state:` line always prints, before the --handoff/--deliver early exits below.
if [ -n "$newly_planned" ]; then
  promoted=""; candidates=0
  while IFS= read -r plan_path; do
    [ -n "$plan_path" ] || continue
    candidates=$((candidates + 1))
    plan_dir="$(dirname "$plan_path")"
    case "$(mentor_plan_effective_state "$plan_dir")" in
      draft|unknown) ;;
      *) continue ;;
    esac
    mentor_plan_state_write "$plan_dir" approved "" "" ""
    promoted="${promoted}$(basename "$plan_dir") "
  done <<<"$newly_planned"
  if [ -n "$promoted" ]; then
    echo "  state: approved — ${promoted% }"
  else
    echo "  state: unchanged — nothing needed promoting (${candidates} candidate(s), none in draft/unknown)"
  fi
else
  echo "  state: unchanged — no plans written this session, nothing to promote"
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

# Restate the SDD directive here — informational only, no enforcement — because this
# is the exact moment the model resumes after the Bash call (printed on re-runs too,
# mirroring the idempotent-directive rule for the flags above).
cat <<EOF

Implementation is subagents-first (SDD) — execute the plan's dispatch
annotations per Skill(skill="mentor:dispatch-agents"); implement directly in
the main thread only if the plan states "Dispatch: skipped".
EOF

exit 0
