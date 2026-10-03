#!/usr/bin/env bash
# super-board installer.
# Copies skills/, scripts/, workflows/ and the guard hooks into the target
# project's .claude/ tree, and merges the hook settings into
# .claude/settings.json (backed up first, never duplicated).
#
# Usage:
#   ./install.sh [--no-hooks] [--protect-main] [target-project-dir]
# Defaults to the current working directory. --no-hooks skips the guard hooks
# and leaves settings.json untouched. --protect-main also wires the opt-in
# guard that blocks direct and force pushes to main/master/base_branch; with
# --no-hooks it installs that one guard alone. The installer asks nothing:
# super-board onboard asks the questions (protect main is one of them).
#
# Output is grouped with emojis, one line per group of files (failures still name
# the file). Environment: SUPER_BOARD_QUIET_NEXT=1 prints only the "🔧 installing"
# group — get.sh sets it and prints its own header and summary around it.
#
# An older super-board already in the target (a different skills/super-board/VERSION,
# or one with no VERSION) is recorded in .claude/super-board/upgrade.json
# {from, to, added_skills}; onboard's 🔍 Checks finishes the upgrade and lists it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS=1
PROTECT=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --no-hooks) HOOKS=0 ;;
    --protect-main) PROTECT=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 64 ;;
    *) TARGET="$arg" ;;
  esac
done
TARGET="${TARGET:-$PWD}"

# Primary: the board and its lanes. Secondary: standalone helpers the lanes
# can call (visual, ui-refine-loop). Worktree cleanup (cleanup-wt) is a
# hook, not a skill: it ships with the guard hooks below.
PRIMARY_SKILLS="super-board super-build super-qa super-review super-collect"
SECONDARY_SKILLS="visual ui-refine-loop"

if [ ! -d "$TARGET" ]; then
  echo "target directory not found: $TARGET" >&2
  exit 64
fi

QUIET="${SUPER_BOARD_QUIET_NEXT:-}"
PACK_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || echo '?')"

# Record an upgrade BEFORE the copy overwrites the old VERSION.
PREV_VERSION=""
if [ -d "$TARGET/.claude/skills/super-board" ]; then
  PREV_VERSION="$(tr -d '[:space:]' < "$TARGET/.claude/skills/super-board/VERSION" 2>/dev/null || echo 'older')"
  [ -n "$PREV_VERSION" ] || PREV_VERSION="older"
fi
ADDED_SKILLS=""
if [ -n "$PREV_VERSION" ]; then
  for skill in $PRIMARY_SKILLS $SECONDARY_SKILLS; do
    [ -e "$TARGET/.claude/skills/$skill" ] || ADDED_SKILLS="$ADDED_SKILLS $skill"
  done
fi

[ -n "$QUIET" ] || echo "🧩 super-board $PACK_VERSION → $TARGET"
echo "🔧 installing"
mkdir -p "$TARGET/.claude/skills" "$TARGET/.claude/bin"

# A project may keep the real skill directories elsewhere and symlink them into
# .claude/skills — a layout some repos use to share one tree between .claude and
# another agent host. `cp -R src dest/` fails outright on such a target ("Not a
# directory"), so resolve the link and write to where it actually points. That
# keeps the project's chosen layout instead of replacing it with a plain copy.
for skill in $PRIMARY_SKILLS $SECONDARY_SKILLS; do
  if [ ! -d "$REPO_ROOT/skills/$skill" ]; then
    echo "    ✗ missing $skill in repo — skipping" >&2
    continue
  fi
  dest="$TARGET/.claude/skills/$skill"
  note=""
  if [ -L "$dest" ]; then
    # `cd -P` walks the link to its physical target in one step. Do NOT rebuild
    # the path from `readlink` output: `cd ""` SUCCEEDS in bash, so an empty
    # readlink silently leaves you in the parent, and the rm below then empties
    # .claude/skills instead of one skill. That is not hypothetical — it deleted
    # 190 entries on a real repo on 2026-08-20 before this comment existed.
    resolved=$(cd -P "$dest" 2>/dev/null && pwd) || resolved=""
    if [ -z "$resolved" ]; then
      echo "    ✗ $skill is a symlink pointing nowhere — skipping rather than replacing it" >&2
      continue
    fi
    dest="$resolved"
    note=" (via symlink → ${resolved#$TARGET/})"
  fi

  # Belt and braces: whatever the resolution produced, it must be a path ENDING
  # in this skill's own name. Anything else is a bug in the line above, and the
  # blast radius of being wrong here is the user's entire skills tree.
  case "$dest" in
    */"$skill") : ;;
    *) echo "    ✗ refusing to write $skill: resolved to '$dest', which is not a $skill directory" >&2
       continue ;;
  esac

  # Replace the contents, not the directory itself, so a symlink stays a symlink.
  mkdir -p "$dest"
  rm -rf "${dest:?}/"* 2>/dev/null || true
  cp -R "$REPO_ROOT/skills/$skill/." "$dest/"
  [ -z "$note" ] || echo "   ✓ $skill$note"
done

for script in super-board-run.sh super-board-gh-guard.sh super-board-status.py super-board-wave-plan.sh super-board-deps.sh super-board-preflight.sh super-board-merge-gate.sh super-board-merge-policy.py super-board-env-check.sh super-board-agents-md.py super-board-settings.py super-board-setup.py super-board-usage.sh super-board-pr-body.sh super-review-file-refactor.sh super-qa-file-bug.sh super-board-stop.sh; do
  if [ -f "$REPO_ROOT/scripts/$script" ]; then
    cp "$REPO_ROOT/scripts/$script" "$TARGET/.claude/bin/"
    chmod +x "$TARGET/.claude/bin/$script"
  fi
done

mkdir -p "$TARGET/.claude/workflows"
for wf in super-board-wave.js ui-refine-loop.js; do
  if [ -f "$REPO_ROOT/workflows/$wf" ]; then
    cp "$REPO_ROOT/workflows/$wf" "$TARGET/.claude/workflows/"
  fi
done
echo "   ✓ skills, scripts and workflows → .claude/"

SETTINGS_PY="$REPO_ROOT/scripts/super-board-settings.py"
# Stdlib-only merge (scripts/super-board-settings.py): keeps every existing key
# and hook, adds each guard command once per event + matcher, backs the file up
# before writing, and leaves an invalid settings.json untouched (exit 2).
# Prints one summary word for the settings line; the helper's own lines (an
# invalid-JSON refusal) go to stderr untouched.
merge_settings() {
  local had=0 res rc=0
  [ -f "$TARGET/.claude/settings.json" ] && had=1
  res=$(python3 "$SETTINGS_PY" hooks "$TARGET/.claude/settings.json" "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 2 ]; then printf '%s\n' "$res" >&2; echo "not valid JSON — left untouched"
  elif echo "$res" | grep -q "already present"; then echo "already present"
  elif [ "$had" -eq 1 ]; then echo "backup kept"
  else echo "new file"; fi
}

if [ "$HOOKS" -eq 1 ]; then
  mkdir -p "$TARGET/.claude/hooks"
  # hooks/*.py only: hooks/dev/ holds gates for repos that author skills, never installed.
  n=0
  for h in "$REPO_ROOT"/hooks/*.py; do
    [ -f "$h" ] || continue
    cp "$h" "$TARGET/.claude/hooks/"
    chmod +x "$TARGET/.claude/hooks/$(basename "$h")"
    n=$((n + 1))
  done
  SNIPPETS="$REPO_ROOT/hooks/settings-snippet.json"
  if [ "$PROTECT" -eq 1 ]; then SNIPPETS="$SNIPPETS $REPO_ROOT/hooks/settings-protect-main.json"; fi
  # shellcheck disable=SC2086
  echo "   🛡️  $n guard hooks → .claude/settings.json ($(merge_settings $SNIPPETS))"
elif [ "$PROTECT" -eq 1 ]; then
  # --no-hooks --protect-main: the one guard asked for, nothing else. This is the
  # command onboard names when its protect-main question finds no guard script.
  mkdir -p "$TARGET/.claude/hooks"
  cp "$REPO_ROOT/hooks/guard-protected-push.py" "$TARGET/.claude/hooks/"
  chmod +x "$TARGET/.claude/hooks/guard-protected-push.py"
  echo "   🛡️  --no-hooks: only the push guard → .claude/settings.json ($(merge_settings "$REPO_ROOT/hooks/settings-protect-main.json"))"
else
  echo "   ⏭️  guard hooks skipped (--no-hooks)"
fi

# AGENTS.md: a re-install refreshes the managed super-board block and touches
# nothing outside its markers. No block yet → onboard writes it (with consent).
if [ -f "$TARGET/AGENTS.md" ] && grep -q '^<!-- super-board:begin' "$TARGET/AGENTS.md"; then
  python3 "$REPO_ROOT/scripts/super-board-agents-md.py" block --root "$TARGET" \
    --template "$REPO_ROOT/skills/super-board/references/agents-md-block.md" \
    --version "$PACK_VERSION" >/dev/null 2>&1 \
    && echo "   📜 AGENTS.md: super-board block refreshed" \
    || echo "   ! AGENTS.md: couldn't refresh the super-board block — onboard repairs it"
fi
if [ -f "$TARGET/CLAUDE.md" ] && ! grep -m1 -v '^[[:space:]]*$' "$TARGET/CLAUDE.md" | grep -qx '@AGENTS.md'; then
  echo "   ! CLAUDE.md holds its own rules — onboard offers a merge"
fi

# Upgrade record for onboard's 🔍 Checks (it migrates config, labels, columns).
if [ -n "$PREV_VERSION" ] && [ "$PREV_VERSION" != "$PACK_VERSION" ]; then
  mkdir -p "$TARGET/.claude/super-board"
  python3 - "$TARGET/.claude/super-board/upgrade.json" "$PREV_VERSION" "$PACK_VERSION" $ADDED_SKILLS <<'PY'
import json, sys, time
path, frm, to, added = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
try:
    old = json.load(open(path))
except Exception:
    old = {}
rec = {"from": old.get("from", frm), "to": to, "added_skills": sorted(set(old.get("added_skills", []) + added)),
       "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
json.dump(rec, open(path, "w"), indent=2)
PY
  echo "   ⬆️  upgrade from $PREV_VERSION — onboard finishes it (config, labels, columns)"
fi

if [ -z "$QUIET" ]; then
  echo "🎉 super-board $PACK_VERSION is installed"
  echo "👉 next: open Claude Code here and run /super-board onboard"
fi
