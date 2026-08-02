#!/usr/bin/env bash
# plan-state.sh — the ONE plan-state API. Read and write .mentor/plans/<slug>/.state.json.
#
# Not a hook: skills call it as a plain Bash command, like approve-plan.sh.
# It exists so no skill ever hand-rolls the sidecar JSON, and so the three places
# that used to resolve "the current plan" with their own `ls -t` share one answer.
#
#   init <slug> [--group G] [--order N]
#       Create the sidecar as `draft`. Idempotent and never LOWERS an existing
#       state — re-running it on an approved plan keeps it approved.
#
#   set <slug> <state> [--note "…"]
#       Upsert (create-then-set): most plans predate the sidecar. <state> is one of
#       draft approved in_progress implemented failed superseded.
#       The note is REPLACED every time, so a plain `set` clears a stale failure note.
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
  init <slug> [--group G] [--order N]   create the sidecar as draft (idempotent)
  set <slug> <state> [--note "…"]       state: draft|approved|in_progress|implemented|failed|superseded
  list [--group G]                      every plan with its effective state
  current                               the current plan (group-aware)
  context                               CONTEXT: ASK|HANDOFF|WARN|OK|UNKNOWN (~N tokens)
  dir [--plans]                         the repo-scoped mentor dir (or its plans dir)
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
     Skill(skill="mentor:handoff") with the chosen plan as the focus, write the
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

case "$sub" in
  init|set|list|current) ;;
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

# --- shared row builder -------------------------------------------------------
# Emits, tab-separated and sorted: <sortkey> <slug> <effective state> <group> <order>
# Sort key: bucket (0 active / 1 superseded+unknown) | group (ungrouped sorts on its
# own slug, so it neither splits a group nor clumps with one) | zero-padded order | slug.
list_rows() {
  local filter="${1:-}" d slug state group order bucket gkey okey
  for d in "${plans_dir}"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "${d}/plan.md" ] || continue
    slug="$(basename "$d")"
    state="$(mentor_plan_effective_state "$d")"
    group="$(mentor_plan_group "$d")"   # sidecar, else the isolation header
    order="$(mentor_plan_order "$d")"
    if [ -n "$filter" ] && [ "$group" != "$filter" ]; then continue; fi
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
  done | LC_ALL=C sort -t"$(printf '\t')" -k1,1
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

case "$sub" in

  init)
    slug=""; group=""; order=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        # shift 1 then conditionally 1 more: a bare trailing `--group` must not
        # leave $# unchanged and spin this loop forever.
        --group) group="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --order) order="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        -*) echo "[mentor plan-state] init: unknown flag ${1}" >&2; usage >&2; exit 1 ;;
        *)  [ -z "$slug" ] && slug="$1" || { echo "[mentor plan-state] init: unexpected argument ${1}" >&2; exit 1; }; shift ;;
      esac
    done
    require_slug "$slug"
    require_jq
    plan_dir="${plans_dir}/${slug}"
    # Idempotent: keep whatever state is already on record; only fill in a missing one.
    existing="$(mentor_plan_state_stored "$plan_dir")"
    mentor_plan_state_write "$plan_dir" "${existing:-draft}" "$group" "$order" \
      "$(mentor_plan_state_field "$plan_dir" note)"
    echo "[mentor plan-state] ${slug}: $(mentor_plan_effective_state "$plan_dir")${group:+  group=${group}}${order:+  order=${order}}"
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
    mentor_plan_state_write "$plan_dir" "$state" "" "" "$note"
    after="$(mentor_plan_effective_state "$plan_dir")"
    echo "[mentor plan-state] ${slug}: ${before} → ${after}${note:+  (${note})}"
    # The effective read can outrank what was just stored — say so rather than let a
    # caller believe the sidecar is the last word.
    if [ "$after" != "$state" ]; then
      echo "[mentor plan-state] note: '${state}' stored, but the plan's ✅ step ticks report '${after}'."
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
      exit 0
    fi
    echo
    echo "Plan files are PLANS_DIR/<PLAN>/plan.md. 'unknown' = a pre-2.4.0 plan with no state on record."
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

esac

exit 0
