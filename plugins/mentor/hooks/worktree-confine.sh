#!/usr/bin/env bash
# PreToolUse hook for Write, Edit, Bash — keeps a mentor executor
# from WRITING source-branch content while it works inside its worktree.
#
# Wired via hooks/hooks.json as PreToolUse:Write, PreToolUse:Edit, PreToolUse:Bash.
# Exit 2 = block the tool call (Claude Code shows stderr to the agent).
# Exit 0 = allow the tool call (no opinion).
#
# SCOPE (v0.20.1): this guard blocks ONLY operations that create / modify /
# delete file *content* landing on the main checkout (the source branch working
# tree) or a sibling worktree. It deliberately does NOT block:
#   • navigation — `cd`, `pushd`, `git -C <path>` to anywhere;
#   • `git` plumbing & worktree lifecycle — `git worktree remove/prune/add/...`,
#     `git branch -d/-D`, fetch/push/pull, status/log/diff, merge --ff-only,
#     checkout, etc.;
#   • reads of any path (cat/grep/diff/… against the main checkout).
# The earlier versions blocked on any *reference* to an outside path (every
# `cd`, `git -C`, and absolute-path argument), which trapped agents inside the
# worktree — they could not even run the /ship cleanup (`git worktree remove`,
# `git worktree prune`, `git branch -d`). Those are git metadata ops, not source
# writes, and are now permitted. The controlled path back to the source branch
# is still /ship; this hook is only a safety net against accidental content
# writes (a stray Write/Edit, redirect, or cp/mv into the parent checkout).
#
# The Bash analyzer covers the common write paths: shell redirects (> >> >| >&),
# cp/rsync/install/ln/mv/rm/tee/truncate/sed -i/perl -i/dd, find -delete/-exec,
# patch, in-place editors (awk -i inplace, ed, ex/vim -es), sort -o, tar -x -C /
# -c -f, unzip -d, xargs <write-verb>, and it sees through subshell/brace
# grouping (with subshell-scoped cd — an inner `cd` does not leak to a redirect
# outside the parens), command wrappers (sudo/env/timeout/nice/…, incl.
# `env -S "…"`), simple VAR=val cd targets (incl. ${braces}, chained, and
# threaded into the recursion), and nested `sh -c`/`bash -c`/`eval "…"`. It is
# explicitly BEST-EFFORT, not a sandbox: a determined interpreter one-liner
# (`python3 -c`, `node -e`, `ruby -e`), an `xargs`/pipe fed entirely from stdin
# with no literal path, an obfuscated/encoded path, a less-common writer not in
# the verb tables (gzip/split/…), or a deliberate working-tree `git apply`/
# `git reset` against an explicit main target can still get through. Out of scope
# — the real boundary is /ship plus the fact that an executor should not be
# deliberately writing source-branch files. (git working-tree mutations are NOT
# blocked on purpose: /ship itself runs `git -C "$main_repo" merge --ff-only`
# and `checkout` into the local source branch.)
#
# Detection: the worktree is "owned" by mentor iff
#   1. git rev-parse --git-dir resolves to a .git/worktrees/<name> dir, AND
#   2. that dir contains mentor.json (written at allocation), AND
#   3. git worktree list --porcelain lists $cwd as a registered worktree
#      (reconciliation against stale state from a half-failed /ship cleanup).
# Plain `git worktree add` use — without the mentor state file — is
# never confined.
#
# Fail-open: any parse / canonicalization error → exit 0 so legitimate work
# is never blocked by a hook bug.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_realpath_m() {
  # Canonicalize a path without requiring it to exist (like GNU realpath -m).
  local path="$1"

  if realpath -m -- "$path" 2>/dev/null; then
    return 0
  fi

  if realpath -- "$path" 2>/dev/null; then
    return 0
  fi

  python3 -c "
import os, sys
p = sys.argv[1]
print(os.path.realpath(p))
" "$path" 2>/dev/null || echo "$path"
}

# ---------------------------------------------------------------------------
# Read stdin JSON (exactly once — store in variable)
# ---------------------------------------------------------------------------

INPUT=""
INPUT=$(cat) || { exit 0; }

# ---------------------------------------------------------------------------
# Extract tool_name + cwd
# ---------------------------------------------------------------------------

TOOL_NAME=""
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || { exit 0; }

if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

CWD=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || true
[[ -z "$CWD" ]] && CWD="$PWD"

# ---------------------------------------------------------------------------
# Resolve active mentor worktree
# ---------------------------------------------------------------------------

# 1. Locate this checkout's git dir. From inside a linked worktree this
#    returns the .git/worktrees/<name> path directly (robust against
#    `git worktree move` and slug-sanitization).
GIT_DIR=""
GIT_DIR=$(git -C "$CWD" rev-parse --git-dir 2>/dev/null || true)
[[ -z "$GIT_DIR" ]] && exit 0

# Make absolute (rev-parse may return a path relative to $cwd).
if [[ "$GIT_DIR" != /* ]]; then
  GIT_DIR=$(cd "$CWD" 2>/dev/null && cd "$GIT_DIR" 2>/dev/null && pwd) || exit 0
fi

# 2. Check for mentor state file. Absence = not our worktree.
STATE_FILE="${GIT_DIR}/mentor.json"
[[ -f "$STATE_FILE" ]] || exit 0

# 3. Reconciliation: ensure git itself still knows about this worktree.
#    If the state file is orphaned (worktree path moved away, half-failed
#    cleanup, etc.) we must NOT block writes anywhere.
WT_ROOT=""
WT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
[[ -z "$WT_ROOT" ]] && exit 0

WT_ROOT_CANON=$(_realpath_m "$WT_ROOT") || exit 0

REGISTERED=0
while IFS= read -r line; do
  [[ "$line" == worktree\ * ]] || continue
  candidate="${line#worktree }"
  candidate_canon=$(_realpath_m "$candidate") || continue
  if [[ "$candidate_canon" == "$WT_ROOT_CANON" ]]; then
    REGISTERED=1
    break
  fi
done < <(git -C "$CWD" worktree list --porcelain 2>/dev/null || true)

[[ "$REGISTERED" -eq 1 ]] || exit 0

# ---------------------------------------------------------------------------
# Collect sibling worktrees and main checkout root from git itself.
# ---------------------------------------------------------------------------

MAIN_CHECKOUT_CANON=""
SIBLING_WT_PATHS=()

# git worktree list --porcelain: blocks of "worktree <path>" lines. The
# first block is the main checkout; subsequent blocks are linked worktrees.
FIRST_SEEN=0
while IFS= read -r line; do
  [[ "$line" == worktree\ * ]] || continue
  candidate="${line#worktree }"
  candidate_canon=$(_realpath_m "$candidate") || continue
  if [[ "$FIRST_SEEN" -eq 0 ]]; then
    MAIN_CHECKOUT_CANON="$candidate_canon"
    FIRST_SEEN=1
  fi
  # Anything that isn't the active worktree is a "sibling".
  if [[ "$candidate_canon" != "$WT_ROOT_CANON" ]]; then
    SIBLING_WT_PATHS+=("$candidate_canon")
  fi
done < <(git -C "$CWD" worktree list --porcelain 2>/dev/null || true)

# The main checkout is itself a sensitive "outside" target if we're in a
# linked worktree (which is the normal mentor case). If by some
# quirk WT_ROOT_CANON equals MAIN_CHECKOUT_CANON (state file exists in the
# main checkout's .git), unset MAIN_CHECKOUT_CANON to avoid blocking the
# entire repo.
if [[ "$MAIN_CHECKOUT_CANON" == "$WT_ROOT_CANON" ]]; then
  MAIN_CHECKOUT_CANON=""
fi

# ---------------------------------------------------------------------------
# Helper: check if a canonical path is "outside" the worktree (and is
# sensitive — i.e. it is the main checkout or a sibling worktree).
# Returns 0 (true) if outside+sensitive, 1 if safe.
# ---------------------------------------------------------------------------
_is_outside_sensitive() {
  local path_canon="$1"

  # Inside active worktree → safe
  if [[ "$path_canon" == "${WT_ROOT_CANON}"/* || "$path_canon" == "$WT_ROOT_CANON" ]]; then
    return 1
  fi

  # Check against main checkout
  if [[ -n "$MAIN_CHECKOUT_CANON" ]]; then
    if [[ "$path_canon" == "$MAIN_CHECKOUT_CANON" || "$path_canon" == "${MAIN_CHECKOUT_CANON}/"* ]]; then
      return 0
    fi
  fi

  # Check against sibling worktrees
  for sib in "${SIBLING_WT_PATHS[@]+"${SIBLING_WT_PATHS[@]}"}"; do
    if [[ "$path_canon" == "$sib" || "$path_canon" == "${sib}/"* ]]; then
      return 0
    fi
  done

  return 1
}

# ---------------------------------------------------------------------------
# Branch: Write / Edit
# ---------------------------------------------------------------------------

if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  FILE_PATH=""
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || { exit 0; }

  if [[ -z "$FILE_PATH" ]]; then
    exit 0
  fi

  FILE_CANON=""
  FILE_CANON=$(_realpath_m "$FILE_PATH") || { exit 0; }

  # Block only writes that land in the main checkout (source branch) or a
  # sibling worktree. Writes inside the active worktree — or to unrelated
  # locations like the central ~/.claude/mentor/<repo>-<hash>/plans dir — are fine.
  if ! _is_outside_sensitive "$FILE_CANON"; then
    exit 0
  fi

  cat >&2 << EOF
BLOCKED by mentor worktree-confine.
This agent must stay inside its worktree:
  ${WT_ROOT_CANON}
The ${TOOL_NAME} attempts to modify a file in the source branch checkout (or a sibling worktree):
  ${FILE_PATH}
If you genuinely need to edit a file in the parent project, exit the worktree first via ExitWorktree, or invoke /ship to merge back into the source branch.
EOF
  exit 2
fi

# ---------------------------------------------------------------------------
# Branch: Bash
# ---------------------------------------------------------------------------
#
# One Python pass classifies the command. It blocks iff some file-content WRITE
# target resolves into the main checkout or a sibling worktree; otherwise it
# prints nothing (allow). Any internal error prints nothing → fail-open.

if [[ "$TOOL_NAME" == "Bash" ]]; then
  BASH_CMD=""
  BASH_CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || { exit 0; }

  if [[ -z "$BASH_CMD" ]]; then
    exit 0
  fi

  command -v python3 >/dev/null 2>&1 || exit 0   # no python → fail-open

  BLOCK_OUT=""
  BLOCK_OUT=$(python3 - "$BASH_CMD" "$CWD" "$WT_ROOT_CANON" "$MAIN_CHECKOUT_CANON" "${SIBLING_WT_PATHS[@]+"${SIBLING_WT_PATHS[@]}"}" 2>/dev/null << 'PYEOF' || true
import sys, os, shlex, re

try:
    cmd       = sys.argv[1] if len(sys.argv) > 1 else ""
    start_cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    wt_root   = sys.argv[3] if len(sys.argv) > 3 else ""
    main_co   = sys.argv[4] if len(sys.argv) > 4 else ""
    siblings  = [s for s in sys.argv[5:] if s]

    if not start_cwd:
        start_cwd = os.getcwd()

    # ── path canonicalization + sensitivity ────────────────────────────────
    def under(path, root):
        if not root or path is None:
            return False
        root = root.rstrip("/")
        return path == root or path.startswith(root + "/")

    def outside_sensitive(path):
        if path is None:
            return False
        if under(path, wt_root):          # inside the agent's own worktree → safe
            return False
        if under(path, main_co):          # the source-branch checkout
            return True
        for sib in siblings:              # another executor's worktree
            if under(path, sib):
                return True
        return False

    ENV_RE   = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
    REDIR_TOK = re.compile(r'^[0-9]*&?>>?\|?$|^[0-9]*<$')
    VAR_RE   = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)')

    def expand(tok, assigns):
        # Expand $VAR / ${VAR} from tracked simple assignments. Returns
        # (expanded, resolvable). Unresolvable if any $ / ` / $( remains.
        def repl(m):
            name = m.group(1) or m.group(2)
            return assigns.get(name, "\x00")
        out = VAR_RE.sub(repl, tok)
        if "\x00" in out or "$" in out or "`" in out:
            return out, False
        return out, True

    def resolve(tok, base, assigns):
        if not tok:
            return None
        e, ok = expand(tok, assigns)
        if not ok:
            return None
        p = os.path.expanduser(e)   # expand ~ before isabs check
        if not os.path.isabs(p):
            p = os.path.join(base or start_cwd, p)
        try:
            return os.path.realpath(p)
        except Exception:
            return os.path.normpath(p)

    DELETION_OPS = {'rm', 'rmdir', 'shred', 'unlink'}

    def resolve_for_delete(tok, base, assigns):
        if not tok:
            return None
        e, ok = expand(tok, assigns)
        if not ok:
            return None
        p = os.path.expanduser(e)   # expand ~ before isabs check
        if not os.path.isabs(p):
            p = os.path.join(base or start_cwd, p)
        return os.path.normpath(p)  # normpath: don't follow symlinks for deletions

    def strip_heredocs(cmd):
        # Strip heredoc BODIES so their content is never parsed as the command line.
        # Handles: <<TAG, <<'TAG', <<"TAG", <<-TAG (indented terminator), extra tokens
        # after the tag on the opener line (e.g. <<'PY' 2>/dev/null), AND a terminator
        # that ends the command with no trailing newline (the (?:\n|$) anchor). The lazy
        # body match stops at the FIRST terminator, so a real redirect on a command AFTER
        # the heredoc still survives the strip.
        return re.sub(
            r"<<-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n(?:.*\n)*?[ \t]*\2[ \t]*(?:\n|$)",
            "<<STRIPPED\n",
            cmd,
        )

    # ── split on && || | ; and newlines, respecting quotes/escapes and ──────
    # NOT splitting on the `|` of a `>|` (noclobber-override) redirect.
    def split_segments(raw):
        segs, start, i, n = [], 0, 0, len(raw)
        while i < n:
            c = raw[i]
            if c in ('"', "'"):
                q = c; i += 1
                while i < n and raw[i] != q:
                    if raw[i] == '\\':
                        i += 1
                    i += 1
                i += 1
                continue
            if c == '\\':
                i += 2
                continue
            if c == '#':
                break
            if c == '>':                       # redirect op: consume >, >>, >|, &>
                i += 1
                if i < n and raw[i] == '>':
                    i += 1
                if i < n and raw[i] == '|':
                    i += 1
                continue
            if raw[i:i+2] in ('&&', '||'):
                segs.append(raw[start:i]); i += 2; start = i
                continue
            if c in ('|', ';', '\n'):
                segs.append(raw[start:i]); i += 1; start = i
                continue
            i += 1
        segs.append(raw[start:])
        return [s.strip() for s in segs if s.strip()]

    # ── shell redirect targets in a segment (quote-aware, skips fd dups) ────
    def redirect_targets(seg):
        out, i, n = [], 0, len(seg)
        while i < n:
            c = seg[i]
            if c in ('"', "'"):
                q = c; i += 1
                while i < n and seg[i] != q:
                    if seg[i] == '\\':
                        i += 1
                    i += 1
                i += 1
                continue
            if c == '\\':
                i += 2
                continue
            if c == '>':
                j = i + 1
                if j < n and seg[j] == '>':    # >>
                    j += 1
                if j < n and seg[j] == '|':    # >| (noclobber override)
                    j += 1
                while j < n and seg[j] in (' ', '\t'):
                    j += 1
                if j < n and seg[j] == '&':
                    k = j + 1
                    while k < n and seg[k] in (' ', '\t'):
                        k += 1
                    if k >= n or seg[k].isdigit() or seg[k] == '-':
                        i = j + 1          # >&1 / >&- / bare >& : fd duplication
                        continue
                    j = k                  # `>& FILE` is a stdout+stderr file redirect
                if j < n and seg[j] in ('"', "'"):
                    q = seg[j]; j += 1; s = j
                    while j < n and seg[j] != q:
                        j += 1
                    if seg[s:j]:
                        out.append(seg[s:j])
                    i = j + 1
                    continue
                s = j
                while j < n and seg[j] not in (' ', '\t', ';', '|', '&', '<', '>', '"', "'"):
                    j += 1
                if seg[s:j]:
                    out.append(seg[s:j])
                i = j
                continue
            i += 1
        return out

    def tokens_of(seg):
        try:
            t = shlex.split(seg)
        except ValueError:
            t = seg.split()
        # Strip shell grouping / compound lead-ins so `(cd X && rm y)` and
        # `{ rm y; }` expose their real verb. Drop standalone ( ) { } tokens
        # and shell keywords; peel a leading ( or { glued to the first token.
        out = []
        for tok in t:
            if tok in ('(', ')', '{', '}', ';', '&', 'then', 'do', 'else', 'fi', 'done'):
                continue
            if tok == '{}':                       # find -exec placeholder — keep verbatim
                out.append(tok); continue
            tok = tok.lstrip('({')
            # peel trailing grouping / terminators, but never the `}` that
            # closes a ${...} expansion (else `cd ${VAR}` becomes unresolvable).
            while tok and tok[-1] in ')};':
                if tok[-1] == '}' and '${' in tok:
                    break
                tok = tok[:-1]
            if tok:
                out.append(tok)
        return out

    WRAPPERS  = {'sudo', 'env', 'nice', 'ionice', 'nohup', 'time', 'timeout',
                 'command', 'builtin', 'exec', 'stdbuf', 'setsid', 'doas', 'busybox'}
    # wrapper flags that consume the following token as their value
    ARG_TAKING = {'-u', '-g', '-C', '-p', '-r', '-t', '-U', '-S', '-k', '-s',
                  '-n', '-o', '-e', '-P', '-L', '-w'}
    SHELLS = {'sh', 'bash', 'zsh', 'dash', 'ksh', 'ash'}

    def verb_and_args(toks, assigns):
        i = 0
        # record + skip leading VAR=val assignments (expanding the value against
        # vars seen so far, so `M=/x; D=$M; cd $D` chains resolve).
        while i < len(toks) and ENV_RE.match(toks[i]):
            k, _, v = toks[i].partition('=')
            ev, ok = expand(v, assigns)
            assigns[k] = ev if ok else v
            i += 1
        # peel command wrappers (sudo/env/timeout/...), possibly nested
        guard = 0
        while i < len(toks) and guard < 12:
            guard += 1
            base = os.path.basename(toks[i])
            if base not in WRAPPERS:
                break
            i += 1
            if base == 'env':
                # `env -S "<cmd>"` / --split-string runs the string as a command;
                # hand it to the shell-recursion path rather than swallowing it.
                j = i
                while j < len(toks):
                    a = toks[j]
                    if a in ('-S', '--split-string'):
                        return ('sh', ['-c', toks[j + 1]]) if j + 1 < len(toks) else (None, [])
                    if a.startswith('-S') and len(a) > 2:
                        return 'sh', ['-c', a[2:]]
                    if a.startswith('--split-string='):
                        return 'sh', ['-c', a.split('=', 1)[1]]
                    if a.startswith('-') or ENV_RE.match(a):
                        if a in ARG_TAKING and j + 1 < len(toks):
                            j += 1
                        j += 1
                        continue
                    break
                # no -S → fall through to the generic flag-skip below
            if base == 'busybox':
                # next non-flag token is the applet → treat as the verb
                while i < len(toks) and toks[i].startswith('-'):
                    i += 1
                break
            # skip this wrapper's own flags + env assignments
            while i < len(toks) and (toks[i].startswith('-') or ENV_RE.match(toks[i])):
                f = toks[i]; i += 1
                if f in ARG_TAKING and i < len(toks):
                    i += 1
            if base == 'timeout' and i < len(toks) and not toks[i].startswith('-'):
                i += 1   # the DURATION positional
        if i >= len(toks):
            return None, []
        return os.path.basename(toks[i]), toks[i + 1:]

    def operands(args):
        out, skip = [], False
        for t in args:
            if skip:
                skip = False
                continue
            if REDIR_TOK.match(t):
                skip = True
                continue
            if t == '--' or t.startswith('-'):
                continue
            out.append(t)
        return out

    def copy_dest(args):
        i = 0
        while i < len(args):
            if args[i] == '-t' and i + 1 < len(args):
                return args[i + 1]
            if args[i].startswith('--target-directory='):
                return args[i].split('=', 1)[1]
            i += 1
        ops = operands(args)
        return ops[-1] if ops else None

    COPY_DEST = {'cp', 'rsync', 'install', 'ln'}
    ALL_OPS   = {'mv', 'rm', 'rmdir', 'shred', 'unlink', 'truncate', 'mkdir',
                 'touch', 'mkfifo', 'mknod', 'chmod', 'chown', 'chgrp', 'tee'}
    AWK       = {'awk', 'gawk', 'mawk'}
    EDITORS   = {'ed', 'ex', 'vi', 'vim', 'view'}
    # verbs that, when invoked by find -exec / xargs, mean "this deletes/writes"
    WRITE_VERB_NAMES = ALL_OPS | COPY_DEST | {'dd', 'sed', 'patch', 'sh', 'bash', 'tee'}

    def find_targets(args):
        # find ROOT… [tests] [-delete | -exec CMD … ;|+]
        roots = []
        for a in args:
            if a.startswith('-'):
                break
            roots.append(a)
        if not roots:
            roots = ['.']
        root0 = roots[0]
        targets = []
        # -delete rewrites/removes the matched files (which live under the roots)
        if '-delete' in args:
            targets.extend(roots)
        # -exec/-execdir/-ok/-okdir CMD … : evaluate the sub-command's OWN write
        # targets, mapping the `{}` placeholder to a matched file (under root0).
        # This blocks `find MAIN -exec rm/sed -i {}` and `-exec cp {} MAIN/dst`,
        # but allows `find MAIN -exec cp {} ./` (read-from-main → write-into-WT)
        # and read-only `-exec cat/grep {}`.
        i = 0
        while i < len(args):
            if args[i] in ('-exec', '-execdir', '-ok', '-okdir'):
                j = i + 1
                sub = []
                while j < len(args) and args[j] not in (';', '+'):
                    sub.append(root0 if args[j] == '{}' else args[j].replace('{}', root0))
                    j += 1
                if sub:
                    ev, ev_args = verb_and_args(sub, {})
                    if ev and ev != 'find':
                        targets.extend(compute_targets(ev, ev_args, ' '.join(sub)))
                i = j
            else:
                i += 1
        return targets

    def patch_targets(args):
        for k, a in enumerate(args):
            if a in ('-d', '--directory') and k + 1 < len(args):
                return [args[k + 1]]
            if a.startswith('--directory='):
                return [a.split('=', 1)[1]]
        ops = operands(args)
        if ops:
            return [ops[-1]]
        return ['.']   # `patch < diff` with no operand applies relative to cwd

    def awk_inplace_targets(args):
        if not any(a == '-i' or a.startswith('-i') or a.startswith('--in-place') or a == 'inplace' for a in args):
            return []
        ops = [o for o in operands(args) if o != 'inplace']
        return ops[1:]   # drop the program text (first remaining operand)

    def editor_targets(verb, args):
        if verb == 'ed':
            return operands(args)
        # ex/vi/vim/view: only when driven non-interactively
        if any(a.startswith('-') and (set('escS') & set(a[1:])) for a in args) or '-c' in args:
            ops = operands(args)
            return ops[-1:] if ops else []
        return []

    def tar_targets(args):
        # extract → -C dir (default cwd); create → archive file. `tar tf` (list)
        # writes nothing. Reading a main archive while writing locally stays OK.
        flagset = "".join(a for a in args if a.startswith('-'))
        first = args[0] if args else ''
        bare = first if (first and not first.startswith('-')
                         and re.match(r'^[A-Za-z]+$', first)) else ''
        allflags = flagset + bare
        is_x = '--extract' in args or 'x' in allflags
        is_c = '--create' in args or 'c' in allflags
        cdir = ffile = None
        i = 0
        while i < len(args):
            a = args[i]
            if a in ('-C', '--directory') and i + 1 < len(args):
                cdir = args[i + 1]; i += 2; continue
            if a.startswith('--directory='):
                cdir = a.split('=', 1)[1]
            if a in ('-f', '--file') and i + 1 < len(args):
                ffile = args[i + 1]; i += 2; continue
            if a.startswith('--file='):
                ffile = a.split('=', 1)[1]
            i += 1
        # combined-flag form `tar czf FILE …` / `-czf FILE …`: the archive is the
        # first non-flag positional (skipping a leading bare flag cluster).
        if ffile is None and 'f' in allflags:
            for a in (args[1:] if bare else args):
                if not a.startswith('-'):
                    ffile = a
                    break
        out = []
        if is_x and cdir:
            out.append(cdir)
        if is_c and ffile:
            out.append(ffile)
        return out

    def compute_targets(verb, args, seg):
        if verb in COPY_DEST:
            d = copy_dest(args)
            return [d] if d else []
        if verb in ALL_OPS:
            return operands(args)
        if verb == 'dd':
            for a in args:
                if a.startswith('of='):
                    return [a[3:]]
            return []
        if verb == 'sed':
            if any(a == '-i' or a.startswith('-i') or a.startswith('--in-place') for a in args):
                ops = operands(args)
                return ops[1:]
            return []
        if verb == 'perl':
            flags = [a for a in args if a.startswith('-')]
            if any('i' in f for f in flags):
                ops = operands(args)
                if any('e' in f for f in flags):
                    ops = ops[1:]
                return ops
            return []
        if verb == 'find':
            return find_targets(args)
        if verb == 'patch':
            return patch_targets(args)
        if verb in AWK:
            return awk_inplace_targets(args)
        if verb in EDITORS:
            return editor_targets(verb, args)
        if verb == 'sort':
            for k, a in enumerate(args):
                if a == '-o' and k + 1 < len(args):
                    return [args[k + 1]]
                if a.startswith('--output='):
                    return [a.split('=', 1)[1]]
            return []
        if verb == 'unzip':
            for k, a in enumerate(args):
                if a == '-d' and k + 1 < len(args):
                    return [args[k + 1]]
            return []
        if verb == 'tar':
            return tar_targets(args)
        return []

    def xargs_inner_cmd(args):
        # Skip xargs' own flags, return (inner_verb, inner_args).
        i = 0
        XARGS_ARG = {'-I', '-i', '-P', '-n', '-s', '-L', '-l', '-d', '-E', '-a',
                     '--max-procs', '--max-args', '--replace', '--delimiter',
                     '--max-lines', '--arg-file'}
        while i < len(args):
            a = args[i]
            if a.startswith('-'):
                if a in XARGS_ARG and i + 1 < len(args):
                    i += 2
                else:
                    i += 1
                continue
            return os.path.basename(a), args[i + 1:]
        return None, []

    def paren_split(seg):
        # Consume leading '(' (subshell opens), then split the rest at top-level
        # ')' into (text, num_closes_after) chunks. Quote/escape aware. A cd that
        # happens inside a ( … ) subshell must NOT leak to a redirect lexically
        # outside the parens — the caller pushes eff_cwd on each open and pops on
        # each close so `(cd MAIN && cat x) > wtfile` resolves wtfile in the WT.
        i, n = 0, len(seg)
        opens = 0
        while i < n and seg[i] in '( \t':
            if seg[i] == '(':
                opens += 1
            i += 1
        chunks, buf, depth = [], '', 0
        while i < n:
            c = seg[i]
            if c in ('"', "'"):
                q = c; buf += c; i += 1
                while i < n and seg[i] != q:
                    if seg[i] == '\\' and i + 1 < n:
                        buf += seg[i:i+2]; i += 2; continue
                    buf += seg[i]; i += 1
                if i < n:
                    buf += seg[i]; i += 1
                continue
            if c == '\\':
                buf += seg[i:i+2] if i + 1 < n else c
                i += 2 if i + 1 < n else 1
                continue
            if c == '(':
                depth += 1; buf += c; i += 1; continue
            if c == ')':
                if depth > 0:
                    depth -= 1; buf += c; i += 1; continue
                cnt = 0
                while i < n and seg[i] in ') \t':
                    if seg[i] == ')':
                        cnt += 1
                    i += 1
                chunks.append((buf, cnt)); buf = ''
                continue
            buf += c; i += 1
        chunks.append((buf, 0))
        return opens, chunks

    MAX_DEPTH = 24

    def analyze(command, eff_cwd, depth, all_tokens, inherited=None):
        if depth > MAX_DEPTH:
            # >24 nested shell wrappers is never a legitimate command — rather
            # than fail open (and let the leaf write slip past), fail CLOSED.
            return ('nested-shell', command[:60], '')
        assigns = dict(inherited) if inherited else {}
        cwd_stack = []
        for seg in split_segments(command):
            opens, chunks = paren_split(seg)
            for _ in range(opens):
                cwd_stack.append(eff_cwd)
            for (text, closes) in chunks:
                text = text.strip()
                toks = tokens_of(text) if text else []
                if toks:
                    all_tokens.extend(toks)
                    # redirects bind at the CURRENT eff_cwd (after any ')' that
                    # preceded this chunk has already popped).
                    for rt in redirect_targets(text):
                        rp = resolve(rt, eff_cwd, assigns)
                        if outside_sensitive(rp):
                            return ('redirect', rt, rp)

                    verb, args = verb_and_args(toks, assigns)
                    if verb is not None:
                        # recurse into `sh -c "…"` / `bash -c "…"` / eval "…"
                        # (the body is expanded by THIS shell, so parent VAR=val
                        # bindings apply — thread `assigns` in).
                        if verb in SHELLS and '-c' in args:
                            k = args.index('-c')
                            if k + 1 < len(args):
                                b = analyze(args[k + 1], eff_cwd, depth + 1, all_tokens, assigns)
                                if b:
                                    return b
                        elif verb == 'eval':
                            b = analyze(' '.join(args), eff_cwd, depth + 1, all_tokens, assigns)
                            if b:
                                return b
                        elif verb == 'xargs':
                            ivb, iv_args = xargs_inner_cmd(args)
                            if ivb in COPY_DEST:
                                # the SOURCE comes from stdin (a read); only the
                                # copy DESTINATION is a write target.
                                d = copy_dest(iv_args)
                                rp = resolve(d, eff_cwd, assigns) if d else None
                                if outside_sensitive(rp):
                                    return ('xargs ' + ivb, d, rp)
                            elif ivb and ivb in WRITE_VERB_NAMES:
                                # rm/mv/sed -i/… operate on the stdin paths; block
                                # if any literal path in the pipeline is outside.
                                for tk in all_tokens:
                                    rp = resolve(tk, eff_cwd, assigns)
                                    if outside_sensitive(rp):
                                        return ('xargs ' + ivb, tk, rp)
                        else:
                            for t in compute_targets(verb, args, text):
                                rp = (resolve_for_delete(t, eff_cwd, assigns)
                                      if verb in DELETION_OPS
                                      else resolve(t, eff_cwd, assigns))
                                if outside_sensitive(rp):
                                    return (verb, t, rp)
                            # cd/pushd update eff_cwd for SUBSEQUENT chunks/segments
                            if verb in ('cd', 'pushd'):
                                ops = operands(args)
                                cand = ops[0] if ops else None
                                if cand == '-':
                                    pass
                                elif cand is None:
                                    if verb == 'cd':
                                        eff_cwd = os.path.expanduser('~')
                                else:
                                    nc = resolve(cand, eff_cwd, assigns)
                                    if nc:
                                        eff_cwd = nc
                # closing this chunk's subshell(s) restores the outer cwd
                for _ in range(closes):
                    if cwd_stack:
                        eff_cwd = cwd_stack.pop()
        return None

    block = analyze(strip_heredocs(cmd), start_cwd, 0, [])
    if block:
        verb, raw, resolved = block
        sys.stdout.write("\t".join([verb or "", raw or "", resolved or ""]))
except Exception:
    pass
PYEOF
)

  if [[ -n "$BLOCK_OUT" ]]; then
    VERB="${BLOCK_OUT%%$'\t'*}"
    REST="${BLOCK_OUT#*$'\t'}"
    RAW="${REST%%$'\t'*}"
    if [[ "$VERB" == "redirect" ]]; then
      DETAIL="redirects output to a file in the source branch checkout (or a sibling worktree): ${RAW}"
    elif [[ "$VERB" == "nested-shell" ]]; then
      DETAIL="nests shell wrappers (sh -c / bash -c / eval) too deeply to analyze safely: ${RAW}"
    else
      DETAIL="runs \`${VERB}\` writing to the source branch checkout (or a sibling worktree): ${RAW}"
    fi
    cat >&2 << EOF
BLOCKED by mentor worktree-confine.
This agent must stay inside its worktree:
  ${WT_ROOT_CANON}
The Bash command ${DETAIL}
Navigation (cd / git -C) and git worktree lifecycle (git worktree remove/prune, git branch -d) are allowed — only content writes outside the worktree are blocked.
If you genuinely need to write to the parent project, exit the worktree first via ExitWorktree, or invoke /ship to merge back into the source branch.
EOF
    exit 2
  fi

  exit 0
fi

exit 0
