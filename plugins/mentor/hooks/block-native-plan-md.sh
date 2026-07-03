#!/usr/bin/env bash
# PreToolUse hook for Write|Edit — blocks the harness-native plan file.
#
# mentor persists the plan as ONE file under
#   $HOME/.claude/mentor/<repo-base>-<hash>/plans/<slug>.{html,md}
# (per the repo's configured output format; mentor-plan SKILL Step 6b). That file is the
# single source of truth — NOT the harness-native ~/.claude/plans/<name>.md.
#
# Claude Code's built-in plan workflow ALSO tells the agent to write a native
# plan file at $HOME/.claude/plans/<name>.md ("the only file you are allowed to
# edit"). Left unchecked, the agent writes both — a duplicate that drifts and
# accumulates. This hook rejects any Write/Edit whose target lands in the native
# plans dir, redirecting the agent to the HTML deliverable instead.
#
# Scope: ONLY $HOME/.claude/plans/*.md — never the mentor/plans HTML
# dir, never anything else. Downstream hooks (strategy-guard, dispatch-executor)
# already fall back to the newest *.html when plan_path is missing, so blocking
# the native .md does not break plan validation or dispatch.
#
# GATED on an active plan flow (v0.38.3): block ONLY when this session is actually
# planning — either Claude Code NATIVE plan mode (permission_mode == "plan"; this
# hook is the sole guard for the native .md there — see block-edits-in-plan-mode.sh)
# OR mentor's OWNED flow (a fresh repo-scoped .planning marker). With neither, the
# native .md belongs to someone else (native plan mode in an unrelated repo, a
# sibling skill) — allow it. An unconditional block over-reached and broke both.
#
# Exit 2 = block the tool call (Claude Code shows stderr to the agent).
# Exit 0 = allow. Fail-open: any parse error → exit 0 so real work is never blocked.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT=""
INPUT=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

TOOL_NAME=""
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
[[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]] || exit 0

FILE_PATH=""
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || exit 0
[[ -n "$FILE_PATH" ]] || exit 0

# Canonicalize without requiring the file to exist (it may not yet).
FILE_CANON=""
FILE_CANON=$(realpath -m -- "$FILE_PATH" 2>/dev/null || realpath -- "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# The harness-native plan dir. Resolve symlinks on $HOME so the prefix matches
# whatever realpath produced above.
HOME_CANON=$(realpath -m -- "$HOME" 2>/dev/null || echo "$HOME")
NATIVE_DIR="${HOME_CANON}/.claude/plans"

# Block ONLY *.md files directly under the native plans dir. Path filter FIRST so
# the 99% of writes that are not the native plan file exit before any git/state work.
case "$FILE_CANON" in
  "${NATIVE_DIR}/"*.md) ;;
  *) exit 0 ;;
esac

# A native ~/.claude/plans/*.md reached here. Block it ONLY when a plan flow is
# active; otherwise it belongs to native plan mode in an unrelated repo or another
# skill, and blocking would over-reach. Signal (a): native plan mode.
PERM_MODE=""
PERM_MODE=$(printf '%s' "$INPUT" | jq -r '.permission_mode // ""' 2>/dev/null || true)
if [[ "$PERM_MODE" != "plan" ]]; then
  # Not native plan mode — signal (b): mentor's OWNED flow (fresh repo-scoped .planning).
  CWD=""
  CWD=$(mentor_cwd "$INPUT")
  REPO_ROOT=""
  REPO_ROOT=$(mentor_repo_root "$CWD")
  [[ -z "$REPO_ROOT" ]] && exit 0
  PLANS_DIR=""
  PLANS_DIR=$(mentor_plans_dir "$REPO_ROOT")
  [[ -z "$PLANS_DIR" ]] && exit 0
  mentor_marker_fresh "${PLANS_DIR}/.planning" || exit 0   # no active plan flow → allow
fi

cat >&2 << EOF
BLOCKED by mentor: do not write the harness-native plan file.

  ${FILE_PATH}

mentor persists the plan in its OWN dir (outside the repo), NOT in the harness-native
~/.claude/plans/*.md. Writing the native file only creates a duplicate that drifts.

Write the mentor plan deliverable instead (mentor-plan SKILL Step 6b), in this repo's
configured output format (/mentor:plan-output-format — html or md):

  \$HOME/.claude/mentor/<repo-base>-<hash>/plans/<slug>.html   (format: html)
  \$HOME/.claude/mentor/<repo-base>-<hash>/plans/<slug>.md     (format: md)

For html, embed the canonical plan (footer markers + any dispatch annotations) in a
<script type="text/markdown" id="plan-source"> block. For md, the .md file IS its own
canonical source (bare footer markers at EOF). The plan-open.sh hook opens it on Write;
strategy-guard.sh reads it on ExitPlanMode. Do NOT retry this native .md.
EOF
exit 2
