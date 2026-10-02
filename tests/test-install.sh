#!/usr/bin/env bash
# Tests install.sh against the three target layouts it can meet.
#
# THIS FILE EXISTS BECAUSE INSTALL.SH ONCE DELETED 190 DIRECTORIES.
#
# On 2026-08-20 a symlink-aware install path resolved its destination by hand:
#
#   resolved=$(cd "$(dirname "$dest")" && cd "$(readlink "$dest")" && pwd)
#
# `cd ""` SUCCEEDS in bash. It is a no-op that returns 0 and leaves you where you
# were. So when `readlink` produced nothing, `resolved` became the PARENT —
# .claude/skills — and the `rm -rf "$dest"/*` that followed emptied the user's
# entire skills tree rather than one skill's contents.
#
# Every scenario below plants decoy directories beside the four skills and
# asserts they are still there afterwards. An installer is allowed to fail; it is
# never allowed to take the neighbours with it.
set -euo pipefail
cd "$(dirname "$0")"
INSTALL="../install.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
plant_decoys() { for d in decoy-one decoy-two decoy-three; do mkdir -p "$1/.claude/skills/$d"; touch "$1/.claude/skills/$d/SKILL.md"; done; }
decoys_intact() { [ "$(ls "$1/.claude/skills" | grep -c '^decoy')" -eq 3 ]; }

SKILLS="super-board super-build super-qa super-review"
ALL_SKILLS="$SKILLS super-collect super-refine visual arch-loop cleanup-wt"

# 1 — a fresh project: plain directories, nothing to preserve. Every primary and
#     secondary skill lands, and both workflows.
T=$(mktemp -d)
"$INSTALL" "$T" >/dev/null 2>&1
for s in $ALL_SKILLS; do
  [ -f "$T/.claude/skills/$s/SKILL.md" ] || fail "plain layout: $s/SKILL.md missing"
done
for w in super-board-wave.js super-refine.js; do
  [ -f "$T/.claude/workflows/$w" ] || fail "workflow $w was not installed"
done
rm -rf "$T"

# 2 — a project that symlinks .claude/skills/<name> at a real tree elsewhere.
#     The symlink must survive, the content must land at the target, and the
#     neighbours must be untouched.
T=$(mktemp -d)
mkdir -p "$T/.claude/skills"
for s in $SKILLS; do
  mkdir -p "$T/.agents/skills/$s"
  ( cd "$T/.claude/skills" && ln -s "../../.agents/skills/$s" "$s" )
done
plant_decoys "$T"
"$INSTALL" "$T" >/dev/null 2>&1
for s in $SKILLS; do
  [ -L "$T/.claude/skills/$s" ] || fail "symlink layout: $s stopped being a symlink"
  [ -f "$T/.agents/skills/$s/SKILL.md" ] || fail "symlink layout: $s content did not reach the real path"
done
decoys_intact "$T" || fail "symlink layout: DECOYS DESTROYED — the 2026-08-20 regression is back"
rm -rf "$T"

# 3 — a symlink pointing nowhere. Skip it and say so; never guess, never delete.
T=$(mktemp -d)
mkdir -p "$T/.claude/skills"
( cd "$T/.claude/skills" && ln -s ../../nowhere/super-board super-board )
plant_decoys "$T"
OUT=$("$INSTALL" "$T" 2>&1 || true)
echo "$OUT" | grep -q "pointing nowhere" || fail "a dangling symlink should be reported, got: $OUT"
decoys_intact "$T" || fail "dangling symlink: DECOYS DESTROYED"
rm -rf "$T"

# 4 — the guard of last resort. Even if resolution goes wrong, a destination that
#     is not named after the skill is refused before anything is removed.
T=$(mktemp -d)
mkdir -p "$T/.claude/skills" "$T/elsewhere"
( cd "$T/.claude/skills" && ln -s ../../elsewhere super-board )
plant_decoys "$T"
OUT=$("$INSTALL" "$T" 2>&1 || true)
echo "$OUT" | grep -q "which is not a super-board directory" \
  || fail "a mis-resolved destination should be refused by name, got: $OUT"
[ "$(ls "$T/elsewhere" | wc -l | tr -d ' ')" -eq 0 ] || fail "the refused destination must not be written to"
decoys_intact "$T" || fail "mis-resolved destination: DECOYS DESTROYED"
rm -rf "$T"

# 5 — every dispatcher script the skills reference is actually shipped. A verb
#     whose script was never installed fails only when a user reaches for it.
T=$(mktemp -d)
"$INSTALL" "$T" >/dev/null 2>&1
for s in super-board-run.sh super-board-stop.sh super-board-wave-plan.sh \
         super-board-deps.sh super-board-merge-gate.sh super-board-usage.sh \
         super-review-file-refactor.sh super-qa-file-bug.sh; do
  [ -x "$T/.claude/bin/$s" ] || fail "$s was not installed, or is not executable"
done
rm -rf "$T"

# 6 — guard hooks: scripts copied, settings merged into an existing file without
#     losing its keys or hooks, backed up first, and a second run adds nothing.
T=$(mktemp -d)
mkdir -p "$T/.claude"
cat > "$T/.claude/settings.json" <<'JSON'
{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo mine"}]}],"Stop":[{"hooks":[{"type":"command","command":"echo stop"}]}]}}
JSON
"$INSTALL" "$T" >/dev/null 2>&1
for h in guard-worktree-path.py guard-secrets.py guard-key-literals.py; do
  [ -f "$T/.claude/hooks/$h" ] || fail "hook $h was not installed"
done
S="$T/.claude/settings.json"
jq -e '.permissions.allow == ["Bash(ls:*)"]' "$S" >/dev/null || fail "existing permissions were lost"
jq -e '[.hooks.PreToolUse[].hooks[].command] | index("echo mine") != null' "$S" >/dev/null || fail "existing PreToolUse hook was lost"
jq -e '.hooks.Stop[0].hooks[0].command == "echo stop"' "$S" >/dev/null || fail "existing Stop hook was lost"
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash")] | length == 1' "$S" >/dev/null || fail "Bash matcher entry duplicated"
for h in guard-worktree-path guard-secrets guard-key-literals; do
  jq -e --arg h "$h" '[.hooks[][].hooks[].command | select(contains($h))] | length > 0' "$S" >/dev/null || fail "$h not wired in settings"
done
ls "$T/.claude/" | grep -q '^settings.json.bak-' || fail "no backup written before changing settings.json"
BEFORE=$(cat "$S")
OUT=$("$INSTALL" "$T" 2>&1)
[ "$(cat "$S")" = "$BEFORE" ] || fail "a second install changed settings.json"
echo "$OUT" | grep -q "already present" || fail "a second install should report nothing to change, got: $OUT"
jq -e '[.hooks[] | [.[].hooks[].command] as $c | ($c | length) == ($c | unique | length)] | all' "$S" >/dev/null \
  || fail "a hook command appears twice in one event"
rm -rf "$T"

# 7 — --no-hooks: no hook scripts, no settings.json written.
T=$(mktemp -d)
"$INSTALL" --no-hooks "$T" >/dev/null 2>&1
[ ! -e "$T/.claude/hooks" ] || fail "--no-hooks still installed hooks"
[ ! -e "$T/.claude/settings.json" ] || fail "--no-hooks still wrote settings.json"
[ -f "$T/.claude/skills/super-board/SKILL.md" ] || fail "--no-hooks must still install the skills"
rm -rf "$T"

# 8 — a settings.json that is not valid JSON is left exactly as it was.
T=$(mktemp -d)
mkdir -p "$T/.claude"; printf '{ not json' > "$T/.claude/settings.json"
OUT=$("$INSTALL" "$T" 2>&1 || true)
[ "$(cat "$T/.claude/settings.json")" = "{ not json" ] || fail "invalid settings.json was modified"
echo "$OUT" | grep -q "not valid JSON" || fail "invalid settings.json should be reported, got: $OUT"
rm -rf "$T"

# 9 — the snippet the installer merges is the one hooks/README.md documents.
python3 - ../hooks/README.md ../hooks/settings-snippet.json <<'PY' || fail "hooks/README.md snippet and hooks/settings-snippet.json differ"
import json, re, sys
doc = re.search(r"```json\n(.*?)```", open(sys.argv[1]).read(), re.S).group(1)
sys.exit(0 if json.loads(doc) == json.load(open(sys.argv[2])) else 1)
PY

echo "PASS: test-install.sh (9 scenarios)"
