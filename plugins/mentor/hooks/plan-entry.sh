#!/usr/bin/env bash
# PostToolUse:EnterPlanMode
#
# Auto-loads the mentor-plan skill by inlining its instructions
# directly into the hook response. Claude receives the full strategy
# instructions immediately — no explicit Skill() call required.

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // ""')
[ "$tool_name" != "EnterPlanMode" ] && exit 0

SKILL_FILE="$(dirname "$0")/../skills/mentor-plan/SKILL.md"

# Set session flag so UserPromptSubmit hook skips injection on the next prompt
session_id=$(echo "$input" | jq -r '.session_id // .sessionId // "default"')
touch "/tmp/mentor-plan-loaded-${session_id}" 2>/dev/null || true

cat <<'HEADER'
[mentor] Plan mode active — strategy instructions auto-loaded.

EXECUTE THE FOLLOWING IMMEDIATELY. Do not ask anything or begin planning until
the strategy question below has been answered by the user.

────────────────────────────────────────────────────────────────────────────────
HEADER

# Emit SKILL.md body — strip YAML frontmatter (skip up to and including closing ---)
awk 'BEGIN{f=0} /^---/{f++; if(f==2){f=3; next}} f>=3{print}' "$SKILL_FILE"
