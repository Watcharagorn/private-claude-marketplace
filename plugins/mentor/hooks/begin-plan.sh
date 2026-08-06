#!/usr/bin/env bash
# begin-plan.sh — arm the mentor plan gate.
#
# Invoked by the /mentor:plan command body as its FIRST action, before any
# drafting. It writes the repo-scoped `.planning` marker (which CLOSES the edit
# gate — plan-gate.sh) and clears stale sidecars from a prior planning session.
# It runs as a normal Bash call and is allowed precisely because the gate never
# matches Bash.
#
# The marker's mtime is the SESSION START: approve-plan.sh only accepts a plan
# file NEWER than the marker, so a stale plan from a prior session can never
# release the gate.
#
# Fail-soft: if we cannot resolve a git repo, print a notice and exit 0 — the
# skill still runs; the gate simply isn't armed outside a repo.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  echo "[mentor] Not inside a git repo — plan gate NOT armed (planning still proceeds)."
  exit 0
fi
plans_dir="$(mentor_plans_dir "$repo_root")"

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
this_session="${CLAUDE_CODE_SESSION_ID:-nosession}"
marker="${plans_dir}/.planning"
if [ -f "$marker" ] && ! mentor_marker_stale "$marker"; then
  other_session="$(mentor_marker_field "$marker" session)"
  if [ -n "$other_session" ] && [ "$other_session" != "$this_session" ]; then
    other_cwd="$(mentor_marker_field "$marker" cwd)"
    other_age="$(mentor_marker_age_min "$marker")"
    cat <<EOF
[mentor] Plan gate NOT armed — another session's plan gate is already active.
  armed by: session ${other_session} at ${other_cwd:-<unknown cwd>}
  age:      ~${other_age:-unknown}m ago (not yet stale)

Re-arming now would reset the marker: if that session's plan.md isn't approved
yet, approve-plan.sh will then refuse it ("predates this planning session"),
silently stranding its work. This repo shares one plan gate across every linked
git worktree (see README "Known limitations"), so this may be a sibling
worktree's live session, not a stray.

Ask the user to confirm before proceeding — either wait for that session to
finish/approve, or have them explicitly authorize overriding it.
EOF
    exit 0
  fi
fi

mentor_ensure_private_dir "$(mentor_state_dir "$repo_root")" "$plans_dir"
mentor_ensure_gitignore "$(mentor_state_dir "$repo_root")"

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
find "$plans_dir" "$zooms_dir" \( -name '*.opened' -o -name '.*.opened' \) -delete 2>/dev/null || true

# Metadata body, not an empty file: session + cwd let a blocked agent (plan-gate.sh's
# deny path) tell "I armed this myself and forgot to approve" from "a different,
# still-live session owns this" without hand-rolled ls/find forensics. Nothing reads
# the marker's content besides mentor_marker_field/mentor_marker_age_min (every other
# reader uses -f/-e/-nt/-newer/-mmin), and mtime — the field approve-plan.sh's
# staleness check depends on — is still set by this one write, same as `: >` before it.
{
  echo "session=${this_session}"
  echo "cwd=$(pwd)"
} > "$marker"

cat <<EOF
[mentor] Plan phase ARMED.
  marker: ${plans_dir}/.planning
  edits:  repo source writes are now BLOCKED until the plan is approved
          (plan-gate.sh — holds even under bypassPermissions).

Now follow the plan skill. Do NOT edit repo files until approval.
EOF

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
