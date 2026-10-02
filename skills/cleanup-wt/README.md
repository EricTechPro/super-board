# /cleanup-wt

Removes git worktrees and branches that are already merged, and keeps a recovery file for every one it touches.

Adapted from the `cleanup-wt` skill in Eric Tech's BookKeepingApp, ported to Python and generalised.

## What It Does

- **Finds what is safe to remove:** worktrees and local or remote branches whose work is already on a base branch, squash merges included (bases detected from `origin/HEAD`, or `--base`).
- **Dry-run first.** Without `--apply` it only prints the plan.
- **Never deletes unmerged work.** A dirty worktree on a merged branch is wip-committed and its branch kept; remote branches go only when merged and `gh` confirms no open PR.
- **Writes a recovery TSV** under `<git-common-dir>/cleanup-wt/` before acting, with the sha of everything removed.

## When To Use It

- When `.claude/worktrees/` or `git branch` has grown after a run of agent work.
- Automatically: `super-board-merge-gate.sh` runs it with `--post-merge` after every merge when it is installed, and `--auto` suits a `SessionStart` hook.

## Hook modes

| Flag | Does |
|---|---|
| `--post-merge` | apply, local only, never wip-commit, never force; quiet unless it acted |
| `--auto` | same, but only when a base tip moved since the last `--auto` run |

## Install

Ships in the super-board pack as a secondary skill. `install.sh` copies `skills/cleanup-wt/` to `.claude/skills/cleanup-wt/`. Needs `git` and Python 3 (stdlib only); `gh` is optional.

Test: `bash tests/test-cleanup-wt.sh`
