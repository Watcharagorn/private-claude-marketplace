#!/usr/bin/env bash
# bypass-context.sh — user-approved session bypass for the mentor context gate.
#
# Run by the model (via Bash) after the user answers "Proceed anyway (bypass for
# this session)" to the gate's ASK question. Writes a `.context-bypass-<session_id>`
# marker in the state dir; context-gate.sh and begin-plan.sh then degrade their ASK
# tier to a one-line advisory for the rest of the session. A fresh session gets a
# new id, so the gate re-arms itself automatically.
#
# Stale markers (>24h) are pruned, mirroring the `.context-warned-*` idiom.
# Fail-soft: never exits non-zero, never bricks a session.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

repo_root="$(mentor_repo_root "$PWD")"
state_dir="$(mentor_state_dir "$repo_root")"
[ -z "$state_dir" ] && state_dir="${HOME}/.claude/mentor/_no-repo"

mkdir -p -m 700 "$state_dir" 2>/dev/null || true
[ -n "$repo_root" ] && mentor_ensure_gitignore "$state_dir"
find "$state_dir" -maxdepth 1 -name '.context-bypass-*' -mmin +1440 -delete 2>/dev/null || true
: > "${state_dir}/.context-bypass-${CLAUDE_CODE_SESSION_ID:-nosession}" 2>/dev/null || true

echo "[mentor] Context gate bypassed for this session — warnings continue; a fresh session re-arms the gate."
exit 0
