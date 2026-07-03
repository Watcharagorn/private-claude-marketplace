#!/usr/bin/env bash
# orchestrator-gate.sh — PreToolUse:Read|Grep|Glob|Write|Edit|MultiEdit|NotebookEdit|Bash
#
# The SESSION-WIDE always-orchestrate gate for "orchestrator" mode (generalizes the
# plan-phase floors to the whole session). When it is ON, the MAIN conversation
# is forced to be a pure orchestrator: it dispatches subagents for all substantive work
# and does no heavy lifting itself. SUBAGENTS run every tool freely (no deadlock).
#
# ON iff mentor_orchestrator_on resolves true — an orthogonal toggle in config.json
# (repo explicit > legacy mode:commander > global ~/.claude/mentor/config.json). It is
# NOT a working mode; see set-orchestrator.sh / /mentor:orchestrator.
#
# Enforcement (main conversation only):
#   • Write/Edit/MultiEdit/NotebookEdit into the repo working tree → BLOCK (exit 2).
#     Writes OUTSIDE the repo (plan file, /tmp, $HOME) → allow. Unresolvable path →
#     fail-OPEN (allow) — session-wide scope must not surprise-lock legitimate writes.
#   • Bash that writes into the repo working tree → BLOCK (reuses plan-phase-gate's
#     python write-path analyzer, minus repo-relative artifact dirs like node_modules/
#     dist/coverage). Read-only / git / gh / test / build / navigation → allow.
#   • Read/Grep/Glob: ~FREE (default 3) in-repo reads/turn to orient, then BLOCK until a
#     subagent is dispatched this turn — at which point reads UNLOCK (the dispatched flag,
#     set by orchestrator-dispatch-tracker.sh). Reads OUTSIDE the repo (returned artifacts,
#     /tmp, ~/.claude/mentor) are always allowed and never counted. The counter resets
#     each turn (orchestrator-prompt.sh), so a block is never permanent.
#
# Deferral (exit 0) — plugin-owned flows own enforcement, so the gate steps aside when:
#   • a fresh `.planning` marker is present (the plan harness),
#   • a fresh `/tmp/mentor-flow-active-<session_id>` flag is present (/ship, /mentor:harvest,
#     /simplify), or
#   • cwd is inside a mentor-managed worktree (.git/worktrees/<n>/mentor.json).
#
# Subagent detection (positive-signal, fail-open): a call is from a subagent iff
# `agent_id` is non-empty OR `transcript_path` matches */subagents/*. The main
# conversation has neither (transcript_path present but not a /subagents/ path). A
# genuine parse failure (no transcript_path) fails OPEN. A false negative here would
# deadlock the whole mode, so both signals are checked.
#
# Fail-open on missing jq / unparseable input / (Bash) missing python3. Exit 2 = block.

set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL_NAME" in
  Read|Grep|Glob|Write|Edit|MultiEdit|NotebookEdit|Bash) ;;
  *) exit 0 ;;
esac

SESSION_ID="$(mentor_session_id "$INPUT")"
CWD="$(mentor_cwd "$INPUT")"

# --- orchestrator on? (resolved repo/global toggle; no repo → nothing to gate) ---
repo_root_common="$(mentor_repo_root "$CWD")"
[ -n "$repo_root_common" ] || exit 0
mentor_orchestrator_on "$repo_root_common" || exit 0

# --- subagent? → allow (run freely) ---
AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)" || AGENT_ID=""
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || TRANSCRIPT=""
[ -n "$AGENT_ID" ] && exit 0
case "$TRANSCRIPT" in */subagents/*) exit 0 ;; esac
[ -z "$TRANSCRIPT" ] && exit 0                    # can't tell → fail-open

# --- repo working tree (the sensitive root). No repo → nothing to gate → allow. ---
REPO_WT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$REPO_WT" ] && exit 0

# Canonicalize without requiring existence (new-file writes are common). macOS BSD
# realpath lacks -m; fall back to python. Mirrors plan-phase-gate.sh.
_canon() {
  realpath -m -- "$1" 2>/dev/null && return 0
  realpath -- "$1" 2>/dev/null && return 0
  python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1" 2>/dev/null && return 0
  echo "$1"
}
REPO_CANON="$(_canon "$REPO_WT")"

# ---------------------------------------------------------------------------
# Exemptions — plugin-owned flows own enforcement; the gate defers (exit 0).
# ---------------------------------------------------------------------------
# 1. plan harness: a fresh .planning marker in the repo-scoped plans dir.
plans_dir="$(mentor_plans_dir "$repo_root_common")"
if mentor_marker_fresh "${plans_dir}/.planning"; then
  exit 0
fi
# 2. /ship · /mentor:harvest · /simplify flow flag (fresh < 60 min).
FLOW="/tmp/mentor-flow-active-${SESSION_ID}"
if [ -f "$FLOW" ] && [ -z "$(find "$FLOW" -mmin +60 2>/dev/null)" ]; then
  exit 0
fi
# 3. inside a mentor-managed worktree (ship/simplify run from the main thread there).
git_dir="$(git -C "$CWD" rev-parse --git-dir 2>/dev/null || true)"
if [ -n "$git_dir" ]; then
  case "$git_dir" in
    /*) : ;;
    *)  git_dir="$(cd "$CWD" 2>/dev/null && cd "$git_dir" 2>/dev/null && pwd || true)" ;;
  esac
  [ -n "$git_dir" ] && [ -f "${git_dir}/mentor.json" ] && exit 0
fi

# ---------------------------------------------------------------------------
# Write / Edit / MultiEdit / NotebookEdit — block in-repo, allow outside.
# ---------------------------------------------------------------------------
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "MultiEdit" ] || [ "$TOOL_NAME" = "NotebookEdit" ]; then
  FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)" || true
  [ -z "$FILE_PATH" ] && exit 0                   # unresolvable → fail-open (session-wide)
  FILE_CANON="$(_canon "$FILE_PATH")"
  case "$FILE_CANON" in
    "$REPO_CANON"|"${REPO_CANON}/"*) ;;           # inside repo → block (fall through)
    *) exit 0 ;;                                  # outside repo → allow
  esac
  cat >&2 << EOF
BLOCKED by mentor: orchestrator mode is ON — implementation is always delegated.

  ${TOOL_NAME}: ${FILE_PATH}

Do NOT retry this tool — it will keep being blocked. In orchestrator mode the main thread
does not edit the repo; a SUBAGENT does.

Recover now:
  • Were you AUTHORING A PLAN (not source)? Do NOT persist it into the repo. Run /mentor:plan —
    it is gate-exempt and persists its plan (HTML or Markdown) OUTSIDE the repo (~/.claude/mentor/<repo>-<hash>/plans/).
    Only for non-plan notes: deliver them inline for the user instead. For a real CODE change:
  • Dispatch ONE implementation agent (Agent/Task) to make THIS change — the agent, not
    you, performs the edit. See Skill(skill="dispatch-agents") for role/model/effort.
  • Give it a STANDALONE prompt: the goal, the exact file(s)/change, the surrounding
    context (it cannot see this conversation), conventions to follow, a Done-when, and
    "run the relevant check (tests/typecheck/build) and report the diff."
  • When it returns, VERIFY: read the diff / changed file yourself and rerun the check.
    Do not accept "done" on its word.

Read-only work (git, gh, tests, builds, cat/grep, reading returned artifacts) stays
allowed. Escape hatch: /mentor:orchestrator off (repo-wide).
EOF
  exit 2
fi

# ---------------------------------------------------------------------------
# Read / Grep / Glob — per-turn budget + dispatch step-aside. In-repo reads only.
# ---------------------------------------------------------------------------
if [ "$TOOL_NAME" = "Read" ] || [ "$TOOL_NAME" = "Grep" ] || [ "$TOOL_NAME" = "Glob" ]; then
  RPATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null)" || true
  if [ -n "$RPATH" ]; then
    RCANON="$(_canon "$RPATH")"
    case "$RCANON" in
      "$REPO_CANON"|"${REPO_CANON}/"*) ;;         # in-repo → counts (fall through)
      *) exit 0 ;;                                # outside repo (/tmp, ~/.claude/mentor, …) → allow, uncounted
    esac
  fi
  # Already dispatched this turn → step aside (verify/coordinate freely).
  DISPATCHED="/tmp/mentor-orchestrator-dispatched-${SESSION_ID}"
  [ -f "$DISPATCHED" ] && exit 0
  # Per-turn read budget.
  FREE="${MENTOR_ORCHESTRATOR_READ_FREE:-3}"
  case "$FREE" in ''|*[!0-9]*) FREE=3 ;; esac
  BUDGET="/tmp/mentor-orchestrator-read-budget-${SESSION_ID}"
  count="$(cat "$BUDGET" 2>/dev/null || echo 0)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -ge "$FREE" ]; then
    cat >&2 << EOF
BLOCKED by mentor: orchestrator mode is ON — delegate the bulk reading.

You've taken ${count} in-repo reads this turn to orient. Further codebase reading must be
DELEGATED so the main conversation stays lean and acts as orchestrator, not analyst.

Recover now:
  • Dispatch Explore agent(s) over the area(s) you need — parallel, one per disjoint area,
    in a single message. Ask each for FINDINGS (≤~400 words) + EVIDENCE (file:line refs,
    no file dumps) + OPEN QUESTIONS.

This gate STEPS ASIDE the moment you dispatch any Agent/Task this turn — after that, reads
unlock so you can read returned artifacts and verify. The counter resets next turn. Reads of
files outside the repo (/tmp, ~/.claude/mentor, returned artifacts) are never counted.
Escape hatch: /mentor:orchestrator off (repo-wide).
EOF
    exit 2
  fi
  echo "$((count + 1))" > "$BUDGET" 2>/dev/null || true
  exit 0
fi

# ---------------------------------------------------------------------------
# Bash — BEST-EFFORT write-path analysis, sensitive root = repo working tree,
# minus repo-relative artifact dirs (test/build output). One python pass; it
# blocks iff a file-content WRITE target resolves inside the repo (and not in an
# artifact dir). Reads / grep / git / navigation → allow. Internal error → fail-open.
# (Analyzer body mirrors plan-phase-gate.sh / worktree-confine.sh — keep in sync.)
# ---------------------------------------------------------------------------
BASH_CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
[ -z "$BASH_CMD" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0      # no python → fail-open
ARTIFACT_DIRS="${MENTOR_ORCHESTRATOR_ARTIFACT_DIRS:-node_modules,dist,build,coverage,.next,target,__pycache__,.pytest_cache,.gradle,.venv,out}"

BLOCK_OUT="$(python3 - "$BASH_CMD" "$CWD" "$REPO_CANON" "$ARTIFACT_DIRS" 2>/dev/null << 'PYEOF' || true
import sys, os, shlex, re

try:
    cmd       = sys.argv[1] if len(sys.argv) > 1 else ""
    start_cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    repo_root = sys.argv[3] if len(sys.argv) > 3 else ""
    artifact_dirs = [d for d in (sys.argv[4].split(",") if len(sys.argv) > 4 else []) if d]

    if not start_cwd:
        start_cwd = os.getcwd()

    # ── path canonicalization + sensitivity ────────────────────────────────
    def under(path, root):
        if not root or path is None:
            return False
        root = root.rstrip("/")
        return path == root or path.startswith(root + "/")

    def in_artifact(path):
        # A write target is exempt if any path component (relative to the repo
        # root) is a known build/test artifact dir — `coverage/`, `dist/`, etc.
        if not repo_root or path is None or not under(path, repo_root):
            return False
        rel = path[len(repo_root.rstrip("/")):].lstrip("/")
        return any(seg in artifact_dirs for seg in rel.split("/") if seg)

    def is_sensitive(path):
        # During orchestrator mode, a write landing inside the repo working tree is
        # blocked — UNLESS it lands in an artifact dir. Writes outside the repo
        # (the plan file, /tmp, $HOME, …) are fine.
        if path is None:
            return False
        return under(path, repo_root) and not in_artifact(path)

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
        p = e
        if not os.path.isabs(p):
            p = os.path.join(base or start_cwd, p)
        try:
            return os.path.realpath(p)
        except Exception:
            return os.path.normpath(p)

    def strip_heredocs(cmd):
        # Strip heredoc BODIES so their content is never parsed as the command line.
        # Handles: <<TAG, <<'TAG', <<"TAG", <<-TAG (indented terminator), extra tokens
        # after the tag on the opener line (e.g. <<'PY' 2>/dev/null), AND a terminator
        # that ends the command with no trailing newline (the (?:\n|$) anchor). The lazy
        # body match stops at the FIRST terminator, so a real redirect on a command AFTER
        # the heredoc still survives the strip. (Kept in sync with plan-phase-gate.sh /
        # worktree-confine.sh.)
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
                                rp = resolve(t, eff_cwd, assigns)
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
BLOCKED by mentor: orchestrator mode is ON — implementation is always delegated.

The Bash command ${DETAIL}

Do NOT retry this command. In orchestrator mode the main thread does not run repo-mutating
commands; dispatch an implementation agent to perform this change (the agent runs the
command), then verify the result yourself. Read-only commands (git, gh, tests, builds,
cat/grep), navigation, and writes into build/artifact dirs are allowed.
Escape hatch: /mentor:orchestrator off (repo-wide).
EOF
  exit 2
fi

exit 0
