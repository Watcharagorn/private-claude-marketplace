#!/usr/bin/env bash
# test-skill-command-collision.sh — regression guard for command/skill name collisions.
#
# A plugin's `commands/<n>.md` and `skills/<n>/` must NEVER share the name <n>.
# When they do, `Skill({"skill": "mentor:<n>"})` resolves to the COMMAND file and the
# skill body is UNREACHABLE: the first call returns the command's own text (which
# self-referentially says "call the skill"), and the retry returns "already loaded
# above; instructions unchanged". Two things break, silently:
#
#   1. The SKILL.md never loads, so every mandatory step inside it is skipped — in the
#      session that found this (12887641, lines 18-20 and 219-226), `resume`'s
#      secret-scan and gate/PR verification and `handoff`'s `CHECK:` self-verification
#      all never ran, while the model reported success.
#   2. The skill's `description:` is shadowed out of the model-visible skill listing by
#      the command's, so the skill can never be reached conversationally either — the
#      trigger phrases the author wrote are dead text.
#
# Nine pairs collided up to v2.17.0 (constitution defer handoff merge plan resume ship
# tour zoom); v2.18.0 renamed every skill away from its command name. The two pairs that
# were already split (grill/grilling, track/plan-track) are the control: they delivered
# their skill body on the first call. This test fails if the defect ever comes back.
#
# Prose cannot enforce this — the colliding commands each CARRIED a documented fallback
# ("if that call returns this command's own text, read the file directly") and the model
# ignored it twice in one session. Hence a test.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
CMD_DIR="$PLUGIN_DIR/commands"
SKILL_DIR="$PLUGIN_DIR/skills"
[ -d "$CMD_DIR" ]   || { echo "FATAL: commands/ not found at $CMD_DIR" >&2; exit 1; }
[ -d "$SKILL_DIR" ] || { echo "FATAL: skills/ not found at $SKILL_DIR" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }

echo "== A. no commands/<n>.md shares its name with skills/<n>/ =="
collisions=0
for f in "$CMD_DIR"/*.md; do
  [ -f "$f" ] || continue
  n="$(basename "$f" .md)"
  if [ -d "$SKILL_DIR/$n" ]; then
    collisions=$((collisions+1))
    printf '       collision: commands/%s.md  <->  skills/%s/\n' "$n" "$n"
  fi
done
if [ "$collisions" = 0 ]; then
  ok "every command name differs from every skill name"
else
  bad "$collisions command/skill name collision(s) — the skill body is unreachable and its description is shadowed; rename the SKILL (the command keeps its user-facing name)"
fi

echo "== B. every skill's frontmatter name matches its directory =="
mismatch=0
for d in "$SKILL_DIR"/*/; do
  [ -f "$d/SKILL.md" ] || continue
  dn="$(basename "$d")"
  fn="$(sed -n 's/^name:[[:space:]]*//p' "$d/SKILL.md" | head -1)"
  if [ "$dn" != "$fn" ]; then
    mismatch=$((mismatch+1))
    printf '       mismatch: skills/%s/ declares name: %s\n' "$dn" "${fn:-<missing>}"
  fi
done
if [ "$mismatch" = 0 ]; then
  ok "all skill frontmatter names match their directory"
else
  bad "$mismatch skill(s) declare a frontmatter name that differs from the directory — a rename left the frontmatter behind"
fi

echo "== C. no command or skill points at a skill name that does not exist =="
missing=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  [ -d "$SKILL_DIR/$ref" ] && continue
  missing=$((missing+1))
  printf '       dead skill target: mentor:%s\n' "$ref"
  grep -rn "mentor:$ref\"" "$CMD_DIR" "$SKILL_DIR" "$PLUGIN_DIR/hooks" 2>/dev/null \
    | sed "s#^$PLUGIN_DIR/#         #" | head -3
done < <(
  grep -rhoE 'skill"?[:=] ?"mentor:[a-z0-9-]+"' "$CMD_DIR" "$SKILL_DIR" "$PLUGIN_DIR/hooks" 2>/dev/null \
    | sed -E 's/.*"mentor:([a-z0-9-]+)"/\1/' | sort -u
)
if [ "$missing" = 0 ]; then
  ok "every Skill(skill=\"mentor:…\") target resolves to a skills/ directory"
else
  bad "$missing Skill() target(s) name a skill that does not exist — a rename missed a call site"
fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
