---
name: cleanup-wt
description: Remove git worktrees and branches whose work is already on a base branch — local and remote, squash merges included — with a dry run first and a recovery TSV on every run. Never deletes unmerged work or the worktree it runs in. Use when the user says cleanup-wt, clean up worktrees or branches, delete merged branches, or after a release or a batch of merged PRs.
---

# cleanup-wt

One script does the work. Run it, show the table, act only on the user's word or a
clear request to apply. The script lives next to this file:
`scripts/cleanup-wt.py` (installed at `.claude/skills/cleanup-wt/scripts/cleanup-wt.py`).

1. Dry run from the repo root or any worktree of it:

   ```bash
   python3 .claude/skills/cleanup-wt/scripts/cleanup-wt.py
   ```

   It fetches `origin --prune`, prints the bases it detected, then one row per branch,
   worktree and remote branch: `WOULD` (goes on `--apply`), `REVIEW` (unmerged and older
   than today: the user decides), `KEEP` (with the reason).
2. Show the table in a fenced block and summarise it in one line: how many would go,
   how many need review.
3. If the request was to clean up, or the user says go, run again with `--apply`. Relay
   the `applied:` lines and the TSV path.
4. `--force` only when the user names the `KEEP` / `REVIEW` worktrees they want gone. It
   removes locked, fresh, open-PR and unmerged *worktrees*, so it can pull a worktree out
   from under a running agent — but their branches are kept (dirty state wip-committed
   first). No flag deletes an unmerged branch.

**Done when** the user has the table, and after `--apply` the `applied:` lines and the
recovery TSV path.

## Bases

Detected, never hardcoded: the remote default branch (`origin/HEAD`), else
`init.defaultBranch`, else `main`/`master` — plus `staging`, `develop`, `dev` when they
exist. Override with `--base <name>` (repeatable) or `CLEANUP_WT_BASES=a,b`. If
`origin/HEAD` is missing, `git remote set-head origin --auto` sets it.

Bases, `main`, `master` and the branch checked out in the main checkout are never
touched. Neither is the worktree the script runs in.

## What counts as merged

The tip is an ancestor of a base (local or `origin/`), or `git cherry` finds every patch
already there, or the squash probe finds one commit equal to the whole branch, or `gh`
reports a PR merged at that tip.

A dirty worktree on a merged branch is wip-committed (`--no-verify`) before removal, and
its branch is kept with the snapshot. A worktree outside `.claude/worktrees/` is removed
and its branch kept (a detached one gets a `cleanup-wt/wip-<name>` branch first). Remote
branches are deleted only when merged and `gh` confirms no open PR; without `gh`, every
remote branch is kept.

## Flags

`--apply` acts. `--force` (step 4). `--local-only`, `--remote-only` limit scope.
`--no-fetch` uses refs as they are. `--tsv <file>` sets the recovery file. `--base`
(above). Hook modes, not for interactive use:

- `--post-merge` — apply, local only, never wip-commit, never force, silent unless it
  acted. For a merge gate right after a PR lands; `super-board-merge-gate.sh` runs it
  after every merge when this skill is installed.
- `--auto` — the same, but only when a base tip moved since the last `--auto` run; the
  first run only records the tips. For `SessionStart`.

Under a hook, output is `hookSpecificOutput.additionalContext` JSON; errors exit 0.

## Recovery

Every run writes `<git-common-dir>/cleanup-wt/<timestamp>.tsv` before acting:
`when, kind, name, sha, path, action, reason`. To restore an entry:

```bash
git branch <name> <sha>                         # local branch
git push origin <sha>:refs/heads/<name>         # remote branch
git worktree add .claude/worktrees/<n> <name>   # a worktree on it
```

Unreachable commits survive about two weeks before `git gc`; restore soon.

## Credit

Adapted from the `cleanup-wt` skill in Eric Tech's BookKeepingApp (Node), ported to
Python and generalised: base branches detected instead of `staging`/`main`, unmerged
branches never deleted, orphan-folder deletion dropped.
