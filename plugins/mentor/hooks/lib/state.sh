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
#   ├── plans/            # the .planning marker + one <slug>/ dir per plan topic:
#   │   └── <slug>/       #   plan.md (+ hidden .plan.md.opened sidecar)
#   │       ├── .state.json  # {"state","group","order","note"} — written ONLY via plan-state.sh
#   │       └── handoffs/ #   <ts>-<slug>.md; solved/superseded notes → handoffs/resolved/
#   ├── zooms/            # mentor:zoom artifacts — <subject-slug>/<topic>-<perspective>.html
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

# --- plan state (v2.4.0) ----------------------------------------------------
#
# Each plan dir carries a hidden `.state.json` sidecar:
#   {"state":"draft|approved|in_progress|implemented|failed|superseded",
#    "group":"<parent slug>"|null, "order":<n>|null, "note":"<free text>"}
# `group` is the slug of the plan that /plan-split replaced; standalone plans hold null.
#
# The sidecar is a CACHE, not the only truth. Reads go through
# mentor_plan_effective_state, which takes the more advanced of the stored state and
# the state derived from plan.md's ✅ step ticks — so a forgotten state write costs
# nothing, and pre-2.4.0 plan dirs read correctly with no migration. Writes go through
# hooks/plan-state.sh (the CLI); skills never hand-roll this JSON.

MENTOR_PLAN_STATES="draft approved in_progress implemented failed superseded"

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

# mentor_plan_state_file <plan_dir> — echo <plan_dir>/.state.json (never created here).
mentor_plan_state_file() {
  local d="${1:-}"
  if [ -z "$d" ]; then echo ""; return 0; fi
  echo "${d}/.state.json"
  return 0
}

# mentor_plan_state_field <plan_dir> <key> — echo the stored value of <key>
# (state|group|order|note), or empty when no sidecar / no jq / corrupt / unset / null.
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

# mentor_plan_tick_state <plan_md> — echo the state implied by the ✅ ticks that
# dispatch-agents appends as each step's `Done when:` passes: every step line in the
# `## Implementation steps` section ticked → implemented; some → in_progress; none or
# no recognizable steps → empty (no opinion). A step line is a numbered item (`3. …`)
# or a `Step 3 — …` line; both totals come from the same rule, so the ratio holds
# whatever the plan's step style.
mentor_plan_tick_state() {
  local md="${1:-}"
  if [ -z "$md" ] || [ ! -f "$md" ]; then echo ""; return 0; fi
  awk '
    /^##[[:space:]]/ {
      h = tolower($0)
      insec = (h ~ /^##[[:space:]]+implementation[[:space:]]+steps/) ? 1 : 0
      next
    }
    !insec { next }
    /^[[:space:]]*(-[[:space:]]+)?(\*\*)?([0-9]+\.|[Ss]tep[[:space:]]+[0-9]+)/ {
      total++
      if (index($0, "✅") > 0) ticked++
    }
    END {
      if (total == 0) exit 0
      if (ticked == total) print "implemented"
      else if (ticked > 0) print "in_progress"
    }
  ' "$md" 2>/dev/null || true
  return 0
}

# mentor_plan_state_rank <state> — ordering for "more advanced". `superseded` outranks
# everything (a split parent stays superseded however many ticks its body carries);
# `failed` ties with `in_progress` so a tie-break toward the stored value keeps it.
mentor_plan_state_rank() {
  case "${1:-}" in
    superseded)  echo 9 ;;
    implemented) echo 4 ;;
    failed)      echo 3 ;;
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

# mentor_plan_state_write <plan_dir> <state> [group] [order] [note] — upsert the
# sidecar (create-then-set: most plans have no sidecar yet). `group`/`order` persist
# when passed empty; `note` is REPLACED every time, so an empty note clears a stale
# failure reason. A corrupt sidecar is reset rather than left unwritable.
# jq has no in-place edit, so this is tmp-file + mv. A torn write leaves the sidecar
# unreadable, which reads back as "unknown" — recoverable, because a split child's
# isolation header carries the same group/order inside plan.md.
# Fail-soft: always status 0, echoes nothing; a bad state / missing jq writes nothing.
mentor_plan_state_write() {
  local d="${1:-}" state="${2:-}" group="${3:-}" order="${4:-}" note="${5:-}" f tmp
  [ -n "$d" ] && [ -d "$d" ] || return 0
  mentor_plan_state_valid "$state" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  f="${d}/.state.json"
  if [ ! -f "$f" ] || ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    printf '%s\n' '{}' > "$f" 2>/dev/null || return 0
  fi
  tmp="${f}.tmp.$$"
  if jq --arg s "$state" --arg g "$group" --arg o "$order" --arg n "$note" '{
        state: $s,
        group: (if $g == "" then (.group // null) else $g end),
        order: (if $o == "" then (.order // null) else ($o | tonumber? // null) end),
        note:  $n
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
