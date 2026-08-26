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

# 1 — a fresh project: plain directories, nothing to preserve.
T=$(mktemp -d)
"$INSTALL" "$T" >/dev/null 2>&1
for s in $SKILLS; do
  [ -f "$T/.claude/skills/$s/SKILL.md" ] || fail "plain layout: $s/SKILL.md missing"
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
         super-board-deps.sh super-board-merge-gate.sh \
         super-review-file-refactor.sh super-qa-file-bug.sh; do
  [ -x "$T/.claude/bin/$s" ] || fail "$s was not installed, or is not executable"
done
rm -rf "$T"

echo "PASS: test-install.sh (5 scenarios)"
