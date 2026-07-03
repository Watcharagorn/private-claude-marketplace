#!/usr/bin/env bash
# plan-phase-gate.sh — PreToolUse:Write|Edit|NotebookEdit|Bash
#
# The fail-closed edit gate for the plugin-OWNED plan harness. Unlike
# block-edits-in-plan-mode.sh (which keys off permission_mode == "plan"), this
# gate keys off a repo-scoped `.planning` MARKER, so it works under
# bypassPermissions: PreToolUse hooks deny independently of permission mode
# (mode governs prompts; hooks govern allow/deny).
#
# While the marker is present:
#   • Write/Edit/NotebookEdit: ALLOW only targets OUTSIDE the repo working tree
#     (the plan file lives under ~/.claude/mentor/<repo>-<hash>/plans/). Any
#     in-repo target — or an unresolvable/absent path — is DENIED. FAIL-CLOSED.
#   • Bash: a write-path analyzer (adapted from worktree-confine.sh, scoped so the
#     repo working tree is the sensitive root) blocks commands that write into the
#     repo; reads / grep / git-read / navigation are allowed. BEST-EFFORT — the
#     same caveats as worktree-confine.sh apply (an obfuscated interpreter
#     one-liner can slip a heuristic). Write/Edit cover Claude's near-universal
#     edit path and ARE fully fail-closed.
#
# Staleness: a marker older than 8h is treated as released (a crashed planning
# session must never permanently lock out editing) — the marker is removed and
# the call allowed.
#
# No marker → exit 0 (not planning). Cannot resolve the repo/marker → exit 0
# (nothing to protect). Exit 2 = block (stderr shown to the agent).

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL_NAME" in
  Write|Edit|NotebookEdit|Bash) ;;
  *) exit 0 ;;
esac

CWD="$(mentor_cwd "$INPUT")"

# --- resolve the repo-scoped plans dir + marker (lib/state.sh, matches strategy-guard.sh) ---
repo_root_common="$(mentor_repo_root "$CWD")"
[ -z "$repo_root_common" ] && exit 0
plans_dir="$(mentor_plans_dir "$repo_root_common")"
marker="${plans_dir}/.planning"

# No marker → not planning → allow.
[ -f "$marker" ] || exit 0

# Stale marker (>8h) → treat as released; self-heal and allow.
if [ -n "$(find "$marker" -mmin +480 2>/dev/null)" ]; then
  rm -f "$marker" "${plans_dir}/.research-dispatched" "${plans_dir}/.plan-authored" "${plans_dir}/.read-budget" 2>/dev/null || true
  exit 0
fi

# The working-tree root to protect (writes anywhere inside it are denied while planning).
REPO_WT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$REPO_WT" ] && REPO_WT="$repo_root_common"

# Canonicalize without requiring the path to exist (new-file writes are the common
# case). macOS BSD `realpath` lacks -m and fails on non-existent paths, so fall back
# to python's os.path.realpath (resolves the existing prefix) — mirrors worktree-confine.sh.
_canon() {
  local p="${1/#\~/$HOME}"     # expand leading ~ to $HOME before realpath
  realpath -m -- "$p" 2>/dev/null && return 0
  realpath -- "$p" 2>/dev/null && return 0
  python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null && return 0
  echo "$p"
}
REPO_CANON="$(_canon "$REPO_WT")"

# ---------------------------------------------------------------------------
# Write / Edit / NotebookEdit — FAIL-CLOSED
# ---------------------------------------------------------------------------
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "NotebookEdit" ]; then
  FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)" || true
  if [ -n "$FILE_PATH" ]; then
    FILE_CANON="$(_canon "$FILE_PATH")"
    case "$FILE_CANON" in
      "$REPO_CANON"|"${REPO_CANON}/"*) ;;   # inside repo → deny (fall through)
      *) exit 0 ;;                          # outside repo (the plan file, /tmp, …) → allow
    esac
  fi
  # empty path (unresolvable) OR inside-repo → deny (fail-closed).
  cat >&2 << EOF
BLOCKED by mentor: PLAN PHASE is active — approve the plan first.

  ${FILE_PATH:-<no path>}

The plugin-owned plan gate (the .planning marker) blocks edits to any file in the
repo working tree until the plan is approved through the mentor-plan skill
(approve-plan.sh validates the plan, then releases the gate). This holds even under
bypassPermissions — a PreToolUse hook denies regardless of permission mode.

During planning the ONLY file you write is the persisted plan (a styled .html or a
Mermaid-first .md, per /mentor:plan-output-format) under
  ${plans_dir}/<slug>.{html|md}
(outside the repo — always allowed). Finish the plan, choose "Proceed" (which runs
approve-plan.sh), and edit/implement only AFTER approval.
EOF
  exit 2
fi

# ---------------------------------------------------------------------------
# Bash — BEST-EFFORT write-path analysis, scoped to the repo working tree.
# One Python pass classifies the command; it blocks iff a file-content WRITE
# target resolves inside the repo. Reads / grep / git / navigation → allow.
# Any internal error prints nothing → fail-open for Bash.
# ---------------------------------------------------------------------------
BASH_CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
[ -z "$BASH_CMD" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0   # no python → fail-open

BLOCK_OUT="$(python3 - "$BASH_CMD" "$CWD" "$REPO_CANON" 2>/dev/null << 'PYEOF' || true
import sys, os, shlex, re

try:
    cmd       = sys.argv[1] if len(sys.argv) > 1 else ""
    start_cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    repo_root = sys.argv[3] if len(sys.argv) > 3 else ""

    if not start_cwd:
        start_cwd = os.getcwd()

    # ── path canonicalization + sensitivity ────────────────────────────────
    def under(path, root):
        if not root or path is None:
            return False
        root = root.rstrip("/")
        return path == root or path.startswith(root + "/")

    def is_sensitive(path):
        # During the plan phase, ANY write landing inside the repo working tree
        # is blocked. Writes outside it (the plan file, /tmp, …) are fine.
        if path is None:
            return False
        return under(path, repo_root)

    ENV_RE   = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
    REDIR_TOK = re.compile(r'^[0-9]*&?>>?\|?$|^[0-9]*<$')
    VAR_RE   = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)')

    def expand(tok, assigns):
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
            if c == '>':
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
                if j < n and seg[j] == '>':
                    j += 1
                if j < n and seg[j] == '|':
                    j += 1
                while j < n and seg[j] in (' ', '\t'):
                    j += 1
                if j < n and seg[j] == '&':
                    k = j + 1
                    while k < n and seg[k] in (' ', '\t'):
                        k += 1
                    if k >= n or seg[k].isdigit() or seg[k] == '-':
                        i = j + 1
                        continue
                    j = k
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
        out = []
        for tok in t:
            if tok in ('(', ')', '{', '}', ';', '&', 'then', 'do', 'else', 'fi', 'done'):
                continue
            if tok == '{}':
                out.append(tok); continue
            tok = tok.lstrip('({')
            while tok and tok[-1] in ')};':
                if tok[-1] == '}' and '${' in tok:
                    break
                tok = tok[:-1]
            if tok:
                out.append(tok)
        return out

    WRAPPERS  = {'sudo', 'env', 'nice', 'ionice', 'nohup', 'time', 'timeout',
                 'command', 'builtin', 'exec', 'stdbuf', 'setsid', 'doas', 'busybox'}
    ARG_TAKING = {'-u', '-g', '-C', '-p', '-r', '-t', '-U', '-S', '-k', '-s',
                  '-n', '-o', '-e', '-P', '-L', '-w'}
    SHELLS = {'sh', 'bash', 'zsh', 'dash', 'ksh', 'ash'}

    def verb_and_args(toks, assigns):
        i = 0
        while i < len(toks) and ENV_RE.match(toks[i]):
            k, _, v = toks[i].partition('=')
            ev, ok = expand(v, assigns)
            assigns[k] = ev if ok else v
            i += 1
        guard = 0
        while i < len(toks) and guard < 12:
            guard += 1
            base = os.path.basename(toks[i])
            if base not in WRAPPERS:
                break
            i += 1
            if base == 'env':
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
            if base == 'busybox':
                while i < len(toks) and toks[i].startswith('-'):
                    i += 1
                break
            while i < len(toks) and (toks[i].startswith('-') or ENV_RE.match(toks[i])):
                f = toks[i]; i += 1
                if f in ARG_TAKING and i < len(toks):
                    i += 1
            if base == 'timeout' and i < len(toks) and not toks[i].startswith('-'):
                i += 1
        if i >= len(toks):
            return None, []
        return os.path.basename(toks[i]), toks[i + 1:]

    def operands(args, valflags=()):
        out, skip = [], False
        for t in args:
            if skip:
                skip = False
                continue
            if REDIR_TOK.match(t) or t in valflags:
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
    WRITE_VERB_NAMES = ALL_OPS | COPY_DEST | {'dd', 'sed', 'patch', 'sh', 'bash', 'tee'}

    def find_targets(args):
        roots = []
        for a in args:
            if a.startswith('-'):
                break
            roots.append(a)
        if not roots:
            roots = ['.']
        root0 = roots[0]
        targets = []
        if '-delete' in args:
            targets.extend(roots)
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
        return ['.']

    def awk_inplace_targets(args):
        if not any(a == '-i' or a.startswith('-i') or a.startswith('--in-place') or a == 'inplace' for a in args):
            return []
        ops = [o for o in operands(args) if o != 'inplace']
        return ops[1:]

    def editor_targets(verb, args):
        if verb == 'ed':
            return operands(args)
        if any(a.startswith('-') and (set('escS') & set(a[1:])) for a in args) or '-c' in args:
            ops = operands(args)
            return ops[-1:] if ops else []
        return []

    def tar_targets(args):
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
        if verb == 'mkdir':
            # `-m MODE` / `--mode MODE` take a value that must NOT be read as a path
            # (else `mkdir -p -m 700 dir` treats `700` as a repo-relative target).
            return operands(args, ('-m', '--mode'))
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
                    for rt in redirect_targets(text):
                        rp = resolve(rt, eff_cwd, assigns)
                        if is_sensitive(rp):
                            return ('redirect', rt, rp)

                    verb, args = verb_and_args(toks, assigns)
                    if verb is not None:
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
                                d = copy_dest(iv_args)
                                rp = resolve(d, eff_cwd, assigns) if d else None
                                if is_sensitive(rp):
                                    return ('xargs ' + ivb, d, rp)
                            elif ivb and ivb in WRITE_VERB_NAMES:
                                for tk in all_tokens:
                                    rp = resolve(tk, eff_cwd, assigns)
                                    if is_sensitive(rp):
                                        return ('xargs ' + ivb, tk, rp)
                        else:
                            for t in compute_targets(verb, args, text):
                                rp = (resolve_for_delete(t, eff_cwd, assigns)
                                      if verb in DELETION_OPS
                                      else resolve(t, eff_cwd, assigns))
                                if is_sensitive(rp):
                                    return (verb, t, rp)
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
)"

if [ -n "$BLOCK_OUT" ]; then
  VERB="${BLOCK_OUT%%$'\t'*}"
  REST="${BLOCK_OUT#*$'\t'}"
  RAW="${REST%%$'\t'*}"
  if [ "$VERB" = "redirect" ]; then
    DETAIL="redirects output into the repo working tree: ${RAW}"
  elif [ "$VERB" = "nested-shell" ]; then
    DETAIL="nests shell wrappers too deeply to analyze safely: ${RAW}"
  else
    DETAIL="runs \`${VERB}\` writing into the repo working tree: ${RAW}"
  fi
  cat >&2 << EOF
BLOCKED by mentor: PLAN PHASE is active — approve the plan first.

The Bash command ${DETAIL}

The plugin-owned plan gate (.planning marker) blocks repo-mutating commands until
the plan is approved (approve-plan.sh). Reads, grep, git, and navigation are fine —
only writes into the repo working tree are blocked. Finish the plan, choose
"Proceed", and run repo-mutating commands only AFTER approval.
EOF
  exit 2
fi

exit 0
