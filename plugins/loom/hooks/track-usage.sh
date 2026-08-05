#!/usr/bin/env bash
# track-usage.sh — SessionEnd (loom's ONLY hook).
#
# Opt-in usage indexer. When the user has run `/loom:track <plugin>`, this appends ONE JSONL line
# per finished session to $cfg/loom/learning/usage-index.jsonl recording how many usage markers each
# tracked+enabled plugin left in the session transcript. `/loom:learn` reads that index to skip
# scanning sessions it already knows about (chassis §K.5). Markers are counted on the session's
# INVOCATION SURFACE, never on raw transcript bytes — see invocation_surface() below.
#
# FAIL-SOFT CONTRACT: every exit path is `exit 0`. A session must NEVER fail to end because of
# tracking. No config / no jq / no transcript / malformed input / unreadable settings → exit 0
# (writing nothing, or an index line that errs toward keeping data — a 0-count line is harmless).
#
# Zero cost when nothing is tracked: the config fast-exit (step 2) returns in well under 10ms.

set -uo pipefail

cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
learn_dir="$cfg/loom/learning"
config="$learn_dir/config.json"
index="$learn_dir/usage-index.jsonl"
reg="$cfg/plugins/installed_plugins.json"
mkts="$cfg/plugins/known_marketplaces.json"

command -v jq >/dev/null 2>&1 || exit 0

# --- 1. read SessionEnd stdin ------------------------------------------------
INPUT="$(cat 2>/dev/null)" || exit 0
sid="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0
[ -z "$sid" ] && exit 0
tx="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)" || true
cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)" || true
[ -z "$cwd" ] && cwd="$PWD"

# The session's own project root (for per-session effective enablement). git toplevel, else cwd.
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"

# Resolve transcript if SessionEnd didn't hand one over: newest .jsonl under the hashed cwd.
if [ -z "$tx" ] || [ ! -e "$tx" ]; then
  hash="$(printf '%s' "$root" | sed 's/[/.]/-/g')"
  tx="$(ls -t "$cfg/projects/$hash"/*.jsonl 2>/dev/null | head -1)"
fi
[ -n "$tx" ] && [ -e "$tx" ] || exit 0

# --- 2. fast exit: nothing tracked ------------------------------------------
[ -f "$config" ] || exit 0
track_count="$(jq -r '(.track // []) | length' "$config" 2>/dev/null)" || exit 0
{ [ -z "$track_count" ] || [ "$track_count" = "0" ]; } && exit 0

# --- helpers ----------------------------------------------------------------

# enabled_state <settings-file> <key> → true | false | unset | absent | unreadable
#   false is falsy in jq, so probe membership with has() — NEVER `(.[$k] // "unset")`.
enabled_state() {
  local f="$1" key="$2" v
  [ -f "$f" ] || { printf 'absent'; return 0; }
  v="$(jq -r --arg k "$key" '(.enabledPlugins // {}) | if has($k) then (.[$k]|tostring) else "unset" end' "$f" 2>/dev/null)" \
    || { printf 'unreadable'; return 0; }
  [ -z "$v" ] && { printf 'unreadable'; return 0; }
  printf '%s' "$v"
}

# install_match <plugin@mkt> <root> → 0 (an install record covers this session's context) / 1
install_match() {
  local key="$1" r="$2"
  [ -f "$reg" ] || return 1
  jq -e --arg k "$key" --arg root "$r" '
    (.plugins[$k] // []) | any(
      .scope == "user"
      or ((.scope == "project" or .scope == "local") and ((.projectPath // "") == $root)))' \
    "$reg" >/dev/null 2>&1
}

# effective_enabled <plugin> <mkt> → 0 keep / 1 drop.  Precedence: project .local → project → user
#   settings; first file that MENTIONS the key wins (explicit false disables; explicit true enables).
#   Mentioned nowhere → install-registry fallback. Unreadable settings → keep (fail-open).
effective_enabled() {
  local plugin="$1" mkt="$2" key="${1}@${2}" f st
  for f in "$root/.claude/settings.local.json" "$root/.claude/settings.json" "$cfg/settings.json"; do
    st="$(enabled_state "$f" "$key")"
    case "$st" in
      true)       return 0 ;;
      false)      return 1 ;;
      unreadable) return 0 ;;   # can't confirm disabled → keep
      *)          : ;;          # absent | unset → consult the next file
    esac
  done
  install_match "$key" "$root" && return 0
  return 1
}

# DUPLICATION NOTE — marker_pattern() and invocation_surface() below are independent copies of chassis
#   §K.1/§K.2 (references/session-plugin-common.md). A hook cannot source a skill's reference doc, so
#   the two live apart and MUST stay behaviorally identical: this hook writes the usage index (§K.5)
#   that /loom:learn trusts as a fast path, so a divergence here silently re-opens the same bug in
#   discovery. Consolidate both into a shared shell library if one ever lands.

# marker_pattern <plugin> <mkt> — echo the §K.1 ERE, sourcing skill/command names from the plugin's
#   OWN marketplace install location (works from any cwd; never assumes any repo is present).
#   Command branches carry the CLOSING </command-name> tag: unlike `"skill":"…"` (whose quotes get
#   escaped the moment the text is nested in a JSON string), `<command-name>/…` is byte-identical
#   whether it is a real record or shell text building this very pattern.
marker_pattern() {
  local plugin="$1" mkt="$2" inst src dir pat bare cmds
  inst="$(jq -r --arg m "$mkt" '.[$m].installLocation // ""' "$mkts" 2>/dev/null)" || inst=""
  [ -z "$inst" ] && inst="$cfg/plugins/marketplaces/$mkt"
  src="$(jq -r --arg p "$plugin" '.plugins[]? | select(.name==$p) | .source // ""' \
         "$inst/.claude-plugin/marketplace.json" 2>/dev/null)" || src=""
  case "$src" in
    "" ) dir="$inst/plugins/$plugin" ;;
    /* ) dir="$src" ;;
    * )  dir="$inst/${src#./}" ;;
  esac
  pat="\"skill\":\"${plugin}:|<command-name>/${plugin}:[a-z0-9][a-z0-9-]*</command-name>"
  bare="$(ls "$dir/skills" 2>/dev/null | paste -sd'|' -)"
  [ -n "$bare" ] && pat="${pat}|\"skill\":\"(${bare})\""
  cmds="$(ls "$dir/commands" 2>/dev/null | sed 's/\.md$//' | paste -sd'|' -)"
  [ -n "$cmds" ] && pat="${pat}|<command-name>/(${plugin}:)?(${cmds})</command-name>"
  printf '%s' "$pat"
}

# invocation_surface <transcript> — emit ONLY the text where a genuine invocation can live (§K.2):
#   a Skill tool_use (read structurally, so key order never matters) and a slash-command envelope.
#   Everything else a transcript carries — Bash/Task tool_use inputs, tool_result bodies, echoed
#   transcripts, prose about a command — is text the session HANDLED, not usage.
invocation_surface() {
  jq -Rr '
    (fromjson? // empty) as $r
    | ( $r.message.content? | select(type == "array") | .[]?
        | select(.type == "tool_use" and .name == "Skill")
        | "\"skill\":\"" + (.input.skill? // "") + "\"" ),
      ( $r.message.content? | select(type == "string") | select(startswith("<command-")) )
  ' "$1" 2>/dev/null
}

# --- 3+4+5. per tracked plugin: enablement gate → count markers → collect ----
# Extract the invocation surface ONCE and match every plugin's pattern against that, not the raw
# transcript. Costs about as much as the single grep it replaces (~20ms on a 2MB transcript).
surface="$(mktemp "${TMPDIR:-/tmp}/loom-surface.XXXXXX" 2>/dev/null)" || surface=""
trap 'rm -f "${surface:-}" 2>/dev/null; exit 0' EXIT INT TERM   # exit 0 even on signal: FAIL-SOFT contract
have_surface=0
[ -n "$surface" ] && invocation_surface "$tx" > "$surface" 2>/dev/null && have_surface=1

# A transcript that parses to NOTHING is unreadable, not unused — an empty surface would otherwise be
# indistinguishable from "this session used no plugins". The probe stops at the first parseable
# record, so it costs one line on a healthy transcript and only walks a genuinely broken one.
[ "$have_surface" = 1 ] && [ -s "$tx" ] \
  && [ -z "$(jq -Rr '(fromjson? // empty) | "1"' "$tx" 2>/dev/null | head -1)" ] \
  && have_surface=0

# FAIL-SOFT: with no usable surface, record NO plugin keys rather than zeros. §K.5 reads a missing
# key as "the hook never evaluated this plugin — rescan", but a 0 as "definitely unused, skip
# forever" — so a false 0 here would silently drop the session from learning for good.
counts='{}'
if [ "$have_surface" = 1 ]; then
  while IFS=$'\t' read -r plugin mkt; do
    [ -z "$plugin" ] && continue
    effective_enabled "$plugin" "$mkt" || continue          # disabled for THIS session → skip
    pat="$(marker_pattern "$plugin" "$mkt")"
    n="$(command grep -cE "$pat" "$surface" 2>/dev/null)"; n=${n:-0}   # grep -c prints 0 AND exits 1 on no match
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    counts="$(printf '%s' "$counts" | jq -c --arg p "$plugin" --argjson n "$n" '. + {($p): $n}' 2>/dev/null)" || counts='{}'
  done < <(jq -r '(.track // [])[] | [.plugin, .marketplace] | @tsv' "$config" 2>/dev/null)
fi

# --- 6. session end timestamp: last transcript timestamp, else file mtime ----
end="$(tail -n 50 "$tx" 2>/dev/null | command grep -o '"timestamp":"[^"]*"' | tail -1 | cut -d'"' -f4)"
[ -z "$end" ] && end="$(date -u -r "$(stat -f %m "$tx" 2>/dev/null)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -z "$end" ] && end="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

# --- 7. append ONE index line (last line per sessionId wins at read time) -----
mkdir -p "$learn_dir" 2>/dev/null || exit 0
line="$(jq -c -n --arg sid "$sid" --arg tx "$tx" --arg end "$end" --arg cwd "$cwd" \
        --argjson plugins "$counts" \
        '{sessionId:$sid, tx:$tx, endTs:$end, cwd:$cwd, plugins:$plugins}' 2>/dev/null)" || exit 0
printf '%s\n' "$line" >> "$index" 2>/dev/null || exit 0
exit 0
