#!/usr/bin/env bash
# plan-gate.sh — PreToolUse:Write|Edit|MultiEdit|NotebookEdit
#
# The single fail-closed edit gate of the mentor plan harness. It keys off a
# repo-scoped `.planning` MARKER (armed by begin-plan.sh, released by
# approve-plan.sh), so it holds even under bypassPermissions: PreToolUse hooks
# deny independently of permission mode.
#
# While the marker is present, ALLOW targets OUTSIDE the repo working tree AND mentor's
# own in-repo state dir (<repo>/.mentor/ — where the plan file now lives). Any OTHER
# in-repo target — or an unresolvable/absent path — is DENIED. FAIL-CLOSED.
#
# Bash is NOT matched: the gate covers Claude's near-universal edit path
# (Write/Edit/MultiEdit/NotebookEdit); the skill instructs against repo-mutating
# shell commands during planning but does not enforce it.
#
# Staleness: a marker older than 8h is treated as released (a crashed planning
# session must never permanently lock out editing) — the marker is removed and
# the call allowed. Checked ONLY for writes the gate would otherwise DENY: a
# gate-exempt .mentor/ write (an ordinary plan.md revision hours into a live
# session) must never silently release the gate as a side effect. When the
# self-heal fires it prints a stdout notice — a silent release is later
# indistinguishable from an approval.
#
# Independently of the marker, a direct write to a plan's `.state.json` sidecar is always
# denied — plan-state.sh is its only writer. That check runs before the marker check
# because sidecars are edited mostly at close-out, when the gate is already released.
#
# No marker → exit 0 (not planning). Cannot resolve the repo/marker → exit 0
# (nothing to protect). Exit 2 = block (stderr shown to the agent).

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

CWD="$(mentor_cwd "$INPUT")"
CURRENT_SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || true

# --- resolve the repo-scoped plans dir + marker ---
repo_root_common="$(mentor_repo_root "$CWD")"
[ -z "$repo_root_common" ] && exit 0
plans_dir="$(mentor_plans_dir "$repo_root_common")"
marker="${plans_dir}/.planning"

# Canonicalize without requiring the path to exist (new-file writes are the common
# case). macOS BSD `realpath` lacks -m and fails on non-existent paths, so fall back
# to python's os.path.realpath (resolves the existing prefix). A relative path is
# resolved against the TOOL's cwd, not the hook process's — they are not the same.
_canon() {
  local p="${1/#\~/$HOME}"     # expand leading ~ to $HOME before realpath
  case "$p" in /*) ;; *) p="${CWD%/}/$p" ;; esac
  realpath -m -- "$p" 2>/dev/null && return 0
  realpath -- "$p" 2>/dev/null && return 0
  python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null && return 0
  echo "$p"
}

FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)" || true
FILE_CANON=""
[ -n "$FILE_PATH" ] && FILE_CANON="$(_canon "$FILE_PATH")"

# --- single-writer guard for plan sidecars ---
# `.state.json` is written ONLY by plan-state.sh, which validates the state, preserves
# the note, and writes atomically. A hand-rolled Write skips all three and drifts as the
# schema evolves. This arm sits ABOVE the marker check on purpose: the sidecar is edited
# most often at close-out, long after the gate released, which is precisely when the
# skill line carrying this rule isn't loaded and nothing else would catch it. Match the
# CANONICAL path — a raw-string match is slipped by `./.mentor/…`, a `..` segment, or a
# symlinked prefix, and this is a Write, so a slipped guard lands.
case "$FILE_CANON" in
  */.mentor/plans/*/.state.json)
    slug="$(basename "$(dirname "$FILE_CANON")")"
    cat >&2 <<EOF
[mentor plan-gate] Refusing a direct write to a plan sidecar: ${FILE_PATH}

plan-state.sh is the only writer of .state.json — it validates the state, keeps the
note, and writes atomically. Use it instead:

  plan-state.sh set ${slug} <draft|approved|in_progress|implemented|failed|superseded> --note "…"
EOF
    exit 2
    ;;
esac

# No marker → not planning → allow.
[ -f "$marker" ] || exit 0

# The working-tree root to protect (writes anywhere inside it are denied while planning).
REPO_WT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$REPO_WT" ] && REPO_WT="$repo_root_common"

REPO_CANON="$(_canon "$REPO_WT")"

if [ -n "$FILE_CANON" ]; then
  case "$FILE_CANON" in
    "${REPO_CANON}/.mentor"|"${REPO_CANON}/.mentor/"*) exit 0 ;;  # mentor's own state (plan file, markers) → always allow, staleness never evaluated
    "$REPO_CANON"|"${REPO_CANON}/"*) ;;   # else inside repo → deny (fall through)
    *) exit 0 ;;                          # outside repo (/tmp, …) → allow
  esac
fi

# Stale marker (>8h, MENTOR_PLAN_MARKER_STALE_MIN) → treat as released; self-heal and
# allow. Reached only for writes the gate would otherwise deny (exempt paths exited
# above), so an ordinary .mentor/ write can never disarm the gate as a side effect.
if mentor_marker_stale "$marker"; then
  rm -f "$marker" 2>/dev/null || true
  echo "[mentor] Stale planning marker (>8h) released — the plan gate is no longer armed. If planning is still active, re-arm it by re-running /mentor:plan (begin-plan.sh)."
  exit 0
fi

# empty path (unresolvable) OR inside-repo → deny (fail-closed).
# Attribution: the alternative is a blocked agent hand-rolling ls/find-newer forensics
# to tell "fresh, someone else's live session" from "abandoned, safe to ask the user to
# clear" apart. mentor_marker_stale already returned false above, so age_min here is
# always < MENTOR_PLAN_MARKER_STALE_MIN.
owner_session="$(mentor_marker_field "$marker" session)"
owner_line=""
if [ -n "$owner_session" ]; then
  owner_cwd="$(mentor_marker_field "$marker" cwd)"
  owner_line="
  Armed by: session ${owner_session} at ${owner_cwd:-<unknown cwd>}"
fi
age_min="$(mentor_marker_age_min "$marker")"
age_line=""
[ -n "$age_min" ] && age_line="
  Age: ~${age_min}m ago (auto-releases after $(( MENTOR_PLAN_MARKER_STALE_MIN / 60 ))h if abandoned)."

cat >&2 << EOF
BLOCKED by mentor: PLAN PHASE is active — approve the plan first.

  ${FILE_PATH:-<no path>}${owner_line}${age_line}

The .planning marker blocks edits to any file in the repo working tree until the
plan is approved through the plan skill (approve-plan.sh validates the plan,
then releases the gate). This holds even under bypassPermissions. This marker is
shared across every linked git worktree of this repo, so a foreign session above
may be a sibling worktree rather than a stray.
EOF

if [ -n "$owner_session" ] && [ -n "$CURRENT_SESSION" ] && [ "$owner_session" != "$CURRENT_SESSION" ]; then
  cat >&2 << EOF

Do not delete ${marker} yourself, and do not run approve-plan.sh to "clear" it —
approve-plan.sh takes no slug and promotes whatever plan is newest, which may not
be yours. Ask the user to confirm before touching it.
EOF
else
  cat >&2 << EOF

During planning the ONLY file you write is the persisted Markdown plan under
  ${plans_dir}/<slug>/plan.md
(inside the gate-exempt .mentor/ tree — always allowed). Finish the plan, choose
"Proceed" (which runs approve-plan.sh), and edit/implement only AFTER approval.
EOF
fi
exit 2
