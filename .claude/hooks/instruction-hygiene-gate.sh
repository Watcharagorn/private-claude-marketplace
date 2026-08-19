#!/usr/bin/env bash
# instruction-hygiene-gate.sh — PreToolUse (Bash|Skill)
#
# Reminds (never blocks) when a session is about to commit, push, or run a
# publish/ship flow over this repo's instruction surface without the
# instruction-hygiene pass having run yet this session.
#
# Why a hook and not just the CLAUDE.md rule: the rule is read at session start
# and the commit happens hundreds of tool calls later, by which point a
# text-only gate has fallen out of attention — the sibling skill-creator gate
# exists for exactly that reason, after a real session edited 14 SKILL.md files
# without its mandatory skill. This fires at the moment of risk instead.
#
# Two trigger surfaces, because "before ship/publish" has two doors:
#   Bash  — a `git commit` / `git push` whose pending change touches
#           plugins/**, .claude/**, or CLAUDE.md
#   Skill — publish-plugin / mentor's ship, i.e. a release flow starting
#
# Warn-only: always exit 0, stdout only. Never stderr or exit 2 — those block,
# and this must not, because the CLAUDE.md gate exempts pure version bumps and
# typo-only fixes and this hook cannot tell those from a real change.
#
# Silenced for the session once skill-invoked-mark.sh (PostToolUse on Skill)
# sees the instruction-hygiene skill actually get invoked.
#
# Fail-soft: no jq / unparsable input / not a git repo → exit 0.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat)" || exit 0

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null)" || SESSION_ID="nosession"
marker="/tmp/claude-instruction-hygiene-gate-${SESSION_ID}"
[ -e "$marker" ] && exit 0

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
trigger=""

case "$TOOL_NAME" in
  Skill)
    SKILL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // ""' 2>/dev/null)" || exit 0
    case "$SKILL_NAME" in
      *publish-plugin*|*shipping*|*ship) trigger="release flow ($SKILL_NAME)" ;;
      *) exit 0 ;;
    esac
    ;;
  Bash)
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
    # `git commit` / `git push`, with or without leading flags or -C <dir>.
    printf '%s' "$CMD" | grep -Eq \
      '(^|[^[:alnum:]_.-])git([[:space:]]+(-[^[:space:]]+|-C[[:space:]]+[^[:space:]]+))*[[:space:]]+(commit|push)([^[:alnum:]_-]|$)' \
      || exit 0

    dir="${CLAUDE_PROJECT_DIR:-.}"
    git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

    # Pending change = worktree + index + anything committed ahead of upstream.
    # A push often carries only the third; a commit only the first two.
    paths="$( { git -C "$dir" status --porcelain 2>/dev/null | awk '{print $NF}'
                git -C "$dir" diff --name-only '@{u}...HEAD' 2>/dev/null; } || true )"
    printf '%s\n' "$paths" | grep -Eq '^(plugins/|\.claude/|CLAUDE\.md$)' || exit 0
    # Name the verb without a pipeline whose exit status could trip set -e:
    # under pipefail an early-closing `head` makes the substitution fail, which
    # would abort the hook before it ever printed the reminder.
    verb="commit/push"
    if printf '%s' "$CMD" | grep -Eq '[[:space:]]push([^[:alnum:]_-]|$)'; then verb="push"; fi
    if printf '%s' "$CMD" | grep -Eq '[[:space:]]commit([^[:alnum:]_-]|$)'; then verb="commit"; fi
    trigger="git $verb touching instruction files"
    ;;
  *) exit 0 ;;
esac

cat <<MSG
[instruction-hygiene] About to run ${trigger} without the instruction-hygiene pass this session.
This repo's CLAUDE.md requires it before every commit/ship/publish that touches plugins/**,
.claude/**, or CLAUDE.md: a change leaves stale references, duplicated rules, contradictions and
run-time-only narrative behind in the files it did NOT touch, and nothing else here reads the
corpus as a whole. Run /prune-instructions [plugin] (then /verify-plugin-edits <plugin>) before
committing. If this is a pure version bump or a typo-only fix, that exception applies — proceed.
MSG
exit 0
