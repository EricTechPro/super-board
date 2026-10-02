#!/bin/sh
# git pre-commit for the super-board repo itself: keep README.md's skill tables
# in step with skills/*/SKILL.md and skills/families.json.
#
# When the commit touches skills/, run the README sync. If it had to change
# README.md, stop the commit so you can stage the regenerated file.
#
# Install:  ln -s ../../hooks/pre-commit-readme.sh .git/hooks/pre-commit
#   (or call it from your existing pre-commit hook)
# Not copied into target projects by install.sh: it is for this repo only.

ROOT=$(git rev-parse --show-toplevel) || exit 0
cd "$ROOT" || exit 0
git diff --cached --name-only -- skills/ | grep -q . || exit 0

if ! python3 scripts/super-board-readme-sync.py --check 2>/dev/null; then
  python3 scripts/super-board-readme-sync.py || exit 1
  echo ""
  echo "✗ Commit stopped: README.md skill tables were stale and have been regenerated."
  echo "  Review and stage it:  git add README.md   then commit again."
  exit 1
fi
exit 0
