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
# init/claim/relocate — see `current --any`, `list --owners`, and `overview`'s
# `owner` field).
#
# v2.24.0: the sidecar carries a `priority` — the plan's IMPACT tier, one of
# critical|high|medium|low|noise or null — so /mentor:track's hierarchy can say which
# plans matter and which are noise. Written by `init --priority` and `set-priority`;
# read back on every `overview --json` plan entry. Orthogonal to `order` (sequence
# WITHIN a split group) and `deps` (what must be built FIRST) — neither of those says
# whether a plan is worth building at all.
#
# v2.25.0: two more sidecar fields for triaging deferred stubs, plus a derived
# `overview` key — all mirroring the priority-tier pattern above:
#   `category`      the plan's WORK KIND, one of feature|fix|refactor|docs|tooling or
#                    null — a CLOSED vocabulary, deliberately excluding anything
#                    test/verify-shaped (a stub's Goal names work to build, never a
#                    check to run). Written by `init --category` and `set-category`;
#                    read back on every `overview --json` plan entry.
#   `deferred_from`  the plan slug a `/mentor:defer` stub was captured out of, or
#                    null — UNVALIDATED like a `deps` target (no script-side missing
#                    flag; a dangling value is resolved at render time, by the
#                    consumer, against the same `overview` array). Written only by
#                    `init --from` — there is no `set-deferred-from`.
#   `goal`           (overview --json only, not stored) the `## Goal` section's first
#                    paragraph, reflowed to one line and word-boundary truncated —
#                    computed ONLY for entries whose `origin` is "deferred", so an
#                    ordinary plan never pays the extra file read.
#
#   init <slug> [--group G] [--order N] [--deps a,b] [--deferred] [--priority P]
#        [--category C] [--from S]
#       Create the sidecar as `draft`. Idempotent and never LOWERS an existing
#       state — re-running it on an approved plan keeps it approved. --deps sets the
#       initial dependency slugs (cycle-checked, same as set-deps); --deferred marks
#       the plan a stub born via /mentor:defer (origin: "deferred" — shields it from
#       approve-plan's promotion sweep until `claim`ed); --priority sets the initial
#       impact tier (same closed vocabulary as set-deps' sibling `set-priority`);
#       --category sets the initial work kind (closed vocabulary, sibling
#       `set-category`); --from stamps `deferred_from` — the plan slug this stub was
#       captured out of (unvalidated pass-through, like a `deps` target).
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
#   set-category <slug> <feature|fix|refactor|docs|tooling|"">
#       Set <slug>'s work kind; an EMPTY string clears it back to unset (null). A
#       CLOSED vocabulary, validated here exactly like set-priority, and for the same
#       reason: /mentor:track buckets by it, and an unvalidated typo would silently
#       become a sixth bucket. Deliberately no test/verify entry — see the v2.25.0
#       note above. An invalid value is a usage error (exit 1, no write). Its own
#       subcommand for the same reason set-priority is one.
#
#   claim <slug>
#       Clear `origin` — used when a deferred stub (born via /mentor:defer) enters
#       real planning, so approve-plan's promotion sweep can promote it like any plan.
#       Keeps `category`/`priority`/`deferred_from` — a claimed stub's triage history
#       stays readable.
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
#       priority, category, deferred_from, deps — each marked missing when no such
#       plan dir exists, origin, live handoffs, ticked/total step counts, goal), plus
#       topic dirs that hold live handoffs but no plan.md yet (state "no plan yet")
#       and the legacy flat handoffs/ dir (topic-less). `priority`/`category`/
#       `deferred_from`/`goal` are null on every entry that has none, including both
#       non-plan kinds, so a consumer never has to branch on kind to read them. `goal`
#       is the ONLY one of these NOT stored in the sidecar — it is derived, per call,
#       from the `## Goal` section of a `origin: "deferred"` entry's own plan.md (see
#       lib/state.sh's mentor_plan_goal_line), reflowed to one line and
#       word-boundary-truncated; null for every non-deferred entry. Computed fresh
#       every call — nothing is cached.
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
       [--category C] [--from S]        create the sidecar as draft (idempotent)
  set <slug> <state> [--note "…"]       state: draft|approved|in_progress|implemented|failed|superseded
  set-deps <slug> a,b                   replace deps wholesale (cycle-checked, fail-soft)
  set-priority <slug> <P>               impact tier: critical|high|medium|low|noise ("" clears)
  set-category <slug> <C>               work kind: feature|fix|refactor|docs|tooling ("" clears)
  claim <slug>                          clear origin (a deferred stub enters real planning);
                                         keeps category/priority/deferred_from
  tick <slug> <N>                       append ✅ to step N in plan.md (idempotent, fails loud)
  verify <slug>                         plan.md structural checks (fence balance, table pipe-count,
                                         Rev-note order) + a folded CONTEXT read, as CHECK: lines;
                                         exit 1 iff a structural check fails (context/Rev-order are
                                         informational only)
  list [--group G] [--owners]           every plan with its effective state (--owners adds OWNER)
  current [--any]                       the current plan, owned-by-this-worktree scoped (group-aware);
                                         --any for a deliberate repo-wide read
  overview --json                       repo-wide JSON: plans + priority/category/deferred_from +
                                         deps + live handoffs + step counts + goal (deferred entries)
  context                               CONTEXT: ASK|HANDOFF|WARN|OK|UNKNOWN (~N tokens)
  dir [--plans]                         the repo-scoped mentor dir (or its plans dir)
  gate [--verbose]                      ARMED|STALE|ARMED_ELSEWHERE|RELEASED — read-only marker
                                         status for THIS worktree (--verbose adds per-token fields;
                                         see the gate doc comment above for the exact contract)
  ensure-dir <path>                     mkdir it + chmod 700 the whole path; echoes it
  relocate <src-plan-dir>                copy a plan from a DIFFERENT repo's
                                         .mentor/plans/<slug> into THIS repo (run
                                         from the destination repo) and re-own it
                                         here; never deletes the source
  handoff-path <topic> <slug>           resolve/create <topic>'s private handoffs/ dir + gitignore,
                                         echo the timestamped note path (handoff-note Step 2)
  handoff-selfcheck <note-path>         supersede <topic>'s older notes into resolved/, print
                                         CHECK: live notes now / CHECK: headings missing: (Step 5)
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
  # A direct child of plans/ is a plan TOPIC dir — the first of the four owner-
  # stamping sites (ensure-dir/init/claim/relocate — see the state-layout header
  # comment and this file's top-of-file v2.23.0 note), because the normal flow writes plan.md
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

# --- relocate <src-plan-dir>: copy a plan from a DIFFERENT repo into this one and
# re-own it here. Run from the DESTINATION repo. Sits here (before the plans_dir
# gate below, alongside ensure-dir) rather than in the main case block precisely
# BECAUSE it must work in a destination repo that has no plans dir yet — the
# whole point of relocating a plan into a repo mentor has never tracked before —
# and the main case block's `[ ! -d "$plans_dir" ]` guard would fail-soft-exit
# before ever reaching a case arm placed there. Deliberately narrow: every write
# this makes stays inside THIS repo's own already-confined mentor dir (the source
# is only ever READ, via `cp -R`), so it needs none of ensure-dir's path-
# confinement guard against the source — that guard exists to stop a model-chosen
# path from escaping THIS repo's .mentor tree, which cannot happen here since
# nothing is ever written under the source path. The source plan is never deleted
# (a two-repo `mv` has no atomic rollback if the copy side fails partway), so the
# caller removes it by hand once they've confirmed the copy landed.
if [ "$sub" = "relocate" ]; then
  rl_src="${1:-}"
  if [ "$#" -gt 1 ]; then
    echo "[mentor plan-state] relocate: unexpected argument ${2}" >&2
    exit 1
  fi
  if [ -z "$rl_src" ]; then
    echo "[mentor plan-state] relocate needs <src-plan-dir> — the OTHER repo's <slug> plan directory (…/.mentor/plans/<slug>). Run this from the DESTINATION repo." >&2
    exit 1
  fi
  # No require_jq here (unlike the main-case-block subcommands) — this block runs
  # BEFORE require_jq's own definition is reached in the file, same constraint
  # ensure-dir/handoff-path already live with. mentor_plan_state_write/_stored/
  # _field all fail-soft on a missing jq internally, same as ensure-dir's stamp.
  rl_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$rl_repo" ]; then
    rl_mdir="$(mentor_state_dir "$rl_repo")"
  else
    rl_mdir="$HOME/.claude/mentor/_no-repo"
  fi
  rl_src_canon="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$rl_src" 2>/dev/null || echo "$rl_src")"
  rl_src_parent="$(dirname "$rl_src_canon")"
  if [ ! -d "$rl_src_canon" ] || [ "$(basename "$rl_src_parent")" != "plans" ] \
     || [ "$(basename "$(dirname "$rl_src_parent")")" != ".mentor" ]; then
    echo "[mentor plan-state] relocate refuses a source that isn't an existing <repo>/.mentor/plans/<slug> directory: ${rl_src}" >&2
    exit 1
  fi
  if [ ! -f "${rl_src_canon}/plan.md" ] || [ ! -f "${rl_src_canon}/.state.json" ]; then
    echo "[mentor plan-state] relocate refuses ${rl_src_canon} — missing plan.md or .state.json (not a real plan dir)." >&2
    exit 1
  fi
  rl_slug="$(basename "$rl_src_canon")"
  rl_dst="${rl_mdir}/plans/${rl_slug}"
  rl_dst_canon="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$rl_dst" 2>/dev/null || echo "$rl_dst")"
  if [ "$rl_dst_canon" = "$rl_src_canon" ]; then
    echo "[mentor plan-state] relocate: source and destination are the same directory — nothing to do." >&2
    exit 1
  fi
  if [ -e "$rl_dst" ]; then
    echo "[mentor plan-state] relocate refuses — ${rl_dst} already exists. Pick a different slug in the destination, or remove/merge it by hand first." >&2
    exit 1
  fi
  rl_wt_id="$(mentor_worktree_id "$(pwd)")"
  # Collision check reads whatever owner is on record for the (not-yet-created)
  # destination slug — a no-op today (it always returns 0 before $rl_dst exists),
  # kept for the same TOCTOU-race defense ensure-dir/init keep it for.
  warn_same_slug_collision "$rl_dst" "$rl_wt_id" "${rl_mdir}/plans"
  # Ensure the PARENT (plans/) exists + is 700 — but NOT $rl_dst itself: `cp -R src
  # dst` copies src's CONTENTS into dst only when dst does not yet exist; if dst is
  # already a directory, cp nests src one level deeper instead (dst/$(basename src)),
  # which would silently land plan.md/.state.json a level too deep and desync every
  # path this subcommand computes below it.
  mentor_ensure_private_dir "$rl_mdir" "${rl_mdir}/plans"
  if ! cp -R "$rl_src_canon" "$rl_dst" 2>/dev/null; then
    echo "[mentor plan-state] relocate: copy from ${rl_src_canon} to ${rl_dst} failed — nothing was moved; check permissions/disk space." >&2
    rm -rf "$rl_dst" 2>/dev/null || true
    exit 1
  fi
  chmod 700 "$rl_dst" 2>/dev/null || true
  # Fourth of the four owner-stamping sites (see this file's top-of-file v2.23.0
  # note): re-owns the copied sidecar to THIS worktree, same last-init-wins shape
  # as `init` — preserves whatever state/category/priority/deps/deferred_from the
  # copy carried over, only overwriting owner/owner_session.
  rl_existing="$(mentor_plan_state_stored "$rl_dst")"
  rl_write_args=(--state "${rl_existing:-draft}" --note "$(mentor_plan_state_field "$rl_dst" note)")
  if [ -n "$rl_wt_id" ]; then
    rl_write_args+=(--owner "$rl_wt_id" --owner-session "${CLAUDE_CODE_SESSION_ID:-}")
  fi
  mentor_plan_state_write "$rl_dst" "${rl_write_args[@]}"
  echo "[mentor plan-state] ${rl_slug}: relocated from ${rl_src_canon} → ${rl_dst}; re-owned to this worktree ($(mentor_plan_effective_state "$rl_dst"))."
  echo "[mentor plan-state] source NOT deleted — remove ${rl_src_canon} yourself once you've confirmed the copy."
  rl_stale_hits="$(awk '/^## Suggested first steps/{f=1;next} /^## /{f=0} f' "${rl_dst}/plan.md" 2>/dev/null \
    | grep -noE '[[:alnum:]_.-]+/[[:alnum:]/_.-]+' | head -20)"
  if [ -n "$rl_stale_hits" ]; then
    echo "[mentor plan-state] WARNING: plan.md's Suggested first steps still names repo-relative paths that may be stale after this move:" >&2
    printf '%s\n' "$rl_stale_hits" | sed 's/^/  /' >&2
  fi
  echo "[mentor plan-state] WARNING: if the source repo's plan-gate marker is still armed for this plan, its gate will not protect edits made back there — check with 'plan-state.sh gate --verbose' in the source repo." >&2
  exit 0
fi

# --- handoff-path <topic> <slug>: the ONE call handoff-note's Step 2 needs — resolve
# the worktree-safe mentor dir, confine + create <topic>'s private handoffs/ dir, write
# the mentor-dir gitignore, and print the timestamped note path. Replaces a 4-invocation
# inline snippet (dir, ensure-dir, a hand-rolled gitignore write, then the timestamp)
# that needed ${CLAUDE_PLUGIN_ROOT} substituted correctly at every one of those calls —
# collapsing them to one command means only one substitution can go wrong, not several
# (a session was observed hardcoding a version-pinned cache path instead, defeating the
# ERROR guard Step 2 already carried for exactly this failure).
if [ "$sub" = "handoff-path" ]; then
  hp_topic="${1:-}"; hp_slug="${2:-}"
  if [ -z "$hp_topic" ] || [ -z "$hp_slug" ]; then
    echo "[mentor plan-state] handoff-path needs <topic> <slug>." >&2
    exit 1
  fi
  # <topic>/<slug> are model-chosen and become path segments — reject a slash/dot-segment
  # (path traversal or a bogus nesting) and an unreplaced `<…>` placeholder (Step 2's own
  # "never leave a literal <…> placeholder" rule) before they ever reach a path.
  case "$hp_topic$hp_slug" in
    *'<'*|*'>'*)
      echo "[mentor plan-state] handoff-path refuses an unreplaced <…> placeholder in topic/slug: '${hp_topic}' '${hp_slug}'" >&2
      exit 1
      ;;
  esac
  case "$hp_topic" in
    */*|.|..)
      echo "[mentor plan-state] handoff-path refuses a topic containing '/' or being '.'/'..': ${hp_topic}" >&2
      exit 1
      ;;
  esac
  case "$hp_slug" in
    */*|.|..)
      echo "[mentor plan-state] handoff-path refuses a slug containing '/' or being '.'/'..': ${hp_slug}" >&2
      exit 1
      ;;
  esac
  hp_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$hp_repo" ]; then
    hp_mdir="$(mentor_state_dir "$hp_repo")"
  else
    hp_mdir="$HOME/.claude/mentor/_no-repo"
  fi
  hp_target="${hp_mdir}/plans/${hp_topic}/handoffs"
  # Confine it — <topic> is model-chosen, so without this a handoff-note run could be
  # steered to create/chmod an arbitrary path via `../` (same guard as `ensure-dir`).
  if ! hp_canon="$(mentor_confine_path "$hp_mdir" "$hp_target")"; then
    echo "[mentor plan-state] handoff-path refuses a path outside ${hp_mdir}: ${hp_topic}" >&2
    exit 1
  fi
  # mentor_ensure_private_dir wants the STATE dir (for its own base-relative chmod cascade),
  # not the target — pass the canonical form of hp_mdir, not hp_canon, or a symlinked repo
  # path (e.g. macOS /tmp → /private/tmp) makes its own base check miss and degrade to a
  # leaf-only chmod.
  hp_base="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$hp_mdir" 2>/dev/null || echo "$hp_mdir")"
  mentor_ensure_private_dir "$hp_base" "$hp_canon"
  case "$hp_mdir" in
    */_no-repo) ;;   # outside a repo — nothing to gitignore
    *) mentor_ensure_gitignore "$hp_mdir" ;;
  esac
  echo "${hp_canon}/$(date +%Y%m%d-%H%M%S)-${hp_slug}.md"
  exit 0
fi

# --- handoff-selfcheck <note-path>: the ONE call handoff-note's Step 5 needs —
# supersede this topic's older notes into resolved/, then print THREE verdict lines
# (`CHECK: live notes now …` / `CHECK: headings missing:…` / `CHECK: current-state
# evidence missing:…`) atomically, and exit non-zero when any of the first two verdicts
# is bad — a non-zero exit surfaces in the tool result even if the note-writing agent
# only skims it, which is stronger than "print a verdict and hope it gets read". Replaces
# a ~25-line inline snippet the agent had to hand-reproduce from prose on every run; a
# session was observed reproducing only the supersede + live-notes half and silently
# dropping the headings-check, then reporting "written and verified" anyway — a
# partial-copy failure a single command call cannot exhibit.
#
# NOT consolidated here (deliberately, not an oversight): skills/shipping/SKILL.md has
# its own independent "supersede every conforming note in a topic's handoffs/ into
# resolved/" loop (no --except, label "work shipped" instead of "superseded") that is
# the same mechanical operation minus the exclusion this subcommand needs. Folding both
# into one shared `handoff-resolve <dir> [--except <note>] [--label <text>]` primitive
# is the right long-term shape, but doing that here would mean editing a second
# skill doc this session never analyzed evidence from — left for a future
# `/loom:learn mentor` pass with its own session evidence and review cycle.
if [ "$sub" = "handoff-selfcheck" ]; then
  hs_out="${1:-}"
  if [ -z "$hs_out" ]; then
    echo "[mentor plan-state] handoff-selfcheck needs <note-path>." >&2
    exit 1
  fi
  hs_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$hs_repo" ]; then
    hs_mdir="$(mentor_state_dir "$hs_repo")"
  else
    hs_mdir="$HOME/.claude/mentor/_no-repo"
  fi
  hs_dir="$(dirname "$hs_out")"
  # Confine it — <note-path> crosses a Bash-tool-call boundary (the agent re-types it from
  # Step 2's output), so a mistyped/hallucinated path must refuse rather than supersede or
  # `mv` files somewhere outside the mentor tree.
  if ! hs_canon_dir="$(mentor_confine_path "$hs_mdir" "$hs_dir")"; then
    echo "[mentor plan-state] handoff-selfcheck refuses a note path outside ${hs_mdir}: ${hs_out}" >&2
    exit 1
  fi
  hs_fail=0
  # Verify BEFORE superseding — if $out isn't actually on disk, there is nothing to
  # supersede FOR, and running the loop anyway would archive the topic's real prior note
  # (the only remaining live one) while reporting the wrong thing was written.
  if [ -f "$hs_out" ]; then
    hs_name="$(basename "$hs_out")"
    for hs_old in "$hs_canon_dir"/*.md; do
      [ -f "$hs_old" ] || continue
      [ "$(basename "$hs_old")" = "$hs_name" ] && continue
      case "$(basename "$hs_old")" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.md)
          mkdir -p "$hs_canon_dir/resolved" 2>/dev/null || true
          chmod 700 "$hs_canon_dir/resolved" 2>/dev/null || true
          mv "$hs_old" "$hs_canon_dir/resolved/$(basename "$hs_old")"
          echo "superseded → resolved: $(basename "$hs_old")" ;;
        *)
          echo "  (skipping non-conforming file: $(basename "$hs_old"))" ;;
      esac
    done
  else
    echo "CHECK: \$out is not a file — the note is not where you think it is"
    hs_fail=1
  fi
  hs_live=0
  for hs_f in "$hs_canon_dir"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.md; do
    [ -f "$hs_f" ] || continue
    hs_live=$((hs_live + 1))
  done
  echo "CHECK: live notes now ${hs_live} (expect 1 — the note just written)"
  [ "$hs_live" -eq 1 ] || hs_fail=1
  hs_miss=""
  if [ -f "$hs_out" ]; then
    grep -Eq '^#+[[:space:]].*[Gg]oal.*next-session focus' "$hs_out" || hs_miss="$hs_miss Goal/next-session-focus"
    grep -Eq '^#+[[:space:]].*[Rr]ecommended.*commands' "$hs_out"    || hs_miss="$hs_miss Recommended-mentor-commands"
  fi
  echo "CHECK: headings missing:${hs_miss:- none (2/2 present)}"
  [ -z "$hs_miss" ] || hs_fail=1
  # Current-state evidence: informational only (does not affect the exit code) — unlike the
  # two checks above, this is a heuristic over free-form prose, not a deterministic parse of
  # a fixed heading pattern, so a false positive here must never block a genuinely-complete
  # note. Step 3 requires the gate --verbose token and a TaskList-close-out mention to be
  # PRESENT in Current state, not merely run — this is that presence check.
  hs_ev=""
  if [ -f "$hs_out" ]; then
    grep -Eq 'ARMED|STALE|RELEASED' "$hs_out"  || hs_ev="$hs_ev gate-verdict"
    grep -Eiq 'tasklist'            "$hs_out"  || hs_ev="$hs_ev TaskList-evidence"
  fi
  echo "CHECK: current-state evidence missing:${hs_ev:- none (2/2 present)}"
  [ "$hs_fail" -eq 0 ] && exit 0
  exit 1
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
  init|set|set-deps|set-priority|set-category|claim|tick|verify|list|current|overview) ;;
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
#   priority  category  deferred_from  goal
# `owner` (v2.23.0, mentor_plan_owner) is the wt-id that minted or last re-owned the
# plan dir, or "-" when unowned. `priority` (v2.24.0, mentor_plan_priority) is the
# impact tier, or "-" when unset; it is APPENDED at the end rather than slotted beside
# `order` on purpose — `list_rows` reads only the first five fields and drops the
# tail into a single `_rest`, so a trailing field cannot disturb the byte-compatible
# 5-column `list` output, while an inserted one would shift every field after it.
# `category`/`deferred_from`/`goal` (v2.25.0, mentor_plan_category/
# mentor_plan_deferred_from/mentor_plan_goal_line) follow the SAME append-only rule —
# they are APPENDED LAST, after `priority`, never slotted in among the earlier
# fields, for exactly the reason above: `list_rows`' `_rest` field-swallow only stays
# safe when every new field lands at the tail. `category`/`deferred_from` read "-"
# when unset, same convention as `priority`; `goal` is likewise "-" for every
# non-deferred entry (see below). `deps_json`/`handoffs_json` are compact (`jq -c`)
# single-line JSON — safe to sit in a tab field because compact jq output never
# contains a literal tab or newline, even inside a string. `list_rows` (below,
# byte-compatible with the pre-v2.17.0 5-field format) and `overview --json` both
# derive from this ONE walk — neither re-walks plans_dir on its own. `list`/`current`
# never needed deps/handoffs/step-counts, so computing them for those two callers too
# is a deliberate small cost in exchange for there being exactly one place that
# decides what "every plan" means.
_plan_walk() {
  local filter="${1:-}" d slug state group order owner origin deps_pairs deps_json
  local handoffs_json ticked total dep miss priority category deferred_from goal
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
    category="$(mentor_plan_category "$d")"
    deferred_from="$(mentor_plan_deferred_from "$d")"
    goal=""
    # Gate: mentor_plan_goal_line re-reads plan.md, so it runs ONLY for entries
    # whose origin is "deferred" — every ordinary plan skips this file read
    # entirely, which is what keeps overview fast on a big plan set.
    if [ "$origin" = "deferred" ]; then
      goal="$(mentor_plan_goal_line "${d}/plan.md")"
    fi
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
    # so a genuinely-empty group/order/owner/origin/priority/category/deferred_from/
    # goal would silently shift every field after it for whoever reads this line.
    # Emit "-" for empty (matching print_table's own existing display convention) and
    # never a raw empty string here; consumers translate "-" back to "" on read. This
    # applies to the LAST field as much as the middle ones: `read` assigns an absent
    # trailing field as empty anyway, so a bare "" there would be indistinguishable
    # from a short record. `goal` can never itself carry a tab (mentor_plan_goal_line
    # strips them), so it is safe to sit as a plain field here too.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$slug" "$state" "${group:--}" "${order:--}" "${owner:--}" "$deps_json" "${origin:--}" "$handoffs_json" "$ticked" "$total" "${priority:--}" "${category:--}" "${deferred_from:--}" "${goal:--}"
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
# FRESH transition into a terminal state, gauged off the STORED sidecar
# (before_stored != state), not the tick-self-healing effective read — a plan whose
# ✅ ticks alone already self-heal the effective state to "implemented" must still
# get this reminder on its real first `set … implemented`. So shipping/merging's
# later `set … implemented` — which idempotently re-closes a plan dispatch-agents
# already closed — stays silent instead of re-nagging mid-ship. The TaskList line is
# the only conditional part: it prints only when this session's own transcript shows an
# Agent dispatch with no matching TaskList call — a prior learn fix already reworded
# that rule's prose once and the same miss recurred, so this gives it a structural
# trigger instead of depending on the model re-reading ~15 lines of prose late in a
# session. The defer-sweep line is unconditional on both terminal states, matching the
# checklist's own "always, whatever Verification returned." (v2.25.0: reworded to
# scope the sweep — a deferred stub captures isolated WORK to build, never a check to
# run; an unresolved verification topic belongs on ITS OWN plan's record via
# `set <slug> failed --note "…"`, not a backlog stub that lets the plan close clean.)
# The tour/ship lines print only for `implemented` — the checklist explicitly holds
# them on `failed`/handed-off ("which speak for work that was accepted"). Never
# blocks — the state write already succeeded by the time this runs.
closing_checklist_reminder() {
  local tx="${1:-}" outcome="${2:-}" tasklist_line=""
  if [ -n "$tx" ] && [ -f "$tx" ] \
     && grep -q '"name":"Agent"' "$tx" 2>/dev/null \
     && ! grep -q '"name":"TaskList"' "$tx" 2>/dev/null; then
    tasklist_line="
  - TaskList: enumerate live tasks, diff against this session's dispatch tree, TaskStop only what traces to it."
  fi
  echo "[mentor plan-state] Closing checklist (dispatch-agents' CLOSING CHECKLIST):${tasklist_line}"
  echo "  - Sweep any follow-up WORK through /mentor:defer before it's forgotten — never a check: an unresolved verification topic ends 'failed --note', not a stub."
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
    slug=""; group=""; order=""; deps=""; deferred=0; priority=""; category=""; from_slug=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        # shift 1 then conditionally 1 more: a bare trailing `--group` must not
        # leave $# unchanged and spin this loop forever.
        --group) group="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --order) order="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --deps) deps="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --deferred) deferred=1; shift ;;
        --priority) priority="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --category) category="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --from) from_slug="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        -*) echo "[mentor plan-state] init: unknown flag ${1}" >&2; usage >&2; exit 1 ;;
        *)  [ -z "$slug" ] && slug="$1" || { echo "[mentor plan-state] init: unexpected argument ${1}" >&2; exit 1; }; shift ;;
      esac
    done
    require_slug "$slug"
    # Validated BEFORE any write, like `set`'s state check — a typo'd tier/category is
    # a usage error, not a fail-soft skip, so `init` can never report success having
    # quietly dropped the one field the caller passed it. (A `--deps` cycle stays
    # fail-soft by contrast: that is a graph condition the caller could not have known
    # locally, not a misspelling. `--from` stays UNVALIDATED for the same reason
    # `--deps` targets are — the source plan slug it names may not exist yet, or may
    # be deleted later; that dangle is resolved at render time, not here.) An EMPTY
    # --priority/--category is not an error and not a clear — init never clears
    # anything; every other flag here preserves on empty the same way, and
    # `set-priority`/`set-category <slug> ""` are the one paths that un-tier/
    # un-categorize a plan.
    if [ -n "$priority" ] && ! mentor_plan_priority_valid "$priority"; then
      echo "[mentor plan-state] init: invalid priority '${priority}'." >&2
      echo "Valid priorities: ${MENTOR_PLAN_PRIORITIES}  (or \"\" to leave unset)" >&2
      exit 1
    fi
    if [ -n "$category" ] && ! mentor_plan_category_valid "$category"; then
      echo "[mentor plan-state] init: invalid category '${category}'." >&2
      echo "Valid categories: ${MENTOR_PLAN_CATEGORIES}  (or \"\" to leave unset)" >&2
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
    [ -n "$category" ] && write_args+=(--category "$category")
    [ -n "$from_slug" ] && write_args+=(--deferred-from "$from_slug")
    # Second of the four owner-stamping sites (see this file's top-of-file v2.23.0
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
    echo "[mentor plan-state] ${slug}: $(mentor_plan_effective_state "$plan_dir")${group:+  group=${group}}${order:+  order=${order}}${priority:+  priority=${priority}}${category:+  category=${category}}${deps_summary:+  deps=${deps_summary}}$([ "$deferred" -eq 1 ] && printf '  origin=deferred')${from_slug:+  from=${from_slug}}"
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
    # Freshness for the reminders below is judged off this STORED read, not `before`
    # above — `before` is effective (max of stored, tick-derived) and self-heals to
    # "implemented" from ✅ ticks alone, before any `set` call ever runs. Gating on
    # that would make the real first `set … implemented` look like an idempotent
    # re-close and silently skip every reminder. `before_stored` only changes when a
    # write actually persists it, so ticks alone can't fool it.
    before_stored="$(mentor_plan_state_stored "$plan_dir")"
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
        # Fire only on a FRESH transition — before_stored == state means this call is
        # an idempotent re-close (e.g. shipping/merging re-running `set … implemented`
        # after dispatch-agents already closed it), which must stay silent.
        if [ "$before_stored" != "$state" ]; then
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

  set-category)
    # The VALUE is required as a positional even when it is the empty string, so
    # `set-category <slug>` with nothing after it is a usage error rather than a
    # silent clear — un-categorizing must be something the caller typed on purpose
    # (`set-category <slug> ""`), not what a dropped shell argument decays into.
    slug="${1:-}"; if [ "$#" -gt 0 ]; then shift; fi
    require_slug "$slug"
    if [ "$#" -eq 0 ]; then
      echo "[mentor plan-state] set-category: a <category> is required (use \"\" to clear)." >&2
      usage >&2
      exit 1
    fi
    cat_val="$1"; shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] set-category: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    if [ -n "$cat_val" ] && ! mentor_plan_category_valid "$cat_val"; then
      echo "[mentor plan-state] set-category: invalid category '${cat_val}'." >&2
      echo "Valid categories: ${MENTOR_PLAN_CATEGORIES}  (or \"\" to clear)" >&2
      exit 1
    fi
    require_jq
    plan_dir="${plans_dir}/${slug}"
    # Re-read and re-pass the note for the same reason set-priority does:
    # mentor_plan_state_write always REPLACES --note (even when omitted, which would
    # clear it), so a category-only write must round-trip the current note.
    mentor_plan_state_write "$plan_dir" --category "$cat_val" --note "$(mentor_plan_state_field "$plan_dir" note)"
    echo "[mentor plan-state] ${slug}: category = ${cat_val:-(unset)}"
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
    # Third of the four owner-stamping sites (see this file's top-of-file v2.23.0
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

  # --- verify <slug>: the ONE call planning's "Verify the write" (SKILL.md, Step 4)
  # needs before every approval ask. Replaces a fresh awk/grep one-liner the agent
  # was observed hand-rebuilding differently on 5 consecutive asks in one session —
  # never the same check twice, and the one ask that dropped the table check is
  # exactly where a table-adjacent defect landed. Same rationale as handoff-selfcheck
  # above: a script call cannot exhibit a partial-copy failure the way a
  # freshly-typed one-liner can.
  #
  # Two DETERMINISTIC checks gate the exit code (fence balance, table pipe-count
  # uniformity) — both already mandated in SKILL.md:447-460 prose, backed by nothing
  # until now. Two more print as informational CHECK: lines and never fail verify:
  # Rev-note order (the plugin's content spec does not mandate a Rev-note changelog
  # at all, so flagging its ABSENCE would be a false-positive machine; when Rev
  # lines DO exist this only reports a non-monotonic sequence, it never blocks) and
  # the CONTEXT verdict (folds planning/SKILL.md's separately-mandated pre-ask
  # context re-check into the one command the agent already calls reliably, rather
  # than a second command observed skipped before half this session's asks; the
  # calling skill still decides how to act on ASK/HANDOFF/WARN via `context` itself).
  verify)
    slug="${1:-}"; [ "$#" -gt 0 ] && shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] verify: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    require_slug "$slug"
    plan_md="${plans_dir}/${slug}/plan.md"
    if [ ! -f "$plan_md" ]; then
      echo "[mentor plan-state] verify: no plan.md at ${plan_md}." >&2
      exit 1
    fi
    v_fail=0

    # `|| true` on every substitution below: under this file's `set -euo pipefail`,
    # grep/a pipeline legitimately finding ZERO matches (no fences, no tables, no Rev
    # lines — the common case for the last of those, since Rev headers aren't part of
    # the content spec) exits non-zero and would otherwise abort verify entirely
    # before it prints a single CHECK: line.
    v_fences=$(grep -c '^```' "$plan_md" || true)
    if [ $((v_fences % 2)) -eq 0 ]; then
      echo "CHECK: fences balanced (${v_fences} markers)"
    else
      echo "CHECK: fences UNBALANCED (${v_fences} markers — an odd count means one never closed)"
      v_fail=1
    fi

    # Every contiguous block of '|'-led lines must share one pipe count — a splice
    # that drops/adds a column mid-table doesn't error on write, it just breaks here.
    v_bad_tables="$(awk '
      /^\|/ {
        n = gsub(/\|/, "|", $0)
        if (block == 0) { block = 1; first = n; start = NR }
        else if (n != first) { bad = 1 }
        next
      }
      block == 1 {
        if (bad == 1) print "line " start ": pipe-count mismatch"
        block = 0; bad = 0
      }
      END { if (block == 1 && bad == 1) print "line " start ": pipe-count mismatch" }
    ' "$plan_md" || true)"
    if [ -z "$v_bad_tables" ]; then
      echo "CHECK: tables uniform (one pipe-count per block)"
    else
      echo "CHECK: table pipe-count MISMATCH:"
      printf '%s\n' "$v_bad_tables" | sed 's/^/  /'
      v_fail=1
    fi

    v_revseq="$(sed '/^##/q' "$plan_md" | grep -oE '^Rev [0-9]+' | grep -oE '[0-9]+' || true)"
    if [ -n "$v_revseq" ]; then
      v_mono="$(printf '%s\n' "$v_revseq" | awk '
        NR == 1 { prev = $1; next }
        { if ($1 > prev) asc = 1; if ($1 < prev) desc = 1; prev = $1 }
        END { print (asc && desc) ? "no" : "yes" }
      ')"
      v_seq_str="$(printf '%s' "$v_revseq" | paste -sd, -)"
      if [ "$v_mono" = "yes" ]; then
        echo "CHECK: Rev-note order monotonic (${v_seq_str})"
      else
        echo "CHECK: Rev-note order NOT monotonic (${v_seq_str}) — changelog may be hard to scan (informational only)"
      fi
    fi

    v_ctx_repo="$(mentor_repo_root "$(pwd)")"
    v_verdict="$(mentor_context_verdict "$v_ctx_repo" "$(pwd)")"
    if [ -n "$v_verdict" ]; then
      read -r v_ctx_level v_ctx_tokens v_ctx_rest <<<"$v_verdict"
      echo "CHECK: context ${v_ctx_level} (~${v_ctx_tokens} tokens)"
    else
      echo "CHECK: context UNKNOWN (not measurable — gate off, or no transcript/jq)"
    fi

    [ "$v_fail" -eq 0 ] && exit 0
    exit 1
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
    while IFS="$(printf '\t')" read -r ov_slug ov_state ov_group ov_order ov_owner ov_deps ov_origin ov_handoffs ov_ticked ov_total ov_priority ov_category ov_deferred_from ov_goal; do
      [ -n "$ov_slug" ] || continue
      [ "$ov_group" = "-" ] && ov_group=""    # un-placeholder — see _plan_walk's comment
      [ "$ov_order" = "-" ] && ov_order=""
      [ "$ov_owner" = "-" ] && ov_owner=""
      [ "$ov_origin" = "-" ] && ov_origin=""
      [ "$ov_priority" = "-" ] && ov_priority=""
      [ "$ov_category" = "-" ] && ov_category=""
      [ "$ov_deferred_from" = "-" ] && ov_deferred_from=""
      [ "$ov_goal" = "-" ] && ov_goal=""
      entry="$(jq -n \
        --arg slug "$ov_slug" --arg state "$ov_state" --arg group "$ov_group" --arg order "$ov_order" \
        --arg owner "$ov_owner" --arg priority "$ov_priority" \
        --arg category "$ov_category" --arg deferred_from "$ov_deferred_from" --arg goal "$ov_goal" \
        --argjson deps "$ov_deps" --arg origin "$ov_origin" --argjson handoffs "$ov_handoffs" \
        --argjson ticked "$ov_ticked" --argjson total "$ov_total" '
        {kind: "plan", slug: $slug, state: $state,
         group: (if $group == "" then null else $group end),
         order: (if $order == "" then null else ($order | tonumber? // null) end),
         owner: (if $owner == "" then null else $owner end),
         priority: (if $priority == "" then null else $priority end),
         category: (if $category == "" then null else $category end),
         deferred_from: (if $deferred_from == "" then null else $deferred_from end),
         deps: $deps, origin: (if $origin == "" then null else $origin end),
         handoffs: $handoffs, steps: {ticked: $ticked, total: $total},
         goal: (if $goal == "" then null else $goal end)}')"
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
         group: null, order: null, owner: null, priority: null, category: null, deferred_from: null,
         deps: [], origin: null,
         handoffs: $handoffs, steps: {ticked: 0, total: 0}, goal: null}')"
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
           group: null, order: null, owner: null, priority: null, category: null, deferred_from: null,
           deps: [], origin: null,
           handoffs: $handoffs, steps: null, goal: null}')"
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
