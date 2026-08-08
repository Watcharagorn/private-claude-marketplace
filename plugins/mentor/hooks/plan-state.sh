#!/usr/bin/env bash
# plan-state.sh — the ONE plan-state API. Read and write .mentor/plans/<slug>/.state.json
# (and, via `tick`, the ✅ step marks in plan.md that the sidecar's effective state derives from).
#
# Not a hook: skills call it as a plain Bash command, like approve-plan.sh.
# It exists so no skill ever hand-rolls the sidecar JSON, and so the three places
# that used to resolve "the current plan" with their own `ls -t` share one answer.
#
#   init <slug> [--group G] [--order N] [--deps a,b] [--deferred]
#       Create the sidecar as `draft`. Idempotent and never LOWERS an existing
#       state — re-running it on an approved plan keeps it approved. --deps sets the
#       initial dependency slugs (cycle-checked, same as set-deps); --deferred marks
#       the plan a stub born via /mentor:defer (origin: "deferred" — shields it from
#       approve-plan's promotion sweep until `claim`ed).
#
#   set <slug> <state> [--note "…"]
#       Upsert (create-then-set): most plans predate the sidecar. <state> is one of
#       draft approved in_progress implemented failed superseded.
#       The note is REPLACED every time, so a plain `set` clears a stale failure note.
#
#   set-deps <slug> a,b
#       Replace <slug>'s deps wholesale with the given comma-separated plan slugs
#       (empty string clears them). Unknown slugs are allowed — the dep plan may be
#       deferred later. Refuses a write that would create a dependency cycle (direct
#       self-cycle or transitive): fail-soft, stderr warning, no write.
#
#   claim <slug>
#       Clear `origin` — used when a deferred stub (born via /mentor:defer) enters
#       real planning, so approve-plan's promotion sweep can promote it like any plan.
#
#   tick <slug> <N>
#       Append ✅ to the Nth step line in plan.md's `## Implementation steps` section
#       (idempotent — already-ticked is a no-op) — replaces hand-rolling an Edit to
#       find and mark that exact line, whose placement is load-bearing (a tick on
#       the wrong line reads as the step never having started). No such step at N →
#       fails loud, no write. Needs no jq: unlike every other subcommand here this
#       edits plan.md directly, not the JSON sidecar.
#
#   list [--group G]
#       One row per plan: ordinal, EFFECTIVE state, slug, group, order.
#       Grouped, ordered within a group, `superseded` and `unknown` last.
#
#   current
#       The plan a bare "review the plan" means. Skips superseded. When the answer
#       belongs to a split group it prints the whole group and says so, instead of
#       silently picking one of N children.
#
#   overview --json
#       Repo-wide JSON array (--json is required — there is no human-table mode): one
#       object per plan dir with a plan.md (slug, effective state, group, order, deps
#       — each marked missing when no such plan dir exists, origin, live handoffs,
#       ticked/total step counts), plus topic dirs that hold live handoffs but no
#       plan.md yet (state "no plan yet") and the legacy flat handoffs/ dir (topic-less).
#       Computed fresh every call — nothing is cached.
#
#   context
#       CONTEXT: ASK|HANDOFF|WARN|OK|UNKNOWN (~N tokens), plus the handoff/compact
#       steer on ASK. /mentor:track calls this before dispatching: context-gate.sh passes
#       every slash-prefixed prompt, so a slash command that starts an implementation
#       has no other backstop.
#
#   dir [--plans]
#       The repo-scoped mentor dir (<repo_root>/.mentor via git-common-dir, so linked
#       worktrees share one; ~/.claude/mentor/_no-repo outside a repo) — one path on
#       stdout. Skills call this instead of hand-rolling the derivation: the inlined
#       copies drifted, and most dropped the no-repo fallback.
#
#   gate [--verbose]
#       ARMED|RELEASED|STALE, exactly one token on stdout (line 1, always — bare
#       `gate` and `gate --verbose` alike) — the plan-gate marker's status,
#       READ-ONLY (never deletes the marker; plan-gate.sh is its only
#       writer/remover, so its self-heal notice is never silently swallowed
#       elsewhere, and a guard run just past the threshold during genuinely live
#       planning can never disarm the gate as a side effect). STALE means the
#       marker is still on disk but older than MENTOR_PLAN_MARKER_STALE_MIN
#       (lib/state.sh, ~8h) — plan-gate.sh hasn't self-healed it yet, but for
#       every other caller it reads as not-armed. Outside a repo (or no marker)
#       → RELEASED. This answers "is the gate armed", not "should it be" — a
#       caller that instead needs "we're inside a repo and planning should have
#       started" wants a different check.
#       --verbose is strictly additive: bare `gate` is unchanged (plan-track's and
#       touring's `[ "$(… gate)" = "ARMED" ]` string-equality checks depend on
#       staying exactly one token). On ARMED only, --verbose appends
#       owner_session=/owner_cwd=/age_min= (the same mentor_marker_field/
#       mentor_marker_age_min facts plan-gate.sh's own deny message already
#       computes) plus affected_plans= — the plan slugs whose plan.md is newer
#       than the marker, i.e. exactly the candidates approve-plan.sh would
#       promote to `approved` if run right now. RELEASED/STALE print nothing
#       past the token even under --verbose — there is no "owner" to report.
#
# EFFECTIVE state (see lib/state.sh): the more advanced of the stored state and the
# state derived from plan.md's ✅ step ticks. A forgotten `set` therefore costs
# nothing, and a pre-2.4.0 plan dir with no sidecar reads `unknown` — never `draft`.
#
# Exit codes: 1 for a usage error (unknown subcommand, bad state, missing/unknown
# slug) — mirroring approve-plan.sh. Everything environmental is fail-soft: no repo,
# no plans dir, no jq, nothing to report → empty stdout, ONE reason line on stderr,
# exit 0. Silent-empty would be indistinguishable from "no plans" and the calling
# skill would improvise a listing.

set -euo pipefail

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${hook_dir}/lib/state.sh"

usage() {
  cat <<'EOF'
Usage: plan-state.sh <subcommand>
  init <slug> [--group G] [--order N] [--deps a,b] [--deferred]
                                         create the sidecar as draft (idempotent)
  set <slug> <state> [--note "…"]       state: draft|approved|in_progress|implemented|failed|superseded
  set-deps <slug> a,b                   replace deps wholesale (cycle-checked, fail-soft)
  claim <slug>                          clear origin (a deferred stub enters real planning)
  tick <slug> <N>                       append ✅ to step N in plan.md (idempotent, fails loud)
  list [--group G]                      every plan with its effective state
  current                               the current plan (group-aware)
  overview --json                       repo-wide JSON: plans + deps + live handoffs + step counts
  context                               CONTEXT: ASK|HANDOFF|WARN|OK|UNKNOWN (~N tokens)
  dir [--plans]                         the repo-scoped mentor dir (or its plans dir)
  gate [--verbose]                      ARMED|RELEASED|STALE — read-only marker status
                                         (--verbose adds owner/age/affected-plans on ARMED)
  ensure-dir <path>                     mkdir it + chmod 700 the whole path; echoes it
EOF
}

sub="${1:-}"
[ "$#" -gt 0 ] && shift

# --- context: the only subcommand that needs neither a repo nor a plans dir ---
if [ "$sub" = "context" ]; then
  ctx_repo="$(mentor_repo_root "$(pwd)")"
  verdict="$(mentor_context_verdict "$ctx_repo" "$(pwd)")"
  if [ -z "$verdict" ]; then
    echo "CONTEXT: UNKNOWN (not measurable — gate off, or no transcript/jq). Proceed."
    exit 0
  fi
  read -r level tokens warn_at ask_at <<<"$verdict"
  case "$level" in
    ASK)
      cat <<EOF
CONTEXT: ASK (~${tokens} tokens ≥ ${ask_at})
[mentor] Do NOT dispatch implementation yet — the user decides first. An
implementation started this deep into a session degrades partway through.
Ask via AskUserQuestion (header "Context", two options):
  1. "Hand off & build in a fresh session (Recommended)" — invoke
     Skill(skill="mentor:handoff-note") with the chosen plan as the focus, write the
     handoff doc, print its copy-paste /mentor:resume prompt, and STOP.
  2. "Proceed anyway (bypass for this session)" — run
     \`bash ${hook_dir}/bypass-context.sh\`, then re-run this command and continue.
(Threshold: "context_block_tokens" in .mentor/config.json or MENTOR_CONTEXT_BLOCK_TOKENS;
disable entirely with MENTOR_CONTEXT_GATE=off.)
EOF
      ;;
    HANDOFF)
      echo "CONTEXT: HANDOFF (~${tokens} tokens ≥ ${ask_at})"
      echo "[mentor] Critically large, but the user already chose to continue this"
      echo "session — proceed. Build ONE plan, keep it lean, and hand off before the"
      echo "next one (/mentor:handoff → /mentor:resume)."
      ;;
    WARN)
      echo "CONTEXT: WARN (~${tokens} tokens ≥ ${warn_at})"
      echo "[mentor] Surface this to the user: one plan is fine, but recommend a fresh"
      echo "session (/mentor:handoff → /mentor:resume) before starting the next one."
      ;;
    *)
      echo "CONTEXT: OK (~${tokens} tokens)"
      ;;
  esac
  exit 0
fi

# --- dir: pure path derivation — needs neither a repo (fallback) nor a plans dir ---
if [ "$sub" = "dir" ]; then
  dir_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$dir_repo" ]; then
    mdir="$(mentor_state_dir "$dir_repo")"
  else
    mdir="$HOME/.claude/mentor/_no-repo"
  fi
  if [ "${1:-}" = "--plans" ]; then
    echo "${mdir}/plans"
  else
    echo "$mdir"
  fi
  exit 0
fi

# --- ensure-dir: create a mentor artifact dir and lock the whole path to 700 ---
# Skills call this instead of `mkdir -p -m 700`, which cannot deliver what it promises
# (see mentor_ensure_private_dir). Echoing the path lets a snippet read
# `d="$(plan-state.sh ensure-dir "$d")"`, so a failure kills the pipeline before the write
# rather than silently leaving the dir wide open.
if [ "$sub" = "ensure-dir" ]; then
  ed_target="${1:-}"
  if [ -z "$ed_target" ]; then
    echo "[mentor plan-state] ensure-dir needs a directory path." >&2
    exit 1
  fi
  ed_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$ed_repo" ]; then
    ed_mdir="$(mentor_state_dir "$ed_repo")"
  else
    ed_mdir="$HOME/.claude/mentor/_no-repo"
  fi
  # Confine it. Callers substitute a model-chosen <topic> into the path, so without this
  # check ensure-dir would be an arbitrary mkdir-and-chmod primitive reachable from a
  # prompt. Compare canonically so `..` cannot walk out.
  ed_canon="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ed_target" 2>/dev/null || echo "$ed_target")"
  ed_base="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ed_mdir" 2>/dev/null || echo "$ed_mdir")"
  case "$ed_canon" in
    "$ed_base"|"$ed_base"/*) ;;
    *)
      echo "[mentor plan-state] ensure-dir refuses a path outside ${ed_mdir}: ${ed_target}" >&2
      exit 1
      ;;
  esac
  mentor_ensure_private_dir "$ed_mdir" "$ed_canon"
  echo "$ed_canon"
  exit 0
fi

# --- gate: read-only plan-gate marker status — needs neither a repo (fallback) nor a
# plans dir, same as dir/ensure-dir above. Never deletes the marker — see the doc
# comment near the top of this file for why plan-gate.sh stays its only remover.
if [ "$sub" = "gate" ]; then
  g_verbose=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verbose) g_verbose=1; shift ;;
      *) echo "[mentor plan-state] gate: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
    esac
  done
  g_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$g_repo" ]; then
    g_mdir="$(mentor_state_dir "$g_repo")"
  else
    g_mdir="$HOME/.claude/mentor/_no-repo"
  fi
  g_marker="${g_mdir}/plans/.planning"
  if [ ! -e "$g_marker" ]; then
    echo RELEASED
  elif mentor_marker_stale "$g_marker"; then
    echo STALE
  else
    echo ARMED
    # Additive-only, ARMED-only: RELEASED/STALE have no "owner" to report, and the
    # bare token above already printed — a caller doing `[ "$(gate)" = "ARMED" ]`
    # never sees these lines because that form passes no --verbose.
    if [ "$g_verbose" -eq 1 ]; then
      echo "owner_session=$(mentor_marker_field "$g_marker" session)"
      echo "owner_cwd=$(mentor_marker_field "$g_marker" cwd)"
      echo "age_min=$(mentor_marker_age_min "$g_marker")"
      # Same computation as approve-plan.sh's newly_planned snapshot: the plan
      # dirs approve-plan.sh would treat as "written this planning session" and
      # promote toward `approved` if run right now — the fact that actually
      # answers "would approving this clobber a plan I never reviewed?".
      g_affected="$(find "${g_mdir}/plans" -mindepth 2 -maxdepth 2 -name plan.md -newer "$g_marker" 2>/dev/null \
        | while IFS= read -r g_p; do basename "$(dirname "$g_p")"; done | paste -sd' ' -)"
      echo "affected_plans=${g_affected}"
    fi
  fi
  exit 0
fi

case "$sub" in
  init|set|set-deps|claim|tick|list|current|overview) ;;
  ""|-h|--help|help)
    usage
    [ -n "$sub" ] && exit 0
    echo "[mentor plan-state] Missing subcommand." >&2
    exit 1
    ;;
  *)
    echo "[mentor plan-state] Unknown subcommand: ${sub}" >&2
    usage >&2
    exit 1
    ;;
esac

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  echo "[mentor plan-state] Not in a git repo — mentor keeps no plan registry here." >&2
  exit 0
fi
plans_dir="$(mentor_plans_dir "$repo_root")"
if [ ! -d "$plans_dir" ]; then
  echo "[mentor plan-state] No plans dir yet (${plans_dir}) — nothing planned in this repo." >&2
  exit 0
fi

# --- shared per-plan iterator --------------------------------------------------
# _plan_walk [group-filter] — the ONE walk over plans_dir for every plan dir that has
# a plan.md. Emits one tab-separated RAW record per line, unsorted:
#   slug  state  group  order  deps_json  origin  handoffs_json  ticked  total
# `deps_json`/`handoffs_json` are compact (`jq -c`) single-line JSON — safe to sit in
# a tab field because compact jq output never contains a literal tab or newline, even
# inside a string. `list_rows` (below, byte-compatible with the pre-v2.17.0 format)
# and `overview --json` (new) both derive from this ONE walk — neither re-walks
# plans_dir on its own. `list`/`current` never needed deps/handoffs/step-counts, so
# computing them for those two callers too is a deliberate small cost in exchange for
# there being exactly one place that decides what "every plan" means.
_plan_walk() {
  local filter="${1:-}" d slug state group order origin deps_pairs deps_json
  local handoffs_json ticked total dep miss
  for d in "${plans_dir}"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "${d}/plan.md" ] || continue
    slug="$(basename "$d")"
    state="$(mentor_plan_effective_state "$d")"
    group="$(mentor_plan_group "$d")"   # sidecar, else the isolation header
    if [ -n "$filter" ] && [ "$group" != "$filter" ]; then continue; fi
    order="$(mentor_plan_order "$d")"
    origin="$(mentor_plan_origin "$d")"
    deps_pairs=""
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      if [ -d "${plans_dir}/${dep}" ]; then miss=false; else miss=true; fi
      deps_pairs="${deps_pairs}${dep}$(printf '\t')${miss}
"
    done <<<"$(mentor_plan_deps "$d")"
    deps_json="$(printf '%s' "$deps_pairs" | jq -R -s -c '
      split("\n") | map(select(length>0) | split("\t") | {slug: .[0], missing: (.[1] == "true")})
    ' 2>/dev/null)"
    [ -n "$deps_json" ] || deps_json="[]"
    handoffs_json="$(mentor_plan_live_handoffs "$d" | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null)"
    [ -n "$handoffs_json" ] || handoffs_json="[]"
    read -r ticked total <<<"$(mentor_plan_tick_counts "${d}/plan.md")"
    # IFS-whitespace read pitfall: a lone tab in IFS is still "IFS whitespace" to
    # bash's `read` — consecutive tabs COLLAPSE instead of producing an empty field,
    # so a genuinely-empty group/order/origin would silently shift every field after
    # it for whoever reads this line. Emit "-" for empty (matching print_table's own
    # existing display convention) and never a raw empty string here; consumers
    # translate "-" back to "" on read.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$slug" "$state" "${group:--}" "${order:--}" "$deps_json" "${origin:--}" "$handoffs_json" "$ticked" "$total"
  done
}

# list_rows [group-filter] — the pre-v2.17.0 5-field row format, byte-compatible:
# <sortkey> <slug> <effective state> <group> <order>, tab-separated and sorted.
# Sort key: bucket (0 active / 1 superseded+unknown) | group (ungrouped sorts on its
# own slug, so it neither splits a group nor clumps with one) | zero-padded order |
# slug. Derived from _plan_walk's raw records — see that function's comment for why
# this is no longer its own directory walk.
list_rows() {
  local filter="${1:-}" slug state group order _rest bucket gkey okey
  while IFS="$(printf '\t')" read -r slug state group order _rest; do
    [ -n "$slug" ] || continue
    [ "$group" = "-" ] && group=""   # un-placeholder — see _plan_walk's comment
    [ "$order" = "-" ] && order=""
    case "$state" in
      superseded|unknown) bucket=1 ;;
      *)                  bucket=0 ;;
    esac
    gkey="${group:-$slug}"
    case "$order" in
      ''|*[!0-9]*) okey="999" ;;
      *)           okey="$(printf '%03d' "$order")" ;;
    esac
    printf '%s|%s|%s|%s\t%s\t%s\t%s\t%s\n' \
      "$bucket" "$gkey" "$okey" "$slug" "$slug" "$state" "${group:--}" "${order:--}"
  done <<<"$(_plan_walk "$filter")" | LC_ALL=C sort -t"$(printf '\t')" -k1,1
}

print_table() {
  local filter="${1:-}" rows i=0 key slug state group order
  rows="$(list_rows "$filter")"
  if [ -z "$rows" ]; then
    return 1
  fi
  printf '%-3s %-13s %-38s %-24s %s\n' "#" "STATE" "PLAN" "GROUP" "ORDER"
  while IFS="$(printf '\t')" read -r key slug state group order; do
    [ -n "$slug" ] || continue
    i=$((i + 1))
    printf '%-3s %-13s %-38s %-24s %s\n' "$i" "$state" "$slug" "$group" "$order"
  done <<<"$rows"
  return 0
}

require_slug() {
  local slug="${1:-}"
  if [ -z "$slug" ]; then
    echo "[mentor plan-state] ${sub}: a <slug> is required." >&2
    usage >&2
    exit 1
  fi
  if [ ! -d "${plans_dir}/${slug}" ]; then
    echo "[mentor plan-state] No such plan: ${plans_dir}/${slug}" >&2
    echo "Run 'plan-state.sh list' to see the slugs that exist." >&2
    exit 1
  fi
}

require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "[mentor plan-state] jq not found — plan state cannot be written. Install jq;" >&2
  echo "until then mentor derives state from the plan's ✅ step ticks alone." >&2
  exit 0
}

# require_jq_read — the READ-side counterpart for overview (which never writes):
# a single stderr line and exit 0, per this file's fail-soft convention for
# environmental problems (see the header comment).
require_jq_read() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "[mentor plan-state] jq not found — cannot compute overview." >&2
  exit 0
}

case "$sub" in

  init)
    slug=""; group=""; order=""; deps=""; deferred=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        # shift 1 then conditionally 1 more: a bare trailing `--group` must not
        # leave $# unchanged and spin this loop forever.
        --group) group="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --order) order="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --deps) deps="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --deferred) deferred=1; shift ;;
        -*) echo "[mentor plan-state] init: unknown flag ${1}" >&2; usage >&2; exit 1 ;;
        *)  [ -z "$slug" ] && slug="$1" || { echo "[mentor plan-state] init: unexpected argument ${1}" >&2; exit 1; }; shift ;;
      esac
    done
    require_slug "$slug"
    require_jq
    plan_dir="${plans_dir}/${slug}"
    # Idempotent: keep whatever state is already on record; only fill in a missing one.
    existing="$(mentor_plan_state_stored "$plan_dir")"
    write_args=(--state "${existing:-draft}" --note "$(mentor_plan_state_field "$plan_dir" note)")
    [ -n "$group" ] && write_args+=(--group "$group")
    [ -n "$order" ] && write_args+=(--order "$order")
    deps_summary=""
    if [ -n "$deps" ]; then
      clean_deps=()
      IFS=',' read -r -a raw_deps <<<"$deps"
      for x in "${raw_deps[@]:-}"; do
        x="$(printf '%s' "$x" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$x" ] && clean_deps+=("$x")
      done
      if [ "${#clean_deps[@]}" -gt 0 ]; then
        if [ -n "$(mentor_plan_would_cycle "$plans_dir" "$slug" "${clean_deps[*]}")" ]; then
          echo "[mentor plan-state] init: --deps would create a dependency cycle (${slug} → … → ${slug}) — deps NOT set; other fields still applied." >&2
        else
          deps_summary="$(IFS=,; echo "${clean_deps[*]}")"
          write_args+=(--deps "$deps_summary")
        fi
      fi
    fi
    [ "$deferred" -eq 1 ] && write_args+=(--origin deferred)
    mentor_plan_state_write "$plan_dir" "${write_args[@]}"
    echo "[mentor plan-state] ${slug}: $(mentor_plan_effective_state "$plan_dir")${group:+  group=${group}}${order:+  order=${order}}${deps_summary:+  deps=${deps_summary}}$([ "$deferred" -eq 1 ] && printf '  origin=deferred')"
    ;;

  set)
    slug=""; state=""; note=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --note) note="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        -*) echo "[mentor plan-state] set: unknown flag ${1}" >&2; usage >&2; exit 1 ;;
        *)
          if [ -z "$slug" ]; then slug="$1"
          elif [ -z "$state" ]; then state="$1"
          else echo "[mentor plan-state] set: unexpected argument ${1}" >&2; exit 1
          fi
          shift ;;
      esac
    done
    require_slug "$slug"
    if ! mentor_plan_state_valid "$state"; then
      echo "[mentor plan-state] set: invalid state '${state}'." >&2
      echo "Valid states: ${MENTOR_PLAN_STATES}" >&2
      exit 1
    fi
    require_jq
    plan_dir="${plans_dir}/${slug}"
    before="$(mentor_plan_effective_state "$plan_dir")"
    mentor_plan_state_write "$plan_dir" --state "$state" --note "$note"
    after="$(mentor_plan_effective_state "$plan_dir")"
    echo "[mentor plan-state] ${slug}: ${before} → ${after}${note:+  (${note})}"
    # The effective read can outrank what was just stored — say so rather than let a
    # caller believe the sidecar is the last word.
    if [ "$after" != "$state" ]; then
      echo "[mentor plan-state] note: '${state}' stored, but the plan's ✅ step ticks report '${after}'."
    fi
    ;;

  set-deps)
    slug="${1:-}"; [ "$#" -gt 0 ] && shift
    depstr="${1:-}"; [ "$#" -gt 0 ] && shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] set-deps: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    require_slug "$slug"
    require_jq
    plan_dir="${plans_dir}/${slug}"
    clean_deps=()
    IFS=',' read -r -a raw_deps <<<"$depstr"
    for x in "${raw_deps[@]:-}"; do
      x="$(printf '%s' "$x" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -n "$x" ] && clean_deps+=("$x")
    done
    if [ "${#clean_deps[@]}" -gt 0 ] && [ -n "$(mentor_plan_would_cycle "$plans_dir" "$slug" "${clean_deps[*]}")" ]; then
      echo "[mentor plan-state] set-deps: refused — ${slug} → … → ${slug} would be a dependency cycle. No write." >&2
      exit 0
    fi
    clean_csv=""
    [ "${#clean_deps[@]}" -gt 0 ] && clean_csv="$(IFS=,; echo "${clean_deps[*]}")"
    # Re-read and re-pass the note: mentor_plan_state_write always REPLACES --note
    # (even when omitted, which would clear it), so a deps-only write must round-trip
    # the current note to avoid silently wiping it.
    mentor_plan_state_write "$plan_dir" --deps "$clean_csv" --note "$(mentor_plan_state_field "$plan_dir" note)"
    echo "[mentor plan-state] ${slug}: deps = ${clean_csv:-(none)}"
    ;;

  claim)
    slug="${1:-}"; [ "$#" -gt 0 ] && shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] claim: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    require_slug "$slug"
    require_jq
    plan_dir="${plans_dir}/${slug}"
    was_deferred="$(mentor_plan_origin "$plan_dir")"
    mentor_plan_state_write "$plan_dir" --origin "" --note "$(mentor_plan_state_field "$plan_dir" note)"
    if [ "$was_deferred" = "deferred" ]; then
      echo "[mentor plan-state] ${slug}: claimed — origin cleared, eligible for the normal approval sweep."
    else
      echo "[mentor plan-state] ${slug}: origin already unset — nothing to claim."
    fi
    ;;

  tick)
    slug="${1:-}"; [ "$#" -gt 0 ] && shift
    step="${1:-}"; [ "$#" -gt 0 ] && shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] tick: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    require_slug "$slug"
    case "$step" in
      ''|*[!0-9]*|0)
        echo "[mentor plan-state] tick: <N> must be a positive integer, got '${step}'." >&2
        usage >&2
        exit 1
        ;;
    esac
    plan_dir="${plans_dir}/${slug}"
    plan_md="${plan_dir}/plan.md"
    if [ ! -f "$plan_md" ]; then
      echo "[mentor plan-state] tick: no plan.md at ${plan_md}." >&2
      exit 1
    fi
    # `if var=$(cmd)` (not a bare assignment) — under `set -e` a failing bare
    # assignment aborts the script before the rc check below ever runs.
    if tick_result="$(mentor_plan_tick_step "$plan_md" "$step")"; then
      read -r tick_status tick_n tick_total <<<"$tick_result"
      case "$tick_status" in
        ticked)  echo "[mentor plan-state] ${slug}: step ${step} ✅ ticked (${tick_n}/${tick_total})." ;;
        already) echo "[mentor plan-state] ${slug}: step ${step} was already ✅ (${tick_n}/${tick_total}) — no write." ;;
      esac
    else
      read -r _ tick_total <<<"$tick_result"
      echo "[mentor plan-state] tick: ${slug} has no step ${step} (plan.md has ${tick_total:-0} step(s) in '## Implementation steps'). No write." >&2
      exit 1
    fi
    ;;

  list)
    filter=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --group) filter="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        *) echo "[mentor plan-state] list: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
      esac
    done
    echo "PLANS_DIR: ${plans_dir}"
    echo
    if ! print_table "$filter"; then
      echo "[mentor plan-state] No plans${filter:+ in group ${filter}} in ${plans_dir}." >&2
      echo "[mentor plan-state] Topics holding only handoffs (no plan.md yet) never appear here — use 'overview --json' for the full picture." >&2
      exit 0
    fi
    echo
    echo "Plan files are PLANS_DIR/<PLAN>/plan.md. 'unknown' = a pre-2.4.0 plan with no state on record."
    echo "Topics holding only handoffs (no plan.md yet) never appear above — use 'overview --json' for the full picture."
    ;;

  current)
    plan="$(mentor_newest_plan "$plans_dir")"
    if [ -z "$plan" ]; then
      echo "[mentor plan-state] No plan found in ${plans_dir}." >&2
      exit 0
    fi
    plan_dir="$(dirname "$plan")"
    group="$(mentor_plan_group "$plan_dir")"

    # Inside a split group, mtime order is just "whichever child agent finished last".
    # Re-pick deterministically: lowest `order` that is not already done.
    if [ -n "$group" ]; then
      pick=""; fallback=""
      while IFS="$(printf '\t')" read -r _ s st _ _; do
        [ -n "$s" ] || continue
        [ -n "$fallback" ] || fallback="$s"
        case "$st" in
          implemented|superseded) ;;
          *) [ -n "$pick" ] || pick="$s" ;;
        esac
      done <<<"$(list_rows "$group")"
      [ -n "$pick" ] || pick="$fallback"
      if [ -n "$pick" ]; then
        plan_dir="${plans_dir}/${pick}"
        plan="${plan_dir}/plan.md"
      fi
    fi

    echo "PLAN: ${plan}"
    echo "SLUG: $(basename "$plan_dir")"
    echo "STATE: $(mentor_plan_effective_state "$plan_dir")"
    echo "GROUP: ${group:--}"
    if [ -n "$group" ]; then
      echo
      echo "This plan is one of a split group. PLAN above is only the first unfinished"
      echo "sibling — do NOT assume it is the one the user means. Ask which sibling (or all):"
      echo
      print_table "$group" || true
    fi
    ;;

  overview)
    ov_json_flag=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) ov_json_flag=1; shift ;;
        *) echo "[mentor plan-state] overview: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
      esac
    done
    if [ "$ov_json_flag" -ne 1 ]; then
      echo "[mentor plan-state] overview: --json is required — there is no human-table mode." >&2
      usage >&2
      exit 1
    fi
    require_jq_read
    mentor_dir="$(dirname "$plans_dir")"
    ov_entries=""

    # 1) every plan dir with a plan.md — the shared per-plan iterator (_plan_walk).
    while IFS="$(printf '\t')" read -r ov_slug ov_state ov_group ov_order ov_deps ov_origin ov_handoffs ov_ticked ov_total; do
      [ -n "$ov_slug" ] || continue
      [ "$ov_group" = "-" ] && ov_group=""    # un-placeholder — see _plan_walk's comment
      [ "$ov_order" = "-" ] && ov_order=""
      [ "$ov_origin" = "-" ] && ov_origin=""
      entry="$(jq -n \
        --arg slug "$ov_slug" --arg state "$ov_state" --arg group "$ov_group" --arg order "$ov_order" \
        --argjson deps "$ov_deps" --arg origin "$ov_origin" --argjson handoffs "$ov_handoffs" \
        --argjson ticked "$ov_ticked" --argjson total "$ov_total" '
        {kind: "plan", slug: $slug, state: $state,
         group: (if $group == "" then null else $group end),
         order: (if $order == "" then null else ($order | tonumber? // null) end),
         deps: $deps, origin: (if $origin == "" then null else $origin end),
         handoffs: $handoffs, steps: {ticked: $ticked, total: $total}}')"
      ov_entries="${ov_entries}${entry}
"
    done <<<"$(_plan_walk)"

    # 2) topic dirs with live handoffs but NO plan.md yet — additive coverage; NOT
    #    part of _plan_walk's plan.md-only filter, so list/current never see these.
    for ov_d in "${plans_dir}"/*/; do
      [ -d "$ov_d" ] || continue
      ov_d="${ov_d%/}"
      [ -f "${ov_d}/plan.md" ] && continue
      ov_slug="$(basename "$ov_d")"
      ov_handoffs="$(mentor_plan_live_handoffs "$ov_d" | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null)"
      [ -n "$ov_handoffs" ] || ov_handoffs="[]"
      [ "$ov_handoffs" = "[]" ] && continue
      entry="$(jq -n --arg slug "$ov_slug" --argjson handoffs "$ov_handoffs" '
        {kind: "no_plan_topic", slug: $slug, state: "no plan yet",
         group: null, order: null, deps: [], origin: null,
         handoffs: $handoffs, steps: {ticked: 0, total: 0}}')"
      ov_entries="${ov_entries}${entry}
"
    done

    # 3) legacy flat .mentor/handoffs/*.md — topic-less (pre-v2.10 notes).
    ov_legacy_dir="${mentor_dir}/handoffs"
    if [ -d "$ov_legacy_dir" ]; then
      ov_legacy_json="$(find "$ov_legacy_dir" -type f -name '*.md' -not -path '*/handoffs/resolved/*' 2>/dev/null \
        | while IFS= read -r ov_f; do basename "$ov_f"; done \
        | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null)"
      [ -n "$ov_legacy_json" ] || ov_legacy_json="[]"
      if [ "$ov_legacy_json" != "[]" ]; then
        entry="$(jq -n --argjson handoffs "$ov_legacy_json" '
          {kind: "legacy_handoffs", slug: null, state: null,
           group: null, order: null, deps: [], origin: null,
           handoffs: $handoffs, steps: null}')"
        ov_entries="${ov_entries}${entry}
"
      fi
    fi

    if [ -z "$ov_entries" ]; then
      echo "[]"
    else
      printf '%s' "$ov_entries" | jq -s '.'
    fi
    ;;

esac

exit 0
