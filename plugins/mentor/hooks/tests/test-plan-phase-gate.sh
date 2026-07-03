#!/usr/bin/env bash
# test-plan-phase-gate.sh — regression tests for plan-phase-gate.sh
#
# Builds a real git repo, derives the repo-scoped plans dir EXACTLY as the hook
# does, plants/removes the .planning marker, then drives the hook with PreToolUse
# JSON for a matrix of tool calls and asserts allow (exit 0) vs block (exit 2).
#
# Contract under test (v0.21.0+): while the .planning marker is present the hook
# is FAIL-CLOSED for Write/Edit/NotebookEdit (only OUTSIDE-repo targets allowed)
# and best-effort for Bash (repo-writing commands blocked; reads/grep/git/nav
# allowed). No marker → inert. Stale marker (>8h) → treated as released.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/plan-phase-gate.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }

# Canonicalize the temp root (macOS mktemp returns /var/... which is a symlink to
# /private/var/...). Production cwd from Claude Code is already canonical, so mirror
# that here — otherwise a /var-vs-/private/var mismatch makes the hook's _canon of an
# existing in-repo target diverge from the raw cwd and spuriously allow it.
ROOT="$(cd "$(mktemp -d)" && pwd -P)"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"
  git config user.email t@t.co; git config user.name t
  mkdir -p src; echo "x" > src/app.ts
  git add -A; git commit -q -m init ) >/dev/null 2>&1

# Derive plans dir + marker exactly as the hook does (plain `pwd`, matching the hook).
git_common="$(git -C "$REPO" rev-parse --git-common-dir)"
case "$git_common" in /*) common_abs="$git_common";; *) common_abs="$REPO/$git_common";; esac
repo_root="$(cd "$(dirname "$common_abs")" && pwd)"
repo_base="$(basename "$repo_root")"
repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
PLANS_DIR="$HOME/.claude/mentor/${repo_base}-${repo_hash}/plans"
MARKER="$PLANS_DIR/.planning"
mkdir -p "$PLANS_DIR"

trap 'rm -rf "$ROOT"; rm -f "$MARKER" "$PLANS_DIR/.read-budget" "$PLANS_DIR/.research-dispatched"; rmdir "$PLANS_DIR" "$(dirname "$PLANS_DIR")" 2>/dev/null || true' EXIT

PASS=0; FAIL=0
run() { # expect cwd tool desc payload
  local expect="$1" cwd="$2" tool="$3" desc="$4" payload="$5" json rc=0 got
  if [ "$tool" = "Bash" ]; then
    json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$cwd" "$payload")
  else
    json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[3],"cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$cwd" "$payload" "$tool")
  fi
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  got="allow"; [ "$rc" = "2" ] && got="block"
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else
    FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s (rc=%s): %s\n       payload: %s\n" "$expect" "$got" "$rc" "$desc" "$payload"
  fi
}

echo "== A. No marker → hook inert (ALLOW all) =="
rm -f "$MARKER"
run allow "$REPO" Write "Write repo file (no marker)"  "$REPO/src/app.ts"
run allow "$REPO" Bash  "rm repo file (no marker)"     "rm $REPO/src/app.ts"

echo "== B. Marker present → repo Write/Edit/NotebookEdit BLOCKED; outside ALLOWED =="
: > "$MARKER"
run block "$REPO" Write       "Write repo source"          "$REPO/src/app.ts"
run block "$REPO" Edit        "Edit repo source"           "$REPO/src/app.ts"
run block "$REPO" Write       "Write new repo file"        "$REPO/NEWFILE"
run block "$REPO" NotebookEdit "NotebookEdit in repo"      "$REPO/nb.ipynb"
run allow "$REPO" Write       "Write the HTML plan (outside)" "$PLANS_DIR/plan.html"
run allow "$REPO" Write       "Write to scratch (outside)" "$ROOT/scratch.txt"

echo "== C. Marker present → repo-writing Bash BLOCKED =="
run block "$REPO" Bash "redirect into repo"  "echo x > $REPO/src/app.ts"
run block "$REPO" Bash "rm repo file"         "rm $REPO/src/app.ts"
run block "$REPO" Bash "sed -i repo file"     "sed -i 's/x/y/' $REPO/src/app.ts"
run block "$REPO" Bash "cd repo && rm rel"    "cd $REPO && rm src/app.ts"
run block "$REPO" Bash "touch new repo file"  "touch $REPO/NEW"
run block "$REPO" Bash "tee into repo"        "echo x | tee $REPO/src/app.ts"

echo "== C2. mkdir -m MODE value must NOT be read as a path (regression: plans-dir create) =="
run allow "$REPO" Bash "mkdir -m 700 OUTSIDE (plans dir)"       "mkdir -p -m 700 $PLANS_DIR"
run allow "$REPO" Bash "mkdir --mode 700 OUTSIDE (plans dir)"   "mkdir -p --mode 700 $PLANS_DIR"
run block "$REPO" Bash "mkdir -m 700 INSIDE repo"              "mkdir -p -m 700 $REPO/newdir"
run block "$REPO" Bash "mkdir -m 700 multi-dir INSIDE"         "mkdir -p -m 700 $REPO/a $REPO/b"
run block "$REPO" Bash "mkdir no -m INSIDE (generic path)"     "mkdir -p $REPO/newdir"
run block "$REPO" Bash "chmod 700 INSIDE (sibling verb, no regress)" "chmod 700 $REPO/src/app.ts"

echo "== D. Marker present → reads / grep / git / navigation / outside writes ALLOWED =="
run allow "$REPO" Bash "cat repo file (read)"     "cat $REPO/src/app.ts"
run allow "$REPO" Bash "grep repo (read)"         "grep -r x $REPO/src"
run allow "$REPO" Bash "git status (read)"        "git -C $REPO status"
run allow "$REPO" Bash "cd repo (navigation)"     "cd $REPO"
run allow "$REPO" Bash "redirect OUTSIDE repo"    "echo x > $ROOT/out.txt"
run allow "$REPO" Bash "write the HTML plan"      "echo '<html>' > $PLANS_DIR/p.html"

echo "== F. Heredoc bodies must NOT be misread as repo writes (regression: session 6d9d6195) =="
# The exact shape that false-fired: a quoted-tag heredoc that ENDS the command (no trailing
# newline). The old stripper required <TAG>\n so it leaked the body; a stray '>' / ')' inside
# was misread as a repo redirect. All four below must ALLOW.
run allow "$REPO" Bash "python3 heredoc read, no trailing newline" \
  $'python3 - <<\'PY\'\nimport sys\nx = 1 > 0\nprint("PLAN-SOURCE: NOT FOUND"); sys.exit()\nPY'
run allow "$REPO" Bash "<<-EOF indented terminator, body has '>'" \
  $'cat <<-EOF\n\tbody with a > redirect-looking char\n\tEOF'
run allow "$REPO" Bash "<< \"EOF\" double-quoted tag, body has '>'" \
  $'cat << "EOF"\na > b inside the body\nEOF\n'
# A REAL repo redirect on a command AFTER the heredoc must STILL block (lazy strip stops at the
# first terminator, so the trailing redirect survives and is correctly flagged).
run block "$REPO" Bash "real repo redirect after a heredoc" \
  "$(printf 'cat <<%sEOF%s\nhello\nEOF\necho pwn > %s/src/app.ts' "'" "'" "$REPO")"

echo "== E. Stale marker (>8h) → treated as released (ALLOW) =="
: > "$MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
run allow "$REPO" Write "Write repo file (stale marker)" "$REPO/src/app.ts"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
