#!/usr/bin/env bash
# Tests install.sh against plain, linked, and self-vendored target layouts.
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
ALL_SKILLS="$SKILLS super-collect ui-refine-loop visual git-sync"

# 1 — a fresh project: plain directories, nothing to preserve. Every primary and
#     secondary skill lands, and both workflows.
T=$(mktemp -d)
"$INSTALL" "$T" >/dev/null 2>&1
for s in $ALL_SKILLS; do
  [ -f "$T/.claude/skills/$s/SKILL.md" ] || fail "plain layout: $s/SKILL.md missing"
done
for w in super-board-wave.js ui-refine-loop.js; do
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

# 4b — a vendored pack is already exposed through two layers of skill links.
#      Refreshing it must preserve the source and both links, on repeated runs.
T=$(mktemp -d)
PACK="$T/_skills/vendor/super-board"
mkdir -p "$PACK" "$T/.agents/skills" "$T/.claude/skills"
cp -R ../install.sh ../VERSION ../skills ../scripts ../workflows ../hooks "$PACK/"
for s in $ALL_SKILLS; do
  ln -s "../../_skills/vendor/super-board/skills/$s" "$T/.agents/skills/$s"
  ln -s "../../.agents/skills/$s" "$T/.claude/skills/$s"
done
plant_decoys "$T"
for run in 1 2; do
  OUT=$("$PACK/install.sh" --no-hooks "$T" 2>&1) || fail "self-vendored refresh failed: $OUT"
  diff -qr ../skills "$PACK/skills" >/dev/null || fail "self-vendored refresh changed the source skills"
  for s in $ALL_SKILLS; do
    [ -L "$T/.claude/skills/$s" ] && [ -L "$T/.agents/skills/$s" ] \
      || fail "self-vendored refresh replaced a link for $s"
    [ -f "$T/.claude/skills/$s/SKILL.md" ] || fail "self-vendored refresh lost $s"
  done
  decoys_intact "$T" || fail "self-vendored refresh: DECOYS DESTROYED"
done
rm -rf "$T"

# 4c — individual helper links also point into the vendored pack. Both the full
#      hook install and the push-guard-only path must tolerate the same files.
T=$(mktemp -d)
PACK="$T/_skills/vendor/super-board"
mkdir -p "$PACK" "$T/.claude/bin" "$T/.claude/workflows" "$T/.claude/hooks"
cp -R ../install.sh ../VERSION ../skills ../scripts ../workflows ../hooks "$PACK/"
for group in scripts workflows hooks; do
  case "$group" in scripts) dest=bin ;; *) dest="$group" ;; esac
  for src in "$PACK/$group/"*; do
    [ -f "$src" ] || continue
    ln -s "$src" "$T/.claude/$dest/$(basename "$src")"
  done
done
for flags in '--protect-main' '--no-hooks --protect-main'; do
  OUT=$("$PACK/install.sh" $flags "$T" 2>&1) || fail "linked helper refresh failed: $OUT"
  for group in scripts workflows hooks; do
    diff -qr "../$group" "$PACK/$group" >/dev/null || fail "linked helper refresh changed source $group"
  done
  for file in bin/super-board-run.sh workflows/super-board-wave.js hooks/guard-protected-push.py; do
    [ -L "$T/.claude/$file" ] || fail "linked helper refresh replaced $file"
    [ -s "$T/.claude/$file" ] || fail "linked helper refresh emptied $file"
  done
done
rm -rf "$T"

# 4d — a linked destination contains the pack itself. Refuse before clearing it.
T=$(mktemp -d)
PACK="$T/super-board/vendor"
mkdir -p "$PACK" "$T/.claude/skills"
cp -R ../install.sh ../VERSION ../skills ../scripts ../workflows ../hooks "$PACK/"
ln -s "$T/super-board" "$T/.claude/skills/super-board"
plant_decoys "$T"
if OUT=$("$PACK/install.sh" --no-hooks "$T" 2>&1); then
  fail "a destination containing the source pack was accepted"
fi
diff -qr ../skills "$PACK/skills" >/dev/null || fail "overlapping destination erased source skills"
diff -qr ../scripts "$PACK/scripts" >/dev/null || fail "overlapping destination erased source scripts"
echo "$OUT" | grep -q 'overlap' || fail "source overlap should be explained: $OUT"
decoys_intact "$T" || fail "overlapping destination: DECOYS DESTROYED"
rm -rf "$T"

# 4e — copying a skill into a directory within itself is unsafe too. It must
#      fail before partially copying files or changing the original source.
T=$(mktemp -d)
PACK="$T/pack"
mkdir -p "$PACK" "$T/.claude/skills"
cp -R ../install.sh ../VERSION ../skills ../scripts ../workflows ../hooks "$PACK/"
mkdir -p "$PACK/skills/super-board/nested/super-board"
ln -s "$PACK/skills/super-board/nested/super-board" "$T/.claude/skills/super-board"
cp -R "$PACK/skills" "$T/expected-skills"
plant_decoys "$T"
if OUT=$("$PACK/install.sh" --no-hooks "$T" 2>&1); then
  fail "a destination inside the source skill was accepted"
fi
diff -qr "$T/expected-skills" "$PACK/skills" >/dev/null || fail "nested destination changed source skills"
echo "$OUT" | grep -q 'overlap' || fail "nested source overlap should be explained: $OUT"
decoys_intact "$T" || fail "nested destination: DECOYS DESTROYED"
rm -rf "$T"

# 5 — every dispatcher script the skills reference is actually shipped. A verb
#     whose script was never installed fails only when a user reaches for it.
T=$(mktemp -d)
"$INSTALL" "$T" >/dev/null 2>&1
for s in super-board-run.sh super-board-stop.sh super-board-wave-plan.sh \
         super-board-deps.sh super-board-preflight.sh super-board-merge-gate.sh super-board-usage.sh super-board-pr-body.sh \
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
for h in guard-worktree-path.py guard-secrets.py guard-key-literals.py guard-delete-outside.py guard-protected-push.py cleanup-wt.py; do
  [ -f "$T/.claude/hooks/$h" ] || fail "hook $h was not installed"
done
[ ! -e "$T/.claude/skills/cleanup-wt" ] || fail "cleanup-wt is a hook now, not a skill"
[ ! -e "$T/.claude/hooks/dev" ] && [ ! -e "$T/.claude/hooks/gate-skill-evals.py" ] || fail "hooks/dev/ (skill-eval gate) must never be installed into a target"
S="$T/.claude/settings.json"
jq -e '.permissions.allow == ["Bash(ls:*)"]' "$S" >/dev/null || fail "existing permissions were lost"
jq -e '[.hooks.PreToolUse[].hooks[].command] | index("echo mine") != null' "$S" >/dev/null || fail "existing PreToolUse hook was lost"
jq -e '.hooks.Stop[0].hooks[0].command == "echo stop"' "$S" >/dev/null || fail "existing Stop hook was lost"
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash")] | length == 1' "$S" >/dev/null || fail "Bash matcher entry duplicated"
jq -e '[.hooks.SessionStart[].hooks[].command | select(contains("cleanup-wt.py --auto"))] | length == 1' "$S" >/dev/null \
  || fail "the cleanup-wt SessionStart hook is not wired by default"
jq -e '[.hooks[][].hooks[].command | select(contains("guard-protected-push"))] | length == 0' "$S" >/dev/null \
  || fail "the protected-push guard is opt-in: it must not be wired without --protect-main"
for h in guard-worktree-path guard-secrets guard-key-literals guard-delete-outside; do
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

# 7b — --no-hooks --protect-main: exactly the one guard, wired; no other hook.
#      Onboard names this command when protect-main finds no guard script.
T=$(mktemp -d)
"$INSTALL" --no-hooks --protect-main "$T" >/dev/null 2>&1
[ "$(ls "$T/.claude/hooks")" = "guard-protected-push.py" ] || fail "--no-hooks --protect-main should install only the push guard, got: $(ls "$T/.claude/hooks")"
jq -e '[.hooks[][].hooks[].command] == ["python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-protected-push.py"]' "$T/.claude/settings.json" >/dev/null \
  || fail "--no-hooks --protect-main should wire only the push guard"
rm -rf "$T"

# 8 — a settings.json that is not valid JSON is left exactly as it was.
T=$(mktemp -d)
mkdir -p "$T/.claude"; printf '{ not json' > "$T/.claude/settings.json"
OUT=$("$INSTALL" "$T" 2>&1 || true)
[ "$(cat "$T/.claude/settings.json")" = "{ not json" ] || fail "invalid settings.json was modified"
echo "$OUT" | grep -q "not valid JSON" || fail "invalid settings.json should be reported, got: $OUT"
rm -rf "$T"

# 10 — --protect-main wires the opt-in push guard, once, next to the defaults.
T=$(mktemp -d)
"$INSTALL" --protect-main "$T" >/dev/null 2>&1
S="$T/.claude/settings.json"
jq -e '[.hooks.PreToolUse[].hooks[].command | select(contains("guard-protected-push.py"))] | length == 1' "$S" >/dev/null \
  || fail "--protect-main did not wire guard-protected-push"
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash")] | length == 1' "$S" >/dev/null || fail "--protect-main duplicated the Bash matcher"
OUT=$("$INSTALL" --protect-main "$T" 2>&1)
echo "$OUT" | grep -q "already present" || fail "a second --protect-main install should change nothing"
rm -rf "$T"

# 11 — AGENTS.md: a re-install refreshes only the managed block; a project without
#      a block is left alone; a rules-bearing CLAUDE.md gets the onboard hint; the
#      last line names onboard as the one next step.
T=$(mktemp -d)
printf '# AGENTS.md\n\n- keep me\n<!-- super-board:begin v0.0.1 -->\nold\n<!-- super-board:end -->\n- and me\n' > "$T/AGENTS.md"
printf '# Rules\n- pnpm\n' > "$T/CLAUDE.md"
OUT=$("$INSTALL" --no-hooks "$T" 2>&1)
grep -q '^- keep me$' "$T/AGENTS.md" && grep -q '^- and me$' "$T/AGENTS.md" || fail "install changed AGENTS.md outside the markers"
grep -q '^old$' "$T/AGENTS.md" && fail "install should refresh the managed block"
grep -q "super-board:begin v$(cat ../VERSION)" "$T/AGENTS.md" || fail "block should carry the pack version"
echo "$OUT" | grep -q "CLAUDE.md holds its own rules" || fail "a non-pointer CLAUDE.md should get the onboard hint"
[ "$(echo "$OUT" | tail -1)" = "👉 next: open Claude Code here and run /super-board onboard" ] || fail "last line should name onboard, got: $(echo "$OUT" | tail -1)"
echo "$OUT" | grep -q "📜 AGENTS.md: super-board block refreshed" || fail "the block refresh should be one grouped line, got: $OUT"
rm -rf "$T"
# SUPER_BOARD_QUIET_NEXT=1 (set by get.sh, which prints its own header and next step)
# prints only the 🔧 installing group: one line per group of files, no per-file list.
T=$(mktemp -d)
OUT=$(SUPER_BOARD_QUIET_NEXT=1 "$INSTALL" "$T" 2>&1)
[ "$(echo "$OUT" | head -1)" = "🔧 installing" ] || fail "quiet mode should start at the installing group, got: $OUT"
echo "$OUT" | grep -q "next:" && fail "quiet mode must not print the next step"
echo "$OUT" | grep -q "✓ skills, scripts and workflows → .claude/" || fail "quiet mode should print the grouped files line"
echo "$OUT" | grep -q "🛡️  6 guard hooks → .claude/settings.json (new file)" || fail "guard line should count hooks, got: $OUT"
[ "$(echo "$OUT" | wc -l | tr -d ' ')" -le 3 ] || fail "grouped output should be ≤ 3 lines here, got: $OUT"
rm -rf "$T"

# 12 — upgrade record: an older super-board in the target is written to
#      .claude/super-board/upgrade.json (from, to, the skills that are new) for onboard.
T=$(mktemp -d); mkdir -p "$T/.claude/skills/super-board" "$T/.claude/skills/super-build"
echo "1.8.2" > "$T/.claude/skills/super-board/VERSION"
OUT=$("$INSTALL" --no-hooks "$T" 2>&1)
jq -e --arg v "$(cat ../VERSION)" '.from == "1.8.2" and .to == $v and (.added_skills | index("super-collect")) and (.added_skills | index("super-build") | not)' \
  "$T/.claude/super-board/upgrade.json" >/dev/null || fail "upgrade.json wrong: $(cat "$T/.claude/super-board/upgrade.json" 2>&1)"
echo "$OUT" | grep -q "⬆️  upgrade from 1.8.2" || fail "the upgrade should be one grouped line, got: $OUT"
"$INSTALL" --no-hooks "$T" >/dev/null 2>&1
jq -e '.from == "1.8.2"' "$T/.claude/super-board/upgrade.json" >/dev/null || fail "a second install must keep the original from-version"
rm -rf "$T"
T=$(mktemp -d); "$INSTALL" --no-hooks "$T" >/dev/null 2>&1
[ -e "$T/.claude/super-board/upgrade.json" ] && fail "a fresh install is not an upgrade"
rm -rf "$T"
T=$(mktemp -d); printf '# AGENTS.md\n- mine\n' > "$T/AGENTS.md"
"$INSTALL" --no-hooks "$T" >/dev/null 2>&1
[ "$(cat "$T/AGENTS.md")" = "$(printf '# AGENTS.md\n- mine')" ] || fail "install must not add a block uninvited"
for s in super-board-env-check.sh super-board-merge-policy.py super-board-agents-md.py super-board-settings.py super-board-setup.py; do
  [ -x "$T/.claude/bin/$s" ] || fail "$s was not installed"
done
rm -rf "$T"

# 9 — the snippet the installer merges is the one hooks/README.md documents.
python3 - ../hooks/README.md ../hooks/settings-snippet.json <<'PY' || fail "hooks/README.md snippet and hooks/settings-snippet.json differ"
import json, re, sys
doc = re.search(r"```json\n(.*?)```", open(sys.argv[1]).read(), re.S).group(1)
sys.exit(0 if json.loads(doc) == json.load(open(sys.argv[2])) else 1)
PY

echo "PASS: test-install.sh (17 scenarios)"
