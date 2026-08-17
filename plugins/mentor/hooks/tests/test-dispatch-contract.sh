#!/usr/bin/env bash
# test-dispatch-contract.sh — regression tests for dispatch-contract.sh
# (PreToolUse:Task|Agent)
#
# Drives the hook with PreToolUse JSON built by jq (so prompt text with backticks/
# em-dashes never has to survive bash string interpolation) and asserts its three
# terminal outcomes: injected (JSON on stdout), passthrough (silent exit 0), and
# fail-soft (silent exit 0) across every branch the hook implements — wrong tool,
# already-injected prompt, malformed stdin, a missing/empty/unreadable sibling
# contract file (unreadable in both shapes: the .txt path being a directory, and
# a present non-empty file that's chmod 000), jq absent from PATH, an
# empty/missing prompt, and that injection never disturbs a sibling tool_input
# key. The contract-file-shape cases need an actual sibling-less/malformed copy
# of the hook (it resolves the file by its own directory, not an env var), so
# this suite stages four extra hook copies under $ROOT — the chmod 000 one has
# its permissions restored by the exit trap before cleanup, so a second run of
# this suite (or a stray `rm -rf` on $ROOT) never trips over it. The "no jq"
# case reuses the house pattern from test-context-gate.sh: feed stdin from a FILE
# (not a pipe) under a PATH with no jq, since the hook exits at the `command -v jq`
# guard before ever reading stdin. Also asserts that the quality line is
# role-independent: it is injected for every subagent_type — including
# read-only roles like Explore and Plan — and when no subagent_type is given
# at all, since the hook has no role branch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
HOOK="$HOOKS/dispatch-contract.sh"
CONTRACT="$HOOKS/dispatch-contract.txt"
for f in "$HOOK" "$CONTRACT"; do [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }; done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
BASH_BIN="$(command -v bash)"
ERRFILE="$ROOT/err"

NOJQ_DIR="$ROOT/nojq"; mkdir -p "$NOJQ_DIR"   # empty PATH dir → `command -v jq` fails

# Sibling-less / empty-contract copies of the hook, for the F/G cases below.
NOTXT_DIR="$ROOT/hooks-notxt"; mkdir -p "$NOTXT_DIR"; cp "$HOOK" "$NOTXT_DIR/"
EMPTYTXT_DIR="$ROOT/hooks-emptytxt"; mkdir -p "$EMPTYTXT_DIR"; cp "$HOOK" "$EMPTYTXT_DIR/"
: > "$EMPTYTXT_DIR/dispatch-contract.txt"

# Unreadable-contract-file copies, for the H/I cases below: one where the
# .txt path is itself a directory, one where it's a regular file present and
# non-empty but chmod 000. Both make `head -n 1 "$CONTRACT_FILE"` fail even
# though `[ -s "$CONTRACT_FILE" ]` already passed.
DIRTXT_DIR="$ROOT/hooks-dirtxt"; mkdir -p "$DIRTXT_DIR"; cp "$HOOK" "$DIRTXT_DIR/"
mkdir -p "$DIRTXT_DIR/dispatch-contract.txt"
UNREADTXT_DIR="$ROOT/hooks-unreadtxt"; mkdir -p "$UNREADTXT_DIR"; cp "$HOOK" "$UNREADTXT_DIR/"
cp "$CONTRACT" "$UNREADTXT_DIR/dispatch-contract.txt"
chmod 000 "$UNREADTXT_DIR/dispatch-contract.txt"

# Restore permissions before the rm -rf: a chmod 000 fixture must never be
# able to leave scratch behind (or foul a second run of this suite).
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

SENTINEL="$(head -n 1 "$CONTRACT")"

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
count_eq() {  # <expected-count> <needle> <haystack> — exact grep -c match
  local want="$1" needle="$2" haystack="$3" got
  got="$(printf '%s' "$haystack" | command grep -c -- "$needle" 2>/dev/null || true)"
  [ "$got" = "$want" ]
}
json_valid()   { printf '%s' "$1" | jq -e . >/dev/null 2>&1; }
field_eq() {    # <json> <jq-path> <expected>
  local got; got="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
  [ "$got" = "$3" ]
}
prompt_of()    { printf '%s' "$1" | jq -r '.hookSpecificOutput.updatedInput.prompt' 2>/dev/null; }
prompt_contains() { case "$(prompt_of "$1")" in *"$2"*) return 0;; *) return 1;; esac; }
first_line_is() { [ "$(prompt_of "$1" | head -n1)" = "$2" ]; }

mkinput() { jq -cn --arg tn "$1" --arg prompt "$2" '{tool_name: $tn, tool_input: {prompt: $prompt}}'; }
mkinput_role() { jq -cn --arg tn "$1" --arg prompt "$2" --arg role "$3" \
  '{tool_name: $tn, tool_input: {prompt: $prompt, subagent_type: $role}}'; }
run() {  # <json-stdin> → sets RC / OUT / ERR
  RC=0
  OUT="$(printf '%s' "$1" | "$BASH_BIN" "$HOOK" 2>"$ERRFILE")" || RC=$?
  ERR="$(cat "$ERRFILE")"
}

echo "== A. Injection: tool_name=Agent =="
run "$(mkinput Agent "do the thing")"
chk "Agent → exit 0"                       test "$RC" = "0"
chk "Agent → valid JSON on stdout"         json_valid "$OUT"
chk "Agent → hookEventName is PreToolUse"  field_eq "$OUT" '.hookSpecificOutput.hookEventName' PreToolUse
chk "Agent → prompt carries the sentinel"  prompt_contains "$OUT" "$SENTINEL"
chk "Agent → original prompt text kept"    prompt_contains "$OUT" "do the thing"
chk "Agent → quality line present"         prompt_contains "$OUT" "Implement the most practical and clean solution"

echo "== B. Injection: tool_name=Task =="
run "$(mkinput Task "do another thing")"
chk "Task → exit 0"                        test "$RC" = "0"
chk "Task → prompt carries the sentinel"   prompt_contains "$OUT" "$SENTINEL"
chk "Task → original prompt text kept"     prompt_contains "$OUT" "do another thing"

echo "== C. Idempotence: block already present → passthrough, exactly one occurrence =="
ORIG_PROMPT="$(printf 'intro text\n\n%s' "$(cat "$CONTRACT")")"
chk "fixture prompt has exactly 1 sentinel occurrence" count_eq 1 "$SENTINEL" "$ORIG_PROMPT"
run "$(mkinput Agent "$ORIG_PROMPT")"
chk "already-present → exit 0"             test "$RC" = "0"
chk "already-present → no stdout (tool_input left untouched, still 1 occurrence)" test -z "$OUT"
chk "already-present → no stderr"          test -z "$ERR"

echo "== D. Passthrough for non-dispatch tools =="
run "$(mkinput Bash "irrelevant")"
chk "Bash → exit 0"     test "$RC" = "0"
chk "Bash → no stdout"  test -z "$OUT"
chk "Bash → no stderr"  test -z "$ERR"
run "$(mkinput Edit "irrelevant")"
chk "Edit → exit 0"     test "$RC" = "0"
chk "Edit → no stdout"  test -z "$OUT"

echo "== E. Malformed stdin → fail-soft =="
RC=0; OUT="$(printf 'not json{{{' | "$BASH_BIN" "$HOOK" 2>"$ERRFILE")" || RC=$?
ERR="$(cat "$ERRFILE")"
chk "malformed stdin → exit 0"    test "$RC" = "0"
chk "malformed stdin → no stdout" test -z "$OUT"

echo "== F. Missing contract .txt (no sibling file) → fail-soft =="
RC=0; OUT="$(printf '%s' "$(mkinput Agent hi)" | "$BASH_BIN" "$NOTXT_DIR/dispatch-contract.sh" 2>"$ERRFILE")" || RC=$?
ERR="$(cat "$ERRFILE")"
chk "missing .txt → exit 0"    test "$RC" = "0"
chk "missing .txt → no stdout" test -z "$OUT"

echo "== G. Empty contract .txt → fail-soft =="
RC=0; OUT="$(printf '%s' "$(mkinput Agent hi)" | "$BASH_BIN" "$EMPTYTXT_DIR/dispatch-contract.sh" 2>"$ERRFILE")" || RC=$?
ERR="$(cat "$ERRFILE")"
chk "empty .txt → exit 0"    test "$RC" = "0"
chk "empty .txt → no stdout" test -z "$OUT"

echo "== H. Contract .txt path is a directory → fail-soft =="
RC=0; OUT="$(printf '%s' "$(mkinput Agent hi)" | "$BASH_BIN" "$DIRTXT_DIR/dispatch-contract.sh" 2>"$ERRFILE")" || RC=$?
ERR="$(cat "$ERRFILE")"
chk "dir-shaped .txt → exit 0"    test "$RC" = "0"
chk "dir-shaped .txt → no stdout" test -z "$OUT"

echo "== I. Contract .txt present, non-empty, but unreadable (chmod 000) → fail-soft =="
RC=0; OUT="$(printf '%s' "$(mkinput Agent hi)" | "$BASH_BIN" "$UNREADTXT_DIR/dispatch-contract.sh" 2>"$ERRFILE")" || RC=$?
ERR="$(cat "$ERRFILE")"
chk "unreadable .txt → exit 0"    test "$RC" = "0"
chk "unreadable .txt → no stdout" test -z "$OUT"

echo "== J. jq absent from PATH → fail-soft =="
mkinput Agent hi > "$ROOT/in.json"
RC=0; OUT="$(PATH="$NOJQ_DIR" "$BASH_BIN" "$HOOK" < "$ROOT/in.json" 2>"$ERRFILE")" || RC=$?
ERR="$(cat "$ERRFILE")"
chk "no jq → exit 0" test "$RC" = "0"
chk "no jq → silent" test -z "$OUT$ERR"

echo "== K. Empty / missing prompt → still injects cleanly, no crash =="
run "$(mkinput Agent "")"
chk "empty prompt → exit 0"                 test "$RC" = "0"
chk "empty prompt → valid JSON"             json_valid "$OUT"
chk "empty prompt → sentinel present"       prompt_contains "$OUT" "$SENTINEL"
chk "empty prompt → starts with quality line (no leading blank line)" \
    first_line_is "$OUT" "Implement the most practical and clean solution — never trade maintainability or reliability for implementation speed."
NOPROMPT="$(jq -cn --arg tn Agent '{tool_name: $tn, tool_input: {description: "d"}}')"
run "$NOPROMPT"
chk "missing prompt key → exit 0"           test "$RC" = "0"
chk "missing prompt key → sentinel present" prompt_contains "$OUT" "$SENTINEL"
chk "missing prompt key → description preserved" field_eq "$OUT" '.hookSpecificOutput.updatedInput.description' d

echo "== L. Sibling tool_input keys preserved untouched =="
SIBLING="$(jq -cn '{tool_name: "Task", tool_input: {prompt: "hello", description: "desc", subagent_type: "general-purpose", foo: "bar", nested: {a: 1, b: [1,2,3]}}}')"
run "$SIBLING"
chk "sibling keys → exit 0"                 test "$RC" = "0"
chk "sibling keys → description preserved"  field_eq "$OUT" '.hookSpecificOutput.updatedInput.description' desc
chk "sibling keys → subagent_type preserved" field_eq "$OUT" '.hookSpecificOutput.updatedInput.subagent_type' general-purpose
chk "sibling keys → foo preserved"          field_eq "$OUT" '.hookSpecificOutput.updatedInput.foo' bar
chk "sibling keys → nested object preserved" field_eq "$OUT" '.hookSpecificOutput.updatedInput.nested | tostring' '{"a":1,"b":[1,2,3]}'
chk "sibling keys → key set is exactly the 5 input keys" \
    field_eq "$OUT" '.hookSpecificOutput.updatedInput | keys | sort | tostring' '["description","foo","nested","prompt","subagent_type"]'

echo "== M. Quality line is role-independent =="
# An earlier design exempted read-only roles (e.g. Explore) from the
# solution-quality line, on the reasoning that it governs how something is
# built, not how it's found. That exemption was deliberately removed: the
# hook injects the line unconditionally, with no subagent_type branch. These
# assertions lock that decision so a future edit cannot quietly reintroduce
# a role carve-out.
run "$(mkinput_role Task "map the callers" Explore)"
chk "Explore → quality line present"  prompt_contains "$OUT" "Implement the most practical and clean solution"
chk "Explore → sentinel present"      prompt_contains "$OUT" "$SENTINEL"
run "$(mkinput_role Task "design the approach" Plan)"
chk "Plan → quality line present"     prompt_contains "$OUT" "Implement the most practical and clean solution"
run "$(mkinput Task "no role specified")"
chk "no subagent_type key → quality line present" prompt_contains "$OUT" "Implement the most practical and clean solution"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
