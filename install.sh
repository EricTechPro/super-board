#!/usr/bin/env bash
# super-board installer.
# Copies skills/ + scripts/ into the target project's .claude/ tree.
#
# Usage:
#   ./install.sh [target-project-dir]
# Defaults to the current working directory.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$PWD}"

if [ ! -d "$TARGET" ]; then
  echo "target directory not found: $TARGET" >&2
  exit 64
fi

if [ ! -d "$TARGET/.claude" ]; then
  echo "creating $TARGET/.claude (didn't exist)"
fi

mkdir -p "$TARGET/.claude/skills" "$TARGET/.claude/bin"

echo "→ installing skills into $TARGET/.claude/skills/"
# A project may keep the real skill directories elsewhere and symlink them into
# .claude/skills — a layout some repos use to share one tree between .claude and
# another agent host. `cp -R src dest/` fails outright on such a target ("Not a
# directory"), so resolve the link and write to where it actually points. That
# keeps the project's chosen layout instead of replacing it with a plain copy.
for skill in super-board super-build super-qa super-review; do
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
  echo "    ✓ $skill$note"
done

echo "→ installing dispatcher scripts into $TARGET/.claude/bin/"
for script in super-board-run.sh super-board-gh-guard.sh super-board-status.py super-board-wave-plan.sh super-board-deps.sh super-board-merge-gate.sh super-review-file-refactor.sh super-qa-file-bug.sh super-board-stop.sh; do
  if [ -f "$REPO_ROOT/scripts/$script" ]; then
    cp "$REPO_ROOT/scripts/$script" "$TARGET/.claude/bin/"
    chmod +x "$TARGET/.claude/bin/$script"
    echo "    ✓ $script"
  fi
done

echo "→ installing dynamic workflow into $TARGET/.claude/workflows/"
mkdir -p "$TARGET/.claude/workflows"
if [ -f "$REPO_ROOT/workflows/super-board-wave.js" ]; then
  cp "$REPO_ROOT/workflows/super-board-wave.js" "$TARGET/.claude/workflows/"
  echo "    ✓ super-board-wave.js"
fi

echo
echo "✓ installed. next steps:"
echo "  1. write a config at $TARGET/.claude/super-board/configs/<slug>.json"
echo "  2. from inside Claude Code, run /super-board run <slug>"
echo
echo "see README.md for the config schema."
