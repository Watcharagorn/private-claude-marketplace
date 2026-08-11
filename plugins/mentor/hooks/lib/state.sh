# lib/state.sh — shared per-repo state derivation for mentor hooks. SOURCED, never executed.
#
# Source from a hook (hooks.json invokes hooks by absolute path, so this resolves):
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"
#
# Layout (v2.11.0 — project-scoped, one directory per plan topic; handoffs and the
# lifecycle-state sidecar live inside it):
#   <repo_root>/.mentor/
#   ├── .gitignore        # commit config.json + constitution.md; ignore transient state
#   ├── config.json       # {"mode": "plan|plan-only", "context_gate", "context_*_tokens", "test_command" ...}
#   ├── constitution.md   # governing principles (committed; managed by /mentor:constitution)
#   ├── plans/            # one .planning.<wt-id> gate marker PER WORKTREE (v2.23.0,
#   │                     #   mentor_worktree_id/mentor_plan_marker below) + one <slug>/
#   │                     #   dir per plan topic, SHARED across every worktree. Bare
#   │                     #   `.planning` (no suffix) is the reserved LEGACY repo-global
#   │                     #   marker — blocks every worktree until released/stale.
#   │   └── <slug>/       #   plan.md (+ hidden .plan.md.opened sidecar)
#   │       ├── .state.json  # {"state","group","order","note","deps","origin","owner",
#   │       │                #   "owner_session"} — written ONLY via plan-state.sh
#   │       │                #   (deps/origin added v2.17.0; owner/owner_session — the
#   │       │                #   minting/re-owning worktree, v2.23.0 — added below; older
#   │       │                #   or mixed-version sidecars read back with any missing key
#   │       │                #   jq-defaulted to []/null/"")
#   │       └── handoffs/ #   <ts>-<slug>.md; solved/superseded notes → handoffs/resolved/
#   ├── zooms/            # mentor:zooming artifacts — <subject-slug>/<topic>-<perspective>.html
#   │                     #   (+ hidden .*.opened sidecars; pre-v2.12 they lived in plans/<slug>/zoom/)
#   └── handoffs/         # legacy flat notes (pre-v2.10 — still read, never written)
#   (.context-warned-<session_id> markers live at the .mentor/ root.)
#   Not inside a git repo → callers fall back to ~/.claude/mentor/_no-repo/.
#
# CONTRACT: callers run under `set -euo pipefail`. Every function here exits with
# status 0. All helpers are fail-soft: bad input echoes empty, never aborts the caller.
# The exceptions are the predicates `mentor_plan_state_valid` and
# `mentor_context_bypassed`, which return 1 for false — always call those from an
# `if`/`&&` condition, never bare.

# mentor_repo_root <cwd> — echo the repo root (main worktree, via git-common-dir,
# so linked worktrees share one state dir). Echoes empty when not in a repo.
mentor_repo_root() {
  local cwd="${1:-$PWD}" git_common common_abs root
  git_common="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -z "$git_common" ]; then echo ""; return 0; fi
  case "$git_common" in
    /*) common_abs="$git_common" ;;
    *)  common_abs="${cwd}/${git_common}" ;;
  esac
  root="$(cd "$(dirname "$common_abs")" 2>/dev/null && pwd || true)"
  echo "$root"
  return 0
}

# mentor_state_dir <repo_root> — echo <repo_root>/.mentor (project-scoped state dir).
# Empty on bad input (callers fall back to ~/.claude/mentor/_no-repo/). Not mkdir'd.
mentor_state_dir() {
  local repo_root="${1:-}"
  if [ -z "$repo_root" ]; then echo ""; return 0; fi
  echo "${repo_root}/.mentor"
  return 0
}

# mentor_plans_dir <repo_root> — echo the plans/markers dir (state_dir/plans). Not mkdir'd.
mentor_plans_dir() {
  local state_dir
  state_dir="$(mentor_state_dir "${1:-}")"
  if [ -z "$state_dir" ]; then echo ""; return 0; fi
  echo "${state_dir}/plans"
  return 0
}

# mentor_worktree_id <cwd> — echo "<name>-<crc>" identifying the git worktree at <cwd>,
# or empty on any git failure (not a repo, bare repo, a cwd inside `.git/`, etc.) —
# callers then fall back to the legacy repo-global marker (see mentor_plan_marker).
#
# name: "main" for the primary worktree, else the `<name>` in `.git/worktrees/<name>`
# (git's own linked-worktree layout). Determined from `--absolute-git-dir`'s PARENT
# BASENAME being exactly "worktrees" — never a substring test on the whole path, which
# would mislabel a repo that merely lives under a directory literally named
# `worktrees/` (e.g. `/tmp/worktrees/myrepo/.git` parent-basename is `myrepo`, not
# `worktrees`, so that repo's primary worktree still gets "main"). Sanitized
# `[^A-Za-z0-9_-] → -` so the id is always marker-filename-safe.
#
# crc: `git rev-parse --show-toplevel | cksum | cut -d' ' -f1` — reproduced here as a
# captured toplevel re-fed through `cksum` (command substitution strips the trailing
# newline `rev-parse` prints, so it's restored before hashing) rather than a second git
# call. `--show-toplevel` is the ONLY sanctioned source: it is the one path form that
# comes back canonical/physical from every derivation site this id is read from (hook
# stdin cwd, `pwd`, symlinked/logical paths, APFS case variance) — `$PWD` and
# `mentor_repo_root`'s output are NOT canonical and must never be hashed instead. The
# `cut` is mandatory: `cksum` emits "<checksum> <byte-count> [file]", and dropping it
# would fold the byte count into the id.
mentor_worktree_id() {
  local cwd="${1:-$PWD}" git_dir parent parent_base name toplevel crc
  git_dir="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -z "$git_dir" ]; then echo ""; return 0; fi
  parent="$(dirname "$git_dir")"
  parent_base="$(basename "$parent")"
  if [ "$parent_base" = "worktrees" ]; then
    name="$(basename "$git_dir")"
  else
    name="main"
  fi
  name="$(printf '%s' "$name" | sed 's/[^A-Za-z0-9_-]/-/g')"
  toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$toplevel" ]; then echo ""; return 0; fi
  crc="$(printf '%s\n' "$toplevel" | cksum | cut -d' ' -f1)"
  if [ -z "$crc" ]; then echo ""; return 0; fi
  echo "${name}-${crc}"
  return 0
}

# mentor_plan_marker <plans_dir> <wt_id> — echo the gate marker path for <wt_id>:
# <plans_dir>/.planning.<wt_id>, or the bare legacy <plans_dir>/.planning when <wt_id>
# is empty. THE ONE fallback site for the empty-wt-id case — every caller that needs a
# worktree's own marker path goes through this function so the fallback can never drift
# between call sites. Empty <plans_dir> → empty.
mentor_plan_marker() {
  local plans_dir="${1:-}" wt_id="${2:-}"
  if [ -z "$plans_dir" ]; then echo ""; return 0; fi
  if [ -z "$wt_id" ]; then echo "${plans_dir}/.planning"; return 0; fi
  echo "${plans_dir}/.planning.${wt_id}"
  return 0
}

# mentor_live_markers <plans_dir> — echo one NON-STALE `.planning*` path per output
# line (both the bare legacy marker and every per-worktree `.planning.<wt-id>` marker),
# using the same staleness convention as everywhere else in this file
# (mentor_marker_stale / MENTOR_PLAN_MARKER_STALE_MIN) so "live" can never mean two
# different things depending on which caller asks. Read-only — never prunes, never
# writes; callers that need to release a marker do so themselves with a named notice
# (the never-release-silently doctrine — see plan-gate.sh). Empty plans_dir or no
# matching files → no output.
mentor_live_markers() {
  local plans_dir="${1:-}" m
  [ -n "$plans_dir" ] && [ -d "$plans_dir" ] || return 0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    mentor_marker_stale "$m" && continue
    echo "$m"
  done < <(find "$plans_dir" -maxdepth 1 -name '.planning*' 2>/dev/null || true)
  return 0
}

# mentor_newest_plan <plans_dir> — echo the current plan file: the mtime-newest
# <plans_dir>/<slug>/plan.md, or empty when none exist. Legacy flat
# <plans_dir>/*.md files are ignored (begin-plan.sh migrates them on arm).
# Plans whose effective state is `superseded` are skipped (v2.4.0): a plan that
# /plan-split replaced with children is no longer "the current plan". When every
# candidate is superseded the newest one is returned anyway, so callers that just
# want "some plan file" never regress to empty.
mentor_newest_plan() {
  local plans_dir="${1:-}" f newest=""
  if [ -z "$plans_dir" ]; then echo ""; return 0; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -n "$newest" ] || newest="$f"
    if [ "$(mentor_plan_effective_state "$(dirname "$f")")" != "superseded" ]; then
      echo "$f"; return 0
    fi
  done < <(ls -t "${plans_dir}"/*/plan.md 2>/dev/null || true)
  echo "$newest"
  return 0
}

# mentor_plan_owner <plan_dir> — echo the sidecar's `owner` (the wt-id that minted or
# last re-owned this plan dir — see the ensure-dir/init/claim stamping sites), or empty
# for unowned (no sidecar / no jq / corrupt / unset / null — including a pre-v2.23.0
# plan dir, or one whose sidecar was rewritten by an older cached plugin copy that
# doesn't know the `owner` key and strips it). Thin wrapper over the generic scalar
# reader, named to match mentor_plan_group/mentor_plan_deps at call sites that read
# ownership alongside the other sidecar fields.
mentor_plan_owner() {
  mentor_plan_state_field "${1:-}" owner
}

# mentor_newest_plan_owned <plans_dir> <wt_id> — mentor_newest_plan's exact walk
# (mtime-newest non-superseded plan.md, falling back to the mtime-newest overall when
# every candidate is superseded), restricted to plan dirs whose owner is <wt_id> or
# unset. A sibling worktree's owned plan is never a candidate here, in EITHER role —
# not as the preferred non-superseded pick, and not as the all-superseded fallback
# either, because the fallback is computed from `newest` which this function only ever
# sets from an already-filtered candidate (unlike mentor_newest_plan, which sets it
# from the very first file the unfiltered walk sees). Without that, an ownership-scoped
# caller (approve-plan, plan-state.sh `current`) could still hand back a sibling's
# superseded plan on the empty-non-superseded-set path — exactly the sweep this
# function exists to prevent. Empty <wt_id> → unfiltered, i.e. behaves identically to
# mentor_newest_plan (repo-wide reads, e.g. `current --any`).
mentor_newest_plan_owned() {
  local plans_dir="${1:-}" wt_id="${2:-}" f owner newest=""
  if [ -z "$plans_dir" ]; then echo ""; return 0; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$wt_id" ]; then
      owner="$(mentor_plan_owner "$(dirname "$f")")"
      if [ -n "$owner" ] && [ "$owner" != "$wt_id" ]; then continue; fi
    fi
    [ -n "$newest" ] || newest="$f"
    if [ "$(mentor_plan_effective_state "$(dirname "$f")")" != "superseded" ]; then
      echo "$f"; return 0
    fi
  done < <(ls -t "${plans_dir}"/*/plan.md 2>/dev/null || true)
  echo "$newest"
  return 0
}

# mentor_newly_planned <plans_dir> <marker> <wt_id> — echo one plan.md path per output
# line: the same `find … -newer "$marker"` snapshot approve-plan.sh takes (plans
# written since <marker> was armed), restricted to the mentor_newest_plan_owned
# ownership filter (owner ∈ {<wt_id>, unset}; empty <wt_id> → unfiltered). Shared by
# approve-plan.sh's promotion sweep and `plan-state.sh gate --verbose`'s
# `affected_plans=` field so the two can never report a different candidate set for
# the same marker. Caller snapshots BEFORE removing the marker, same as before — `find
# -newer` on a gone marker matches everything.
mentor_newly_planned() {
  local plans_dir="${1:-}" marker="${2:-}" wt_id="${3:-}" f owner
  [ -n "$plans_dir" ] && [ -n "$marker" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$wt_id" ]; then
      owner="$(mentor_plan_owner "$(dirname "$f")")"
      if [ -n "$owner" ] && [ "$owner" != "$wt_id" ]; then continue; fi
    fi
    echo "$f"
  done < <(find "$plans_dir" -mindepth 2 -maxdepth 2 -name plan.md -newer "$marker" 2>/dev/null || true)
  return 0
}

# mentor_ensure_gitignore <state_dir> — idempotently write <state_dir>/.gitignore so
# only config.json is committed and transient session state (plans, handoffs, markers)
# stays out of `git status`. Never overwrites an existing file — a user may un-ignore
# plans/ to version-control plans. Fail-soft: bad input / unwritable → status 0.
mentor_ensure_gitignore() {
  local state_dir="${1:-}"
  [ -z "$state_dir" ] && return 0
  [ -e "${state_dir}/.gitignore" ] && return 0
  cat > "${state_dir}/.gitignore" 2>/dev/null <<'GITIGNORE' || true
# mentor — project-scoped state. Committed: config.json, constitution.md (+ this file).
# Ignored: transient session state (plans, handoffs, markers).
*
!.gitignore
!config.json
!constitution.md
GITIGNORE
  return 0
}

# mentor_ensure_private_dir <state_dir> <target_dir> — mkdir -p <target_dir>, then chmod
# 700 every level from <state_dir>/plans down to <target_dir> inclusive.
#
# Why this exists rather than `mkdir -p -m 700`: `-m` applies the mode ONLY to the final
# component, so intermediates land at whatever umask gives (typically 755), and re-running
# it against an already-existing dir is a mode no-op. Every mentor call site creates a
# nested path, so the "700, because plans may carry sensitive paths and snippets" promise
# could never hold as written — and a tree that starts wrong stays wrong forever. Walking
# down from plans/ makes the call self-healing: the next command repairs earlier drift.
#
# <state_dir> itself is deliberately NOT touched — it holds the committed config.json and
# constitution.md, and locking it down would be a behavior change nobody asked for.
# Fail-soft throughout: bad input or an unwritable path returns 0, never breaks a caller.
mentor_ensure_private_dir() {
  local state_dir="${1:-}" target="${2:-}" base rel part cur
  [ -z "$state_dir" ] || [ -z "$target" ] && return 0
  mkdir -p "$target" 2>/dev/null || return 0
  base="${state_dir%/}/plans"
  case "$target" in
    "$base"|"$base"/*) ;;
    *) chmod 700 "$target" 2>/dev/null || true; return 0 ;;   # outside plans/ → leaf only
  esac
  chmod 700 "$base" 2>/dev/null || true
  rel="${target#"$base"}"; rel="${rel#/}"
  cur="$base"
  # `while read -d /` would drop the final part; split on / explicitly instead.
  local IFS=/
  for part in $rel; do
    [ -n "$part" ] || continue
    cur="${cur}/${part}"
    chmod 700 "$cur" 2>/dev/null || true
  done
  return 0
}

# mentor_config_get <repo_root> <key> — echo the string value of config.json[<key>]
# (numbers coerced to text), or empty when no repo / no file / no jq / unset.
mentor_config_get() {
  local repo_root="${1:-}" key="${2:-}" config
  if [ -z "$repo_root" ] || [ -z "$key" ]; then echo ""; return 0; fi
  config="$(mentor_state_dir "$repo_root")/config.json"
  if [ ! -f "$config" ]; then echo ""; return 0; fi
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  jq -r --arg k "$key" '.[$k] // "" | tostring' "$config" 2>/dev/null || true
  return 0
}

# mentor_get_mode <repo_root> — echo the persisted approval-gate default (plan|plan-only)
# or empty when unset / no repo / no jq (fail-open: unset behaves as plan).
mentor_get_mode() {
  mentor_config_get "${1:-}" "mode"
}

# mentor_cwd <input_json> — echo the hook cwd ($PWD fallback).
mentor_cwd() {
  local cwd
  cwd="$(printf '%s' "${1:-}" | jq -r '.cwd // empty' 2>/dev/null || true)"
  [ -z "$cwd" ] && cwd="$PWD"
  echo "$cwd"
  return 0
}

# --- plan state (v2.4.0, deps/origin added v2.17.0, owner/owner_session added v2.23.0) --
#
# Each plan dir carries a hidden `.state.json` sidecar:
#   {"state":"draft|approved|in_progress|implemented|failed|superseded",
#    "group":"<parent slug>"|null, "order":<n>|null, "note":"<free text>",
#    "deps":["<slug>", …], "origin":"deferred"|null,
#    "owner":"<wt-id>"|null, "owner_session":"<session id>"|null}
# `group` is the slug of the plan that /plan-split replaced; standalone plans hold null.
# `deps` names plan slugs this one needs first (unknown slugs allowed — the dep may be
# deferred later; `plan-state.sh overview` marks those `missing`). `origin` is
# `"deferred"` for a stub born via `/mentor:defer` (shields it from the approval
# sweep — see approve-plan.sh) and null once `claim`ed or for an ordinary plan. `owner`
# is the wt-id (mentor_worktree_id) that minted or last re-owned this plan dir —
# stamped only by ensure-dir/init/claim, never by `set`; read it via mentor_plan_owner,
# never mentor_plan_state_field directly, for the same reason mentor_plan_group exists
# — a future second read site must not have to remember the field name by hand.
# `owner_session` is the session id that performed that stamp, alongside it.
#
# The sidecar is a CACHE, not the only truth. Reads go through
# mentor_plan_effective_state, which takes the more advanced of the stored state and
# the state derived from plan.md's ✅ step ticks — so a forgotten state write costs
# nothing, and pre-2.4.0 plan dirs read correctly with no migration. `deps`/`origin`/
# `owner`/`owner_session` are jq-defaulted the same way (`// []`, `// null`): a
# pre-2.17.0 4-field sidecar, or one an OLDER cached plugin copy rewrote without the
# owner keys (mixed-version worktrees during a rollout), reads back as unowned with no
# migration pass — degrades to the unowned handling, never corrupts. Writes go through
# hooks/plan-state.sh (the CLI); skills never hand-roll this JSON.

MENTOR_PLAN_STATES="draft approved in_progress implemented failed superseded"

# The plan-gate marker (.planning) is treated as released once it is this old, in
# minutes — a crashed planning session must never permanently lock out editing.
# plan-gate.sh's self-heal and plan-state.sh's `gate` subcommand both read this ONE
# number (via mentor_marker_stale below) so the two can never silently drift apart.
MENTOR_PLAN_MARKER_STALE_MIN=480

# mentor_plan_state_valid <state> — status 0 when <state> is one of the six above.
# THE ONE NON-ZERO-EXITING HELPER HERE: only call it as a condition.
mentor_plan_state_valid() {
  local s="${1:-}"
  [ -n "$s" ] || return 1
  case " ${MENTOR_PLAN_STATES} " in
    *" ${s} "*) return 0 ;;
  esac
  return 1
}

# mentor_marker_stale <marker_path> — status 0 when <marker_path> exists and is older
# than MENTOR_PLAN_MARKER_STALE_MIN minutes; status 1 when missing or fresh. A
# predicate, not an echo: always call it as a condition, never bare.
mentor_marker_stale() {
  local marker="${1:-}"
  [ -n "$marker" ] && [ -e "$marker" ] || return 1
  [ -n "$(find "$marker" -mmin "+${MENTOR_PLAN_MARKER_STALE_MIN}" 2>/dev/null)" ]
}

# mentor_marker_age_min <marker_path> — echo the marker's age in whole minutes, or
# empty when missing/unmeasurable. mentor_marker_stale above only answers a threshold
# (find -mmin can't report an absolute age), so this is the one sanctioned `stat` call
# in the plugin — GNU form FIRST: BSD stat rejects -c outright (clean failure), while
# GNU stat's -f treats %m as a FILE operand and half-succeeds, polluting stdout. A
# fail-soft echo helper, never a predicate.
mentor_marker_age_min() {
  local marker="${1:-}" epoch now
  [ -n "$marker" ] && [ -e "$marker" ] || { echo ""; return 0; }
  epoch="$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || true)"
  case "$epoch" in ''|*[!0-9]*) echo ""; return 0 ;; esac
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in ''|*[!0-9]*) echo ""; return 0 ;; esac
  echo "$(( (now - epoch) / 60 ))"
  return 0
}

# mentor_marker_field <marker_path> <field> — echo the value of a `key=value` line
# from the marker's metadata body (session/cwd, written by begin-plan.sh), or empty
# when missing/absent/pre-metadata (a marker armed before this field existed). Reads
# with grep, never `source` — cwd is an arbitrary path and must never be shell-evaluated.
# The `|| true` is load-bearing under callers' `set -o pipefail`: a no-match grep exits
# 1, which pipefail promotes to the pipeline's (and so this function's) exit status —
# and under `set -e` in plan-gate.sh, a bare `var=$(mentor_marker_field ...)` on a
# legacy/empty marker would then abort the WHOLE fail-closed gate script mid-deny,
# turning it fail-open. Always echo + explicit `return 0`, never let the grep miss
# become this function's exit status.
mentor_marker_field() {
  local marker="${1:-}" field="${2:-}" val
  [ -n "$marker" ] && [ -f "$marker" ] && [ -n "$field" ] || { echo ""; return 0; }
  val="$(command grep -m1 "^${field}=" "$marker" 2>/dev/null | cut -d= -f2- || true)"
  echo "$val"
  return 0
}

# mentor_plan_state_file <plan_dir> — echo <plan_dir>/.state.json (never created here).
mentor_plan_state_file() {
  local d="${1:-}"
  if [ -z "$d" ]; then echo ""; return 0; fi
  echo "${d}/.state.json"
  return 0
}

# mentor_plan_state_field <plan_dir> <key> — echo the stored value of <key>
# (state|group|order|note|origin), or empty when no sidecar / no jq / corrupt /
# unset / null. SCALAR fields only — it `tostring`s whatever it finds, so on `deps`
# (an array) it would return a JSON-stringified array rather than a real list; use
# mentor_plan_deps for that field instead.
mentor_plan_state_field() {
  local d="${1:-}" key="${2:-}" f
  if [ -z "$d" ] || [ -z "$key" ]; then echo ""; return 0; fi
  f="${d}/.state.json"
  if [ ! -f "$f" ]; then echo ""; return 0; fi
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  jq -r --arg k "$key" '.[$k] // "" | tostring' "$f" 2>/dev/null || true
  return 0
}

# mentor_plan_state_stored <plan_dir> — echo the sidecar's raw `state`, or empty when
# there is no readable sidecar. Empty means "pre-2.4.0 / unknown" — never `draft`:
# telling a user that a plan which shipped months ago was never approved is worse
# than saying nothing is on record.
mentor_plan_state_stored() {
  local s
  s="$(mentor_plan_state_field "${1:-}" state)"
  if mentor_plan_state_valid "$s"; then echo "$s"; else echo ""; fi
  return 0
}

# mentor_plan_header_field <plan_md> <group|order> — echo the value carried by a split
# child's isolation header, or empty. `/plan-split` writes that header as the first
# thing in every child:
#     > **Plan 3 of 5** · group `multi-tenant-billing` · depends on `…`
# It holds the same two facts the sidecar does, which makes it the recovery path when
# a sidecar is deleted or a write is torn — grouping then survives exactly the way
# state does, from the plan file itself.
mentor_plan_header_field() {
  local md="${1:-}" key="${2:-}"
  if [ -z "$md" ] || [ ! -f "$md" ] || [ -z "$key" ]; then echo ""; return 0; fi
  case "$key" in
    group) sed -n '1,20p' "$md" 2>/dev/null | sed -n 's/.*[Gg]roup `\([^`]*\)`.*/\1/p' | head -1 || true ;;
    order) sed -n '1,20p' "$md" 2>/dev/null | sed -n 's/.*\*\*Plan \([0-9][0-9]*\) of .*/\1/p' | head -1 || true ;;
    *)     echo "" ;;
  esac
  return 0
}

# mentor_plan_group / mentor_plan_order <plan_dir> — the resolved value: sidecar first,
# isolation header as the fallback. Read grouping through these, never through
# mentor_plan_state_field directly, or a lost sidecar silently drops a child out of
# its group and "the current plan" starts picking finished work.
mentor_plan_group() {
  local d="${1:-}" v
  v="$(mentor_plan_state_field "$d" group)"
  if [ -z "$v" ]; then v="$(mentor_plan_header_field "${d}/plan.md" group)"; fi
  echo "$v"
  return 0
}

mentor_plan_order() {
  local d="${1:-}" v
  v="$(mentor_plan_state_field "$d" order)"
  if [ -z "$v" ]; then v="$(mentor_plan_header_field "${d}/plan.md" order)"; fi
  echo "$v"
  return 0
}

# mentor_plan_deps <plan_dir> — echo the sidecar's `deps` array, one plan slug per
# output line (never a JSON array). Dedicated array-typed reader, parallel to
# mentor_plan_group/mentor_plan_order but for a list-valued field: the generic
# mentor_plan_state_field `tostring`s every value, which on `deps` would hand back a
# JSON-stringified array rather than something a caller can loop over (the set-deps
# cycle walk) or re-encode as real JSON (`overview --json`). Empty output when no
# sidecar / no jq / corrupt / unset / empty array — same jq-default (`// []`) that
# makes a pre-2.17.0 4-field sidecar read as "no deps" with no migration needed.
mentor_plan_deps() {
  local d="${1:-}" f
  [ -n "$d" ] || return 0
  f="${d}/.state.json"
  [ -f "$f" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '(.deps // []) | if type == "array" then .[] else empty end' "$f" 2>/dev/null || true
  return 0
}

# mentor_plan_origin <plan_dir> — echo the sidecar's `origin` ("deferred") or empty
# (null / unset / no sidecar / no jq — an ordinary, non-deferred plan). Thin wrapper
# over the generic scalar reader, named to match mentor_plan_deps at call sites that
# read both fields side by side.
mentor_plan_origin() {
  mentor_plan_state_field "${1:-}" origin
}

# mentor_plan_would_cycle <plans_dir> <slug> <tentative deps, space-separated> — echo
# "cycle" when giving <slug> exactly this deps list would create a dependency cycle
# (including a direct self-cycle, <slug> listed in its own deps), else echo nothing.
# BFS from each tentative dep, following every OTHER plan's CURRENTLY STORED deps
# (mentor_plan_deps) — reaching <slug> again means a cycle closes through it. A dep
# slug with no matching plan dir is a dead end, not an error (unknown deps are
# allowed — see overview's `missing` marking). The visited-set makes this terminate
# in at most one pass over the plan dirs, so a torn/circular sidecar graph that
# somehow already exists can never spin forever. Fail-soft: no plans_dir / no slug /
# no jq → echoes "" (treated as safe by callers, matching every other reader here).
mentor_plan_would_cycle() {
  local plans_dir="${1:-}" slug="${2:-}" deps="${3:-}" dep node queue seen
  [ -n "$plans_dir" ] && [ -n "$slug" ] || { echo ""; return 0; }
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  queue="$deps"
  seen=" "
  while [ -n "$queue" ]; do
    node="${queue%% *}"
    if [ "$node" = "$queue" ]; then queue=""; else queue="${queue#* }"; fi
    [ -n "$node" ] || continue
    if [ "$node" = "$slug" ]; then echo "cycle"; return 0; fi
    case "$seen" in *" ${node} "*) continue ;; esac
    seen="${seen}${node} "
    if [ -d "${plans_dir}/${node}" ]; then
      for dep in $(mentor_plan_deps "${plans_dir}/${node}"); do
        queue="${queue} ${dep}"
      done
    fi
  done
  echo ""
  return 0
}

# mentor_plan_live_handoffs <plan_dir> — echo one LIVE handoff basename per output
# line: <plan_dir>/handoffs/*.md, excluding handoffs/resolved/* — the same anchored
# exclusion (`-not -path '*/handoffs/resolved/*'`) /mentor:resume uses, so a repo path
# or topic slug literally named "resolved" is never false-excluded. Empty when the
# handoffs dir doesn't exist or holds nothing live.
# The exclusion is shared with /mentor:resume; the NAME filter deliberately is not.
# /mentor:resume lists only `^[0-9]{8}-[0-9]{6}-.+\.md$` and skips the rest, so a
# misnamed note is invisible there — which is exactly why `overview` must still show
# it: this is the only surface that can tell the user the note exists and needs
# renaming. Applying resume's filter here would hide it from both sides at once.
mentor_plan_live_handoffs() {
  local d="${1:-}"
  [ -n "$d" ] || return 0
  [ -d "${d}/handoffs" ] || return 0
  find "${d}/handoffs" -type f -name '*.md' -not -path '*/handoffs/resolved/*' 2>/dev/null \
    | while IFS= read -r hf; do basename "$hf"; done
  return 0
}

# MENTOR_STEP_LINE_PATTERN — the ONE definition of "this line is a step" inside a
# plan's `## Implementation steps` section: a numbered item (`3. …`) or a
# `Step 3 — …` line. mentor_plan_tick_counts (read) and mentor_plan_tick_step
# (write, below) both match against this exact string — a second, drifting copy
# in either direction would let a written tick land on a line the counter doesn't
# see, or vice versa, silently breaking the "ratio and verdict never disagree"
# guarantee both functions depend on. `[*][*]` (not `\*\*`): passed as a dynamic
# regex via awk -v, a backslash-escaped literal is undefined behavior on some awk
# implementations (confirmed failing on macOS's awk 20200816) — a bracket
# expression is the portable way to mean "one literal asterisk" in both a static
# `/…/` literal and a dynamic string. `(#{3,4}[[:space:]]+)?`: real plans mentor
# itself writes commonly use `### N. Title` step headings, not just bare `N.` —
# without this branch those steps are invisible to both functions, which
# silently report 0 ticked/total instead of erroring. `###`/`####` never collide
# with the separate `/^##[[:space:]]/` section-boundary check both functions use
# (exactly two hashes) since a third/fourth `#` sits where that check needs
# whitespace.
MENTOR_STEP_LINE_PATTERN='^[[:space:]]*(-[[:space:]]+)?([*][*])?(#{3,4}[[:space:]]+)?([0-9]+\.|[Ss]tep[[:space:]]+[0-9]+)'

# mentor_plan_tick_counts <plan_md> — echo "<ticked> <total>" step-line counts from
# the `## Implementation steps` section, ticked when a step line contains ✅.
# "0 0" when no plan.md or no recognizable step lines. The one parsing
# implementation — mentor_plan_tick_state (below) derives its
# implemented/in_progress/empty verdict FROM these counts, and
# `plan-state.sh overview --json` reports the raw counts for the task-level rung of
# the hierarchy — so the ratio and the verdict can never disagree.
mentor_plan_tick_counts() {
  local md="${1:-}"
  if [ -z "$md" ] || [ ! -f "$md" ]; then echo "0 0"; return 0; fi
  awk -v pat="$MENTOR_STEP_LINE_PATTERN" '
    /^##[[:space:]]/ {
      h = tolower($0)
      insec = (h ~ /^##[[:space:]]+implementation[[:space:]]+steps/) ? 1 : 0
      next
    }
    !insec { next }
    $0 ~ pat {
      total++
      if (index($0, "✅") > 0) ticked++
    }
    END { printf "%d %d\n", ticked+0, total+0 }
  ' "$md" 2>/dev/null || echo "0 0"
  return 0
}

# mentor_plan_tick_step <plan_md> <N> — append ✅ to the Nth step line inside the
# `## Implementation steps` section, using MENTOR_STEP_LINE_PATTERN so a written
# tick and mentor_plan_tick_counts's ratio can never disagree about what counts as
# a step. Idempotent: a step that already carries ✅ is left untouched. Echoes one
# status line on success and returns 0:
#   ticked <N> <total>    — this call appended the ✅
#   already <N> <total>   — the step was already ticked, nothing written
# On failure (bad/missing plan_md, N not a positive integer, or N out of range)
# echoes "no-such-step <total>" (total 0 when the file/section is unreadable) and
# returns 1 — the caller decides whether that is worth surfacing. No write happens
# on any failure path, including a mid-write error, since the rewritten file is
# only moved into place after a full, successful pass over the input.
mentor_plan_tick_step() {
  local md="${1:-}" n="${2:-}"
  if [ -z "$md" ] || [ ! -f "$md" ]; then echo "no-such-step 0"; return 1; fi
  case "$n" in ''|*[!0-9]*) echo "no-such-step 0"; return 1 ;; esac
  [ "$n" -ge 1 ] || { echo "no-such-step 0"; return 1; }

  local tmp status_file status_line
  tmp="$(mktemp "${md}.tick.XXXXXX")" || { echo "no-such-step 0"; return 1; }
  status_file="${tmp}.status"

  # `if awk …; then` (not a bare command) — under the caller's `set -e` contract, a
  # bare failing command aborts the whole hook before the rc check below ever runs.
  local awk_rc
  if awk -v pat="$MENTOR_STEP_LINE_PATTERN" -v target="$n" '
    /^##[[:space:]]/ {
      h = tolower($0)
      insec = (h ~ /^##[[:space:]]+implementation[[:space:]]+steps/) ? 1 : 0
      print; next
    }
    !insec { print; next }
    $0 ~ pat {
      total++
      if (total == target) {
        found = 1
        if (index($0, "✅") > 0) { print; status = "already" }
        else { print $0 " ✅"; status = "ticked" }
      } else {
        print
      }
      next
    }
    { print }
    END {
      if (!found) { print "no-such-step " total+0 > "/dev/stderr"; exit 1 }
      print status " " target " " total+0 > "/dev/stderr"
    }
  ' "$md" >"$tmp" 2>"$status_file"; then
    awk_rc=0
  else
    awk_rc=$?
  fi
  status_line="$(cat "$status_file" 2>/dev/null)"
  rm -f "$status_file"

  if [ "$awk_rc" -ne 0 ] || [ -z "$status_line" ]; then
    rm -f "$tmp"
    echo "${status_line:-no-such-step 0}"
    return 1
  fi
  case "$status_line" in
    already\ *) rm -f "$tmp" ;;   # unchanged — discard the rewritten-but-identical copy
    *)          mv "$tmp" "$md" ;;
  esac
  echo "$status_line"
  return 0
}

# mentor_plan_tick_state <plan_md> — echo the state implied by the ✅ ticks that
# dispatch-agents appends as each step's `Done when:` passes: every step line in the
# `## Implementation steps` section ticked → implemented; some → in_progress; none or
# no recognizable steps → empty (no opinion). Built on mentor_plan_tick_counts, so the
# step-line rule lives in exactly one place.
mentor_plan_tick_state() {
  local md="${1:-}" ticked total
  read -r ticked total <<<"$(mentor_plan_tick_counts "$md")"
  if [ "${total:-0}" -eq 0 ]; then echo ""; return 0; fi
  if [ "$ticked" -eq "$total" ]; then echo "implemented"
  elif [ "$ticked" -gt 0 ]; then echo "in_progress"
  fi
  return 0
}

# mentor_plan_state_rank <state> — ordering for "more advanced":
#   superseded 9 > failed 5 > implemented 4 > in_progress 3 > approved 2 > draft 1.
# `superseded` outranks everything (a split parent stays superseded however many ticks
# its body carries). `failed` sits ABOVE `implemented` — and so above every state the
# tick derivation can produce — because it is an explicit judgment written by an
# orchestrator that observed a real failure, while `implemented` is merely DERIVABLE
# from ticks alone. End-to-end verification runs after every step is ticked, so an
# escalation to `failed` always lands on an all-ticked plan; ranking the derivation
# higher would resurface a genuinely failed plan as successfully completed, with only a
# free-text note surviving. A derivation must never overrule an explicit failure record.
# This also keeps the older guarantee that a stored `failed` survives a derived
# `in_progress` — now by strictly outranking it rather than by the stored-wins tie-break.
# Clearing a `failed` plan stays explicit: the orchestrator writes a new state, and a
# stored state always wins ties against the derived one.
mentor_plan_state_rank() {
  case "${1:-}" in
    superseded)  echo 9 ;;
    failed)      echo 5 ;;
    implemented) echo 4 ;;
    in_progress) echo 3 ;;
    approved)    echo 2 ;;
    draft)       echo 1 ;;
    *)           echo 0 ;;
  esac
  return 0
}

# mentor_plan_effective_state <plan_dir> — THE authoritative read: the more advanced of
# the stored state and the tick-derived state, ties keeping the stored one. No sidecar
# and no ticks → "unknown". Always echoes one of the six states or "unknown".
mentor_plan_effective_state() {
  local d="${1:-}" stored tick
  if [ -z "$d" ]; then echo "unknown"; return 0; fi
  stored="$(mentor_plan_state_stored "$d")"
  tick="$(mentor_plan_tick_state "${d}/plan.md")"
  if [ -z "$tick" ]; then echo "${stored:-unknown}"; return 0; fi
  if [ "$(mentor_plan_state_rank "$tick")" -gt "$(mentor_plan_state_rank "$stored")" ]; then
    echo "$tick"
  else
    echo "${stored:-unknown}"
  fi
  return 0
}

# mentor_plan_state_write <plan_dir> [--state S] [--group G] [--order N] [--note "…"]
#   [--deps a,b] [--origin deferred|""] [--owner W] [--owner-session S] — upsert the
#   sidecar (create-then-set: most plans have no sidecar yet).
#
# Flag-style since v2.17.0 (was fixed positional <state> <group> <order> <note>) so a
# write that only touches one or two fields — set-deps, claim, approve-plan's
# promotion — doesn't have to thread every other field through by hand.
#
# AN OMITTED FLAG PRESERVES THE EXISTING STORED VALUE for --state/--group/--order/
# --deps/--origin/--owner/--owner-session. This is what lets `deps`/`origin`/`owner`
# survive every state transition: approve-plan's promotion write passes only `--state
# approved` and deps/origin/owner ride through untouched, instead of getting clobbered
# back to defaults the way a mandatory-positional write would. In particular, `set`
# never passes --owner, so it never touches ownership — only ensure-dir/init/claim do.
#
# --note is the ONE exception to "omitted preserves": it is ALWAYS replaced with
# whatever was passed (empty when the flag is omitted) — unchanged from before the
# rework. "note REPLACED every time" is a deliberate feature (a plain `set` with no
# --note clears a stale failure note); a caller that wants to keep the current note
# must re-pass it, the same way `init` already reads it back before writing.
#
# Passing a flag with an EXPLICIT EMPTY VALUE clears that field (group/order/origin/
# owner/owner_session → null, deps → []) rather than preserving it — this is how
# `claim` clears origin (`--origin ""`) without touching anything else, and how a
# caller can deliberately release ownership (`--owner ""`). --state cannot be cleared
# this way: an empty/invalid --state is rejected outright (fail-soft: no write), same
# as before. --origin only accepts "deferred" or "" (clear); anything else is also
# rejected.
#
# jq has no in-place edit, so this is tmp-file + mv. A torn write leaves the sidecar
# unreadable, which reads back as "unknown" — recoverable, because a split child's
# isolation header carries the same group/order inside plan.md. Lost-update semantics:
# the tmp+mv happens inside the sidecar's own dir, so each individual write is atomic —
# but two worktrees writing the same slug's sidecar concurrently can still lose one
# write to the other (last mv wins), never corrupt it.
# Fail-soft: always status 0, echoes nothing; a bad --state/--origin or missing jq
# writes nothing.
mentor_plan_state_write() {
  local d="${1:-}"
  shift || true
  local state="" state_set=0
  local group="" group_set=0
  local order="" order_set=0
  local note="" deps="" deps_set=0
  local origin="" origin_set=0
  local owner="" owner_set=0
  local owner_session="" owner_session_set=0
  local f tmp deps_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state)  state="${2:-}";  state_set=1;  shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --group)  group="${2:-}";  group_set=1;  shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --order)  order="${2:-}";  order_set=1;  shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --note)   note="${2:-}";                 shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --deps)   deps="${2:-}";   deps_set=1;   shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --origin) origin="${2:-}"; origin_set=1; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --owner)  owner="${2:-}";  owner_set=1;  shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --owner-session)
                owner_session="${2:-}"; owner_session_set=1; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      *) shift ;;   # fail-soft: an unrecognized flag is ignored, never aborts a caller
    esac
  done
  [ -n "$d" ] && [ -d "$d" ] || return 0
  if [ "$state_set" -eq 1 ] && ! mentor_plan_state_valid "$state"; then return 0; fi
  if [ "$origin_set" -eq 1 ] && [ -n "$origin" ] && [ "$origin" != "deferred" ]; then return 0; fi
  command -v jq >/dev/null 2>&1 || return 0
  f="${d}/.state.json"
  if [ ! -f "$f" ] || ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    printf '%s\n' '{}' > "$f" 2>/dev/null || return 0
  fi
  if [ -n "$deps" ]; then
    deps_json="$(printf '%s' "$deps" | jq -R -c 'split(",") | map(select(length>0))' 2>/dev/null)"
  else
    deps_json="[]"
  fi
  [ -n "$deps_json" ] || deps_json="[]"
  tmp="${f}.tmp.$$"
  if jq --arg state "$state" --argjson state_set "$state_set" \
        --arg group "$group" --argjson group_set "$group_set" \
        --arg order "$order" --argjson order_set "$order_set" \
        --arg note "$note" \
        --argjson deps "$deps_json" --argjson deps_set "$deps_set" \
        --arg origin "$origin" --argjson origin_set "$origin_set" \
        --arg owner "$owner" --argjson owner_set "$owner_set" \
        --arg owner_session "$owner_session" --argjson owner_session_set "$owner_session_set" '
        {
          state: (if $state_set == 1 then $state else (.state // null) end),
          group: (if $group_set == 1 then (if $group == "" then null else $group end) else (.group // null) end),
          order: (if $order_set == 1 then (if $order == "" then null else ($order | tonumber? // null) end) else (.order // null) end),
          note:  $note,
          deps:  (if $deps_set == 1 then $deps else (.deps // []) end),
          origin: (if $origin_set == 1 then (if $origin == "" then null else $origin end) else (.origin // null) end),
          owner: (if $owner_set == 1 then (if $owner == "" then null else $owner end) else (.owner // null) end),
          owner_session: (if $owner_session_set == 1 then (if $owner_session == "" then null else $owner_session end) else (.owner_session // null) end)
        }' "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# --- context gate -----------------------------------------------------------

# mentor_context_tokens <transcript_path> — echo the current main-chain context size
# in tokens (the last assistant usage record, or the postTokens of a later
# compact_boundary), or empty when unmeasurable (no file / no jq / no usage in the tail
# window). Skips subagent sidechains and <synthetic> all-zero API-error placeholders.
mentor_context_tokens() {
  local tx="${1:-}" last
  [ -z "$tx" ] && { echo ""; return 0; }
  [ -f "$tx" ] || { echo ""; return 0; }
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  last="$(tail -n "${MENTOR_CONTEXT_TAIL_LINES:-400}" "$tx" 2>/dev/null | jq -R -r '
    fromjson? | select(type == "object") | select(.isSidechain != true)
    | if .type == "assistant" then
        (.message.usage? // empty) | select(type == "object")
        | select(.input_tokens != null)
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
        | select(. > 0)
      elif .type == "system" and .subtype == "compact_boundary" then
        (.compactMetadata.postTokens // 0) | select(. > 0)
      else empty end' 2>/dev/null | tail -n 1)"
  case "$last" in
    ''|*[!0-9]*) echo ""; return 0 ;;
  esac
  echo "$last"
  return 0
}

# mentor_context_threshold <repo_root> <env_value> <config_key> <default> — resolve a
# numeric threshold with precedence env > config.json > default. A candidate wins only
# if all-digits; otherwise fall through. Echoes the chosen integer.
mentor_context_threshold() {
  local repo_root="${1:-}" env_value="${2:-}" config_key="${3:-}" default="${4:-}" cfg
  case "$env_value" in
    ''|*[!0-9]*) ;;
    *) echo "$env_value"; return 0 ;;
  esac
  cfg="$(mentor_config_get "$repo_root" "$config_key")"
  case "$cfg" in
    ''|*[!0-9]*) ;;
    *) echo "$cfg"; return 0 ;;
  esac
  echo "$default"
  return 0
}

# mentor_context_gate_state <repo_root> — echo "off" when the gate is disabled via env
# MENTOR_CONTEXT_GATE (off|0|false|no) or config context_gate == "off"; else "on".
mentor_context_gate_state() {
  local repo_root="${1:-}" cfg
  case "${MENTOR_CONTEXT_GATE:-}" in
    off|0|false|no) echo "off"; return 0 ;;
  esac
  cfg="$(mentor_config_get "$repo_root" "context_gate")"
  if [ "$cfg" = "off" ]; then echo "off"; return 0; fi
  echo "on"
  return 0
}

# mentor_latest_handoff <repo_root> — echo the mtime-newest conforming handoff note
# (<YYYYMMDD-HHMMSS>-<slug>.md under plans/*/handoffs/ or the legacy flat handoffs/ —
# the exact locations /mentor:resume lists), or empty when none exist. Non-conforming
# names are skipped; notes stamped resolved (moved into a handoffs/resolved/ subdir on
# completion or supersession) never match the globs, so solved notes stop counting as fresh.
# With no repo_root, falls back to ~/.claude/mentor/_no-repo — the dir the handoff skill
# writes to outside a git repo — so no-repo sessions get the same freshness handling.
mentor_latest_handoff() {
  local state_dir f
  state_dir="$(mentor_state_dir "${1:-}")"
  if [ -z "$state_dir" ]; then state_dir="${HOME}/.claude/mentor/_no-repo"; fi
  while IFS= read -r f; do
    case "${f##*/}" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.md)
        echo "$f"; return 0 ;;
    esac
  done < <(ls -t "${state_dir}"/plans/*/handoffs/*.md "${state_dir}/handoffs"/*.md 2>/dev/null || true)
  echo ""
  return 0
}

# mentor_find_transcript [cwd] — echo this session's main transcript (.jsonl), or empty
# when it cannot be located. Hooks invoked as plain Bash calls get no hook stdin, so
# they locate it themselves. Primary (exact, race-free): CLAUDE_CODE_SESSION_ID is
# exported into Bash tool environments and equals the transcript filename. Fallback
# (older Claude Code): the newest transcript in the hashed project dir.
mentor_find_transcript() {
  local cwd="${1:-$PWD}" projects_dir tx="" base hash
  projects_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    tx="$(find "$projects_dir" -maxdepth 2 -name "${CLAUDE_CODE_SESSION_ID}.jsonl" 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$tx" ]; then
    for base in "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)" "$cwd"; do
      [ -n "$base" ] || continue
      hash="$(printf '%s' "$base" | sed 's/[^A-Za-z0-9]/-/g')"
      tx="$(ls -t "${projects_dir}/${hash}"/*.jsonl 2>/dev/null | head -1 || true)"
      [ -n "$tx" ] && break
    done
  fi
  echo "$tx"
  return 0
}

# mentor_context_bypassed <repo_root> — status 0 when the user already chose to bypass
# the context gate for THIS session (bypass-context.sh wrote the marker). Predicate:
# call it from a condition only.
mentor_context_bypassed() {
  local state_dir
  state_dir="$(mentor_state_dir "${1:-}")"
  [ -n "$state_dir" ] || return 1
  [ -e "${state_dir}/.context-bypass-${CLAUDE_CODE_SESSION_ID:-nosession}" ]
}

# mentor_context_verdict <repo_root> [cwd] — echo "<OK|WARN|ASK|HANDOFF> <tokens>
# <warn_at> <ask_at>", or empty when the gate is off or the context is unmeasurable
# (no transcript / no jq / no usage record in the tail window).
#
# The single implementation of the ask-first context check (v2.8.0), shared by
# begin-plan.sh at arm time and by plan-state.sh `context`, which /mentor:track calls
# before it dispatches — hooks/context-gate.sh passes every slash-prefixed prompt, so a
# slash command that starts an implementation has no other backstop.
#
# The tiers mirror the gate's own policy, deliberately: over the ask threshold the USER
# decides (ASK), unless they already chose to continue this session, in which case the
# work proceeds with a lean-mode advisory (HANDOFF). A caller must never be stricter
# than the gate — refusing someone who explicitly opted to keep going is a bug.
mentor_context_verdict() {
  local repo_root="${1:-}" cwd="${2:-$PWD}" tx tokens ask_at warn_at
  [ "$(mentor_context_gate_state "$repo_root")" = "on" ] || { echo ""; return 0; }
  tx="$(mentor_find_transcript "$cwd")"
  tokens="$(mentor_context_tokens "$tx")"
  if [ -z "$tokens" ]; then echo ""; return 0; fi
  ask_at="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_BLOCK_TOKENS:-}" context_block_tokens 350000)"
  warn_at="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_TOKENS:-}" context_warn_tokens 200000)"
  if [ "$tokens" -ge "$ask_at" ]; then
    if mentor_context_bypassed "$repo_root"; then
      echo "HANDOFF ${tokens} ${warn_at} ${ask_at}"
    else
      echo "ASK ${tokens} ${warn_at} ${ask_at}"
    fi
  elif [ "$tokens" -ge "$warn_at" ]; then
    echo "WARN ${tokens} ${warn_at} ${ask_at}"
  else
    echo "OK ${tokens} ${warn_at} ${ask_at}"
  fi
  return 0
}
