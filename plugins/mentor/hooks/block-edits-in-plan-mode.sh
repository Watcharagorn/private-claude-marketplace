#!/usr/bin/env bash
# PreToolUse:Write|Edit — block source edits while in plan mode.
#
# mentor's plan flow ends with the NATIVE ExitPlanMode approval. Until the
# user approves, NO source file in the repo/worktree may be edited — not by the main
# agent and not by a dispatched subagent (which inherits the parent's plan mode).
# Editing source before approval is "developing during plan mode"; this hook makes
# the approval an unbypassable gate.
#
# Allowed even in plan mode: anything OUTSIDE the repo working tree — in particular the
# plan file under ~/.claude/mentor/<repo>-<hash>/plans/ (the only artifact the plan
# flow writes during planning). The native ~/.claude/plans/*.md stays handled by
# block-native-plan-md.sh.
#
# Exit 2 = block (stderr shown to the agent). Exit 0 = allow.
# Fail-open: any parse/resolution error -> exit 0 so real work is never blocked.

set -euo pipefail

INPUT=""
INPUT=$(cat) || exit 0

TOOL_NAME=""
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
[[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]] || exit 0

# Only gate while in plan mode. PreToolUse stdin carries permission_mode.
PERM_MODE=""
PERM_MODE=$(printf '%s' "$INPUT" | jq -r '.permission_mode // ""' 2>/dev/null) || exit 0
[[ "$PERM_MODE" == "plan" ]] || exit 0

FILE_PATH=""
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || exit 0
[[ -n "$FILE_PATH" ]] || exit 0

CWD=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || true
[[ -z "$CWD" ]] && CWD="$PWD"

# Resolve the repo working-tree root. No repo -> nothing to protect -> allow.
REPO_ROOT=""
REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
[[ -z "$REPO_ROOT" ]] && exit 0

_canon() { realpath -m -- "$1" 2>/dev/null || realpath -- "$1" 2>/dev/null || echo "$1"; }
FILE_CANON=$(_canon "$FILE_PATH")
REPO_CANON=$(_canon "$REPO_ROOT")

# Allow writes OUTSIDE the repo (e.g. the plan file under ~/.claude/mentor/<repo>-<hash>/plans).
case "$FILE_CANON" in
  "$REPO_CANON"|"${REPO_CANON}/"*) ;;   # inside repo -> gated below
  *) exit 0 ;;                          # outside repo -> allow
esac

cat >&2 << EOF
BLOCKED by mentor: you are in PLAN MODE — approve the plan first.

  ${FILE_PATH}

No source file in the repo may be edited until you call ExitPlanMode and the user
APPROVES the plan. (Dispatched subagents inherit plan mode, so this applies to them
too.) During planning, the only file you should write is the persisted plan (a styled .html
or a Mermaid-first .md, per /mentor:plan-output-format) under
  ~/.claude/mentor/<repo>-<hash>/plans/<slug>.{html|md}
which lives outside the repo and is always allowed.

Finish the plan, call ExitPlanMode, and edit/implement only AFTER approval.
EOF
exit 2
