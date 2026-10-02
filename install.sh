#!/usr/bin/env bash
# super-board installer.
# Copies skills/, scripts/, workflows/ and the guard hooks into the target
# project's .claude/ tree, and merges the hook settings into
# .claude/settings.json (backed up first, never duplicated).
#
# Usage:
#   ./install.sh [--no-hooks] [target-project-dir]
# Defaults to the current working directory. --no-hooks skips the guard hooks
# and leaves settings.json untouched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS=1
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --no-hooks) HOOKS=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 64 ;;
    *) TARGET="$arg" ;;
  esac
done
TARGET="${TARGET:-$PWD}"

# Primary: the board and its lanes. Secondary: standalone helpers the lanes
# can call (visual, arch-loop) or that tidy up after them (cleanup-wt).
PRIMARY_SKILLS="super-board super-build super-qa super-review super-collect super-refine"
SECONDARY_SKILLS="visual arch-loop cleanup-wt"

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
  echo "    ✓ $skill$note"
done

echo "→ installing dispatcher scripts into $TARGET/.claude/bin/"
for script in super-board-run.sh super-board-gh-guard.sh super-board-status.py super-board-wave-plan.sh super-board-deps.sh super-board-merge-gate.sh super-board-usage.sh super-review-file-refactor.sh super-qa-file-bug.sh super-board-stop.sh; do
  if [ -f "$REPO_ROOT/scripts/$script" ]; then
    cp "$REPO_ROOT/scripts/$script" "$TARGET/.claude/bin/"
    chmod +x "$TARGET/.claude/bin/$script"
    echo "    ✓ $script"
  fi
done

echo "→ installing dynamic workflows into $TARGET/.claude/workflows/"
mkdir -p "$TARGET/.claude/workflows"
for wf in super-board-wave.js super-refine.js; do
  if [ -f "$REPO_ROOT/workflows/$wf" ]; then
    cp "$REPO_ROOT/workflows/$wf" "$TARGET/.claude/workflows/"
    echo "    ✓ $wf"
  fi
done

if [ "$HOOKS" -eq 1 ]; then
  echo "→ installing guard hooks into $TARGET/.claude/hooks/"
  mkdir -p "$TARGET/.claude/hooks"
  for h in "$REPO_ROOT"/hooks/*.py; do
    [ -f "$h" ] || continue
    cp "$h" "$TARGET/.claude/hooks/"
    chmod +x "$TARGET/.claude/hooks/$(basename "$h")"
    echo "    ✓ $(basename "$h")"
  done

  echo "→ merging hook settings into $TARGET/.claude/settings.json"
  # Stdlib-only merge: keeps every existing key and hook, adds each guard
  # command once per event + matcher, and backs the file up before writing.
  python3 - "$REPO_ROOT/hooks/settings-snippet.json" "$TARGET/.claude/settings.json" <<'PY'
import json, os, shutil, sys, time
snippet_path, settings_path = sys.argv[1], sys.argv[2]
snippet = json.load(open(snippet_path))
settings = {}
if os.path.exists(settings_path):
    try:
        settings = json.load(open(settings_path))
    except ValueError as e:
        print(f"    ✗ {settings_path} is not valid JSON ({e}); left untouched — merge hooks/settings-snippet.json by hand", file=sys.stderr)
        sys.exit(0)
    if not isinstance(settings, dict):
        print(f"    ✗ {settings_path} is not a JSON object; left untouched", file=sys.stderr)
        sys.exit(0)
hooks = settings.setdefault("hooks", {})
added = 0
for event, entries in snippet["hooks"].items():
    current = hooks.setdefault(event, [])
    for entry in entries:
        matcher = entry.get("matcher")
        target = next((e for e in current if e.get("matcher") == matcher), None)
        if target is None:
            target = {"matcher": matcher} if matcher is not None else {}
            target["hooks"] = []
            current.append(target)
        have = {h.get("command") for e in current if e.get("matcher") == matcher for h in e.get("hooks", [])}
        for h in entry["hooks"]:
            if h["command"] not in have:
                target.setdefault("hooks", []).append(h)
                have.add(h["command"])
                added += 1
if added == 0:
    print("    ✓ already present — nothing to change")
    sys.exit(0)
if os.path.exists(settings_path):
    backup = f"{settings_path}.bak-{time.strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(settings_path, backup)
    print(f"    ✓ backup: {backup}")
tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_path)
print(f"    ✓ {added} hook command(s) added")
PY
else
  echo "→ skipping guard hooks (--no-hooks)"
fi

echo
echo "✓ installed. next steps:"
echo "  1. write a config at $TARGET/.claude/super-board/configs/<slug>.json (or run /super-board onboard)"
echo "  2. from inside Claude Code, run /super-board run <slug>"
echo
echo "see README.md and docs/super-board/README.md for the config schema."
