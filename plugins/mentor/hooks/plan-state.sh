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
# init/claim/relocate — see `current --any`, `list --owners`, and `query`'s
# `owner` field).
#
# v2.24.0: the sidecar carries a `priority` — the plan's IMPACT tier, one of
# critical|high|medium|low|noise or null — so /mentor:track's hierarchy can say which
# plans matter and which are noise. Written by `init --priority` and `set-priority`;
# read back on every `query` plan entry. Orthogonal to `order` (sequence
# WITHIN a split group) and `deps` (what must be built FIRST) — neither of those says
# whether a plan is worth building at all.
#
# v2.25.0: two more sidecar fields for triaging deferred stubs, plus a derived
# `query` key — all mirroring the priority-tier pattern above:
#   `category`      the plan's WORK KIND, one of feature|fix|refactor|docs|tooling or
#                    null — a CLOSED vocabulary, deliberately excluding anything
#                    test/verify-shaped (a stub's Goal names work to build, never a
#                    check to run). Written by `init --category` and `set-category`;
#                    read back on every `query` plan entry.
#   `deferred_from`  the plan slug a `/mentor:defer` stub was captured out of, or
#                    null — UNVALIDATED like a `deps` target (no script-side missing
#                    flag; v2.33.0 note: `query` now resolves it to `{slug, missing}`
#                    for the consumer, so a dangle is no longer a render-time concern).
#                    Written only by `init --from` — there is no `set-deferred-from`.
#   `goal`           (query only, not stored) the `## Goal` section's first
#                    paragraph, reflowed to one line and word-boundary truncated —
#                    computed ONLY for entries whose `origin` is "deferred", so an
#                    ordinary plan never pays the extra file read.
#
# v2.29.0: one more sidecar field for PARKING blocking work under the plan that must
# finish first, plus a derived roll-up — recursively, so a fix
# discovered while building a fix nests arbitrarily deep:
#   `parent`         the slug of the plan THIS one must complete before, or null —
#                     UNLIKE `deferred_from` (informational only), existence AND
#                     cycle are validated AT WRITE TIME (a nonexistent parent slug is
#                     a usage error; a cycle — self-parent or transitive, mirroring
#                     the existing `deps[]` cycle refusal — is refused fail-soft, no
#                     write). Written by `init --parent` and `set-parent`; read back
#                     on every `query` plan entry and as a new PARENT
#                     column in `list --parent`. A dangling parent (the target dir
#                     later renamed/removed) is a render-time concern for the
#                     consumer, same pattern `deferred_from` already uses — this
#                     script never re-validates a parent that was valid when set.
#   `subtree <slug>` (v2.29.0; RETIRED in v2.33.0 — now `query --subtree`) every TRANSITIVE
#                     descendant of <slug> via `parent` chains, indented by depth,
#                     each with its effective state and an open/closed verdict
#                     ("open" = effective state NOT in {implemented, superseded}),
#                     plus a trailing open-descendant count. Powers the soft warn
#                     below and the roll-up `/mentor:track`/`/mentor:resume` read.
#   `set <slug> implemented` now prints `WARN: N open descendant(s)` (plus the list,
#                     to stderr) when `<slug>` has open descendants — SOFT only, the
#                     write still succeeds; there is no hard completion gate.
#
#   init <slug> [--group G] [--order N] [--deps a,b] [--deferred] [--priority P]
#        [--category C] [--from S] [--parent S]
#       Create the sidecar as `draft`. Idempotent and never LOWERS an existing
#       state — re-running it on an approved plan keeps it approved. --deps sets the
#       initial dependency slugs (cycle-checked, same as set-deps); --deferred marks
#       the plan a stub born via /mentor:defer (origin: "deferred" — shields it from
#       approve-plan's promotion sweep until `claim`ed); --priority sets the initial
#       impact tier (same closed vocabulary as set-deps' sibling `set-priority`);
#       --category sets the initial work kind (closed vocabulary, sibling
#       `set-category`); --from stamps `deferred_from` — the plan slug this stub was
#       captured out of (unvalidated pass-through, like a `deps` target); --parent
#       stamps the containing plan (existence + cycle validated — see set-parent
#       below; on a validation failure the parent is silently NOT set and every
#       other flag still applies, same as a rejected --deps).
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
#   set-parent <slug> <parent-slug|"">
#       Set <slug>'s `parent` — the plan <slug> must complete before; an EMPTY string
#       clears it back to unset (null), detaching <slug> from its container. UNLIKE
#       set-priority/set-category (closed-vocabulary, hard usage error on a bad
#       value), parent validation is a GRAPH condition the caller could not have
#       known locally — so it mirrors set-deps exactly: existence (<parent-slug> must
#       already be a real plan dir) and cycle (self-parent, or <parent-slug> already
#       a descendant of <slug> — the two-node/N-node case) are BOTH fail-soft,
#       stderr warning, no write. Its own subcommand for the same reason
#       set-priority/set-category are one.
#
#   claim <slug>
#       Clear `origin` — used when a deferred stub (born via /mentor:defer) enters
#       real planning, so approve-plan's promotion sweep can promote it like any plan.
#       Keeps `category`/`priority`/`deferred_from`/`parent` — a claimed stub's
#       triage history AND its containing plan stay intact; a claimed fix must never
#       silently detach from its root.
#
#   tick <slug> <N>
#       Append ✅ to the Nth step line in plan.md's `## Implementation steps` section
#       (idempotent — already-ticked is a no-op) — replaces hand-rolling an Edit to
#       find and mark that exact line, whose placement is load-bearing (a tick on
#       the wrong line reads as the step never having started). No such step at N →
#       fails loud, no write. Needs no jq: unlike every other subcommand here this
#       edits plan.md directly, not the JSON sidecar.
#
#   subtree <slug>
#       Every TRANSITIVE descendant of <slug> via `parent` chains (children,
#       grandchildren, …), indented by depth, each with its EFFECTIVE state and an
#       open/closed verdict (open = effective state NOT in {implemented,
#       superseded}), plus a trailing open-descendant count. Read-only — the ONE
#       query `/mentor:track`'s roll-up, `/mentor:resume`'s drain, and `set …
#       implemented`'s soft warn (below) all build on.
#
#   list [--group G] [--owners] [--parent]
#       One row per plan: ordinal, EFFECTIVE state, slug, group, order — and, with
#       --owners, a 6th OWNER column (the wt-id from the sidecar, "-" when unowned);
#       --parent adds its own column (the sidecar `parent` slug, "-" when absent) —
#       the two flags compose (both columns appear together when both are passed).
#       Grouped, ordered within a group, `superseded` and `unknown` last. The default
#       (no --owners, no --parent) 5-column shape is byte-compatible with pre-2.23.0
#       output — both extra columns are opt-in for exactly that reason. Deliberately
#       carries NO priority column, in any shape: `query` is what every
#       rendering skill reads, and a column here would buy a table nothing consumes
#       at the cost of the byte-compatibility promise above. `--parent` earns its own
#       flag anyway (unlike priority) because the tree it exposes is this
#       plan-state.sh's OWN new completion-tracking concern (`query --subtree`, the soft
#       warn), not something only a rendering skill cares about.
#
#   current [--any]
#       The plan a bare "review the plan" means, scoped to plans OWNED by THIS
#       worktree (or unowned) — a write target must never resolve to a sibling
#       worktree's in-flight draft. --any drops the filter for a deliberate,
#       repo-wide read. Skips superseded. When the answer belongs to a split group
#       it prints the whole group and says so, instead of silently picking one of N
#       children.
#
#   query [select] [filter] [enrich] [output]
#       The ONE filterable read surface (v2.33.0). Repo-wide JSON array by default:
#       one object per plan dir with a plan.md (slug, effective state, group, order,
#       owner, priority, category, deferred_from, parent, deps, origin, live handoffs,
#       ticked/total step counts, goal), plus topic dirs that hold live handoffs but no
#       plan.md yet (state "no plan yet") and the legacy flat handoffs/ dir
#       (topic-less). `priority`/`category`/`deferred_from`/`parent`/`goal` are null on
#       every entry that has none, including both non-plan kinds, so a consumer never
#       has to branch on kind to read them. `goal` is the ONLY one of these NOT stored
#       in the sidecar — it is derived, per call, from the `## Goal` section of an
#       `origin: "deferred"` entry's own plan.md (see lib/state.sh's
#       mentor_plan_goal_line), reflowed to one line and word-boundary-truncated; null
#       for every non-deferred entry. Computed fresh every call — nothing is cached.
#
#       `deps`, `deferred_from` and `parent` all carry the SAME `{slug, missing}` shape
#       (missing true when no such plan dir exists), so a consumer never re-resolves a
#       reference against the array by hand. Consumers still build the parent TREE from
#       `parent` exactly as they build `group` blocks from `group`/`order` — same
#       pattern, no new machinery.
#
#       select   --slug S          just that plan
#                --subtree S       every TRANSITIVE descendant of S via parent chains,
#                                   breadth-first, never S itself
#                --roots           kind plan with no parent
#       filter   --kind --state --open --closed --priority --category --origin --group
#                --parent S --no-parent --deferred-from S --deferred-from-exists
#                --owner W --unowned --has-handoff --deps-missing --match GLOB
#                AND-combined; a comma-separated value ORs within that ONE flag.
#                "open" means effective state NOT in {implemented, superseded} — the
#                same definition the `set … implemented` soft warn uses.
#       enrich   --open-counts     adds `open_descendants` to EVERY entry, computed in
#                                   one pass over the parent graph. This is what makes
#                                   a whole-repo roll-up one process instead of one per
#                                   root.
#       output   --format json|table|slug|count|tsv|tree   (json default, so migrating
#                                   a caller off the retired `overview --json` is a
#                                   rename and nothing else)
#                --format tree     the finished /mentor:track hierarchy, ready to print
#                                   verbatim: glyphs, tier/category columns, depth-first
#                                   ordinals, group blocks, parent nesting, the
#                                   done-with-open-descendants warn and the unparented-fix
#                                   clause. Pair with --open-counts; --fields is ignored.
#                --fields a,b      dot paths (steps.total, parent.slug); tsv/table
#                                   render null as `-`
#                --sort F --limit N
#
#       Two phases, deliberately: a fixed ~3 subprocesses scan every sidecar/plan.md/
#       handoff regardless of plan count, then only the SURVIVORS of the filter pay the
#       per-entry `## Goal` re-read — and only when the projection actually emits it.
#
#   overview --json / subtree <slug>   [RETIRED in v2.33.0]
#       Both were replaced by `query` and now exit 1 naming it, rather than failing as
#       an unknown subcommand: a caller still invoking one has a migration to do, not a
#       typo to find. `overview --json` → `query`; `subtree <slug>` → `query --subtree
#       <slug>`, or `query --roots --open-counts` for every root at once.
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
#   instant <slug> [<step-n>] [--verbose]
#       GO|DEFER|ASK|HOLD|DONE|NO_STEPS|UNRESOLVED — exactly one BARE token on stdout
#       (line 1, always — bare `instant` and `instant --verbose` alike), answering
#       "may dispatch-agents' unattended loop run this plan / this step right now,
#       without a human in the turn?"
#
#       READ-ONLY, and more strictly than `brief`: it never ticks, never writes a
#       sidecar, never touches a marker, and never writes the run record
#       (.mentor/plans/<slug>/instant-run-<ts>.md is the LOOP's artifact — see
#       dispatch-agents). It is called once per step inside a loop whose every other
#       call mutates something, so the one call that only reads has to be provably so.
#
#       The BARE-token shape is `gate`'s, not `policy`/`context`'s prefixed one, and
#       for `gate`'s reason: the loop branches on line 1 by string equality
#       (`[ "$(… instant "$slug" "$n")" = "GO" ]`) once per step, so line 1 carries
#       ONE token and nothing else. Everything a reader wants is behind --verbose.
#
#       THE PRINTED TOKEN IS THE VERDICT, not the exit code — same split `policy`
#       spells out. 0 = the check RAN (any of the six real tokens); 2 = the check
#       could NOT run (UNRESOLVED; never read it as GO, and never as HOLD either —
#       "unknown" is not "unsafe", it is "ask"); 1 = a usage error (unknown slug, no
#       plan.md, <step-n> not a positive integer or out of range) exactly as `brief`
#       and `verify` already treat those.
#
#       NO-REPO FALLBACK, deliberately unlike `gate`/`dir`/`context`: those answer
#       from ~/.claude/mentor/_no-repo because a marker path and a token budget are
#       still meaningful there. A standing grant is not — there is no plans dir, no
#       sidecar and no approve-plan.sh sweep to be safe from — so outside a repo (and
#       with no plans dir, or without jq) this prints UNRESOLVED and exits 2 rather
#       than fabricating a RELEASED-shaped clean answer.
#
#       The tokens, in the order the ladder decides them (first match wins):
#         UNRESOLVED  the environment could not answer: no git repo, no plans dir, no
#                      jq (the sidecar note is unreadable, so the swept-in refusal
#                      below would silently pass — the exact failure it exists to
#                      prevent), or `git rev-parse` cannot yield a worktree id. Exit 2.
#         HOLD        a mechanical blocker no question clears: `gate` reads ARMED or
#                      STALE, the structural scan fails, or a preceding step is
#                      unticked with no forward reference to excuse it. Stop; do not
#                      dispatch, do not tick.
#         ASK         a condition only the USER can clear: the sidecar note says the
#                      approval was swept in by approve-plan.sh; no grant on record;
#                      stored `draft`/`failed`; stored `implemented` with ticks still
#                      open; `context` reads ASK; a non-negated outward action in the
#                      step body; a `Done when:` that is ambiguous AS A COMMAND. Stop
#                      and ask the named question.
#         NO_STEPS    the plan has no `## Implementation steps` step lines at all —
#                      25 of 39 plans in this repo are step-less deferred stubs. There
#                      is nothing to loop over; route to mentor:planning (or, on
#                      origin=deferred, plan-track's claim path). Never HOLD: a stub
#                      is not a failure.
#         DONE        nothing left for the loop here — every step ticked (plan arity),
#                      or this step already carries its ✅ (step arity). On the plan
#                      arity this is ALSO the authorization to run the `## Verification`
#                      remediation: see "the last tick" below.
#         DEFER       (step arity only) dispatch this step now, do NOT tick it — its
#                      own `Done when:` forward-references a LATER step, so ticking on
#                      the evidence available now would be false. Real: plan-tour's
#                      Step 6, "zero unaddressed HIGH findings after Step 7". Re-call
#                      `instant <slug> N` once `defer_until=` is ticked.
#         GO          every mechanical condition holds. Dispatch, verify, tick.
#
#       WHY `gate` STALE IS A HARD STOP AND ARMED_ELSEWHERE IS NOT. This is the whole
#       point of the subcommand, so it is spelled out rather than left to the caller:
#       mentor_plan_tick_step (lib/state.sh) ends in `mv`, which bumps plan.md's
#       mtime, and mentor_newly_planned is `find -newer <marker>` and IS
#       approve-plan.sh's promotion set. approve-plan.sh resolves THIS worktree's
#       own marker with NO staleness test — so any own/legacy marker FILE still on
#       disk, live or stale, makes every plan this loop ticks a promotion candidate,
#       manufacturing the very "swept in by approve-plan.sh… not necessarily reviewed"
#       case plan-track's `approved` row carries a mandatory confirm for. A stale
#       marker is the WORSE of the two: being older, its `find -newer` set is larger.
#       ARMED_ELSEWHERE is different in kind, not in degree: no own or legacy marker
#       exists, so approve-plan.sh run here resolves no marker and sweeps nothing, and
#       the sibling's own run goes strict, where strict mode excludes exactly the
#       unowned and foreign-owned candidates a tick here could produce. It also does
#       not block a write here at all (see `gate` above). So ARMED_ELSEWHERE proceeds
#       as RELEASED does — it is only reported, in `gate=`.
#
#       WHY THE GRANT READS THE STORED STATE, NEVER THE EFFECTIVE ONE. Ticking the
#       LAST step makes mentor_plan_tick_state return `implemented` (rank 4), which
#       outranks both `in_progress` (3) and `approved` (2), so
#       mentor_plan_effective_state flips to `implemented` the instant the loop
#       finishes — and a grant keyed on the effective state would become unsatisfiable
#       at exactly the moment the `## Verification` remediation needs it. So the grant
#       reads mentor_plan_state_stored, which a tick cannot move (tick_step writes
#       plan.md only, never the sidecar), and the tick counts are used ONLY to pick
#       the entry step and to distinguish DONE from GO. The effective state is still
#       reported, in `effective=`, and is never decisive.
#
#       --verbose is strictly additive and the per-token field contract below is
#       NORMATIVE — exactly these fields, in this order, nothing else. Every token
#       except UNRESOLVED carries the PLAN BLOCK; step arity appends the STEP BLOCK;
#       NOTE: lines come last.
#
#         PLAN BLOCK (every token but UNRESOLVED)
#           reason=<kebab-case cause>   slug=   plan_dir=
#           stored=<state|->            effective=<state|unknown>
#           ticked=<n>  total=<n>       next_step=<n|->
#           gate=<ARMED|STALE|ARMED_ELSEWHERE|RELEASED>
#           note_swept=<0|1>            structure=<OK|FAIL[:reason]>
#           context=<OK|WARN|HANDOFF|ASK|UNKNOWN>
#         STEP BLOCK (only when <step-n> was given)
#           step=<n>  step_ticked=<0|1>
#           header_line=<n>  header_crc=<cksum>  header=<the step line, verbatim>
#           body=<first>-<last>         body_glue_from=<n|->
#           prev_unticked=<n,n|->       prev_deferred=<n,n|->
#           dw_lines=<n>  dw_code_spans=<n>
#           dw_ellipsis=<0|1>  dw_unclosed_span=<0|1>
#           dw_inverted=<0|1>  dw_slash_only=<0|1>
#           dw_forward_refs=<n,n|->     defer_until=<n|->
#           outward=<kind@line,…|->     outward_negated=<kind@line,…|->
#           outward_prose=<kind@line,…|->
#         UNRESOLVED
#           reason=<no-repo|no-plans-dir|no-jq|no-worktree-id> and nothing else —
#           there is no plan to report fields about.
#         NOTE: lines (step arity + --verbose only, AFTER the fields)
#           NOTE: inputs-missing=<path,…>       — paths named in `Inputs:` that do not
#                                                  exist. REPORT ONLY, never a token:
#                                                  measured 29/92 absent, of which 2
#                                                  were real drift, and 24 of 68 steps
#                                                  name no path at all.
#           NOTE: critical-files-unlisted=<path,…> — `Inputs:` paths absent from
#                                                  `## Critical files`. REPORT ONLY:
#                                                  25 of 39 plans have no such section,
#                                                  it was never specified as a write
#                                                  allowlist (planning's Content spec),
#                                                  and plan-review already treats a
#                                                  mismatch as a routine finding.
#                                                  Emitted only when the section exists.
#
#       WHAT THIS SUBCOMMAND DOES NOT DECIDE. It never classifies a `Done when:` into
#       "runnable / needs a verifier / needs a human". Measured across 72 parseable
#       blocks in this repo, only 14 (19%) are settled by a bounded command alone; 19
#       carry a command AND a prose conjunct that still decides it; 33 are judgment
#       only. A lexical test cannot separate those, and a boolean "has a runnable
#       check" gate would auto-tick 19 steps on evidence that proves a fraction of
#       them. So the script reports the five ambiguity FACTS above (dw_ellipsis,
#       dw_unclosed_span, dw_inverted, dw_slash_only, dw_code_spans) — each one
#       mechanically decidable — refuses outright when any ambiguity fact fires, and
#       leaves the three-way route to the model, per dispatch-agents' "Unattended
#       continuation" section. Tiebreak, the loop's own: unsure a condition holds →
#       it does not hold. (Deliberately NOT verifier-contract.md's stamp tiebreaks,
#       which resolve the other way, toward the user's verdict.)
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
       [--category C] [--from S] [--parent S]
                                         create the sidecar as draft (idempotent)
  start <slug> [any init flag]          ensure-dir + init + claim in ONE call; echoes the
                                         plan.md path. The plan-write path — replaces the
                                         three-call sequence and its re-derive footguns
  set <slug> <state> [--note "…"]       state: draft|approved|in_progress|implemented|failed|superseded;
                                         `implemented` with open descendants prints a soft
                                         WARN (the write still succeeds — see query --subtree)
  set-deps <slug> a,b                   replace deps wholesale (cycle-checked, fail-soft)
  set-priority <slug> <P>               impact tier: critical|high|medium|low|noise ("" clears)
  set-category <slug> <C>               work kind: feature|fix|refactor|docs|tooling ("" clears)
  set-parent <slug> <P>                 set the containing plan (existence + cycle checked,
                                         fail-soft — mirrors set-deps; "" clears)
  claim <slug>                          clear origin (a deferred stub enters real planning);
                                         keeps category/priority/deferred_from/parent
  tick <slug> <N>                       append ✅ to step N in plan.md (idempotent, fails loud)
  verify <slug>                         plan.md structural checks (fence balance, table pipe-count,
                                         step bodies each carrying a Done when:, Rev-note order,
                                         stray ✅ / ### inside the steps section) + a folded CONTEXT
                                         read, as CHECK: lines; exit 1 iff a GATING check fails
                                         (Rev-order, context, stray ✅ and ### are informational)
  list [--group G] [--owners] [--parent]
                                         every plan with its effective state (--owners adds OWNER,
                                         --parent adds PARENT; both compose)
  current [--any]                       the current plan, owned-by-this-worktree scoped (group-aware);
                                         --any for a deliberate repo-wide read
  query [select] [filter] [enrich] [output]
                                         the ONE filterable read surface (replaced the retired
                                         `overview --json` and `subtree`). Repo-wide JSON by default:
                                         plans + priority/category/parent/deferred_from
                                         (the last two as `{slug, missing}`, like deps) +
                                         live handoffs + step counts + goal, plus
                                         no-plan topics and legacy handoffs.
    select   --slug S | --subtree S | --roots
    filter   --kind K --state S --open --closed --priority P --category C --origin O
             --group G --parent S --no-parent --deferred-from S --deferred-from-exists
             --owner W --unowned --has-handoff --deps-missing --match GLOB
             (AND-combined; a comma-separated value ORs within that one flag)
    enrich   --open-counts        adds `open_descendants` to every entry, one pass for all
    output   --format json|table|slug|count|tsv|tree   (default json; `tree` renders
                                         the finished /mentor:track hierarchy — pair it
                                         with --open-counts)
             --fields a,b         dot paths, e.g. steps.total, parent.slug
             --sort F --limit N
  brief <slug> [--step N]               scope-complete envelope for one plan: title, CONTEXT
                                         goal line, whole Out of scope section, every step's
                                         title line with tick state, the verbatim body of step
                                         N (when given), and the Verification topic titles;
                                         read-only, never ticks — see `tick`
  sweep <pattern> [--roots policy|plans|repo] [--ignore-case]
                                        the ONE portable search over mentor's own state.
                                         Prints `SWEEP: roots=N files=N hits=N` FIRST, then
                                         one `path:line:text` per hit. Exits like grep:
                                         0 hits found / 1 files read but no match /
                                         2 NOTHING-SEARCHED (no root existed) or a usage
                                         error. roots: policy = this worktree's CLAUDE.md +
                                         .claude/ + the main repo's .mentor/plans (default);
                                         plans = that plans dir alone; repo = the whole
                                         worktree minus .git/. find walks so grep never
                                         applies .gitignore — gitignored .mentor/ IS reached
  policy                                the pre-dispatch preflight, one call, no skill load:
                                         POLICY: SET|NONE|FOUND|UNRESOLVED + CONTRACT:
                                         active|MISSING (can dispatch-contract.sh inject?).
                                         SET means .mentor/config.json recorded a dispatch
                                         preference (agents|solo|verify-only) — honor it and
                                         ask NOTHING; the other three answer "is a standing
                                         no-subagents instruction on record?" The printed
                                         token is the verdict; exit 2 iff the check
                                         could not run
  instant <slug> [<step-n>]             may the unattended loop run this plan/step now?
                                         GO|DEFER|ASK|HOLD|DONE|NO_STEPS|UNRESOLVED — one
                                         BARE token on stdout (line 1, always), read-only:
                                         never ticks, never writes. --verbose adds a
                                         normative per-token field set (see the instant doc
                                         comment above). The printed token is the verdict;
                                         exit 2 iff the check could not run. Consumed only
                                         by mentor:dispatch-agents' per-step loop
  context                               CONTEXT: ASK|HANDOFF|WARN|OK|UNKNOWN (~N tokens)
  dir [--plans]                         the repo-scoped mentor dir (or its plans dir)
  gate [--verbose]                      ARMED|STALE|ARMED_ELSEWHERE|RELEASED — read-only marker
                                         status for THIS worktree (--verbose adds per-token fields;
                                         see the gate doc comment above for the exact contract)
  ensure-dir <path>                     mkdir it + chmod 700 the whole path; echoes it
  relocate <src-plan-dir>                copy a plan from a DIFFERENT repo's
                                         .mentor/plans/<slug> into THIS repo (run
                                         from the destination repo) and re-own it
                                         here; never deletes the source; warns (does
                                         NOT copy) any children left in the source repo
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
  # as `init` — preserves whatever state/category/priority/deps/deferred_from/parent
  # the copy carried over (the `cp -R` above already copied `.state.json` byte for
  # byte), only overwriting owner/owner_session.
  rl_existing="$(mentor_plan_state_stored "$rl_dst")"
  rl_write_args=(--state "${rl_existing:-draft}" --note "$(mentor_plan_state_field "$rl_dst" note)")
  if [ -n "$rl_wt_id" ]; then
    rl_write_args+=(--owner "$rl_wt_id" --owner-session "${CLAUDE_CODE_SESSION_ID:-}")
  fi
  mentor_plan_state_write "$rl_dst" "${rl_write_args[@]}"
  echo "[mentor plan-state] ${rl_slug}: relocated from ${rl_src_canon} → ${rl_dst}; re-owned to this worktree ($(mentor_plan_effective_state "$rl_dst"))."
  echo "[mentor plan-state] source NOT deleted — remove ${rl_src_canon} yourself once you've confirmed the copy."
  # Pre-existing bug fixed in passing (discovered while verifying the v2.29.0
  # children-warning added right below this): under this file's `set -euo pipefail`,
  # `grep` finding ZERO matches — the COMMON case, whenever plan.md has no
  # "Suggested first steps" section or none of its lines look like a path — exits
  # 1, and `pipefail` propagates that through `head` to this bare assignment, which
  # aborts the whole `relocate` under `set -e` before ever reaching the two
  # WARNINGs (or the children check) below. Same class of pitfall the `verify`
  # subcommand's own comment already documents and guards with `|| true` — applying
  # the identical guard here, since this dead-ended `relocate` in exactly the case
  # this line exists to warn about being ABSENT (a plan with nothing stale to flag).
  rl_stale_hits="$(awk '/^## Suggested first steps/{f=1;next} /^## /{f=0} f' "${rl_dst}/plan.md" 2>/dev/null \
    | grep -noE '[[:alnum:]_.-]+/[[:alnum:]/_.-]+' | head -20 || true)"
  if [ -n "$rl_stale_hits" ]; then
    echo "[mentor plan-state] WARNING: plan.md's Suggested first steps still names repo-relative paths that may be stale after this move:" >&2
    printf '%s\n' "$rl_stale_hits" | sed 's/^/  /' >&2
  fi
  echo "[mentor plan-state] WARNING: if the source repo's plan-gate marker is still armed for this plan, its gate will not protect edits made back there — check with 'plan-state.sh gate --verbose' in the source repo." >&2
  # v2.29.0: `relocate` copies exactly ONE plan dir — it never walks the source
  # repo's `parent` chains, so a fix parked under the slug being moved (parent ==
  # rl_slug) is left behind at rl_src_parent, not brought along. Silently leaving
  # that unsaid would read as "the whole subtree moved" when only the one plan did
  # — surface it the same way the stale-paths check above does (informational,
  # never fails the relocate). rl_src_parent is the SOURCE plans dir (set above,
  # dirname of rl_src_canon) — not this plan's own `parent` field.
  rl_children="$(for rl_sib in "${rl_src_parent}"/*/; do
    [ -d "$rl_sib" ] || continue
    rl_sib="${rl_sib%/}"
    [ "$(basename "$rl_sib")" = "$rl_slug" ] && continue
    if [ "$(mentor_plan_parent "$rl_sib")" = "$rl_slug" ]; then basename "$rl_sib"; fi
  done; true)"   # trailing `true`: under `set -e` a bare assignment propagates the
                 # substitution's exit status, and the loop's LAST iteration can
                 # legitimately end on the false branch of the `if` above — `true`
                 # keeps that from aborting the whole script (same class of pitfall
                 # this file's own `tick_result="$(mentor_plan_tick_step …)"` comment
                 # already calls out, just on a `for` loop instead of a function call).
  if [ -n "$rl_children" ]; then
    echo "[mentor plan-state] WARNING: ${rl_slug} has children still only in the SOURCE repo (parent = ${rl_slug}, at ${rl_src_parent}) — relocate does NOT bring a subtree, only the one plan dir. Relocate each one separately if you want the whole subtree here:" >&2
    printf '%s\n' "$rl_children" | sed 's/^/  /' >&2
  fi
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

# --- sweep <pattern> [--roots policy|plans|repo] [--ignore-case]: the ONE portable
# search over mentor's own state. Deliberately an EARLY handler, alongside gate/dir/
# context: it must run BEFORE the repo-root and plans-dir guards below, because a repo
# with a CLAUDE.md but no .mentor/plans yet is a perfectly good `policy` sweep, and the
# plans-dir guard would exit 0 with "nothing planned" — the exact silent-clean answer
# this subcommand exists to make impossible. Outside a git repo it still answers, with
# the NOTHING-SEARCHED verdict rather than a false zero.
#
# The mechanism (find walks, grep only reads the list it is handed), why the GNU/ripgrep
# no-ignore flag and its ugrep-only cousin are both wrong, and the measured hit matrix live
# `sweep` section of lib/state.sh — read it there before changing anything here.
if [ "$sub" = "sweep" ]; then
  sw_pattern=""; sw_set="policy"; sw_icase=""; sw_have_pattern=0; sw_endopts=0
  while [ "$#" -gt 0 ]; do
    if [ "$sw_endopts" -eq 0 ]; then
      case "$1" in
        --roots)
          if [ "$#" -lt 2 ]; then
            echo "[mentor plan-state] sweep --roots needs a value: policy|plans|repo" >&2
            exit 2
          fi
          sw_set="$2"; shift 2; continue ;;
        --roots=*) sw_set="${1#--roots=}"; shift; continue ;;
        --ignore-case) sw_icase=1; shift; continue ;;
        # `--` ends option parsing, so a PATTERN beginning with a dash is still reachable
        # (`sweep -- -not-a-flag`) instead of being rejected as an unknown flag.
        --) sw_endopts=1; shift; continue ;;
        -?*)
          echo "[mentor plan-state] sweep: unknown flag '${1}'." >&2
          echo "  usage: sweep <pattern> [--roots policy|plans|repo] [--ignore-case]" >&2
          exit 2 ;;
      esac
    fi
    if [ "$sw_have_pattern" -eq 1 ]; then
      echo "[mentor plan-state] sweep takes ONE pattern; got an extra argument '${1}'." >&2
      echo "  quote a multi-word pattern: sweep 'no subagents' --ignore-case" >&2
      exit 2
    fi
    sw_pattern="$1"; sw_have_pattern=1; shift
  done
  case "$sw_set" in
    policy|plans|repo) ;;
    *)
      echo "[mentor plan-state] sweep: unknown root set '${sw_set}' — use policy|plans|repo." >&2
      echo "  policy  this worktree's CLAUDE.md + .claude/ + the main repo's .mentor/plans" >&2
      echo "  plans   the main repo's .mentor/plans" >&2
      echo "  repo    the whole worktree, minus .git/ (.mentor/ included)" >&2
      exit 2 ;;
  esac
  if [ "$sw_have_pattern" -eq 0 ] || [ -z "$sw_pattern" ]; then
    echo "[mentor plan-state] sweep needs a non-empty pattern." >&2
    echo "  usage: sweep <pattern> [--roots policy|plans|repo] [--ignore-case]" >&2
    exit 2
  fi
  sw_out="$(mentor_sweep "$(pwd)" "$sw_set" "$sw_pattern" "$sw_icase")"
  sw_roots=0; sw_files=0; sw_hits=0
  read -r sw_roots sw_files sw_hits <<<"$(printf '%s\n' "$sw_out" | head -1)" || true
  # The accounting line leads, always. On a broken sweep there are no hits at all, so this
  # line IS the entire output; on a long result set it must not scroll away from the
  # reader who has to judge whether a zero is trustworthy.
  echo "SWEEP: roots=${sw_roots:-0} files=${sw_files:-0} hits=${sw_hits:-0}"
  if [ "${sw_files:-0}" -eq 0 ]; then
    echo "SWEEP: NOTHING-SEARCHED — no root existed; this result is not evidence"
    exit 2
  fi
  if [ "${sw_hits:-0}" -gt 0 ]; then
    printf '%s\n' "$sw_out" | tail -n +2
    exit 0
  fi
  exit 1
fi

# --- policy: the ONE pre-dispatch preflight (v2.34.0) -------------------------
# Answers, in one call, both questions a surface must settle before its first
# Agent/Task dispatch — so no skill has to load mentor:dispatch-agents (~16k tokens)
# just to reach them:
#
#   POLICY:    SET first — a `dispatch` value in .mentor/config.json is the user's own
#              answer, recorded once, and it ends the question outright. Otherwise: is a
#              STANDING no-subagents instruction recorded anywhere durable —
#              this worktree's CLAUDE.md, its .claude/ tree, or the main repo's
#              .mentor/plans handoff notes? Runs exactly the sweep the prescription
#              always meant (`--roots policy --ignore-case`), so gitignored .mentor/
#              is really read and a search that read NOTHING can never pass for a
#              clean result.
#   CONTRACT:  can hooks/dispatch-contract.sh actually inject the standing "Deliver
#              before idling" block into this dispatch? That hook fail-softs SILENTLY
#              (no jq, missing/empty contract file), and since v2.34.0 no skill pastes
#              the block by hand any more — so a silent fail-soft would ship raw agent
#              prompts with nothing anywhere saying so. This line is that alarm.
#
# THE PRINTED TOKEN IS THE VERDICT, not the exit code. `sweep` needs its grep-shaped
# codes because a bare hit count cannot distinguish "no match" from "read nothing";
# here that distinction is spelled out in words (NONE / FOUND / UNRESOLVED), which
# leaves the exit code free to mean the one thing a caller actually branches on:
#   0  the check RAN — read POLICY: NONE (dispatch as designed) or FOUND (stop, ask)
#   2  the check could NOT run — UNRESOLVED; never read this as "no policy"
# CONTRACT: never moves the exit code. A missing contract is not a reason to withhold
# the policy answer the caller came for; it is a reason to print a loud second line.
if [ "$sub" = "policy" ]; then
  if [ "$#" -gt 0 ]; then
    echo "[mentor plan-state] policy takes no arguments; got '${1}'." >&2
    exit 2
  fi

  # Contract liveness, resolved first so it is reportable on every branch below.
  pol_txt="${hook_dir}/dispatch-contract.txt"
  pol_sh="${hook_dir}/dispatch-contract.sh"
  if ! command -v jq >/dev/null 2>&1; then
    pol_contract="MISSING — jq is absent, so dispatch-contract.sh fail-softs and injects nothing. Paste the contents of hooks/dispatch-contract.txt into each dispatch prompt by hand until jq is installed."
  elif [ ! -s "$pol_txt" ]; then
    pol_contract="MISSING — hooks/dispatch-contract.txt is absent or empty; nothing can be injected."
  elif [ -z "$(head -n 1 "$pol_txt" 2>/dev/null || true)" ]; then
    pol_contract="MISSING — hooks/dispatch-contract.txt has no first line, so the hook's idempotence sentinel is unreadable."
  elif [ ! -r "$pol_sh" ]; then
    pol_contract="MISSING — hooks/dispatch-contract.sh is not readable."
  else
    pol_contract="active — dispatch prompts are injected automatically; do NOT paste the block by hand."
  fi

  # --- a recorded preference ends the question -------------------------------
  # Without this branch the sweep below is re-run at every dispatch surface, in every
  # session, forever — and since no file sweep can see an instruction that lives in the
  # session's own system prompt, a NONE verdict never stopped the model asking anyway.
  # Measured before this existed: 46 mentor sessions asked the user where the work should
  # run, under 16 different question headers, none of the answers outliving its session.
  # One recorded value answers all seven call sites at once, for good.
  pol_repo="$(mentor_repo_root "$(pwd)")"
  pol_pref=""
  if [ -n "$pol_repo" ]; then pol_pref="$(mentor_get_dispatch "$pol_repo")"; fi
  case "$pol_pref" in
    agents)
      echo "POLICY: SET (dispatch=agents) — the user recorded that mentor should route per dispatch-agents' \"Where dispatch pays\" test. Do NOT ask; route and dispatch as the skill prescribes."
      echo "CONTRACT: ${pol_contract}"
      exit 0
      ;;
    solo)
      echo "POLICY: SET (dispatch=solo) — the user recorded that implementation AND verification stay in the main thread here. Do NOT ask. Honor it, and disclose in the report that the plan carries no independent verification (dispatch-agents, \"A substitution is disclosed as a substitution\"). One user-ruled exception: an instant run's per-step loop still dispatches its one fresh prose-criterion verifier, disclosed in the run record (dispatch-agents, \"Unattended continuation\")."
      echo "CONTRACT: ${pol_contract}"
      exit 0
      ;;
    verify-only)
      echo "POLICY: SET (dispatch=verify-only) — the user recorded that implementation stays in the main thread and verification still dispatches. Do NOT ask; implement in-thread, then dispatch the Verification topics normally."
      echo "CONTRACT: ${pol_contract}"
      exit 0
      ;;
    "") ;;
    *)
      echo "POLICY: UNRESOLVED (dispatch=\"${pol_pref}\") — .mentor/config.json carries a \"dispatch\" value that is not agents|solo|verify-only, so what the user wanted cannot be read off it. Treat the question as open; fix the value with /mentor:mode agents|solo|verify-only."
      echo "CONTRACT: ${pol_contract}"
      exit 2
      ;;
  esac

  # No recorded preference — look for a standing instruction in the durable locations.
  # ERE, because one literal ('no subagents') matched almost nothing people actually
  # write: the measured real-world wording was "Default to solo in-thread review over
  # dispatching background agents", which that literal missed completely.
  pol_out="$(mentor_sweep "$(pwd)" policy 'no[- ]?sub-?agents|without sub-?agents|(do not|do NOT|don'"'"'t|never|not to) (use|call|dispatch|spawn) [^.]{0,24}(sub-?agents?|agent[- ]?tool|background agents)|solo in-?thread|background (agents|teammates)|no fan-?out' 1 1)"
  pol_roots=0; pol_files=0; pol_hits=0
  read -r pol_roots pol_files pol_hits <<<"$(printf '%s\n' "$pol_out" | head -1)" || true

  # `sweep` maps files=0 to NOTHING-SEARCHED because its roots are caller-chosen and its
  # pattern arbitrary — a zero there really can mean the caller aimed at nothing. THIS
  # check cannot: its root set is fixed and exhaustive (this worktree's CLAUDE.md, its
  # .claude/ tree, the main repo's .mentor/plans), and each root is listed only when it
  # exists. So roots=0 is not a failed search — it is the positive finding that NONE of
  # the three places a standing instruction can live exists in this repo, which is the
  # ordinary state of a repo with no CLAUDE.md. Reporting that as UNRESOLVED would stop
  # every dispatch in every such repo to ask a question with no possible answer.
  #
  # roots>0 with files=0 is the genuinely odd one and keeps the loud verdict: a root that
  # exists but yielded no readable file is as consistent with an unreadable directory
  # (find swallows the error) as with an empty one, and that is exactly the ambiguity
  # this whole subcommand refuses to launder into a clean result.
  if [ "${pol_roots:-0}" -eq 0 ]; then
    echo "POLICY: NONE (roots=0) — none of the durable locations exists here (CLAUDE.md, .claude/, .mentor/plans), so there is nowhere a standing instruction could be recorded."
    echo "CONTRACT: ${pol_contract}"
    exit 0
  fi
  if [ "${pol_files:-0}" -eq 0 ]; then
    echo "POLICY: UNRESOLVED (roots=${pol_roots} files=0) — the durable locations exist but not one readable file was searched. Treat the question as open; this is NOT evidence that no policy exists."
    echo "CONTRACT: ${pol_contract}"
    exit 2
  fi
  if [ "${pol_hits:-0}" -gt 0 ]; then
    echo "POLICY: FOUND (files=${pol_files} hits=${pol_hits}) — a standing no-subagents instruction is recorded. Ask the user ONCE (see mentor:dispatch-agents, \"Standing no-subagents policy\") and record the answer with set-mode.sh so this never has to be asked again."
    echo "CONTRACT: ${pol_contract}"
    # Evidence is CAPPED. A repo that has lived under such a policy accumulates the
    # phrase in every handoff note it ever wrote — 68 hits measured in one real repo —
    # and the verdict is already in the line above, so printing them all buys nothing
    # and costs the orchestrator context on a preflight that runs before every fan-out.
    # A few concrete lines are what makes the verdict checkable; the rest is volume.
    printf '%s\n' "$pol_out" | tail -n +2 | head -5
    if [ "${pol_hits:-0}" -gt 5 ]; then
      echo "  … ${pol_hits} hits total; the 5 above are a sample. Re-run with \`sweep\` if you need the full list."
    fi
    exit 0
  fi
  echo "POLICY: NONE (files=${pol_files}) — no standing no-subagents instruction recorded; dispatch as designed."
  echo "CONTRACT: ${pol_contract}"
  exit 0
fi

# --- instant <slug> [<step-n>] [--verbose]: may the unattended loop run this now? ---
# The full token/field/exit contract lives in the `instant` doc block near the top of
# this file — read it before changing anything here. An EARLY handler (like policy/
# gate/context) so it must derive repo_root/plans_dir itself; require_slug and the
# shared guards below it are not defined yet when this block runs.
if [ "$sub" = "instant" ]; then
  in_slug=""; in_step=""; in_verbose=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verbose) in_verbose=1 ;;
      -*) echo "[mentor plan-state] instant: unknown flag '${1}'." >&2; usage >&2; exit 1 ;;
      *)
        if [ -z "$in_slug" ]; then in_slug="$1"
        elif [ -z "$in_step" ]; then in_step="$1"
        else
          echo "[mentor plan-state] instant: unexpected argument '${1}'." >&2
          usage >&2; exit 1
        fi ;;
    esac
    shift
  done
  if [ -z "$in_slug" ]; then
    echo "[mentor plan-state] instant: a <slug> is required." >&2
    usage >&2; exit 1
  fi
  if [ -n "$in_step" ]; then
    case "$in_step" in
      *[!0-9]*|0)
        echo "[mentor plan-state] instant: <step-n> must be a positive integer; got '${in_step}'." >&2
        exit 1 ;;
    esac
  fi

  # E1 — environment. UNRESOLVED (exit 2) carries reason= alone: there is no plan to
  # report fields about. Deliberately NO _no-repo fallback — see the doc block.
  in_repo="$(mentor_repo_root "$(pwd)")"
  if [ -z "$in_repo" ]; then
    echo UNRESOLVED
    [ "$in_verbose" -eq 1 ] && echo "reason=no-repo"
    exit 2
  fi
  in_plans="$(mentor_plans_dir "$in_repo")"
  if [ -z "$in_plans" ] || [ ! -d "$in_plans" ]; then
    echo UNRESOLVED
    [ "$in_verbose" -eq 1 ] && echo "reason=no-plans-dir"
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo UNRESOLVED
    [ "$in_verbose" -eq 1 ] && echo "reason=no-jq"
    exit 2
  fi
  in_wt="$(mentor_worktree_id "$(pwd)")"
  if [ -z "$in_wt" ]; then
    echo UNRESOLVED
    [ "$in_verbose" -eq 1 ] && echo "reason=no-worktree-id"
    exit 2
  fi

  # E0 disk half — unknown slug / missing plan.md are usage errors (exit 1), matching
  # brief/verify. Inlined require_slug: that function is defined below this handler.
  in_dir="${in_plans}/${in_slug}"
  if [ ! -d "$in_dir" ]; then
    echo "[mentor plan-state] No such plan: ${in_dir}" >&2
    echo "Run 'plan-state.sh list' to see the slugs that exist." >&2
    exit 1
  fi
  in_md="${in_dir}/plan.md"
  if [ ! -f "$in_md" ]; then
    echo "[mentor plan-state] instant: no plan.md at ${in_md}." >&2
    exit 1
  fi

  # --- gather every fact first, decide the token second: --verbose must print the
  # full PLAN BLOCK whatever the verdict, so nothing here can short-circuit. `|| true`
  # on every substitution — a legitimate zero-match exits non-zero under this file's
  # `set -euo pipefail` and would abort before line 1 prints (verify documents the
  # same trap).
  in_scan="$(mentor_plan_step_scan "$in_md" || true)"
  in_total="$(printf '%s\n' "$in_scan" | awk -F'\t' '$1 == "TOTAL" { print $2 }' || true)"
  in_total="${in_total:-0}"
  in_ticked="$(printf '%s\n' "$in_scan" | awk -F'\t' '$1 == "STEP" && $5 == 1 { n++ } END { print n + 0 }' || true)"
  in_next="$(printf '%s\n' "$in_scan" | awk -F'\t' '$1 == "STEP" && $5 == 0 { print $2; exit }' || true)"

  if [ -n "$in_step" ] && [ "$in_step" -gt "$in_total" ]; then
    echo "[mentor plan-state] instant: step ${in_step} is out of range (plan has ${in_total} step(s))." >&2
    exit 1
  fi

  # Gate token, inline with the same helpers `gate` uses — never `bash "$0" gate`,
  # which would fork and re-derive the repo root once per loop step.
  in_own="$(mentor_plan_marker "$in_plans" "$in_wt")"
  in_legacy="$(mentor_plan_marker "$in_plans" "")"
  in_own_exists=0; in_own_live=0
  [ -e "$in_own" ] && in_own_exists=1
  if [ "$in_own_exists" -eq 1 ] && ! mentor_marker_stale "$in_own"; then in_own_live=1; fi
  in_leg_exists=0; in_leg_live=0
  if [ -n "$in_wt" ]; then
    [ -e "$in_legacy" ] && in_leg_exists=1
    if [ "$in_leg_exists" -eq 1 ] && ! mentor_marker_stale "$in_legacy"; then in_leg_live=1; fi
  fi
  in_gate=RELEASED
  if [ "$in_own_live" -eq 1 ] || [ "$in_leg_live" -eq 1 ]; then in_gate=ARMED
  elif [ "$in_own_exists" -eq 1 ] || [ "$in_leg_exists" -eq 1 ]; then in_gate=STALE
  elif [ -n "$(mentor_live_markers "$in_plans")" ]; then in_gate=ARMED_ELSEWHERE
  fi

  in_stored="$(mentor_plan_state_stored "$in_dir")"
  in_eff="$(mentor_plan_effective_state "$in_dir")"
  in_note="$(mentor_plan_state_field "$in_dir" note)"
  in_swept=0
  case "$in_note" in *"swept in by approve-plan.sh"*) in_swept=1 ;; esac

  # Structure — the same two facts that GATE verify's exit code: every step body
  # carries a Done when:, and fences balance. The informational facts (stray ✅,
  # ### glue) are verify's to report, not a stop here.
  in_fences="$(grep -c '^```' "$in_md" || true)"
  in_nodw_line="$(printf '%s\n' "$in_scan" | awk -F'\t' '$1 == "STEP" && $6 == 0 { print $3; exit }' || true)"
  in_structure=OK
  if [ -n "$in_nodw_line" ]; then in_structure="FAIL:nodw@${in_nodw_line}"
  elif [ $(( ${in_fences:-0} % 2 )) -ne 0 ]; then in_structure="FAIL:fences"
  fi

  in_ctx_raw="$(mentor_context_verdict "$in_repo" "$(pwd)" || true)"
  in_ctx="${in_ctx_raw%% *}"
  [ -n "$in_ctx" ] || in_ctx=UNKNOWN

  # Per-step Done-when / outward facts, one awk pass. DWF rows carry every step's
  # conjunct facts (the ordering excuse in E10 needs the predecessors', not just the
  # target's); OUT/OUTN/OUTP and INP rows are scoped to the target step's body. The
  # conjunct runs from the `Done when:` line to the end of the body, stopping early
  # at the next field label. Forward refs keep only ordinals > the step's own — that
  # single filter is what silences the backward/self-referring dispatch-group headers
  # (`after Steps 2-5`) without giving up the real forward reference.
  in_facts="$(awk -v pat="$MENTOR_STEP_LINE_PATTERN" \
                  -v cmdpat="$MENTOR_OUTWARD_CMD_PATTERN" \
                  -v prosepat="$MENTOR_OUTWARD_PROSE_PATTERN" \
                  -v negpat="$MENTOR_NEGATION_CUE_PATTERN" \
                  -v target="${in_step:-0}" '
    function flushdw() {
      if (ord > 0)
        printf "DWF\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", ord, dwl, spans, ell, uncl, inv, \
               (spans > 0 && slashy == spans) ? 1 : 0, (refs == "") ? "-" : refs
    }
    /^##[[:space:]]/ {
      h = tolower($0)
      if (insec) flushdw()
      ord = (insec) ? 0 : ord
      insec = (h ~ /^##[[:space:]]+implementation[[:space:]]+steps/) ? 1 : 0
      next
    }
    !insec { next }
    $0 ~ pat {
      flushdw()
      ord++; indw = 0; ininp = 0
      dwl = 0; spans = 0; ell = 0; uncl = 0; inv = 0; slashy = 0; refs = ""
      next
    }
    {
      if (target > 0 && ord == target) {
        low = tolower($0)
        neg = (low ~ negpat) ? 1 : 0
        rest = $0
        while (match(rest, cmdpat)) {
          m = substr(rest, RSTART, RLENGTH)
          gsub(/[[:space:]]+/, "-", m)
          if (neg) printf "OUTN\t%s@%d\n", m, NR
          else     printf "OUT\t%s@%d\n",  m, NR
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (match(low, prosepat)) {
          pm = substr(low, RSTART, RLENGTH)
          gsub(/[[:space:]]+/, "-", pm)
          printf "OUTP\t%s@%d\n", pm, NR
        }
        if ($0 ~ /^[[:space:]]*[-*]?[[:space:]]*[*]{0,2}Inputs[*]{0,2}:/) ininp = 1
        else if ($0 ~ /^[[:space:]]*[-*]?[[:space:]]*[*]{0,2}(Goal|Prompt sketch|Dispatch|Role|Done when)[*]{0,2}:/) ininp = 0
        if (ininp) {
          r2 = $0
          while (match(r2, /`[^`]+`/)) {
            sp = substr(r2, RSTART + 1, RLENGTH - 2)
            if (sp ~ /\// && sp !~ /[[:space:]{*?]/) printf "INP\t%s\n", sp
            r2 = substr(r2, RSTART + RLENGTH)
          }
        }
      }
      if (indw && $0 ~ /^[[:space:]]*[-*]?[[:space:]]*[*]{0,2}(Goal|Inputs|Prompt sketch|Dispatch|Role)[*]{0,2}:/) indw = 0
      if (!indw && $0 ~ /[Dd]one when:/) indw = 1
      if (indw) {
        dwl++
        c = $0
        nb = gsub(/`/, "`", c)
        spans += int(nb / 2)
        if (nb % 2 == 1) uncl = 1
        if ($0 ~ /`[^`]*(\.\.\.|…)[^`]*`/) ell = 1
        if ($0 ~ /FAILS|must[[:space:]]+fail|expected[[:space:]]+to[[:space:]]+fail|fails[[:space:]]+against|non-?zero[[:space:]]+exit/) inv = 1
        r3 = $0
        while (match(r3, /`[^`]+`/)) {
          s3 = substr(r3, RSTART + 1, RLENGTH - 2)
          if (s3 ~ /^\/[A-Za-z0-9_-]+:[A-Za-z0-9_-]+/ || s3 ~ /^Skill\(skill=/) slashy++
          r3 = substr(r3, RSTART + RLENGTH)
        }
        r4 = $0
        gsub(/–/, "-", r4)
        while (match(r4, /[Ss]teps?[[:space:]]+[0-9]+(-[0-9]+)?/)) {
          m4 = substr(r4, RSTART, RLENGTH)
          r4 = substr(r4, RSTART + RLENGTH)
          gsub(/[Ss]teps?[[:space:]]+/, "", m4)
          k = split(m4, a4, "-")
          lo = a4[1] + 0; hi = (k > 1) ? a4[k] + 0 : lo
          for (v = lo; v <= hi && v <= lo + 30; v++)
            if (v > ord) refs = refs ((refs == "") ? "" : ",") v
        }
      }
    }
    END { if (insec) flushdw() }
  ' "$in_md" 2>/dev/null || true)"

  # --- the ladder — first match wins; E9-E14 only when <step-n> was given ---------
  in_token=""; in_reason=""
  if [ "$in_gate" = "ARMED" ]; then in_token=HOLD; in_reason=gate-armed
  elif [ "$in_gate" = "STALE" ]; then in_token=HOLD; in_reason=gate-stale
  elif [ "$in_swept" -eq 1 ]; then in_token=ASK; in_reason=swept-in
  else
    case "$in_stored" in
      approved|in_progress) ;;
      "") in_token=ASK; in_reason=no-grant-on-record ;;
      draft) in_token=ASK; in_reason=draft ;;
      failed) in_token=ASK; in_reason=failed ;;
      superseded) in_token=HOLD; in_reason=superseded ;;
      implemented)
        if [ "$in_total" -gt 0 ] && [ "$in_ticked" -eq "$in_total" ]; then
          in_token=DONE; in_reason=closed
        else
          in_token=ASK; in_reason=stored-implemented-ticks-open
        fi ;;
      *) in_token=ASK; in_reason=no-grant-on-record ;;
    esac
  fi
  if [ -z "$in_token" ] && [ "$in_total" -eq 0 ]; then
    in_token=NO_STEPS; in_reason=stub
    if [ "$(mentor_plan_origin "$in_dir")" = "deferred" ]; then in_reason=deferred-stub; fi
  fi
  if [ -z "$in_token" ] && [ "$in_structure" != "OK" ]; then in_token=HOLD; in_reason=structure; fi
  if [ -z "$in_token" ] && [ "$in_ctx" = "ASK" ]; then in_token=ASK; in_reason=context; fi
  if [ -z "$in_token" ] && [ "$in_ticked" -eq "$in_total" ]; then in_token=DONE; in_reason=all-ticked; fi
  if [ -z "$in_step" ] && [ -z "$in_token" ]; then in_token=GO; in_reason=next-step; fi

  # Step-scope facts — computed whenever <step-n> was given (the STEP BLOCK prints on
  # every token, not just the step-decided ones), decided only when the plan scope
  # left the token open.
  in_st_ticked=""; in_hdr_line=""; in_body_end=""; in_glue=""; in_header=""
  in_prev_unticked=""; in_prev_deferred=""; in_dwf=""; in_refs="-"
  in_out=""; in_outn=""; in_outp=""
  if [ -n "$in_step" ]; then
    in_row="$(printf '%s\n' "$in_scan" | awk -F'\t' -v n="$in_step" '$1 == "STEP" && $2 == n { print; exit }' || true)"
    in_hdr_line="$(printf '%s\n' "$in_row" | cut -f3)"
    in_body_end="$(printf '%s\n' "$in_row" | cut -f4)"
    in_st_ticked="$(printf '%s\n' "$in_row" | cut -f5)"
    in_glue="$(printf '%s\n' "$in_row" | cut -f7)"
    in_header="$(printf '%s\n' "$in_row" | cut -f8-)"
    in_dwf="$(printf '%s\n' "$in_facts" | awk -F'\t' -v n="$in_step" '$1 == "DWF" && $2 == n { print; exit }' || true)"
    in_refs="$(printf '%s\n' "$in_dwf" | cut -f9)"
    in_refs="${in_refs:--}"
    in_out="$(printf '%s\n' "$in_facts" | awk -F'\t' '$1 == "OUT" { print $2 }' | paste -sd, - || true)"
    in_outn="$(printf '%s\n' "$in_facts" | awk -F'\t' '$1 == "OUTN" { print $2 }' | paste -sd, - || true)"
    in_outp="$(printf '%s\n' "$in_facts" | awk -F'\t' '$1 == "OUTP" { print $2 }' | paste -sd, - || true)"

    # E10 inputs: an unticked predecessor is EXCUSED when its own Done when: forward-
    # references a step >= the one requested now (plan-tour's step 6 vs 7 deadlock).
    while IFS=$'\t' read -r _ in_p_ord _ _ in_p_tick _ _ _; do
      [ -n "$in_p_ord" ] || continue
      [ "$in_p_ord" -lt "$in_step" ] || continue
      [ "$in_p_tick" -eq 0 ] || continue
      in_p_refs="$(printf '%s\n' "$in_facts" | awk -F'\t' -v n="$in_p_ord" '$1 == "DWF" && $2 == n { print $9; exit }' || true)"
      in_excused=0
      if [ -n "$in_p_refs" ] && [ "$in_p_refs" != "-" ]; then
        for in_r in $(printf '%s' "$in_p_refs" | tr ',' ' '); do
          if [ "$in_r" -ge "$in_step" ]; then in_excused=1; fi
        done
      fi
      if [ "$in_excused" -eq 1 ]; then
        in_prev_deferred="${in_prev_deferred}${in_prev_deferred:+,}${in_p_ord}"
      else
        in_prev_unticked="${in_prev_unticked}${in_prev_unticked:+,}${in_p_ord}"
      fi
    done <<EOF_STEPS
$(printf '%s\n' "$in_scan" | awk -F'\t' '$1 == "STEP"' || true)
EOF_STEPS

    if [ -z "$in_token" ]; then
      if [ "${in_st_ticked:-0}" -eq 1 ]; then in_token=DONE; in_reason=step-ticked
      elif [ -n "$in_prev_unticked" ]; then in_token=HOLD; in_reason=ordering
      elif [ -n "$in_out" ]; then in_token=ASK; in_reason=outward-action
      else
        in_ell="$(printf '%s\n' "$in_dwf" | cut -f5)"; in_uncl="$(printf '%s\n' "$in_dwf" | cut -f6)"
        in_inv="$(printf '%s\n' "$in_dwf" | cut -f7)"; in_slash="$(printf '%s\n' "$in_dwf" | cut -f8)"
        if [ "${in_ell:-0}" -eq 1 ] || [ "${in_uncl:-0}" -eq 1 ] || [ "${in_inv:-0}" -eq 1 ] || [ "${in_slash:-0}" -eq 1 ]; then
          in_token=ASK; in_reason=done-when-ambiguous
        elif [ "$in_refs" != "-" ]; then
          in_token=DEFER; in_reason=forward-ref
        else
          in_token=GO; in_reason=clear
        fi
      fi
    fi
  fi

  echo "$in_token"
  if [ "$in_verbose" -eq 1 ]; then
    echo "reason=${in_reason}"
    echo "slug=${in_slug}"
    echo "plan_dir=${in_dir}"
    echo "stored=${in_stored:--}"
    echo "effective=${in_eff:-unknown}"
    echo "ticked=${in_ticked}"
    echo "total=${in_total}"
    echo "next_step=${in_next:--}"
    echo "gate=${in_gate}"
    echo "note_swept=${in_swept}"
    echo "structure=${in_structure}"
    echo "context=${in_ctx}"
    if [ -n "$in_step" ]; then
      in_crc="$(printf '%s\n' "$in_header" | cksum | cut -d' ' -f1 || true)"
      in_defer_until="-"
      if [ "$in_refs" != "-" ]; then
        in_defer_until="$(printf '%s' "$in_refs" | tr ',' '\n' | sort -n | tail -1 || true)"
      fi
      echo "step=${in_step}"
      echo "step_ticked=${in_st_ticked:-0}"
      echo "header_line=${in_hdr_line:--}"
      echo "header_crc=${in_crc}"
      echo "header=${in_header}"
      echo "body=${in_hdr_line:-0}-${in_body_end:-0}"
      if [ "${in_glue:-0}" -gt 0 ]; then echo "body_glue_from=${in_glue}"; else echo "body_glue_from=-"; fi
      echo "prev_unticked=${in_prev_unticked:--}"
      echo "prev_deferred=${in_prev_deferred:--}"
      echo "dw_lines=$(printf '%s\n' "$in_dwf" | cut -f3)"
      echo "dw_code_spans=$(printf '%s\n' "$in_dwf" | cut -f4)"
      echo "dw_ellipsis=$(printf '%s\n' "$in_dwf" | cut -f5)"
      echo "dw_unclosed_span=$(printf '%s\n' "$in_dwf" | cut -f6)"
      echo "dw_inverted=$(printf '%s\n' "$in_dwf" | cut -f7)"
      echo "dw_slash_only=$(printf '%s\n' "$in_dwf" | cut -f8)"
      echo "dw_forward_refs=${in_refs}"
      echo "defer_until=${in_defer_until}"
      echo "outward=${in_out:--}"
      echo "outward_negated=${in_outn:--}"
      echo "outward_prose=${in_outp:--}"
      # NOTE: lines — report-only drift signals (never a token; see the doc block).
      in_inputs="$(printf '%s\n' "$in_facts" | awk -F'\t' '$1 == "INP" { print $2 }' | sort -u || true)"
      if [ -n "$in_inputs" ]; then
        in_missing=""
        while IFS= read -r in_p; do
          [ -n "$in_p" ] || continue
          case "$in_p" in /*) in_abs="$in_p" ;; *) in_abs="${in_repo}/${in_p}" ;; esac
          if [ ! -e "$in_abs" ] && [ ! -e "$in_p" ]; then
            in_missing="${in_missing}${in_missing:+,}${in_p}"
          fi
        done <<EOF_INP
$in_inputs
EOF_INP
        [ -n "$in_missing" ] && echo "NOTE: inputs-missing=${in_missing}"
        if grep -q '^## Critical files' "$in_md" 2>/dev/null; then
          in_cf="$(awk '/^## Critical files/ { s = 1; next } /^## / { s = 0 } s' "$in_md" || true)"
          in_unlisted=""
          while IFS= read -r in_p; do
            [ -n "$in_p" ] || continue
            case "$in_cf" in *"$in_p"*) ;; *) in_unlisted="${in_unlisted}${in_unlisted:+,}${in_p}" ;; esac
          done <<EOF_INP2
$in_inputs
EOF_INP2
          [ -n "$in_unlisted" ] && echo "NOTE: critical-files-unlisted=${in_unlisted}"
        fi
      fi
    fi
  fi
  exit 0
fi

# --- start <slug> [init flags]: ensure-dir + init + claim in ONE call (v2.34.0) ---
# The plan-write path used to cost three separate Bash calls around one Write, and
# because each is its own shell, the skill had to warn twice about re-deriving $slug
# — an empty one silently registering nothing. One call removes both footguns.
#
# Order is load-bearing and not a convenience: `init` runs require_slug, which demands
# the dir already exist, and `claim` needs the sidecar `init` writes. Every flag after
# the slug is forwarded to `init` verbatim, so a caller that needs --group/--order/
# --parent/--priority/--category/--from/--deps/--deferred keeps all of them.
#
# `claim` is folded in unconditionally: it is an idempotent no-op on a plan that was
# never a /mentor:defer stub, so a brand-new plan pays nothing and a stub being fleshed
# out stops being shielded from the approval sweep without the caller having to know
# which case they are in. Its "nothing to claim" notice is suppressed here — that line
# is the normal path for a new plan, and printing it every time trains the reader to
# ignore the one case where it matters.
if [ "$sub" = "start" ]; then
  st_slug="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$st_slug" in
    ""|-*)
      echo "[mentor plan-state] start needs <slug> as its FIRST argument." >&2
      echo "  usage: start <slug> [any init flag]" >&2
      exit 1 ;;
  esac
  st_repo="$(mentor_repo_root "$(pwd)")"
  if [ -z "$st_repo" ]; then
    echo "[mentor plan-state] Not inside a git repo — mentor keeps no plan registry here." >&2
    exit 1
  fi
  st_plans="$(mentor_plans_dir "$st_repo")"
  st_self="${hook_dir}/plan-state.sh"
  st_dir="$(bash "$st_self" ensure-dir "${st_plans}/${st_slug}")" || exit 1
  # Both inner calls report to STDERR here, so this subcommand's stdout is exactly one
  # line: the plan path. That is what lets the caller write
  # `plan_md="$(plan-state.sh start "$slug")"` and have a failure kill the pipeline —
  # ensure-dir's own contract, which is worth nothing if init's state summary rides
  # along in the same capture. The summaries are not suppressed, only redirected: they
  # still appear in the command's output for the reader.
  bash "$st_self" init "$st_slug" "$@" >&2 || exit 1
  # Surface only a real claim; swallow the "origin already unset" no-op notice, which is
  # the normal path for a new plan and trains the reader to ignore the line that matters.
  st_claim="$(bash "$st_self" claim "$st_slug" 2>&1)" || { printf '%s\n' "$st_claim" >&2; exit 1; }
  case "$st_claim" in
    *"nothing to claim"*) ;;
    *) printf '%s\n' "$st_claim" >&2 ;;
  esac
  echo "${st_dir}/plan.md"
  exit 0
fi

# Every subcommand handled by an early `if` above (context, dir, ensure-dir, relocate,
# handoff-path, handoff-selfcheck, gate, sweep, policy, start) exits before reaching
# here, so none of them appears in this allow-list — adding one would be unreachable
# code, not a fix.
case "$sub" in
  init|set|set-deps|set-priority|set-category|set-parent|claim|tick|verify|query|list|current|brief) ;;
  ""|-h|--help|help)
    usage
    [ -n "$sub" ] && exit 0
    echo "[mentor plan-state] Missing subcommand." >&2
    exit 1
    ;;
  overview|subtree)
    # Retired in v2.33.0, replaced by `query`. Deliberately its own branch rather than
    # falling through to the unknown-subcommand catch-all: a caller that still invokes
    # one of these is a MIGRATION problem, and "Unknown subcommand: overview" sends
    # them looking for a typo instead of at the flag that replaced it.
    echo "[mentor plan-state] '${sub}' was retired — use 'query' instead." >&2
    case "$sub" in
      overview) echo "  overview --json   ->  query" >&2 ;;
      subtree)  echo "  subtree <slug>    ->  query --subtree <slug>" >&2
                echo "                        (every root at once: query --roots --open-counts)" >&2 ;;
    esac
    usage >&2
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
#   priority  category  deferred_from  goal  parent
# `owner` (v2.23.0, mentor_plan_owner) is the wt-id that minted or last re-owned the
# plan dir, or "-" when unowned. `priority` (v2.24.0, mentor_plan_priority) is the
# impact tier, or "-" when unset; it is APPENDED at the end rather than slotted beside
# `order` on purpose — `list_rows` reads only the first five fields and drops the
# tail into a single `_rest`, so a trailing field cannot disturb the byte-compatible
# 5-column `list` output, while an inserted one would shift every field after it.
# `category`/`deferred_from`/`goal` (v2.25.0, mentor_plan_category/
# mentor_plan_deferred_from/mentor_plan_goal_line) and `parent` (v2.29.0,
# mentor_plan_parent) all follow the SAME append-only rule — each is APPENDED LAST,
# after whatever came before it, never slotted in among the earlier fields, for
# exactly the reason above: `list_rows`' `_rest` field-swallow only stays safe when
# every new field lands at the tail. `category`/`deferred_from`/`parent` read "-"
# when unset, same convention as `priority`; `goal` is likewise "-" for every
# non-deferred entry (see below). `deps_json`/`handoffs_json` are compact (`jq -c`)
# single-line JSON — safe to sit in a tab field because compact jq output never
# contains a literal tab or newline, even inside a string. `list_rows` (below,
# byte-compatible with the pre-v2.17.0 5-field format) and `query` both
# derive from this ONE walk — neither re-walks plans_dir on its own. `list`/`current`
# never needed deps/handoffs/step-counts, so computing them for those two callers too
# is a deliberate small cost in exchange for there being exactly one place that
# decides what "every plan" means.
_plan_walk() {
  local filter="${1:-}" d slug state group order owner origin deps_pairs deps_json
  local handoffs_json ticked total dep miss priority category deferred_from goal parent
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
    parent="$(mentor_plan_parent "$d")"
    goal=""
    # Gate: mentor_plan_goal_line re-reads plan.md, so it runs ONLY for entries
    # whose origin is "deferred" — every ordinary plan skips this file read
    # entirely, which is what keeps the walk fast on a big plan set.
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
    # goal/parent would silently shift every field after it for whoever reads this
    # line. Emit "-" for empty (matching print_table's own existing display
    # convention) and never a raw empty string here; consumers translate "-" back to
    # "" on read. This applies to the LAST field as much as the middle ones: `read`
    # assigns an absent trailing field as empty anyway, so a bare "" there would be
    # indistinguishable from a short record. `goal` can never itself carry a tab
    # (mentor_plan_goal_line strips them), so it is safe to sit as a plain field
    # here too; `parent` is a plain slug (same shape as every other slug-typed
    # sidecar field here), never containing a tab either.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$slug" "$state" "${group:--}" "${order:--}" "${owner:--}" "$deps_json" "${origin:--}" "$handoffs_json" "$ticked" "$total" "${priority:--}" "${category:--}" "${deferred_from:--}" "${goal:--}" "${parent:--}"
  done
}

# list_rows [group-filter] [with-owner] [with-parent] — the pre-v2.17.0 5-field row
# format, byte-compatible: <sortkey> <slug> <effective state> <group> <order>,
# tab-separated and sorted. Sort key: bucket (0 active / 1 superseded+unknown) |
# group (ungrouped sorts on its own slug, so it neither splits a group nor clumps
# with one) | zero-padded order | slug. Derived from _plan_walk's raw records — see
# that function's comment for why this is no longer its own directory walk.
# with-owner=1 appends a tab field (owner wt-id, "-" when unowned) for `list
# --owners`; with-parent=1 (v2.29.0) appends a tab field (parent slug, "-" when
# absent) for `list --parent` — the two compose (both flags together append BOTH,
# owner then parent, in that fixed order) by building the line up with plain string
# concatenation rather than a combinatorial printf per flag pair. The default (both
# omitted/0) 5-field shape used by bare `list` stays byte-identical either way,
# since an extra field is only ever emitted, never read, unless a caller explicitly
# asks for it. `_rest`'s trailing field is `parent` (see _plan_walk's append-only
# comment) — pulled out with a trailing-field parameter expansion rather than
# widening this read to name every one of _plan_walk's tail fields, since this
# function has never needed deps/handoffs/step-counts/priority/category/
# deferred_from/goal and still doesn't.
list_rows() {
  local filter="${1:-}" with_owner="${2:-0}" with_parent="${3:-0}"
  local slug state group order owner _rest bucket gkey okey parent line
  while IFS="$(printf '\t')" read -r slug state group order owner _rest; do
    [ -n "$slug" ] || continue
    [ "$group" = "-" ] && group=""   # un-placeholder — see _plan_walk's comment
    [ "$order" = "-" ] && order=""
    [ "$owner" = "-" ] && owner=""
    parent="${_rest##*$'\t'}"        # _plan_walk's LAST field — see comment above
    [ "$parent" = "-" ] && parent=""
    case "$state" in
      superseded|unknown) bucket=1 ;;
      *)                  bucket=0 ;;
    esac
    gkey="${group:-$slug}"
    case "$order" in
      ''|*[!0-9]*) okey="999" ;;
      *)           okey="$(printf '%03d' "$order")" ;;
    esac
    line="$(printf '%s|%s|%s|%s\t%s\t%s\t%s\t%s' "$bucket" "$gkey" "$okey" "$slug" "$slug" "$state" "${group:--}" "${order:--}")"
    [ "$with_owner" = "1" ]  && line="$(printf '%s\t%s' "$line" "${owner:--}")"
    [ "$with_parent" = "1" ] && line="$(printf '%s\t%s' "$line" "${parent:--}")"
    printf '%s\n' "$line"
  done <<<"$(_plan_walk "$filter")" | LC_ALL=C sort -t"$(printf '\t')" -k1,1
}

print_table() {
  local filter="${1:-}" with_owner="${2:-0}" with_parent="${3:-0}"
  local rows i=0 key slug state group order owner parent
  rows="$(list_rows "$filter" "$with_owner" "$with_parent")"
  if [ -z "$rows" ]; then
    return 1
  fi
  if [ "$with_owner" = "1" ] && [ "$with_parent" = "1" ]; then
    printf '%-3s %-13s %-38s %-24s %-6s %-20s %s\n' "#" "STATE" "PLAN" "GROUP" "ORDER" "OWNER" "PARENT"
    while IFS="$(printf '\t')" read -r key slug state group order owner parent; do
      [ -n "$slug" ] || continue
      i=$((i + 1))
      printf '%-3s %-13s %-38s %-24s %-6s %-20s %s\n' "$i" "$state" "$slug" "$group" "$order" "$owner" "$parent"
    done <<<"$rows"
    return 0
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
  if [ "$with_parent" = "1" ]; then
    printf '%-3s %-13s %-38s %-24s %-6s %s\n' "#" "STATE" "PLAN" "GROUP" "ORDER" "PARENT"
    while IFS="$(printf '\t')" read -r key slug state group order parent; do
      [ -n "$slug" ] || continue
      i=$((i + 1))
      printf '%-3s %-13s %-38s %-24s %-6s %s\n' "$i" "$state" "$slug" "$group" "$order" "$parent"
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

# require_jq_read — the READ-side counterpart for query (which never writes):
# a single stderr line and exit 0, per this file's fail-soft convention for
# environmental problems (see the header comment).
require_jq_read() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "[mentor plan-state] jq not found — cannot compute query." >&2
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
# session. The follow-up line is unconditional on both terminal states, matching the
# checklist's own "always, whatever Verification returned." (v2.25.0: reworded to
# scope it — a deferred stub captures isolated WORK to build, never a check to
# run; an unresolved verification topic belongs on ITS OWN plan's record via
# `set <slug> failed --note "…"`, not a backlog stub that lets the plan close clean.
# v2.33.0: deferral became manual-only, so the line asks for follow-ups to be NAMED
# and offers /mentor:defer as a pointer, instead of instructing a sweep through it.)
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
  echo "  - Name every follow-up WORK item in the report before it's forgotten — don't park it yourself; offer /mentor:defer and let the user choose. Never a check: an unresolved verification topic ends 'failed --note', not a stub."
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

# _descendant_lines <slug> — one TAB-separated line per TRANSITIVE descendant of
# <slug> (mentor_plan_descendants, lib/state.sh): <depth>\t<child-slug>\t<effective
# state>\t<open|closed>. "open" = effective state NOT in {implemented, superseded}
# — the plan's ONE definition of "open descendant"; `query --subtree`'s tree render and
# `set … implemented`'s soft warn both draw from this SAME classification below so
# the two can never drift apart. <depth> is 0 for a direct child of <slug>, 1 for a
# grandchild, etc. — computed by walking each descendant's own parent chain back up
# to <slug> (mentor_plan_parent, repeatedly); mentor_plan_descendants' own output
# order is breadth-first but doesn't expose depth itself, so this is a second,
# per-descendant walk on top of it. A visited-set guards that upward walk against a
# torn/circular sidecar graph that already exists (should never happen given the
# write-time cycle refusal), so this always terminates. No output for a <slug> with
# no descendants.
_descendant_lines() {
  local for_slug="${1:-}" d state depth walk seen
  [ -n "$for_slug" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    state="$(mentor_plan_effective_state "${plans_dir}/${d}")"
    depth=0
    seen=" ${d} "
    walk="$(mentor_plan_parent "${plans_dir}/${d}")"
    while [ -n "$walk" ] && [ "$walk" != "$for_slug" ]; do
      case "$seen" in *" ${walk} "*) break ;; esac
      seen="${seen}${walk} "
      depth=$((depth + 1))
      walk="$(mentor_plan_parent "${plans_dir}/${walk}")"
    done
    case "$state" in
      implemented|superseded) printf '%s\t%s\t%s\tclosed\n' "$depth" "$d" "$state" ;;
      *)                      printf '%s\t%s\t%s\topen\n'   "$depth" "$d" "$state" ;;
    esac
  done <<<"$(mentor_plan_descendants "$plans_dir" "$for_slug")"
  return 0
}

# _query_tree_program — the jq that renders `query`'s entry array as the plan
# hierarchy `/mentor:track` prints. It lives here, not in the skill, because every
# line of it is mechanical: glyphs, tier/category columns, depth-first numbering,
# the roll-up warn, group blocks and parent nesting are all derivable from fields
# `query` already carries. Rendering it in prose cost ~2.8k tokens of instruction on
# every invocation AND re-derived the layout each session, so two runs of the same
# repo could disagree about what "done" looked like. A script cannot drift that way.
#
# Two inputs the entry array itself cannot supply, both passed as --arg:
#   $wt   this worktree's id, for the ` [worktree: …]` tag on a plan another worktree
#         owns. Empty when underivable — an absent tag beats a wrong one.
#   $excl space-joined slugs whose sidecar `note` records the dispatch non-goal gate
#         disposition. They are deliberately NOT counted as unparented fixes: flat is
#         the answer the user already gave there, and re-flagging it every session
#         would tell them to undo a decision they made on purpose.
_query_tree_program() {
  cat <<'MENTOR_TREE_JQ'
# Renders `query`'s entry array as the plan hierarchy /mentor:track shows.
#   $wt   — this worktree's id ("" when underivable: print no tag rather than a wrong one)
#   $excl — space-joined slugs whose sidecar note reads `gate: left uncontained`
def prilbl: {"critical":"crit","high":"high","medium":"med","low":"low","noise":"noise"}[. // ""] // "";
def catlbl: {"feature":"feat","fix":"fix","refactor":"refac","docs":"docs","tooling":"tool"}[. // ""] // "";
def glyph:
    if . == "implemented"  then "●"
  elif . == "in_progress"  then "◐"
  elif . == "draft" or . == "approved" then "○"
  elif . == "failed"       then "✕"
  else "⊘" end;
def isopen: . != "implemented" and . != "superseded";
def pad($n): . + ((" " * ($n - length)) // "");
def tag($w): (if . == "" then "" else "[" + . + "]" end) | pad($w);

. as $all
| [ $all[] | select(.kind == "plan") ]            as $plans
| [ $all[] | select(.kind == "no_plan_topic") ]   as $topics
| [ $all[] | select(.kind == "legacy_handoffs") ] as $legacy
| ($excl | split(" ") | map(select(length > 0)))  as $EX
| ($plans | INDEX(.slug))                         as $BY
# Lineage without containment: an OPEN fix that names a plan through `deferred_from`
# but was never parented to it. `open_descendants` walks `parent` only, so without
# this a root whose every defect was parked flat reads perfectly clean — the wrong
# answer to "any fixes left under this plan?". Stubs the user dispositioned at the
# non-goal gate are excluded: flat is the answer they already gave.
| ( reduce ($plans[] | select(
      .category == "fix" and .parent == null and .deferred_from != null
      and (.state | isopen) and ((.slug | IN($EX[])) | not)
    )) as $f ({}; .[$f.deferred_from.slug] = ((.[$f.deferred_from.slug] // 0) + 1)) ) as $UNP
| ( reduce ($plans[] | select(.parent != null and ((.parent.missing // false) | not)))
      as $c ({}; .[$c.parent.slug] = ((.[$c.parent.slug] // []) + [$c.slug])) ) as $KIDS
| [ $plans[] | select(.parent == null or (.parent.missing // false)) ] as $roots
# Active states first, then group (an ungrouped plan sorts on its own slug, so it lands
# where its name would), then order, then slug — the order the retired `list` table used.
| def sortkey: [ (if .state == "superseded" or .state == "unknown" then 1 else 0 end),
                 (.group // .slug), (.order // 999999), .slug ];
# Widths are measured, not guessed, so the tier/category columns stay scannable whatever
# this repo's longest slug happens to be. +3 leaves room for both brackets and a space.
  ([ $plans[] | (.priority | prilbl) | length ] + [0] | max) as $wPri
| ([ $plans[] | (.category | catlbl) | length ] + [0] | max) as $wCat
| ([ $plans[] | .slug | length ] + [ $topics[] | .slug | length ] + [0] | max) as $wSlug
| def body($e):
    ($e.open_descendants // 0) as $od
    | ($e.state == "implemented" and $od > 0) as $notdone
    | ($UNP[$e.slug] // 0) as $unp
    # The warn marker is a fixed 2-char slot, so flagging a root never shifts the
    # columns of every line beside it out of alignment.
    | ((if $notdone then "⚠ " else "  " end)
       + ($e.state | glyph) + " "
       + (if $wPri > 0 then ($e.priority | prilbl | tag($wPri + 3)) else "" end)
       + (if $wCat > 0 then ($e.category | catlbl | tag($wCat + 3)) else "" end)
       + ($e.slug | pad($wSlug + 2))
       + $e.state
       + ( [ (if $e.parent != null then "fix child" else empty end),
             (if $e.origin == "deferred" then
                ("deferred" + (if $e.deferred_from != null
                   then ", from: " + $e.deferred_from.slug
                        + (if $e.deferred_from.missing then " (missing)" else "" end)
                   else "" end))
              else empty end) ]
           | if length > 0 then " (" + join(", ") + ")" else "" end )
       + (if ($e.parent.missing // false) then " (parent: " + $e.parent.slug + " missing)" else "" end)
       + (if ($e.steps.total // 0) > 0 then " (\($e.steps.ticked)/\($e.steps.total) steps)" else "" end)
       + (if ($e.deps | length) > 0 then " — deps: "
            + ([ $e.deps[] | .slug + (if .missing then " (missing)" else "" end) ] | join(", ")) else "" end)
       + (if $notdone then " — not really done, \($od) open descendant(s)"
          elif $e.parent == null and $od > 0 then " — \($od) open descendant(s)" else "" end)
       + (if $unp > 0 then " — ⚠ \($unp) unparented open fix(es) trace here" else "" end)
       + (if $wt != "" and $e.owner != null and $e.owner != $wt
          then " [worktree: \($e.owner)]" else "" end));
  def emit($slug; $depth):
    $BY[$slug] as $e
    | [ { t: "n", depth: $depth, s: body($e) } ]
      + [ $e.handoffs[]? | { t: "s", depth: $depth, s: ("└ handoff: " + . + " (live)") } ]
      + (if ($e.goal // "") != "" then [ { t: "s", depth: $depth, s: ("└ goal: " + $e.goal) } ] else [] end)
      + ((($KIDS[$slug] // []) | map($BY[.]) | sort_by(sortkey) | map(emit(.slug; $depth + 1)) | add) // []);
  ( reduce ($roots | sort_by(sortkey))[] as $r ({ prev: null, out: [] };
      .out += (if $r.group != null and $r.group != .prev
               then [ { t: "h", depth: 0, s: ("▸ group: " + $r.group) } ] else [] end)
              + emit($r.slug; (if $r.group != null then 1 else 0 end))
      | .prev = $r.group ) | .out ) as $planItems
| ( $topics | sort_by(.slug) | map(
      [ { t: "n", depth: 0, s: ("  ▷ " + (.slug | pad($wSlug + 2)) + "no plan yet") } ]
      + [ .handoffs[]? | { t: "s", depth: 0, s: ("└ handoff: " + . + " (live)") } ] ) | add // [] ) as $topicItems
| ( $legacy | map({ t: "h", depth: 0, s: ("▽ (untracked) legacy handoffs: "
                    + (.handoffs | join(", ")) + " — .mentor/handoffs/, no topic") }) ) as $legacyItems
| ($planItems + $topicItems + $legacyItems) as $items
# Ordinals land only on actionable entries, depth-first — group headers, handoff/goal
# sublines and the footer never consume one, because Step 2 resolves the user's pick
# against exactly these numbers. Padding them to a common width keeps the glyph column
# straight once the list runs past nine entries.
| ([ $items[] | select(.t == "n") ] | length | tostring | length + 1) as $wOrd
| ( reduce $items[] as $it ({ n: 0, out: [] };
      if $it.t == "n"
      then .n += 1
           | .out += [ ("  " * $it.depth) + ("\(.n)." | pad($wOrd)) + " " + $it.s ]
      elif $it.t == "h" then .out += [ ("  " * $it.depth) + $it.s ]
      else .out += [ ("  " * $it.depth) + (" " * ($wOrd + 1)) + $it.s ] end ) | .out ) as $lines
| ($lines + (if ([ $UNP[] ] | add // 0) > 0
    then [ "", "unparented fixes exist — adopt with: plan-state.sh set-parent <stub-slug> <owning-plan>" ]
    else [] end))
| .[]
MENTOR_TREE_JQ
}

# --- query engine: phase-1 scan ------------------------------------------------
# The `query` subcommand replaced `overview --json` + `subtree` (both retired in
# v2.33.0) with one filterable
# read surface. Its whole performance argument rests on a TWO-PHASE walk, so the
# helpers below are deliberately shaped around subprocess COUNT, not code brevity:
#
#   phase 1 (these helpers)  — a fixed, small number of spawns REGARDLESS of plan
#                              count: one jq over every sidecar, one awk over every
#                              plan.md, one find over every handoffs dir. This is
#                              the change that matters. `_plan_walk` calls
#                              mentor_plan_state_field (one `jq` each) nine times per
#                              plan and mentor_plan_tick_counts (one `awk`) once
#                              more, so a 34-plan repo paid ~440 spawns and 1.8 s for
#                              what is really three passes over the same bytes.
#   phase 2 (the query branch) — per-entry work that a filter can ELIMINATE, so it
#                              runs only for survivors: the `## Goal` re-read (one
#                              awk + a bash reflow per deferred entry), which is also
#                              skipped outright when the projection never emits it.
#
# `_plan_walk` stays exactly as it was and remains the single source for
# `list`/`current`; `query` is a second reader of the same plan dirs, not a second
# definition of what a plan is — both agree because both derive "effective state"
# from the same stored-vs-ticks rule (mentor_plan_effective_state's rank comparison,
# reimplemented here over batch-scanned data rather than re-read per plan).

# _query_state_rank <state> — the pure-string half of mentor_plan_state_rank, inlined
# here so the effective-state merge below needs no subshell per plan.
_query_state_rank() {
  case "${1:-}" in
    superseded)  echo 9 ;;
    failed)      echo 5 ;;
    implemented) echo 4 ;;
    in_progress) echo 3 ;;
    approved)    echo 2 ;;
    draft)       echo 1 ;;
    *)           echo 0 ;;
  esac
}

# _query_sidecars — ONE jq spawn for every plan dir's .state.json, emitting
# `{order: [<slug>…], map: {<slug>: <sidecar>}}`. `order` preserves the bash GLOB
# order the dirs were read in, because that is the order the retired `overview --json`
# emitted entries in (a contract `query` keeps); jq's own `keys` sorts by codepoint, which disagrees with glob
# collation on `-` under some locales and would silently reorder the array. Each sidecar is streamed as `<slug><TAB><json-on-one-line>`
# so the slug rides WITH its data: a positional zip against a parallel slug list
# would silently shift every later plan the moment one sidecar is missing. `tr -d`
# is safe because a raw newline cannot appear inside a JSON string (it must be
# escaped as \n), so collapsing a pretty-printed sidecar to one line never changes
# what it parses to. A corrupt sidecar yields `null` from `fromjson?` and is treated
# as "no sidecar" — the same fail-soft reading mentor_plan_state_field gives it,
# rather than aborting the whole query.
_query_sidecars() {
  local d slug
  for d in "${plans_dir}"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "${d}/plan.md" ] || continue
    slug="$(basename "$d")"
    printf '%s\t' "$slug"
    [ -f "${d}/.state.json" ] && tr -d '\n' < "${d}/.state.json"
    printf '\n'
  done | jq -R -s -c '
    [ split("\n")[] | select(length > 0)
      | (index("\t")) as $i
      | { key: .[0:$i], value: ( (.[$i+1:] | fromjson?) // {} ) } ] as $rows
    | { order: [$rows[].key], map: ($rows | from_entries) }' 2>/dev/null
}

# _query_plan_files — ONE awk spawn over every plan.md, emitting
# `<slug>\t<ticked>\t<total>\t<hdr-group>\t<hdr-order>` per plan ("-" for an absent
# header field, matching _plan_walk's placeholder convention — a bare empty field
# collapses under `read`'s IFS handling).
#
# It folds together THREE per-plan reads that were separate processes before:
# mentor_plan_tick_counts' awk, and mentor_plan_header_field's two `sed -n '1,20p'`
# pipelines for the isolation header's group/order. All three want the same file, and
# two of them want only its first 20 lines, so one pass serves all of them.
#
# The step-line match uses MENTOR_STEP_LINE_PATTERN — the SAME shared pattern
# mentor_plan_tick_counts and mentor_plan_tick_step match against — so `query`'s step
# counts can never disagree with what `tick` writes or what the retired `overview` reported.
# The header extractions mirror mentor_plan_header_field's two `sed` expressions
# exactly (first match within lines 1-20 wins). `[*][*]` rather than `\*\*`: a
# backslash-escaped literal is undefined behavior in a dynamic awk regex on some
# implementations (macOS awk 20200816), and the bracket form is portable in both.
_query_plan_files() {
  local d files=()
  for d in "${plans_dir}"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "${d}/plan.md" ] || continue
    files+=("${d}/plan.md")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  awk -v pat="$MENTOR_STEP_LINE_PATTERN" '
    function slugof(f,   n, parts) { n = split(f, parts, "/"); return parts[n-1] }
    FNR == 1 { s = slugof(FILENAME); seen[s] = 1; tot[s] += 0; tk[s] += 0; insec = 0 }
    FNR <= 20 {
      if (grp[s] == "" && match($0, /[Gg]roup `[^`]*`/)) {
        v = substr($0, RSTART, RLENGTH); sub(/^[Gg]roup `/, "", v); sub(/`$/, "", v); grp[s] = v
      }
      if (ord[s] == "" && match($0, /[*][*]Plan [0-9]+ of /)) {
        v = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); ord[s] = v
      }
    }
    /^##[[:space:]]/ {
      h = tolower($0)
      insec = (h ~ /^##[[:space:]]+implementation[[:space:]]+steps/) ? 1 : 0
      next
    }
    !insec { next }
    $0 ~ pat { tot[s]++; if (index($0, "✅") > 0) tk[s]++ }
    END {
      for (x in seen)
        printf "%s\t%d\t%d\t%s\t%s\n", x, tk[x] + 0, tot[x] + 0,
               (grp[x] == "" ? "-" : grp[x]), (ord[x] == "" ? "-" : ord[x])
    }
  ' "${files[@]}" 2>/dev/null
}

# _query_handoffs — ONE find over the whole mentor dir, emitting
# `<topic>\t<live|resolved>\t<basename>\t<path>` per note, where <topic> is `-` for a
# note in the LEGACY flat `.mentor/handoffs/` dir (pre-v2.10, topic-less). Replaces
# both mentor_plan_live_handoffs' per-plan-dir find (one spawn each) and the retired
# `overview`'s separate legacy-dir find — every handoff note in the repo comes from this one pass.
#
# The resolved/live split is by the ANCHORED `*/handoffs/resolved/*` path test, never
# a bare `*/resolved/*`: an unanchored test also matches a repo whose own path
# contains a `resolved/` segment, or a topic slug literally named `resolved`, and
# would silently reclassify every note in the repo. Both kinds are emitted here and
# the caller filters — the default output (equivalent to the retired `overview`) wants live only, while
# `--kind handoff` wants both with their state labelled.
#
# A note that is under neither `<plans_dir>/<topic>/handoffs/` nor the legacy dir is
# dropped rather than guessed at: `topic` has to be a real plan-topic dir name for a
# consumer to resolve it back to a plan.
_query_handoffs() {
  local mdir="$1" hf hstate htopic rest
  [ -d "$mdir" ] || return 0
  find "$mdir" -type f -name '*.md' -path '*/handoffs/*' 2>/dev/null \
  | while IFS= read -r hf; do
      case "$hf" in
        */handoffs/resolved/*) hstate="resolved" ;;
        *)                     hstate="live" ;;
      esac
      case "$hf" in
        "${plans_dir}"/*)
          rest="${hf#"${plans_dir}/"}"
          htopic="${rest%%/*}"
          # must be <topic>/handoffs/… — anything else is not a plan-topic note
          case "$rest" in "${htopic}/handoffs/"*) ;; *) continue ;; esac
          ;;
        "${mdir}"/handoffs/*) htopic="-" ;;
        *) continue ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "$htopic" "$hstate" "${hf##*/}" "$hf"
    done
}

# _query_handoff_mtimes — `<path>\t<epoch-seconds>` for every path on stdin, in ONE
# `stat` call rather than one per note. BSD (`-f %m %N`) and GNU (`-c %Y %n`) disagree
# on both the flag and the format, so it tries BSD first and falls back; a path `stat`
# cannot read is simply absent from the output and the caller renders `mtime: null`.
# Only ever called when `--kind handoff` is actually requested — an ordinary query
# never pays for it.
_query_handoff_mtimes() {
  local paths=()
  while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done
  [ "${#paths[@]}" -gt 0 ] || return 0
  if stat -f '%m %N' "${paths[@]}" 2>/dev/null; then return 0; fi
  stat -c '%Y %n' "${paths[@]}" 2>/dev/null || true
}

# MENTOR_QUERY_JQ — the whole `query` build+filter engine as ONE jq program, so the
# entry construction and every predicate cost a single spawn no matter how many plans
# or filters are involved. Inputs (all named, all pre-batched by the `_query_*`
# helpers above):
#   $sc       {order: [<slug>…], map: {<slug>: <sidecar>}} — plan dirs WITH a plan.md,
#             in glob order (see _query_sidecars on why order is carried explicitly)
#   $alldirs  newline-joined names of EVERY subdir of plans_dir — the set a ref target
#             is checked against, matching _plan_walk's `[ -d … ]` test, which does not
#             require a plan.md
#   $ticks    <slug>\t<ticked>\t<total>\t<hdr-group>\t<hdr-order> per plan
#   $ho       <topic>\t<live|resolved>\t<basename>\t<path> per handoff note
#   $f        the parsed filter flags
#
# Effective state is recomputed here rather than shelled out to
# mentor_plan_effective_state per plan, but by the SAME rule — the more advanced of
# the stored state and the tick-derived one, ties keeping stored, `unknown` when
# neither exists. `rank` mirrors mentor_plan_state_rank exactly (superseded 9 >
# failed 5 > implemented 4 > in_progress 3 > approved 2 > draft 1), including why
# `failed` outranks everything derivable from ticks: an explicit failure record must
# never be overruled by a derivation.
MENTOR_QUERY_JQ='
def rank: {"superseded":9,"failed":5,"implemented":4,"in_progress":3,"approved":2,"draft":1}[.] // 0;
def valid_state: . as $s | ["draft","approved","in_progress","implemented","failed","superseded"] | index($s) != null;
def dash: if . == "-" then null else . end;
def nz: if . == null or . == "" then null else . end;

# scal — the batch equivalent of mentor_plan_state_field: a SCALAR sidecar read that
# `tostring`s whatever it finds and reports unset/null/empty alike as null.
def scal($c; $k): ($c[$k] | if . == null then "" else tostring end) | nz;

# ref — a slug-typed field resolved to deps[]-shaped {slug, missing}, or null when
# unset. This is the contract change that lets consumers stop re-resolving
# deferred_from/parent by hand against the same array.
# `== null` rather than `| not`: jq counts 0 as truthy, so a target sitting at index
# 0 would still read correctly — but only by accident, and the explicit test is what
# makes that non-obvious. `$v`/`$dirs` are bound variables, never a bare `.`: see the
# filter block below for what a rebinding `.` costs here.
def ref($v; $dirs): if ($v | nz) == null then null else {slug: $v, missing: (($dirs | index($v)) == null)} end;

# globre — glob (`*`, `?`) to regex, escaping every other non-word character so a slug
# containing regex punctuation cannot turn into an accidental pattern. Character-wise
# rather than a gsub chain: no nested backslash-escaping to get wrong, and no named
# captures (not portable across every jq build).
def globre:
  reduce (explode[] | [.] | implode) as $ch ("";
    . + (if $ch == "*" then ".*"
         elif $ch == "?" then "."
         elif ($ch | test("[A-Za-z0-9_-]")) then $ch
         else "\\" + $ch end));
def csv: split(",") | map(select(length > 0));

# descendants — every TRANSITIVE child of $root via parent chains, breadth-first,
# alphabetical within a level. This is `mentor_plan_descendants`'"'"'s walk (lib/state.sh)
# served from the parent graph phase 1 already built, not a reimplementation of a
# different algorithm: same frontier/seen structure, same ordering, same
# "descendants only, never $root itself" contract. The whole point is that N roots
# now cost ONE pass over an in-memory map instead of N `subtree` subprocesses.
# The `seen` set is what makes a torn/cyclic parent graph terminate rather than spin —
# `set-parent` cycle-checks at write time, but a hand-edited sidecar has no such gate.
def descendants($children; $root):
  {frontier: [$root], seen: [$root], out: []}
  | until((.frontier | length) == 0;
      ([.frontier[] as $x | ($children[$x] // [])[]] | unique) as $next
      | ($next - .seen) as $fresh
      | .out = (.out + $fresh) | .seen = (.seen + $fresh) | .frontier = $fresh)
  | .out;

($alldirs | split("\n") | map(select(length > 0)))                                    as $DIRS |
($ticks | split("\n") | map(select(length > 0) | split("\t"))
  | map({key: .[0],
         value: {ticked: (.[1] | tonumber), total: (.[2] | tonumber),
                 hgroup: (.[3] | dash), horder: (.[4] | dash)}})
  | from_entries)                                                                     as $T |
($ho | split("\n") | map(select(length > 0) | split("\t")))                           as $H |
(reduce ($H[] | select(.[0] != "-" and .[1] == "live")) as $r
   ({}; .[$r[0]] = ((.[$r[0]] // []) + [$r[2]])))                                     as $LIVE |
[$H[] | select(.[0] == "-" and .[1] == "live") | .[2]]                                as $LEGACY |
($homt | split("\n") | map(select(length > 0))
   | map((index(" ")) as $i | {key: .[$i+1:], value: .[0:$i]}) | from_entries)         as $MT |

[ $sc.order[] as $s
  | ($sc.map[$s] // {})                                                               as $c
  | ($T[$s] // {ticked: 0, total: 0, hgroup: null, horder: null})                     as $t
  | (if (($c.state | type) == "string" and ($c.state | valid_state))
     then $c.state else "" end)                                                       as $stored
  | (if $t.total == 0 then ""
     elif $t.ticked == $t.total then "implemented"
     elif $t.ticked > 0 then "in_progress"
     else "" end)                                                                     as $tick
  | (if $stored == "" then "unknown" else $stored end)                                as $storedeff
  | (if $tick == "" then $storedeff
     elif ($tick | rank) > ($stored | rank) then $tick
     else $storedeff end)                                                             as $eff
  | (scal($c; "group") // $t.hgroup)                                                  as $group
  | (scal($c; "order") // $t.horder)                                                  as $order
  | {kind: "plan", slug: $s, state: $eff,
     group: $group,
     order: (if $order == null then null else ($order | tonumber? // null) end),
     owner: scal($c; "owner"),
     priority: scal($c; "priority"),
     category: scal($c; "category"),
     deferred_from: ref(scal($c; "deferred_from"); $DIRS),
     parent: ref(scal($c; "parent"); $DIRS),
     deps: [ ($c.deps // []) | if type == "array" then .[] else empty end
             | tostring | select(length > 0) | . as $dep
             | {slug: $dep, missing: (($DIRS | index($dep)) == null)} ],
     origin: scal($c; "origin"),
     handoffs: ($LIVE[$s] // []),
     steps: {ticked: $t.ticked, total: $t.total},
     goal: null}
]                                                                                     as $PLANS |

[ $DIRS[] | . as $s
  | select($sc.map[$s] == null)
  | ($LIVE[$s] // []) as $hs | select(($hs | length) > 0)
  | {kind: "no_plan_topic", slug: $s, state: "no plan yet",
     group: null, order: null, owner: null, priority: null, category: null,
     deferred_from: null, parent: null, deps: [], origin: null,
     handoffs: $hs, steps: {ticked: 0, total: 0}, goal: null} ]                       as $NPT |

# Handoff notes as first-class entries — opt-in via `--kind handoff`, so a bare
# `query` returns exactly the kinds the retired `overview --json` returned, so migrating
# a caller stayed a rename. Unlike the `handoffs` array on a plan entry (live basenames only),
# this kind carries RESOLVED notes too, each labelled, because the whole reason to ask
# for notes as items is to see the ones already retired alongside the ones that are not.
# `mtime` is converted from epoch seconds by jq'"'"'s own `todate` rather than a `date`
# subprocess per note.
(if $f.want_handoffs == 1 then
   [ $H[] | . as $r
     | {kind: "handoff",
        topic: (if $r[0] == "-" then null else $r[0] end),
        path: ($r[3] | if ($reporoot != "" and startswith($reporoot + "/")) then .[($reporoot | length) + 1:] else . end),
        handoff_state: $r[1],
        mtime: (($MT[$r[3]] // null) | if . == null then null else (tonumber | todate) end)} ]
 else [] end)                                                                         as $HOF |

(if ($LEGACY | length) > 0 then
   [{kind: "legacy_handoffs", slug: null, state: null,
     group: null, order: null, owner: null, priority: null, category: null,
     deferred_from: null, parent: null, deps: [], origin: null,
     handoffs: $LEGACY, steps: null, goal: null}]
 else [] end)                                                                         as $LEG |

# The parent graph and the open/closed verdict are built from EVERY plan, never from
# the filtered set: an `open_descendants` count computed after filtering would silently
# report 0 for a root whose children the filter happened to exclude.
(reduce ($PLANS[] | select(.parent != null)) as $p
   ({}; .[$p.parent.slug] = ((.[$p.parent.slug] // []) + [$p.slug])))          as $CHILDREN |
(reduce $PLANS[] as $p
   ({}; .[$p.slug] = (($p.state == "implemented" or $p.state == "superseded") | not))) as $OPEN |

($PLANS + $NPT + $LEG + $HOF)
| (if $f.sel_slug_set == 1 then map(select(.slug == $f.sel_slug)) else . end)
| (if $f.sel_subtree_set == 1
   then (descendants($CHILDREN; $f.sel_subtree)) as $D
        | map(. as $e | select($e.slug != null and (($D | index($e.slug)) != null)))
        # Restore BFS/level order: the array being filtered is in glob order, so a
        # plain `select` would hand back the walk'"'"'s answer in the wrong sequence and
        # `--format slug` would stop matching what `subtree` printed.
        | (. as $sel | [$D[] as $s | $sel[] | select(.slug == $s)])
   else . end)
| (if $f.roots == 1 then map(select(.kind == "plan" and .parent == null)) else . end)
| (if $f.open_counts == 1
   then map(if .slug == null then .open_descendants = 0
            else .open_descendants =
                 ([descendants($CHILDREN; .slug)[] | select($OPEN[.])] | length) end)
   else . end)
# Every predicate reads the entry through the explicit `$e` binding, never a bare
# `.`: several of them pipe into a derived value first (`$f.state | csv`), and a
# pipe rebinds `.` to that value — so a bare `.state` inside one of them indexes
# the CSV ARRAY, not the entry, and jq aborts the whole read with "Cannot index
# array with string". Binding once here is what keeps a filter list this long
# uniform enough to extend safely.
| map(. as $e | select(
      ($f.kind     == "" or (($f.kind     | csv) | index($e.kind)     != null))
  and ($f.state    == "" or (($f.state    | csv) | index($e.state)    != null))
  and ($f.priority == "" or (($f.priority | csv) | index($e.priority) != null))
  and ($f.category == "" or (($f.category | csv) | index($e.category) != null))
  and ($f.origin   == "" or (($f.origin   | csv) | index($e.origin)   != null))
  and ($f.openf   == 0 or (($e.state == "implemented" or $e.state == "superseded") | not))
  and ($f.closedf == 0 or ($e.state == "implemented" or $e.state == "superseded"))
  and ($f.group_set  == 0 or (if ($f.group | nz) == null then ($e.group == null)
                              else (($f.group | csv) | index($e.group) != null) end))
  and ($f.parent_set == 0 or (($e.parent != null)
                              and (($f.parent | csv) | index($e.parent.slug) != null)))
  and ($f.no_parent  == 0 or ($e.parent == null))
  and ($f.dfrom_set    == 0 or (($e.deferred_from != null) and ($e.deferred_from.slug == $f.dfrom)))
  and ($f.dfrom_exists == 0 or (($e.deferred_from != null) and (($e.deferred_from.missing) | not)))
  and ($f.owner_set == 0 or (if ($f.owner | nz) == null then ($e.owner == null)
                             else (($f.owner | csv) | index($e.owner) != null) end))
  and ($f.unowned   == 0 or ($e.owner == null))
  and ($f.has_handoff  == 0 or (($e.handoffs | length) > 0))
  and ($f.deps_missing == 0 or (([$e.deps[] | select(.missing)] | length) > 0))
  and ($f.match == "" or (($e.slug // "") | test("^" + ($f.match | globre) + "$")))
))
'

case "$sub" in

  init)
    slug=""; group=""; order=""; deps=""; deferred=0; priority=""; category=""; from_slug=""; parent=""
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
        --parent) parent="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        -*) echo "[mentor plan-state] init: unknown flag ${1}" >&2; usage >&2; exit 1 ;;
        *)  [ -z "$slug" ] && slug="$1" || { echo "[mentor plan-state] init: unexpected argument ${1}" >&2; exit 1; }; shift ;;
      esac
    done
    require_slug "$slug"
    # Validated BEFORE any write, like `set`'s state check — a typo'd tier/category is
    # a usage error, not a fail-soft skip, so `init` can never report success having
    # quietly dropped the one field the caller passed it. (A `--deps` cycle stays
    # fail-soft by contrast: that is a graph condition the caller could not have known
    # locally, not a misspelling — `--parent` mirrors deps for the same reason, see
    # the existence+cycle block below, near --deps'. `--from` stays UNVALIDATED for
    # the same reason `--deps` targets are — the source plan slug it names may not
    # exist yet, or may be deleted later; that dangle is resolved at render time, not
    # here.) An EMPTY --priority/--category is not an error and not a clear — init
    # never clears anything; every other flag here preserves on empty the same way,
    # and `set-priority`/`set-category <slug> ""` are the one paths that un-tier/
    # un-categorize a plan (`set-parent <slug> ""` mirrors them for parent).
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
    parent_summary=""
    if [ -n "$parent" ]; then
      if [ ! -d "${plans_dir}/${parent}" ]; then
        echo "[mentor plan-state] init: --parent '${parent}' does not exist — parent NOT set; other fields still applied. Run 'plan-state.sh list' to see the slugs that exist." >&2
      elif [ -n "$(mentor_plan_would_cycle_parent "$plans_dir" "$slug" "$parent")" ]; then
        echo "[mentor plan-state] init: --parent would create a parent cycle (${slug} → … → ${slug} through ${parent}) — parent NOT set; other fields still applied." >&2
      else
        parent_summary="$parent"
        write_args+=(--parent "$parent_summary")
      fi
    fi
    mentor_plan_state_write "$plan_dir" "${write_args[@]}"
    echo "[mentor plan-state] ${slug}: $(mentor_plan_effective_state "$plan_dir")${group:+  group=${group}}${order:+  order=${order}}${priority:+  priority=${priority}}${category:+  category=${category}}${deps_summary:+  deps=${deps_summary}}$([ "$deferred" -eq 1 ] && printf '  origin=deferred')${from_slug:+  from=${from_slug}}${parent_summary:+  parent=${parent_summary}}"
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
    # v2.29.0 soft warn (NOT gated on before_stored, unlike the reminders below): a
    # plan set implemented while its own subtree still has open work should say so
    # EVERY time, fresh transition or idempotent re-close alike, because whether a
    # descendant is open is a live fact that can change between calls (a new fix can
    # get parked under an already-implemented root) — this must never go stale the
    # way a one-time "you just closed this" reminder can. SOFT only: the write above
    # already happened and always succeeds regardless of what this finds — see the
    # plan's decision table ("consistent with the deps precedent").
    if [ "$state" = "implemented" ]; then
      open_lines="$(_descendant_lines "$slug" | awk -F'\t' '$4=="open"')"
      if [ -n "$open_lines" ]; then
        open_n="$(printf '%s\n' "$open_lines" | grep -c .)"
        echo "[mentor plan-state] WARN: ${open_n} open descendant(s) — ${slug} is not really done until these close too:" >&2
        printf '%s\n' "$open_lines" | awk -F'\t' '{printf "  - %s (%s)\n", $2, $3}' >&2
      fi
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

  set-parent)
    # The VALUE is required as a positional even when it is the empty string, so
    # `set-parent <slug>` with nothing after it is a usage error rather than a
    # silent clear — detaching from a parent must be something the caller typed on
    # purpose (`set-parent <slug> ""`), not what a dropped shell argument decays
    # into. UNLIKE set-priority/set-category, a non-empty value here is NOT a
    # closed-vocabulary usage error on a bad value — existence and cycle are graph
    # conditions the caller could not have known locally, so both are fail-soft
    # (stderr warning, no write), mirroring set-deps exactly.
    slug="${1:-}"; if [ "$#" -gt 0 ]; then shift; fi
    require_slug "$slug"
    if [ "$#" -eq 0 ]; then
      echo "[mentor plan-state] set-parent: a <parent-slug> is required (use \"\" to clear)." >&2
      usage >&2
      exit 1
    fi
    parent_val="$1"; shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] set-parent: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    require_jq
    plan_dir="${plans_dir}/${slug}"
    if [ -n "$parent_val" ]; then
      if [ ! -d "${plans_dir}/${parent_val}" ]; then
        echo "[mentor plan-state] set-parent: refused — no such plan '${parent_val}' (run 'plan-state.sh list' to see the slugs that exist). No write." >&2
        exit 0
      fi
      if [ -n "$(mentor_plan_would_cycle_parent "$plans_dir" "$slug" "$parent_val")" ]; then
        echo "[mentor plan-state] set-parent: refused — ${slug} → … → ${slug} would be a parent cycle through ${parent_val}. No write." >&2
        exit 0
      fi
    fi
    # Re-read and re-pass the note for the same reason set-priority/set-category do:
    # mentor_plan_state_write always REPLACES --note (even when omitted, which would
    # clear it), so a parent-only write must round-trip the current note.
    mentor_plan_state_write "$plan_dir" --parent "$parent_val" --note "$(mentor_plan_state_field "$plan_dir" note)"
    echo "[mentor plan-state] ${slug}: parent = ${parent_val:-(unset)}"
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


  # --- query: the ONE filterable read surface, which replaced `overview --json` (whole
  # array, no filters) and `subtree <slug>` (one root's descendants, one process per
  # root). Four orthogonal argument groups — Select (which items are walked at all),
  # Filter (AND-combined predicates), Enrich (opt-in extra fields), Output (shape).
  #
  # Two contract changes vs the retired `overview --json`, both deliberate:
  #   * `deferred_from` and `parent` are resolved to `{slug, missing}` — the shape
  #     `deps[]` has carried since v2.17.0 — instead of a bare slug string. Consumers
  #     were re-resolving those two by hand against the same array (plan-track's
  #     `(parent: X missing)` and `from: X (missing)` render rules, resuming's
  #     lineage-fix jq); the field now carries the answer.
  #   * `open_descendants` appears when `--open-counts` is passed, computed for EVERY
  #     entry from one parent graph rather than one `subtree` subprocess per root.
  #
  # Performance is the reason this exists at all, so the walk is two-phase: phase 1
  # (the `_query_*` helpers above) costs a FIXED three subprocesses no matter how many
  # plans there are, and phase 2 — the `## Goal` re-read, the only genuinely per-entry
  # cost left — runs for survivors only, and only when the projection actually emits
  # `goal`. A naive filter-after-enrich walk would pass every correctness check here
  # and still be slower than what it replaced.
  query)
    q_sel_slug=""; q_sel_slug_set=0
    q_sel_subtree=""; q_sel_subtree_set=0; q_roots=0; q_open_counts=0
    q_kind=""; q_state=""; q_openf=0; q_closedf=0
    q_priority=""; q_category=""; q_origin=""
    q_group=""; q_group_set=0
    q_parent=""; q_parent_set=0; q_no_parent=0
    q_dfrom=""; q_dfrom_set=0; q_dfrom_exists=0
    q_owner=""; q_owner_set=0; q_unowned=0
    q_has_handoff=0; q_deps_missing=0; q_match=""
    q_format="json"; q_fields=""; q_sort=""; q_limit=""
    # Whether the projection will actually emit `goal`. Always 1 today; the output
    # layer sets it to 0 when --fields/--format leaves `goal` out, so a query that
    # never shows the field also never pays for the plan.md re-reads behind it.
    q_want_goal=1
    q_need() {
      if [ "$2" -lt 2 ]; then
        echo "[mentor plan-state] query: ${1} needs a value." >&2
        usage >&2
        exit 1
      fi
    }
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --slug)        q_need "$1" "$#"; q_sel_slug="$2";  q_sel_slug_set=1; shift 2 ;;
        --subtree)     q_need "$1" "$#"; q_sel_subtree="$2"; q_sel_subtree_set=1; shift 2 ;;
        --roots)       q_roots=1; shift ;;
        --open-counts) q_open_counts=1; shift ;;
        --kind)        q_need "$1" "$#"; q_kind="$2";      shift 2 ;;
        --state)       q_need "$1" "$#"; q_state="$2";     shift 2 ;;
        --open)        q_openf=1;   shift ;;
        --closed)      q_closedf=1; shift ;;
        --priority)    q_need "$1" "$#"; q_priority="$2";  shift 2 ;;
        --category)    q_need "$1" "$#"; q_category="$2";  shift 2 ;;
        --origin)      q_need "$1" "$#"; q_origin="$2";    shift 2 ;;
        --group)       q_need "$1" "$#"; q_group="$2";     q_group_set=1;  shift 2 ;;
        --parent)      q_need "$1" "$#"; q_parent="$2";    q_parent_set=1; shift 2 ;;
        --no-parent)   q_no_parent=1; shift ;;
        --deferred-from) q_need "$1" "$#"; q_dfrom="$2";   q_dfrom_set=1;  shift 2 ;;
        --deferred-from-exists) q_dfrom_exists=1; shift ;;
        --owner)       q_need "$1" "$#"; q_owner="$2";     q_owner_set=1;  shift 2 ;;
        --unowned)     q_unowned=1;     shift ;;
        --has-handoff) q_has_handoff=1; shift ;;
        --deps-missing) q_deps_missing=1; shift ;;
        --match)       q_need "$1" "$#"; q_match="$2";     shift 2 ;;
        --format)      q_need "$1" "$#"; q_format="$2";    shift 2 ;;
        --fields)      q_need "$1" "$#"; q_fields="$2";    shift 2 ;;
        --sort)        q_need "$1" "$#"; q_sort="$2";      shift 2 ;;
        --limit)       q_need "$1" "$#"; q_limit="$2";     shift 2 ;;
        *)
          echo "[mentor plan-state] query: unexpected argument ${1}" >&2
          usage >&2
          exit 1
          ;;
      esac
    done
    if [ "$q_openf" -eq 1 ] && [ "$q_closedf" -eq 1 ]; then
      echo "[mentor plan-state] query: --open and --closed are mutually exclusive." >&2
      exit 1
    fi
    if [ "$q_parent_set" -eq 1 ] && [ "$q_no_parent" -eq 1 ]; then
      echo "[mentor plan-state] query: --parent and --no-parent are mutually exclusive." >&2
      exit 1
    fi
    if [ "$q_owner_set" -eq 1 ] && [ "$q_unowned" -eq 1 ]; then
      echo "[mentor plan-state] query: --owner and --unowned are mutually exclusive." >&2
      exit 1
    fi
    case "$q_format" in
      json|table|slug|count|tsv|tree) ;;
      *)
        echo "[mentor plan-state] query: --format must be one of json|table|slug|count|tsv|tree (got: ${q_format})." >&2
        exit 1
        ;;
    esac
    if [ -n "$q_limit" ]; then
      case "$q_limit" in
        ''|*[!0-9]*)
          echo "[mentor plan-state] query: --limit must be a non-negative integer (got: ${q_limit})." >&2
          exit 1
          ;;
      esac
    fi
    if [ "$q_sel_slug_set" -eq 1 ] && [ "$q_sel_subtree_set" -eq 1 ]; then
      echo "[mentor plan-state] query: --slug and --subtree are mutually exclusive." >&2
      exit 1
    fi
    if [ "$q_sel_slug_set" -eq 1 ]; then require_slug "$q_sel_slug"; fi
    if [ "$q_sel_subtree_set" -eq 1 ]; then require_slug "$q_sel_subtree"; fi
    require_jq_read

    # Skip phase 2 entirely when nothing downstream can show `goal` — the enrichment
    # costs one plan.md re-read per deferred survivor, and a projection that never
    # emits the field has no reason to pay for it. `--sort goal` still needs it even
    # though the field may not be printed, so it re-enables the pass.
    case "$q_format" in
      count|slug) q_want_goal=0 ;;
    esac
    if [ -n "$q_fields" ]; then
      case ",${q_fields}," in
        *,goal,*) q_want_goal=1 ;;
        *)        q_want_goal=0 ;;
      esac
    fi
    [ "$q_sort" = "goal" ] && q_want_goal=1

    q_mentor_dir="$(dirname "$plans_dir")"

    # Every subdir of plans_dir, glob order — the set a `deps`/`deferred_from`/`parent`
    # target is checked against. Deliberately NOT the plan.md-only set: `_plan_walk`'s
    # own missing-marking tests `[ -d "${plans_dir}/${dep}" ]`, so a topic dir that
    # holds handoffs but no plan.md yet counts as PRESENT, not missing. Built with
    # plain string concatenation — no subprocess.
    q_alldirs=""
    for q_d in "${plans_dir}"/*/; do
      [ -d "$q_d" ] || continue
      q_d="${q_d%/}"
      q_alldirs="${q_alldirs}${q_d##*/}
"
    done

    # `handoff` entries are opt-in: only a --kind that explicitly names them adds the
    # kind to the pool, so bare `query` keeps returning exactly what the retired
    # `overview --json` did. The mtime `stat` pass is gated on the same answer.
    q_want_handoffs=0
    case ",${q_kind}," in *,handoff,*) q_want_handoffs=1 ;; esac

    q_sc="$(_query_sidecars)"
    [ -n "$q_sc" ] || q_sc='{"order":[],"map":{}}'
    q_ticks="$(_query_plan_files)"
    q_ho="$(_query_handoffs "$q_mentor_dir")"
    q_homt=""
    if [ "$q_want_handoffs" -eq 1 ] && [ -n "$q_ho" ]; then
      q_homt="$(printf '%s\n' "$q_ho" | cut -f4 | _query_handoff_mtimes)"
    fi

    q_filters="$(jq -n -c \
      --arg kind "$q_kind" --arg state "$q_state" \
      --argjson openf "$q_openf" --argjson closedf "$q_closedf" \
      --arg priority "$q_priority" --arg category "$q_category" --arg origin "$q_origin" \
      --arg group "$q_group" --argjson group_set "$q_group_set" \
      --arg parent "$q_parent" --argjson parent_set "$q_parent_set" --argjson no_parent "$q_no_parent" \
      --arg dfrom "$q_dfrom" --argjson dfrom_set "$q_dfrom_set" --argjson dfrom_exists "$q_dfrom_exists" \
      --arg owner "$q_owner" --argjson owner_set "$q_owner_set" --argjson unowned "$q_unowned" \
      --argjson has_handoff "$q_has_handoff" --argjson deps_missing "$q_deps_missing" \
      --arg match "$q_match" --arg sel_slug "$q_sel_slug" --argjson sel_slug_set "$q_sel_slug_set" \
      --arg sel_subtree "$q_sel_subtree" --argjson sel_subtree_set "$q_sel_subtree_set" \
      --argjson roots "$q_roots" --argjson open_counts "$q_open_counts" \
      --argjson want_handoffs "$q_want_handoffs" \
      '$ARGS.named')"

    q_out="$(jq -n -c \
      --argjson sc "$q_sc" \
      --arg alldirs "$q_alldirs" \
      --arg ticks "$q_ticks" \
      --arg ho "$q_ho" \
      --arg homt "$q_homt" \
      --arg reporoot "$repo_root" \
      --argjson f "$q_filters" \
      "$MENTOR_QUERY_JQ")" || {
        echo "[mentor plan-state] query: the read failed (corrupt sidecar or jq error)." >&2
        exit 1
      }

    # --- phase 2: enrich SURVIVORS only -----------------------------------------
    # `goal` is the one field that still costs a per-entry plan.md re-read (an awk
    # pass plus a reflow), and _plan_walk's own gate applies unchanged: only an
    # `origin: "deferred"` entry has a `## Goal` section to read, so an ordinary plan
    # never pays it. Running this AFTER the filter is the whole point of the two-phase
    # split — a query that selected 3 of 34 plans reads 3 files, not 34.
    if [ "$q_want_goal" -eq 1 ]; then
      q_goal_slugs="$(printf '%s' "$q_out" | jq -r '.[] | select(.kind == "plan" and .origin == "deferred") | .slug')"
      if [ -n "$q_goal_slugs" ]; then
        q_goal_tsv=""
        while IFS= read -r q_g; do
          [ -n "$q_g" ] || continue
          q_goal_tsv="${q_goal_tsv}${q_g}$(printf '\t')$(mentor_plan_goal_line "${plans_dir}/${q_g}/plan.md")
"
        done <<<"$q_goal_slugs"
        q_out="$(printf '%s' "$q_out" | jq -c --arg g "$q_goal_tsv" '
          ($g | split("\n") | map(select(length > 0) | split("\t"))
             | map({key: .[0], value: (.[1] // "")}) | from_entries) as $G
          | map(if $G[.slug // ""] != null and $G[.slug] != ""
                then .goal = $G[.slug] else . end)')"
      fi
    fi

    # --- output layer: sort, limit, project, format ------------------------------
    # Applied in that order, and deliberately AFTER phase 2, so `--sort goal` sorts on
    # the enriched value rather than the null placeholder. `--fields` takes dot paths
    # (`steps.total`, `parent.slug`) resolved with getpath, so a caller can pull one
    # scalar out of a nested field without a second jq of their own.
    #
    # `json` is the default precisely so migrating a caller off the retired
    # `overview --json` was a rename and nothing more.
    q_out="$(printf '%s' "$q_out" | jq -c \
      --arg sort "$q_sort" --arg limit "$q_limit" '
      def path_of($s): ($s | split("."));
      (if $sort == "" then . else sort_by(getpath(path_of($sort))) end)
      | (if $limit == "" then . else .[0:($limit | tonumber)] end)')"

    case "$q_format" in
      count)
        printf '%s' "$q_out" | jq 'length'
        ;;
      slug)
        # `.slug // empty`, not `.slug // "-"`: a legacy_handoffs entry has no slug at
        # all, and inventing a placeholder here would put a non-slug into a list whose
        # entire purpose is to be fed back in as `--slug`/`--subtree` arguments.
        printf '%s' "$q_out" | jq -r '.[] | .slug // empty'
        ;;
      tree)
        # The rendered hierarchy, ready to print verbatim. `--fields` is meaningless
        # here (the layout picks its own columns) and is ignored rather than erroring,
        # so a caller that sets it globally still gets a usable tree.
        q_wt="$(mentor_worktree_id "$(pwd)" 2>/dev/null)" || q_wt=""
        # `query`'s projection drops `note`, so re-read the sidecars for the one field
        # the exclusion needs — one jq spawn, the same helper phase 1 used.
        q_excl="$(_query_sidecars | jq -r '
          (.map // {}) | to_entries[]
          | select(((.value.note // "") | contains("gate: left uncontained")))
          | .key' 2>/dev/null | tr '\n' ' ')" || q_excl=""
        printf '%s' "$q_out" | jq -r --arg wt "$q_wt" --arg excl "$q_excl" "$(_query_tree_program)"
        ;;
      json)
        if [ -n "$q_fields" ]; then
          printf '%s' "$q_out" | jq --arg fields "$q_fields" '
            ($fields | split(",") | map(select(length > 0))) as $F
            | map(. as $e | reduce $F[] as $f ({}; .[$f] = ($e | getpath($f | split(".")))))'
        else
          printf '%s' "$q_out" | jq '.'
        fi
        ;;
      tsv|table)
        # Default columns mirror `list`'s five, so a `--format table` with no --fields
        # reads like the table people already know.
        q_cols="${q_fields:-slug,state,group,order}"
        q_tsv="$(printf '%s' "$q_out" | jq -r --arg fields "$q_cols" '
          ($fields | split(",") | map(select(length > 0))) as $F
          | .[] | . as $e
          | [ $F[] as $f
              | ($e | getpath($f | split(".")))
              | if . == null then "-"
                elif type == "array"  then (map(tostring) | join(" "))
                elif type == "object" then (tostring)
                else tostring end ]
          | @tsv')"
        if [ "$q_format" = "tsv" ]; then
          [ -n "$q_tsv" ] && printf '%s\n' "$q_tsv"
        else
          if [ -z "$q_fields" ]; then
            # print_table's own widths, so the default table lines up with `list`.
            printf '%-3s %-13s %-38s %-24s %s\n' "#" "STATE" "PLAN" "GROUP" "ORDER"
            q_i=0
            while IFS="$(printf '\t')" read -r q_c1 q_c2 q_c3 q_c4; do
              [ -n "$q_c1" ] || continue
              q_i=$((q_i + 1))
              printf '%-3s %-13s %-38s %-24s %s\n' "$q_i" "$q_c2" "$q_c1" "$q_c3" "$q_c4"
            done <<<"$q_tsv"
          else
            # An arbitrary --fields set has no pre-agreed widths, so size each column
            # to its own widest cell (header included) rather than truncating into
            # `list`'s layout, which was chosen for a different five columns.
            printf '%s\n' "$q_tsv" | awk -F'\t' -v hdr="$q_cols" '
              BEGIN { n = split(hdr, H, ",") ; for (i = 1; i <= n; i++) w[i] = length(H[i]) }
              { for (i = 1; i <= n; i++) if (length($i) > w[i]) w[i] = length($i); rows[NR] = $0 }
              END {
                for (i = 1; i <= n; i++) printf "%-*s%s", w[i], toupper(H[i]), (i < n ? "  " : "\n")
                for (r = 1; r <= NR; r++) {
                  split(rows[r], C, "\t")
                  for (i = 1; i <= n; i++) printf "%-*s%s", w[i], C[i], (i < n ? "  " : "\n")
                }
              }'
          fi
        fi
        ;;
    esac
    ;;

  # --- verify <slug>: the ONE call planning's "Verify the write" (SKILL.md, Step 4)
  # needs before every approval ask. Replaces a fresh awk/grep one-liner the agent
  # was observed hand-rebuilding differently on 5 consecutive asks in one session —
  # never the same check twice, and the one ask that dropped the table check is
  # exactly where a table-adjacent defect landed. Same rationale as handoff-selfcheck
  # above: a script call cannot exhibit a partial-copy failure the way a
  # freshly-typed one-liner can.
  #
  # Three DETERMINISTIC checks gate the exit code (fence balance, table pipe-count
  # uniformity, every step body carrying a `Done when:`) — the first two already
  # mandated in SKILL.md:447-460 prose, backed by nothing until now; the third is
  # documented at its implementation below. The rest print as informational CHECK:
  # lines and never fail verify (a stray ✅ and an `###` inside the steps section,
  # both documented below, plus):
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

    # Step-structure checks (v2.36.0), reading mentor_plan_step_scan (lib/state.sh) —
    # the ONE derivation `instant` also consumes, so verify can never disagree with
    # tick/query/instant about what a step is. Only the first GATES: every step body
    # carrying a `Done when:` holds across all 14 step-bearing plans in this repo with
    # zero exceptions, and its ABSENCE is the direct symptom of a body truncated by a
    # phantom step line — the class the `[.]` delimiter fix in lib/state.sh closed.
    # The other two only report, because both fire on legitimate authoring: a ✅ off a
    # step line is a stray tick about half the time and the rest of the time is prose
    # quoting the character (a `Prompt sketch:` describing tick state), and an `###`
    # inside the section is a real subsection that step-body extraction nonetheless
    # glues onto the step above.
    v_scan="$(mentor_plan_step_scan "$plan_md" || true)"
    v_total="$(printf '%s\n' "$v_scan" | awk -F'\t' '$1 == "TOTAL" { print $2 }' || true)"
    v_nodw="$(printf '%s\n' "$v_scan" | awk -F'\t' '
      $1 == "STEP" && $6 == 0 {
        h = $8; for (i = 9; i <= NF; i++) h = h "\t" $i
        printf "%d %s\n", $3, substr(h, 1, 60)
      }' || true)"
    if [ "${v_total:-0}" -eq 0 ]; then
      echo "CHECK: no ## Implementation steps section (deferred stub, or not yet fleshed out)"
    elif [ -z "$v_nodw" ]; then
      echo "CHECK: step bodies complete (${v_total} step(s), each carrying a Done when:)"
    else
      echo "CHECK: step body INCOMPLETE — no Done when: under:"
      printf '%s\n' "$v_nodw" | sed 's/^/  line /'
      v_fail=1
    fi
    v_tick="$(printf '%s\n' "$v_scan" | awk -F'\t' '$1 == "XTICK" { print $2 }' | paste -sd, - || true)"
    if [ -n "$v_tick" ]; then
      echo "CHECK: ✅ on a non-step line inside ## Implementation steps (line ${v_tick}) — the tick counter cannot see it (informational only)"
    fi
    v_glue="$(printf '%s\n' "$v_scan" | awk -F'\t' '$1 == "GLUE" { print $2 }' | paste -sd, - || true)"
    if [ -n "$v_glue" ]; then
      echo "CHECK: ### heading inside ## Implementation steps (line ${v_glue}) — step-body extraction glues it onto the step above (informational only)"
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
    filter=""; list_owners=0; list_parent=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --group) filter="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --owners) list_owners=1; shift ;;
        --parent) list_parent=1; shift ;;
        *) echo "[mentor plan-state] list: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
      esac
    done
    echo "PLANS_DIR: ${plans_dir}"
    echo
    if ! print_table "$filter" "$list_owners" "$list_parent"; then
      echo "[mentor plan-state] No plans${filter:+ in group ${filter}} in ${plans_dir}." >&2
      echo "[mentor plan-state] Topics holding only handoffs (no plan.md yet) never appear here — use 'query' for the full picture." >&2
      exit 0
    fi
    echo
    echo "Plan files are PLANS_DIR/<PLAN>/plan.md. 'unknown' = a pre-2.4.0 plan with no state on record."
    echo "Topics holding only handoffs (no plan.md yet) never appear above — use 'query' for the full picture."
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

  # --- brief <slug> [--step N]: a scoped envelope for dispatching one step, instead of
  # handing an implementer the whole plan.md (22.8 KB median, 48.5 KB max — see this
  # plan's own Context). Read-only: never writes, never ticks (that stays `tick`'s job).
  # Reuses MENTOR_STEP_LINE_PATTERN — the SAME pattern mentor_plan_tick_counts/
  # mentor_plan_tick_step (lib/state.sh) already match step lines against — for every
  # step-line decision below, so `brief` and `tick` can never disagree about what counts
  # as a step. `br_body_awk` (the --step body extractor) mirrors mentor_plan_tick_step's
  # own boundary logic (a step's body runs from its own step line through, but not
  # including, the next step line or the next `##` section heading) but only ever
  # PRINTS — it is not a copy of tick_step's write path, just the same walk.
  brief)
    slug="${1:-}"; [ "$#" -gt 0 ] && shift
    brief_step_set=0; brief_step=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --step) brief_step_set=1; brief_step="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        *) echo "[mentor plan-state] brief: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
      esac
    done
    require_slug "$slug"
    plan_md="${plans_dir}/${slug}/plan.md"
    if [ ! -f "$plan_md" ]; then
      echo "[mentor plan-state] brief: no plan.md at ${plan_md}." >&2
      exit 1
    fi
    if [ "$brief_step_set" -eq 1 ]; then
      case "$brief_step" in
        ''|*[!0-9]*|0)
          echo "[mentor plan-state] brief: --step must be a positive integer, got '${brief_step}'." >&2
          usage >&2
          exit 1
          ;;
      esac
    fi
    read -r br_ticked br_total <<<"$(mentor_plan_tick_counts "$plan_md")"
    if [ "$brief_step_set" -eq 1 ] && [ "$brief_step" -gt "$br_total" ]; then
      echo "[mentor plan-state] brief: ${slug} has no step ${brief_step} (plan.md has ${br_total} step(s) in '## Implementation steps')." >&2
      exit 1
    fi

    # Plan title: the first `# ` (single-hash) heading — the content spec's own opening line.
    br_title="$(awk '/^#[[:space:]]/ { sub(/^#[[:space:]]*/, ""); print; exit }' "$plan_md")"
    # `## Context`, never `## Goal` — an ordinary mentor-authored plan carries the former;
    # the latter is `mentor:deferring`'s stub-only heading (mentor_plan_goal_line's default).
    br_context="$(mentor_plan_goal_line "$plan_md" context)"

    # Whole `## Out of scope` section body (heading excluded, printed separately below) —
    # same "##-heading-gated awk pass" technique mentor_plan_goal_line itself uses, just
    # keeping every line of the section instead of only its first paragraph.
    br_oos="$(awk '
      /^##[[:space:]]/ {
        h = tolower($0)
        if (insec) exit
        insec = (h ~ /^##[[:space:]]+out[[:space:]]+of[[:space:]]+scope/) ? 1 : 0
        next
      }
      insec { print }
    ' "$plan_md")"

    # One line per step, trimmed of leading indent, in document order — every step's own
    # line already carries its title AND its ✅ tick state, so this is the whole list.
    br_steps="$(awk -v pat="$MENTOR_STEP_LINE_PATTERN" '
      /^##[[:space:]]/ {
        h = tolower($0)
        insec = (h ~ /^##[[:space:]]+implementation[[:space:]]+steps/) ? 1 : 0
        next
      }
      !insec { next }
      $0 ~ pat {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        print line
      }
    ' "$plan_md")"

    # `## Verification` topic TITLE lines only (not the whole section) — the canonical
    # `Topic N — …` grammar (mentor:plan-review's own wording); a hyphen is accepted too,
    # but a bare digit-led prose line ("Topic 3 greps for …", seen in real plans outside
    # `## Verification`) is not, since it carries neither delimiter after the number.
    br_topics="$(awk '
      /^##[[:space:]]/ {
        h = tolower($0)
        if (insec) exit
        insec = (h ~ /^##[[:space:]]+verification/) ? 1 : 0
        next
      }
      insec && ($0 ~ /^Topic[[:space:]]+[0-9]+[[:space:]]+—/ || $0 ~ /^Topic[[:space:]]+[0-9]+[[:space:]]+-[[:space:]]/) { print }
    ' "$plan_md")"

    echo "PLAN: ${slug}"
    echo "TITLE: ${br_title:-(untitled)}"
    echo "CONTEXT: ${br_context:-(none)}"
    echo
    echo "## Out of scope"
    if [ -n "$br_oos" ]; then printf '%s\n' "$br_oos"; else echo "(none)"; fi
    echo
    echo "## Steps (${br_ticked}/${br_total} ticked)"
    if [ -n "$br_steps" ]; then
      printf '%s\n' "$br_steps" | awk '{ printf "  %d: %s\n", NR, $0 }'
    else
      echo "(no steps found)"
    fi
    if [ "$brief_step_set" -eq 1 ]; then
      echo
      echo "## Step ${brief_step} — verbatim body"
      awk -v pat="$MENTOR_STEP_LINE_PATTERN" -v target="$brief_step" '
        /^##[[:space:]]/ {
          if (in_target) exit
          h = tolower($0)
          insec = (h ~ /^##[[:space:]]+implementation[[:space:]]+steps/) ? 1 : 0
          next
        }
        !insec { next }
        $0 ~ pat {
          if (in_target) exit
          count++
          if (count == target) in_target = 1
        }
        in_target { print }
      ' "$plan_md"
    fi
    echo
    echo "## Verification topics"
    if [ -n "$br_topics" ]; then printf '%s\n' "$br_topics"; else echo "(none)"; fi
    ;;

esac

exit 0
