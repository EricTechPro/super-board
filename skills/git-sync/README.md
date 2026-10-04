# /git-sync

Commits the working tree, pulls and pushes the current branch in one pass, then says what it did.

## What It Does

- **One change, one commit.** Groups the diff into logical changes and stages each by path. Never `git add -A`.
- **Writes the host's commit format** when the repo's `AGENTS.md`, `CLAUDE.md` or `CONTRIBUTING.md` defines one; otherwise the super-board [writing standard](../super-board/references/writing-standard.md).
- **Refuses secrets.** A `.env*`, key or credential file stops the run with a warning.
- **Gates Supabase changes.** Schema edits need a migration file; advisors and `migration list --local` run when the CLI is up. Defers to the `supabase` skill when it is installed.
- **Merges, never rebases.** `git pull --no-rebase`; conflicts are resolved hunk by hunk, then the host's fast checks run before the merge is concluded.
- **Pushes safely.** No force push. The default or a protected branch needs your yes; otherwise it offers a PR.

## When To Use It

- At the end of a piece of work, to get it committed and onto the remote.
- When your branch is behind and you want it caught up and pushed.

## Install

Ships in the super-board pack as a secondary skill. `install.sh` copies `skills/git-sync/` to `.claude/skills/git-sync/`. Needs `git`; uses `gh` and the Supabase CLI when present.
