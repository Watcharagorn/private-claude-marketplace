#!/usr/bin/env bash
# Regression tests for instruction-hygiene-gate.sh + skill-invoked-mark.sh —
# the warn-only gate that reminds a session to run the instruction-hygiene pass
# before it commits, pushes, or starts a release flow over instruction files,
# and the generic marker that silences it once the skill has run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
for dep in "$HOOKS/instruction-hygiene-gate.sh" "$HOOKS/skill-invoked-mark.sh"; do
  [ -f "$dep" ] || { echo "FATAL: $dep not found"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required (the hooks need it)"; exit 1; }

ROOT="$(mktemp -d)"
SCRATCH="$ROOT/repo"
SID="ihtest-$$"                    # gate sessions: never marked
SID_MARKED="ihtest-marked-$$"      # gate session with a marker present
SID_MARK="ihtest-mark-$$"          # marker-script sessions
MARKED="/tmp/claude-instruction-hygiene-gate-${SID_MARKED}"
trap 'rm -rf "$ROOT"; rm -f "$MARKED" "/tmp/claude-instruction-hygiene-gate-${SID_MARK}" \
      "/tmp/claude-skill-creator-gate-${SID_MARK}" "/tmp/claude-instruction-hygiene-gate-${SID}"' EXIT

# Scratch repo — never run the hook against the working repo.
mkdir -p "$SCRATCH/plugins/demo/skills/x"
git init -q -b develop "$SCRATCH"
git -C "$SCRATCH" config user.email t@t.t
git -C "$SCRATCH" config user.name t
printf 'rule\n' > "$SCRATCH/plugins/demo/skills/x/SKILL.md"
printf 'note\n' > "$SCRATCH/notes.txt"
printf 'repo rules\n' > "$SCRATCH/CLAUDE.md"
git -C "$SCRATCH" add -A >/dev/null 2>&1
git -C "$SCRATCH" commit -qm init >/dev/null 2>&1

PASS=0; FAIL=0
chk() {  # chk <description> <command...>
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   — $desc"
  else FAIL=$((FAIL+1)); echo "FAIL — $desc"; fi
}

reset_tree() { git -C "$SCRATCH" reset --hard -q; git -C "$SCRATCH" clean -fdq; }
json_bash()  { printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2"; }
json_skill() { printf '{"session_id":"%s","tool_name":"Skill","tool_input":{"skill":"%s"}}' "$1" "$2"; }
gate()       { printf '%s' "$1" | CLAUDE_PROJECT_DIR="$SCRATCH" bash "$HOOKS/instruction-hygiene-gate.sh" 2>/dev/null; }
nags()       { gate "$1" | grep -q 'instruction-hygiene'; }
silent()     { [ -z "$(gate "$1")" ]; }
exits_zero() { printf '%s' "$1" | CLAUDE_PROJECT_DIR="$SCRATCH" bash "$HOOKS/instruction-hygiene-gate.sh" >/dev/null 2>&1; }

echo "== A. release-flow Skill calls =="
chk "publish-plugin nags"                 nags   "$(json_skill "$SID" publish-plugin)"
chk "namespaced loom:publish-plugin nags" nags   "$(json_skill "$SID" loom:publish-plugin)"
chk "mentor:shipping nags"                nags   "$(json_skill "$SID" mentor:shipping)"
chk "mentor:ship nags"                    nags   "$(json_skill "$SID" mentor:ship)"
chk "unrelated skill is silent"           silent "$(json_skill "$SID" mentor:planning)"
chk "instruction-hygiene itself silent"   silent "$(json_skill "$SID" instruction-hygiene)"

echo "== B. marker silences the gate for the session =="
: > "$MARKED"
chk "marked session: publish-plugin silent" silent "$(json_skill "$SID_MARKED" publish-plugin)"
rm -f "$MARKED"
chk "unmarked again: publish-plugin nags"   nags   "$(json_skill "$SID_MARKED" publish-plugin)"

echo "== C. git commit/push over instruction files =="
reset_tree; printf 'more\n' >> "$SCRATCH/plugins/demo/skills/x/SKILL.md"
chk "dirty plugin skill + git commit nags"  nags "$(json_bash "$SID" 'git commit -m wip')"
chk "dirty plugin skill + git push nags"    nags "$(json_bash "$SID" 'git push origin HEAD')"
chk "git -C form nags"                      nags "$(json_bash "$SID" 'git -C . commit -m wip')"
chk "compound command nags"                 nags "$(json_bash "$SID" 'git add plugins/demo/ && git commit -m wip')"
reset_tree; mkdir -p "$SCRATCH/plugins/demo/commands"; printf 'x\n' > "$SCRATCH/plugins/demo/commands/new.md"
chk "untracked plugin file counts"          nags "$(json_bash "$SID" 'git commit -m wip')"
reset_tree; printf 'x\n' >> "$SCRATCH/CLAUDE.md"
chk "dirty root CLAUDE.md counts"           nags "$(json_bash "$SID" 'git commit -m wip')"

echo "== D. commits that are none of its business =="
reset_tree
chk "clean tree is silent"                     silent "$(json_bash "$SID" 'git commit -m wip')"
printf 'x\n' >> "$SCRATCH/notes.txt"
chk "non-instruction change is silent"         silent "$(json_bash "$SID" 'git commit -m wip')"
reset_tree; printf 'more\n' >> "$SCRATCH/plugins/demo/skills/x/SKILL.md"
chk "git log --grep=commit is not a commit"    silent "$(json_bash "$SID" 'git log --grep=commit')"
chk "git status is silent"                     silent "$(json_bash "$SID" 'git status --porcelain')"
chk "unrelated bash is silent"                 silent "$(json_bash "$SID" 'ls plugins')"
chk "Read tool is silent"                      silent '{"session_id":"x","tool_name":"Read","tool_input":{"file_path":"CLAUDE.md"}}'

echo "== E. fail-soft, always exit 0 =="
chk "nagging run still exits 0"      exits_zero "$(json_bash "$SID" 'git commit -m wip')"
chk "empty stdin exits 0"            exits_zero ''
chk "empty stdin prints nothing"     silent     ''
chk "garbage stdin exits 0"          exits_zero 'not json at all'
chk "missing tool_input exits 0"     exits_zero '{"session_id":"x","tool_name":"Bash"}'
# $ROOT itself is not a git repo (only $ROOT/repo is) — the hook must not nag
# about a repo it cannot even see.
outside_repo_silent() {
  local out
  out="$(printf '%s' "$(json_bash outside 'git commit -m wip')" \
        | CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOKS/instruction-hygiene-gate.sh" 2>/dev/null)"
  [ -z "$out" ]
}
chk "outside a git repo is silent"   outside_repo_silent

echo "== F. skill-invoked-mark.sh writes the marker the gate reads =="
mark() { printf '%s' "$1" | bash "$HOOKS/skill-invoked-mark.sh" "$2" "$3" >/dev/null 2>&1; }
rm -f "/tmp/claude-instruction-hygiene-gate-${SID_MARK}" "/tmp/claude-skill-creator-gate-${SID_MARK}"
mark "$(json_skill "$SID_MARK" instruction-hygiene)" instruction-hygiene instruction-hygiene-gate
chk "hygiene skill invocation writes its marker" test -e "/tmp/claude-instruction-hygiene-gate-${SID_MARK}"
mark "$(json_skill "$SID_MARK" skill-creator:skill-creator)" skill-creator skill-creator-gate
chk "namespaced skill-creator writes its marker" test -e "/tmp/claude-skill-creator-gate-${SID_MARK}"
rm -f "/tmp/claude-instruction-hygiene-gate-${SID}"
mark "$(json_skill "$SID" mentor:planning)" instruction-hygiene instruction-hygiene-gate
chk "another skill writes no marker"   bash -c '[ ! -e "/tmp/claude-instruction-hygiene-gate-'"$SID"'" ]'
mark '{"session_id":"'"$SID"'","tool_name":"Bash","tool_input":{"command":"ls"}}' instruction-hygiene instruction-hygiene-gate
chk "non-Skill tool writes no marker"  bash -c '[ ! -e "/tmp/claude-instruction-hygiene-gate-'"$SID"'" ]'
mark "$(json_skill "$SID" instruction-hygiene)" '' ''
chk "missing args write no marker"     bash -c '[ ! -e "/tmp/claude-instruction-hygiene-gate-'"$SID"'" ]'
chk "marker script exits 0 on garbage" bash -c 'printf "junk" | bash "'"$HOOKS"'/skill-invoked-mark.sh" a b'

echo "RESULT: PASS=$PASS FAIL=$FAIL"
