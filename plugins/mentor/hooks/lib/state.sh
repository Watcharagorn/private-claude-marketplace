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
#   │       │                #   "owner_session","priority","category","deferred_from",
#   │       │                #   "parent"} — written ONLY via plan-state.sh (deps/origin
#   │       │                #   added v2.17.0; owner/owner_session — the minting/re-owning
#   │       │                #   worktree, v2.23.0; priority — the impact tier, v2.24.0;
#   │       │                #   category — the work kind, and deferred_from — the plan
#   │       │                #   slug a stub was captured out of, both v2.25.0; parent —
#   │       │                #   the slug of the plan this one must complete before
#   │       │                #   (existence + cycle checked at write, unlike the looser
#   │       │                #   deferred_from), v2.29.0 — added below; older or
#   │       │                #   mixed-version sidecars read back with any missing key
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

# mentor_confine_path <state_dir> <target> — canonicalize <target> (realpath) and print it
# on stdout iff it resolves under <state_dir> itself; else print nothing and return 1.
#
# Every call site that turns a model-chosen path segment (a plan slug, a handoff topic) into
# an mkdir/mv target needs this same guard — without it a prompt-steered `../` walks the write
# outside the mentor tree. `ensure-dir` keeps its own inline copy (predates this helper, already
# covered by its own tests) rather than being refactored to call it; newer call sites should
# call this instead of adding a third/fourth copy of the same six lines.
mentor_confine_path() {
  local state_dir="${1:-}" target="${2:-}" canon base
  [ -n "$state_dir" ] && [ -n "$target" ] || return 1
  canon="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target" 2>/dev/null || echo "$target")"
  base="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$state_dir" 2>/dev/null || echo "$state_dir")"
  case "$canon" in
    "$base"|"$base"/*) printf '%s\n' "$canon"; return 0 ;;
    *) return 1 ;;
  esac
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

# --- plan state (v2.4.0, deps/origin added v2.17.0, owner/owner_session added
# v2.23.0, priority added v2.24.0, category/deferred_from added v2.25.0) -----
#
# Each plan dir carries a hidden `.state.json` sidecar:
#   {"state":"draft|approved|in_progress|implemented|failed|superseded",
#    "group":"<parent slug>"|null, "order":<n>|null, "note":"<free text>",
#    "deps":["<slug>", …], "origin":"deferred"|null,
#    "owner":"<wt-id>"|null, "owner_session":"<session id>"|null,
#    "priority":"critical|high|medium|low|noise"|null,
#    "category":"feature|fix|refactor|docs|tooling"|null,
#    "deferred_from":"<plan slug>"|null}
# `group` is the slug of the plan that /plan-split replaced; standalone plans hold null.
# `deps` names plan slugs this one needs first (unknown slugs allowed — the dep may be
# deferred later; `plan-state.sh query` marks those `missing`). `origin` is
# `"deferred"` for a stub born via `/mentor:defer` (shields it from the approval
# sweep — see approve-plan.sh) and null once `claim`ed or for an ordinary plan. `owner`
# is the wt-id (mentor_worktree_id) that minted or last re-owned this plan dir —
# stamped only by ensure-dir/init/claim, never by `set`; read it via mentor_plan_owner,
# never mentor_plan_state_field directly, for the same reason mentor_plan_group exists
# — a future second read site must not have to remember the field name by hand.
# `owner_session` is the session id that performed that stamp, alongside it.
# `priority` is the plan's IMPACT tier — how much this plan matters, so
# /mentor:track's hierarchy can separate the work that counts from the noise. It is
# orthogonal to every other field here: `order` sequences siblings INSIDE a split
# group, `deps` says what must be built FIRST, and neither says anything about
# whether a plan is worth building at all. Unset (null) is a first-class answer — an
# unprioritized plan renders with no tier rather than defaulting into one, the same
# reason mentor_plan_state_stored refuses to invent `draft`.
# `category` is the plan's WORK KIND — a CLOSED vocabulary like `priority`,
# deliberately excluding anything test/verify-shaped (see MENTOR_PLAN_CATEGORIES
# below): a deferred stub's Goal names work to build, never a check to run.
# `deferred_from` is the slug of the plan a `/mentor:defer` stub was captured out
# of mid-flow — UNVALIDATED, like a `deps` target, since the source plan may be
# deleted later; a dangling value is resolved at render time (plan-track's
# `(missing)` marker), never by this layer.
#
# The sidecar is a CACHE, not the only truth. Reads go through
# mentor_plan_effective_state, which takes the more advanced of the stored state and
# the state derived from plan.md's ✅ step ticks — so a forgotten state write costs
# nothing, and pre-2.4.0 plan dirs read correctly with no migration. `deps`/`origin`/
# `owner`/`owner_session`/`priority`/`category`/`deferred_from` are jq-defaulted the
# same way (`// []`, `// null`): a pre-2.17.0 4-field sidecar, or one an OLDER cached
# plugin copy rewrote without the owner/priority/category/deferred_from keys
# (mixed-version worktrees during a rollout), reads back as
# unowned/unprioritized/uncategorized with no migration pass — degrades to the unset
# handling, never corrupts. Writes go through hooks/plan-state.sh (the CLI); skills
# never hand-roll this JSON.

MENTOR_PLAN_STATES="draft approved in_progress implemented failed superseded"

# The impact tiers, most impactful first — the order every renderer sorts and groups
# by, so "which matters more" lives here rather than being re-derived per caller.
# A CLOSED set, validated on write exactly like MENTOR_PLAN_STATES, and deliberately
# unlike `deps` (arbitrary slugs) or `note` (free text): the whole point of the field
# is that /mentor:track can bucket plans by tier, and a typo'd `hgih` would silently
# render as its own sixth tier rather than failing. `group` stays free text for the
# opposite reason — it names another plan's slug, which no closed set could know.
MENTOR_PLAN_PRIORITIES="critical high medium low noise"

# mentor_plan_priority_valid <priority> — status 0 when <priority> is one of the five
# above. A predicate like mentor_plan_state_valid — only call it as a condition. The
# EMPTY string is NOT valid here: clearing goes through an explicit `--priority ""` in
# mentor_plan_state_write, which never consults this function.
mentor_plan_priority_valid() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  case " ${MENTOR_PLAN_PRIORITIES} " in
    *" ${p} "*) return 0 ;;
  esac
  return 1
}

# The work-kind categories — a CLOSED set like MENTOR_PLAN_PRIORITIES, validated on
# write the same way. Deliberately excludes anything test/verify-shaped: a category
# exists to classify SHIPPABLE work — a deferred stub's Goal names work to build,
# never a check to run — so a `test`/`verify` bucket would hand the scope rule a side
# door to leak through.
MENTOR_PLAN_CATEGORIES="feature fix refactor docs tooling"

# mentor_plan_category_valid <category> — status 0 when <category> is one of the five
# above. A predicate like mentor_plan_priority_valid — only call it as a condition.
# The EMPTY string is NOT valid here either: clearing goes through an explicit
# `--category ""` in mentor_plan_state_write, which never consults this function.
mentor_plan_category_valid() {
  local c="${1:-}"
  [ -n "$c" ] || return 1
  case " ${MENTOR_PLAN_CATEGORIES} " in
    *" ${c} "*) return 0 ;;
  esac
  return 1
}

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
# (state|group|order|note|origin|owner|owner_session|priority|category|
# deferred_from|parent), or empty when no sidecar / no jq / corrupt / unset / null.
# SCALAR fields only — it `tostring`s whatever it finds, so on `deps`
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
# cycle walk) or re-encode as real JSON (`query`). Empty output when no
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

# mentor_plan_priority <plan_dir> — echo the sidecar's `priority` (one of
# MENTOR_PLAN_PRIORITIES) or empty (null / unset / no sidecar / no jq / a pre-v2.24.0
# plan dir — an UNPRIORITIZED plan). Thin wrapper over the generic scalar reader,
# named to match mentor_plan_origin/mentor_plan_owner so a second read site never has
# to remember the field name by hand.
#
# Deliberately NO fallback and NO default: unlike mentor_plan_group/mentor_plan_order
# there is no plan.md header carrying this (nothing writes an impact tier into the
# plan body), and unlike mentor_plan_effective_state there is nothing in the plan file
# to derive it from. Empty means "nobody has judged this plan's impact", which is a
# different and more honest answer than `medium`.
mentor_plan_priority() {
  mentor_plan_state_field "${1:-}" priority
}

# mentor_plan_category <plan_dir> — echo the sidecar's `category` (one of
# MENTOR_PLAN_CATEGORIES) or empty (null / unset / no sidecar / no jq / a
# pre-v2.25.0 plan dir — an UNCATEGORIZED plan). Thin wrapper over the generic
# scalar reader, named to match mentor_plan_origin/mentor_plan_priority so a second
# read site never has to remember the field name by hand.
mentor_plan_category() {
  mentor_plan_state_field "${1:-}" category
}

# mentor_plan_deferred_from <plan_dir> — echo the sidecar's `deferred_from` (a plan
# slug) or empty (null / unset / no sidecar / no jq / an ordinary plan, or one
# deferred before v2.25.0). UNVALIDATED, like mentor_plan_deps' targets — the source
# plan may itself be deleted later; resolving that dangle is a render-time concern
# (plan-track's `(missing)` marker, now carried by the field itself as `{slug, missing}`), never
# this reader's job. Thin wrapper over the generic scalar reader, matching
# mentor_plan_origin/mentor_plan_priority.
mentor_plan_deferred_from() {
  mentor_plan_state_field "${1:-}" deferred_from
}

# mentor_plan_parent <plan_dir> — echo the sidecar's `parent` (the slug of the plan
# this one must complete before) or empty (null / unset / no sidecar / no jq / an
# ordinary, non-child plan). Thin wrapper over the generic scalar reader, matching
# mentor_plan_origin/mentor_plan_priority/mentor_plan_deferred_from. UNLIKE
# deferred_from (informational only, never validated), `parent` IS validated for
# existence + cycle at write time — by plan-state.sh's `init --parent`/`set-parent`,
# via mentor_plan_would_cycle_parent below — but this reader itself stays exactly as
# unvalidated as every other thin wrapper here: the plan a `parent` points at can
# still be renamed or deleted AFTER the write, and resolving that dangle is a
# render-time concern for the consumer (plan-track's `(missing)` marker, same
# pattern deferred_from already uses), never this reader's job.
mentor_plan_parent() {
  mentor_plan_state_field "${1:-}" parent
}

# mentor_plan_would_cycle <plans_dir> <slug> <tentative deps, space-separated> — echo
# "cycle" when giving <slug> exactly this deps list would create a dependency cycle
# (including a direct self-cycle, <slug> listed in its own deps), else echo nothing.
# BFS from each tentative dep, following every OTHER plan's CURRENTLY STORED deps
# (mentor_plan_deps) — reaching <slug> again means a cycle closes through it. A dep
# slug with no matching plan dir is a dead end, not an error (unknown deps are
# allowed — see query's `missing` marking). The visited-set makes this terminate
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

# mentor_plan_would_cycle_parent <plans_dir> <slug> <tentative_parent> — echo "cycle"
# when giving <slug> exactly this parent would create a cycle in the parent-chain
# graph (a direct self-parent, or <tentative_parent> already sitting somewhere in
# <slug>'s own current descendant subtree — walking UP from <tentative_parent> via
# mentor_plan_parent eventually reaching <slug> again means <tentative_parent> is
# already a descendant of <slug>, so the edge would close a loop), else echo
# nothing. Same SHAPE as mentor_plan_would_cycle above (visited-set walk, dead ends
# on an unknown node are not errors), simplified from a BFS-over-a-queue to a
# straight walk because `parent` is single-valued — each node has AT MOST one
# outgoing edge, so there is only ever one path to follow, never a fan-out to queue.
# Fail-soft: no plans_dir / no slug / no tentative_parent → echoes "" (nothing to
# cycle through — an empty/clearing parent can never be a cycle).
mentor_plan_would_cycle_parent() {
  local plans_dir="${1:-}" slug="${2:-}" parent="${3:-}" node seen
  [ -n "$plans_dir" ] && [ -n "$slug" ] && [ -n "$parent" ] || { echo ""; return 0; }
  if [ "$parent" = "$slug" ]; then echo "cycle"; return 0; fi
  node="$parent"
  seen=" "
  while [ -n "$node" ]; do
    case "$seen" in *" ${node} "*) break ;; esac   # already-visited: a pre-existing
      # torn/circular sidecar graph elsewhere — not a cycle THIS edge would create,
      # so stop rather than spin forever.
    seen="${seen}${node} "
    if [ "$node" = "$slug" ]; then echo "cycle"; return 0; fi
    node="$(mentor_plan_parent "${plans_dir}/${node}")"
  done
  echo ""
  return 0
}

# mentor_plan_descendants <plans_dir> <slug> — echo one TRANSITIVE descendant slug
# per output line (children, grandchildren, …) — every OTHER plan dir under
# <plans_dir> whose `parent` chain (mentor_plan_parent, followed repeatedly) leads
# back to <slug>. BFS over the inverse of the stored parent pointer: there is no
# child-list sidecar field to read directly (only each child's own `parent`), so
# each level requires one pass over every not-yet-seen sibling — same asymptotic
# shape mentor_plan_would_cycle already accepts for a plan set this size. Output
# order is BREADTH-FIRST (a plan before its own children) — NOT the leaf-first
# post-order `/mentor:resume`'s drain needs; that ordering is a consumer-side
# concern layered on top of this bare transitive-closure primitive, same as the
# open/closed verdict `query --subtree` decorates it with. A visited-set guards against a
# torn/circular sidecar graph that already exists (should never happen given the
# write-time cycle refusal above, but a hand-edited .state.json is still possible),
# so this always terminates in at most one pass per depth level. Fail-soft: no
# plans_dir / no slug → no output.
mentor_plan_descendants() {
  local plans_dir="${1:-}" slug="${2:-}" frontier next d child_slug p seen
  [ -n "$plans_dir" ] && [ -n "$slug" ] || return 0
  frontier="$slug"
  seen=" ${slug} "
  while [ -n "$frontier" ]; do
    next=""
    for d in "${plans_dir}"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      child_slug="$(basename "$d")"
      case "$seen" in *" ${child_slug} "*) continue ;; esac
      p="$(mentor_plan_parent "$d")"
      [ -n "$p" ] || continue
      case " ${frontier} " in
        *" ${p} "*)
          echo "$child_slug"
          next="${next} ${child_slug}"
          seen="${seen}${child_slug} "
          ;;
      esac
    done
    frontier="${next# }"
  done
  return 0
}

# mentor_plan_live_handoffs <plan_dir> — echo one LIVE handoff basename per output
# line: <plan_dir>/handoffs/*.md, excluding handoffs/resolved/* — the same anchored
# exclusion (`-not -path '*/handoffs/resolved/*'`) /mentor:resume uses, so a repo path
# or topic slug literally named "resolved" is never false-excluded. Empty when the
# handoffs dir doesn't exist or holds nothing live.
# The exclusion is shared with /mentor:resume; the NAME filter deliberately is not.
# /mentor:resume lists only `^[0-9]{8}-[0-9]{6}-.+\.md$` and skips the rest, so a
# misnamed note is invisible there — which is exactly why `query` must still show
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
# whitespace. A trailing delimiter — whitespace, `:`, `*` (a bold label's closing
# marker), or end of line — is required after the number on both branches (and
# after an optional `.N` sub-step suffix, so a real `Step 4.1 — …` / `4.1. …`
# sub-step heading still matches): without it, a hand-wrapped prose line that
# merely starts with a number reads as its own step — a decimal ("3.5 seconds is
# acceptable here"), a multi-part version ("1.2.3 is the release we target"), or a
# possessive reference to another step ("Step 4.1's design output is ready") —
# inflating the denominator `query` reports and shifting which physical line
# `tick`'s positional write lands ✅ on. Every existing heading form mentor itself
# writes (`1. Title`, `### 1. Title`, `**1.** Title`, `Step 3 — Title`) already
# carries this delimiter naturally, so nothing legitimate loses coverage.
MENTOR_STEP_LINE_PATTERN='^[[:space:]]*(-[[:space:]]+)?([*][*])?(#{3,4}[[:space:]]+)?([0-9]+([.][0-9]+)*\.([[:space:]]|[*]|$)|[Ss]tep[[:space:]]+[0-9]+([.][0-9]+)*([[:space:]]|:|[*]|[.][[:space:]]|[.]$|$))'

# mentor_plan_tick_counts <plan_md> — echo "<ticked> <total>" step-line counts from
# the `## Implementation steps` section, ticked when a step line contains ✅.
# "0 0" when no plan.md or no recognizable step lines. The one parsing
# implementation — mentor_plan_tick_state (below) derives its
# implemented/in_progress/empty verdict FROM these counts, and
# `plan-state.sh query` reports the raw counts for the task-level rung of
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

# Word-boundary truncation length for mentor_plan_goal_line — see its own comment.
MENTOR_GOAL_LINE_MAX=85

# mentor_plan_goal_line <plan_md> [section=goal] — echo the plan's `## <section>`
# section's FIRST paragraph, reflowed to ONE line (Markdown wraps at ~90 cols, so a
# raw line ends mid-sentence), tabs replaced by spaces (so it can never corrupt a
# tab-separated row downstream), and truncated at a word boundary at
# MENTOR_GOAL_LINE_MAX chars with a trailing `…` — added only when truncation
# actually happens. Empty when no plan.md, no matching section, or the section has
# no first paragraph.
#
# `section` generalizes what began as a Goal-only extractor: `mentor:deferring`'s
# stub template writes `## Goal`; an ordinary plan authored by `mentor:planning`'s
# content spec never does — it has `## Context` instead. The default stays `goal`
# so the ONE existing call site (`_plan_walk` in plan-state.sh, gated to
# `origin == "deferred"`) is byte-identical in behavior; a caller that wants an
# ordinary plan's synopsis passes `context` explicitly (see `mentor:plan-track`'s
# Step 1 "broader ask" note) and gets `## Context`'s first paragraph instead. This
# function is still deliberately NOT called for every plan from `_plan_walk`'s
# default walk — see that call site's comment for the hot-path gate this preserves;
# a caller wanting every plan's synopsis pays the extra `plan.md` read itself, on
# only the plans it actually needs to summarize.
#
# The plugin's only other plan.md text-parser besides mentor_plan_tick_counts, and
# built the same way (an awk pass gated on the current `##` section).
mentor_plan_goal_line() {
  local md="${1:-}" section="${2:-goal}" sec_lc para w out candidate
  if [ -z "$md" ] || [ ! -f "$md" ]; then echo ""; return 0; fi
  sec_lc="$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]')"
  para="$(awk -v want="$sec_lc" '
    /^##[[:space:]]/ {
      h = tolower($0)
      insec = (h ~ ("^##[[:space:]]+" want "([[:space:]]|$)")) ? 1 : 0
      next
    }
    !insec { next }
    /^[[:space:]]*$/ {
      if (started) exit
      next
    }
    {
      started = 1
      line = $0
      gsub(/\t/, " ", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      buf = (buf == "") ? line : buf " " line
    }
    END { print buf }
  ' "$md" 2>/dev/null)"
  if [ -z "$para" ]; then echo ""; return 0; fi
  if [ "${#para}" -le "$MENTOR_GOAL_LINE_MAX" ]; then
    printf '%s\n' "$para"
    return 0
  fi
  out=""
  # `read -a` (not a bare `for w in $para`) so a paragraph containing `*`/`[`/`?` —
  # ordinary Markdown emphasis/link syntax — is split on whitespace only, never
  # pathname-expanded against the caller's cwd.
  local -a words
  IFS=' ' read -r -a words <<<"$para"
  for w in "${words[@]}"; do
    if [ -z "$out" ]; then candidate="$w"; else candidate="${out} ${w}"; fi
    [ "${#candidate}" -gt "$MENTOR_GOAL_LINE_MAX" ] && break
    out="$candidate"
  done
  # A single word longer than the limit (e.g. one long inline code span) has no
  # earlier boundary to fall back to — hard-cut it rather than emit nothing.
  [ -z "$out" ] && out="${para:0:$MENTOR_GOAL_LINE_MAX}"
  printf '%s…\n' "$out"
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
#   [--deps a,b] [--origin deferred|""] [--owner W] [--owner-session S]
#   [--priority P|""] [--category C|""] [--deferred-from S] [--parent S|""] —
#   upsert the sidecar (create-then-set: most plans have no sidecar yet).
#
# Flag-style since v2.17.0 (was fixed positional <state> <group> <order> <note>) so a
# write that only touches one or two fields — set-deps, claim, approve-plan's
# promotion — doesn't have to thread every other field through by hand.
#
# AN OMITTED FLAG PRESERVES THE EXISTING STORED VALUE for --state/--group/--order/
# --deps/--origin/--owner/--owner-session/--priority/--category/--deferred-from/
# --parent. This is what lets `deps`/`origin`/`owner`/`priority`/`category`/
# `deferred_from`/`parent` survive every state transition: approve-plan's promotion
# write passes only `--state approved` and every one of those fields rides through
# untouched, instead of getting clobbered back to defaults the way a
# mandatory-positional write would.
# In particular, `set` never passes --owner, --priority, --category,
# --deferred-from, or --parent, so it never touches ownership, the impact tier, the
# work kind, the source plan, or the containing plan — only ensure-dir/init/claim
# stamp ownership, only init/set-priority write the tier, only init/set-category
# write the category, only init writes deferred_from (no set-deferred-from
# subcommand exists), and only init/set-parent write parent — see plan-state.sh.
#
# --note is the ONE exception to "omitted preserves": it is ALWAYS replaced with
# whatever was passed (empty when the flag is omitted) — unchanged from before the
# rework. "note REPLACED every time" is a deliberate feature (a plain `set` with no
# --note clears a stale failure note); a caller that wants to keep the current note
# must re-pass it, the same way `init` already reads it back before writing.
#
# Passing a flag with an EXPLICIT EMPTY VALUE clears that field (group/order/origin/
# owner/owner_session/priority/category/deferred_from/parent → null, deps → [])
# rather than preserving it — this is how `claim` clears origin (`--origin ""`)
# without touching anything else, how a caller can deliberately release ownership
# (`--owner ""`), how `set-priority <slug> ""` un-tiers a plan (`set-category <slug>
# ""` mirrors it for category), and how `set-parent <slug> ""` detaches a plan from
# its parent. --state cannot be cleared this way: an empty/invalid --state is
# rejected outright (fail-soft: no write), same as before. --origin only accepts
# "deferred" or "" (clear), --priority only a MENTOR_PLAN_PRIORITIES value or ""
# (clear), and --category only a MENTOR_PLAN_CATEGORIES value or "" (clear); anything
# else is also rejected, whole write and all — a rejected --priority/--category must
# not leave a half-applied write behind that looks like it worked. --deferred-from
# and --parent are BOTH UNVALIDATED AT THIS LAYER (like `deps` targets) — the source/
# parent plan may not exist, or may be deleted later; that dangle is resolved at
# render time, not here. --parent's existence + cycle validation happens one layer
# up, in plan-state.sh's `init --parent`/`set-parent`, via mentor_plan_would_cycle_parent
# — it needs the WHOLE plans_dir to walk the graph, which this single-plan-dir
# function never has.
#
# jq has no in-place edit, so this is tmp-file + mv. A torn write leaves the sidecar
# unreadable, which reads back as "unknown" — recoverable, because a split child's
# isolation header carries the same group/order inside plan.md. Lost-update semantics:
# the tmp+mv happens inside the sidecar's own dir, so each individual write is atomic —
# but two worktrees writing the same slug's sidecar concurrently can still lose one
# write to the other (last mv wins), never corrupt it.
# Fail-soft: always status 0, echoes nothing; a bad --state/--origin/--priority/
# --category or missing jq writes nothing.
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
  local priority="" priority_set=0
  local category="" category_set=0
  local deferred_from="" deferred_from_set=0
  local parent="" parent_set=0
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
      --priority)
                priority="${2:-}"; priority_set=1; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --category)
                category="${2:-}"; category_set=1; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --deferred-from)
                deferred_from="${2:-}"; deferred_from_set=1; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --parent) parent="${2:-}"; parent_set=1; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      *) shift ;;   # fail-soft: an unrecognized flag is ignored, never aborts a caller
    esac
  done
  [ -n "$d" ] && [ -d "$d" ] || return 0
  if [ "$state_set" -eq 1 ] && ! mentor_plan_state_valid "$state"; then return 0; fi
  if [ "$origin_set" -eq 1 ] && [ -n "$origin" ] && [ "$origin" != "deferred" ]; then return 0; fi
  if [ "$priority_set" -eq 1 ] && [ -n "$priority" ] && ! mentor_plan_priority_valid "$priority"; then return 0; fi
  if [ "$category_set" -eq 1 ] && [ -n "$category" ] && ! mentor_plan_category_valid "$category"; then return 0; fi
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
        --arg owner_session "$owner_session" --argjson owner_session_set "$owner_session_set" \
        --arg priority "$priority" --argjson priority_set "$priority_set" \
        --arg category "$category" --argjson category_set "$category_set" \
        --arg deferred_from "$deferred_from" --argjson deferred_from_set "$deferred_from_set" \
        --arg parent "$parent" --argjson parent_set "$parent_set" '
        {
          state: (if $state_set == 1 then $state else (.state // null) end),
          group: (if $group_set == 1 then (if $group == "" then null else $group end) else (.group // null) end),
          order: (if $order_set == 1 then (if $order == "" then null else ($order | tonumber? // null) end) else (.order // null) end),
          note:  $note,
          deps:  (if $deps_set == 1 then $deps else (.deps // []) end),
          origin: (if $origin_set == 1 then (if $origin == "" then null else $origin end) else (.origin // null) end),
          owner: (if $owner_set == 1 then (if $owner == "" then null else $owner end) else (.owner // null) end),
          owner_session: (if $owner_session_set == 1 then (if $owner_session == "" then null else $owner_session end) else (.owner_session // null) end),
          priority: (if $priority_set == 1 then (if $priority == "" then null else $priority end) else (.priority // null) end),
          category: (if $category_set == 1 then (if $category == "" then null else $category end) else (.category // null) end),
          deferred_from: (if $deferred_from_set == 1 then (if $deferred_from == "" then null else $deferred_from end) else (.deferred_from // null) end),
          parent: (if $parent_set == 1 then (if $parent == "" then null else $parent end) else (.parent // null) end)
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

# mentor_list_handoffs <repo_root> — echo every conforming handoff note
# (<YYYYMMDD-HHMMSS>-<slug>.md under plans/*/handoffs/ or the legacy flat handoffs/ —
# the exact locations /mentor:resume lists), newest first, one per line. Non-conforming
# names are skipped; notes stamped resolved (moved into a handoffs/resolved/ subdir on
# completion or supersession) never match the globs, so solved notes stop counting as fresh.
# With no repo_root, falls back to ~/.claude/mentor/_no-repo — the dir the handoff skill
# writes to outside a git repo — so no-repo sessions get the same freshness handling. The
# one place the name-shape/location contract lives — mentor_latest_handoff and
# mentor_live_handoff_count both derive from it instead of re-globbing independently.
mentor_list_handoffs() {
  local state_dir f
  state_dir="$(mentor_state_dir "${1:-}")"
  if [ -z "$state_dir" ]; then state_dir="${HOME}/.claude/mentor/_no-repo"; fi
  while IFS= read -r f; do
    case "${f##*/}" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.md)
        printf '%s\n' "$f" ;;
    esac
  done < <(ls -t "${state_dir}"/plans/*/handoffs/*.md "${state_dir}/handoffs"/*.md 2>/dev/null || true)
  return 0
}

# mentor_latest_handoff <repo_root> — echo the mtime-newest conforming handoff note, or
# empty when none exist. See mentor_list_handoffs for the location/name-shape contract.
mentor_latest_handoff() {
  mentor_list_handoffs "${1:-}" | head -1
  return 0
}

# mentor_live_handoff_count <repo_root> — echo the number of conforming, unresolved
# handoff notes across every topic in this repo (the same set mentor_latest_handoff
# picks its newest from), or 0 when none exist.
mentor_live_handoff_count() {
  mentor_list_handoffs "${1:-}" | wc -l | tr -d ' '
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

# --- sweep: the portable, self-reporting search over mentor's own state (v2.33.0) ---
#
# WHY THIS EXISTS. mentor prescribes searching its own state dir in three places
# (dispatch-agents' standing-policy check, planning's Step 2 research sweep,
# plan-review's count-mismatch reconciliation). All three used to prescribe
# a recursive grep plus GNU/ripgrep's no-ignore flag, which is broken twice over:
#
#   1. That no-ignore flag is GNU-grep/ripgrep-only. ugrep — a drop-in `grep` many
#      developers install via Homebrew — rejects it outright: exit 2 and a usage wall,
#      so the prescribed command cannot run at all.
#   2. Dropping the flag is SILENTLY worse. `.mentor/.gitignore` contains `*`, so a grep
#      that honors ignore rules during its own traversal reads nothing there and reports
#      a clean zero — indistinguishable from "no policy is recorded".
#
# AND THIS IS NOT A MACHINE-SPECIFIC QUIRK, which is the part worth internalizing: the
# ignore-aware grep is not something the developer installed. Claude Code injects a `grep`
# shell FUNCTION into the Bash tool's shell that routes to its own bundled ugrep with
# `--ignore-files --hidden -I` already on. Measured here: /usr/bin/grep is BSD grep
# 2.6.0-FreeBSD and finds the gitignored note fine, while `grep` as an agent actually
# invokes it does not. So every agent running `grep -r` over `.mentor/` in this harness
# hits defect 2 by default, whatever greps are installed — and because the wrapper is a
# function rather than a PATH entry, a script launched as `bash foo.sh` silently gets a
# DIFFERENT grep than the same command typed at the Bash tool. Never conclude from "it
# worked in my test script" that it works where the skills prescribe it.
#
# The escape is STRUCTURAL, not a better flag: ignore rules apply only when GREP does the
# walking. Hand grep an explicit list of files and it reads every one of them, under GNU
# grep, BSD grep and ugrep alike. So `find` walks and `grep` only reads.
#
# Measured on ugrep 7.5.0 in this repo:
#   grep -rl 'No subagents' .mentor/        -> 0 hits   (traversal root IS the ignored dir)
#   grep -rl 'No subagents' .mentor/plans/  -> 5 hits   (root sits BELOW the `*` rule)
#   find .mentor -type f -exec grep -l … {} + -> 5 hits (find walks; grep never decides)
#
# ugrep reads .gitignore files at or BELOW the traversal root and never walks *up*, which
# is the whole reason the second line differs from the first — and why `plan-split`'s
# sweep at `$plans_dir` happens to work untouched. Do NOT "simplify" the code below back
# to a recursive grep aimed one level deeper (it breaks the moment a caller re-aims it),
# and do NOT reach for ugrep's own no-ignore-files spelling: it is ugrep-ONLY, so it moves
# the bug to a different machine.
#
# Only POSIX grep flags are used here (-I -H -n -i -e --) and no -r/-R at all. `-H` is
# mandatory, not decorative: without it a SINGLE-file file list prints a bare `15:` with
# no path, which is useless to a caller reconciling hits against files.
#
# NOTE ON SPELLING: the two retired flags are named WITHOUT their leading double dash
# throughout this comment, on purpose. A regression test asserts ZERO occurrences of the
# dashed spellings anywhere under plugins/mentor/ — that invariant is what actually stops
# the broken form being prescribed again, and prose describing it must not be what trips
# it. Do not "fix" the punctuation here; see tests/test-sweep.sh section K, which records
# both exact spellings via split string literals for the same reason.

# mentor_sweep_roots <cwd> <set> — echo one EXISTING root path per line for the named
# set, or nothing when none exist. Never errors on a missing root; an unknown set name
# echoes nothing (callers validate the name themselves and report it as a usage error).
#
# CLAUDE.md and .claude/ resolve against `git rev-parse --show-toplevel` — THIS worktree's
# own checkout — while .mentor/plans resolves via mentor_repo_root (git-common-dir, the
# main repo every worktree shares). Using one resolution for both is wrong in a linked
# worktree: it would read another tree's CLAUDE.md, or look for .mentor/ where there is
# none. Every test in `if` form, never `a && b && echo`: a trailing false `&&` list is a
# failed simple command, which would abort a `set -e` caller (see this file's CONTRACT).
mentor_sweep_roots() {
  local cwd="${1:-$PWD}" set_name="${2:-policy}" toplevel main_root plans
  toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  main_root="$(mentor_repo_root "$cwd")"
  plans="$(mentor_plans_dir "$main_root")"
  case "$set_name" in
    policy)
      if [ -n "$toplevel" ] && [ -f "${toplevel}/CLAUDE.md" ]; then echo "${toplevel}/CLAUDE.md"; fi
      if [ -n "$toplevel" ] && [ -d "${toplevel}/.claude" ]; then echo "${toplevel}/.claude"; fi
      if [ -n "$plans" ] && [ -d "$plans" ]; then echo "$plans"; fi
      ;;
    plans)
      if [ -n "$plans" ] && [ -d "$plans" ]; then echo "$plans"; fi
      ;;
    repo)
      if [ -n "$toplevel" ] && [ -d "$toplevel" ]; then echo "$toplevel"; fi
      ;;
  esac
  return 0
}

# mentor_sweep <cwd> <set> <pattern> [ignore_case] — search <pattern> across the named
# root set. Echoes ONE counts line first:
#
#     <roots> <files> <hits>
#
# followed by one `path:line:text` hit per line. `files` is the denominator that makes a
# zero trustworthy: it separates "read 185 files, none matched" from "read nothing at
# all". A non-empty <ignore_case> adds `grep -i`.
#
# Callers own the exit-code policy (plan-state.sh `sweep` maps hits>0 -> 0, files>0 with
# no hits -> 1, files==0 -> 2). This function is fail-soft and always returns 0, per the
# CONTRACT at the top of this file.
mentor_sweep() {
  local cwd="${1:-$PWD}" set_name="${2:-policy}" pattern="${3:-}" icase="${4:-}"
  local roots r root_count files out hits
  local -a root_args find_args grep_args
  roots="$(mentor_sweep_roots "$cwd" "$set_name")"
  if [ -z "$roots" ] || [ -z "$pattern" ]; then echo "0 0 0"; return 0; fi
  root_count=0
  root_args=()
  while IFS= read -r r; do
    if [ -n "$r" ]; then root_args+=("$r"); root_count=$((root_count + 1)); fi
  done <<<"$roots"
  if [ "$root_count" -eq 0 ]; then echo "0 0 0"; return 0; fi

  # ONE traversal expression, built once and reused by both passes below. It is deliberately
  # not written out twice: the counting pass and the grepping pass must walk exactly the same
  # set, or `files=` stops describing what was actually searched — and a denominator that
  # doesn't match the search is precisely the false confidence this subcommand exists to
  # remove. Two literal copies would let a later edit change one and not the other, silently.
  # `-name .git -prune` drops git's own store from the `repo` set — as a DIR in the main
  # worktree and as a FILE in a linked one, which this predicate covers either way.
  find_args=("${root_args[@]}" -name .git -prune -o -type f -print0)

  # Counting NUL bytes is the only newline-safe count that holds on BSD tools: piping
  # through `tr '\0' '\n' | wc -l` over-counts a filename containing a newline, and BSD
  # awk silently ignores RS="\0" and reports 1 for any list.
  files="$(find "${find_args[@]}" 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ' || true)"
  files="${files:-0}"
  # Return before xargs when there is nothing to search: BSD and GNU xargs disagree about
  # running the utility on empty input, and a `grep` invoked with no file operands reads
  # STDIN — which would hang here rather than report the nothing-searched verdict.
  if [ "$files" -eq 0 ]; then echo "${root_count} 0 0"; return 0; fi

  grep_args=(-I -H -n)
  if [ -n "$icase" ]; then grep_args+=(-i); fi
  # `-e` guards a pattern beginning with `-`; the trailing `--` guards a FILENAME
  # beginning with `-` (xargs appends the file operands after it).
  out="$(find "${find_args[@]}" 2>/dev/null \
         | xargs -0 grep "${grep_args[@]}" -e "$pattern" -- 2>/dev/null || true)"
  # The hit count comes from the OUTPUT, never from grep's exit status: a long file list
  # is split across several xargs batches, so the status reflects only the LAST batch.
  if [ -z "$out" ]; then hits=0; else hits="$(printf '%s\n' "$out" | grep -c . || true)"; fi
  echo "${root_count} ${files} ${hits:-0}"
  if [ -n "$out" ]; then printf '%s\n' "$out"; fi
  return 0
}
