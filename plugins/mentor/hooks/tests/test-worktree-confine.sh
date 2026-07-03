#!/usr/bin/env bash
# test-worktree-confine.sh — regression tests for worktree-confine.sh
#
# Builds a real main checkout + linked worktree + sibling worktree, plants the
# mentor.json state file, then drives the hook with PreToolUse JSON
# for a matrix of commands and asserts allow (exit 0) vs block (exit 2).
#
# Contract under test (v0.21.0+): the hook blocks ONLY file-content writes that
# land on the main checkout or a sibling worktree. Navigation, git plumbing /
# worktree lifecycle, and reads are always allowed — so the /ship cleanup
# (cd main && git worktree remove … && git worktree prune && git branch -d …)
# is never trapped.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/worktree-confine.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
MAIN="$ROOT/sample-space"
WT="$ROOT/worktrees/sample-space-feat"
SIB="$ROOT/worktrees/sample-space-other"

git init -q -b main "$MAIN"
( cd "$MAIN"
  git config user.email t@t.co; git config user.name t
  mkdir -p src; echo "x" > src/app.ts; echo "v=1" > .env
  git add -A; git commit -q -m init
  git worktree add -q -b feature/feat "$WT"
  git worktree add -q -b feature/other "$SIB" ) >/dev/null 2>&1

WT_GITDIR="$(git -C "$WT" rev-parse --git-dir)"
case "$WT_GITDIR" in /*) : ;; *) WT_GITDIR="$(cd "$WT" && cd "$WT_GITDIR" && pwd)";; esac
printf '{"source_branch":"main","feature_branch":"feature/feat"}' > "$WT_GITDIR/mentor.json"

MAINC="$(cd "$MAIN" && pwd -P)"
WTC="$(cd "$WT" && pwd -P)"
SIBC="$(cd "$SIB" && pwd -P)"

PASS=0; FAIL=0
run() { # expect(allow|block) cwd tool desc payload
  local expect="$1" cwd="$2" tool="$3" desc="$4" payload="$5" json rc=0 got
  if [ "$tool" = "Bash" ]; then
    json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$cwd" "$payload")
  else
    json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[3],"cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$cwd" "$payload" "$tool")
  fi
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  got="allow"; [ "$rc" = "2" ] && got="block"
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else
    FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s (rc=%s): %s\n       payload: %s\n" "$expect" "$got" "$rc" "$desc" "$payload"
  fi
}

echo "== A. /ship cleanup flow — ALLOWED =="
run allow "$WTC" Bash "git -C main worktree remove (plain, no --force)" "git -C $MAINC worktree remove $WTC"
run allow "$WTC" Bash "cd main && git worktree remove (plain)"     "cd $MAINC && git worktree remove $WTC"
run allow "$WTC" Bash "cd main && git worktree remove --force"     "cd $MAINC && git worktree remove $WTC --force"
run allow "$WTC" Bash "multi-line cleanup (remove/prune/branch -d)" "cd $MAINC
git worktree remove ../worktrees/sample-space-feat --force
git worktree prune
git branch -d feature/feat"
run allow "$WTC" Bash "git -C main worktree prune"                 "git -C $MAINC worktree prune"
run allow "$WTC" Bash "git -C main branch -d"                      "git -C $MAINC branch -d feature/feat"
run allow "$WTC" Bash "git -C main branch -D"                      "git -C $MAINC branch -D feature/feat"

echo "== B. Navigation / reads / git plumbing into main — ALLOWED =="
run allow "$WTC" Bash "cd into main"                "cd $MAINC"
run allow "$WTC" Bash "pushd into main"             "pushd $MAINC"
run allow "$WTC" Bash "git -C main status"          "git -C $MAINC status"
run allow "$WTC" Bash "git -C main fetch && log"    "git -C $MAINC fetch origin main && git -C $MAINC log --oneline -5"
run allow "$WTC" Bash "cat main file (read)"        "cat $MAINC/.env"
run allow "$WTC" Bash "diff against main (read)"    "diff $MAINC/src/app.ts ./src/app.ts"
run allow "$WTC" Bash "git log fmt with > in quote" "cd $MAINC && git log --format='%H>%s' -1"
run allow "$WTC" Bash "2>&1 fd-dup not a redirect"  "git -C $MAINC status 2>&1 | head"

echo "== C. Copy/install/ln INTO the worktree (main is source) — ALLOWED =="
run allow "$WTC" Bash "cp main/.env into ."         "cp $MAINC/.env ."
run allow "$WTC" Bash "cp relative ../main/.env ."  "cp ../../sample-space/.env ."
run allow "$WTC" Bash "rsync main file into ./"     "rsync $MAINC/.env ./"
run allow "$WTC" Bash "install main into ./config"  "mkdir -p config && install -m 644 $MAINC/.env ./config/"
run allow "$WTC" Bash "ln -s main into worktree"    "ln -s $MAINC/.env ./envlink"

echo "== D. Content writes INTO main / sibling — BLOCKED =="
run block "$WTC" Bash "redirect > main file"        "echo pwned > $MAINC/src/app.ts"
run block "$WTC" Bash "append >> main file"         "echo more >> $MAINC/.env"
run block "$WTC" Bash "redirect > sibling file"     "echo x > $SIBC/src/app.ts"
run block "$WTC" Bash "cp INTO main"                "cp ./README.md $MAINC/README.md"
run block "$WTC" Bash "cp INTO main dir"            "cp ./x $MAINC/src/"
run block "$WTC" Bash "rm -rf main src"             "rm -rf $MAINC/src"
run block "$WTC" Bash "mv INTO main"                "mv ./foo.txt $MAINC/foo.txt"
run block "$WTC" Bash "sed -i on main file"         "sed -i 's/x/y/' $MAINC/src/app.ts"
run block "$WTC" Bash "tee into main file"          "echo x | tee $MAINC/.env"
run block "$WTC" Bash "truncate main file"          "truncate -s 0 $MAINC/.env"
run block "$WTC" Bash "touch new main file"         "touch $MAINC/NEWFILE"
run block "$WTC" Bash "cd main THEN rm relative"    "cd $MAINC && rm src/app.ts"
run block "$WTC" Bash "cd main THEN redirect rel"   "cd $MAINC && echo x > src/app.ts"
run block "$WTC" Bash "cp -t main (target-dir)"     "cp -t $MAINC ./a ./b"
run block "$WTC" Bash "dd of= main file"            "dd if=/dev/zero of=$MAINC/.env bs=1 count=1"

echo "== E. Writes that stay INSIDE the worktree — ALLOWED =="
run allow "$WTC" Bash "redirect inside worktree"    "echo x > out.txt"
run allow "$WTC" Bash "sed -i inside worktree"      "sed -i 's/x/y/' src/app.ts"
run allow "$WTC" Bash "rm inside worktree"          "rm -rf node_modules"

echo "== E2. Heredoc bodies must NOT be misread as escaping writes (regression: strip_heredocs) =="
run allow "$WTC" Bash "heredoc python read (no trailing newline)" \
  $'python3 - <<\'PY\'\nimport sys\nx = 1 > 0\nprint("ok"); sys.exit()\nPY'
run allow "$WTC" Bash "<<-EOF indented terminator, body has '>'" \
  $'cat <<-EOF\n\tbody with a > redirect-looking char\n\tEOF'
# A real redirect into MAIN after a heredoc must STILL block (lazy strip stops at first terminator).
run block "$WTC" Bash "real redirect into main after a heredoc" \
  "$(printf 'cat <<%sEOF%s\nhi\nEOF\necho pwn > %s/src/app.ts' "'" "'" "$MAINC")"

echo "== F. Write/Edit tool — BLOCKED to main/sibling, ALLOWED in worktree =="
run block "$WTC" Write "Write into main src"        "$MAINC/src/app.ts"
run block "$WTC" Edit  "Edit a sibling file"        "$SIBC/src/app.ts"
run allow "$WTC" Write "Write inside worktree"       "$WTC/src/new.ts"
run allow "$WTC" Edit  "Edit inside worktree"        "$WTC/src/app.ts"
run allow "$WTC" Write "Write to ~/.claude plans"    "$HOME/.claude/mentor/plans/x.html"

echo "== G. Not a mentor worktree — hook inert (ALLOW all) =="
run allow "$MAINC" Bash  "rm in plain main checkout" "rm -rf $MAINC/src"
run allow "$MAINC" Write "Write in plain main"       "$MAINC/src/app.ts"

echo "== H. Hardened bypass forms into main / sibling — BLOCKED =="
run block "$WTC" Bash "noclobber-override >| main"      "echo x >| $MAINC/src/app.ts"
run block "$WTC" Bash "subshell (cd main && rm rel)"    "(cd $MAINC && rm src/app.ts)"
run block "$WTC" Bash "subshell (rm main abs)"          "(rm $MAINC/src/app.ts)"
run block "$WTC" Bash "brace group { cd main; rm; }"    "{ cd $MAINC && rm src/app.ts; }"
run block "$WTC" Bash "sudo rm main"                    "sudo rm $MAINC/src/app.ts"
run block "$WTC" Bash "env rm main"                     "env rm $MAINC/src/app.ts"
run block "$WTC" Bash "timeout 5 rm main"               "timeout 5 rm $MAINC/src/app.ts"
run block "$WTC" Bash "nice rm main"                    "nice rm $MAINC/src/app.ts"
run block "$WTC" Bash "command rm main"                 "command rm $MAINC/src/app.ts"
run block "$WTC" Bash "busybox rm main"                 "busybox rm $MAINC/src/app.ts"
run block "$WTC" Bash "sudo tee main"                   "echo x | sudo tee $MAINC/.env"
run block "$WTC" Bash "bash -c rm main"                 "bash -c \"rm $MAINC/src/app.ts\""
run block "$WTC" Bash "sh -c redirect main"             "sh -c \"echo x > $MAINC/src/app.ts\""
run block "$WTC" Bash "eval rm main"                    "eval \"rm $MAINC/src/app.ts\""
run block "$WTC" Bash "cd \$VAR then rm rel"            "M=$MAINC; cd \$M && rm src/app.ts"
run block "$WTC" Bash "find -delete in main"            "find $MAINC/src -name app.ts -delete"
run block "$WTC" Bash "find -exec rm in main"           "find $MAINC/src -name app.ts -exec rm {} \\;"
run block "$WTC" Bash "patch a main file"               "patch $MAINC/src/app.ts < /tmp/p.diff"
run block "$WTC" Bash "cd main && patch -p1"            "cd $MAINC && patch -p1 < /tmp/p.diff"
run block "$WTC" Bash "awk -i inplace main"             "awk -i inplace '{print}' $MAINC/src/app.ts"
run block "$WTC" Bash "ed main file"                    "ed $MAINC/src/app.ts"
run block "$WTC" Bash "xargs rm main (stdin literal)"   "echo $MAINC/src/app.ts | xargs rm"
run block "$WTC" Bash "redirect to sibling >|"          "echo x >| $SIBC/src/app.ts"

echo "== I. Hardening must NOT over-block legitimate work — ALLOWED =="
run allow "$WTC" Bash "ship: git -C main merge --ff-only"  "git -C $MAINC merge --ff-only origin/main"
run allow "$WTC" Bash "ship: git -C main checkout source"  "git -C $MAINC checkout main"
run allow "$WTC" Bash "ship: cd main && git merge --ff"    "cd $MAINC && git merge --ff-only feature/feat"
run allow "$WTC" Bash "timeout wraps a build (no write)"   "timeout 600 npm test"
run allow "$WTC" Bash "env VAR wraps a build"              "env NODE_ENV=test npm run build"
run allow "$WTC" Bash "subshell writes INSIDE worktree"    "(cd src && echo x > out.txt)"
run allow "$WTC" Bash "bash -c build inside worktree"      "bash -c \"npm test\""
run allow "$WTC" Bash "bash -c write inside worktree"      "bash -c \"echo x > out.txt\""
run allow "$WTC" Bash "find -delete INSIDE worktree"       "find . -name '*.log' -delete"
run allow "$WTC" Bash "xargs cat (read, not write)"        "echo $MAINC/.env | xargs cat"
run allow "$WTC" Bash "cd \$VAR into worktree subdir"      "D=$WTC/src; cd \$D && echo x > out.txt"
run allow "$WTC" Bash "grep -r reading main"               "grep -r foo $MAINC/src"

echo "== J. Round-2 fixes: brace-var cd + find -exec target analysis =="
run block "$WTC" Bash "cd \${VAR} brace then rm rel"     "M=$MAINC; cd \${M} && rm src/app.ts"
run block "$WTC" Bash "pushd \${VAR} brace then rm"      "M=$MAINC; pushd \${M} && rm src/app.ts"
run block "$WTC" Bash "chained \${VAR} cd then rm"       "M=$MAINC; D=\${M}; cd \$D && rm src/app.ts"
run block "$WTC" Bash "cd \${VAR}/src then rm (control)" "M=$MAINC; cd \${M}/src && rm app.ts"
run block "$WTC" Bash "find -exec sed -i on main files"  "find $MAINC -name app.ts -exec sed -i 's/a/b/' {} +"
run block "$WTC" Bash "find . -exec cp INTO main (dest)" "find . -name '*.ts' -exec cp {} $MAINC/dst \\;"
run allow "$WTC" Bash "find main -exec cp {} ./ (read-in)" "find $MAINC/src -name '*.ts' -exec cp {} ./ \\;"
run allow "$WTC" Bash "find main -exec cp -t ./dst {} +"   "find $MAINC/src -name '*.ts' -exec cp -t ./dst {} +"
run allow "$WTC" Bash "find main -exec cat (read)"         "find $MAINC -name app.ts -exec cat {} +"
run allow "$WTC" Bash "find main -exec grep (read)"        "find $MAINC -exec grep foo {} +"

echo "== K. Outer var threaded into sh -c / bash -c / eval recursion — BLOCKED =="
run block "$WTC" Bash "var + bash -c cd brace rm"   "M=$MAINC; bash -c \"cd \${M} && rm src/app.ts\""
run block "$WTC" Bash "var + sh -c cd rm"           "M=$MAINC; sh -c \"cd \$M && rm src/app.ts\""
run block "$WTC" Bash "var + eval rm abs"           "M=$MAINC; eval \"rm \$M/src/app.ts\""
run block "$WTC" Bash "var + bash -c redirect abs"  "M=$MAINC; bash -c \"echo pwned > \$M/src/app.ts\""
run block "$WTC" Bash "var(sib) + bash -c rm"       "S=$SIBC; bash -c \"rm \$S/src/app.ts\""
run allow "$WTC" Bash "var + bash -c build (no write)" "M=$MAINC; bash -c \"cd \$M && git status\""

echo "== L. env -S split-string + deep shell nesting — BLOCKED =="
run block "$WTC" Bash "env -S rm main"               "env -S \"rm $MAINC/src/app.ts\""
run block "$WTC" Bash "env -S redirect main"         "env -S \"echo y > $MAINC/src/app.ts\""
run block "$WTC" Bash "env --split-string= rm main"  "env --split-string=\"rm $MAINC/src/app.ts\""
run allow "$WTC" Bash "env -S git status (read)"     "env -S \"git -C $MAINC status\""
run allow "$WTC" Bash "env -S write inside worktree" "env -S \"echo y > out.txt\""

# Deep-nesting: build bash-VALID N-level `bash -c "..."` (escaping for embedding
# in a double-quoted string) around a write. The recursion must descend through
# every level (cap is 24): 6 levels into main must BLOCK, into the worktree ALLOW.
nest() { python3 - "$1" "$2" <<'PYGEN'
import sys
def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"')
inner = sys.argv[2]
for _ in range(int(sys.argv[1])):
    inner = 'bash -c "' + esc(inner) + '"'
print(inner)
PYGEN
}
run block "$WTC" Bash "6x nested bash -c rm main"     "$(nest 6 "rm $MAINC/src/app.ts")"
run allow "$WTC" Bash "6x nested bash -c write in WT" "$(nest 6 'echo y > out.txt')"

echo "== M. Round-3 (gate) fixes: >& redirect, subshell-scoped cd, xargs copy-dest, archives =="
# >& FILE is a real stdout+stderr file redirect (synonym of &>)
run block "$WTC" Bash ">& into main"               "make >& $MAINC/build.log"
run block "$WTC" Bash ">& glued into main"          "make >&$MAINC/build.log"
run block "$WTC" Bash "1>& into main"               "echo hi 1>& $MAINC/src/app.ts"
run allow "$WTC" Bash ">&1 fd-dup (not a file)"     "make >&1 2>&1"
run allow "$WTC" Bash ">& into worktree file"       "make >& build.log"
# subshell-scoped cd: inner cd must NOT leak to a redirect outside the parens
run allow "$WTC" Bash "(cd main && read) > wtfile"  "(cd $MAINC && cat src/app.ts) > snapshot.txt"
run allow "$WTC" Bash "(cd main && git diff)>wtfile" "(cd $MAINC && git diff) > changes.diff"
run block "$WTC" Bash "(cd main && write inside ())" "(cd $MAINC && echo x > rel.txt)"
run block "$WTC" Bash "(cd main && rm) still blocks" "(cd $MAINC && rm src/app.ts)"
# xargs: copy-from-main-into-WT allowed; copy/delete-into-main blocked
run allow "$WTC" Bash "find main | xargs cp -t WT"  "find $MAINC/src -name '*.ts' | xargs cp -t $WTC"
run allow "$WTC" Bash "find main | xargs cp -t ./"  "find $MAINC/src | xargs cp -t ./"
run allow "$WTC" Bash "find main | xargs cat (read)" "find $MAINC | xargs cat"
run block "$WTC" Bash "find . | xargs cp -t main"   "find . | xargs cp -t $MAINC/src"
run block "$WTC" Bash "echo main | xargs rm"        "echo $MAINC/src/app.ts | xargs rm"
# archive / output-flag writers
run block "$WTC" Bash "sort -o into main"           "sort -o $MAINC/out.txt in.txt"
run allow "$WTC" Bash "sort -o into worktree"       "sort -o out.txt in.txt"
run block "$WTC" Bash "unzip -d into main"          "unzip a.zip -d $MAINC"
run allow "$WTC" Bash "unzip -d into worktree"      "unzip a.zip -d ./extracted"
run block "$WTC" Bash "tar extract -C into main"    "tar xzf a.tgz -C $MAINC"
run block "$WTC" Bash "tar create -f into main"     "tar czf $MAINC/a.tgz src"
run allow "$WTC" Bash "tar create reads main->local" "tar czf out.tgz $MAINC/src"
run allow "$WTC" Bash "tar extract into worktree"   "tar xzf a.tgz -C ./build"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
