#!/usr/bin/env bash
# plan-state.sh — the ONE plan-state API. Read and write .mentor/plans/<slug>/.state.json
# (and, via `tick`, the ✅ step marks in plan.md that the sidecar's effective state derives from).
#
# Not a hook: skills call it as a plain Bash command, like approve-plan.sh.
# It exists so no skill ever hand-rolls the sidecar JSON, and so the three places
# that used to resolve "the current plan" with their own `ls -t` share one answer.
#
# v2.23.0: the plan-gate marker is now per-worktree (`.planning.<wt-id>`, one per
# linked worktree, legacy bare `.planning` reserved repo-global — see `gate` below
# and lib/state.sh's state-layout header); plans stay SHARED across every worktree,
# tracked by an `owner`/`owner_session` pair on the sidecar (stamped by ensure-dir/
# init/claim — see `current --any`, `list --owners`, and `overview`'s `owner` field).
#
# v2.24.0: the sidecar carries a `priority` — the plan's IMPACT tier, one of
# critical|high|medium|low|noise or null — so /mentor:track's hierarchy can say which
# plans matter and which are noise. Written by `init --priority` and `set-priority`;
# read back on every `overview --json` plan entry. Orthogonal to `order` (sequence
# WITHIN a split group) and `deps` (what must be built FIRST) — neither of those says
# whether a plan is worth building at all.
#
#   init <slug> [--group G] [--order N] [--deps a,b] [--deferred] [--priority P]
#       Create the sidecar as `draft`. Idempotent and never LOWERS an existing
#       state — re-running it on an approved plan keeps it approved. --deps sets the
#       initial dependency slugs (cycle-checked, same as set-deps); --deferred marks
#       the plan a stub born via /mentor:defer (origin: "deferred" — shields it from
#       approve-plan's promotion sweep until `claim`ed); --priority sets the initial
#       impact tier (same closed vocabulary as set-deps' sibling `set-priority`).
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
#   set-priority <slug> <critical|high|medium|low|noise|"">
#       Set <slug>'s impact tier; an EMPTY string clears it back to unset (null),
#       which renders as absent rather than as any tier. A CLOSED vocabulary,
#       validated here — unlike set-deps' arbitrary slugs — because the field exists
#       so /mentor:track can bucket plans by tier, and an unvalidated typo would
#       silently become a sixth bucket. An invalid value is a usage error (exit 1, no
#       write), not a fail-soft skip: a tiering pass over N plans must not report
#       success while one of them silently kept its old tier.
#       Its own subcommand rather than a `set` flag for exactly the reason `set-deps`
#       and `claim` are: `set <slug> <state>` takes state as a REQUIRED positional, so
#       a priority-only edit would have to restate (and risk re-writing) a state the
#       caller never meant to touch.
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
#   list [--group G] [--owners]
#       One row per plan: ordinal, EFFECTIVE state, slug, group, order — and, with
#       --owners, a 6th OWNER column (the wt-id from the sidecar, "-" when unowned).
#       Grouped, ordered within a group, `superseded` and `unknown` last. The default
#       (no --owners) 5-column shape is byte-compatible with pre-2.23.0 output.
#       Deliberately carries NO priority column, in either shape: `overview --json` is
#       what every rendering skill reads, and a third column layout here would buy a
#       table nothing consumes at the cost of the byte-compatibility promise above.
#
#   current [--any]
#       The plan a bare "review the plan" means, scoped to plans OWNED by THIS
#       worktree (or unowned) — a write target must never resolve to a sibling
#       worktree's in-flight draft. --any drops the filter for a deliberate,
#       repo-wide read. Skips superseded. When the answer belongs to a split group
#       it prints the whole group and says so, instead of silently picking one of N
#       children.
#
#   overview --json
#       Repo-wide JSON array (--json is required — there is no human-table mode): one
#       object per plan dir with a plan.md (slug, effective state, group, order,
#       priority, deps — each marked missing when no such plan dir exists, origin,
#       live handoffs, ticked/total step counts), plus topic dirs that hold live
#       handoffs but no plan.md yet (state "no plan yet") and the legacy flat handoffs/
#       dir (topic-less). `priority` is null on every entry that has none, including
#       both non-plan kinds, so a consumer never has to branch on kind to read it.
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
#       ARMED|STALE|ARMED_ELSEWHERE|RELEASED — exactly one token on stdout (line 1,
#       always — bare `gate` and `gate --verbose` alike), reporting the plan-gate
#       marker's status for THIS worktree (v2.23.0 — one `.planning.<wt-id>` marker
#       per worktree; see lib/state.sh's state-layout header for the full scheme):
#         ARMED           this worktree's OWN marker is live, or the legacy repo-
#                          global `.planning` marker is live (it blocks every
#                          worktree) — a write HERE would be denied right now.
#         STALE           the own or legacy marker exists but is older than
#                          MENTOR_PLAN_MARKER_STALE_MIN (lib/state.sh, ~8h) —
#                          plan-gate.sh/begin-plan.sh haven't pruned/healed it yet,
#                          but every other caller already reads it as not-armed.
#         ARMED_ELSEWHERE no own/legacy marker at all, but a SIBLING worktree's
#                          marker is live — an independent gate; it does not block
#                          writes here.
#         RELEASED        no marker at all (outside a repo — the `_no-repo`
#                          fallback — always reads RELEASED too).
#       This answers "is the gate armed HERE", not "should it be" — a caller that
#       instead needs "we're inside a repo and planning should have started" wants
#       a different check.
#       READ-ONLY: gate never deletes or heals a marker. That stays true even though
#       it is no longer the ONLY thing that could remove one — two removers exist now
#       (plan-gate.sh's self-heal on a would-deny write, and begin-plan.sh's stale-
#       sibling prune on arm), each printing its own named notice before removing
#       anything, so a marker is never released silently; gate must never become a
#       third, silent one.
#       --verbose is strictly additive: bare `gate` is unchanged (plan-track's and
#       touring's `[ "$(… gate)" = "ARMED" ]` string-equality checks depend on
#       staying exactly one token — and now on ARMED_ELSEWHERE reading as "not armed
#       for me" by that same equality check). The per-token field contract below is
#       NORMATIVE — exactly these fields, nothing else:
#         ARMED           marker= owner_session= owner_cwd= owner_worktree=
#                          age_min= affected_plans= — the mentor_marker_field/
#                          mentor_marker_age_min facts plan-gate.sh's own deny
#                          message already computes, plus the mentor_newly_planned
#                          slugs approve-plan.sh would promote to `approved` if run
#                          right now (unfiltered when the armed marker is the legacy
#                          one — mirrors approve-plan.sh's legacy_mode, which is
#                          unfiltered too).
#         ARMED_ELSEWHERE one `elsewhere=<wt-id> session=<sid> worktree=<path>
#                          age_min=<n>` line per live sibling marker, nothing else.
#         STALE/RELEASED  bare token only — there is no "owner" to report.
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

# warn_same_slug_collision <plan_dir> <this_wt_id> <plans_dir> — stderr WARNING when
# <plan_dir> already exists AND its sidecar `owner` is a DIFFERENT worktree whose own
# marker is currently live: two worktrees drafting the same slug is reachable now that
# the gate is per-worktree (the old repo-global marker used to make this impossible —
# see begin-plan.sh's matching same-slug WARN on the arm side). Never blocks —
# informational only. Called from both `ensure-dir` (mint time) and `init` (re-own
# time), defined here (ahead of both) so `ensure-dir`'s early-exit block can reach it
# too. Skipped entirely when <this_wt_id> is empty — without a wt-id of our own there
# is nothing meaningful to compare against.
warn_same_slug_collision() {
  local plan_dir="${1:-}" this_wt="${2:-}" pdir="${3:-}" other other_marker
  [ -n "$plan_dir" ] && [ -d "$plan_dir" ] && [ -n "$this_wt" ] || return 0
  other="$(mentor_plan_owner "$plan_dir")"
  [ -n "$other" ] && [ "$other" != "$this_wt" ] || return 0
  other_marker="$(mentor_plan_marker "$pdir" "$other")"
  if [ -e "$other_marker" ] && ! mentor_marker_stale "$other_marker"; then
    echo "[mentor plan-state] WARNING: $(basename "$plan_dir") is already owned by worktree ${other}, whose plan gate is currently live — two worktrees may be drafting the same slug. Coordinate with that worktree, or pick a different slug." >&2
  fi
  return 0
}

usage() {
  cat <<'EOF'
Usage: plan-state.sh <subcommand>
  init <slug> [--group G] [--order N] [--deps a,b] [--deferred] [--priority P]
                                         create the sidecar as draft (idempotent)
  set <slug> <state> [--note "…"]       state: draft|approved|in_progress|implemented|failed|superseded
  set-deps <slug> a,b                   replace deps wholesale (cycle-checked, fail-soft)
  set-priority <slug> <P>               impact tier: critical|high|medium|low|noise ("" clears)
  claim <slug>                          clear origin (a deferred stub enters real planning)
  tick <slug> <N>                       append ✅ to step N in plan.md (idempotent, fails loud)
  list [--group G] [--owners]           every plan with its effective state (--owners adds OWNER)
  current [--any]                       the current plan, owned-by-this-worktree scoped (group-aware);
                                         --any for a deliberate repo-wide read
  overview --json                       repo-wide JSON: plans + deps + live handoffs + step counts
  context                               CONTEXT: ASK|HANDOFF|WARN|OK|UNKNOWN (~N tokens)
  dir [--plans]                         the repo-scoped mentor dir (or its plans dir)
  gate [--verbose]                      ARMED|STALE|ARMED_ELSEWHERE|RELEASED — read-only marker
                                         status for THIS worktree (--verbose adds per-token fields;
                                         see the gate doc comment above for the exact contract)
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
  # A direct child of plans/ is a plan TOPIC dir — the first of the three owner-
  # stamping sites (ensure-dir/init/claim — see the state-layout header comment and
  # this file's top-of-file v2.23.0 note), because the normal flow writes plan.md
  # before Step 4's `init`, which is routinely skipped (approve-plan.sh) — leaving
  # the plan unowned in between is exactly the window this closes. The collision
  # check runs BEFORE the stamp below, so it still sees whatever owner (if any) was
  # on record before this call claims it.
  ed_plans="${ed_mdir}/plans"
  ed_wt_id=""
  if [ "$(dirname "$ed_canon")" = "$ed_plans" ]; then
    ed_wt_id="$(mentor_worktree_id "$(pwd)")"
    warn_same_slug_collision "$ed_canon" "$ed_wt_id" "$ed_plans"
  fi
  mentor_ensure_private_dir "$ed_mdir" "$ed_canon"
  if [ -n "$ed_wt_id" ]; then
    mentor_plan_state_write "$ed_canon" --owner "$ed_wt_id" --owner-session "${CLAUDE_CODE_SESSION_ID:-}"
  fi
  echo "$ed_canon"
  exit 0
fi

# --- gate: read-only plan-gate marker status — needs neither a repo (fallback) nor a
# plans dir, same as dir/ensure-dir above. Never deletes a marker itself — see the doc
# comment near the top of this file for the full token contract and why gate must
# never become a third (silent) remover alongside plan-gate.sh's self-heal and
# begin-plan.sh's stale-sibling prune.
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
  g_plans="${g_mdir}/plans"
  g_wt_id="$(mentor_worktree_id "$(pwd)")"
  g_own="$(mentor_plan_marker "$g_plans" "$g_wt_id")"
  g_legacy="$(mentor_plan_marker "$g_plans" "")"

  g_own_exists=0; g_own_live=0
  [ -e "$g_own" ] && g_own_exists=1
  if [ "$g_own_exists" -eq 1 ] && ! mentor_marker_stale "$g_own"; then g_own_live=1; fi

  # Legacy is a SEPARATE path only when wt_id is non-empty (empty wt_id already makes
  # g_own == g_legacy — see mentor_plan_marker) — guarded so the two checks can never
  # double-count the same file.
  g_legacy_exists=0; g_legacy_live=0
  if [ -n "$g_wt_id" ]; then
    [ -e "$g_legacy" ] && g_legacy_exists=1
    if [ "$g_legacy_exists" -eq 1 ] && ! mentor_marker_stale "$g_legacy"; then g_legacy_live=1; fi
  fi

  if [ "$g_own_live" -eq 1 ] || [ "$g_legacy_live" -eq 1 ]; then
    if [ "$g_own_live" -eq 1 ]; then g_marker="$g_own"; else g_marker="$g_legacy"; fi
    echo ARMED
    if [ "$g_verbose" -eq 1 ]; then
      echo "marker=${g_marker}"
      echo "owner_session=$(mentor_marker_field "$g_marker" session)"
      echo "owner_cwd=$(mentor_marker_field "$g_marker" cwd)"
      echo "owner_worktree=$(mentor_marker_field "$g_marker" worktree)"
      echo "age_min=$(mentor_marker_age_min "$g_marker")"
      # Unfiltered when the armed marker is the legacy one, matching approve-plan.sh's
      # own legacy_mode (unfiltered repo-wide sweep) — a legacy-armed gate blocks every
      # worktree, so "what would approving promote" must answer for the whole repo, not
      # just this worktree's slice.
      if [ "$g_marker" = "$g_legacy" ]; then g_affected_wt=""; else g_affected_wt="$g_wt_id"; fi
      g_affected="$(mentor_newly_planned "$g_plans" "$g_marker" "$g_affected_wt" \
        | while IFS= read -r g_p; do basename "$(dirname "$g_p")"; done | paste -sd' ' -)"
      echo "affected_plans=${g_affected}"
    fi
  elif [ "$g_own_exists" -eq 1 ] || [ "$g_legacy_exists" -eq 1 ]; then
    echo STALE
  else
    g_siblings="$(mentor_live_markers "$g_plans")"
    if [ -n "$g_siblings" ]; then
      echo ARMED_ELSEWHERE
      if [ "$g_verbose" -eq 1 ]; then
        while IFS= read -r g_m; do
          [ -n "$g_m" ] || continue
          g_suffix="$(basename "$g_m")"
          g_suffix="${g_suffix#.planning.}"
          echo "elsewhere=${g_suffix} session=$(mentor_marker_field "$g_m" session) worktree=$(mentor_marker_field "$g_m" worktree) age_min=$(mentor_marker_age_min "$g_m")"
        done <<<"$g_siblings"
      fi
    else
      echo RELEASED
    fi
  fi
  exit 0
fi

case "$sub" in
  init|set|set-deps|set-priority|claim|tick|list|current|overview) ;;
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
#   slug  state  group  order  owner  deps_json  origin  handoffs_json  ticked  total
#   priority
# `owner` (v2.23.0, mentor_plan_owner) is the wt-id that minted or last re-owned the
# plan dir, or "-" when unowned. `priority` (v2.24.0, mentor_plan_priority) is the
# impact tier, or "-" when unset; it is APPENDED at the end rather than slotted beside
# `order` on purpose — `list_rows` reads only the first five fields and drops the
# tail into a single `_rest`, so a trailing field cannot disturb the byte-compatible
# 5-column `list` output, while an inserted one would shift every field after it. `deps_json`/`handoffs_json` are compact (`jq -c`)
# single-line JSON — safe to sit in a tab field because compact jq output never
# contains a literal tab or newline, even inside a string. `list_rows` (below,
# byte-compatible with the pre-v2.17.0 5-field format) and `overview --json` both
# derive from this ONE walk — neither re-walks plans_dir on its own. `list`/`current`
# never needed deps/handoffs/step-counts, so computing them for those two callers too
# is a deliberate small cost in exchange for there being exactly one place that
# decides what "every plan" means.
_plan_walk() {
  local filter="${1:-}" d slug state group order owner origin deps_pairs deps_json
  local handoffs_json ticked total dep miss priority
  for d in "${plans_dir}"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "${d}/plan.md" ] || continue
    slug="$(basename "$d")"
    state="$(mentor_plan_effective_state "$d")"
    group="$(mentor_plan_group "$d")"   # sidecar, else the isolation header
    if [ -n "$filter" ] && [ "$group" != "$filter" ]; then continue; fi
    order="$(mentor_plan_order "$d")"
    owner="$(mentor_plan_owner "$d")"
    origin="$(mentor_plan_origin "$d")"
    priority="$(mentor_plan_priority "$d")"
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
    # so a genuinely-empty group/order/owner/origin/priority would silently shift
    # every field after it for whoever reads this line. Emit "-" for empty (matching
    # print_table's own existing display convention) and never a raw empty string
    # here; consumers translate "-" back to "" on read. This applies to the LAST field
    # as much as the middle ones: `read` assigns an absent trailing field as empty
    # anyway, so a bare "" there would be indistinguishable from a short record.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$slug" "$state" "${group:--}" "${order:--}" "${owner:--}" "$deps_json" "${origin:--}" "$handoffs_json" "$ticked" "$total" "${priority:--}"
  done
}

# list_rows [group-filter] [with-owner] — the pre-v2.17.0 5-field row format,
# byte-compatible: <sortkey> <slug> <effective state> <group> <order>, tab-separated
# and sorted. Sort key: bucket (0 active / 1 superseded+unknown) | group (ungrouped
# sorts on its own slug, so it neither splits a group nor clumps with one) |
# zero-padded order | slug. Derived from _plan_walk's raw records — see that
# function's comment for why this is no longer its own directory walk.
# with-owner=1 appends a 6th tab field (owner wt-id, "-" when unowned) for `list
# --owners` — the default (with-owner omitted/0) 5-field shape used by bare `list`
# stays byte-identical either way, since the extra field is only ever emitted, never
# read, unless a caller explicitly asks for it.
list_rows() {
  local filter="${1:-}" with_owner="${2:-0}"
  local slug state group order owner _rest bucket gkey okey
  while IFS="$(printf '\t')" read -r slug state group order owner _rest; do
    [ -n "$slug" ] || continue
    [ "$group" = "-" ] && group=""   # un-placeholder — see _plan_walk's comment
    [ "$order" = "-" ] && order=""
    [ "$owner" = "-" ] && owner=""
    case "$state" in
      superseded|unknown) bucket=1 ;;
      *)                  bucket=0 ;;
    esac
    gkey="${group:-$slug}"
    case "$order" in
      ''|*[!0-9]*) okey="999" ;;
      *)           okey="$(printf '%03d' "$order")" ;;
    esac
    if [ "$with_owner" = "1" ]; then
      printf '%s|%s|%s|%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$bucket" "$gkey" "$okey" "$slug" "$slug" "$state" "${group:--}" "${order:--}" "${owner:--}"
    else
      printf '%s|%s|%s|%s\t%s\t%s\t%s\t%s\n' \
        "$bucket" "$gkey" "$okey" "$slug" "$slug" "$state" "${group:--}" "${order:--}"
    fi
  done <<<"$(_plan_walk "$filter")" | LC_ALL=C sort -t"$(printf '\t')" -k1,1
}

print_table() {
  local filter="${1:-}" with_owner="${2:-0}" rows i=0 key slug state group order owner
  rows="$(list_rows "$filter" "$with_owner")"
  if [ -z "$rows" ]; then
    return 1
  fi
  if [ "$with_owner" = "1" ]; then
    printf '%-3s %-13s %-38s %-24s %-6s %s\n' "#" "STATE" "PLAN" "GROUP" "ORDER" "OWNER"
    while IFS="$(printf '\t')" read -r key slug state group order owner; do
      [ -n "$slug" ] || continue
      i=$((i + 1))
      printf '%-3s %-13s %-38s %-24s %-6s %s\n' "$i" "$state" "$slug" "$group" "$order" "$owner"
    done <<<"$rows"
    return 0
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

# closing_checklist_reminder <transcript_path> <implemented|failed> — best-effort
# stdout nudge for dispatch-agents' CLOSING CHECKLIST. The caller fires this only on a
# FRESH transition into a terminal state (before != state), so shipping/merging's own
# later `set … implemented` — which idempotently re-closes a plan dispatch-agents
# already closed — stays silent instead of re-nagging mid-ship. The TaskList line is
# the only conditional part: it prints only when this session's own transcript shows an
# Agent dispatch with no matching TaskList call — a prior learn fix already reworded
# that rule's prose once and the same miss recurred, so this gives it a structural
# trigger instead of depending on the model re-reading ~15 lines of prose late in a
# session. The defer-sweep line is unconditional on both terminal states, matching the
# checklist's own "always, whatever Verification returned." The tour/ship lines print
# only for `implemented` — the checklist explicitly holds them on `failed`/handed-off
# ("which speak for work that was accepted"). Never blocks — the state write already
# succeeded by the time this runs.
closing_checklist_reminder() {
  local tx="${1:-}" outcome="${2:-}" tasklist_line=""
  if [ -n "$tx" ] && [ -f "$tx" ] \
     && grep -q '"name":"Agent"' "$tx" 2>/dev/null \
     && ! grep -q '"name":"TaskList"' "$tx" 2>/dev/null; then
    tasklist_line="
  - TaskList: enumerate live tasks, diff against this session's dispatch tree, TaskStop only what traces to it."
  fi
  echo "[mentor plan-state] Closing checklist (dispatch-agents' CLOSING CHECKLIST):${tasklist_line}"
  echo "  - Sweep any known gap or follow-up through /mentor:defer before it's forgotten."
  if [ "$outcome" = "implemented" ]; then
    echo "  - Offer /mentor:tour — one line."
    echo "  - Point at /mentor:ship — one line."
  fi
  return 0
}

# verification_artifact_reminder <plan_dir> — best-effort stderr warning, fired only
# alongside closing_checklist_reminder (same FRESH-transition-to-implemented guard, so
# shipping/merging's idempotent re-`set … implemented` stays silent). Catches the false
# green dispatch-agents' "Verifying the plan (execution-time)" exists to prevent: a plan
# whose `## Verification` section is non-empty (real criteria to check, canonical `Topic
# N —` grammar or legacy prose alike — both dispatch "one fresh verifier per topic, never
# self-check") but whose plan dir holds no `*verify*.md` durable copy — the file every
# verifier is required to write before returning (this skill file, "Deliver before
# idling"). No artifact is the observable footprint of a main-thread self-check standing
# in for a dispatched verifier: the context that just ran the build grading its own work,
# exactly the failure mode that section's opening line names. A false negative here (the
# artifact exists but under a name this glob misses) costs nothing — same fail-soft
# nudge, not a gate — so the check stays deliberately loose rather than parsing topic
# counts and demanding an exact match.
verification_artifact_reminder() {
  local plan_dir="${1:-}" plan_md="${1:-}/plan.md" nonempty
  [ -n "$plan_dir" ] && [ -f "$plan_md" ] || return 0
  nonempty="$(awk '
    /^##[[:space:]]/ { h = tolower($0); insec = (h ~ /^##[[:space:]]+verification/) ? 1 : 0; next }
    insec && $0 ~ /[^[:space:]]/ { found = 1 }
    END { print (found ? 1 : 0) }
  ' "$plan_md")"
  [ "$nonempty" = "1" ] || return 0
  find "$plan_dir" -maxdepth 1 -iname '*verify*.md' 2>/dev/null | grep -q . && return 0
  echo "[mentor plan-state] WARNING: ${plan_dir##*/} has a non-empty ## Verification section but no *verify*.md artifact under ${plan_dir}." >&2
  echo "  dispatch-agents' \"Verifying the plan (execution-time)\" requires one fresh verifier per topic — never a main-thread self-check, no escape hatch." >&2
  echo "  If verification genuinely ran via dispatched agents, confirm each one wrote its durable copy; if it didn't, this plan is not actually verified yet." >&2
  return 0
}

# tick_reconciliation_reminder <plan_dir> — best-effort stderr warning, fired only
# alongside closing_checklist_reminder (same FRESH-transition-to-implemented guard, so
# shipping/merging's idempotent re-`set … implemented` stays silent). Distinct from the
# "'implemented' stored, but the plan's ✅ step ticks report …" note above: that note
# fires only when the tick-derived state OUTRANKS what was just stored
# (mentor_plan_state_rank), which a partially- or un-ticked plan never does —
# `implemented` at 0/6 or 2/6 stores clean, mentor_plan_effective_state agrees with it,
# and nothing above this function ever says otherwise. Ticks self-heal STATE (a stale
# sidecar can be overridden by finishing the ticks) but nothing self-heals a TICK — once
# a plan is closed `implemented`, plan-track's own Step 4 ("reconcile the ticks before
# writing implemented") was the last chance to write the ones that actually passed,
# which is why this fires exactly here. A false positive here is cheap (a legacy plan
# closed before this sidecar existed, or a `merging` partial close the user already
# accepted) — same fail-soft nudge as its neighbor, not a gate.
tick_reconciliation_reminder() {
  local plan_dir="${1:-}" plan_md="${1:-}/plan.md" ticked total
  [ -n "$plan_dir" ] && [ -f "$plan_md" ] || return 0
  read -r ticked total <<<"$(mentor_plan_tick_counts "$plan_md")"
  [ "${total:-0}" -gt 0 ] || return 0
  [ "${ticked:-0}" -lt "${total:-0}" ] || return 0
  echo "[mentor plan-state] WARNING: ${plan_dir##*/} closed 'implemented' with only ${ticked}/${total} steps ticked." >&2
  echo "  Tick the steps that actually passed (plan-state.sh tick ${plan_dir##*/} <N>), or tell the user which are closing untracked and why." >&2
  return 0
}

case "$sub" in

  init)
    slug=""; group=""; order=""; deps=""; deferred=0; priority=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        # shift 1 then conditionally 1 more: a bare trailing `--group` must not
        # leave $# unchanged and spin this loop forever.
        --group) group="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --order) order="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --deps) deps="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --deferred) deferred=1; shift ;;
        --priority) priority="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        -*) echo "[mentor plan-state] init: unknown flag ${1}" >&2; usage >&2; exit 1 ;;
        *)  [ -z "$slug" ] && slug="$1" || { echo "[mentor plan-state] init: unexpected argument ${1}" >&2; exit 1; }; shift ;;
      esac
    done
    require_slug "$slug"
    # Validated BEFORE any write, like `set`'s state check — a typo'd tier is a usage
    # error, not a fail-soft skip, so `init` can never report success having quietly
    # dropped the one field the caller passed it. (A `--deps` cycle stays fail-soft by
    # contrast: that is a graph condition the caller could not have known locally,
    # not a misspelling.) An EMPTY --priority is not an error and not a clear — init
    # never clears anything; every other flag here preserves on empty the same way,
    # and `set-priority <slug> ""` is the one path that un-tiers a plan.
    if [ -n "$priority" ] && ! mentor_plan_priority_valid "$priority"; then
      echo "[mentor plan-state] init: invalid priority '${priority}'." >&2
      echo "Valid priorities: ${MENTOR_PLAN_PRIORITIES}  (or \"\" to leave unset)" >&2
      exit 1
    fi
    require_jq
    plan_dir="${plans_dir}/${slug}"
    init_wt_id="$(mentor_worktree_id "$(pwd)")"
    # Collision check reads whatever owner is currently on record, BEFORE the
    # last-init-wins re-stamp below overwrites it.
    warn_same_slug_collision "$plan_dir" "$init_wt_id" "$plans_dir"
    # Idempotent: keep whatever state is already on record; only fill in a missing one.
    existing="$(mentor_plan_state_stored "$plan_dir")"
    write_args=(--state "${existing:-draft}" --note "$(mentor_plan_state_field "$plan_dir" note)")
    [ -n "$group" ] && write_args+=(--group "$group")
    [ -n "$order" ] && write_args+=(--order "$order")
    [ -n "$priority" ] && write_args+=(--priority "$priority")
    # Second of the three owner-stamping sites (see this file's top-of-file v2.23.0
    # note): last-init-wins re-owning — this is also how `/mentor:plan <slug>` re-owns
    # a plan resumed in a different worktree. Skipped entirely when wt-id is empty
    # (no git / bare repo / etc.) — same fail-soft convention as everywhere else here.
    if [ -n "$init_wt_id" ]; then
      write_args+=(--owner "$init_wt_id" --owner-session "${CLAUDE_CODE_SESSION_ID:-}")
    fi
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
    echo "[mentor plan-state] ${slug}: $(mentor_plan_effective_state "$plan_dir")${group:+  group=${group}}${order:+  order=${order}}${priority:+  priority=${priority}}${deps_summary:+  deps=${deps_summary}}$([ "$deferred" -eq 1 ] && printf '  origin=deferred')"
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
    case "$state" in
      implemented|failed)
        # Fire only on a FRESH transition — before == state means this call is an
        # idempotent re-close (e.g. shipping/merging re-running `set … implemented`
        # after dispatch-agents already closed it), which must stay silent.
        if [ "$before" != "$state" ]; then
          closing_checklist_reminder "$(mentor_find_transcript "$(pwd)")" "$state"
          # Only implemented claims verification passed — failed has nothing to fake.
          if [ "$state" = "implemented" ]; then
            verification_artifact_reminder "$plan_dir"
            tick_reconciliation_reminder "$plan_dir"
          fi
        fi
        ;;
    esac
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

  set-priority)
    # The VALUE is required as a positional even when it is the empty string, so
    # `set-priority <slug>` with nothing after it is a usage error rather than a
    # silent clear — un-tiering must be something the caller typed on purpose
    # (`set-priority <slug> ""`), not what a dropped shell argument decays into.
    slug="${1:-}"; if [ "$#" -gt 0 ]; then shift; fi
    require_slug "$slug"
    if [ "$#" -eq 0 ]; then
      echo "[mentor plan-state] set-priority: a <priority> is required (use \"\" to clear)." >&2
      usage >&2
      exit 1
    fi
    prio="$1"; shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] set-priority: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    if [ -n "$prio" ] && ! mentor_plan_priority_valid "$prio"; then
      echo "[mentor plan-state] set-priority: invalid priority '${prio}'." >&2
      echo "Valid priorities: ${MENTOR_PLAN_PRIORITIES}  (or \"\" to clear)" >&2
      exit 1
    fi
    require_jq
    plan_dir="${plans_dir}/${slug}"
    # Re-read and re-pass the note for the same reason set-deps does:
    # mentor_plan_state_write always REPLACES --note (even when omitted, which would
    # clear it), so a priority-only write must round-trip the current note.
    mentor_plan_state_write "$plan_dir" --priority "$prio" --note "$(mentor_plan_state_field "$plan_dir" note)"
    echo "[mentor plan-state] ${slug}: priority = ${prio:-(unset)}"
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
    # Third of the three owner-stamping sites (see this file's top-of-file v2.23.0
    # note): re-stamps on deferred-stub resurrection, same skip-when-empty rule as
    # `init`. No same-slug WARN here — a deferred stub's own worktree claiming it is
    # the normal path, not a collision signal.
    claim_wt_id="$(mentor_worktree_id "$(pwd)")"
    claim_args=(--origin "" --note "$(mentor_plan_state_field "$plan_dir" note)")
    if [ -n "$claim_wt_id" ]; then
      claim_args+=(--owner "$claim_wt_id" --owner-session "${CLAUDE_CODE_SESSION_ID:-}")
    fi
    mentor_plan_state_write "$plan_dir" "${claim_args[@]}"
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
    filter=""; list_owners=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --group) filter="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --owners) list_owners=1; shift ;;
        *) echo "[mentor plan-state] list: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
      esac
    done
    echo "PLANS_DIR: ${plans_dir}"
    echo
    if ! print_table "$filter" "$list_owners"; then
      echo "[mentor plan-state] No plans${filter:+ in group ${filter}} in ${plans_dir}." >&2
      echo "[mentor plan-state] Topics holding only handoffs (no plan.md yet) never appear here — use 'overview --json' for the full picture." >&2
      exit 0
    fi
    echo
    echo "Plan files are PLANS_DIR/<PLAN>/plan.md. 'unknown' = a pre-2.4.0 plan with no state on record."
    echo "Topics holding only handoffs (no plan.md yet) never appear above — use 'overview --json' for the full picture."
    ;;

  current)
    cur_any=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --any) cur_any=1; shift ;;
        *) echo "[mentor plan-state] current: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
      esac
    done
    cur_wt_id=""
    [ "$cur_any" -eq 1 ] || cur_wt_id="$(mentor_worktree_id "$(pwd)")"
    # Scoped to plans owned by THIS worktree (or unowned) — plan-review WRITES to the
    # plan `current` resolves, so an unscoped read would let worktree A silently
    # rewrite worktree B's in-flight draft. --any drops the filter for a deliberate,
    # repo-wide read (mentor_newest_plan_owned with an empty wt-id is unfiltered).
    plan="$(mentor_newest_plan_owned "$plans_dir" "$cur_wt_id")"
    if [ -z "$plan" ]; then
      if [ "$cur_any" -eq 1 ]; then
        echo "[mentor plan-state] No plan found in ${plans_dir}." >&2
      else
        echo "[mentor plan-state] No plan owned by this worktree found in ${plans_dir} (plans owned by another worktree are excluded — use --any for a repo-wide, unfiltered read, or /mentor:plan <slug> to re-own one)." >&2
      fi
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
    while IFS="$(printf '\t')" read -r ov_slug ov_state ov_group ov_order ov_owner ov_deps ov_origin ov_handoffs ov_ticked ov_total ov_priority; do
      [ -n "$ov_slug" ] || continue
      [ "$ov_group" = "-" ] && ov_group=""    # un-placeholder — see _plan_walk's comment
      [ "$ov_order" = "-" ] && ov_order=""
      [ "$ov_owner" = "-" ] && ov_owner=""
      [ "$ov_origin" = "-" ] && ov_origin=""
      [ "$ov_priority" = "-" ] && ov_priority=""
      entry="$(jq -n \
        --arg slug "$ov_slug" --arg state "$ov_state" --arg group "$ov_group" --arg order "$ov_order" \
        --arg owner "$ov_owner" --arg priority "$ov_priority" \
        --argjson deps "$ov_deps" --arg origin "$ov_origin" --argjson handoffs "$ov_handoffs" \
        --argjson ticked "$ov_ticked" --argjson total "$ov_total" '
        {kind: "plan", slug: $slug, state: $state,
         group: (if $group == "" then null else $group end),
         order: (if $order == "" then null else ($order | tonumber? // null) end),
         owner: (if $owner == "" then null else $owner end),
         priority: (if $priority == "" then null else $priority end),
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
         group: null, order: null, owner: null, priority: null, deps: [], origin: null,
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
           group: null, order: null, owner: null, priority: null, deps: [], origin: null,
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
