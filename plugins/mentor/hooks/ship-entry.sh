#!/usr/bin/env bash
# UserPromptSubmit
#
# When the user types /ship inside a mentor-managed worktree, inline
# the mentor-ship SKILL.md body so Claude follows the worktree-aware
# ship flow instead of the global /ship.
#
# No-op (exit 0 silently) when:
#   - prompt does not contain a /ship token
#   - cwd is not inside a mentor worktree (no state file)

set -euo pipefail

input=$(cat)
prompt=$(echo "$input" | jq -r '.prompt // ""')
cwd=$(echo "$input" | jq -r '.cwd // empty')
[ -z "$cwd" ] && cwd="$PWD"

# 1. Match /ship as a token. Bash \b is unreliable around `/` — use explicit boundaries.
#    Matches: "/ship", " /ship ", "/ship\n". Does NOT match: "/shipper", "/ship-foo".
if ! echo "$prompt" | grep -qE '(^|[[:space:]])/ship([[:space:]]|$)'; then
  exit 0
fi

# /ship is a main-thread, repo-mutating flow (merge / conflict edits / push). Set the
# shared mentor-flow-active marker so orchestrator-gate.sh defers for this turn (and the
# ~60min freshness window covers the multi-turn ship dialogue). Belt-and-suspenders with
# orchestrator-prompt.sh, which also sets it; harmless when orchestrator mode is off.
sid=$(echo "$input" | jq -r '.session_id // .sessionId // "default"' 2>/dev/null || echo default)
[ -z "$sid" ] && sid="default"
touch "/tmp/mentor-flow-active-${sid}" 2>/dev/null || true

# 2. Locate this checkout's git dir. From inside a linked worktree, this
#    resolves directly to .git/worktrees/<name> — robust against
#    `git worktree move` and slug-sanitization (no basename guessing).
git_dir="$(git -C "$cwd" rev-parse --git-dir 2>/dev/null || true)"
[ -z "$git_dir" ] && exit 0

# rev-parse --git-dir may return a path relative to $cwd; make absolute.
if [[ "$git_dir" != /* ]]; then
  git_dir="$(cd "$cwd" 2>/dev/null && cd "$git_dir" 2>/dev/null && pwd)" || exit 0
fi

state_file="${git_dir}/mentor.json"
[ -f "$state_file" ] || exit 0

# 3. Inline the ship skill body so Claude executes it immediately.
SKILL_FILE="$(dirname "$0")/../skills/mentor-ship/SKILL.md"
[ -f "$SKILL_FILE" ] || exit 0

cat <<'HEADER'
[mentor] /ship detected inside a managed worktree — ship instructions auto-loaded.

EXECUTE THE FOLLOWING IMMEDIATELY instead of the global /ship. This flow uses the source branch captured at worktree allocation time (read from the per-worktree state file) and runs simplify → catch source up into the worktree → optional tests → user-chosen ship target → cleanup. It NEVER merges worktree commits into the remote source branch directly: the user always chooses between remote:worktree (push the feature branch to its own remote + offer a PR; default) and local:source (fast-forward into the LOCAL source, with a separate explicit confirmation before any push to the remote source). The worktree is only torn down after the user confirms.

────────────────────────────────────────────────────────────────────────────────
HEADER

# Emit SKILL.md body — strip YAML frontmatter (skip up to and including closing ---)
awk 'BEGIN{f=0} /^---/{f++; if(f==2){f=3; next}} f>=3{print}' "$SKILL_FILE"
