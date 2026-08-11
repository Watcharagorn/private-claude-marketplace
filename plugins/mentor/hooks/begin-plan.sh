#!/usr/bin/env bash
# begin-plan.sh — arm the mentor plan gate.
#
# Invoked by the /mentor:plan command body as its FIRST action, before any
# drafting. It writes THIS WORKTREE's gate marker, `.planning.<wt-id>` (v2.23.0
# — one marker per git worktree, via lib/state.sh's mentor_worktree_id /
# mentor_plan_marker), or the legacy repo-global bare `.planning` when no
# worktree id can be derived — which CLOSES the edit gate (plan-gate.sh) for
# that worktree (or, for the legacy marker, every worktree) and clears stale
# sidecars from a prior planning session.
# It runs as a normal Bash call and is allowed precisely because the gate never
# matches Bash.
#
# The marker's mtime is the SESSION START: approve-plan.sh only accepts a plan
# file NEWER than the marker, so a stale plan from a prior session can never
# release the gate.
#
# Optional $1: the slug this session is about to plan/resume (e.g. the slug
# named in `/mentor:plan <slug>`). Purely informational — used only to warn in
# the ARMED banner when that slug is already owned by a worktree with a live
# sibling marker; never required, never affects whether arming succeeds.
#
# Fail-soft: if we cannot resolve a git repo, print a notice and exit 0 — the
# skill still runs; the gate simply isn't armed outside a repo.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

target_slug="${1:-}"

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  echo "[mentor] Not inside a git repo — plan gate NOT armed (planning still proceeds)."
  exit 0
fi
plans_dir="$(mentor_plans_dir "$repo_root")"

# --- worktree id + own marker (v2.23.0) -------------------------------------
# Every worktree gets its own gate marker so parallel sessions in DIFFERENT
# worktrees never block each other; two sessions in the SAME worktree still
# serialize on the one marker (unchanged, intentional). Empty wt_id (git
# failure, `.git/` cwds, bare repos) means our own marker IS the legacy path —
# mentor_plan_marker's one fallback site — which is exactly why the legacy
# guard below is skipped in that case (see its comment).
wt_id="$(mentor_worktree_id "$(pwd)")"
marker="$(mentor_plan_marker "$plans_dir" "$wt_id")"
legacy_marker="$(mentor_plan_marker "$plans_dir" "")"
toplevel="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || true)"

# --- context gate (plan start) ---------------------------------------------
# begin-plan gets no hook stdin, so mentor_context_verdict locates the session
# transcript itself and measures it. Over the ask threshold the USER decides first:
# without a session bypass marker we print a CONTEXT: ASK directive (AskUserQuestion —
# hand off, or bypass and plan lean) and do NOT arm yet; with the marker the gate arms
# with a CONTEXT: HANDOFF advisory. The UserPromptSubmit gate never sees /mentor:plan
# (slash passthrough), so we check here. The same helper backs `plan-state.sh context`,
# which /mentor:track uses before it dispatches — so both entry points apply one policy.
# Fail-soft: unmeasurable → empty verdict → skip silently (like the not-a-repo grace).
context_warn=""
verdict="$(mentor_context_verdict "$repo_root" "$(pwd)")"
if [ -n "$verdict" ]; then
  read -r level tokens warn_at ask_at <<<"$verdict"
  case "$level" in
    HANDOFF)
      context_warn="CONTEXT: HANDOFF (~${tokens} tokens ≥ ${ask_at}) — critically large (gate bypassed this session): do not propose a zoom or plan-review; at the approval step lead with \"Hand off to next agent (Recommended)\"."
      ;;
    ASK)
      hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      cat <<EOF
CONTEXT: ASK (~${tokens} tokens ≥ ${ask_at})
[mentor] Plan gate NOT armed yet — the user decides first. Do NOT invoke the plan
skill yet; ask via AskUserQuestion (header "Context", two options):
  1. "Hand off & plan in a fresh session (Recommended)" — invoke
     Skill(skill="mentor:handoff-note") with the plan request as the focus, write the
     handoff doc, print its copy-paste /mentor:resume prompt, and STOP.
  2. "Proceed anyway (bypass + lean plan)" — run \`bash ${hook_dir}/bypass-context.sh\`,
     re-run \`bash ${hook_dir}/begin-plan.sh\`, then invoke the plan skill and follow
     the CONTEXT: HANDOFF advisory the re-run prints.
(Threshold: "context_block_tokens" in .mentor/config.json or MENTOR_CONTEXT_BLOCK_TOKENS;
disable entirely with MENTOR_CONTEXT_GATE=off.)
EOF
      exit 0
      ;;
    WARN)
      context_warn="CONTEXT: WARN (~${tokens} tokens ≥ ${warn_at}) — surface to the user; prefer \"Hand off to next agent\" at the approval step."
      ;;
  esac
fi

# --- legacy-marker guard (v2.23.0) ------------------------------------------
# A bare `.planning` (no worktree suffix) is a pre-upgrade repo-global marker,
# reserved to still block EVERY worktree until released or stale — fail-closed,
# because it may have been armed by a session this upgrade has no worktree
# attribution for. SKIPPED ENTIRELY when wt_id is empty: in that case our own
# marker already IS this same legacy path (mentor_plan_marker's one fallback
# site), so running this guard would refuse a session's own re-arm and turn
# the design back into an un-armable repo-global lock — the foreign-session
# guard below (which fail-softs on no session match) is what re-arming and the
# CONTEXT: ASK → bypass → re-run path depend on in that case.
if [ -n "$wt_id" ] && [ -f "$legacy_marker" ]; then
  if ! mentor_marker_stale "$legacy_marker"; then
    other_session="$(mentor_marker_field "$legacy_marker" session)"
    other_cwd="$(mentor_marker_field "$legacy_marker" cwd)"
    other_age="$(mentor_marker_age_min "$legacy_marker")"
    cat <<EOF
[mentor] Plan gate NOT armed — a legacy repo-wide plan gate marker is still active.
  marker:   ${legacy_marker}
  armed by: session ${other_session:-unknown} at ${other_cwd:-<unknown cwd>}
  age:      ~${other_age:-unknown}m ago (not yet stale)

This is a PRE-UPGRADE marker with no worktree attribution, so it fail-closed
blocks every worktree, not just this one. Wait for its owning session to
approve or release it, or ask the user to explicitly authorize removing
${legacy_marker} by hand.
EOF
    exit 0
  fi
  s_session="$(mentor_marker_field "$legacy_marker" session)"
  s_age="$(mentor_marker_age_min "$legacy_marker")"
  rm -f "$legacy_marker" 2>/dev/null || true
  echo "[mentor] Pruned stale legacy plan gate marker .planning (session ${s_session:-unknown}, age ~${s_age:-unknown}m) — released, proceeding."
fi

# --- foreign-marker guard -----------------------------------------------------
# begin-plan.sh used to truncate any existing marker unconditionally. If another
# session's plan was still being drafted (not yet approved), its plan.md silently
# stopped being newer than the marker the instant this ran, and approve-plan.sh
# would refuse it forever afterwards ("predates this planning session") — the
# other session's work stranded with no error until someone notices. Same-session
# re-arms (the CONTEXT: ASK → bypass-context.sh → re-run path above) are expected
# and harmless; only a marker armed by a genuinely DIFFERENT, still-live session is
# a collision worth stopping for. A marker with no metadata (pre-upgrade) or no
# session match can't be attributed — fail-soft, arm as before.
#
# This now operates on THIS WORKTREE's own marker (v2.23.0) — a linked
# worktree's session arms its own independent marker and never reaches this
# branch over another worktree's live session; only two sessions sharing the
# SAME worktree (or the empty-wt_id case, where "own marker" IS the legacy
# marker) still serialize here.
this_session="${CLAUDE_CODE_SESSION_ID:-nosession}"
if [ -f "$marker" ] && ! mentor_marker_stale "$marker"; then
  other_session="$(mentor_marker_field "$marker" session)"
  if [ -n "$other_session" ] && [ "$other_session" != "$this_session" ]; then
    other_cwd="$(mentor_marker_field "$marker" cwd)"
    other_age="$(mentor_marker_age_min "$marker")"
    cat <<EOF
[mentor] Plan gate NOT armed — another session's plan gate is already active.
  armed by: session ${other_session} at ${other_cwd:-<unknown cwd>}
  age:      ~${other_age:-unknown}m ago (not yet stale)
  marker:   ${marker}

Re-arming now would reset the marker: if that session's plan.md isn't approved
yet, approve-plan.sh will then refuse it ("predates this planning session"),
silently stranding its work. This marker is scoped to THIS worktree only — a
linked worktree's own session arms its own independent marker and is never
blocked by this one; this collision means another session shares THIS SAME
worktree (or no worktree id could be derived here at all).

Ask the user to confirm before proceeding — either wait for that session to
finish/approve, or have them explicitly authorize overriding it.
EOF
    exit 0
  fi
fi

mentor_ensure_private_dir "$(mentor_state_dir "$repo_root")" "$plans_dir"
mentor_ensure_gitignore "$(mentor_state_dir "$repo_root")"

# --- stale sibling marker prune (v2.23.0) -----------------------------------
# Any OTHER worktree's `.planning.<wt-id>` marker gone stale is pruned here —
# by ANY worktree's arm, not just its own — so an abandoned sibling gate never
# outlives its usefulness. This IS releasing that sibling's gate, so per the
# never-release-silently doctrine (plan-gate.sh) it always prints a named
# notice. `2>/dev/null || true` guards the whole construct: mentor_ensure_
# private_dir above is fail-soft and may not have created plans_dir on an
# unwritable path, and a bare `find` on a missing dir aborts under this
# script's `set -e`. The glob `.planning.*` requires a dot-suffix after
# "planning" and so never matches the bare legacy `.planning` marker (handled
# above, not here) — verified. Our OWN marker is excluded too: if it happens
# to be stale, it's about to be overwritten below anyway, not "released".
while IFS= read -r stale; do
  [ -n "$stale" ] || continue
  [ "$stale" = "$marker" ] && continue
  suffix="${stale##*/.planning.}"
  s_session="$(mentor_marker_field "$stale" session)"
  s_age="$(mentor_marker_age_min "$stale")"
  rm -f "$stale" 2>/dev/null || true
  echo "[mentor] Pruned stale sibling plan gate marker .planning.${suffix} (session ${s_session:-unknown}, age ~${s_age:-unknown}m) — released."
done < <(find "$plans_dir" -maxdepth 1 -name '.planning.*' -mmin "+${MENTOR_PLAN_MARKER_STALE_MIN}" 2>/dev/null || true)

# One-shot migration (v2.2.0): flat <slug>.md + <slug>-*.html → <slug>/plan.md +
# <slug>/zoom/<topic>-<perspective>.html. Longest slug first, so "auth-retry"'s
# zooms are never captured by a shorter "auth" plan. Orphan html with no matching
# .md is left in place (harmless, gitignored).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  slug="$(basename "$f" .md)"
  mentor_ensure_private_dir "$(mentor_state_dir "$repo_root")" "${plans_dir}/${slug}"
  mv -n "$f" "${plans_dir}/${slug}/plan.md" 2>/dev/null || true
  for h in "${plans_dir}/${slug}-"*.html; do
    [ -f "$h" ] || continue
    mentor_ensure_private_dir "$(mentor_state_dir "$repo_root")" "${plans_dir}/${slug}/zoom"
    base="${h##*/}"
    mv -n "$h" "${plans_dir}/${slug}/zoom/${base#"$slug"-}" 2>/dev/null || true
  done
done < <(ls "${plans_dir}"/*.md 2>/dev/null | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- || true)

# One-shot relocation (v2.12.0): zoom artifacts moved out of the per-plan dirs
# into the flat zooms tree — plans/<slug>/zoom/*.html → zooms/<slug>/ (the
# mentor:zooming skill's plan-slug contract). Sidecars move too; mv -n never
# clobbers; the emptied zoom/ dir is removed. Runs AFTER the v2.2.0 migration
# above, so freshly-migrated flat zooms take both hops in one arm. Idempotent.
zooms_dir="$(mentor_state_dir "$repo_root")/zooms"
for zdir in "${plans_dir}"/*/zoom; do
  [ -d "$zdir" ] || continue
  slug="$(basename "$(dirname "$zdir")")"
  mentor_ensure_private_dir "$(mentor_state_dir "$repo_root")" "${zooms_dir}/${slug}"
  for f in "$zdir"/*.html "$zdir"/.*.opened; do
    [ -e "$f" ] || continue
    mv -n "$f" "${zooms_dir}/${slug}/" 2>/dev/null || true
  done
  rmdir "$zdir" 2>/dev/null || true
done

# Clear ".opened" sidecars (dot-hidden beside plans and zooms; legacy flat ones
# swept too): plan/zoom paths are slug-derived, so a stale sidecar from a prior
# session would suppress plan-open.sh's first-creation open for the same slug.
# Ownership-scoped (v2.23.0): a plan dir owned by a DIFFERENT, still-live
# worktree must not have its sidecars swept out from under it — only unowned
# or THIS-worktree-owned plan/zoom dirs are cleared. Zoom dirs carry no sidecar
# of their own: a zoom dir's owner resolves via the plan-slug contract —
# plans/<same-slug>'s owner when that plan dir exists, else unowned. Tour
# sidecars under plans/<slug>/tour/ inherit the plan dir's owner for free,
# because each plan dir is swept with its OWN recursive `find` (which descends
# into tour/ on its own) rather than one flat find over all of plans_dir.
for pd in "$plans_dir"/*/; do
  [ -d "$pd" ] || continue
  pd="${pd%/}"
  pd_owner="$(mentor_plan_owner "$pd")"
  if [ -z "$pd_owner" ] || [ "$pd_owner" = "$wt_id" ]; then
    find "$pd" \( -name '*.opened' -o -name '.*.opened' \) -delete 2>/dev/null || true
  fi
done
for zd in "$zooms_dir"/*/; do
  [ -d "$zd" ] || continue
  zd="${zd%/}"
  zd_owner=""
  [ -d "${plans_dir}/$(basename "$zd")" ] && zd_owner="$(mentor_plan_owner "${plans_dir}/$(basename "$zd")")"
  if [ -z "$zd_owner" ] || [ "$zd_owner" = "$wt_id" ]; then
    find "$zd" \( -name '*.opened' -o -name '.*.opened' \) -delete 2>/dev/null || true
  fi
done
# Legacy flat .opened (pre-v2.2.0 layout: <slug>.md.opened directly under
# plans_dir/zooms_dir, no slug dir to carry ownership) — always cleared.
find "$plans_dir" -maxdepth 1 \( -name '*.opened' -o -name '.*.opened' \) -delete 2>/dev/null || true
find "$zooms_dir" -maxdepth 1 \( -name '*.opened' -o -name '.*.opened' \) -delete 2>/dev/null || true

# Metadata body, not an empty file: session + cwd + worktree let a blocked
# agent (plan-gate.sh's deny path) tell "I armed this myself and forgot to
# approve" from "a different, still-live session/worktree owns this" without
# hand-rolled ls/find forensics. Nothing reads the marker's content besides
# mentor_marker_field/mentor_marker_age_min (every other reader uses
# -f/-e/-nt/-newer/-mmin), and mtime — the field approve-plan.sh's staleness
# check depends on — is still set by this one write, same as `: >` before it.
{
  echo "session=${this_session}"
  echo "cwd=$(pwd)"
  echo "worktree=${toplevel}"
} > "$marker"

cat <<EOF
[mentor] Plan phase ARMED.
  marker: ${marker}
  edits:  repo source writes are now BLOCKED until the plan is approved
          (plan-gate.sh — holds even under bypassPermissions); this marker is
          scoped to THIS worktree only.

Now follow the plan skill. Do NOT edit repo files until approval.
EOF

# Informational sibling-marker lines (v2.23.0) — a live marker in another
# worktree never blocks THIS worktree's gate, but the model should still know
# it exists. Additionally, when $1 named a slug that ALREADY exists and is
# owned by that sibling worktree, WARN of a same-slug collision — this is the
# protection the old repo-global guard used to provide for free, now that
# siblings arm independently.
target_owner=""
if [ -n "$target_slug" ] && [ -d "${plans_dir}/${target_slug}" ]; then
  target_owner="$(mentor_plan_owner "${plans_dir}/${target_slug}")"
fi
while IFS= read -r lm; do
  [ -n "$lm" ] || continue
  [ "$lm" = "$marker" ] && continue
  s_suffix="${lm##*/.planning.}"
  s_session="$(mentor_marker_field "$lm" session)"
  s_age="$(mentor_marker_age_min "$lm")"
  echo "  also armed elsewhere: ${s_suffix} (session ${s_session:-unknown}, age ${s_age:-unknown}min) — independent gate, does not block this worktree"
  if [ -n "$target_owner" ] && [ "$s_suffix" = "$target_owner" ]; then
    echo "  WARNING: slug '${target_slug}' is owned by worktree ${target_owner}, whose marker .planning.${s_suffix} is live — two worktrees may be drafting the same slug concurrently."
  fi
done < <(mentor_live_markers "$plans_dir")

[ -n "$context_warn" ] && echo "$context_warn"

# The mode is only the APPROVAL-GATE DEFAULT — it decides which option the
# Step-6 approval question lists first; both outcomes are always offered.
# Never ask the user to pick a mode upfront.
mode="$(mentor_get_mode "$repo_root")"
case "$mode" in
  plan-only)
    echo "MODE: plan-only"
    echo '[mentor] Approval default: "Deliver plan only" listed first ("Proceed" always offered).'
    ;;
  "")
    echo "MODE: UNSET (default: plan)"
    echo '[mentor] No approval default persisted — "Proceed" listed first. Set one with /mentor:mode.'
    ;;
  *)
    echo "MODE: ${mode}"
    echo '[mentor] Approval default: "Proceed" listed first ("Deliver plan only" always offered).'
    ;;
esac
exit 0
