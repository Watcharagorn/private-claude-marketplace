#!/usr/bin/env bash
# test-orchestrator-gate.sh — regression tests for orchestrator-gate.sh (+ orchestrator-prompt.sh
# injection economy). Builds a real git repo, writes the repo config the hook keys off
# (v0.37: orchestrator is an orthogonal toggle — ON iff config.json {"orchestrator":true},
# with legacy {"mode":"commander"} still resolving ON), and drives the gate with PreToolUse
# JSON, asserting: subagent allow (deadlock guard), in-repo write/bash block, outside-repo +
# artifact-dir + read-budget + dispatch step-aside, the plugin-owned-flow exemptions, the
# legacy-commander fallback, no-git no-op, and the <2000-char injected span.
#
# NOTE: this drives the gate with the REAL $HOME (the temp repo's hash is unique, and cleanup
# removes its state dir). It deliberately does NOT write the GLOBAL ~/.claude/mentor/config.json
# — that would clobber the user's real global toggle. Global/precedence is covered by
# test-state-lib.sh under a sandbox HOME.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/orchestrator-gate.sh"
PROMPT_HOOK="$(dirname "$SCRIPT_DIR")/orchestrator-prompt.sh"
SKILL="$(dirname "$(dirname "$SCRIPT_DIR")")/skills/orchestrator/SKILL.md"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }

# Canonicalize the temp root (macOS mktemp returns /var/... → symlink to /private/var/...).
# Production cwd is already canonical; mirror that so the hook's _canon doesn't diverge.
ROOT="$(cd "$(mktemp -d)" && pwd -P)"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

git_common="$(git -C "$REPO" rev-parse --git-common-dir)"
case "$git_common" in /*) common_abs="$git_common";; *) common_abs="$REPO/$git_common";; esac
repo_root="$(cd "$(dirname "$common_abs")" && pwd)"
repo_base="$(basename "$repo_root")"; repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
STATE_DIR="$HOME/.claude/mentor/${repo_base}-${repo_hash}"
PLANS_DIR="$STATE_DIR/plans"
CONF="$STATE_DIR/config.json"
mkdir -p "$PLANS_DIR"

SID="orch-test-$$"
BUD="/tmp/mentor-orchestrator-read-budget-${SID}"
DISP="/tmp/mentor-orchestrator-dispatched-${SID}"
FLOW="/tmp/mentor-flow-active-${SID}"
LOADED="/tmp/mentor-orchestrator-loaded-${SID}"
MAIN_TX="/tmp/orch-test-main-${SID}.jsonl"           # path WITHOUT /subagents/ → main
SUB_TX="/tmp/sess/subagents/agent-x-${SID}.jsonl"    # path WITH /subagents/ → subagent

cleanup() {
  rm -rf "$ROOT" "$STATE_DIR"
  rm -f "$BUD" "$DISP" "$FLOW" "$LOADED" 2>/dev/null
}
trap cleanup EXIT

conf_on()    { printf '{"orchestrator": true}\n' > "$CONF"; }   # the toggle, repo scope
conf_off()   { rm -f "$CONF" 2>/dev/null; }
conf_plan()  { printf '{"mode": "plan"}\n' > "$CONF"; }         # mode set, orchestrator absent → OFF
conf_legacy(){ printf '{"mode": "commander"}\n' > "$CONF"; }    # pre-0.37 config → resolver fallback ON

PASS=0; FAIL=0

mk() { python3 - "$@" <<'PY'
import json, sys
d = dict(a.split('=', 1) for a in sys.argv[1:])
ti = {}
for k in ('file_path', 'command', 'path', 'notebook_path'):
    if k in d:
        ti[k] = d[k]
o = {'tool_name': d.get('tool', ''), 'cwd': d.get('cwd', ''),
     'session_id': d.get('sid', ''), 'tool_input': ti}
if 'transcript' in d: o['transcript_path'] = d['transcript']
if 'agent_id' in d:   o['agent_id'] = d['agent_id']
print(json.dumps(o))
PY
}
mkprompt() { python3 -c 'import json,sys;print(json.dumps({"prompt":sys.argv[1],"session_id":sys.argv[2],"cwd":sys.argv[3]}))' "$1" "$SID" "$REPO"; }

run() { # expect desc json [env=val ...]
  local expect="$1" desc="$2" json="$3"; shift 3
  local rc=0
  if [ "$#" -gt 0 ]; then
    printf '%s' "$json" | env "$@" bash "$HOOK" >/dev/null 2>&1 || rc=$?
  else
    printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  fi
  local got="allow"; [ "$rc" = "2" ] && got="block"
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s (rc=%s): %s\n" "$expect" "$got" "$rc" "$desc"; fi
}
chk() { # "desc" cond... (cond is a command; 0 = pass)
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
reset() { rm -f "$BUD" "$DISP" "$FLOW" "$PLANS_DIR/.planning" "$REPO/.git/mentor.json" 2>/dev/null; }

echo "== A. Toggle OFF (no config / config mode=plan) → ALLOW =="
reset; conf_off
run allow "in-repo Write, no config" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
conf_plan
run allow "in-repo Write, config mode=plan (orchestrator absent)" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"

echo "== B. Subagent → ALLOW (deadlock guard) =="
conf_on
run allow "subagent via agent_id, in-repo Write" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" agent_id=abc file_path="$REPO/src/a.ts")"
run allow "subagent via /subagents/ transcript"   "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$SUB_TX" file_path="$REPO/src/a.ts")"
run allow "fail-open: no transcript_path"          "$(mk tool=Write cwd="$REPO" sid="$SID" file_path="$REPO/src/a.ts")"

echo "== C. Write / Edit / MultiEdit (main) =="
reset; conf_on
run block "in-repo Write"      "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
run block "in-repo Edit"       "$(mk tool=Edit cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
run block "in-repo MultiEdit"  "$(mk tool=MultiEdit cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
run allow "outside-repo Write (plans HTML)" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$PLANS_DIR/p.html")"
run allow "outside-repo Write (/tmp)"       "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="/tmp/foo-$SID.txt")"
run allow "unresolvable (empty path) → fail-open" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX")"

echo "== D. Bash =="
reset; conf_on
run block "rm into repo"           "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="rm $REPO/src/a.ts")"
run block "redirect into repo"     "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="echo hi > $REPO/x.txt")"
run allow "git status (read-only)" "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="git status")"
run allow "npm test"               "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="npm test")"
run allow "cat (read-only)"        "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="cat $REPO/f")"
run allow "write into coverage/ (artifact dir)" "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="touch $REPO/coverage/lcov.info")"

echo "== D1. Heredoc bodies must NOT be misread as repo writes (regression: this gate never stripped) =="
reset; conf_on
# Confirmed false-fire shape: a quoted-tag heredoc ending the command with NO trailing newline.
# orchestrator-gate.sh formerly ran analyze(cmd) on the RAW command (no strip_heredocs) → the body
# leaked and a stray '>' was misread as a repo redirect. These must ALLOW now.
hd_read=$'python3 - <<\'PY\'\nimport sys\nx = 1 > 0\nprint("PLAN-SOURCE: NOT FOUND"); sys.exit()\nPY'
run allow "heredoc python read (no trailing newline)" "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="$hd_read")"
hd_dash=$'cat <<-EOF\n\tbody with a > redirect-looking char\n\tEOF'
run allow "<<-EOF indented terminator, body has '>'" "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="$hd_dash")"
# A REAL repo redirect AFTER the heredoc must STILL block (lazy strip stops at the first terminator).
hd_block=$'cat <<\'EOF\'\nhi\nEOF\necho pwn > '"$REPO"$'/x.txt'
run block "real repo redirect after a heredoc" "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="$hd_block")"

echo "== D2. mkdir -m MODE value must NOT be read as a path (regression) =="
reset; conf_on
run allow "mkdir -m 700 OUTSIDE (plans dir)"   "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="mkdir -p -m 700 $PLANS_DIR")"
run allow "mkdir --mode 700 OUTSIDE"           "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="mkdir -p --mode 700 $PLANS_DIR")"
run block "mkdir -m 700 INSIDE repo"           "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="mkdir -p -m 700 $REPO/newdir")"
run block "mkdir -m 700 multi-dir INSIDE"      "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="mkdir -p -m 700 $REPO/a $REPO/b")"
run block "mkdir no -m INSIDE (generic path)"  "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="mkdir -p $REPO/newdir")"
run block "chmod 700 INSIDE (sibling verb, no regress)" "$(mk tool=Bash cwd="$REPO" sid="$SID" transcript="$MAIN_TX" command="chmod 700 $REPO/f")"

echo "== E. Read budget + dispatch step-aside + carve-out =="
reset; conf_on
run allow "in-repo read #1"  "$(mk tool=Read cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
run allow "in-repo read #2"  "$(mk tool=Read cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
run allow "in-repo read #3"  "$(mk tool=Read cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
run block "in-repo read #4 (budget)" "$(mk tool=Read cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
: > "$DISP"
run allow "in-repo read after dispatch (step-aside)" "$(mk tool=Read cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
reset; conf_on; echo 9 > "$BUD"
run allow "outside-repo read, budget exhausted (uncounted)" "$(mk tool=Read cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="/tmp/x-$SID")"
run block "in-repo read, budget exhausted" "$(mk tool=Read cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"

echo "== F. Plugin-owned-flow exemptions → ALLOW (defer) =="
reset; conf_on; : > "$PLANS_DIR/.planning"
run allow ".planning present → defer" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
reset; conf_on; : > "$FLOW"
run allow "mentor-flow-active fresh → defer" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
reset; conf_on; : > "$REPO/.git/mentor.json"
run allow "inside mentor worktree (mentor.json) → defer" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"

echo "== G. Legacy mode:commander still activates the gate (resolver fallback) =="
reset; conf_legacy
run block "legacy {\"mode\":\"commander\"} → in-repo Write blocked" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")"
# removed knobs are inert: the v0.33-era MENTOR_COMMANDER env never re-enables/disables.
conf_on
run block "removed MENTOR_COMMANDER=off is ignored (still blocks)" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")" MENTOR_COMMANDER=off
conf_off
run allow "removed MENTOR_COMMANDER=on does not enable (no config)" "$(mk tool=Write cwd="$REPO" sid="$SID" transcript="$MAIN_TX" file_path="$REPO/src/a.ts")" MENTOR_COMMANDER=on

echo "== H. No git repo → no-op (ALLOW) =="
reset; conf_on
run allow "non-git dir Write" "$(mk tool=Write cwd="$NONGIT" sid="$SID" transcript="$MAIN_TX" file_path="$NONGIT/a.ts")"

echo "== I. Injection economy (orchestrator-prompt.sh + SKILL span) =="
span="$(awk '/<!--INJECT-->/{f=1;next} /<!--\/INJECT-->/{f=0} f' "$SKILL" | wc -c | tr -d ' ')"
chk "injected span <2000 chars (got ${span})" sh -c "[ \"$span\" -gt 0 ] && [ \"$span\" -lt 2000 ]"
reset; conf_on; rm -f "$LOADED"
OUT0="$(printf '%s' "$(mkprompt 'hello')"  | bash "$PROMPT_HOOK" 2>/dev/null)"
chk "prompt hook ON via config" sh -c "printf '%s' \"\$0\" | grep -q 'orchestrator ON'" "$OUT0"
rm -f "$LOADED"
OUT1="$(printf '%s' "$(mkprompt 'hello')"  | bash "$PROMPT_HOOK" 2>/dev/null)"
OUT2="$(printf '%s' "$(mkprompt 'again')"  | bash "$PROMPT_HOOK" 2>/dev/null)"
chk "reminder injected turn 1" sh -c "printf '%s' \"\$0\" | grep -q 'orchestrator ON'" "$OUT1"
chk "reminder injected turn 2" sh -c "printf '%s' \"\$0\" | grep -q 'orchestrator ON'" "$OUT2"
chk "playbook injected ONCE (turn 1 only)" sh -c "printf '%s' \"\$0\" | grep -q 'you are the orchestrator' && ! printf '%s' \"\$1\" | grep -q 'you are the orchestrator'" "$OUT1" "$OUT2"
conf_off
OUT3="$(printf '%s' "$(mkprompt 'hello')"  | bash "$PROMPT_HOOK" 2>/dev/null)"
chk "prompt hook silent when config off" sh -c "[ -z \"\$0\" ]" "$OUT3"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
